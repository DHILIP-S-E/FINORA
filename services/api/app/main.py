from __future__ import annotations

from datetime import date
from typing import Callable, Optional

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware

from . import errors
from .ai.provider import AIProvider, build_provider
from .config import Settings, get_settings
from .infra import FcmNotifier, GcsStorage, LocalStorage, NoopNotifier
from .logging_setup import setup_logging
from .ratelimit import RateLimiter
from .repo import FirestoreRepo, MemoryRepo, Repo
from .routers import assistant, core, misc, scenarios
from .security import TokenVerifier, build_verifier


def create_app(settings: Optional[Settings] = None, *, repo: Optional[Repo] = None, ai: Optional[AIProvider] = None,
               storage=None, notifier=None, verifier: Optional[TokenVerifier] = None,
               clock: Optional[Callable[[], date]] = None) -> FastAPI:
    s = settings or get_settings()
    setup_logging()
    app = FastAPI(title="CASCADE API", version="1.0.0",
                  description="Informational financial risk intelligence. Not financial advice.")
    app.state.settings = s
    app.state.repo = repo or (FirestoreRepo(s.gcp_project) if s.datastore == "firestore" else MemoryRepo())
    app.state.ai = ai or build_provider(s)
    app.state.storage = storage or (GcsStorage(s.storage_bucket, s.gcp_project) if s.storage_bucket else LocalStorage(s.local_upload_dir))
    app.state.notifier = notifier or (FcmNotifier() if s.env == "prod" else NoopNotifier())
    app.state.verifier = verifier or build_verifier(s)
    app.state.limiter = RateLimiter()
    app.state.clock = clock or date.today
    errors.install(app)

    if s.cors_origins:  # native mobile clients don't need CORS; list only real web origins
        app.add_middleware(CORSMiddleware, allow_origins=s.cors_origins, allow_methods=["*"], allow_headers=["*"])

    @app.middleware("http")
    async def headers(request: Request, call_next):
        resp = await call_next(request)
        resp.headers["X-Content-Type-Options"] = "nosniff"
        resp.headers["Cache-Control"] = "no-store"
        return resp

    @app.get("/healthz", tags=["meta"])
    def health():
        return {"status": "ok", "ai": {"provider": app.state.ai.name, "live": app.state.ai.live}}

    for r in (core.router, scenarios.router, assistant.router, misc.router):
        app.include_router(r)
    return app


def app_factory() -> FastAPI:  # uvicorn --factory app.main:app_factory
    return create_app()
