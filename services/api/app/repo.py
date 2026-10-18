"""Repository abstraction. All data lives under users/{uid}/..., so ownership is structural.

Documents are stored as JSON-safe dicts (dates/timestamps as ISO-8601 strings).
"""
from __future__ import annotations

import copy
import threading
from datetime import datetime, timezone
from typing import Any, Optional, Protocol

SCHEMA_VERSION = 1
COLLECTIONS = [
    "financial_records", "cashflow_events", "documents", "document_extractions", "scenarios",
    "simulation_runs", "alerts", "notification_preferences", "audit_events", "idempotency",
]


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


class Repo(Protocol):
    def get_user(self, uid: str) -> Optional[dict]: ...
    def put_user(self, uid: str, data: dict) -> None: ...
    def get(self, uid: str, coll: str, id: str) -> Optional[dict]: ...
    def put(self, uid: str, coll: str, id: str, data: dict) -> None: ...
    def delete(self, uid: str, coll: str, id: str) -> None: ...
    def list(self, uid: str, coll: str, limit: int = 50, after: Optional[str] = None,
             where: Optional[dict[str, Any]] = None) -> tuple[list[dict], Optional[str]]: ...
    def list_user_ids(self) -> list[str]: ...
    def delete_user(self, uid: str) -> None: ...


class MemoryRepo:
    def __init__(self) -> None:
        self._users: dict[str, dict] = {}
        self._data: dict[tuple[str, str], dict[str, dict]] = {}
        self._lock = threading.RLock()

    def get_user(self, uid):
        with self._lock:
            return copy.deepcopy(self._users.get(uid))

    def put_user(self, uid, data):
        with self._lock:
            self._users[uid] = copy.deepcopy(data)

    def get(self, uid, coll, id):
        with self._lock:
            return copy.deepcopy(self._data.get((uid, coll), {}).get(id))

    def put(self, uid, coll, id, data):
        with self._lock:
            self._data.setdefault((uid, coll), {})[id] = copy.deepcopy(data)

    def delete(self, uid, coll, id):
        with self._lock:
            self._data.get((uid, coll), {}).pop(id, None)

    def list(self, uid, coll, limit=50, after=None, where=None):
        with self._lock:
            rows = list(self._data.get((uid, coll), {}).items())
        rows.sort(key=lambda kv: (kv[1].get("created_at", ""), kv[0]))
        if where:
            rows = [kv for kv in rows if all(kv[1].get(k) == v for k, v in where.items())]
        if after:
            idx = next((i for i, kv in enumerate(rows) if kv[0] == after), -1)
            rows = rows[idx + 1:]
        page = rows[:limit]
        nxt = page[-1][0] if len(rows) > limit else None
        return [copy.deepcopy(v) for _, v in page], nxt

    def list_user_ids(self):
        with self._lock:
            return sorted(set(self._users) | {u for u, _ in self._data})

    def delete_user(self, uid):
        with self._lock:
            self._users.pop(uid, None)
            for k in [k for k in self._data if k[0] == uid]:
                del self._data[k]


class FirestoreRepo:
    """Cloud Firestore implementation (requires ADC / service identity on Cloud Run)."""

    def __init__(self, project: Optional[str] = None) -> None:
        from google.cloud import firestore  # lazy import
        self._fs = firestore
        self.db = firestore.Client(project=project)

    def _user(self, uid):
        return self.db.collection("users").document(uid)

    def get_user(self, uid):
        s = self._user(uid).get()
        return s.to_dict() if s.exists else None

    def put_user(self, uid, data):
        self._user(uid).set(data)

    def get(self, uid, coll, id):
        s = self._user(uid).collection(coll).document(id).get()
        return s.to_dict() if s.exists else None

    def put(self, uid, coll, id, data):
        self._user(uid).collection(coll).document(id).set(data)

    def delete(self, uid, coll, id):
        self._user(uid).collection(coll).document(id).delete()

    def list(self, uid, coll, limit=50, after=None, where=None):
        q = self._user(uid).collection(coll)
        for k, v in (where or {}).items():
            q = q.where(k, "==", v)
        q = q.order_by("created_at").order_by("__name__")
        if after:
            snap = self._user(uid).collection(coll).document(after).get()
            if snap.exists:
                q = q.start_after(snap)
        docs = list(q.limit(limit + 1).stream())
        page = docs[:limit]
        return [d.to_dict() for d in page], (page[-1].id if len(docs) > limit else None)

    def list_user_ids(self):
        return [d.id for d in self.db.collection("users").select([]).stream()]

    def delete_user(self, uid):
        u = self._user(uid)
        for coll in COLLECTIONS:
            for d in u.collection(coll).stream():
                d.reference.delete()
        u.delete()
