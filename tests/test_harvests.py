from utils import actions, checks, utils
import pytest

# tests harvesting a strategy that returns profits correctly
def test_profitable_harvest(
    chain, accounts, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, MAX_BPS,
    n_proxy_views, n_proxy_batch
):
    # Deposit to the vault
    actions.user_deposit(user, vault, token, amount)
    
    amount_fcash = n_proxy_views.getfCashAmountGivenCashAmount(
        strategy.currencyID(),
        - amount / strategy.DECIMALS_DIFFERENCE() * MAX_BPS,
        1,
        chain.time()+5
        )

    # Harvest 1: Send funds through the strategy
    chain.sleep(1)
    strategy.harvest({"from": strategist})

    account = n_proxy_views.getAccount(strategy)
    next_settlement = account[0][0]

    assert pytest.approx(account[2][0][3], rel=RELATIVE_APPROX) == amount_fcash

    position_cash = n_proxy_views.getCashAmountGivenfCashAmount(
        strategy.currencyID(),
        - amount_fcash,
        1,
        chain.time()+1
        )[1] * strategy.DECIMALS_DIFFERENCE() / MAX_BPS
    total_assets = strategy.estimatedTotalAssets()
    
    assert pytest.approx(total_assets, rel=RELATIVE_APPROX) == position_cash
    
    # Add some code before harvest #2 to simulate earning yield
    actions.wait_until_settlement(next_settlement)
    position_cash = n_proxy_views.getCashAmountGivenfCashAmount(
        strategy.currencyID(),
        - amount_fcash,
        1,
        chain.time()+1
        )[1] * strategy.DECIMALS_DIFFERENCE() / MAX_BPS

    # check that estimatedTotalAssets estimates correctly
    assert pytest.approx(strategy.estimatedTotalAssets(), rel=RELATIVE_APPROX) == position_cash
    assert position_cash > amount
    profit_amount = position_cash - amount

    before_pps = vault.pricePerShare()
    print("Vault assets 1: ", vault.totalAssets())
    # Harvest 2: Realize profit
    chain.sleep(1)
    tx = strategy.harvest({"from": strategist})

    checks.check_harvest_profit(tx, profit_amount, RELATIVE_APPROX)

    chain.sleep(3600 * 6)  # 6 hrs needed for profits to unlock
    chain.mine(1)
    profit = token.balanceOf(vault.address)  # Profits go to vault
    print("ETH Balance is ", vault.balance())
    print("Vault assets 2: ", vault.totalAssets())
    assert pytest.approx(profit, rel=RELATIVE_APPROX) == profit_amount
    assert vault.pricePerShare() > before_pps


# # tests harvesting a strategy that reports losses
def test_lossy_harvest(
    chain, accounts, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, MAX_BPS,
    n_proxy_views, n_proxy_batch, token_whale, currencyID, balance_threshold
):
    # Deposit to the vault
    actions.user_deposit(user, vault, token, amount)

    actions.whale_drop_rates(n_proxy_batch, token_whale, token, n_proxy_views, currencyID, balance_threshold)

    amount_fcash = n_proxy_views.getfCashAmountGivenCashAmount(
        strategy.currencyID(),
        - amount / strategy.DECIMALS_DIFFERENCE() * MAX_BPS,
        1,
        chain.time()+5
        )

    # Harvest 1: Send funds through the strategy
    chain.sleep(1)
    strategy.harvest({"from": strategist})
    
    account = n_proxy_views.getAccount(strategy)
    next_settlement = account[0][0]

    assert pytest.approx(account[2][0][3], rel=RELATIVE_APPROX) == amount_fcash

    actions.wait_half_until_settlement(next_settlement)
    actions.whale_exit(n_proxy_batch, token_whale, n_proxy_views, currencyID)
    print("Amount: ", amount)
    position_cash = strategy.estimatedTotalAssets()
    loss_amount = amount - position_cash
    assert loss_amount > 0
    print("TA: ", position_cash)
    # Harvest 2: Realize loss
    chain.sleep(1)

    vault.updateStrategyDebtRatio(strategy, 0, {"from":vault.governance()})
    tx = strategy.harvest({"from": strategist})
    print(tx.events["Harvested"])
    checks.check_harvest_loss(tx, loss_amount, RELATIVE_APPROX)
    chain.sleep(3600 * 6)  # 6 hrs needed for profits to unlock
    chain.mine(1)

    # User will withdraw accepting losses
    vault.withdraw(vault.balanceOf(user), user, 10_000, {"from": user})
    assert pytest.approx(token.balanceOf(user) + loss_amount, rel=RELATIVE_APPROX) == amount


