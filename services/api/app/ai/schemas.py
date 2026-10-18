"""Typed AI I/O. Models propose; deterministic code validates and calculates."""
from __future__ import annotations

from typing import Literal, Optional

from pydantic import BaseModel, Field


class AIDisruption(BaseModel):
    type: Literal["income_delay", "income_reduction", "unexpected_expense", "rate_change"]
    record_id: Optional[str] = None
    days: Optional[int] = None
    percent: Optional[float] = None             # income_reduction, e.g. 25 = 25%
    on: Optional[str] = None                    # ISO date (unexpected_expense)
    amount_major: Optional[float] = None        # unexpected_expense, major currency units
    effective: Optional[str] = None             # ISO date (rate_change)
    new_payment_major: Optional[float] = None   # rate_change; only if known from the records
    label: Optional[str] = None


class ScenarioHypothesis(BaseModel):
    scenario_title: str
    scenario_summary: str
    trigger_events: list[str] = Field(default_factory=list)
    assumptions: list[str] = Field(default_factory=list)
    required_inputs: list[str] = Field(default_factory=list)
    source_record_ids: list[str] = Field(default_factory=list)
    time_horizon_days: int = 60
    potential_impact: Literal["worsens_liquidity", "improves_liquidity", "uncertain"] = "worsens_liquidity"
    rationale: str = ""
    uncertainties: list[str] = Field(default_factory=list)
    # Qualitative interpretation confidence only. NOT a probability of the event occurring.
    interpretation_confidence: Literal["low", "medium", "high"] = "medium"
    disruptions: list[AIDisruption] = Field(default_factory=list)


class DiscoveryResponse(BaseModel):
    scenarios: list[ScenarioHypothesis]


class AssistantPlan(BaseModel):
    intent: Literal["explain_shortfall", "what_if", "top_pressures", "sensitivity", "missing_info", "out_of_scope"]
    disruptions: list[AIDisruption] = Field(default_factory=list)
    clarifying_question: Optional[str] = None


class ExtractedTerm(BaseModel):
    field_name: Literal[
        "principal_amount", "interest_rate_pct", "rate_type", "repayment_frequency", "payment_amount",
        "first_payment_date", "tenure_months", "processing_fee", "late_payment_penalty", "grace_period_days",
        "insurance_premium", "premium_due_date", "rate_reset_condition", "other_payment_date",
    ]
    status: Literal["found", "unknown", "conflict"]
    value: Optional[str] = None  # as written in the document; never inferred
    page: Optional[int] = None
    excerpt: Optional[str] = None


class DocumentExtraction(BaseModel):
    document_type: Literal["loan", "credit_card", "insurance", "invoice", "bank_statement", "other", "unreadable"]
    terms: list[ExtractedTerm] = Field(default_factory=list)
    conflicts: list[str] = Field(default_factory=list)
    missing_information: list[str] = Field(default_factory=list)
    suspected_prompt_injection: bool = False


class AIUnavailable(Exception):
    """Raised when the model cannot be reached or returns unusable output after bounded retries."""
