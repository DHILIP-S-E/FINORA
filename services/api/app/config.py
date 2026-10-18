from functools import lru_cache
from typing import Literal

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    env: Literal["local", "test", "prod"] = "local"
    # Data store: "memory" (local/tests) or "firestore"
    datastore: Literal["memory", "firestore"] = "memory"
    gcp_project: str | None = None
    storage_bucket: str | None = None
    local_upload_dir: str = ".uploads"

    # Auth: "firebase" verifies ID tokens. "dev" accepts `Bearer dev:<uid>` and is REFUSED when env=prod.
    auth_mode: Literal["firebase", "dev"] = "firebase"

    # AI: "auto" = Gemini if a key/Vertex is configured, otherwise labelled demo fallback.
    ai_mode: Literal["auto", "gemini", "fallback"] = "auto"
    gemini_api_key: str | None = None  # server-side only; from Secret Manager in prod
    gemini_model: str = "gemini-2.5-flash"  # VERIFY availability for your project before deploying
    use_vertex: bool = False
    vertex_location: str = "us-central1"
    ai_timeout_s: int = 45
    ai_max_retries: int = 2

    max_upload_bytes: int = 10 * 1024 * 1024
    cors_origins: list[str] = []
    rate_limit_per_min: int = 120
    ai_rate_limit_per_min: int = 12

    # Shared secret / audience for the scheduled job endpoint (Cloud Scheduler OIDC in prod).
    job_token: str | None = None
    scheduler_audience: str | None = None


@lru_cache
def get_settings() -> Settings:
    return Settings()
