"""Scenario discovery, persistence, simulation, comparison and intervention analysis."""
from __future__ import annotations

import hashlib
import json
from datetime import date, timedelta
from typing import Optional

from fastapi import APIRouter, Depends, Header, Query
from pydantic import TypeAdapter

from ..ai.explain import guarded_explanation
from ..ai.schemas import AIUnavailable
from ..deps import get_ai, get_repo, get_today
from ..engine import (
    Disruption, ReserveTopUp, ShiftEvent, SimulationInput, SpendingCut, UseGracePeriods, compare, sensitivity,
    simulate,
)
from ..engine.money import to_major_str
from ..errors import ApiError, NotFound
from ..repo import SCHEMA_VERSION, Repo, now_iso
from ..schemas import CompareIn, DiscoverIn, ScenarioIn, SimulateIn
from ..security import Principal, ai_limited, current_user
from ..services.discovery import build_context, evaluate, validate
from ..services.projection import all_docs, audit, build_projection, new_id, result_summary

router = APIRouter(prefix="/api/v1", tags=["scenarios"])
_DIS = TypeAdapter(list[Disruption])
MAX_STORED_LEDGER = 400


def _need_complete(proj) -> None:
    res = simulate(proj.sim_input)
    if not res.complete:
        raise ApiError(422, "incomplete_inputs", "A simulation needs more information.",
                       {"reasons": res.incomplete_reasons, "missing_information": proj.missing_info})


def _labels_flags(ai) -> dict:
    return {"hypotheses": "ai_generated" if ai.live else "rule_based_demo_fallback", "numbers": "simulated_by_engine",
            "live_ai": ai.live, "provider": ai.name}


def _strip(result_json: dict, keep_ledger: bool = True) -> dict:
    r = dict(result_json)
    r["ledger"] = r["ledger"][:MAX_STORED_LEDGER] if keep_ledger else []
    return r


# ---------------- discovery ----------------
@router.post("/scenarios/discover")
def discover(body: DiscoverIn, user: Principal = Depends(ai_limited), repo: Repo = Depends(get_repo), ai=Depends(get_ai),
             today: date = Depends(get_today)):
    records = all_docs(repo, user.uid, "financial_records")
    proj = build_projection(repo, user.uid, today, body.horizon_days)
    _need_complete(proj)
    cur = proj.sim_input.currency
    ctx = build_context(records, proj, today, body.horizon_days)
    try:
        resp = ai.discover(ctx, body.max_candidates)
    except AIUnavailable as e:
        raise ApiError(503, "ai_unavailable", "AI scenario discovery is currently unavailable. Your records, projection "
                       "and manual what-if simulations still work.", {"reason": str(e)[:160]})
    validated = validate(resp.scenarios, records, today, body.horizon_days, cur)
    out = []
    for v in validated:
        h = v.hypothesis
        item = {"scenario_title": h.scenario_title, "scenario_summary": h.scenario_summary, "trigger_events": h.trigger_events,
                "assumptions": h.assumptions, "required_inputs": h.required_inputs, "source_record_ids": h.source_record_ids,
                "time_horizon_days": h.time_horizon_days, "potential_impact": h.potential_impact, "rationale": h.rationale,
                "uncertainties": h.uncertainties, "interpretation_confidence": h.interpretation_confidence,
                "validation_status": v.status, "validation_reasons": v.reasons,
                "disruptions": [d.model_dump(mode="json") for d in v.disruptions], "evaluation": None, "compound_effect": None}
        if v.status == "validated":
            ev = evaluate(v, proj.sim_input, proj)
            item["evaluation"], item["compound_effect"], item["_k"] = ev["summary"], ev["compound_effect"], ev["sort_key"]
        out.append(item)
    out.sort(key=lambda x: (x["validation_status"] != "validated", -x.get("_k", 0)))
    for x in out:
        x.pop("_k", None)
    audit(repo, user.uid, "scenario.discover")
    return {"labels": _labels_flags(ai), "candidates": out,
            "baseline": result_summary(simulate(proj.sim_input), proj.labels),
            "note": "Hypotheses are model-proposed and unverified; amounts shown are deterministic simulation output."}


