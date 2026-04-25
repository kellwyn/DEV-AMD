"""
Order execution + confirmation gate — AMD v1.00

Auto-execute mode  (cfg.manual_confirm = False):
  Fires the order immediately — only use after demo validation.

Manual mode        (cfg.manual_confirm = True):
  Displays setup summary and waits for  y / n / q.
"""

import MetaTrader5 as mt5

from .signals  import TradeSetup
from .strategy import StrategyConfig
from .periods  import record_trade


# ── Position sizing ───────────────────────────────────────────────────────────

def calc_lot_size(setup: TradeSetup, cfg: StrategyConfig) -> float:
    """Risk-based lot sizing capped at cfg.max_lots. Mirrors CalcLots() in the EA."""
    sym = mt5.symbol_info(setup.symbol)
    if sym is None:
        return 0.01

    acct = mt5.account_info()
    if acct is None:
        return sym.volume_min

    balance    = acct.balance
    risk_amt   = balance * cfg.risk_pct / 100.0
    sl_dist    = abs(setup.entry - setup.stop_loss)

    if sl_dist == 0 or sym.trade_tick_size == 0 or sym.trade_tick_value == 0:
        return sym.volume_min

    val_per_pt = sym.trade_tick_value / sym.trade_tick_size
    lot        = risk_amt / (sl_dist * val_per_pt)

    max_lot = min(sym.volume_max, cfg.max_lots)
    lot     = max(sym.volume_min, min(max_lot, lot))

    if sym.volume_step > 0:
        lot = round(round(lot / sym.volume_step) * sym.volume_step, 8)

    return lot


# ── Order execution ───────────────────────────────────────────────────────────

def send_order(setup: TradeSetup, lots: float, cfg: StrategyConfig) -> bool:
    """Send a market order. Returns True on success."""
    tick = mt5.symbol_info_tick(setup.symbol)
    if tick is None:
        print(f"  ERROR: no tick for {setup.symbol}")
        return False

    if setup.direction == "SHORT":
        order_type = mt5.ORDER_TYPE_SELL
        price      = tick.bid
    else:
        order_type = mt5.ORDER_TYPE_BUY
        price      = tick.ask

    sym  = mt5.symbol_info(setup.symbol)
    fill = mt5.ORDER_FILLING_IOC
    if sym is not None:
        fm   = sym.filling_mode
        fill = (mt5.ORDER_FILLING_FOK if fm & 1 else
                mt5.ORDER_FILLING_IOC if fm & 2 else
                mt5.ORDER_FILLING_RETURN)

    request = {
        "action":       mt5.TRADE_ACTION_DEAL,
        "symbol":       setup.symbol,
        "volume":       lots,
        "type":         order_type,
        "price":        price,
        "sl":           setup.stop_loss,
        "tp":           setup.target,
        "deviation":    cfg.slippage,
        "magic":        cfg.magic,
        "comment":      "AMD_v1.00",
        "type_time":    mt5.ORDER_TIME_GTC,
        "type_filling": fill,
    }

    result = mt5.order_send(request)

    if result is None:
        print(f"  ORDER FAILED: {mt5.last_error()}")
        return False
    if result.retcode != mt5.TRADE_RETCODE_DONE:
        print(f"  ORDER FAILED  retcode={result.retcode}  {result.comment}")
        return False

    record_trade(setup.period_idx)

    sep = "=" * 64
    print(f"\n{sep}")
    print(f"  ORDER EXECUTED  — AMD v1.00")
    print(f"  Ticket    : #{result.order}")
    print(f"  Symbol    : {setup.symbol}  [{setup.timeframe}]")
    print(f"  Direction : {setup.direction}")
    print(f"  Volume    : {lots} lots")
    print(f"  Entry     : {result.price:.5f}")
    print(f"  Stop Loss : {setup.stop_loss:.5f}")
    print(f"  Target    : {setup.target:.5f}")
    print(f"  R:R       : 1:{setup.risk_reward:.2f}")
    print(f"  Phase     : A·M·D  |  Session: {setup.session}")
    print(sep)
    return True


# ── Confirmation + execution gate ─────────────────────────────────────────────

def execute_setup(setup: TradeSetup, cfg: StrategyConfig) -> None:
    """Auto-execute or present manual confirm prompt, then send the order."""
    lots    = calc_lot_size(setup, cfg)
    acct    = mt5.account_info()
    balance = acct.balance  if acct else 0.0
    curr    = acct.currency if acct else ""
    risk_usd = balance * cfg.risk_pct / 100.0

    sep  = "=" * 64
    sep2 = "-" * 64

    print(f"\n{sep}")
    print(f"  ═══ AMD STRATEGY — A·M·D  v1.00 ═══")
    print(sep2)
    for note in setup.setup_notes:
        print(f"  {note}")
    print(sep2)
    print(f"  Lot Size  : {lots:.2f}  "
          f"(risk {cfg.risk_pct}% = {risk_usd:.2f} {curr}, max {cfg.max_lots} lots)")
    print(sep)

    if not cfg.manual_confirm:
        print("  [AUTO] Executing order...")
        send_order(setup, lots, cfg)
        return

    print("  [MANUAL] Confirm trade execution:")
    while True:
        try:
            ans = input("  Execute?  [y = yes / n = skip / q = quit]: ").strip().lower()
        except (EOFError, KeyboardInterrupt):
            print("\n  Cancelled.")
            return

        if ans == "y":
            send_order(setup, lots, cfg)
            break
        elif ans == "n":
            print("  Setup skipped.")
            break
        elif ans == "q":
            print("  Shutting down.")
            raise SystemExit(0)
        else:
            print("  Enter  y  n  or  q")
