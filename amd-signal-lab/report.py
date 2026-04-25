"""
AMD Signal Lab — console report output.
"""
from __future__ import annotations

import pandas as pd

from config import LabConfig
from periods import SLOT_LABELS
from strategy_scan import DetectedSetup
from tp_analysis import SetupOutcome


SEP  = "═" * 74
SEP2 = "─" * 74


def _pct(n: int, d: int) -> str:
    return f"{n/d*100:.1f}%" if d else "—"


# ── Market overview ───────────────────────────────────────────────────────────

def print_market_overview(df: pd.DataFrame, cfg: LabConfig, duration: str) -> None:
    t0 = df["time"].iloc[0].strftime("%Y-%m-%d")
    t1 = df["time"].iloc[-1].strftime("%Y-%m-%d")
    print(f"\n{SEP}")
    print(f"  AMD Signal Lab  |  {cfg.symbol} [{cfg.analysis_tf}]  |  {duration}")
    print(f"  {len(df):,} bars   {t0} → {t1}")
    print(SEP2)
    avg_range = ((df["h"] - df["l"]) / df["o"] * 100).mean()
    print(f"  Avg bar range : {avg_range:.3f}%")
    print(f"  Sessions      : Asian 23–09h | London 07–16h | NY 12–21h  (UTC)")
    if cfg.use_rth:
        print(f"  RTH filter    : {cfg.rth_start_h:02d}:{cfg.rth_start_m:02d}–"
              f"{cfg.rth_end_h:02d}:{cfg.rth_end_m:02d} UTC  (active)")
    print(SEP)


# ── Period character table ────────────────────────────────────────────────────

def print_period_table(char_df: pd.DataFrame, top_n: int = 48,
                        sort_by: str = "avg_volume") -> None:
    if char_df.empty:
        print("  No period data.")
        return
    df = char_df.sort_values(sort_by, ascending=False).head(top_n)
    print(f"\n{SEP}")
    print(f"  48-Period Character Table  (sorted by {sort_by})")
    print(SEP2)
    print(f"  {'Slot':<8} {'Label':<7} {'N':>5} {'AvgVol':>8} {'Move%':>7} "
          f"{'BigC%':>7} {'Bias':>8} {'HVol%':>7}")
    print(SEP2)
    for _, r in df.iterrows():
        print(f"  P{int(r['slot']):<6} {r['label']:<7} {int(r['n']):>5} "
              f"{int(r['avg_volume']):>8,} {r['avg_move_pct']:>7.3f} "
              f"{r['pct_big']:>7.1f} {r['bias_str']:>8} {r['hist_vol_ann']:>7.1f}")
    print(SEP)


# ── Big-move profile ──────────────────────────────────────────────────────────

def print_big_move_profile(big_df: pd.DataFrame, cfg: LabConfig) -> None:
    if big_df.empty:
        print(f"\n  No big-move candles found (body >= {cfg.big_move_pct}%)")
        return
    print(f"\n{SEP}")
    print(f"  Big-Move Candle Profile  (body >= {cfg.big_move_pct}%)  — top 20 slots")
    print(SEP2)
    print(f"  {'Slot':<8} {'Label':<7} {'Count':>7} {'Bull%':>7} {'Bear%':>7}")
    print(SEP2)
    for _, r in big_df.head(20).iterrows():
        print(f"  P{int(r['slot']):<6} {r['label']:<7} {int(r['count']):>7} "
              f"{r['bull_pct']:>7.1f} {r['bear_pct']:>7.1f}")
    print(SEP)


# ── Setup summary ─────────────────────────────────────────────────────────────

