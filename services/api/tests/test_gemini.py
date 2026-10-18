import pytest

from app.ai.gemini import GeminiProvider
from app.ai.schemas import AIUnavailable, DiscoveryResponse


class _Resp:
    def __init__(self, text):
        self.text = text


class _Models:
    def __init__(self, outputs):
        self.outputs, self.calls = list(outputs), 0

    def generate_content(self, **kw):
        self.calls += 1
        o = self.outputs.pop(0)
        if isinstance(o, Exception):
            raise o
        return _Resp(o)


def provider(outputs, retries=2):
    p = GeminiProvider.__new__(GeminiProvider)
    from google.genai import types
    p._types, p.model, p.retries = types, "m", retries
    p.client = type("C", (), {"models": _Models(outputs)})()
    return p


GOOD = '{"scenarios":[{"scenario_title":"t","scenario_summary":"s","disruptions":[{"type":"income_delay","days":5}]}]}'


def test_recovers_from_malformed_output_within_retry_budget():
    p = provider(["not json", '{"scenarios": 5}', GOOD])
    r = p._structured(DiscoveryResponse, "x")
    assert r.scenarios[0].scenario_title == "t" and p.client.models.calls == 3


def test_gives_up_after_bounded_retries():
    p = provider(["bad"] * 10, retries=2)
    with pytest.raises(AIUnavailable):
        p._structured(DiscoveryResponse, "x")
    assert p.client.models.calls == 3


def test_timeout_and_transport_errors_surface_as_unavailable():
    p = provider([TimeoutError("deadline")])
    with pytest.raises(AIUnavailable):
        p.discover({"records": []}, 3)


def test_disallowed_disruption_type_fails_schema():
    p = provider(['{"scenarios":[{"scenario_title":"t","scenario_summary":"s","disruptions":[{"type":"wire_money"}]}]}'] * 3)
    with pytest.raises(AIUnavailable):
        p._structured(DiscoveryResponse, "x")
