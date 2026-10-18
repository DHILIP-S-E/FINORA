"""Alerts, notification preferences, documents, account, demo and scheduled jobs."""
from __future__ import annotations

import hmac
import re
from datetime import date
from typing import Optional

from fastapi import APIRouter, Depends, File, Header, Query, Request, UploadFile

from ..ai.schemas import AIUnavailable
from ..config import Settings
from ..deps import get_cfg, get_ai, get_notifier, get_repo, get_storage, get_today
from ..errors import ApiError, NotFound
from ..repo import COLLECTIONS, SCHEMA_VERSION, Repo, now_iso
from ..schemas import AlertPatch, DocumentConfirmIn, NotificationPrefsIn
from ..security import Principal, ai_limited, current_user
from ..services.alerts import evaluate_user
from ..services.demo import reset_user_data, seed_demo
from ..services.projection import all_docs, audit, new_id

router = APIRouter(prefix="/api/v1", tags=["misc"])

# ---------------- alerts ----------------
@router.get("/alerts")
def list_alerts(unread_only: bool = False, limit: int = Query(50, ge=1, le=200), cursor: Optional[str] = None,
                user: Principal = Depends(current_user), repo: Repo = Depends(get_repo)):
    items, nxt = repo.list(user.uid, "alerts", limit, cursor, {"read": False} if unread_only else None)
    items = [a for a in items if not a.get("dismissed")]
    return {"items": list(reversed(items)), "next_cursor": nxt}


@router.patch("/alerts/{alert_id}")
def patch_alert(alert_id: str, body: AlertPatch, user: Principal = Depends(current_user), repo: Repo = Depends(get_repo)):
    a = repo.get(user.uid, "alerts", alert_id)
    if not a:
        raise NotFound("alert")
    a.update(body.model_dump(exclude_unset=True, exclude_none=True))
    repo.put(user.uid, "alerts", alert_id, a)
    return a


@router.get("/notification-preferences")
def get_prefs(user: Principal = Depends(current_user), repo: Repo = Depends(get_repo)):
    from ..services.alerts import DEFAULT_PREFS
    p = repo.get(user.uid, "notification_preferences", "main") or {}
    return {**DEFAULT_PREFS, **p}


@router.put("/notification-preferences")
def put_prefs(body: NotificationPrefsIn, user: Principal = Depends(current_user), repo: Repo = Depends(get_repo)):
    doc = {**body.model_dump(mode="json"), "id": "main", "uid": user.uid, "schema_version": SCHEMA_VERSION,
           "created_at": now_iso(), "updated_at": now_iso()}
    repo.put(user.uid, "notification_preferences", "main", doc)
    audit(repo, user.uid, "prefs.update")
    return doc


# ---------------- documents ----------------
ALLOWED = {"application/pdf": b"%PDF", "image/png": b"\x89PNG", "image/jpeg": b"\xff\xd8\xff", "image/webp": b"RIFF"}


def _safe_name(n: str) -> str:
    n = re.sub(r"[^A-Za-z0-9._ -]", "_", n.split("/")[-1].split("\\")[-1])
    return n[:100] or "document"


@router.post("/documents", status_code=201)
async def upload_document(request: Request, file: UploadFile = File(...), user: Principal = Depends(current_user),
                          repo: Repo = Depends(get_repo), storage=Depends(get_storage), s: Settings = Depends(get_cfg)):
    mime = (file.content_type or "").lower()
    if mime not in ALLOWED:
        raise ApiError(415, "unsupported_type", "Only PDF, PNG, JPEG or WebP files are supported.")
    data = await file.read(s.max_upload_bytes + 1)
    if len(data) > s.max_upload_bytes:
        raise ApiError(413, "file_too_large", f"Maximum size is {s.max_upload_bytes // (1024 * 1024)} MB.")
    if not data.startswith(ALLOWED[mime]):  # trust content, not the declared type
        raise ApiError(415, "content_mismatch", "File content does not match its declared type.")
    did = new_id()
    path = f"users/{user.uid}/documents/{did}/original"
    storage.put(path, data, mime)
    doc = {"id": did, "uid": user.uid, "filename": _safe_name(file.filename or "document"), "mime": mime, "size": len(data),
           "storage_path": path, "status": "uploaded", "created_at": now_iso(), "updated_at": now_iso(),
           "schema_version": SCHEMA_VERSION}
    repo.put(user.uid, "documents", did, doc)
    audit(repo, user.uid, "document.upload", did)
    return doc


def _doc(repo, uid, did):
    d = repo.get(uid, "documents", did)
    if not d:
        raise NotFound("document")
    return d