# ---------------- CRUD ----------------
def _run(repo: Repo, uid: str, scenario: dict, proj, disruptions: list, ai, explain: bool) -> dict:
    inp = proj.sim_input.model_copy(update={"disruptions": disruptions})
    res = simulate(inp)
    base = simulate(proj.sim_input)
    summary = result_summary(res, proj.labels)
    explanation = source = None
    if explain:
        facts = {**summary, "scenario_title": scenario["title"], "baseline_lowest_balance_minor": base.lowest_balance_minor}
        explanation, source = guarded_explanation(ai, facts)
    snapshot = inp.model_dump(mode="json")
    run = {"id": new_id(), "uid": uid, "scenario_id": scenario["id"], "created_at": now_iso(), "schema_version": SCHEMA_VERSION,
           "input_hash": hashlib.sha256(json.dumps(snapshot, sort_keys=True).encode()).hexdigest(), "input": snapshot,
           "result": _strip(res.model_dump(mode="json")), "summary": summary, "explanation": explanation,
           "explanation_source": source, "labels": {"hypotheses": "see scenario.origin", "numbers": "simulated_by_engine",
                                                    "live_ai": bool(source == "gemini")}}
    repo.put(uid, "simulation_runs", run["id"], run)
    return run


@router.post("/scenarios", status_code=201)
def save_scenario(body: ScenarioIn, idempotency_key: Optional[str] = Header(default=None), user: Principal = Depends(current_user),
                  repo: Repo = Depends(get_repo), ai=Depends(get_ai), today: date = Depends(get_today)):
    if idempotency_key:
        hit = repo.get(user.uid, "idempotency", f"scenario:{idempotency_key}"[:200])
        if hit:
            return hit["response"]
    for rid in body.source_record_ids:
        if not repo.get(user.uid, "financial_records", rid):
            raise ApiError(422, "unknown_record", f"source record {rid} does not exist")
    for d in body.disruptions:
        rid = getattr(d, "record_id", None)
        if rid and not repo.get(user.uid, "financial_records", rid):
            raise ApiError(422, "unknown_record", f"disruption references unknown record {rid}")
    sid, now = new_id(), now_iso()
    doc = {**body.model_dump(mode="json"), "id": sid, "uid": user.uid, "validation_status": "validated",
           "created_at": now, "updated_at": now, "schema_version": SCHEMA_VERSION}
    proj = build_projection(repo, user.uid, today, body.horizon_days)
    run = None
    if simulate(proj.sim_input).complete:
        run = _run(repo, user.uid, doc, proj, _DIS.validate_python(doc["disruptions"]), ai, explain=True)
        doc["last_summary"] = run["summary"]
    repo.put(user.uid, "scenarios", sid, doc)
    resp = {"scenario": doc, "run": run}
    if idempotency_key:
        repo.put(user.uid, "idempotency", f"scenario:{idempotency_key}"[:200],
                 {"id": f"scenario:{idempotency_key}"[:200], "response": resp, "created_at": now})
    audit(repo, user.uid, "scenario.create", sid)
    return resp


@router.get("/scenarios")
def list_scenarios(limit: int = Query(30, ge=1, le=100), cursor: Optional[str] = None,
                   user: Principal = Depends(current_user), repo: Repo = Depends(get_repo)):
    items, nxt = repo.list(user.uid, "scenarios", limit, cursor)
    return {"items": items, "next_cursor": nxt}


def _latest_run(repo: Repo, uid: str, sid: str) -> Optional[dict]:
    runs = all_docs(repo, uid, "simulation_runs", {"scenario_id": sid})
    return runs[-1] if runs else None


