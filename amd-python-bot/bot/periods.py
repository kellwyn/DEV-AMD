"""
48 × 30-min UTC period framework — AMD bot.

Tracks trade counts per period per trading day (reset at UTC midnight).
Provides ICT session tagging and multi-select period filtering.
"""
from __future__ import annotations

from datetime import datetime, timezone, date

# Labels: '00:00', '00:30', '01:00', ..., '23:30'
PERIOD_LABELS: list[str] = [
    f"{h:02d}:{m:02d}" for h in range(24) for m in (0, 30)
]

# ICT session windows (UTC start_h, end_h) — midnight-spanning windows use start > end
ICT_SESSIONS: dict[str, tuple[int, int]] = {
    "Asian":  (23, 9),
    "London": (7, 16),
    "NY":     (12, 21),
}


def get_current_period() -> int:
    """Return current UTC period index 0–47."""
    now = datetime.now(timezone.utc)
    return now.hour * 2 + (now.minute // 30)


def get_period_label(idx: int) -> str:
    """Return label like '13:30' for a period index."""
    return PERIOD_LABELS[idx % 48]


def period_to_session(idx: int) -> str:
    """Return ICT session name(s) for a period index, or 'Off'."""
    h = idx // 2
    parts = []
    for name, (start, end) in ICT_SESSIONS.items():
        if start > end:            # midnight-spanning (e.g. Asian 23→9)
            if h >= start or h < end:
                parts.append(name)
        else:
            if start <= h < end:
                parts.append(name)
    return "/".join(parts) if parts else "Off"


def parse_allowed_periods(raw: str) -> list[int]:
    """
    Parse a comma-separated string of period indices into a list.
    Empty string or 'ALL' returns [] (meaning all periods allowed).
    """
    raw = raw.strip().upper()
    if not raw or raw == "ALL":
        return []
    result = []
    for part in raw.split(","):
        part = part.strip()
        if part.isdigit():
            idx = int(part)
            if 0 <= idx < 48:
                result.append(idx)
    return result


def is_allowed_period(idx: int, allowed: list[int]) -> bool:
    """True if idx is in allowed list, or allowed is empty (= all allowed)."""
    if not allowed:
        return True
    return idx in allowed


# ── Per-day trade count tracking ──────────────────────────────────────────────

_period_counts: dict[int, int] = {}
_reset_date: date | None = None


def _reset_if_new_day() -> None:
    global _period_counts, _reset_date
    today = datetime.now(timezone.utc).date()
    if _reset_date != today:
        _period_counts = {}
        _reset_date = today


def record_trade(period_idx: int) -> None:
    """Increment trade count for this period today."""
    _reset_if_new_day()
    _period_counts[period_idx] = _period_counts.get(period_idx, 0) + 1


def trades_in_period(period_idx: int) -> int:
    _reset_if_new_day()
    return _period_counts.get(period_idx, 0)


def can_trade_period(period_idx: int, max_trades: int) -> bool:
    """True if we haven't reached max_trades for this period today."""
    return trades_in_period(period_idx) < max_trades
