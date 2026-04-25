"""
AMD Strategy — Accumulation · Manipulation · Distribution  v1.00
Python implementation mirroring AMD_v1.00.mq5

Setup sequence (both directions):
  Rule 1  — Accumulation: N bars of tight range (height < accum_atr_mult × ATR-14)
  Rule 2  — Manipulation: bar sweeps stops beyond range boundary by >= manip_pips,
             closes back inside or near the range (failed breakout = trap)
  Rule 3  — Displacement: strong impulsive bar leaving a Fair Value Gap (FVG)
             Bearish FVG: bar[i].high < bar[i-2].low
             Bullish FVG: bar[i].low  > bar[i-2].high
  Rule 4  — Distribution entry: current price retraces into the FVG zone
  Rule 5  — SL: above/below manipulation extreme + sl_pips buffer
  Rule 6  — TP: R:R ratio, fixed pips, or at accumulation range opposite extreme
  Rule 7  — Period filter: 48 × 30-min UTC slots; trade only selected periods
  Rule 8  — ICT Session filter: Asian / London / NY
  Rule 9  — Max trades per period per day
  Rule 10 — Day quality: manual high-probability flag (news days)

NOTE on array direction:
  Python/MT5 arrays are chronological: index 0 = oldest, -1 = most recent.
  This is the OPPOSITE of MQL5 AsSeries. All logic below uses chronological order.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Optional

import numpy as np
import pandas as pd
import MetaTrader5 as mt5

from .signals import TradeSetup
from .periods import (
    get_current_period, get_period_label, period_to_session,
    is_allowed_period, can_trade_period,
)


# ── Strategy configuration ────────────────────────────────────────────────────

@dataclass
class StrategyConfig:
    # Execution
    symbol:          str  = "XAUUSD"
    timeframe:       str  = "M5"
    manual_confirm:  bool = True        # True = alert only, never auto until validated

    # Risk
    risk_pct:        float = 1.0
    min_rr:          float = 1.5        # 0 = disabled
    max_lots:        float = 5.0

    # SL / TP specification
    sl_pips:         float = 10.0       # buffer above/below manipulation extreme
    use_pip_tp:      bool  = False      # False = use risk_reward ratio
    tp_pips:         float = 20.0       # TP in pips when use_pip_tp=True
    risk_reward:     float = 2.0        # TP = entry ± risk × this (when not pip TP)
    tp_buffer_pips:  float = 5.0        # extra pip buffer beyond range extreme (fallback TP)

    # AMD detection parameters
    accum_bars:      int   = 20         # accumulation lookback bars
    accum_atr_mult:  float = 1.5        # range height < this × ATR(14)
    manip_pips:      float = 5.0        # minimum sweep beyond range boundary
    manip_lookback:  int   = 10         # bars before FVG to search for manipulation
    fvg_lookback:    int   = 8          # bars to search for FVG
    candle_count:    int   = 60         # total bars to fetch

    # Period filter (Rule 7) — 48 × 30-min UTC slots
    use_period_filter:     bool       = False
    allowed_periods:       list[int]  = field(default_factory=list)  # [] = all
    max_trades_per_period: int        = 2

    # ICT session filter (Rule 8)
    use_session:     bool = True
    gmt_offset:      int  = 0
    asian_start_h:   int  = 23
    asian_end_h:     int  = 9
    london_start_h:  int  = 7
    london_end_h:    int  = 16
    ny_start_h:      int  = 12
    ny_end_h:        int  = 21

    # Day quality (Rule 10)
    high_prob_day:   bool = True        # False = sit out today

    # Trade settings
    magic:    int = 20260501
    slippage: int = 20


# ── Timeframe map ─────────────────────────────────────────────────────────────

_TF_MAP = {
    "M1":  mt5.TIMEFRAME_M1,  "M5":  mt5.TIMEFRAME_M5,
    "M15": mt5.TIMEFRAME_M15, "M30": mt5.TIMEFRAME_M30,
    "H1":  mt5.TIMEFRAME_H1,  "H4":  mt5.TIMEFRAME_H4,
    "D1":  mt5.TIMEFRAME_D1,  "W1":  mt5.TIMEFRAME_W1,
}


# ── Helpers ───────────────────────────────────────────────────────────────────

def _pip_size(symbol: str) -> float:
    info = mt5.symbol_info(symbol)
    if info is None:
        return 0.0001
    return info.point * 10 if info.digits in (3, 5) else info.point


def _atr(highs: np.ndarray, lows: np.ndarray, closes: np.ndarray,
         period: int) -> float:
    """Average True Range over the last `period` completed bars."""
    n = len(highs)
    if n < period + 1:
        return float(highs.max() - lows.min())
    trs = []
    for i in range(n - period, n):
        tr = max(
            highs[i] - lows[i],
            abs(highs[i] - closes[i - 1]),
            abs(lows[i]  - closes[i - 1]),
        )
        trs.append(tr)
    return float(np.mean(trs))


def _fetch(symbol: str, tf_str: str, count: int) -> Optional[pd.DataFrame]:
    """Fetch completed OHLC bars (pos=1 skips the forming bar)."""
    tf = _TF_MAP.get(tf_str.upper())
    if tf is None:
        return None
    rates = mt5.copy_rates_from_pos(symbol, tf, 1, count)
    if rates is None or len(rates) == 0:
        return None
    df = pd.DataFrame(rates)
    df["time"] = pd.to_datetime(df["time"], unit="s")
    df.rename(columns={"open": "o", "high": "h", "low": "l", "close": "c"},
              inplace=True)
    return df


# ── Rule 8: ICT session filter ────────────────────────────────────────────────

def _in_window(h: int, start: int, end: int) -> bool:
    """True if hour h is in [start, end), handling midnight-spanning windows."""
    if start > end:
        return h >= start or h < end
    return start <= h < end


def get_current_session(cfg: StrategyConfig) -> str:
    if not cfg.use_session:
        return "ALL"
    h = (datetime.now(timezone.utc).hour + cfg.gmt_offset) % 24
    parts = []
    if _in_window(h, cfg.asian_start_h,  cfg.asian_end_h):
        parts.append("Asian")
    if _in_window(h, cfg.london_start_h, cfg.london_end_h):
        parts.append("London")
    if _in_window(h, cfg.ny_start_h,     cfg.ny_end_h):
        parts.append("NY")
    return "/".join(parts) if parts else ""


def is_in_trading_session(cfg: StrategyConfig) -> bool:
    if not cfg.use_session:
        return True
    return bool(get_current_session(cfg))


# ── Rule 1–3: AMD structure detection ────────────────────────────────────────
#
# Chronological arrays (index 0 = oldest, -1 = most recent).
#
# SHORT timeline:
#   [...ACCUMULATION (tight range)...] [MANIP: bar sweeps above range_high]
#   [DISPLACEMENT: bearish bar(s) leaving bearish FVG] → price retraces UP into FVG
#
# Bearish FVG: highs[i] < lows[i-2]   →  FVG zone = [highs[i], lows[i-2]]
# Entry when: bid price is inside FVG zone

def _find_short_setup(
    highs: np.ndarray, lows: np.ndarray, closes: np.ndarray,
    cfg: StrategyConfig, pip: float,
) -> Optional[dict]:
    n = len(highs)
    if n < cfg.accum_bars + cfg.fvg_lookback + 4:
        return None

    atr = _atr(highs, lows, closes, 14)
    if atr <= 0:
        return None

    # Step 1: Find most recent bearish FVG
    # Bearish FVG at bar i (chronological): highs[i] < lows[i-2]
    fvg_bar  = -1
    fvg_upper = 0.0   # lows[i-2] — the gap top
    fvg_lower = 0.0   # highs[i]  — the gap bottom

    for back in range(0, cfg.fvg_lookback):
        i = n - 1 - back
        if i < 2:
            break
        if highs[i] < lows[i - 2]:
            fvg_bar   = i
            fvg_upper = float(lows[i - 2])
            fvg_lower = float(highs[i])
            break

    if fvg_bar < 0 or (fvg_upper - fvg_lower) < pip * 2:
        return None

    # Step 2: Find manipulation sweep BEFORE the FVG
    # Scan from fvg_bar-2 backward (the FVG's A bar is at fvg_bar-2)
    # For each candidate manipulation bar m, the accumulation window is [m-accum_bars .. m-1]
    for m in range(fvg_bar - 1, max(cfg.accum_bars, fvg_bar - cfg.manip_lookback - 2) - 1, -1):
        if m < cfg.accum_bars:
            break
        accum_end   = m              # exclusive
        accum_start = m - cfg.accum_bars

        w_highs  = highs[accum_start:accum_end]
        w_lows   = lows[accum_start:accum_end]
        r_high   = float(w_highs.max())
        r_low    = float(w_lows.min())
        r_height = r_high - r_low

        if r_height <= 0 or r_height > cfg.accum_atr_mult * atr:
            continue    # too wide — not tight accumulation

        sweep = highs[m] - r_high
        if sweep < cfg.manip_pips * pip:
            continue    # not enough of a sweep

        # Confirm: close returns inside range (or within 50% of range height above it)
        if closes[m] > r_high + r_height * 0.5:
            continue    # close stayed too high — real breakout, not manipulation

        return dict(
            range_high=r_high, range_low=r_low,
            manip_high=float(highs[m]), manip_idx=m,
            fvg_upper=fvg_upper, fvg_lower=fvg_lower, fvg_bar=fvg_bar,
        )

    return None


def _find_long_setup(
    highs: np.ndarray, lows: np.ndarray, closes: np.ndarray,
    cfg: StrategyConfig, pip: float,
) -> Optional[dict]:
    """
    AMD LONG: sweep of lows (manipulation) → bullish displacement → FVG entry.

    Bullish FVG at bar i: lows[i] > highs[i-2]  →  FVG zone = [highs[i-2], lows[i]]
    Entry when: ask price is inside FVG zone (retracing DOWN into it).
    """
    n = len(highs)
    if n < cfg.accum_bars + cfg.fvg_lookback + 4:
        return None

    atr = _atr(highs, lows, closes, 14)
    if atr <= 0:
        return None

    # Step 1: Find most recent bullish FVG
    fvg_bar  = -1
    fvg_upper = 0.0   # lows[i]    — gap top
    fvg_lower = 0.0   # highs[i-2] — gap bottom

    for back in range(0, cfg.fvg_lookback):
        i = n - 1 - back
        if i < 2:
            break
        if lows[i] > highs[i - 2]:
            fvg_bar   = i
            fvg_upper = float(lows[i])
            fvg_lower = float(highs[i - 2])
            break

    if fvg_bar < 0 or (fvg_upper - fvg_lower) < pip * 2:
        return None

    # Step 2: Find manipulation sweep of lows BEFORE the FVG
    for m in range(fvg_bar - 1, max(cfg.accum_bars, fvg_bar - cfg.manip_lookback - 2) - 1, -1):
        if m < cfg.accum_bars:
            break
        accum_end   = m
        accum_start = m - cfg.accum_bars

        w_highs  = highs[accum_start:accum_end]
        w_lows   = lows[accum_start:accum_end]
        r_high   = float(w_highs.max())
        r_low    = float(w_lows.min())
        r_height = r_high - r_low

        if r_height <= 0 or r_height > cfg.accum_atr_mult * atr:
            continue

        sweep = r_low - lows[m]
        if sweep < cfg.manip_pips * pip:
            continue

        if closes[m] < r_low - r_height * 0.5:
            continue    # close stayed too low — real breakdown, not manipulation

        return dict(
            range_high=r_high, range_low=r_low,
            manip_low=float(lows[m]), manip_idx=m,
            fvg_upper=fvg_upper, fvg_lower=fvg_lower, fvg_bar=fvg_bar,
        )

    return None


# ── Rule 5–6: SL / TP calculation ─────────────────────────────────────────────

def _calc_short_levels(s: dict, cur: float, cfg: StrategyConfig,
                        pip: float) -> Optional[tuple[float, float, float]]:
    """Return (sl, tp, rr) for a SHORT setup, or None if invalid."""
    sl = s["manip_high"] + cfg.sl_pips * pip

    if cfg.use_pip_tp:
        tp = cur - cfg.tp_pips * pip
    elif cfg.risk_reward > 0:
        risk = sl - cur
        if risk <= 0:
            return None
        tp = cur - risk * cfg.risk_reward
    else:
        tp = s["range_low"] - cfg.tp_buffer_pips * pip

    if tp >= cur:
        return None     # TP must be below entry for SHORT

    risk   = sl - cur
    reward = cur - tp
    rr     = round(reward / risk, 2) if risk > 0 else 0.0

    if cfg.min_rr > 0 and rr < cfg.min_rr:
        return None

    return sl, tp, rr


def _calc_long_levels(lg: dict, cur: float, cfg: StrategyConfig,
                       pip: float) -> Optional[tuple[float, float, float]]:
    """Return (sl, tp, rr) for a LONG setup, or None if invalid."""
    sl = lg["manip_low"] - cfg.sl_pips * pip

    if cfg.use_pip_tp:
        tp = cur + cfg.tp_pips * pip
    elif cfg.risk_reward > 0:
        risk = cur - sl
        if risk <= 0:
            return None
        tp = cur + risk * cfg.risk_reward
    else:
        tp = lg["range_high"] + cfg.tp_buffer_pips * pip

    if tp <= cur:
        return None

    risk   = cur - sl
    reward = tp - cur
    rr     = round(reward / risk, 2) if risk > 0 else 0.0

    if cfg.min_rr > 0 and rr < cfg.min_rr:
        return None

    return sl, tp, rr


# ── Core setup finder ─────────────────────────────────────────────────────────

def find_setup(cfg: StrategyConfig) -> Optional[TradeSetup]:
    """
    Fetch bars, apply all pre-checks (Rules 7–10), detect AMD structure,
    confirm FVG entry zone. Returns TradeSetup or None.
    """
    # Rule 10: day quality
    if not cfg.high_prob_day:
        return None

    # Rule 8: ICT session filter
    if not is_in_trading_session(cfg):
        return None

    # Rule 7: period filter
    period_idx = get_current_period()
    if cfg.use_period_filter:
        if not is_allowed_period(period_idx, cfg.allowed_periods):
            return None
        if not can_trade_period(period_idx, cfg.max_trades_per_period):
            return None

    df = _fetch(cfg.symbol, cfg.timeframe, cfg.candle_count)
    if df is None or len(df) < cfg.accum_bars + cfg.fvg_lookback + 4:
        return None

    highs  = df["h"].values.astype(float)
    lows   = df["l"].values.astype(float)
    closes = df["c"].values.astype(float)

    pip     = _pip_size(cfg.symbol)
    session = get_current_session(cfg)

    tick = mt5.symbol_info_tick(cfg.symbol)
    if tick is None:
        return None

    # ── Try SHORT ─────────────────────────────────────────────────────────────
    s = _find_short_setup(highs, lows, closes, cfg, pip)
    if s:
        cur = float(tick.bid)
        # Rule 4: price must be retracing UP into the bearish FVG zone
        if s["fvg_lower"] <= cur <= s["fvg_upper"]:
            levels = _calc_short_levels(s, cur, cfg, pip)
            if levels:
                sl, tp, rr = levels
                return TradeSetup(
                    symbol=cfg.symbol, timeframe=cfg.timeframe,
                    direction="SHORT",
                    entry=cur, stop_loss=sl, target=tp, risk_reward=rr,
                    range_high=s["range_high"], range_low=s["range_low"],
                    manip_extreme=s["manip_high"],
                    fvg_upper=s["fvg_upper"], fvg_lower=s["fvg_lower"],
                    session=session, period_idx=period_idx,
                    setup_notes=_build_notes(
                        "SHORT", cur, sl, tp, rr, s, session, period_idx, cfg, pip),
                )

    # ── Try LONG ──────────────────────────────────────────────────────────────
    lg = _find_long_setup(highs, lows, closes, cfg, pip)
    if lg:
        cur = float(tick.ask)
        # Rule 4: price must be retracing DOWN into the bullish FVG zone
        if lg["fvg_lower"] <= cur <= lg["fvg_upper"]:
            levels = _calc_long_levels(lg, cur, cfg, pip)
            if levels:
                sl, tp, rr = levels
                return TradeSetup(
                    symbol=cfg.symbol, timeframe=cfg.timeframe,
                    direction="LONG",
                    entry=cur, stop_loss=sl, target=tp, risk_reward=rr,
                    range_high=lg["range_high"], range_low=lg["range_low"],
                    manip_extreme=lg["manip_low"],
                    fvg_upper=lg["fvg_upper"], fvg_lower=lg["fvg_lower"],
                    session=session, period_idx=period_idx,
                    setup_notes=_build_notes(
                        "LONG", cur, sl, tp, rr, lg, session, period_idx, cfg, pip),
                )

    return None


# ── Human-readable notes ───────────────────────────────────────────────────────

def _build_notes(
    direction: str, entry: float, sl: float, tp: float, rr: float,
    struct: dict, session: str, period_idx: int,
    cfg: StrategyConfig, pip: float,
) -> list[str]:
    period_label = f"{period_idx:02d} ({get_period_label(period_idx)} UTC)"
    sl_pips_val  = abs(entry - sl) / pip if pip > 0 else 0.0
    tp_pips_val  = abs(entry - tp) / pip if pip > 0 else 0.0
    manip_label  = "Manip High" if direction == "SHORT" else "Manip Low"
    manip_val    = struct.get("manip_high") or struct.get("manip_low", 0.0)

    return [
        f"Phase            : A·M·D — {direction}",
        f"Session          : {session}  |  Period {period_label}",
        f"Accumulation     : {struct['range_low']:.5f} – {struct['range_high']:.5f}",
        f"{manip_label:<17}: {manip_val:.5f}",
        f"FVG Zone         : {struct['fvg_lower']:.5f} – {struct['fvg_upper']:.5f}",
        f"Entry            : {entry:.5f}",
        f"Stop Loss        : {sl:.5f}  ({sl_pips_val:.1f} pips from entry)",
        f"Take Profit      : {tp:.5f}  ({tp_pips_val:.1f} pips from entry)",
        f"Risk : Reward    : 1:{rr:.2f}",
    ]


# ── Dashboard print ────────────────────────────────────────────────────────────

def print_dashboard(setup: Optional[TradeSetup], cfg: StrategyConfig) -> None:
    sep = "─" * 64
    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    print(f"\n{sep}")
    print(f"  AMD Strategy  —  Accumulation · Manipulation · Distribution")
    print(f"  Scan : {now}  |  {cfg.symbol} [{cfg.timeframe}]")
    print(sep)

    if setup is None:
        period_idx = get_current_period()
        session    = get_current_session(cfg)
        print(f"  No setup — monitoring...  "
              f"[{session or 'Off-session'}  P{period_idx}: {get_period_label(period_idx)} UTC]")
        print(sep)
        return

    for note in setup.setup_notes:
        print(f"  {note}")
    print(sep)
