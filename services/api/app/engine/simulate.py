"""Deterministic cash-flow simulation.

Rules (RULES_VERSION engine-1):
* Money is integer minor units; percentage maths rounds half-up (see money.apply_bps).
* Balance is tracked per calendar day. Shortfall = a day whose CLOSING balance < 0.
* Within a day the ledger lists inflows first, then outflows (ties by id). Closing balance is
  order-independent. If an outflows-first ordering would dip below zero on a day that closes
  >= 0, that day is reported in `order_sensitive_dates` instead of silently picking an order.
* No overdraft, credit line, deferral, interest or penalty is assumed. Each is modelled only if
  the input states it explicitly; otherwise it is listed in `excluded_or_unknown`.
* Same input -> same output (no randomness, no clock access).
"""
from __future__ import annotations

from datetime import date, timedelta

from .models import (
    CashEvent, Comparison, DayBalance, Direction, EventKind, EventStatus, IncomeDelay,
    IncomeReduction, LedgerEntry, RateChange, ReserveTopUp, SensitivityItem, ShiftEvent,
    Shortfall, SimulationInput, SimulationResult, SpendingCut, UnexpectedExpense,
    UseGracePeriods,
)
from .money import apply_bps, to_major_str
from .schedule import expand_schedule

STANDING_EXCLUSIONS = [
    "Overdraft or credit-line availability is not assumed.",
    "Interest accrual and late fees are modelled only where explicitly provided.",
    "Payment deferrals by lenders are not assumed.",
]


def describe(d, currency: str = "INR") -> str:
    m = lambda v: f"{currency} {to_major_str(v, currency)}"  # noqa: E731
    if isinstance(d, IncomeDelay):
        return f"Income {'(' + d.record_id + ') ' if d.record_id else ''}arrives {d.days} days late"
    if isinstance(d, IncomeReduction):
        return f"Income {'(' + d.record_id + ') ' if d.record_id else ''}reduced by {d.percent_bps / 100:g}%"
    if isinstance(d, UnexpectedExpense):
        return f"Unexpected expense of {m(d.amount_minor)} on {d.on.isoformat()}"
    if isinstance(d, RateChange):
        return f"Variable-rate reset on {d.record_id} effective {d.effective.isoformat()}"
    if isinstance(d, UseGracePeriods):
        return "Obligations paid at the end of their known grace period"
    if isinstance(d, SpendingCut):
        return f"{d.kind.value} reduced by {d.percent_bps / 100:g}%"
    if isinstance(d, ShiftEvent):
        return f"Event {d.event_id} moved by {d.days:+d} days"
    if isinstance(d, ReserveTopUp):
        return f"Cash reserve increased by {m(d.amount_minor)}"
    return str(d)


def _matches(ev: CashEvent, ident: str | None) -> bool:
    return ident is None or ident in (ev.record_id, ev.id, ev.id.split("@")[0])


