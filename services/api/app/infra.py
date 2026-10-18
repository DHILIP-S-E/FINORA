"""Storage and push-notification backends (swappable)."""
from __future__ import annotations

import logging
from pathlib import Path
from typing import Optional, Protocol

log = logging.getLogger("cascade.infra")


class Storage(Protocol):
    def put(self, path: str, data: bytes, content_type: str) -> None: ...
    def get(self, path: str) -> Optional[bytes]: ...
    def delete(self, path: str) -> None: ...
    def delete_prefix(self, prefix: str) -> None: ...


class LocalStorage:
    def __init__(self, root: str) -> None:
        self.root = Path(root).resolve()

    def _p(self, path: str) -> Path:
        p = (self.root / path).resolve()
        if self.root not in p.parents:
            raise ValueError("path escape")
        return p

    def put(self, path, data, content_type):
        p = self._p(path)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(data)

    def get(self, path):
        p = self._p(path)
        return p.read_bytes() if p.exists() else None

    def delete(self, path):
        self._p(path).unlink(missing_ok=True)

    def delete_prefix(self, prefix):
        import shutil
        p = self._p(prefix)
        if p.exists():
            shutil.rmtree(p, ignore_errors=True)


class MemoryStorage:
    def __init__(self) -> None:
        self.blobs: dict[str, bytes] = {}

    def put(self, path, data, content_type):
        self.blobs[path] = data

    def get(self, path):
        return self.blobs.get(path)

    def delete(self, path):
        self.blobs.pop(path, None)

    def delete_prefix(self, prefix):
        for k in [k for k in self.blobs if k.startswith(prefix)]:
            del self.blobs[k]


class GcsStorage:
    def __init__(self, bucket: str, project: Optional[str] = None) -> None:
        from google.cloud import storage
        self.bucket = storage.Client(project=project).bucket(bucket)

    def put(self, path, data, content_type):
        self.bucket.blob(path).upload_from_string(data, content_type=content_type)

    def get(self, path):
        b = self.bucket.blob(path)
        return b.download_as_bytes() if b.exists() else None

    def delete(self, path):
        b = self.bucket.blob(path)
        if b.exists():
            b.delete()

    def delete_prefix(self, prefix):
        for b in self.bucket.list_blobs(prefix=prefix):
            b.delete()


class Notifier(Protocol):
    def send(self, token: str, title: str, body: str, data: dict[str, str]) -> bool: ...


class NoopNotifier:
    """Records sends instead of pushing (local dev/tests)."""

    def __init__(self) -> None:
        self.sent: list[dict] = []

    def send(self, token, title, body, data):
        self.sent.append({"token": token, "title": title, "body": body, "data": data})
        return True


class FcmNotifier:
    def send(self, token, title, body, data):
        from firebase_admin import messaging
        try:
            messaging.send(messaging.Message(token=token, notification=messaging.Notification(title=title, body=body), data=data))
            return True
        except Exception as e:  # noqa: BLE001
            log.warning("fcm send failed: %s", type(e).__name__)
            return False
