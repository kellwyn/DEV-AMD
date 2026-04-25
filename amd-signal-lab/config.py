"""
AMD Signal Lab — instrument + strategy configuration.
"""
from dataclasses import dataclass

DURATIONS: dict[str, int] = {
    "1W":  7,
    "1M":  30,
    "3M":  90,
    "6M":  180,
    "1Y":  365,
    "2Y":  730,
    "5Y":  1825,
}

DURATION_LABELS = list(DURATIONS.keys())


@dataclass
class LabConfig:
    # ── Instrument ─────────────────────────────────────────────────────────────
    symbol:      str = "XAUUSD"
    analysis_tf: str = "M5"

    # ── RTH filter ─────────────────────────────────────────────────────────────
    use_rth:     bool = False
    rth_start_h: int  = 13      # COMEX gold floor: 13:30–20:00 UTC
    rth_start_m: int  = 30
    rth_end_h:   int  = 20
    rth_end_m:   int  = 0

    # ── AMD detection parameters ───────────────────────────────────────────────
    accum_bars:      int   = 20
    accum_atr_mult:  float = 1.5
    manip_pips:      float = 5.0
    manip_lookback:  int   = 10
    fvg_lookback:    int   = 8
    candle_count:    int   = 60     # bars fetched per detection window

    # ── SL / TP for outcome evaluation ────────────────────────────────────────
    sl_pips:         float = 10.0
    risk_reward:     float = 2.0
    tp_buffer_pips:  float = 5.0

    # ── ICT session hours (UTC) ────────────────────────────────────────────────
    asian_start_h:  int = 23
    asian_end_h:    int = 9
    london_start_h: int = 7
    london_end_h:   int = 16
    ny_start_h:     int = 12
    ny_end_h:       int = 21

    # ── TP outcome lookahead ───────────────────────────────────────────────────
    tp_lookahead_bars: int = 100

    # ── Candle classification ──────────────────────────────────────────────────
    big_move_pct:    float = 1.0
    tight_range_pct: float = 0.15

    # ── Indicator periods ──────────────────────────────────────────────────────
    rsi_period:    int = 14
    atr_period:    int = 14
    vol_ma_period: int = 20
