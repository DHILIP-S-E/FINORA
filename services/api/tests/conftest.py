import os
from datetime import date

import pytest
from fastapi.testclient import TestClient

os.environ.setdefault("ENV", "test")

from app.ai.fallback import FallbackProvider  # noqa: E402
from app.ai.schemas import AIUnavailable  # noqa: E402
from app.config import Settings  # noqa: E402
from app.infra import MemoryStorage, NoopNotifier  # noqa: E402
from app.main import create_app  # noqa: E402

TODAY = date(2026, 10, 20)


class Harness:
    def __init__(self, ai=None, **settings):
        self.settings = Settings(env="test", auth_mode="dev", datastore="memory", ai_mode="fallback", job_token="jobsecret",
                                 **settings)
        self.notifier = NoopNotifier()
        self.storage = MemoryStorage()
        self.app = create_app(self.settings, ai=ai or FallbackProvider(), storage=self.storage, notifier=self.notifier,
                              clock=lambda: TODAY)
        self.client = TestClient(self.app, raise_server_exceptions=False)

    @staticmethod
    def h(uid="alice"):
        return {"Authorization": f"Bearer dev:{uid}"}


@pytest.fixture
def hx():
    return Harness()


@pytest.fixture
def client(hx):
    return hx.client


@pytest.fixture
def alice():
    return Harness.h("alice")


@pytest.fixture
def bob():
    return Harness.h("bob")


class BrokenAI(FallbackProvider):
    live = True
    name = "gemini"

    def discover(self, context, max_n):
        raise AIUnavailable("simulated outage")

    def plan(self, message, context):
        raise AIUnavailable("simulated outage")

    def explain(self, facts, question):
        raise AIUnavailable("simulated outage")
