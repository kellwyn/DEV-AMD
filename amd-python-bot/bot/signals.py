"""
AMD TradeSetup dataclass — v1.00
Carries all levels needed to display the setup summary and execute the order.
"""

from dataclasses import dataclass, field
from typing import List, Literal


@dataclass
class TradeSetup:
    symbol:    str
    timeframe: str
    direction: Literal["LONG", "SHORT"]

    # ── Order levels ──────────────────────────────────────────────────────────
    entry:       float
    stop_loss:   float
    target:      float
    risk_reward: float          # e.g. 2.0 means 1:2.0

    # ── AMD structure levels ──────────────────────────────────────────────────
    range_high:    float        # accumulation range high
    range_low:     float        # accumulation range low
    manip_extreme: float        # manipulation sweep extreme (HIGH for SHORT, LOW for LONG)
    fvg_upper:     float        # FVG zone upper bound
    fvg_lower:     float        # FVG zone lower bound

    # ── Context ───────────────────────────────────────────────────────────────
    session:    str             # active ICT session name(s)
    period_idx: int             # 0-47 (current 30-min UTC slot)

    # ── Human-readable notes ──────────────────────────────────────────────────
    setup_notes: List[str] = field(default_factory=list)
