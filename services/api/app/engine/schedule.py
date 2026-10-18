from __future__ import annotations

import calendar
from datetime import date, timedelta

from .models import CashEvent, Frequency


def _add_months(anchor_day: int, anchor: date, months: int) -> date:
    """Add months keeping the original day-of-month, clamped to month end."""
    y, m0 = divmod(anchor.year * 12 + (anchor.month - 1) + months, 12)
    m = m0 + 1
    return date(y, m, min(anchor_day, calendar.monthrange(y, m)[1]))


def occurrences(ev: CashEvent, win_start: date, win_end: date) -> list[date]:
    s = ev.schedule
    if s is None:
        return [ev.date] if ev.date and win_start <= ev.date <= win_end else []
    last = min(s.end, win_end) if s.end else win_end
    out: list[date] = []
    if s.frequency == Frequency.once:
        return [s.start] if win_start <= s.start <= last else []
    if s.frequency in (Frequency.weekly, Frequency.fortnightly, Frequency.custom_days):
        step = {Frequency.weekly: 7, Frequency.fortnightly: 14}.get(s.frequency) or s.interval_days
        d = s.start
        while d <= last:
            if d >= win_start:
                out.append(d)
            d += timedelta(days=step)
        return out
    i = 0  # monthly, anchored on start.day (31st clamps to month end; Feb 29 handled)
    while True:
        d = _add_months(s.start.day, s.start, i)
        if d > last:
            break
        if d >= win_start:
            out.append(d)
        i += 1
    return out


def expand_schedule(events: list[CashEvent], win_start: date, win_end: date) -> list[CashEvent]:
    """Expand recurring definitions into concrete dated occurrences (id suffixed '@date')."""
    out: list[CashEvent] = []
    for ev in events:
        for d in occurrences(ev, win_start, win_end):
            eid = f"{ev.id}@{d.isoformat()}" if ev.schedule is not None else ev.id
            out.append(ev.model_copy(update={"id": eid, "date": d, "schedule": None}))
    return out
