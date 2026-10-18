"""Synthetic demo persona: fictional freelancer. All values are fabricated for demonstration."""
from __future__ import annotations

from datetime import date, datetime, timedelta, timezone

from ..repo import Repo, SCHEMA_VERSION, now_iso
from .projection import audit, new_id

DEMO_NAME = "Asha (synthetic demo user)"


def _rec(**kw) -> dict:
    return {"currency": "INR", "frequency": "monthly", "category": None, "end_date": None, "interval_days": None,
            "grace_days": None, "discretionary": False, "variable_rate": False, "estimated": False,
            "verification": "demo", "source": "demo", "source_ref": None, "notes": "Synthetic demo data", **kw}


def seed_demo(repo: Repo, uid: str, today: date) -> dict:
    reset_user_data(repo, uid)
    d = lambda n: (today + timedelta(days=n)).isoformat()  # noqa: E731
    now = now_iso()
    repo.put_user(uid, {"uid": uid, "display_name": DEMO_NAME, "currency": "INR", "opening_balance_minor": 42_000_00,
                        "balance_as_of": today.isoformat(), "monthly_essential_minor": 30_000_00,
                        "reserve_target_minor": 60_000_00, "onboarding_complete": True, "is_demo": True,
                        "schema_version": SCHEMA_VERSION, "created_at": now, "updated_at": now})
    specs = [
        ("client_a", dict(name="Client A - design retainer", type="income", amount_minor=60_000_00, start_date=d(6), estimated=True,
                          notes="Synthetic: client usually pays near the 6th, sometimes late")),
        ("client_b", dict(name="Client B - project payment", type="income", amount_minor=25_000_00, start_date=d(40), frequency="once", estimated=True)),
        ("essentials", dict(name="Household essentials", type="recurring_expense", amount_minor=12_000_00, start_date=d(3), category="groceries")),
        ("rent", dict(name="Rent", type="recurring_expense", amount_minor=18_000_00, start_date=d(9), category="housing")),
        ("loan", dict(name="Personal loan EMI", type="loan", amount_minor=22_000_00, start_date=d(8), category="loan",
                      notes="Synthetic: grace period unknown - add it for a better simulation")),
        ("card", dict(name="Credit card payment", type="credit_card", amount_minor=15_000_00, start_date=d(11), grace_days=3)),
        ("insurance", dict(name="Health insurance premium", type="insurance", amount_minor=3_200_00, start_date=d(15))),
        ("repair", dict(name="Laptop repair (estimated)", type="one_time_expense", amount_minor=14_000_00, start_date=d(10),
                        frequency="once", estimated=True, category="unexpected")),
        ("savings", dict(name="Emergency savings", type="emergency_savings", amount_minor=20_000_00, start_date=None, frequency="once")),
    ]
    ids = {}
    t0 = datetime.now(timezone.utc)
    for i, (key, kw) in enumerate(specs):  # strictly increasing timestamps => stable list order
        rid = new_id()
        ids[key] = rid
        ts = (t0 + timedelta(microseconds=i)).isoformat()
        repo.put(uid, "financial_records", rid, {**_rec(**kw), "id": rid, "uid": uid, "schema_version": SCHEMA_VERSION,
                                                  "created_at": ts, "updated_at": ts})
    sid = new_id()
    repo.put(uid, "scenarios", sid, {
        "id": sid, "uid": uid, "title": "Client A pays 10 days late", "origin": "demo", "horizon_days": 60,
        "summary": "Demo scenario: the retainer lands 10 days late while rent, EMI, card and insurance stay due.",
        "disruptions": [{"type": "income_delay", "record_id": ids["client_a"], "days": 10}],
        "assumptions": ["Delay of 10 days (illustrative)", "No overdraft, deferral or grace relied upon"],
        "uncertainties": ["Actual delay is unknown"], "source_record_ids": [ids["client_a"], ids["rent"], ids["loan"], ids["card"]],
        "validation_status": "validated", "created_at": now, "updated_at": now, "schema_version": SCHEMA_VERSION})
    audit(repo, uid, "demo.seed")
    return {"record_ids": ids, "scenario_id": sid}


def reset_user_data(repo: Repo, uid: str) -> None:
    from ..repo import COLLECTIONS
    for coll in COLLECTIONS:
        if coll in ("audit_events", "notification_preferences"):
            continue
        cur = None
        while True:
            page, cur = repo.list(uid, coll, 200, None)
            for row in page:
                repo.delete(uid, coll, row["id"])
            if not page or not cur:
                break
