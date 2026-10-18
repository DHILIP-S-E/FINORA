"""Deterministic, rule-based stand-in used when no Gemini credentials are configured.

It is ALWAYS labelled (`provider=fallback`, `live_ai=false`) in API responses and in the UI.
It never claims that a live AI analysis ran.
"""
from __future__ import annotations

import re
from datetime import date, timedelta

from .explain import template_explanation
from .schemas import (
    AIDisruption, AIUnavailable, AssistantPlan, DiscoveryResponse, DocumentExtraction, ScenarioHypothesis,
)


def _heaviest_cluster(upcoming: list[dict]) -> tuple[date | None, list[str]]:
    outs = [u for u in upcoming if u["type"] != "income"]
    best, best_sum, ids = None, 0, []
    for u in outs:
        d0 = date.fromisoformat(u["date"])
        window = [x for x in outs if 0 <= (date.fromisoformat(x["date"]) - d0).days <= 5]
        total = sum(x["amount_major"] for x in window)
        if total > best_sum:
            best, best_sum, ids = d0, total, sorted({x["record_id"] for x in window})
    return best, ids


class FallbackProvider:
    name = "fallback"
    live = False

    def discover(self, context, max_n):
        recs = context["records"]
        upcoming = context.get("upcoming", [])
        incomes = sorted([r for r in recs if r["type"] == "income"], key=lambda r: -r["amount_major"])
        obligations = [r for r in recs if r["type"] in ("loan", "credit_card", "insurance", "recurring_expense", "other")]
        heavy_date, heavy_ids = _heaviest_cluster(upcoming)
        out: list[ScenarioHypothesis] = []
        h = min(context.get("horizon_days", 60), 60)

        exp_amt = max([r["amount_major"] for r in obligations], default=0)
        for inc in incomes[:1]:
            near_ids = heavy_ids or [r["id"] for r in obligations[:3]]
            out.append(ScenarioHypothesis(
                scenario_title=f"Late payment from {inc['name']}",
                scenario_summary="Income arrives 10 days later than scheduled while fixed obligations stay due.",
                trigger_events=[f"{inc['name']} delayed by 10 days", "Obligations remain due on schedule"],
                assumptions=["Delay of 10 days (illustrative, not a prediction)", "No overdraft or deferral available"],
                source_record_ids=[inc["id"], *near_ids], time_horizon_days=h,
                rationale="Irregular income paid after fixed due dates is the most common source of short-term shortfalls.",
                uncertainties=["Actual delay length is unknown"], interpretation_confidence="medium",
                disruptions=[AIDisruption(type="income_delay", record_id=inc["id"], days=10)]))
            if heavy_date and exp_amt:
                out.append(ScenarioHypothesis(
                    scenario_title="Late income plus an unexpected expense",
                    scenario_summary=f"{inc['name']} is 10 days late and an unplanned expense lands near your heaviest payment cluster.",
                    trigger_events=[f"{inc['name']} delayed 10 days", f"Unexpected expense on {heavy_date.isoformat()}"],
                    assumptions=["Delay of 10 days", f"Unexpected expense equal to your largest single obligation ({exp_amt:g})"],
                    source_record_ids=[inc["id"], *heavy_ids], time_horizon_days=h,
                    rationale="Two disruptions can create a larger gap than either alone.",
                    uncertainties=["Size and timing of any unexpected expense are unknown"], interpretation_confidence="low",
                    disruptions=[AIDisruption(type="income_delay", record_id=inc["id"], days=10),
                                 AIDisruption(type="unexpected_expense", on=heavy_date.isoformat(), amount_major=exp_amt,
                                              label="Unexpected expense (illustrative)")]))
        if incomes:
            out.append(ScenarioHypothesis(
                scenario_title="Income falls 30% during high fixed obligations",
                scenario_summary="All income is 30% lower than expected while obligations are unchanged.",
                trigger_events=["Income reduced by 30%"], assumptions=["30% reduction applied to every income source"],
                source_record_ids=[r["id"] for r in incomes], time_horizon_days=h,
                rationale="Variable earnings can undershoot estimates.", uncertainties=["Size of any shortfall in income is unknown"],
                interpretation_confidence="low", disruptions=[AIDisruption(type="income_reduction", percent=30)]))
        return DiscoveryResponse(scenarios=out[:max_n])

    def plan(self, message, context):
        m = message.lower()
        incomes = [r for r in context["records"] if r["type"] == "income"]
        days = re.search(r"(\d{1,3})\s*(?:days?|d)\s*(?:late|delay\w*|later|behind)", m) or \
            re.search(r"(?:late|delay\w*)\s*(?:by)?\s*(\d{1,3})\s*days?", m)
        amt = re.search(r"(?:expense|bill|cost)[^\d]{0,20}(?:rs\.?|inr|₹)?\s*([\d,]+(?:\.\d+)?)", m)
        pct = re.search(r"(\d{1,3})\s*%\s*(?:less|lower|drop|reduc\w*|fall)", m)
        named = [r for r in incomes if r["name"].lower().split(" - ")[0] in m]
        if days:
            if named:
                rid = named[0]["id"]
            elif len(incomes) == 1:
                rid = incomes[0]["id"]
            elif not incomes:
                return AssistantPlan(intent="out_of_scope", clarifying_question="I don't see any income records yet. Add one first.")
            else:
                return AssistantPlan(intent="what_if", clarifying_question="Which income source would be delayed? " +
                                     ", ".join(r["name"] for r in incomes))
            return AssistantPlan(intent="what_if", disruptions=[AIDisruption(type="income_delay", record_id=rid, days=int(days.group(1)))])
        if pct:
            return AssistantPlan(intent="what_if", disruptions=[AIDisruption(type="income_reduction", percent=float(pct.group(1)))])
        if amt and "unexpected" in m or (amt and "emergency" in m):
            upc = [u for u in context.get("upcoming", []) if u["type"] != "income"]
            on = upc[0]["date"] if upc else (date.fromisoformat(context["today"]) + timedelta(days=7)).isoformat()
            return AssistantPlan(intent="what_if", disruptions=[AIDisruption(type="unexpected_expense", on=on,
                                 amount_major=float(amt.group(1).replace(",", "")), label="Unexpected expense")])
        if any(k in m for k in ("sensitiv", "biggest impact", "which assumption")):
            return AssistantPlan(intent="sensitivity")
        if any(k in m for k in ("pressure", "greatest", "which obligation")):
            return AssistantPlan(intent="top_pressures")
        if any(k in m for k in ("information", "missing", "need to know")):
            return AssistantPlan(intent="missing_info")
        if any(k in m for k in ("negative", "shortfall", "why", "run out", "balance")):
            return AssistantPlan(intent="explain_shortfall")
        return AssistantPlan(intent="out_of_scope")

    def explain(self, facts, question):
        return template_explanation(facts)

    def extract(self, data, mime) -> DocumentExtraction:
        raise AIUnavailable("Document extraction needs a configured Gemini model (set GEMINI_API_KEY or USE_VERTEX).")
