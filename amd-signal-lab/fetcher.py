"""
MT5 OHLCV fetch for the AMD signal lab.
Returns a DataFrame with UTC timestamps and slot/session/RTH tags.
"""
from __future__ import annotations

from datetime import datetime, timezone, timedelta

import pandas as pd
import MetaTrader5 as mt5

from config import LabConfig, DURATIONS
from periods import tag_slot, tag_session, tag_rth

_TF_MAP = {
    "M1":  mt5.TIMEFRAME_M1,  "M5":  mt5.TIMEFRAME_M5,
    "M15": mt5.TIMEFRAME_M15, "M30": mt5.TIMEFRAME_M30,
    "H1":  mt5.TIMEFRAME_H1,  "H4":  mt5.TIMEFRAME_H4,
    "D1":  mt5.TIMEFRAME_D1,
}


def fetch_ohlcv(cfg: LabConfig, duration_key: str) -> pd.DataFrame:
    """
    Fetch completed OHLC bars for the given duration.
    Returns a DataFrame with columns: time, o, h, l, c, volume, slot, session, is_rth.
    """
    days = DURATIONS[duration_key]
    tf   = _TF_MAP.get(cfg.analysis_tf.upper())
    if tf is None:
        raise ValueError(f"Unknown timeframe: {cfg.analysis_tf}")

    end   = datetime.now(timezone.utc)
    start = end - timedelta(days=days + 2)  # +2 for ATR warmup

    rates = mt5.copy_rates_range(cfg.symbol, tf, start, end)
    if rates is None or len(rates) == 0:
        raise RuntimeError(
            f"No data for {cfg.symbol} {cfg.analysis_tf}: {mt5.last_error()}"
        )

    df = pd.DataFrame(rates)
    df["time"] = pd.to_datetime(df["time"], unit="s", utc=True)
    df.rename(columns={"open": "o", "high": "h", "low": "l", "close": "c",
                        "tick_volume": "volume"}, inplace=True)
    df = df[["time", "o", "h", "l", "c", "volume"]].copy()

    # Tag each bar
    df["slot"]    = df["time"].apply(tag_slot)
    df["session"] = df["time"].apply(lambda t: tag_session(t, cfg))
    df["is_rth"]  = df["time"].apply(lambda t: tag_rth(t, cfg))

    return df.reset_index(drop=True)
