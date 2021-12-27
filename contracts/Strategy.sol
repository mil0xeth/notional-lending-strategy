// SPDX-License-Identifier: AGPL-3.0
// Feel free to change the license, but this is what we use

// Feel free to change this version of Solidity. We support >=0.6.0 <0.7.0;
pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "../interfaces/notional/NotionalProxy.sol";
import "../interfaces/IWETH.sol";


// These are the core Yearn libraries
import {
    BaseStrategy,
    StrategyParams
} from "@yearnvaults/contracts/BaseStrategy.sol";
import {
    SafeERC20,
    SafeMath,
    IERC20,
    Address
} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "@openzeppelin/contracts/math/Math.sol";

import {
    BalanceActionWithTrades,
    PortfolioAsset,
    AssetRateParameters,
    Token,
    ETHRate
} from "../interfaces/notional/Types.sol";

// Import interfaces for many popular DeFi projects, or add your own!
//import "../interfaces/<protocol>/<Interface>.sol";

contract Strategy is BaseStrategy {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    NotionalProxy public immutable nProxy;
    uint16 private immutable currencyID; 
    uint16 public minAmountWant;
    IWETH public weth;

    uint256 private constant MAX_BPS = 10_000;
    uint256 private SCALE_FCASH = 9_500;

    // DEBUGGING VARIABLES - WILL BE REMOVED
    uint256 public testVar1;
    int256 public testVar2;
    int256 public testVar3;
    int256 public testVar4;
    bytes32 public testVar5;

    constructor(address _vault, NotionalProxy _nProxy) public BaseStrategy(_vault) {
        // You can set these parameters on deployment to whatever you want
        // maxReportDelay = 6300;
        // profitFactor = 100;
        // debtThreshold = 0;
        currencyID = 1;
        nProxy = _nProxy;

        weth = IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    }

    receive() external payable {}

    // ******** OVERRIDE THESE METHODS FROM BASE CONTRACT ************

    function name() external view override returns (string memory) {
        // Add your own name here, suggestion e.g. "StrategyCreamYFI"
        return "StrategyNotionalLending";
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        
        return balanceOfWant()
            .add(_getTotalValueFromPortfolio())
            // .sub() TODO: Include cost of getting out: Already included in value of fcash?
            // Add ETH balance of weth vault? Or re-deposit after withdraw
        ;
    }

    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        // NOTE: Return `_profit` which is value generated by all positions, priced in `want`
        // NOTE: Should try to free up at least `_debtOutstanding` of underlying position

        // Withdraw from past terms
        _checkPositionsAndWithdraw();

        // Calculate assets (estimatedTotalAssets)
        uint256 totalAssetsAfterProfit = estimatedTotalAssets();
        // Get total debt from vault: vault.strategies(address(this)).totalDebt;
        uint256 strategyTotalDebt = vault.strategies(address(this)).totalDebt;

        // Calculate P&L: assets - debt ==> profit, loss

        _profit = totalAssetsAfterProfit > strategyTotalDebt
            ? totalAssetsAfterProfit.sub(strategyTotalDebt)
            : 0;

        uint256 _amountFreed;
        (_amountFreed, _loss) = liquidatePosition(
            _debtOutstanding.add(_profit)
        );
        _debtPayment = Math.min(_debtOutstanding, _amountFreed);

        if (_loss > _profit) {
            // Example:
            // debtOutstanding 100, profit 50, _amountFreed 100, _loss 50
            // loss should be 0, (50-50)
            // profit should endup in 0
            _loss = _loss.sub(_profit);
            _profit = 0;
        } else {
            // Example:
            // debtOutstanding 100, profit 50, _amountFreed 140, _loss 10
            // _profit should be 40, (50 profit - 10 loss)
            // loss should end up in be 0
            _profit = _profit.sub(_loss);
            _loss = 0;
        }
    }

    function adjustPosition(uint256 _debtOutstanding) internal override {
        // Check if we have invested in past terms
        // probably we need to check if we have a previous term we can take funds from
        _checkPositionsAndWithdraw();

        uint256 availableWantBalance = balanceOfWant();
        if(availableWantBalance <= _debtOutstanding) {
            return;
        }
        availableWantBalance = availableWantBalance.sub(_debtOutstanding);
        if(availableWantBalance < minAmountWant) {
            return;
        }

        // Only necessary for wETH/ ETH pair
        weth.withdraw(availableWantBalance);
        
        BalanceActionWithTrades[] memory actions = new BalanceActionWithTrades[](1);
        
        MarketParameters[] memory marketParameters = nProxy.getActiveMarkets(currencyID);

        // TODO: Instead only selling the amount in market 1, loop through all markets to 
        // identify higher APY opportunities

        int256 fCashAmountToTrade = nProxy.getfCashAmountGivenCashAmount(
            currencyID, 
            -int88(availableWantBalance / 1e10), 
            1, 
            block.timestamp
            );

        // Trade the shortest maturity market
        bytes32[] memory trades = new bytes32[](1);
        // Scale down fCash amount 95% to avoid potential reverts
        trades[0] = getTradeFrom(
            0, 
            1, 
            uint256(fCashAmountToTrade).mul(SCALE_FCASH).div(MAX_BPS)
            );
        testVar1 = availableWantBalance;
        testVar4 = fCashAmountToTrade;
        testVar5 = trades[0];
        
        actions[0] = BalanceActionWithTrades(
            DepositActionType.DepositUnderlying,
            currencyID,
            availableWantBalance,
            0, // TODO: review this
            true, // TODO: review this
            true, // TODO: review this
            trades);

        nProxy.batchBalanceAndTradeAction{value: availableWantBalance}(address(this), actions);
    }

    function getTradeFrom(uint8 _tradeType, uint256 _marketIndex, uint256 _amount) internal returns (bytes32 result) {
        uint8 tradeType = uint8(_tradeType);
        uint8 marketIndex = uint8(_marketIndex);
        uint88 fCashAmount = uint88(_amount);
        uint32 minSlippage = uint32(0);
        uint120 padding = uint120(0);

        result = bytes32(uint(tradeType)) << 248;
        result |= bytes32(uint(marketIndex) << 240);
        result |= bytes32(uint(fCashAmount) << 152);
        result |= bytes32(uint(minSlippage) << 120);

        return result;
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        uint256 balance = balanceOfWant();
        if (balance >= _amountNeeded) {
            return (_amountNeeded, 0);
        }

        PortfolioAsset[] memory _accountPortfolio = nProxy.getAccountPortfolio(address(this));
        MarketParameters[] memory _activeMarkets = nProxy.getActiveMarkets(currencyID);
        bytes32[] memory trades = new bytes32[](_accountPortfolio.length);
        
        uint256 _remainingAmount = _amountNeeded;
        // TODO: Also loop through active markets as each position can only be closed against its own market
        // Use maturity date to identify the active market!
        for(uint256 i=0; i<_accountPortfolio.length; i++) {
            if (_remainingAmount > 0) {
                for(uint256 j=0; j<_activeMarkets.length; j++){
                    if(_accountPortfolio[i].maturity == _activeMarkets[j].maturity) {
                        (int256 cashPosition, int256 underlyingPosition) = nProxy.getCashAmountGivenfCashAmount(
                            currencyID,
                            int88(-_accountPortfolio[i].notional),
                            j+1,
                            block.timestamp
                        );
                        underlyingPosition = underlyingPosition * 1e10;
                        if (underlyingPosition > 0) {
                            if(underlyingPosition >= int256(_remainingAmount)) {

                                int256 _fCashRemainingAmount = nProxy.getfCashAmountGivenCashAmount(
                                    currencyID,
                                    -int88(_remainingAmount / 1e10),
                                    j+1,
                                    block.timestamp
                                );

                                trades[i] = getTradeFrom(1, j+1, uint256(_fCashRemainingAmount));
                                _remainingAmount = 0;
                            } else {
                                trades[i] = getTradeFrom(1, j+1, uint256(_accountPortfolio[i].notional));
                                _remainingAmount -= uint256(underlyingPosition);
                            }
                            break;
                        }
                    }
                }
            }
        }

        BalanceActionWithTrades[] memory actions = new BalanceActionWithTrades[](1);
        actions[0] = BalanceActionWithTrades(
            DepositActionType.None,
            currencyID,
            0,
            0, 
            true,
            true,
            trades
        );
        nProxy.batchBalanceAndTradeAction{value: 0}(address(this), actions);

        // Assess result 

        uint256 totalAssets = want.balanceOf(address(this));
        if (_amountNeeded > totalAssets) {
            _liquidatedAmount = totalAssets;
            _loss = _amountNeeded.sub(totalAssets);
        } else {
            _liquidatedAmount = _amountNeeded;
        }
    }

    function liquidateAllPositions() internal override returns (uint256) {
        PortfolioAsset[] memory _accountPortfolio = nProxy.getAccountPortfolio(address(this));
        MarketParameters[] memory _activeMarkets = nProxy.getActiveMarkets(currencyID);
        bytes32[] memory trades = new bytes32[](_accountPortfolio.length);

        for(uint256 i=0; i<_accountPortfolio.length; i++) {
            
            for(uint256 j=0; j<_activeMarkets.length; j++){
                if(_accountPortfolio[i].maturity == _activeMarkets[j].maturity) {
                    (int256 cashPosition, int256 underlyingPosition) = nProxy.getCashAmountGivenfCashAmount(
                        currencyID,
                        int88(-_accountPortfolio[i].notional),
                        j+1,
                        block.timestamp
                    );
                    trades[i] = getTradeFrom(1, j+1, uint256(_accountPortfolio[i].notional));
                    break;
                }
            }
        }

        BalanceActionWithTrades[] memory actions = new BalanceActionWithTrades[](1);
        actions[0] = BalanceActionWithTrades(
            DepositActionType.None,
            currencyID,
            0,
            0, 
            true,
            true,
            trades
        );
        nProxy.batchBalanceAndTradeAction{value: 0}(address(this), actions);
        
        return want.balanceOf(address(this));
    }
    // DEBUGGING FUNCTIONS:
    function _liquidateAll() public {
        liquidateAllPositions();
    }

    function _liquidate(uint256 _amountNeeded) public returns (uint256 _liquidatedAmount, uint256 _loss){
        (_liquidatedAmount, _loss) = liquidatePosition(_amountNeeded);
    }

    // END OF DEBUGGING FUNCTIONS

    // NOTE: Can override `tendTrigger` and `harvestTrigger` if necessary

    function prepareMigration(address _newStrategy) internal override {
        // TODO: Transfer any non-`want` tokens to the new strategy
        // NOTE: `migrate` will automatically forward all `want` in this strategy to the new one
    }

    // Override this to add all tokens/tokenized positions this contract manages
    // on a *persistent* basis (e.g. not just for swapping back to want ephemerally)
    // NOTE: Do *not* include `want`, already included in `sweep` below
    //
    // Example:
    //
    //    function protectedTokens() internal override view returns (address[] memory) {
    //      address[] memory protected = new address[](3);
    //      protected[0] = tokenA;
    //      protected[1] = tokenB;
    //      protected[2] = tokenC;
    //      return protected;
    //    }
    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    {}

    /**
     * @notice
     *  Provide an accurate conversion from `_amtInWei` (denominated in wei)
     *  to `want` (using the native decimal characteristics of `want`).
     * @dev
     *  Care must be taken when working with decimals to assure that the conversion
     *  is compatible. As an example:
     *
     *      given 1e17 wei (0.1 ETH) as input, and want is USDC (6 decimals),
     *      with USDC/ETH = 1800, this should give back 1800000000 (180 USDC)
     *
     * @param _amtInWei The amount (in wei/1e-18 ETH) to convert to `want`
     * @return The amount in `want` of `_amtInEth` converted to `want`
     **/
    function ethToWant(uint256 _amtInWei)
        public
        view
        virtual
        override
        returns (uint256)
    {
        // TODO create an accurate price oracle
        return _amtInWei;
    }

    // INTERNAL FUNCTIONS

    function _checkPositionsAndWithdraw() internal {

        // PortfolioAsset[] memory _accountPortfolio = nProxy.getAccountPortfolio(address(this));

        // for(uint256 i=0; i<_accountPortfolio.length; i++) {

        //     if(_accountPortfolio[i].maturity <= block.timestamp) {
        //         // Withdraw position, to receive want balance here
        //     }

        // }

        nProxy.settleAccount(address(this));

        (int256 cashBalance, 
        int256 nTokenBalance,
        uint256 lastClaimTime) = nProxy.getAccountBalance(currencyID, address(this));

        if(cashBalance > 0) {
            nProxy.withdraw(currencyID, uint88(cashBalance), true);
        }

    }

    function _getTotalValueFromPortfolio() internal view returns(uint256 _totalWantValue) {
        PortfolioAsset[] memory _accountPortfolio = nProxy.getAccountPortfolio(address(this));
        MarketParameters[] memory _activeMarkets = nProxy.getActiveMarkets(currencyID);
        
        for(uint256 i=0; i<_accountPortfolio.length; i++) {
            for(uint256 j=0; j<_activeMarkets.length; j++){
                if(_accountPortfolio[i].maturity == _activeMarkets[j].maturity) {
                    (int256 cashPosition, int256 underlyingPosition) = nProxy.getCashAmountGivenfCashAmount(
                        currencyID,
                        int88(-_accountPortfolio[i].notional),
                        j+1,
                        block.timestamp
                    );
                    _totalWantValue += uint256(underlyingPosition) * 1e10;
                    break;
                }
            }
        }
    }

    // CALCS
    function balanceOfWant() public view returns (uint256) {
        return want.balanceOf(address(this));
    }

    function _wantToAsset(uint256 _availableWantBalance) public view returns(int256 _availableAssetBalance) {

        (Token memory _assetToken,
        Token memory _underlyingToken,
        ETHRate memory _ethRate,
        AssetRateParameters memory _assetRate) = nProxy.getCurrencyAndRates(currencyID);

        _availableAssetBalance = int256(_availableWantBalance) * _underlyingToken.decimals / _assetRate.rate;
    }

    function _assetToWant(int256 _assetAmount) internal view returns(uint256 _wantAmount) {
        (Token memory _assetToken,
        Token memory _underlyingToken,
        ETHRate memory _ethRate,
        AssetRateParameters memory _assetRate) = nProxy.getCurrencyAndRates(currencyID);

        _wantAmount = uint256(_assetAmount * _assetRate.rate / _underlyingToken.decimals);
    }

    // NOTIONAL FUNCTIONS

}
