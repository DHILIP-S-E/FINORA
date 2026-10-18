"""Alert evaluation: deterministic engine only (no Gemini), deduplicated, rate-limited, quiet-hours aware.

Push payloads never contain amounts or account detail; they carry an alert id and scenario id for deep linking.
"""
from __future__ import annotations

import hashlib
from datetime import date, datetime, timedelta, timezone

from pydantic import TypeAdapter

from ..engine import Disruption, simulate
from ..repo import Repo, SCHEMA_VERSION, now_iso
from .projection import all_docs, build_projection, result_summary

MAX_PUSH_PER_DAY = 3
DEFAULT_PREFS = {"push_enabled": True, "min_shortfall_minor": 0, "quiet_hours": None, "utc_offset_minutes": 330,
                 "fcm_token": None, "alert_types": ["new_shortfall", "income_date_changed", "material_obligation",
                                                    "missing_information", "scenario_changed"]}


def _in_quiet_hours(prefs: dict, now: datetime) -> bool:
    q = prefs.get("quiet_hours")
    if not q:
        return False
    local = now + timedelta(minutes=prefs.get("utc_offset_minutes", 0))
    h, s, e = local.hour, q["start_hour"], q["end_hour"]
    return (s <= h < e) if s < e else (h >= s or h < e)


def _bucket(minor: int) -> int:
    return minor // 1_000_000  # 10,000 major units per bucket: ignore small drift


def _emit(repo: Repo, uid: str, prefs: dict, notifier, now: datetime, *, key: str, type_: str, title: str, body: str,
          why: str, scenario_id: str | None, push_title: str, push_body: str) -> dict | None:
    aid = hashlib.sha1(f"{uid}:{key}".encode()).hexdigest()[:24]
    if repo.get(uid, "alerts", aid):  # duplicate suppression
        return None
    alert = {"id": aid, "uid": uid, "type": type_, "title": title, "body": body, "why": why, "scenario_id": scenario_id,
             "dedupe_key": key, "read": False, "dismissed": False, "push_sent": False, "push_suppressed_reason": None,
             "created_at": now.isoformat(), "schema_version": SCHEMA_VERSION}
    token = prefs.get("fcm_token")
    if type_ not in prefs.get("alert_types", []):
        alert["push_suppressed_reason"] = "type_disabled"
    elif not prefs.get("push_enabled") or not token:
        alert["push_suppressed_reason"] = "push_disabled_or_no_token"
    elif _in_quiet_hours(prefs, now):
        alert["push_suppressed_reason"] = "quiet_hours"
    else:
        recent = [a for a in all_docs(repo, uid, "alerts", {"push_sent": True})
                  if datetime.fromisoformat(a["created_at"]) > now - timedelta(days=1)]
        if len(recent) >= MAX_PUSH_PER_DAY:
            alert["push_suppressed_reason"] = "daily_push_limit"
        else:
            data = {"alert_id": aid, "type": type_}
            if scenario_id:
                data["scenario_id"] = scenario_id
            alert["push_sent"] = bool(notifier.send(token, push_title, push_body, data))
    repo.put(uid, "alerts", aid, alert)
    return alert


def evaluate_user(repo: Repo, uid: str, today: date, notifier, now: datetime | None = None) -> list[dict]:
    now = now or datetime.now(timezone.utc)
    prefs = {**DEFAULT_PREFS, **(repo.get(uid, "notification_preferences", "main") or {})}
    proj = build_projection(repo, uid, today)
    new: list[dict] = []

    def emit(**kw):
        a = _emit(repo, uid, prefs, notifier, now, **kw)
        if a:
            new.append(a)

    if proj.sim_input.opening_balance_minor is None:
        emit(key="missing:opening_balance", type_="missing_information", title="Add your cash balance",
             body="A projection can't be calculated without your current cash balance.",
             why="Opening balance is missing, so no reliable simulation can run.", scenario_id=None,
             push_title="Information needed", push_body="Add your cash balance to keep your projection reliable.")
        return new

    base = simulate(proj.sim_input)
    s = base.shortfall
    if s and s.max_deficit_minor >= prefs["min_shortfall_minor"]:
        names = ", ".join(sorted({proj.labels.get(e.split('@')[0], e) for e in s.obligations_at_risk})[:3])
        emit(key=f"shortfall:{s.first_date}:{_bucket(s.max_deficit_minor)}", type_="new_shortfall",
             title="Possible cash shortfall ahead",
             body=f"Based on your records, cash could fall below zero around {s.first_date}. Payments affected: {names}.",
             why="Your scheduled income and obligations, run through the deterministic projection, show the balance "
                 "dipping below zero. Estimates and unconfirmed dates may change this.",
             scenario_id=None, push_title="Possible cash shortfall", push_body="Open CASCADE to review the projection.")
    if len(proj.missing_info) and base.complete:
        digest = hashlib.sha1("|".join(sorted(proj.missing_info)).encode()).hexdigest()[:10]
        emit(key=f"missing:{digest}", type_="missing_information", title="Some information is missing",
             body=proj.missing_info[0] + (f" (+{len(proj.missing_info) - 1} more)" if len(proj.missing_info) > 1 else ""),
             why="Unknown contract terms or stale data limit how reliable the simulation is.", scenario_id=None,
             push_title="Information needed", push_body="Some details are missing for a reliable projection.")

    adapter = TypeAdapter(list[Disruption])
    for sc in all_docs(repo, uid, "scenarios"):
        dis = adapter.validate_python(sc.get("disruptions", []))
        r = simulate(proj.sim_input.model_copy(update={"disruptions": dis}))
        prev_summary = sc.get("last_summary")
        prev = (prev_summary or {}).get("shortfall")
        cur = r.shortfall
        changed = prev_summary is not None and (
            (cur is None) != (prev is None)
            or (cur and prev and (prev["first_date"] != cur.first_date.isoformat()
                                  or _bucket(prev["max_deficit_minor"]) != _bucket(cur.max_deficit_minor))))
        if changed and cur and cur.max_deficit_minor >= prefs["min_shortfall_minor"]:
            emit(key=f"scn:{sc['id']}:{cur.first_date}:{_bucket(cur.max_deficit_minor)}", type_="scenario_changed",
                 title=f"Scenario update: {sc['title']}",
                 body=f"Under this what-if, cash could go negative around {cur.first_date}.",
                 why="Your records changed, so the saved scenario was re-run and its outcome differs from before. "
                     "It is a hypothetical, not a forecast.",
                 scenario_id=sc["id"], push_title="Scenario outcome changed", push_body="Open CASCADE to review.")
        sc["last_summary"] = result_summary(r, proj.labels)
        repo.put(uid, "scenarios", sc["id"], sc)
    return new
