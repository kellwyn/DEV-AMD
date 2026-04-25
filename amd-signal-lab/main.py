"""
AMD Signal Lab — Historical AMD Setup Analyser

Scans historical M5 data from MT5 across 48 × 30-min trading periods
in a 24-hour day. Detects AMD setups (Accumulation → Manipulation → FVG
→ Distribution) and evaluates TP/SL outcomes, period character, and
session-level win rates.

Usage:
  python main.py                 # XAUUSD, 3M default
  python main.py EURUSD 1Y
  python main.py XAUUSD 6M

Durations: 1W | 1M | 3M | 6M | 1Y | 2Y | 5Y
"""

import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
if hasattr(sys.stderr, "reconfigure"):
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")

import MetaTrader5 as mt5

from config import LabConfig, DURATIONS, DURATION_LABELS
from fetcher import fetch_ohlcv
from strategy_scan import scan_setups, _pip_size_from_price
from tp_analysis import evaluate_outcomes, slot_summary, session_summary, direction_summary
from market_char import compute_market_char, big_move_profile
from report import (
    print_market_overview, print_period_table, print_big_move_profile,
    print_setup_summary, print_insights,
)


# ── MT5 connection ────────────────────────────────────────────────────────────

def connect() -> None:
    if not mt5.initialize():
        raise RuntimeError(f"MT5 init failed: {mt5.last_error()}")
    info = mt5.account_info()
    if info:
        print(f"  Connected : {info.name}  #{info.login}  "
              f"{info.balance:,.2f} {info.currency}")
    else:
        print("  MT5 connected.")


def disconnect() -> None:
    mt5.shutdown()
    print("\n  Disconnected from MT5.")


def _get_pip(symbol: str) -> float:
    info = mt5.symbol_info(symbol)
    if info is None:
        return _pip_size_from_price(1000.0)
    return info.point * 10 if info.digits in (3, 5) else info.point


# ── Data loading + analysis ───────────────────────────────────────────────────

def load(cfg: LabConfig, duration_key: str) -> dict:
    print(f"\n  Loading {cfg.symbol} {cfg.analysis_tf}  [{duration_key}]"
          f"  {'RTH only' if cfg.use_rth else '24hr'} ...")

    df_full = fetch_ohlcv(cfg, duration_key)
    df      = df_full[df_full["is_rth"]].copy().reset_index(drop=True) if cfg.use_rth else df_full

    if df.empty:
        raise RuntimeError("No bars after RTH filter. Disable RTH or use a longer duration.")

    t0 = df["time"].iloc[0].strftime("%Y-%m-%d")
    t1 = df["time"].iloc[-1].strftime("%Y-%m-%d")
    print(f"  {len(df):,} bars  ({t0} → {t1})")

    pip      = _get_pip(cfg.symbol)
    char_df  = compute_market_char(df, cfg)
    big_df   = big_move_profile(df, cfg)
    setups   = scan_setups(df, cfg, pip)
    print(f"  {len(setups)} AMD setups detected")

    outcomes = evaluate_outcomes(setups, df, cfg, pip)
    slot_df  = slot_summary(outcomes)
    sess_df  = session_summary(outcomes)
    dir_df   = direction_summary(outcomes)

    return dict(
        df=df, char_df=char_df, big_df=big_df, pip=pip,
        setups=setups, outcomes=outcomes,
        slot_df=slot_df, sess_df=sess_df, dir_df=dir_df,
    )


# ── Interactive menu ──────────────────────────────────────────────────────────

SORT_OPTIONS = ["avg_volume", "avg_move_pct", "pct_big", "bias_score", "hist_vol_ann"]


def menu(cfg: LabConfig, duration_key: str) -> None:
    bundle = load(cfg, duration_key)

    while True:
        rth_tag = "RTH ON" if cfg.use_rth else "24hr"
        print(f"\n{'═' * 74}")
        print(f"  AMD Signal Lab  |  {cfg.symbol} [{cfg.analysis_tf}]  |"
              f"  {duration_key}  |  {rth_tag}")
        print(f"{'─' * 74}")
        print("  [1]  Market overview")
        print("  [2]  48-period character table")
        print("  [3]  Big-move candle profile by slot")
        print("  [4]  AMD setup scan results + session/direction breakdown")
        print("  [5]  Strategy insights + recommended period filter")
        print("  [6]  Full report  (all of the above)")
        print(f"{'─' * 74}")
        print(f"  [R]  Toggle RTH filter  (currently: {rth_tag})")
        print(f"  [D]  Change duration    (current: {duration_key})")
        print(f"  [S]  Change symbol      (current: {cfg.symbol})")
        print("  [Q]  Quit")

        try:
            ans = input("\n  Select: ").strip().upper()
        except (EOFError, KeyboardInterrupt):
            break

        if ans == "1":
            print_market_overview(bundle["df"], cfg, duration_key)

        elif ans == "2":
            print(f"  Sort by: {' | '.join(SORT_OPTIONS)}")
            s = input("  Sort column (default: avg_volume): ").strip()
            if s not in SORT_OPTIONS:
                s = "avg_volume"
            print_period_table(bundle["char_df"], top_n=48, sort_by=s)

        elif ans == "3":
            print_big_move_profile(bundle["big_df"], cfg)

        elif ans == "4":
            print_setup_summary(
                bundle["outcomes"], bundle["slot_df"],
                bundle["sess_df"],  bundle["dir_df"],
            )

        elif ans == "5":
            print_insights(bundle["outcomes"], bundle["char_df"], cfg, duration_key)

        elif ans == "6":
            print_market_overview(bundle["df"], cfg, duration_key)
            print_period_table(bundle["char_df"], top_n=48)
            print_big_move_profile(bundle["big_df"], cfg)
            print_setup_summary(
                bundle["outcomes"], bundle["slot_df"],
                bundle["sess_df"],  bundle["dir_df"],
            )
            print_insights(bundle["outcomes"], bundle["char_df"], cfg, duration_key)

        elif ans == "R":
            cfg.use_rth = not cfg.use_rth
            bundle = load(cfg, duration_key)

        elif ans == "D":
            print(f"  Available: {' | '.join(DURATION_LABELS)}")
            new_d = input("  Enter duration: ").strip().upper()
            if new_d in DURATIONS:
                duration_key = new_d
                bundle = load(cfg, duration_key)
            else:
                print(f"  Invalid.  Choose from: {' | '.join(DURATION_LABELS)}")

        elif ans == "S":
            new_s = input("  Enter symbol: ").strip().upper()
            if new_s:
                cfg.symbol = new_s
                bundle = load(cfg, duration_key)

        elif ans == "Q":
            break


# ── Entry point ───────────────────────────────────────────────────────────────

def main() -> None:
    symbol   = sys.argv[1].upper() if len(sys.argv) > 1 else "XAUUSD"
    duration = sys.argv[2].upper() if len(sys.argv) > 2 else "3M"

    if duration not in DURATIONS:
        print(f"  Invalid duration '{duration}'.  Choose: {' | '.join(DURATION_LABELS)}")
        sys.exit(1)

    cfg = LabConfig(symbol=symbol)

    print("\n  ══ AMD Signal Lab — A·M·D Strategy Analyser ══")

    try:
        connect()
        menu(cfg, duration)
    finally:
        disconnect()


if __name__ == "__main__":
    main()
