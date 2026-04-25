"""
Market character analysis: 48-slot profiles, big-move detection, volatility.
"""
from __future__ import annotations

import numpy as np
import pandas as pd

from config import LabConfig
from periods import SLOT_LABELS


def compute_market_char(df: pd.DataFrame, cfg: LabConfig) -> pd.DataFrame:
    """
    Per-slot statistics across the full dataset.
    Returns one row per slot (0-47) with: avg_volume, avg_move_pct, avg_atr,
    pct_big, bias_score, hist_vol_ann.
    """
    df = df.copy()
    df["body_pct"]  = ((df["c"] - df["o"]).abs() / df["o"] * 100).clip(lower=0)
    df["range_pct"] = ((df["h"] - df["l"]) / df["o"] * 100).clip(lower=0)
    df["is_big"]    = df["body_pct"] >= cfg.big_move_pct
    df["is_tight"]  = df["range_pct"] < cfg.tight_range_pct
    df["direction"] = np.where(df["c"] >= df["o"], 1.0, -1.0)

    rows = []
    for slot in range(48):
        sub = df[df["slot"] == slot]
        if sub.empty:
            continue
        n           = len(sub)
        avg_vol     = float(sub["volume"].mean())
        avg_move    = float(sub["range_pct"].mean())
        pct_big     = float(sub["is_big"].mean() * 100)
        pct_tight   = float(sub["is_tight"].mean() * 100)
        bias        = float(sub["direction"].mean())  # -1 to +1
        log_ret     = np.log(sub["c"].values / sub["o"].values)
        hist_vol    = float(np.std(log_ret) * np.sqrt(48 * 252) * 100)

        # Directional bias string
        if bias > 0.2:
            bias_str = "Bullish"
        elif bias < -0.2:
            bias_str = "Bearish"
        else:
            bias_str = "Neutral"

        rows.append(dict(
            slot=slot,
            label=SLOT_LABELS[slot],
            n=n,
            avg_volume=round(avg_vol, 0),
            avg_move_pct=round(avg_move, 3),
            pct_big=round(pct_big, 1),
            pct_tight=round(pct_tight, 1),
            bias_score=round(bias, 3),
            bias_str=bias_str,
            hist_vol_ann=round(hist_vol, 1),
        ))

    return pd.DataFrame(rows)


def big_move_profile(df: pd.DataFrame, cfg: LabConfig) -> pd.DataFrame:
    """Frequency of big-move candles per slot, with directional breakdown."""
    df = df.copy()
    df["body_pct"] = ((df["c"] - df["o"]).abs() / df["o"] * 100).clip(lower=0)
    df["is_big"]   = df["body_pct"] >= cfg.big_move_pct
    df["bull_big"] = (df["is_big"]) & (df["c"] >= df["o"])
    df["bear_big"] = (df["is_big"]) & (df["c"] <  df["o"])

    big = df[df["is_big"]].copy()
    if big.empty:
        return pd.DataFrame(columns=["slot", "label", "count", "bull_pct", "bear_pct"])

    rows = []
    for slot in range(48):
        sub = big[big["slot"] == slot]
        if sub.empty:
            continue
        n    = len(sub)
        bull = int(sub["bull_big"].sum())
        bear = int(sub["bear_big"].sum())
        rows.append(dict(
            slot=slot,
            label=SLOT_LABELS[slot],
            count=n,
            bull_pct=round(bull / n * 100, 1),
            bear_pct=round(bear / n * 100, 1),
        ))

    return pd.DataFrame(rows).sort_values("count", ascending=False)
