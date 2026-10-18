"""Profile, financial records, cash-flow events and the cash-flow projection."""
from __future__ import annotations

from datetime import date, timedelta
from typing import Optional

from fastapi import APIRouter, Depends, Header, Query

from ..deps import get_notifier, get_repo, get_today
from ..engine import simulate
from ..errors import ApiError, NotFound
from ..repo import SCHEMA_VERSION, Repo, now_iso
from ..schemas import (
    CashflowEventIn, CashflowEventPatch, ProfileIn, RecordIn, RecordPatch,
)
from ..security import Principal, current_user
from ..services.alerts import evaluate_user
from ..services.projection import all_docs, audit, build_projection, new_id, result_summary

router = APIRouter(prefix="/api/v1", tags=["core"])


# ---------------- profile ----------------
@router.get("/profile")
def get_profile(user: Principal = Depends(current_user), repo: Repo = Depends(get_repo)):
    p = repo.get_user(user.uid)
    if p is None:
        p = {"uid": user.uid, "currency": "INR", "onboarding_complete": False, "opening_balance_minor": None,
             "balance_as_of": None, "is_demo": False, "schema_version": SCHEMA_VERSION}
    return p


@router.put("/profile")
def put_profile(body: ProfileIn, user: Principal = Depends(current_user), repo: Repo = Depends(get_repo),
                today: date = Depends(get_today)):
    existing = repo.get_user(user.uid) or {}
    data = {**existing, **body.model_dump(mode="json"), "uid": user.uid, "schema_version": SCHEMA_VERSION,
            "updated_at": now_iso(), "created_at": existing.get("created_at", now_iso()),
            "is_demo": existing.get("is_demo", False)}
    if body.opening_balance_minor is not None and body.balance_as_of is None:
        data["balance_as_of"] = today.isoformat()
    repo.put_user(user.uid, data)
    audit(repo, user.uid, "profile.update")
    return data


# ---------------- records ----------------
def _check_idem(repo: Repo, uid: str, key: Optional[str], scope: str) -> Optional[dict]:
    if not key:
        return None
    hit = repo.get(uid, "idempotency", f"{scope}:{key}"[:200])
    return hit["response"] if hit else None


def _store_idem(repo: Repo, uid: str, key: Optional[str], scope: str, response: dict) -> None:
    if key:
        i = f"{scope}:{key}"[:200]
        repo.put(uid, "idempotency", i, {"id": i, "response": response, "created_at": now_iso()})


@router.get("/records")
def list_records(type: Optional[str] = None, limit: int = Query(50, ge=1, le=200), cursor: Optional[str] = None,
                 user: Principal = Depends(current_user), repo: Repo = Depends(get_repo)):
    items, nxt = repo.list(user.uid, "financial_records", limit, cursor, {"type": type} if type else None)
    return {"items": items, "next_cursor": nxt}


@router.post("/records", status_code=201)
def create_record(body: RecordIn, idempotency_key: Optional[str] = Header(default=None),
                  user: Principal = Depends(current_user), repo: Repo = Depends(get_repo)):
    if (prev := _check_idem(repo, user.uid, idempotency_key, "record")):
        return prev
    rid, now = new_id(), now_iso()
    doc = {**body.model_dump(mode="json"), "id": rid, "uid": user.uid, "schema_version": SCHEMA_VERSION,
           "created_at": now, "updated_at": now}
    repo.put(user.uid, "financial_records", rid, doc)
    _store_idem(repo, user.uid, idempotency_key, "record", doc)
    audit(repo, user.uid, "record.create", rid)
    return doc


@router.get("/records/{record_id}")
def get_record(record_id: str, user: Principal = Depends(current_user), repo: Repo = Depends(get_repo)):
    r = repo.get(user.uid, "financial_records", record_id)
    if not r:
        raise NotFound("record")
    return r


@router.patch("/records/{record_id}")
def patch_record(record_id: str, body: RecordPatch, user: Principal = Depends(current_user), repo: Repo = Depends(get_repo)):
    r = repo.get(user.uid, "financial_records", record_id)
    if not r:
        raise NotFound("record")
    merged = {**r, **body.model_dump(mode="json", exclude_unset=True)}
    try:  # re-validate the merged record as a whole
        RecordIn.model_validate({k: v for k, v in merged.items() if k in RecordIn.model_fields})
    except Exception as e:  # noqa: BLE001
        raise ApiError(422, "validation_error", "Updated record is not valid", {"reason": str(e)[:200]})
    merged["updated_at"] = now_iso()
    if "amount_minor" in body.model_fields_set or "start_date" in body.model_fields_set:
        merged["verification"] = body.verification.value if body.verification else "user_provided"
    repo.put(user.uid, "financial_records", record_id, merged)
    audit(repo, user.uid, "record.update", record_id)
    return merged


@router.delete("/records/{record_id}", status_code=204)
def delete_record(record_id: str, user: Principal = Depends(current_user), repo: Repo = Depends(get_repo)):
    if not repo.get(user.uid, "financial_records", record_id):
        raise NotFound("record")
    repo.delete(user.uid, "financial_records", record_id)
    for ev in all_docs(repo, user.uid, "cashflow_events", {"record_id": record_id}):
        repo.delete(user.uid, "cashflow_events", ev["id"])
    audit(repo, user.uid, "record.delete", record_id)


# ---------------- cash-flow events (one-offs and per-occurrence overrides) ----------------
@router.get("/cashflow/events")
def list_events(include_deleted: bool = False, limit: int = Query(100, ge=1, le=200), cursor: Optional[str] = None,
                user: Principal = Depends(current_user), repo: Repo = Depends(get_repo)):
    items, nxt = repo.list(user.uid, "cashflow_events", limit, cursor)
    if not include_deleted:
        items = [i for i in items if not i.get("deleted")]
    return {"items": items, "next_cursor": nxt}


