from __future__ import annotations

from datetime import date

from fastapi import Request

from .ai.provider import AIProvider
from .repo import Repo


def get_repo(request: Request) -> Repo:
    return request.app.state.repo


def get_ai(request: Request) -> AIProvider:
    return request.app.state.ai


def get_storage(request: Request):
    return request.app.state.storage


def get_notifier(request: Request):
    return request.app.state.notifier


def get_today(request: Request) -> date:
    return request.app.state.clock()


def get_cfg(request: Request):
    return request.app.state.settings
