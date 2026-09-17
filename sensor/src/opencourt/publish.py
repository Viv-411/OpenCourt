"""Publishing snapshots to the backend, and local history logging.

The publisher never blocks the camera loop: a background thread sends only the most
recent payload, so a slow or dead network just means fewer, fresher updates.
"""

from __future__ import annotations

import json
import logging
import threading
import time
from collections.abc import Callable
from pathlib import Path
from typing import Any, Protocol

import httpx

from .config import BackendConfig, HistoryConfig
from .engine import Snapshot

log = logging.getLogger(__name__)


class Publisher(Protocol):
    def submit(self, snap: Snapshot) -> None: ...
    def close(self) -> None: ...


class NullPublisher:
    def submit(self, snap: Snapshot) -> None:
        pass

    def close(self) -> None:
        pass


class Throttle:
    """Send when something visible changed (at most every ``min_interval``), and otherwise
    every ``heartbeat`` so the backend can tell the device is alive."""

    def __init__(self, min_interval: float, heartbeat: float,
                 clock: Callable[[], float] = time.monotonic):
        self.min_interval = min_interval
        self.heartbeat = heartbeat
        self._clock = clock
        self._last_sent: float | None = None
        self._last_sig: tuple | None = None

    def should_send(self, snap: Snapshot) -> bool:
        now = self._clock()
        sig = snap.signature()
        if self._last_sent is None:
            due = True
        elif sig != self._last_sig:
            due = now - self._last_sent >= self.min_interval
        else:
            due = now - self._last_sent >= self.heartbeat
        if due:
            self._last_sent, self._last_sig = now, sig
        return due


class SupabasePublisher:
    """Calls the ``ingest_status`` RPC with the anon key plus a per-device token.

    The service-role key never lives on the device (docs/PLAN.md §9).
    """

    def __init__(self, cfg: BackendConfig, site_id: str,
                 client: httpx.Client | None = None, start_thread: bool = True):
        if not cfg.url:
            raise ValueError("backend.url is not set")
        anon, token = cfg.anon_key, cfg.device_token
        if not anon or not token:
            raise ValueError(
                f"set {cfg.anon_key_env} and {cfg.device_token_env} in the environment"
            )
        self.site_id = site_id
        self._endpoint = cfg.url.rstrip("/") + "/rest/v1/rpc/ingest_status"
        self._token = token
        self._client = client or httpx.Client(timeout=cfg.timeout_seconds)
        self._headers = {"apikey": anon, "Authorization": f"Bearer {anon}",
                         "Content-Type": "application/json"}
        self._throttle = Throttle(cfg.min_interval_seconds, cfg.heartbeat_seconds)
        self._pending: dict[str, Any] | None = None
        self._cv = threading.Condition()
        self._stop = False
        self.sent = 0
        self.failed = 0
        self._thread = None
        if start_thread:
            self._thread = threading.Thread(target=self._worker, name="publisher", daemon=True)
            self._thread.start()

    def submit(self, snap: Snapshot) -> None:
        if not self._throttle.should_send(snap):
            return
        with self._cv:
            self._pending = snap.to_payload(self.site_id)
            self._cv.notify()

    def send_now(self, payload: dict[str, Any]) -> None:
        body = {"p_token": self._token, "p_payload": payload}
        r = self._client.post(self._endpoint, headers=self._headers, content=json.dumps(body))
        if r.status_code >= 300:
            raise httpx.HTTPStatusError(f"ingest failed: {r.status_code} {r.text[:200]}",
                                        request=r.request, response=r)

    def _worker(self) -> None:
        backoff = 1.0
        while True:
            with self._cv:
                while self._pending is None and not self._stop:
                    self._cv.wait()
                if self._stop and self._pending is None:
                    return
                payload, self._pending = self._pending, None
            try:
                self.send_now(payload)
                self.sent += 1
                backoff = 1.0
            except Exception as e:  # network errors must never kill the loop
                self.failed += 1
                log.warning("publish failed (%s); retrying in %.0fs", e, backoff)
                with self._cv:
                    if self._pending is None:
                        self._pending = payload  # keep it unless something newer arrived
                    self._cv.wait(timeout=backoff)
                backoff = min(backoff * 2, 60.0)

    def close(self) -> None:
        with self._cv:
            self._stop = True
            self._cv.notify()
        if self._thread:
            self._thread.join(timeout=5)
        self._client.close()


class HistoryWriter:
    """Appends one snapshot per interval as JSON lines: counts and states only."""

    def __init__(self, cfg: HistoryConfig, site_id: str, path: Path | None):
        self._interval = cfg.interval_seconds
        self._site = site_id
        self._path = path
        self._last: float | None = None
        if path is not None:
            path.parent.mkdir(parents=True, exist_ok=True)

    def submit(self, snap: Snapshot) -> None:
        if self._path is None:
            return
        if self._last is not None and snap.t - self._last < self._interval:
            return
        self._last = snap.t
        with open(self._path, "a") as f:
            f.write(json.dumps(snap.to_payload(self._site)) + "\n")

    def close(self) -> None:
        pass
