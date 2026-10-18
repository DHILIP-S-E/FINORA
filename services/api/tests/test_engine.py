from datetime import date
from decimal import Decimal

import pytest

from app.engine import (
    CashEvent, EventKind, Frequency, IncomeDelay, IncomeReduction, RateChange, ReserveTopUp,
    Schedule, ShiftEvent, SimulationInput, SpendingCut, UnexpectedExpense, UseGracePeriods,
    compare, expand_schedule, sensitivity, simulate,
)
from app.engine.money import apply_bps, to_major_str, to_minor

D = date


def once(id, kind, amt, when, **kw):
    return CashEvent(id=id, label=kw.pop("label", id), kind=kind, amount_minor=amt, date=when, **kw)


def inp(events, opening=100_00, disruptions=(), start=D(2026, 1, 1), horizon=30):
    return SimulationInput(opening_balance_minor=opening, start=start, horizon_days=horizon,
                           events=list(events), disruptions=list(disruptions))


def test_income_on_time_no_shortfall():
    r = simulate(inp([once("pay", EventKind.income, 500_00, D(2026, 1, 5)),
                      once("rent", EventKind.essential_expense, 400_00, D(2026, 1, 10))]))
    assert r.complete and r.shortfall is None
    assert r.closing_balance_minor == 200_00
    assert r.lowest_balance_minor == 100_00


def test_income_late_creates_shortfall_with_affected_obligation():
    ev = [once("pay", EventKind.income, 500_00, D(2026, 1, 5), record_id="client"),
          once("rent", EventKind.essential_expense, 400_00, D(2026, 1, 10))]
    r = simulate(inp(ev, disruptions=[IncomeDelay(record_id="client", days=10)]))
    s = r.shortfall
    assert s and s.first_date == D(2026, 1, 10)
    assert s.max_deficit_minor == 300_00
    assert s.days_negative == 5          # Jan 10..14, income lands Jan 15
    assert s.obligations_at_risk == ["rent"]
    assert r.closing_balance_minor == 200_00


def test_multiple_obligations_same_date_closing_is_order_independent():
    ev = [once("a", EventKind.loan_repayment, 60_00, D(2026, 1, 3)),
          once("b", EventKind.credit_card, 30_00, D(2026, 1, 3)),
          once("c", EventKind.insurance, 20_00, D(2026, 1, 3))]
    r = simulate(inp(ev))
    assert r.shortfall and r.shortfall.first_date == D(2026, 1, 3)
    assert r.shortfall.max_deficit_minor == 10_00
    assert [e.event_id for e in r.ledger] == ["a", "b", "c"]  # deterministic tie-break


def test_same_day_order_sensitivity_is_reported_not_hidden():
    ev = [once("bill", EventKind.essential_expense, 150_00, D(2026, 1, 3)),
          once("pay", EventKind.income, 100_00, D(2026, 1, 3))]
    r = simulate(inp(ev))
    assert r.shortfall is None                      # closes at 50.00
    assert r.order_sensitive_dates == [D(2026, 1, 3)]  # outflow-first would dip to -50.00


def test_unexpected_expense():
    r = simulate(inp([], disruptions=[UnexpectedExpense(on=D(2026, 1, 4), amount_minor=250_00)]))
    assert r.shortfall.max_deficit_minor == 150_00
    assert r.ledger[0].status.value == "hypothetical"


def test_negative_opening_balance():
    r = simulate(inp([], opening=-50_00))
    assert r.shortfall and r.shortfall.first_date == D(2026, 1, 1) and r.shortfall.days_negative == 30


def test_missing_opening_balance_is_incomplete_not_zero():
    r = simulate(inp([once("x", EventKind.income, 10_00, D(2026, 1, 2))], opening=None))
    assert not r.complete and r.closing_balance_minor is None and r.incomplete_reasons


def test_recurring_monthly_month_end_and_leap_year():
    e = CashEvent(id="emi", label="EMI", kind=EventKind.loan_repayment, amount_minor=1_00,
                  schedule=Schedule(frequency=Frequency.monthly, start=D(2024, 1, 31)))
    days = [x.date for x in expand_schedule([e], D(2024, 1, 1), D(2024, 5, 31))]
    assert days == [D(2024, 1, 31), D(2024, 2, 29), D(2024, 3, 31), D(2024, 4, 30), D(2024, 5, 31)]
    days = [x.date for x in expand_schedule([e], D(2025, 1, 1), D(2025, 3, 31))]
    assert days == [D(2025, 1, 31), D(2025, 2, 28), D(2025, 3, 31)]


def test_weekly_fortnightly_custom_recurrence():
    def mk(f, **k):
        return CashEvent(id="x", label="x", kind=EventKind.income, amount_minor=1,
                         schedule=Schedule(frequency=f, start=D(2026, 1, 1), **k))
    assert len(expand_schedule([mk(Frequency.weekly)], D(2026, 1, 1), D(2026, 1, 31))) == 5
    assert len(expand_schedule([mk(Frequency.fortnightly)], D(2026, 1, 1), D(2026, 1, 31))) == 3
    assert len(expand_schedule([mk(Frequency.custom_days, interval_days=10)], D(2026, 1, 1), D(2026, 1, 31))) == 4