_DATE = re.compile(r"\d{1,4}[-/.]\d{1,2}[-/.]\d{1,4}|\d{1,2}\s+\w+\s+\d{4}|\w+\s+\d{1,2},?\s+\d{4}")


def _validate_terms(terms) -> list[dict]:
    out = []
    for t in terms:
        issues = []
        v = (t.value or "").strip()
        if t.status == "found" and not v:
            issues.append("found but empty")
        if t.field_name in ("principal_amount", "payment_amount", "processing_fee", "insurance_premium") and v:
            num = re.sub(r"[^\d.]", "", v)
            if not num or num.count(".") > 1:
                issues.append("amount not parseable")
        if t.field_name == "interest_rate_pct" and v:
            try:
                if not 0 <= float(re.sub(r"[^\d.]", "", v) or "x") <= 100:
                    issues.append("rate outside 0-100%")
            except ValueError:
                issues.append("rate not parseable")
        if t.field_name in ("first_payment_date", "premium_due_date", "other_payment_date") and v and not _DATE.search(v):
            issues.append("date not recognised")
        if t.status == "found" and not t.excerpt:
            issues.append("no source excerpt")
        out.append({**t.model_dump(), "validation_issues": issues, "needs_user_input": t.status != "found" or bool(issues)})
    return out


@router.get("/documents")
def list_documents(user: Principal = Depends(current_user), repo: Repo = Depends(get_repo)):
    items, _ = repo.list(user.uid, "documents", 100)
    return {"items": items, "next_cursor": None}


@router.get("/documents/{document_id}")
def get_document(document_id: str, user: Principal = Depends(current_user), repo: Repo = Depends(get_repo)):
    return {"document": _doc(repo, user.uid, document_id), "extraction": repo.get(user.uid, "document_extractions", document_id)}


@router.post("/documents/{document_id}/extract")
def extract_document(document_id: str, user: Principal = Depends(ai_limited), repo: Repo = Depends(get_repo),
                     ai=Depends(get_ai), storage=Depends(get_storage)):
    d = _doc(repo, user.uid, document_id)
    if d["status"] == "confirmed":
        raise ApiError(409, "already_confirmed", "This document's terms were already confirmed.")
    data = storage.get(d["storage_path"])
    if data is None:
        raise NotFound("document file")
    repo.put(user.uid, "documents", document_id, {**d, "status": "processing", "updated_at": now_iso()})
    try:
        ex = ai.extract(data, d["mime"])
    except AIUnavailable as e:
        repo.put(user.uid, "documents", document_id, {**d, "status": "failed", "error": str(e)[:200], "updated_at": now_iso()})
        raise ApiError(503, "ai_unavailable", "Document extraction is unavailable. You can retry later or enter the terms manually.",
                       {"reason": str(e)[:160]})
    cur = repo.get(user.uid, "documents", document_id)
    if cur and cur["status"] == "cancelled":
        raise ApiError(409, "cancelled", "Extraction was cancelled.")
    rec = {"id": document_id, "uid": user.uid, "document_id": document_id, "document_type": ex.document_type,
           "terms": _validate_terms(ex.terms), "conflicts": ex.conflicts, "missing_information": ex.missing_information,
           "suspected_prompt_injection": ex.suspected_prompt_injection, "provider": ai.name, "live_ai": ai.live,
           "review_required": True, "created_at": now_iso(), "schema_version": SCHEMA_VERSION}
    repo.put(user.uid, "document_extractions", document_id, rec)
    repo.put(user.uid, "documents", document_id, {**d, "status": "extracted", "updated_at": now_iso()})
    audit(repo, user.uid, "document.extract", document_id)
    return rec


@router.post("/documents/{document_id}/cancel")
def cancel_document(document_id: str, user: Principal = Depends(current_user), repo: Repo = Depends(get_repo)):
    d = _doc(repo, user.uid, document_id)
    if d["status"] in ("processing", "uploaded", "failed"):
        d = {**d, "status": "cancelled", "updated_at": now_iso()}
        repo.put(user.uid, "documents", document_id, d)
    return d


