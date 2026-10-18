"""Turn stored records + event overrides into engine input. Pure and deterministic."""
from __future__ import annotations

import uuid
from dataclasses import dataclass, field
from datetime import date, timedelta
from typing import Any

from ..engine import (
    CashEvent, EventKind, EventStatus, Frequency, Schedule, SimulationInput, expand_schedule,
)
from ..repo import Repo, SCHEMA_VERSION, now_iso

KIND_BY_TYPE = {
    "income": EventKind.income,
    "recurring_expense": EventKind.essential_expense,
    "loan": EventKind.loan_repayment,
    "credit_card": EventKind.credit_card,
    "insurance": EventKind.insurance,
    "one_time_expense": EventKind.essential_expense,
    "other": EventKind.other_commitment,
}


def new_id() -> str:
    return uuid.uuid4().hex


def all_docs(repo: Repo, uid: str, coll: str, where: dict | None = None, cap: int = 1000) -> list[dict]:
    out, cur = [], None
    while True:
        page, cur = repo.list(uid, coll, 200, cur, where)
        out += page
        if not cur or len(out) >= cap:
            return out


def audit(repo: Repo, uid: str, action: str, target: str | None = None) -> None:
    """Audit trail: action + target id only, never financial values."""
    i = new_id()
    repo.put(uid, "audit_events", i, {"id": i, "uid": uid, "action": action, "target": target,
                                      "created_at": now_iso(), "schema_version": SCHEMA_VERSION})


@dataclass
class Projection:
    sim_input: SimulationInput
    start: date
    labels: dict[str, str]
    missing_info: list[str] = field(default_factory=list)
    stale_days: int | None = None
    reserve_minor: int = 0


def record_to_event(r: dict) -> CashEvent | None:
    kind = KIND_BY_TYPE.get(r["type"])
    if kind is None or not r.get("start_date"):
        return None
    if r.get("discretionary") and kind == EventKind.essential_expense:
        kind = EventKind.discretionary_expense
    est = r.get("estimated") or r.get("verification") == "extracted_unverified"
    return CashEvent(
        id=r["id"], label=r["name"], kind=kind, amount_minor=r["amount_minor"], record_id=r["id"],
        status=EventStatus.estimated if est else EventStatus.scheduled,
        schedule=Schedule(frequency=Frequency(r.get("frequency", "once")), start=date.fromisoformat(r["start_date"]),
                          end=date.fromisoformat(r["end_date"]) if r.get("end_date") else None,
                          interval_days=r.get("interval_days")),
        grace_days=r.get("grace_days"), source=r.get("source", "manual"),
    )


def build_projection(repo: Repo, uid: str, today: date, horizon_days: int = 60) -> Projection:
    profile = repo.get_user(uid) or {}
    currency = profile.get("currency", "INR")
    as_of = date.fromisoformat(profile["balance_as_of"]) if profile.get("balance_as_of") else None
    start = min(as_of, today) if as_of else today
    horizon = min(730, (today - start).days + horizon_days)
    end = start + timedelta(days=horizon - 1)

    records = all_docs(repo, uid, "financial_records")
    overrides = [o for o in all_docs(repo, uid, "cashflow_events") if not o.get("deleted")]
    by_occ = {(o["record_id"], o["original_date"]): o for o in overrides if o.get("record_id") and o.get("original_date")}

    events: list[CashEvent] = []
    labels: dict[str, str] = {}
    missing: list[str] = []
    reserve = 0
    for r in records:
        labels[r["id"]] = r["name"]
        if r["type"] == "emergency_savings":
            reserve += r["amount_minor"]
            continue
        base = record_to_event(r)
        if base is None:
            continue
        if r["type"] == "loan" and r.get("grace_days") is None:
            missing.append(f"Grace period for '{r['name']}' is unknown.")
        if r["type"] == "loan" and r.get("variable_rate"):
            missing.append(f"'{r['name']}' has a variable rate; payment after a reset is unknown.")
        if r.get("verification") == "extracted_unverified":
            missing.append(f"'{r['name']}' was extracted from a document and is not yet verified.")
        for c in expand_schedule([base], start, end):
            occ = by_occ.get((r["id"], c.date.isoformat()))
            if occ:
                if occ.get("completed") or occ.get("skipped"):
                    continue
                c = c.model_copy(update={"date": date.fromisoformat(occ["date"]), "amount_minor": occ["amount_minor"],
                                         "label": occ["label"], "status": EventStatus(occ["status"])})
            events.append(c)
    for o in overrides:
        if o.get("record_id") or o.get("completed") or o.get("skipped"):
            continue
        d = date.fromisoformat(o["date"])
        if start <= d <= end:
            events.append(CashEvent(id=o["id"], label=o["label"], kind=EventKind(o["kind"]), amount_minor=o["amount_minor"],
                                    status=EventStatus(o["status"]), date=d, source="manual_event"))
            labels[o["id"]] = o["label"]

    if profile.get("opening_balance_minor") is None:
        missing.append("Opening cash balance is missing.")
    if not any(e.kind == EventKind.income for e in events):
        missing.append("No expected income in the projection window.")
    stale = (today - as_of).days if as_of else None
    if stale is not None and stale > 7:
        missing.append(f"Cash balance was last updated {stale} days ago.")

    return Projection(
        sim_input=SimulationInput(currency=currency, opening_balance_minor=profile.get("opening_balance_minor"),
                                  start=start, horizon_days=horizon, events=events),
        start=start, labels=labels, missing_info=missing, stale_days=stale, reserve_minor=reserve)


def label_for(labels: dict[str, str], event_id: str) -> str:
    return labels.get(event_id.split("@")[0], event_id)


def result_summary(result, labels: dict[str, str]) -> dict[str, Any]:
    """Compact, API-friendly facts (also the ONLY numbers the explainer may use)."""
    s = result.shortfall
    return {
        "complete": result.complete,
        "incomplete_reasons": result.incomplete_reasons,
        "currency": result.currency,
        "opening_balance_minor": result.opening_balance_minor,
        "lowest_balance_minor": result.lowest_balance_minor,
        "lowest_balance_date": result.lowest_balance_date.isoformat() if result.lowest_balance_date else None,
        "closing_balance_minor": result.closing_balance_minor,
        "shortfall": None if not s else {
            "first_date": s.first_date.isoformat(), "max_deficit_minor": s.max_deficit_minor,
            "days_negative": s.days_negative,
            "obligations_at_risk": sorted({label_for(labels, e) for e in s.obligations_at_risk}),
        },
        "order_sensitive_dates": [d.isoformat() for d in result.order_sensitive_dates],
        "assumptions_applied": result.assumptions_applied,
        "excluded_or_unknown": result.excluded_or_unknown,
        "requires_external_confirmation": result.requires_external_confirmation,
    }
