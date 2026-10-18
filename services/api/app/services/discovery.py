"""Scenario discovery pipeline: context -> AI hypotheses -> validation -> deterministic simulation."""
from __future__ import annotations

from dataclasses import dataclass, field
from datetime import date, timedelta
from typing import Any

from pydantic import TypeAdapter

from ..ai.schemas import AIDisruption, ScenarioHypothesis
from ..engine import (
    Disruption, IncomeDelay, IncomeReduction, RateChange, SimulationInput, UnexpectedExpense, expand_schedule,
    simulate,
)
from ..engine.money import to_major_str, to_minor
from .projection import Projection, record_to_event, result_summary

_DIS = TypeAdapter(Disruption)


def build_context(records: list[dict], proj: Projection, today: date, horizon_days: int) -> dict[str, Any]:
    """Minimised context for the model: no document text, no account identifiers, no notes."""
    cur = proj.sim_input.currency
    end = today + timedelta(days=horizon_days)
    recs, upcoming = [], []
    for r in records:
        e = record_to_event(r)
        recs.append({
            "id": r["id"], "type": r["type"], "name": r["name"][:40], "amount_major": float(to_major_str(r["amount_minor"], cur)),
            "frequency": r.get("frequency"), "grace_days": r.get("grace_days"),
            "variable_rate": r.get("variable_rate", False), "estimated": bool(r.get("estimated")),
        })
        if e:
            for c in expand_schedule([e], today, end)[:4]:
                upcoming.append({"record_id": r["id"], "type": r["type"], "date": c.date.isoformat(),
                                 "amount_major": float(to_major_str(c.amount_minor, cur))})
    upcoming.sort(key=lambda u: u["date"])
    ob = proj.sim_input.opening_balance_minor
    return {"today": today.isoformat(), "horizon_days": horizon_days, "currency": cur,
            "opening_balance_major": None if ob is None else float(to_major_str(ob, cur)),
            "records": recs, "upcoming": upcoming[:40]}


@dataclass
class Validated:
    hypothesis: ScenarioHypothesis
    disruptions: list = field(default_factory=list)
    status: str = "validated"           # validated | needs_input | rejected
    reasons: list[str] = field(default_factory=list)


def _d(s: str | None) -> date | None:
    try:
        return date.fromisoformat(s) if s else None
    except ValueError:
        return None


def convert(ad: AIDisruption, records: dict[str, dict], today: date, horizon: int, cur: str) -> tuple[Any, str | None, bool]:
    """-> (engine disruption | None, reason, needs_input)."""
    end = today + timedelta(days=horizon)
    rec = records.get(ad.record_id) if ad.record_id else None
    if ad.record_id and rec is None:
        return None, f"unknown record id '{ad.record_id}'", False
    if ad.type == "income_delay":
        if rec and rec["type"] != "income":
            return None, "income_delay must reference an income record", False
        if not ad.days or not 1 <= ad.days <= 90:
            return None, "delay must be 1-90 days", False
        return IncomeDelay(record_id=ad.record_id, days=ad.days), None, False
    if ad.type == "income_reduction":
        if rec and rec["type"] != "income":
            return None, "income_reduction must reference an income record", False
        if ad.percent is None or not 0 < ad.percent <= 100:
            return None, "reduction percent must be in (0, 100]", False
        return IncomeReduction(record_id=ad.record_id, percent_bps=int(round(ad.percent * 100))), None, False
    if ad.type == "unexpected_expense":
        on = _d(ad.on)
        if on is None or not today <= on <= end:
            return None, "unexpected expense date missing or outside horizon", False
        if ad.amount_major is None or ad.amount_major <= 0 or ad.amount_major > 1e9:
            return None, "unexpected expense amount invalid", False
        return UnexpectedExpense(on=on, amount_minor=to_minor(str(ad.amount_major), cur),
                                 label=(ad.label or "Unexpected expense")[:60]), None, False
    if ad.type == "rate_change":
        if not rec or rec["type"] != "loan" or not rec.get("variable_rate"):
            return None, "rate_change requires a variable-rate loan record", False
        eff = _d(ad.effective)
        if eff is None or not today <= eff <= end:
            return None, "rate change date missing or outside horizon", False
        if not ad.new_payment_major or ad.new_payment_major <= 0:
            return None, "new payment after the rate change is unknown; please provide it", True
        return RateChange(record_id=rec["id"], effective=eff,
                          new_payment_minor=to_minor(str(ad.new_payment_major), cur)), None, False
    return None, "unsupported disruption type", False


def validate(hyps: list[ScenarioHypothesis], records: list[dict], today: date, horizon: int, cur: str) -> list[Validated]:
    by_id = {r["id"]: r for r in records}
    seen: set[str] = set()
    out: list[Validated] = []
    for h in hyps:
        v = Validated(hypothesis=h)
        bad = [i for i in h.source_record_ids if i not in by_id]
        if bad:
            v.status, v.reasons = "rejected", [f"references unknown records: {', '.join(bad)}"]
            out.append(v)
            continue
        needs = hard = False
        for ad in h.disruptions:
            dis, reason, need = convert(ad, by_id, today, horizon, cur)
            if dis is not None:
                v.disruptions.append(dis)
            else:
                v.reasons.append(reason or "invalid")
                needs, hard = needs or need, hard or not need
        if hard:
            v.status = "rejected"
        elif needs:
            v.status = "needs_input"
        elif not v.disruptions:
            v.status, v.reasons = "rejected", ["no usable disruptions"]
        sig = repr(sorted(d.model_dump_json() for d in v.disruptions))
        if v.status == "validated" and sig in seen:
            v.status, v.reasons = "rejected", ["duplicate scenario"]
        seen.add(sig)
        out.append(v)
    return out


def evaluate(v: Validated, base_input: SimulationInput, proj: Projection) -> dict:
    """Simulate a validated scenario and quantify the compound effect against single disruptions."""
    inp = base_input.model_copy(update={"disruptions": v.disruptions})
    res = simulate(inp)
    base = simulate(base_input)
    solo = []
    if len(v.disruptions) > 1:
        for d in v.disruptions:
            r = simulate(base_input.model_copy(update={"disruptions": [d]}))
            solo.append(r.shortfall.max_deficit_minor if r.shortfall else 0)
    combined = res.shortfall.max_deficit_minor if res.shortfall else 0
    compound = None
    if solo:
        compound = {"combined_deficit_minor": combined, "individual_deficits_minor": solo,
                    "interaction_minor": combined - max(solo)}
    return {"result": res, "summary": result_summary(res, proj.labels), "baseline_summary": result_summary(base, proj.labels),
            "compound_effect": compound, "sort_key": combined}
