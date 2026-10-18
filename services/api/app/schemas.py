"""API request/response models (Pydantic v2)."""
from __future__ import annotations

import datetime as dt
from enum import Enum
from typing import Any, Optional

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

from .engine import Disruption, EventKind, Frequency
from .engine.money import CURRENCY_EXPONENT

Date = dt.date
MAX_MINOR = 10**13  # sanity bound


class Strict(BaseModel):
    model_config = ConfigDict(extra="forbid")


class RecordType(str, Enum):
    income = "income"
    recurring_expense = "recurring_expense"
    loan = "loan"
    credit_card = "credit_card"
    insurance = "insurance"
    one_time_expense = "one_time_expense"
    emergency_savings = "emergency_savings"
    other = "other"


class Verification(str, Enum):
    user_provided = "user_provided"
    verified = "verified"
    extracted_unverified = "extracted_unverified"
    demo = "demo"


def _currency(v: str) -> str:
    if v not in CURRENCY_EXPONENT:
        raise ValueError(f"unsupported currency {v}")
    return v


class RecordIn(Strict):
    name: str = Field(min_length=1, max_length=120)
    type: RecordType
    amount_minor: int = Field(ge=0, le=MAX_MINOR)
    currency: str = "INR"
    category: Optional[str] = Field(default=None, max_length=60)
    frequency: Frequency = Frequency.once
    start_date: Optional[Date] = None
    end_date: Optional[Date] = None
    interval_days: Optional[int] = Field(default=None, ge=1, le=366)
    grace_days: Optional[int] = Field(default=None, ge=0, le=60)
    discretionary: bool = False
    variable_rate: bool = False
    estimated: bool = False           # income/amount is an estimate
    verification: Verification = Verification.user_provided
    source: str = Field(default="manual", max_length=40)
    source_ref: Optional[dict[str, Any]] = None  # e.g. {"document_id","page","excerpt"}
    notes: Optional[str] = Field(default=None, max_length=1000)

    _cur = field_validator("currency")(_currency)

    @model_validator(mode="after")
    def _dates(self):
        if self.type != RecordType.emergency_savings and self.start_date is None:
            raise ValueError("start_date is required for dated records")
        if self.end_date and self.start_date and self.end_date < self.start_date:
            raise ValueError("end_date before start_date")
        if self.frequency == Frequency.custom_days and not self.interval_days:
            raise ValueError("interval_days required for custom_days")
        if self.type != RecordType.emergency_savings and self.amount_minor == 0:
            raise ValueError("amount must be greater than zero")
        return self


class RecordPatch(Strict):
    name: Optional[str] = Field(default=None, min_length=1, max_length=120)
    amount_minor: Optional[int] = Field(default=None, ge=0, le=MAX_MINOR)
    category: Optional[str] = Field(default=None, max_length=60)
    frequency: Optional[Frequency] = None
    start_date: Optional[Date] = None
    end_date: Optional[Date] = None
    interval_days: Optional[int] = Field(default=None, ge=1, le=366)
    grace_days: Optional[int] = Field(default=None, ge=0, le=60)
    discretionary: Optional[bool] = None
    variable_rate: Optional[bool] = None
    estimated: Optional[bool] = None
    verification: Optional[Verification] = None
    notes: Optional[str] = Field(default=None, max_length=1000)


class ProfileIn(Strict):
    display_name: Optional[str] = Field(default=None, max_length=80)
    currency: str = "INR"
    opening_balance_minor: Optional[int] = Field(default=None, ge=-MAX_MINOR, le=MAX_MINOR)
    balance_as_of: Optional[Date] = None
    monthly_essential_minor: Optional[int] = Field(default=None, ge=0, le=MAX_MINOR)
    reserve_target_minor: Optional[int] = Field(default=None, ge=0, le=MAX_MINOR)
    onboarding_complete: bool = False

    _cur = field_validator("currency")(_currency)


class EventStatusIn(str, Enum):
    scheduled = "scheduled"
    estimated = "estimated"
    actual = "actual"


class CashflowEventIn(Strict):
    """One-off event, or an override of one occurrence of a recurring record."""
    label: str = Field(min_length=1, max_length=120)
    kind: EventKind
    amount_minor: int = Field(gt=0, le=MAX_MINOR)
    date: Date
    status: EventStatusIn = EventStatusIn.scheduled
    record_id: Optional[str] = None
    original_date: Optional[Date] = None  # set with record_id to override that occurrence
    completed: bool = False
    skipped: bool = False


class CashflowEventPatch(Strict):
    label: Optional[str] = Field(default=None, min_length=1, max_length=120)
    amount_minor: Optional[int] = Field(default=None, gt=0, le=MAX_MINOR)
    date: Optional[Date] = None
    status: Optional[EventStatusIn] = None
    completed: Optional[bool] = None
    skipped: Optional[bool] = None


class ScenarioIn(Strict):
    title: str = Field(min_length=1, max_length=140)
    summary: str = Field(default="", max_length=1000)
    origin: str = Field(default="user", pattern="^(user|ai|ai_fallback|natural_language|demo)$")
    horizon_days: int = Field(default=60, ge=7, le=365)
    disruptions: list[Disruption] = Field(default_factory=list, max_length=12)
    assumptions: list[str] = Field(default_factory=list, max_length=20)
    uncertainties: list[str] = Field(default_factory=list, max_length=20)
    source_record_ids: list[str] = Field(default_factory=list, max_length=50)


class SimulateIn(Strict):
    disruptions: Optional[list[Disruption]] = None  # override saved assumptions (what-if)
    explain: bool = True


class CompareIn(Strict):
    alternative_disruptions: Optional[list[Disruption]] = None  # user-modified alternative
    explain: bool = True


class DiscoverIn(Strict):
    horizon_days: int = Field(default=60, ge=14, le=180)
    max_candidates: int = Field(default=4, ge=1, le=6)


class AssistantIn(Strict):
    message: str = Field(min_length=1, max_length=600)
    horizon_days: int = Field(default=60, ge=7, le=180)


class QuietHours(Strict):
    start_hour: int = Field(ge=0, le=23)
    end_hour: int = Field(ge=0, le=23)


class NotificationPrefsIn(Strict):
    push_enabled: bool = True
    min_shortfall_minor: int = Field(default=0, ge=0, le=MAX_MINOR)
    quiet_hours: Optional[QuietHours] = None
    utc_offset_minutes: int = Field(default=330, ge=-720, le=840)
    fcm_token: Optional[str] = Field(default=None, max_length=4096)
    alert_types: list[str] = Field(default_factory=lambda: [
        "new_shortfall", "income_date_changed", "material_obligation", "missing_information", "scenario_changed"])


class AlertPatch(Strict):
    read: Optional[bool] = None
    dismissed: Optional[bool] = None


class Page(BaseModel):
    items: list[dict]
    next_cursor: Optional[str] = None


class DocumentConfirmIn(Strict):
    records: list[RecordIn] = Field(min_length=1, max_length=20)
