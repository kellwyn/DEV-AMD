"""
AMD Strategy Bot  v1.00  — Accumulation · Manipulation · Distribution

Monitors MT5 for AMD setups: accumulation range → manipulation sweep →
displacement FVG → retrace entry. Auto-executes or prompts for confirmation.

Usage:
  python main.py                          # uses .env defaults
  python main.py --profile metaquotes    # named broker profile
  python main.py --profile blackbull
  python main.py --symbol XAUUSDp        # one-off symbol override

High-probability days (CPI, NFP, FOMC, GDP, PPI):
  Set HIGH_PROB_DAY=true in .env (default true).
  Set HIGH_PROB_DAY=false to sit out low-quality days.

Period filter — to trade only NY open slots (13:00–15:30 UTC):
  Set USE_PERIOD_FILTER=true and ALLOWED_PERIODS=26,27,28,29,30 in .env.
"""

import argparse
import os
import sys
import time
from dotenv import load_dotenv

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

from bot.connection import connect, disconnect
from bot.strategy   import StrategyConfig, find_setup, print_dashboard
from bot.trader     import execute_setup
from bot.periods    import parse_allowed_periods

load_dotenv()

# ── CLI arguments ─────────────────────────────────────────────────────────────

_parser = argparse.ArgumentParser(description="AMD Strategy Bot v1.00")
_parser.add_argument("--profile", metavar="NAME",
                     help="Broker profile (e.g. metaquotes, blackbull)")
_parser.add_argument("--symbol",  metavar="SYM",
                     help="Symbol override")
_args = _parser.parse_args()

# ── Profile resolution ────────────────────────────────────────────────────────

_profile = "default"
if _args.profile:
    key = _args.profile.upper().replace("-", "_")
    _profile = _args.profile.lower()
    for env_key in ("SYMBOL", "MT5_PATH", "MT5_LOGIN", "MT5_SERVER"):
        profile_key = f"PROFILE_{key}_{env_key.replace('MT5_', '')}"
        if env_key == "MT5_PATH":
            profile_key = f"PROFILE_{key}_MT5_PATH"
        elif env_key == "MT5_LOGIN":
            profile_key = f"PROFILE_{key}_MT5_LOGIN"
        elif env_key == "MT5_SERVER":
            profile_key = f"PROFILE_{key}_MT5_SERVER"
        val = os.getenv(profile_key)
        if val:
            os.environ[env_key] = val
    sym = os.getenv(f"PROFILE_{key}_SYMBOL")
    if sym is None:
        print(f"  ERROR: profile '{_args.profile}' not found "
              f"(expected PROFILE_{key}_SYMBOL in .env)")
        sys.exit(1)
    if sym:
        os.environ["SYMBOL"] = sym

if _args.symbol:
    os.environ["SYMBOL"] = _args.symbol

# ── Config helpers ────────────────────────────────────────────────────────────

def _bool(k: str, d: bool)   -> bool:  v = os.getenv(k); return d if v is None else v.strip().lower() in ("true","1","yes")
def _int(k: str, d: int)     -> int:   return int(os.getenv(k, d))
def _float(k: str, d: float) -> float: return float(os.getenv(k, d))
def _str(k: str, d: str)     -> str:   return os.getenv(k, d)

# ── Build config from environment ─────────────────────────────────────────────

cfg = StrategyConfig(
    symbol         = _str("SYMBOL",           "XAUUSD"),
    timeframe      = _str("TIMEFRAME",         "M5"),
    manual_confirm = _bool("MANUAL_CONFIRM",   True),

    risk_pct       = _float("RISK_PERCENT",    1.0),
    min_rr         = _float("MIN_RR",          1.5),
    max_lots       = _float("MAX_LOTS",        5.0),

    sl_pips        = _float("SL_PIPS",         10.0),
    use_pip_tp     = _bool("USE_PIP_TP",       False),
    tp_pips        = _float("TP_PIPS",         20.0),
    risk_reward    = _float("RISK_REWARD",     2.0),
    tp_buffer_pips = _float("TP_BUFFER_PIPS",  5.0),

    accum_bars     = _int("ACCUM_BARS",        20),
    accum_atr_mult = _float("ACCUM_ATR_MULT",  1.5),
    manip_pips     = _float("MANIP_PIPS",      5.0),
    manip_lookback = _int("MANIP_LOOKBACK",    10),
    fvg_lookback   = _int("FVG_LOOKBACK",      8),
    candle_count   = _int("CANDLE_COUNT",      60),

    use_period_filter     = _bool("USE_PERIOD_FILTER",     False),
    allowed_periods       = parse_allowed_periods(_str("ALLOWED_PERIODS", "")),
    max_trades_per_period = _int("MAX_TRADES_PER_PERIOD",  2),

    use_session    = _bool("USE_SESSION",      True),
    gmt_offset     = _int("GMT_OFFSET",        0),
    asian_start_h  = _int("ASIAN_START_H",     23),
    asian_end_h    = _int("ASIAN_END_H",       9),
    london_start_h = _int("LONDON_START_H",    7),
    london_end_h   = _int("LONDON_END_H",      16),
    ny_start_h     = _int("NY_START_H",        12),
    ny_end_h       = _int("NY_END_H",          21),

    high_prob_day  = _bool("HIGH_PROB_DAY",    True),

    magic    = _int("MAGIC_NUMBER", 20260501),
    slippage = _int("SLIPPAGE",     20),
)

SCAN_INTERVAL = _int("SCAN_INTERVAL", 30)

_alerted: set = set()


def _alert_key(setup) -> str:
    return f"{setup.symbol}|{setup.direction}|{setup.fvg_lower:.5f}|{setup.fvg_upper:.5f}"


# ── Main scan loop ─────────────────────────────────────────────────────────────

def run() -> None:
    mode = "AUTO-EXECUTE" if not cfg.manual_confirm else "MANUAL CONFIRM"
    print(f"\n  AMD Strategy Bot  —  A·M·D  v1.00")
    print(f"  Symbol    : {cfg.symbol} [{cfg.timeframe}]")
    print(f"  Mode      : {mode}")
    print(f"  Risk      : {cfg.risk_pct}%  |  R:R >= 1:{cfg.min_rr}  |  Max lots: {cfg.max_lots}")
    print(f"  SL        : {cfg.sl_pips} pips  |  "
          f"TP: {'pip-based ' + str(cfg.tp_pips) + 'p' if cfg.use_pip_tp else f'R:R {cfg.risk_reward}x'}")
    if cfg.use_period_filter and cfg.allowed_periods:
        print(f"  Periods   : {cfg.allowed_periods}  (max {cfg.max_trades_per_period}/period/day)")
    print(f"  Interval  : every {SCAN_INTERVAL}s  |  Ctrl+C to stop\n")

    while True:
        try:
            setup = find_setup(cfg)
            print_dashboard(setup, cfg)

            if setup:
                key = _alert_key(setup)
                if key not in _alerted:
                    _alerted.add(key)
                    execute_setup(setup, cfg)
            else:
                _alerted.clear()

            time.sleep(SCAN_INTERVAL)

        except KeyboardInterrupt:
            print("\n  Stopped by user.")
            break
        except SystemExit:
            break
        except Exception as exc:
            print(f"  ERROR: {exc}")
            time.sleep(SCAN_INTERVAL)


def main() -> None:
    try:
        connect(_profile)
        run()
    finally:
        disconnect()


if __name__ == "__main__":
    main()
