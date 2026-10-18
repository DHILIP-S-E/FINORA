import threading
import time
from collections import defaultdict, deque

from .errors import ApiError


class RateLimiter:
    """In-process sliding window. For multi-instance Cloud Run, back with Redis/Firestore or API Gateway quotas."""

    def __init__(self) -> None:
        self._hits: dict[tuple[str, str], deque[float]] = defaultdict(deque)
        self._lock = threading.Lock()

    def check(self, uid: str, bucket: str, limit: int, window_s: float = 60.0) -> None:
        now = time.monotonic()
        with self._lock:
            q = self._hits[(uid, bucket)]
            while q and now - q[0] > window_s:
                q.popleft()
            if len(q) >= limit:
                raise ApiError(429, "rate_limited", "Too many requests; please retry shortly.")
            q.append(now)
