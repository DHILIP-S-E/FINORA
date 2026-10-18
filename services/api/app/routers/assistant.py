"""AI assistant. The model only plans (intent + validated parameters); numbers come from the engine."""
from __future__ import annotations

from datetime import date

from fastapi import APIRouter, Depends
from pydantic import TypeAdapter

from ..ai.explain import guarded_explanation
from ..ai.schemas import AIUnavailable
from ..deps import get_ai, get_repo, get_today
from ..engine import Disruption, compare, sensitivity, simulate
from ..engine.money import to_major_str
from ..errors import ApiError
from ..repo import Repo
from ..schemas import AssistantIn
from ..security import Principal, ai_limited
from ..services.discovery import build_context, convert
from ..services.projection import all_docs, build_projection, result_summary

router = APIRouter(prefix="/api/v1", tags=["assistant"])
_DIS = TypeAdapter(list[Disruption])


@router.post("/assistant/query")
def query(body: AssistantIn, user: Principal = Depends(ai_limited), repo: Repo = Depends(get_repo), ai=Depends(get_ai),
          today: date = Depends(get_today)):
    records = all_docs(repo, user.uid, "financial_records")
    proj = build_projection(repo, user.uid, today, body.horizon_days)
    cur = proj.sim_input.currency
    base = simulate(proj.sim_input)
    envelope = {"live_ai": ai.live, "provider": ai.name, "facts": [], "assumptions": [], "hypotheses": [], "citations": [],
                "proposed_scenario": None, "needs_clarification": False, "answer_source": "template"}
    if not base.complete:
        envelope.update(answer="I can't calculate this yet: " + " ".join(base.incomplete_reasons) +
                        " Please add the missing information.", needs_clarification=True,
                        facts=[f"Missing: {m}" for m in proj.missing_info])
        return envelope
    try:
        plan = ai.plan(body.message, build_context(records, proj, today, body.horizon_days))
    except AIUnavailable as e:
        raise ApiError(503, "ai_unavailable", "The assistant is unavailable right now. Your data and the deterministic "
                       "projection are unaffected.", {"reason": str(e)[:160]})
    if plan.clarifying_question:
        envelope.update(answer=plan.clarifying_question, needs_clarification=True)
        return envelope

    base_sum = result_summary(base, proj.labels)
    m = lambda v: f"{cur} {to_major_str(v, cur)}"  # noqa: E731
    if plan.intent == "what_if":
        by_id = {r["id"]: r for r in records}
        dis, problems = [], []
        for ad in plan.disruptions:
            d, reason, _ = convert(ad, by_id, today, body.horizon_days, cur)
            (dis.append(d) if d else problems.append(reason))
        if not dis:
            envelope.update(answer="I couldn't turn that into a valid scenario: " + "; ".join(problems or ["no details found"]) +
                            ". Please rephrase with who/what, how many days or how much.", needs_clarification=True)
            return envelope
        cmp_ = compare(proj.sim_input, proj.sim_input.model_copy(update={"disruptions": dis}))
        summary = result_summary(cmp_.alternative, proj.labels)
        facts = {**summary, "scenario_title": "your what-if", "baseline_lowest_balance_minor": cmp_.baseline.lowest_balance_minor}
        text, src = guarded_explanation(ai, facts, body.message)
        title = body.message.strip()[:100]
        envelope.update(
            answer=text, answer_source=src, assumptions=cmp_.alternative.assumptions_applied,
            hypotheses=[f"Hypothetical (from your question): {a}" for a in cmp_.alternative.assumptions_applied],
            facts=[f"Baseline lowest projected balance: {m(cmp_.baseline.lowest_balance_minor)}"],
            proposed_scenario={"title": title, "origin": "natural_language", "disruptions": [d.model_dump(mode="json") for d in dis],
                               "horizon_days": body.horizon_days, "needs_confirmation": True,
                               "source_record_ids": [d.record_id for d in dis if getattr(d, "record_id", None)]},
            simulation=summary,
            citations=[{"type": "scenario_output", "label": "Simulated what-if"}] +
                      [{"type": "record", "id": d.record_id, "label": proj.labels.get(d.record_id, "")} for d in dis if getattr(d, "record_id", None)])
        return envelope

    if plan.intent == "top_pressures":
        outs = sorted((e for e in base.ledger if e.delta_minor < 0), key=lambda e: e.delta_minor)[:3]
        envelope["facts"] = [f"{e.label} on {e.date}: {m(-e.delta_minor)}" for e in outs]
        envelope["citations"] = [{"type": "record", "id": e.event_id.split("@")[0], "label": e.label} for e in outs]
        envelope["answer"] = ("The largest upcoming payments in the window are listed in the facts. Several landing close together "
                              "creates the most pressure." if outs else "No upcoming obligations were found.")
    elif plan.intent == "sensitivity":
        scs = all_docs(repo, user.uid, "scenarios")
        if not scs:
            envelope["answer"] = "There's no saved scenario to analyse yet. Ask a what-if question or run scenario discovery first."
        else:
            sc = max(scs, key=lambda s: (s.get("last_summary") or {}).get("shortfall", {}) and
                     (s["last_summary"]["shortfall"] or {}).get("max_deficit_minor", 0) or 0)
            inp = proj.sim_input.model_copy(update={"disruptions": _DIS.validate_python(sc["disruptions"])})
            sens = sensitivity(inp)
            envelope["facts"] = [f"Removing '{x.assumption}' raises the lowest balance by {m(x.impact_minor)}" for x in sens[:4]]
            envelope["assumptions"] = result_summary(simulate(inp), proj.labels)["assumptions_applied"]
            envelope["citations"] = [{"type": "scenario", "id": sc["id"], "label": sc["title"]}]
            envelope["answer"] = f"For '{sc['title']}', the assumptions with the largest effect are listed in the facts."
    elif plan.intent == "missing_info":
        envelope["facts"] = proj.missing_info or ["Nothing critical is missing."]
        envelope["answer"] = "Here is what I still need (or what is unverified) to calculate this more reliably."
    elif plan.intent == "explain_shortfall":
        text, src = guarded_explanation(ai, base_sum, body.message)
        envelope.update(answer=text, answer_source=src,
                        facts=[f"Lowest projected balance: {m(base.lowest_balance_minor)} on {base.lowest_balance_date}"],
                        simulation=base_sum)
    else:
        envelope["answer"] = ("I can explain your projection, test what-ifs (e.g. 'my payment arrives 10 days late'), rank "
                              "upcoming pressures, show which assumptions matter most, or list missing information.")
    return envelope