def test_currency_rounding_half_up():
    assert to_minor("10.005") == 1001
    assert to_minor("0.004") == 0
    assert to_minor("1.5", "JPY") == 2
    assert apply_bps(333, 1000) == 33        # 33.3 -> 33
    assert apply_bps(335, 1000) == 34        # 33.5 -> 34 (half up)
    assert to_major_str(-1234) == "-12.34" and to_major_str(5) == "0.05"
    with pytest.raises(TypeError):
        to_minor(1.1)


def test_income_reduction_rounding():
    ev = [once("pay", EventKind.income, 1001, D(2026, 1, 2))]
    r = simulate(inp(ev, opening=0, disruptions=[IncomeReduction(percent_bps=2500)]))
    assert r.closing_balance_minor == 751  # 1001 - round(250.25)=250


def test_variable_rate_applied_only_when_new_payment_known():
    emi = CashEvent(id="loan", label="Loan", kind=EventKind.loan_repayment, amount_minor=100_00,
                    record_id="loan", schedule=Schedule(frequency=Frequency.monthly, start=D(2026, 1, 5)))
    known = simulate(inp([emi], opening=1000_00, horizon=60,
                         disruptions=[RateChange(record_id="loan", effective=D(2026, 2, 1), new_payment_minor=140_00)]))
    assert known.total_outflow_minor == 100_00 + 140_00
    unknown = simulate(inp([emi], opening=1000_00, horizon=60,
                           disruptions=[RateChange(record_id="loan", effective=D(2026, 2, 1))]))
    assert unknown.total_outflow_minor == 200_00
    assert any("new payment amount is unknown" in x for x in unknown.excluded_or_unknown)


def test_grace_period_only_when_known():
    ev = [once("a", EventKind.credit_card, 50_00, D(2026, 1, 5), grace_days=5, label="Card"),
          once("b", EventKind.loan_repayment, 50_00, D(2026, 1, 5), label="Loan")]
    r = simulate(inp(ev, disruptions=[UseGracePeriods()]))
    dates = {e.event_id: e.date for e in r.ledger}
    assert dates["a"] == D(2026, 1, 10) and dates["b"] == D(2026, 1, 5)
    assert any("'Loan' is unknown" in x for x in r.excluded_or_unknown)
    assert r.requires_external_confirmation


def test_multiple_simultaneous_disruptions_compound():
    ev = [once("pay", EventKind.income, 300_00, D(2026, 1, 5), record_id="client"),
          once("emi", EventKind.loan_repayment, 200_00, D(2026, 1, 8)),
          once("card", EventKind.credit_card, 150_00, D(2026, 1, 12))]
    delay = IncomeDelay(record_id="client", days=10)
    exp = UnexpectedExpense(on=D(2026, 1, 9), amount_minor=80_00)
    solo_d = simulate(inp(ev, disruptions=[delay])).shortfall.max_deficit_minor
    solo_e = simulate(inp(ev, disruptions=[exp])).shortfall
    both = simulate(inp(ev, disruptions=[delay, exp])).shortfall.max_deficit_minor
    assert both > solo_d and (solo_e is None or both > solo_e.max_deficit_minor)


def test_compare_and_sensitivity():
    ev = [once("pay", EventKind.income, 500_00, D(2026, 1, 5), record_id="client"),
          once("rent", EventKind.essential_expense, 400_00, D(2026, 1, 10))]
    base = inp(ev)
    alt = inp(ev, disruptions=[IncomeDelay(record_id="client", days=10), UnexpectedExpense(on=D(2026, 1, 11), amount_minor=10_00)])
    c = compare(base, alt)
    assert c.baseline.shortfall is None and c.alternative.shortfall
    assert c.shortfall_delta_minor == c.alternative.shortfall.max_deficit_minor
    assert any(x.startswith("+ Income") for x in c.differing_assumptions)
    s = sensitivity(alt)
    assert s[0].assumption.startswith("Income") and s[0].impact_minor > s[1].impact_minor


def test_intervention_effects():
    ev = [once("pay", EventKind.income, 500_00, D(2026, 1, 5), record_id="client"),
          once("rent", EventKind.essential_expense, 400_00, D(2026, 1, 10)),
          once("ott", EventKind.discretionary_expense, 100_00, D(2026, 1, 11))]
    late = IncomeDelay(record_id="client", days=10)
    base = simulate(inp(ev, disruptions=[late]))
    topped = simulate(inp(ev, disruptions=[late, ReserveTopUp(amount_minor=400_00)]))
    cut = simulate(inp(ev, disruptions=[late, SpendingCut(percent_bps=10000)]))
    shifted = simulate(inp(ev, disruptions=[late, ShiftEvent(event_id="rent", days=6)]))
    assert topped.shortfall is None
    assert cut.shortfall.max_deficit_minor < base.shortfall.max_deficit_minor
    assert shifted.shortfall is None and shifted.requires_external_confirmation


def test_determinism():
    ev = [once("pay", EventKind.income, 500_00, D(2026, 1, 5)), once("r", EventKind.essential_expense, 1_00, D(2026, 1, 6))]
    assert simulate(inp(ev)).model_dump() == simulate(inp(ev)).model_dump()


def test_events_outside_horizon_ignored_and_delay_beyond_horizon_noted():
    ev = [once("pay", EventKind.income, 500_00, D(2026, 1, 28), record_id="c")]
    r = simulate(inp(ev, disruptions=[IncomeDelay(days=10)]))
    assert r.closing_balance_minor == 100_00
    assert any("after the horizon" in x for x in r.excluded_or_unknown)
