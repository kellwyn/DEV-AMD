"""
AMD TP/SL outcome evaluation.
For each detected setup, scan forward to find whether TP or SL was hit first.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Optional

import pandas as pd
import numpy as np

from config import LabConfig
from strategy_scan import DetectedSetup


@dataclass
class SetupOutcome:
    setup:       DetectedSetup
    result:      str            # 'TP', 'SL', 'OPEN'
    pips_pnl:    float          # + = win, - = loss
    bars_held:   int
    exit_time:   Optional[pd.Timestamp] = None
    exit_price:  float = 0.0


def evaluate_outcomes(
    setups: list[DetectedSetup],
    df: pd.DataFrame,
    cfg: LabConfig,
    pip: float,
) -> list[SetupOutcome]:
    highs  = df["h"].values.astype(float)
    lows   = df["l"].values.astype(float)
    outcomes = []

    for setup in setups:
        start = setup.bar_idx + 1
        end   = min(start + cfg.tp_lookahead_bars, len(df))
        result    = "OPEN"
        exit_px   = 0.0
        exit_time = None
        bars_held = 0

        for j in range(start, end):
            bars_held = j - setup.bar_idx
            if setup.direction == "SHORT":
                if lows[j]  <= setup.target:
                    result = "TP"; exit_px = setup.target; exit_time = df["time"].iloc[j]; break
                if highs[j] >= setup.stop_loss:
                    result = "SL"; exit_px = setup.stop_loss; exit_time = df["time"].iloc[j]; break
            else:
                if highs[j] >= setup.target:
                    result = "TP"; exit_px = setup.target; exit_time = df["time"].iloc[j]; break
                if lows[j]  <= setup.stop_loss:
                    result = "SL"; exit_px = setup.stop_loss; exit_time = df["time"].iloc[j]; break

        if result == "OPEN":
            exit_px   = float(df["c"].iloc[min(end - 1, len(df) - 1)])
            exit_time = df["time"].iloc[min(end - 1, len(df) - 1)]

        if pip > 0:
            if setup.direction == "SHORT":
                pips_pnl = (setup.entry - exit_px) / pip
            else:
                pips_pnl = (exit_px - setup.entry) / pip
        else:
            pips_pnl = 0.0

        outcomes.append(SetupOutcome(
            setup=setup, result=result,
            pips_pnl=round(pips_pnl, 1), bars_held=bars_held,
            exit_time=exit_time, exit_price=exit_px,
        ))

    return outcomes


# ── Aggregations ──────────────────────────────────────────────────────────────

def slot_summary(outcomes: list[SetupOutcome]) -> pd.DataFrame:
    """Win rate and avg pips per 30-min slot."""
    rows = []
    for o in outcomes:
        rows.append({"slot": o.setup.slot, "result": o.result, "pips": o.pips_pnl})
    if not rows:
        return pd.DataFrame(columns=["slot", "total", "tp", "win_rate", "avg_pips"])
    df = pd.DataFrame(rows)
    agg = (df.groupby("slot")
             .agg(total=("result", "count"),
                  tp=("result", lambda x: (x == "TP").sum()),
                  avg_pips=("pips", "mean"))
             .reset_index())
    agg["win_rate"] = (agg["tp"] / agg["total"] * 100).round(1)
    agg["avg_pips"] = agg["avg_pips"].round(1)
    return agg.sort_values("slot")


def session_summary(outcomes: list[SetupOutcome]) -> pd.DataFrame:
    rows = [{"session": o.setup.session, "result": o.result, "pips": o.pips_pnl}
            for o in outcomes]
    if not rows:
        return pd.DataFrame(columns=["session", "total", "tp", "win_rate", "avg_pips"])
    df = pd.DataFrame(rows)
    agg = (df.groupby("session")
             .agg(total=("result", "count"),
                  tp=("result", lambda x: (x == "TP").sum()),
                  avg_pips=("pips", "mean"))
             .reset_index())
    agg["win_rate"] = (agg["tp"] / agg["total"] * 100).round(1)
    agg["avg_pips"] = agg["avg_pips"].round(1)
    return agg.sort_values("win_rate", ascending=False)


def direction_summary(outcomes: list[SetupOutcome]) -> pd.DataFrame:
    rows = [{"direction": o.setup.direction, "result": o.result, "pips": o.pips_pnl}
            for o in outcomes]
    if not rows:
        return pd.DataFrame()
    df = pd.DataFrame(rows)
    agg = (df.groupby("direction")
             .agg(total=("result", "count"),
                  tp=("result", lambda x: (x == "TP").sum()),
                  avg_pips=("pips", "mean"))
             .reset_index())
    agg["win_rate"] = (agg["tp"] / agg["total"] * 100).round(1)
    agg["avg_pips"] = agg["avg_pips"].round(1)
    return agg