# tests harvesting a strategy twice, once with loss and another with profit
# it checks that even with previous profit and losses, accounting works as expected
def test_choppy_harvest(
    chain, accounts, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, MAX_BPS,
    n_proxy_views, n_proxy_batch, token_whale, currencyID, n_proxy_account, n_proxy_implementation,
    balance_threshold
):
    # Deposit to the vault
    # assert token.balanceOf(user) == amount + 5e20 - 3
    actions.user_deposit(user, vault, token, amount)

    actions.whale_drop_rates(n_proxy_batch, token_whale, token, n_proxy_views, currencyID, balance_threshold)

    # Harvest 1: Send funds through the strategy
    chain.sleep(1)
    strategy.harvest({"from": strategist})

    account = n_proxy_views.getAccount(strategy)
    next_settlement = account[0][0]

    actions.wait_half_until_settlement(next_settlement)
    actions.whale_exit(n_proxy_batch, token_whale, n_proxy_views, currencyID)

    print("TA: ", strategy.estimatedTotalAssets())

    # Harvest 2: Realize loss
    chain.sleep(1)
    position_cash = strategy.estimatedTotalAssets()
    loss_amount = (amount - position_cash) / 2
    assert loss_amount > 0
    vault.updateStrategyDebtRatio(strategy, 5_000, {"from":vault.governance()})
    tx = strategy.harvest({"from": strategist})

    # Harvest 3: Realize profit on the rest of the position
    print("TA 1: ", strategy.estimatedTotalAssets())
    chain.sleep(next_settlement - chain.time() - 100)
    chain.mine(1)
    print("TA 2: ", strategy.estimatedTotalAssets())
    position_cash = strategy.estimatedTotalAssets()
    profit_amount = position_cash - vault.totalDebt()
    assert profit_amount > 0
    
    tx = strategy.harvest({"from": strategist})
    checks.check_harvest_profit(tx, profit_amount, RELATIVE_APPROX)

    # User will withdraw accepting losses
    chain.sleep(3600 * 6)  # 6 hrs needed for profits to unlock
    chain.mine(1)
    assert pytest.approx(vault.strategies(strategy)["totalLoss"], rel=RELATIVE_APPROX) == loss_amount
    assert pytest.approx(vault.strategies(strategy)["totalGain"], rel=RELATIVE_APPROX) == profit_amount
    vault.withdraw({"from": user})

def test_maturity_harvest(
    chain, accounts, token, vault, strategy, user, strategist, amount, RELATIVE_APPROX, MAX_BPS,
    n_proxy_views, n_proxy_batch, token_whale, currencyID, n_proxy_account, n_proxy_implementation,
    balance_threshold
):
    # Deposit to the vault
    actions.user_deposit(user, vault, token, amount)

    amount_fcash = n_proxy_views.getfCashAmountGivenCashAmount(
        strategy.currencyID(),
        - amount / strategy.DECIMALS_DIFFERENCE() * MAX_BPS,
        1,
        chain.time()+5
        )
    
    # Harvest 1: Send funds through the strategy
    chain.sleep(1)
    strategy.harvest({"from": strategist})

    account = n_proxy_views.getAccount(strategy)
    next_settlement = account[0][0]

    assert pytest.approx(account[2][0][3], rel=RELATIVE_APPROX) == amount_fcash

    position_cash = n_proxy_views.getCashAmountGivenfCashAmount(
        strategy.currencyID(),
        - amount_fcash,
        1,
        chain.time()+1
        )[1] * strategy.DECIMALS_DIFFERENCE() / MAX_BPS
    total_assets = strategy.estimatedTotalAssets()
    
    assert pytest.approx(total_assets, rel=RELATIVE_APPROX) == position_cash
    
    # Add some code before harvest #2 to simulate earning yield
    actions.wait_until_settlement(next_settlement)
    chain.sleep(next_settlement - chain.time() + 1)
    chain.mine(1)
    totalAssets = strategy.estimatedTotalAssets()
    position_cash = account[2][0][3] * strategy.DECIMALS_DIFFERENCE() / MAX_BPS

    assert pytest.approx(position_cash+token.balanceOf(strategy), rel=RELATIVE_APPROX) == totalAssets
    profit_amount = totalAssets - amount
    assert profit_amount > 0
    n_proxy_implementation.initializeMarkets(currencyID, 0)
    
    vault.updateStrategyDebtRatio(strategy, 0, {"from":vault.governance()})
    tx = strategy.harvest()
    assert tx.events["Harvested"]["profit"] >= profit_amount

    chain.sleep(3600 * 6)  # 6 hrs needed for profits to unlock
    chain.mine(1)
    assert vault.strategies(strategy)["totalLoss"] == 0
    assert vault.strategies(strategy)["totalGain"] >= profit_amount
    # assert 0==1
    vault.withdraw({"from": user})

    