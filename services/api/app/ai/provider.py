from __future__ import annotations

from typing import Protocol

from ..config import Settings
from .schemas import AssistantPlan, DiscoveryResponse, DocumentExtraction


class AIProvider(Protocol):
    name: str
    live: bool  # True only if a real model produced the output

    def discover(self, context: dict, max_n: int) -> DiscoveryResponse: ...
    def plan(self, message: str, context: dict) -> AssistantPlan: ...
    def explain(self, facts: dict, question: str | None) -> str: ...
    def extract(self, data: bytes, mime: str) -> DocumentExtraction: ...


def build_provider(s: Settings) -> AIProvider:
    from .fallback import FallbackProvider
    from .gemini import GeminiProvider
    configured = bool(s.gemini_api_key) or s.use_vertex
    if s.ai_mode == "fallback" or (s.ai_mode == "auto" and not configured):
        return FallbackProvider()
    if not configured:
        raise RuntimeError("AI_MODE=gemini but neither GEMINI_API_KEY nor USE_VERTEX is configured")
    return GeminiProvider(s)
