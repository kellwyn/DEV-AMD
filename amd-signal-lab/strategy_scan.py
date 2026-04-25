"""
AMD historical setup scanner.

For each bar in the dataset (as a potential current bar), detects whether an
AMD structure was complete at that point in time and price was within the FVG
entry zone. Mirrors the live-bot detection logic without MT5 tick calls.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Optional

import numpy as np
import pandas as pd

from config import LabConfig
from periods import tag_slot, tag_session, SLOT_LABELS


@dataclass
class DetectedSetup:
    bar_idx:   int           # DataFrame index of entry bar
    time:      pd.Timestamp
    direction: str           # 'SHORT' or 'LONG'
    slot:      int           # 0-47
    session:   str

    # Entry levels
    entry:     float
    stop_loss: float
    target:    float
    risk_reward: float

    # AMD structure
    range_high:    float
    range_low:     float
    manip_extreme: float
    fvg_upper:     float
    fvg_lower:     float

    tags: list[str] = field(default_factory=list)


# ── ATR helper ────────────────────────────────────────────────────────────────

def _atr_at(highs: np.ndarray, lows: np.ndarray, closes: np.ndarray,
             end: int, period: int) -> float:
    start = max(0, end - period)
    if end - start < 2:
        return float(highs[start:end].max() - lows[start:end].min())
    trs = []
    for i in range(start + 1, end):
        tr = max(
            highs[i] - lows[i],
            abs(highs[i] - closes[i - 1]),
            abs(lows[i]  - closes[i - 1]),
        )
        trs.append(tr)
    return float(np.mean(trs)) if trs else 1e-8


def _pip_size_from_price(price: float) -> float:
    """Fallback pip estimate from price magnitude (for signal lab without MT5 symbol)."""
    if price > 100:
        return 0.01
    if price > 1:
        return 0.0001
    return 0.00001


# ── Single-bar AMD detection (chronological arrays, window ending at `end`) ──

def _detect_short(
    highs: np.ndarray, lows: np.ndarray, closes: np.ndarray,
    end: int, cfg: LabConfig, pip: float,
) -> Optional[dict]:
    """
    Check for a SHORT AMD setup using bars [0..end] (end is the current bar).
    Returns dict with structure levels, or None.
    """
    if end < cfg.accum_bars + cfg.fvg_lookback + 4:
        return None

    atr = _atr_at(highs, lows, closes, end, cfg.atr_period)
    if atr <= 0:
        return None

    # Find most recent bearish FVG within fvg_lookback bars before `end`
    fvg_bar = -1
    fvg_upper = fvg_lower = 0.0

    for back in range(0, cfg.fvg_lookback):
        i = end - back
        if i < 2:
            break
        if highs[i] < lows[i - 2]:
            fvg_bar   = i
            fvg_upper = float(lows[i - 2])
            fvg_lower = float(highs[i])
            break

    if fvg_bar < 0 or (fvg_upper - fvg_lower) < pip * 2:
        return None

    # Find manipulation sweep before the FVG
    for m in range(fvg_bar - 1,
                   max(cfg.accum_bars, fvg_bar - cfg.manip_lookback - 2) - 1, -1):
        if m < cfg.accum_bars:
            break
        w_h  = highs[m - cfg.accum_bars : m]
        w_l  = lows[m - cfg.accum_bars  : m]
        r_h  = float(w_h.max())
        r_l  = float(w_l.min())
        r_ht = r_h - r_l

        if r_ht <= 0 or r_ht > cfg.accum_atr_mult * atr:
            continue
        if (highs[m] - r_h) < cfg.manip_pips * pip:
            continue
        if closes[m] > r_h + r_ht * 0.5:
            continue

        return dict(
            range_high=r_h, range_low=r_l,
            manip_high=float(highs[m]), manip_idx=m,
            fvg_upper=fvg_upper, fvg_lower=fvg_lower, fvg_bar=fvg_bar,
        )

    return None


def _detect_long(
    highs: np.ndarray, lows: np.ndarray, closes: np.ndarray,
    end: int, cfg: LabConfig, pip: float,
) -> Optional[dict]:
    if end < cfg.accum_bars + cfg.fvg_lookback + 4:
        return None

    atr = _atr_at(highs, lows, closes, end, cfg.atr_period)
    if atr <= 0:
        return None

    fvg_bar = -1
    fvg_upper = fvg_lower = 0.0

    for back in range(0, cfg.fvg_lookback):
        i = end - back
        if i < 2:
            break
        if lows[i] > highs[i - 2]:
            fvg_bar   = i
            fvg_upper = float(lows[i])
            fvg_lower = float(highs[i - 2])
            break

    if fvg_bar < 0 or (fvg_upper - fvg_lower) < pip * 2:
        return None

    for m in range(fvg_bar - 1,
                   max(cfg.accum_bars, fvg_bar - cfg.manip_lookback - 2) - 1, -1):
        if m < cfg.accum_bars:
            break
        w_h  = highs[m - cfg.accum_bars : m]
        w_l  = lows[m - cfg.accum_bars  : m]
        r_h  = float(w_h.max())
        r_l  = float(w_l.min())
        r_ht = r_h - r_l

        if r_ht <= 0 or r_ht > cfg.accum_atr_mult * atr:
            continue
        if (r_l - lows[m]) < cfg.manip_pips * pip:
            continue
        if closes[m] < r_l - r_ht * 0.5:
            continue

        return dict(
            range_high=r_h, range_low=r_l,
            manip_low=float(lows[m]), manip_idx=m,
            fvg_upper=fvg_upper, fvg_lower=fvg_lower, fvg_bar=fvg_bar,
        )

    return None


def _calc_levels_short(s: dict, entry: float, cfg: LabConfig, pip: float):
    sl = s["manip_high"] + cfg.sl_pips * pip
    risk = sl - entry
    if risk <= 0:
        return None
    tp = entry - risk * cfg.risk_reward
    if tp >= entry:
        return None
    rr = round((entry - tp) / risk, 2)
    return sl, tp, rr


def _calc_levels_long(lg: dict, entry: float, cfg: LabConfig, pip: float):
    sl = lg["manip_low"] - cfg.sl_pips * pip
    risk = entry - sl
    if risk <= 0:
        return None
    tp = entry + risk * cfg.risk_reward
    if tp <= entry:
        return None
    rr = round((tp - entry) / risk, 2)
    return sl, tp, rr


# ── Full dataset scan ─────────────────────────────────────────────────────────

def scan_setups(df: pd.DataFrame, cfg: LabConfig, pip: float) -> list[DetectedSetup]:
    """
    Walk through every bar in df as a potential entry bar.
    Uses the bar's midpoint (o+c)/2 as a proxy for tick price to check FVG entry.
    """
    setups: list[DetectedSetup] = []
    highs  = df["h"].values.astype(float)
    lows   = df["l"].values.astype(float)
    closes = df["c"].values.astype(float)
    opens  = df["o"].values.astype(float)

    # Track seen FVG zones to avoid duplicate signals on same FVG
    seen_fvg_keys: set[tuple] = set()

    for i in range(cfg.accum_bars + cfg.fvg_lookback + 4, len(df)):
        ts      = df["time"].iloc[i]
        slot    = int(df["slot"].iloc[i])
        session = str(df["session"].iloc[i])
        mid     = (opens[i] + closes[i]) / 2.0

        # SHORT
        s = _detect_short(highs, lows, closes, i, cfg, pip)
        if s and s["fvg_lower"] <= mid <= s["fvg_upper"]:
            key = ("S", round(s["fvg_lower"], 5), round(s["fvg_upper"], 5))
            if key not in seen_fvg_keys:
                seen_fvg_keys.add(key)
                entry = mid
                levels = _calc_levels_short(s, entry, cfg, pip)
                if levels:
                    sl, tp, rr = levels
                    setups.append(DetectedSetup(
                        bar_idx=i, time=ts, direction="SHORT",
                        slot=slot, session=session,
                        entry=entry, stop_loss=sl, target=tp, risk_reward=rr,
                        range_high=s["range_high"], range_low=s["range_low"],
                        manip_extreme=s["manip_high"],
                        fvg_upper=s["fvg_upper"], fvg_lower=s["fvg_lower"],
                    ))

        # LONG
        lg = _detect_long(highs, lows, closes, i, cfg, pip)
        if lg and lg["fvg_lower"] <= mid <= lg["fvg_upper"]:
            key = ("L", round(lg["fvg_lower"], 5), round(lg["fvg_upper"], 5))
            if key not in seen_fvg_keys:
                seen_fvg_keys.add(key)
                entry = mid
                levels = _calc_levels_long(lg, entry, cfg, pip)
                if levels:
                    sl, tp, rr = levels
                    setups.append(DetectedSetup(
                        bar_idx=i, time=ts, direction="LONG",
                        slot=slot, session=session,
                        entry=entry, stop_loss=sl, target=tp, risk_reward=rr,
                        range_high=lg["range_high"], range_low=lg["range_low"],
                        manip_extreme=lg["manip_low"],
                        fvg_upper=lg["fvg_upper"], fvg_lower=lg["fvg_lower"],
                    ))

    return setups
