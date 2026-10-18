from __future__ import annotations

import datetime as _dt
from enum import Enum
from typing import Annotated, Literal, Optional, Union

from pydantic import BaseModel, Field, model_validator

Date = _dt.date


class Direction(str, Enum):
    inflow = "inflow"
    outflow = "outflow"


class EventKind(str, Enum):
    income = "income"
    essential_expense = "essential_expense"
    discretionary_expense = "discretionary_expense"
    loan_repayment = "loan_repayment"
    credit_card = "credit_card"
    insurance = "insurance"
    other_commitment = "other_commitment"
    unexpected_expense = "unexpected_expense"


class EventStatus(str, Enum):
    actual = "actual"              # observed / completed
    scheduled = "scheduled"        # contractual or confirmed
    estimated = "estimated"        # user estimate
    hypothetical = "hypothetical"  # scenario-introduced


class Frequency(str, Enum):
    once = "once"
    weekly = "weekly"
    fortnightly = "fortnightly"
    monthly = "monthly"
    custom_days = "custom_days"


class Schedule(BaseModel):
    frequency: Frequency = Frequency.once
    start: Date
    end: Optional[Date] = None
    interval_days: Optional[int] = Field(default=None, ge=1)  # custom_days only

    @model_validator(mode="after")
    def _check(self):
        if self.frequency == Frequency.custom_days and not self.interval_days:
            raise ValueError("interval_days required for custom_days")
        if self.end and self.end < self.start:
            raise ValueError("end before start")
        return self


class CashEvent(BaseModel):
    id: str
    label: str
    kind: EventKind
    amount_minor: int = Field(gt=0)  # magnitude; direction derives from kind
    status: EventStatus = EventStatus.scheduled
    record_id: Optional[str] = None
    schedule: Optional[Schedule] = None  # recurring definition (expanded by expand_schedule)
    date: Optional[Date] = None          # concrete occurrence date
    grace_days: Optional[int] = Field(default=None, ge=0)  # None = unknown
    source: str = "user"

    @property
    def direction(self) -> Direction:
        return Direction.inflow if self.kind == EventKind.income else Direction.outflow


# ---- Disruptions (scenario assumptions). Each is explicit and auditable. ----
class IncomeDelay(BaseModel):
    type: Literal["income_delay"] = "income_delay"
    record_id: Optional[str] = None  # None = all income
    days: int = Field(ge=1, le=365)


class IncomeReduction(BaseModel):
    type: Literal["income_reduction"] = "income_reduction"
    record_id: Optional[str] = None
    percent_bps: int = Field(ge=1, le=10000)  # 2500 = 25%


class UnexpectedExpense(BaseModel):
    type: Literal["unexpected_expense"] = "unexpected_expense"
    on: Date
    amount_minor: int = Field(gt=0)
    label: str = "Unexpected expense"


class RateChange(BaseModel):
    """Variable-rate reset. Applied only when the new payment is explicitly known."""
    type: Literal["rate_change"] = "rate_change"
    record_id: str
    effective: Date
    new_payment_minor: Optional[int] = Field(default=None, gt=0)


class UseGracePeriods(BaseModel):
    """Pay obligations at due date + grace days, only where grace is known."""
    type: Literal["use_grace_periods"] = "use_grace_periods"


class SpendingCut(BaseModel):
    type: Literal["spending_cut"] = "spending_cut"
    kind: EventKind = EventKind.discretionary_expense
    percent_bps: int = Field(ge=1, le=10000)


class ShiftEvent(BaseModel):
    """Move an event's date; needs external confirmation (flagged in result)."""
    type: Literal["shift_event"] = "shift_event"
    event_id: str  # matches the base event id, or record_id
    days: int = Field(ge=-365, le=365)


class ReserveTopUp(BaseModel):
    type: Literal["reserve_top_up"] = "reserve_top_up"
    amount_minor: int = Field(gt=0)


Disruption = Annotated[
    Union[IncomeDelay, IncomeReduction, UnexpectedExpense, RateChange,
          UseGracePeriods, SpendingCut, ShiftEvent, ReserveTopUp],
    Field(discriminator="type"),
]


class SimulationInput(BaseModel):
    currency: str = "INR"
    opening_balance_minor: Optional[int] = None  # None => simulation incomplete
    start: Date
    horizon_days: int = Field(default=60, ge=1, le=730)
    events: list[CashEvent] = Field(default_factory=list)
    disruptions: list[Disruption] = Field(default_factory=list)


class LedgerEntry(BaseModel):
    date: Date
    event_id: str
    label: str
    kind: EventKind
    status: EventStatus
    delta_minor: int
    balance_after_minor: int
    note: Optional[str] = None


class DayBalance(BaseModel):
    date: Date
    closing_minor: int
    pessimistic_intraday_min_minor: int  # outflows applied before inflows


class Shortfall(BaseModel):
    first_date: Date
    max_deficit_minor: int
    days_negative: int
    obligations_at_risk: list[str]  # event ids


class SimulationResult(BaseModel):
    complete: bool
    incomplete_reasons: list[str] = Field(default_factory=list)
    currency: str
    opening_balance_minor: Optional[int]
    closing_balance_minor: Optional[int] = None
    lowest_balance_minor: Optional[int] = None
    lowest_balance_date: Optional[Date] = None
    shortfall: Optional[Shortfall] = None
    order_sensitive_dates: list[Date] = Field(default_factory=list)
    daily: list[DayBalance] = Field(default_factory=list)
    ledger: list[LedgerEntry] = Field(default_factory=list)
    assumptions_applied: list[str] = Field(default_factory=list)
    excluded_or_unknown: list[str] = Field(default_factory=list)
    requires_external_confirmation: list[str] = Field(default_factory=list)
    total_inflow_minor: int = 0
    total_outflow_minor: int = 0
    rules_version: str = "engine-1"


class Comparison(BaseModel):
    baseline: SimulationResult
    alternative: SimulationResult
    lowest_balance_delta_minor: Optional[int]
    shortfall_delta_minor: int
    first_shortfall_shift_days: Optional[int]
    newly_at_risk: list[str]
    differing_assumptions: list[str]


class SensitivityItem(BaseModel):
    assumption: str
    lowest_balance_without_minor: Optional[int]
    impact_minor: Optional[int]  # lowest(without) - lowest(with); larger = stronger driver