@router.get("/scenarios/{scenario_id}")
def get_scenario(scenario_id: str, user: Principal = Depends(current_user), repo: Repo = Depends(get_repo)):
    sc = repo.get(user.uid, "scenarios", scenario_id)
    if not sc:
        raise NotFound("scenario")
    run = _latest_run(repo, user.uid, scenario_id)
    replay = None
    if run:  # re-run the stored snapshot: same inputs + rules must give the same numbers
        again = simulate(SimulationInput.model_validate(run["input"]))
        replay = {"matches_stored_result": again.lowest_balance_minor == run["summary"]["lowest_balance_minor"]
                  and [d.closing_minor for d in again.daily] == [d["closing_minor"] for d in run["result"]["daily"]]}
    return {"scenario": sc, "latest_run": run, "replay": replay}


@router.post("/scenarios/{scenario_id}/simulate")
def simulate_scenario(scenario_id: str, body: SimulateIn, user: Principal = Depends(ai_limited), repo: Repo = Depends(get_repo),
                      ai=Depends(get_ai), today: date = Depends(get_today)):
    sc = repo.get(user.uid, "scenarios", scenario_id)
    if not sc:
        raise NotFound("scenario")
    proj = build_projection(repo, user.uid, today, sc["horizon_days"])
    _need_complete(proj)
    dis = body.disruptions if body.disruptions is not None else _DIS.validate_python(sc["disruptions"])
    run = _run(repo, user.uid, sc, proj, dis, ai, body.explain)
    if body.disruptions is None:
        sc["last_summary"] = run["summary"]
        sc["updated_at"] = now_iso()
        repo.put(user.uid, "scenarios", scenario_id, sc)
    audit(repo, user.uid, "scenario.simulate", scenario_id)
    return run


@router.post("/scenarios/{scenario_id}/compare")
def compare_scenario(scenario_id: str, body: CompareIn, user: Principal = Depends(ai_limited), repo: Repo = Depends(get_repo),
                     ai=Depends(get_ai), today: date = Depends(get_today)):
    sc = repo.get(user.uid, "scenarios", scenario_id)
    if not sc:
        raise NotFound("scenario")
    proj = build_projection(repo, user.uid, today, sc["horizon_days"])
    _need_complete(proj)
    risk = _DIS.validate_python(sc["disruptions"])
    base_in = proj.sim_input
    risk_in = base_in.model_copy(update={"disruptions": risk})
    out = {"baseline_vs_risk": compare(base_in, risk_in)}
    if body.alternative_disruptions is not None:
        alt_in = base_in.model_copy(update={"disruptions": body.alternative_disruptions})
        out["risk_vs_alternative"] = compare(risk_in, alt_in)
        target = alt_in
    else:
        target = risk_in
    sens = sensitivity(target)

    def slim(c):
        d = c.model_dump(mode="json")
        d["baseline"]["ledger"] = []
        d["alternative"]["ledger"] = d["alternative"]["ledger"][:MAX_STORED_LEDGER]
        return d

    resp = {k: slim(v) for k, v in out.items()}
    resp["sensitivity"] = [s.model_dump(mode="json") for s in sens]
    resp["labels"] = {"baseline": "projection from your records", "risk": "hypothetical scenario (not a forecast)",
                      "alternative": "user-modified what-if", "numbers": "simulated_by_engine"}
    if body.explain:
        cmp_ = out["baseline_vs_risk"]
        facts = {**result_summary(cmp_.alternative, proj.labels), "scenario_title": sc["title"],
                 "baseline_lowest_balance_minor": cmp_.baseline.lowest_balance_minor}
        resp["explanation"], resp["explanation_source"] = guarded_explanation(ai, facts)
    resp["labels"]["live_ai"] = bool(resp.get("explanation_source") == "gemini")
    audit(repo, user.uid, "scenario.compare", scenario_id)
    return resp