@router.post("/documents/{document_id}/confirm")
def confirm_document(document_id: str, body: DocumentConfirmIn, user: Principal = Depends(current_user), repo: Repo = Depends(get_repo)):
    d = _doc(repo, user.uid, document_id)
    if d["status"] != "extracted":
        raise ApiError(409, "not_extracted", "Extract and review the document before confirming.")
    created = []
    for r in body.records:  # the user's reviewed values, not the raw model output, become records
        rid, now = new_id(), now_iso()
        doc = {**r.model_dump(mode="json"), "id": rid, "uid": user.uid, "source": "document",
               "source_ref": {**(r.source_ref or {}), "document_id": document_id}, "schema_version": SCHEMA_VERSION,
               "created_at": now, "updated_at": now}
        repo.put(user.uid, "financial_records", rid, doc)
        created.append(doc)
    repo.put(user.uid, "documents", document_id, {**d, "status": "confirmed", "updated_at": now_iso()})
    audit(repo, user.uid, "document.confirm", document_id)
    return {"records": created}


@router.delete("/documents/{document_id}", status_code=204)
def delete_document(document_id: str, user: Principal = Depends(current_user), repo: Repo = Depends(get_repo),
                    storage=Depends(get_storage)):
    d = _doc(repo, user.uid, document_id)
    storage.delete(d["storage_path"])
    repo.delete(user.uid, "document_extractions", document_id)
    repo.delete(user.uid, "documents", document_id)
    audit(repo, user.uid, "document.delete", document_id)


# ---------------- demo ----------------
@router.post("/demo/seed")
def demo_seed(user: Principal = Depends(current_user), repo: Repo = Depends(get_repo), today: date = Depends(get_today)):
    return seed_demo(repo, user.uid, today)


@router.post("/demo/reset", status_code=204)
def demo_reset(user: Principal = Depends(current_user), repo: Repo = Depends(get_repo)):
    p = repo.get_user(user.uid) or {}
    if not p.get("is_demo"):
        raise ApiError(409, "not_demo", "Only demo data can be reset with this action.")
    reset_user_data(repo, user.uid)
    repo.put_user(user.uid, {**p, "opening_balance_minor": None, "balance_as_of": None, "is_demo": False,
                             "onboarding_complete": False, "display_name": None})


# ---------------- account ----------------
@router.post("/account/export")
def export_account(user: Principal = Depends(current_user), repo: Repo = Depends(get_repo)):
    data = {"exported_at": now_iso(), "profile": repo.get_user(user.uid)}
    for coll in COLLECTIONS:
        if coll == "idempotency":
            continue
        data[coll] = all_docs(repo, user.uid, coll)
    audit(repo, user.uid, "account.export")
    return data


@router.delete("/account", status_code=202)
def delete_account(user: Principal = Depends(current_user), repo: Repo = Depends(get_repo), storage=Depends(get_storage),
                   s: Settings = Depends(get_cfg)):
    """Deletes Firestore data and uploaded files, then the Firebase Auth user. Audit entries are removed too."""
    storage.delete_prefix(f"users/{user.uid}/")
    repo.delete_user(user.uid)
    auth_deleted = False
    if s.auth_mode == "firebase":
        try:
            from firebase_admin import auth
            auth.delete_user(user.uid)
            auth_deleted = True
        except Exception:  # noqa: BLE001
            pass
    return {"status": "deleted", "data_deleted": True, "files_deleted": True, "auth_user_deleted": auth_deleted}


# ---------------- scheduled job ----------------
def _job_authorised(authorization: Optional[str], x_job_token: Optional[str], s: Settings) -> bool:
    if s.scheduler_audience and authorization and authorization.lower().startswith("bearer "):
        try:
            from google.auth.transport import requests as greq
            from google.oauth2 import id_token
            id_token.verify_oauth2_token(authorization[7:], greq.Request(), audience=s.scheduler_audience)
            return True
        except Exception:  # noqa: BLE001
            return False
    return bool(s.job_token and x_job_token and hmac.compare_digest(s.job_token, x_job_token))


@router.post("/internal/jobs/refresh", include_in_schema=False)
def refresh_job(authorization: Optional[str] = Header(default=None), x_job_token: Optional[str] = Header(default=None),
                repo: Repo = Depends(get_repo), notifier=Depends(get_notifier), today: date = Depends(get_today),
                s: Settings = Depends(get_cfg), max_users: int = Query(500, ge=1, le=5000)):
    """Run by Cloud Scheduler. Deterministic engine only: no Gemini calls, so cost is bounded."""
    if not _job_authorised(authorization, x_job_token, s):
        raise ApiError(401, "unauthorised", "Job authentication failed")
    done = alerts = failures = 0
    for uid in repo.list_user_ids()[:max_users]:
        try:
            alerts += len(evaluate_user(repo, uid, today, notifier))
            done += 1
        except Exception:  # noqa: BLE001 - one bad user must not stop the batch
            failures += 1
    return {"users_processed": done, "alerts_created": alerts, "failures": failures}