@router.post("/cashflow/events", status_code=201)
def create_event(body: CashflowEventIn, idempotency_key: Optional[str] = Header(default=None),
                 user: Principal = Depends(current_user), repo: Repo = Depends(get_repo)):
    if (prev := _check_idem(repo, user.uid, idempotency_key, "event")):
        return prev
    if body.record_id:
        if not repo.get(user.uid, "financial_records", body.record_id):
            raise NotFound("record")
        if not body.original_date:
            raise ApiError(422, "validation_error", "original_date is required when overriding a recurring record")
    eid, now = new_id(), now_iso()
    doc = {**body.model_dump(mode="json"), "id": eid, "uid": user.uid, "deleted": False, "previous": None,
           "source": "manual", "schema_version": SCHEMA_VERSION, "created_at": now, "updated_at": now}
    repo.put(user.uid, "cashflow_events", eid, doc)
    _store_idem(repo, user.uid, idempotency_key, "event", doc)
    audit(repo, user.uid, "event.create", eid)
    return doc


@router.patch("/cashflow/events/{event_id}")
def patch_event(event_id: str, body: CashflowEventPatch, user: Principal = Depends(current_user), repo: Repo = Depends(get_repo)):
    ev = repo.get(user.uid, "cashflow_events", event_id)
    if not ev or ev.get("deleted"):
        raise NotFound("event")
    snapshot = {k: v for k, v in ev.items() if k != "previous"}
    new = {**ev, **body.model_dump(mode="json", exclude_unset=True), "previous": snapshot, "updated_at": now_iso()}
    repo.put(user.uid, "cashflow_events", event_id, new)
    audit(repo, user.uid, "event.update", event_id)
    return new


@router.delete("/cashflow/events/{event_id}", status_code=204)
def delete_event(event_id: str, user: Principal = Depends(current_user), repo: Repo = Depends(get_repo)):
    ev = repo.get(user.uid, "cashflow_events", event_id)
    if not ev:
        raise NotFound("event")
    snapshot = {k: v for k, v in ev.items() if k != "previous"}
    repo.put(user.uid, "cashflow_events", event_id, {**ev, "deleted": True, "previous": snapshot, "updated_at": now_iso()})
    audit(repo, user.uid, "event.delete", event_id)


@router.post("/cashflow/events/{event_id}/undo")
def undo_event(event_id: str, user: Principal = Depends(current_user), repo: Repo = Depends(get_repo)):
    ev = repo.get(user.uid, "cashflow_events", event_id)
    if not ev or not ev.get("previous"):
        raise ApiError(409, "nothing_to_undo", "No previous version to restore")
    restored = {**ev["previous"], "previous": None, "updated_at": now_iso()}
    repo.put(user.uid, "cashflow_events", event_id, restored)
    audit(repo, user.uid, "event.undo", event_id)
    return restored


# ---------------- projection ----------------
@router.get("/cashflow")
def cashflow(horizon_days: int = Query(60, ge=7, le=365), user: Principal = Depends(current_user),
             repo: Repo = Depends(get_repo), today: date = Depends(get_today)):
    proj = build_projection(repo, user.uid, today, horizon_days)
    res = simulate(proj.sim_input)
    profile = repo.get_user(user.uid) or {}
    ledger = [{**e.model_dump(mode="json"), "obligation_label": proj.labels.get(e.event_id.split("@")[0], e.label),
               "source_record_id": e.event_id.split("@")[0]} for e in res.ledger][:600]
    weekly: dict[str, dict] = {}
    monthly: dict[str, dict] = {}
    for e in res.ledger:
        for bucket, key in ((weekly, (e.date - timedelta(days=e.date.weekday())).isoformat()), (monthly, e.date.strftime("%Y-%m"))):
            b = bucket.setdefault(key, {"period": key, "inflow_minor": 0, "outflow_minor": 0})
            b["inflow_minor" if e.delta_minor > 0 else "outflow_minor"] += abs(e.delta_minor)
    for bucket in (weekly, monthly):
        for k, b in bucket.items():
            last = [d for d in res.daily if (d.date.strftime("%Y-%m") == k if bucket is monthly else
                                             (d.date - timedelta(days=d.date.weekday())).isoformat() == k)]
            b["closing_minor"] = last[-1].closing_minor if last else None
    return {
        "actual_balance": {"amount_minor": profile.get("opening_balance_minor"), "as_of": profile.get("balance_as_of"),
                           "kind": "actual_user_reported", "stale_days": proj.stale_days},
        "projection": {"kind": "projected", "summary": result_summary(res, proj.labels),
                       "daily": [d.model_dump(mode="json") for d in res.daily],
                       "weekly": sorted(weekly.values(), key=lambda x: x["period"]),
                       "monthly": sorted(monthly.values(), key=lambda x: x["period"])},
        "events": ledger,
        "missing_information": proj.missing_info,
        "is_demo": bool(profile.get("is_demo")),
        "reserve_minor": proj.reserve_minor,
    }


@router.post("/cashflow/recalculate")
def recalculate(user: Principal = Depends(current_user), repo: Repo = Depends(get_repo), today: date = Depends(get_today),
                notifier=Depends(get_notifier)):
    new = evaluate_user(repo, user.uid, today, notifier)
    audit(repo, user.uid, "cashflow.recalculate")
    return {"new_alerts": new, "count": len(new)}