@router.post("/scenarios/{scenario_id}/interventions")
def interventions(scenario_id: str, user: Principal = Depends(current_user), repo: Repo = Depends(get_repo),
                  today: date = Depends(get_today)):
    sc = repo.get(user.uid, "scenarios", scenario_id)
    if not sc:
        raise NotFound("scenario")
    proj = build_projection(repo, user.uid, today, sc["horizon_days"])
    _need_complete(proj)
    risk = _DIS.validate_python(sc["disruptions"])
    base_in = proj.sim_input.model_copy(update={"disruptions": risk})
    cur = simulate(base_in)
    if not cur.shortfall:
        return {"shortfall": None, "candidates": [], "note": "No projected shortfall under this scenario; no intervention needed."}
    s = cur.shortfall
    cands: list[tuple[str, str, list, list[str], list[str]]] = []
    cands.append(("Hold a larger cash reserve",
                  f"Keep an additional {cur.currency} {to_major_str(s.max_deficit_minor, cur.currency)} available before {s.first_date}.",
                  [ReserveTopUp(amount_minor=s.max_deficit_minor)],
                  ["Requires you to have or free up this cash; it may not be possible without other trade-offs."],
                  ["You must confirm you can actually hold this amount."]))
    if any(e.kind.value == "discretionary_expense" for e in base_in.events):
        cands.append(("Pause discretionary spending", "Reduce discretionary expenses by 100% for the horizon.",
                      [SpendingCut(percent_bps=10000)], ["Lifestyle trade-off; savings only if spending was actually planned."], []))
    at_risk = [e for e in cur.ledger if e.event_id in s.obligations_at_risk]
    if at_risk:
        big = max(at_risk, key=lambda e: abs(e.delta_minor))
        later_inflows = [e.date for e in cur.ledger if e.delta_minor > 0 and e.date >= s.first_date]
        if later_inflows:
            days = (min(later_inflows) - big.date).days
            if 0 < days <= 60:
                cands.append((f"Ask to move '{big.label}' by {days} days",
                              "Request a later due date so the payment falls after your next inflow.",
                              [ShiftEvent(event_id=big.event_id, days=days)],
                              ["The provider may refuse, charge a fee, or report the delay; none is modelled."],
                              [f"The provider of '{big.label}' must agree. No approval is assumed."]))
    if any(e.grace_days for e in base_in.events):
        cands.append(("Use known grace periods", "Pay obligations at the end of their documented grace periods.",
                      [UseGracePeriods()], ["Grace terms must match your contract; late fees or credit impact are not modelled."],
                      ["Confirm the grace period with the lender."]))
    out = []
    for title, desc, extra, tradeoffs, actions in cands:
        r = simulate(base_in.model_copy(update={"disruptions": [*risk, *extra]}))
        rs = r.shortfall
        out.append({"title": title, "description": desc, "assumptions": [a for a in r.assumptions_applied[len(risk):]],
                    "remaining_shortfall_minor": rs.max_deficit_minor if rs else 0,
                    "first_shortfall_date": rs.first_date.isoformat() if rs else None,
                    "lowest_balance_minor": r.lowest_balance_minor, "improvement_minor": s.max_deficit_minor - (rs.max_deficit_minor if rs else 0),
                    "resolves_shortfall": rs is None, "trade_offs": tradeoffs,
                    "required_user_actions": actions + r.requires_external_confirmation,
                    "excluded_or_unknown": r.excluded_or_unknown,
                    "daily": [{"date": d.date.isoformat(), "closing_minor": d.closing_minor} for d in r.daily],
                    "disruptions": [d.model_dump(mode="json") for d in extra]})
    out.sort(key=lambda x: x["remaining_shortfall_minor"])
    return {"shortfall": result_summary(cur, proj.labels)["shortfall"], "candidates": out,
            "note": "Interventions are simulated what-ifs. CASCADE never moves money, changes payments or contacts providers."}


@router.delete("/scenarios/{scenario_id}", status_code=204)
def delete_scenario(scenario_id: str, user: Principal = Depends(current_user), repo: Repo = Depends(get_repo)):
    if not repo.get(user.uid, "scenarios", scenario_id):
        raise NotFound("scenario")
    for r in all_docs(repo, user.uid, "simulation_runs", {"scenario_id": scenario_id}):
        repo.delete(user.uid, "simulation_runs", r["id"])
    repo.delete(user.uid, "scenarios", scenario_id)
    audit(repo, user.uid, "scenario.delete", scenario_id)