def simulate(inp: SimulationInput) -> SimulationResult:
    end = inp.start + timedelta(days=inp.horizon_days - 1)
    exclusions = list(STANDING_EXCLUSIONS)
    assumptions: list[str] = []
    confirm: list[str] = []

    if inp.opening_balance_minor is None:
        return SimulationResult(
            complete=False,
            incomplete_reasons=["Opening cash balance is missing; a projection cannot be calculated."],
            currency=inp.currency, opening_balance_minor=None,
            excluded_or_unknown=exclusions,
        )

    opening = inp.opening_balance_minor
    events = expand_schedule(inp.events, inp.start, end + timedelta(days=366))
    # Concrete events already dated inside/outside window are handled by expand_schedule too.

    delays = [d for d in inp.disruptions if isinstance(d, IncomeDelay)]
    cuts = [d for d in inp.disruptions if isinstance(d, IncomeReduction)]
    spend = [d for d in inp.disruptions if isinstance(d, SpendingCut)]
    shifts = [d for d in inp.disruptions if isinstance(d, ShiftEvent)]
    rates = [d for d in inp.disruptions if isinstance(d, RateChange)]
    use_grace = any(isinstance(d, UseGracePeriods) for d in inp.disruptions)

    for d in inp.disruptions:
        if isinstance(d, ReserveTopUp):
            opening += d.amount_minor
        assumptions.append(describe(d, inp.currency))
        if isinstance(d, ShiftEvent):
            confirm.append(f"Moving {d.event_id} requires the payee/provider to agree.")
        if isinstance(d, UseGracePeriods):
            confirm.append("Using a grace period depends on the contract terms and lender confirmation.")
        if isinstance(d, RateChange) and d.new_payment_minor is None:
            exclusions.append(
                f"Rate change on {d.record_id} not applied: the new payment amount is unknown.")

    grace_unknown: set[str] = set()
    work: list[tuple[CashEvent, list[str]]] = []
    for ev in events:
        notes: list[str] = []
        amount, when = ev.amount_minor, ev.date
        assert when is not None
        if ev.kind == EventKind.income:
            for d in delays:
                if _matches(ev, d.record_id):
                    when += timedelta(days=d.days)
                    notes.append(f"delayed {d.days}d")
            for c in cuts:
                if _matches(ev, c.record_id):
                    amount -= apply_bps(amount, c.percent_bps)
                    notes.append(f"reduced {c.percent_bps / 100:g}%")
        else:
            for s in spend:
                if ev.kind == s.kind:
                    amount -= apply_bps(amount, s.percent_bps)
                    notes.append(f"cut {s.percent_bps / 100:g}%")
            for r in rates:
                if r.record_id == ev.record_id and r.new_payment_minor and when >= r.effective:
                    amount = r.new_payment_minor
                    notes.append("rate reset payment")
            if use_grace and ev.kind != EventKind.unexpected_expense:
                if ev.grace_days is None:
                    grace_unknown.add(ev.label)
                elif ev.grace_days:
                    when += timedelta(days=ev.grace_days)
                    notes.append(f"paid in grace (+{ev.grace_days}d)")
        for sh in shifts:
            if _matches(ev, sh.event_id):
                when += timedelta(days=sh.days)
                notes.append(f"moved {sh.days:+d}d")
        if amount <= 0:
            continue
        if inp.start <= when <= end:
            work.append((ev.model_copy(update={"amount_minor": amount, "date": when}), notes))
        elif when > end and ev.kind == EventKind.income and notes:
            exclusions.append(f"{ev.label} falls after the horizon once delayed ({when.isoformat()}).")

    for lbl in sorted(grace_unknown):
        exclusions.append(f"Grace period for '{lbl}' is unknown; paid on the due date.")

    for d in inp.disruptions:
        if isinstance(d, UnexpectedExpense) and inp.start <= d.on <= end:
            work.append((CashEvent(
                id=f"unexpected:{d.on.isoformat()}", label=d.label, kind=EventKind.unexpected_expense,
                amount_minor=d.amount_minor, status=EventStatus.hypothetical, date=d.on, source="scenario",
            ), []))

    # Deterministic order: date, inflow before outflow, id.
    work.sort(key=lambda x: (x[0].date, 0 if x[0].direction == Direction.inflow else 1, x[0].id))

    balance = opening
    ledger: list[LedgerEntry] = []
    by_day: dict[date, list[tuple[CashEvent, int]]] = {}
    inflow_total = outflow_total = 0
    for ev, notes in work:
        delta = ev.amount_minor if ev.direction == Direction.inflow else -ev.amount_minor
        balance += delta
        if delta > 0:
            inflow_total += delta
        else:
            outflow_total -= delta
        ledger.append(LedgerEntry(
            date=ev.date, event_id=ev.id, label=ev.label, kind=ev.kind, status=ev.status,
            delta_minor=delta, balance_after_minor=balance, note=", ".join(notes) or None,
        ))
        by_day.setdefault(ev.date, []).append((ev, delta))

    daily: list[DayBalance] = []
    close = opening
    sensitive: list[date] = []
    d = inp.start
    while d <= end:
        day = by_day.get(d, [])
        outs = sum(-x for _, x in day if x < 0)
        ins = sum(x for _, x in day if x > 0)
        pess = close - outs
        close = close + ins - outs
        if close >= 0 and pess < 0:
            sensitive.append(d)
        daily.append(DayBalance(date=d, closing_minor=close, pessimistic_intraday_min_minor=pess))
        d += timedelta(days=1)

    low_entry = min(daily, key=lambda x: (x.closing_minor, x.date))
    lowest = min(low_entry.closing_minor, opening)
    lowest_date = low_entry.date if low_entry.closing_minor <= opening else inp.start

    neg_days = [x for x in daily if x.closing_minor < 0]
    shortfall = None
    if neg_days:
        at_risk = [e.event_id for e in ledger if e.delta_minor < 0 and e.balance_after_minor < 0]
        shortfall = Shortfall(
            first_date=neg_days[0].date,
            max_deficit_minor=-min(x.closing_minor for x in neg_days),
            days_negative=len(neg_days),
            obligations_at_risk=at_risk,
        )

    return SimulationResult(
        complete=True, currency=inp.currency, opening_balance_minor=opening,
        closing_balance_minor=close, lowest_balance_minor=lowest, lowest_balance_date=lowest_date,
        shortfall=shortfall, order_sensitive_dates=sensitive, daily=daily, ledger=ledger,
        assumptions_applied=assumptions, excluded_or_unknown=exclusions,
        requires_external_confirmation=confirm,
        total_inflow_minor=inflow_total, total_outflow_minor=outflow_total,
    )


