"""Explanations. Numbers only ever come from verified engine output (`facts`)."""
from __future__ import annotations

import logging
import re
from decimal import Decimal

from ..engine.money import to_major_str

log = logging.getLogger("cascade.ai")
_NUM = re.compile(r"\d[\d,]*(?:\.\d+)?")


def _m(minor: int | None, cur: str) -> str:
    return "unknown" if minor is None else f"{cur} {to_major_str(minor, cur)}"


def template_explanation(facts: dict) -> str:
    """Deterministic explanation; used when AI is off/unavailable or fails the number guard."""
    cur = facts.get("currency", "INR")
    if not facts.get("complete", True):
        return "A projection can't be calculated yet: " + " ".join(facts.get("incomplete_reasons", []))
    s = facts.get("shortfall")
    parts = []
    scen = facts.get("scenario_title")
    parts.append(f"Under the assumptions of '{scen}'," if scen else "Under the current records,")
    if s:
        risk = ", ".join(s["obligations_at_risk"]) or "upcoming payments"
        parts.append(
            f"your projected cash could drop below zero from {s['first_date']}, by up to {_m(s['max_deficit_minor'], cur)} "
            f"over {s['days_negative']} day(s). Payments affected: {risk}.")
    else:
        parts.append(f"projected cash stays at or above zero; the lowest point is {_m(facts.get('lowest_balance_minor'), cur)}"
                     f" on {facts.get('lowest_balance_date')}.")
    base = facts.get("baseline_lowest_balance_minor")
    if base is not None:
        parts.append(f"Without these assumptions the lowest projected balance is {_m(base, cur)}.")
    if facts.get("order_sensitive_dates"):
        parts.append("On some days the outcome depends on which payment clears first: " + ", ".join(facts["order_sensitive_dates"]) + ".")
    if facts.get("excluded_or_unknown"):
        parts.append("Not modelled / unknown: " + " ".join(facts["excluded_or_unknown"][:3]))
    parts.append("This is a what-if projection, not a prediction or financial advice.")
    return " ".join(parts)


def _numbers(text: str) -> set[Decimal]:
    return {Decimal(n.replace(",", "")) for n in _NUM.findall(text)}


def numbers_are_grounded(text: str, facts_text: str) -> bool:
    """Every number in the model's text must already appear in the verified facts (dates split into parts)."""
    allowed = _numbers(facts_text.replace("-", " ")) | {Decimal(x) for x in range(0, 11)}
    # also allow major-unit renderings of minor values present in facts
    for n in re.findall(r"-?\d+", facts_text):
        try:
            allowed.add(Decimal(to_major_str(int(n))))
        except Exception:  # noqa: BLE001
            pass
    return all(n in allowed for n in _numbers(text))


def guarded_explanation(provider, facts: dict, question: str | None = None) -> tuple[str, str]:
    """Returns (text, source) where source is 'gemini' or 'template'. Never returns ungrounded numbers."""
    import json
    from .schemas import AIUnavailable
    if provider.live:
        try:
            text = provider.explain(facts, question)
            # Facts rendered with major-unit strings as well so the model may quote either form.
            facts_text = json.dumps(facts) + " " + template_explanation(facts)
            if text and numbers_are_grounded(text, facts_text):
                return text, "gemini"
            log.warning("model explanation rejected by number-grounding guard")
        except AIUnavailable:
            pass
    return template_explanation(facts), "template"