def print_setup_summary(
    outcomes: list[SetupOutcome],
    slot_df: pd.DataFrame,
    sess_df: pd.DataFrame,
    dir_df: pd.DataFrame,
) -> None:
    total = len(outcomes)
    if total == 0:
        print(f"\n  No AMD setups detected.")
        return

    tp_count  = sum(1 for o in outcomes if o.result == "TP")
    sl_count  = sum(1 for o in outcomes if o.result == "SL")
    open_count = total - tp_count - sl_count
    avg_pips  = sum(o.pips_pnl for o in outcomes) / total if total else 0.0
    win_pips  = sum(o.pips_pnl for o in outcomes if o.result == "TP")
    loss_pips = sum(abs(o.pips_pnl) for o in outcomes if o.result == "SL")
    pf        = win_pips / loss_pips if loss_pips > 0 else float("inf")

    print(f"\n{SEP}")
    print(f"  AMD Setup Summary — {total} setups detected")
    print(SEP2)
    print(f"  TP  : {tp_count:>4}  ({_pct(tp_count, total)})   "
          f"Win pips: {win_pips:>+8.1f}")
    print(f"  SL  : {sl_count:>4}  ({_pct(sl_count, total)})   "
          f"Loss pips: {loss_pips:>8.1f}")
    print(f"  OPEN: {open_count:>4}  ({_pct(open_count, total)})")
    print(f"  Avg pips/trade: {avg_pips:>+7.1f}   Profit factor: {pf:.2f}")
    print(SEP2)

    if not dir_df.empty:
        print("  Direction Breakdown:")
        for _, r in dir_df.iterrows():
            print(f"    {r['direction']:<6}  "
                  f"n={int(r['total'])}  win={r['win_rate']}%  avg={r['avg_pips']:+.1f}p")

    if not sess_df.empty:
        print(SEP2)
        print("  Session Breakdown:")
        for _, r in sess_df.iterrows():
            print(f"    {r['session']:<12}  "
                  f"n={int(r['total'])}  win={r['win_rate']}%  avg={r['avg_pips']:+.1f}p")

    if not slot_df.empty:
        print(SEP2)
        top = slot_df.nlargest(10, "win_rate")
        print("  Top 10 Slots by Win Rate:")
        for _, r in top.iterrows():
            label = SLOT_LABELS[int(r["slot"])]
            print(f"    P{int(r['slot']):<3} {label}  "
                  f"n={int(r['total']):>3}  win={r['win_rate']:>5.1f}%  avg={r['avg_pips']:>+6.1f}p")
    print(SEP)


# ── Insights ──────────────────────────────────────────────────────────────────

def print_insights(
    outcomes: list[SetupOutcome],
    char_df: pd.DataFrame,
    cfg: LabConfig,
    duration: str,
) -> None:
    total = len(outcomes)
    if total == 0:
        print(f"\n  No setups — try loosening accum_atr_mult or manip_pips.")
        return

    tp_count = sum(1 for o in outcomes if o.result == "TP")
    win_rate = tp_count / total * 100 if total else 0.0

    print(f"\n{SEP}")
    print(f"  Strategy Insights  —  {cfg.symbol}  {duration}")
    print(SEP2)
    print(f"  Overall win rate : {win_rate:.1f}%  ({tp_count}/{total} TP)")

    if win_rate >= 55:
        print("  Edge assessment  : Positive — AMD structure showing R-edge.")
    elif win_rate >= 45:
        print("  Edge assessment  : Marginal — consider tightening filters.")
    else:
        print("  Edge assessment  : Weak — review accum_atr_mult and manip_pips.")

    # Best session
    sess_wins = {}
    for o in outcomes:
        sess = o.setup.session
        if sess not in sess_wins:
            sess_wins[sess] = {"total": 0, "tp": 0}
        sess_wins[sess]["total"] += 1
        if o.result == "TP":
            sess_wins[sess]["tp"] += 1
    best_sess = max(sess_wins, key=lambda s: sess_wins[s]["tp"] / max(sess_wins[s]["total"], 1))
    bw = sess_wins[best_sess]
    print(f"  Best session     : {best_sess}  "
          f"({bw['tp']}/{bw['total']}  {bw['tp']/bw['total']*100:.0f}%)")

    # Slot concentration
    slot_counts = {}
    for o in outcomes:
        s = o.setup.slot
        slot_counts[s] = slot_counts.get(s, 0) + 1
    if slot_counts:
        top_slot = max(slot_counts, key=slot_counts.get)
        print(f"  Busiest period   : P{top_slot} {SLOT_LABELS[top_slot]} UTC  "
              f"({slot_counts[top_slot]} setups)")

    print(SEP2)
    print("  Recommended allowed_periods (highest-activity UTC slots):")
    top_slots = sorted(slot_counts, key=slot_counts.get, reverse=True)[:10]
    print(f"  {','.join(str(s) for s in sorted(top_slots))}")
    print(SEP)