def compare(baseline: SimulationInput, alternative: SimulationInput) -> Comparison:
    b, a = simulate(baseline), simulate(alternative)
    bs, as_ = b.shortfall, a.shortfall
    low_delta = (a.lowest_balance_minor - b.lowest_balance_minor) if (
        a.lowest_balance_minor is not None and b.lowest_balance_minor is not None) else None
    shift = (as_.first_date - bs.first_date).days if (bs and as_) else None
    base_set = {describe(d, baseline.currency) for d in baseline.disruptions}
    alt_set = {describe(d, alternative.currency) for d in alternative.disruptions}
    diff = sorted(f"+ {x}" for x in alt_set - base_set) + sorted(f"- {x}" for x in base_set - alt_set)
    if baseline.opening_balance_minor != alternative.opening_balance_minor:
        diff.append("Opening balance differs")
    new_risk = sorted(
        {e.split("@")[0] for e in (as_.obligations_at_risk if as_ else [])}
        - {e.split("@")[0] for e in (bs.obligations_at_risk if bs else [])})
    return Comparison(
        baseline=b, alternative=a, lowest_balance_delta_minor=low_delta,
        shortfall_delta_minor=(as_.max_deficit_minor if as_ else 0) - (bs.max_deficit_minor if bs else 0),
        first_shortfall_shift_days=shift, newly_at_risk=new_risk, differing_assumptions=diff,
    )


def sensitivity(inp: SimulationInput) -> list[SensitivityItem]:
    """Drop each assumption in turn; the bigger the rise in the lowest balance, the stronger the driver."""
    full = simulate(inp)
    out: list[SensitivityItem] = []
    if not full.complete:
        return out
    for i, d in enumerate(inp.disruptions):
        without = simulate(inp.model_copy(update={
            "disruptions": [x for j, x in enumerate(inp.disruptions) if j != i]}))
        impact = without.lowest_balance_minor - full.lowest_balance_minor
        out.append(SensitivityItem(
            assumption=describe(d, inp.currency),
            lowest_balance_without_minor=without.lowest_balance_minor, impact_minor=impact))
    return sorted(out, key=lambda s: (-abs(s.impact_minor or 0), s.assumption))
