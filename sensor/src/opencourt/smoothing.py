"""Temporal smoothing. Nothing downstream ever acts on a single frame."""

from __future__ import annotations

import statistics
from collections import deque


class RollingMedian:
    """Median of samples within the last ``window`` seconds.

    Also keeps a longer history of the smoothed value so callers can ask
    "what was the smoothed value around time t?" (used for queue-drop evidence).
    """

    def __init__(self, window: float, history_seconds: float = 900.0):
        self.window = window
        self.history_seconds = history_seconds
        self._samples: deque[tuple[float, float]] = deque()
        self._smoothed: deque[tuple[float, float]] = deque()

    def add(self, t: float, value: float) -> float:
        self._samples.append((t, value))
        while self._samples and self._samples[0][0] < t - self.window:
            self._samples.popleft()
        m = float(statistics.median(v for _, v in self._samples))
        self._smoothed.append((t, m))
        while self._smoothed and self._smoothed[0][0] < t - self.history_seconds:
            self._smoothed.popleft()
        return m

    @property
    def value(self) -> float:
        return self._smoothed[-1][1] if self._smoothed else 0.0

    def value_at(self, t: float) -> float:
        """Smoothed value at the latest sample at or before ``t`` (or the earliest known)."""
        best = None
        for ts, v in self._smoothed:
            if ts <= t:
                best = v
            else:
                break
        if best is None:
            return self._smoothed[0][1] if self._smoothed else 0.0
        return best


class Sustained:
    """Boolean with asymmetric hysteresis.

    Turns on after the raw condition has held for ``on_seconds``; turns off after it has
    been false for ``off_seconds``. ``since`` is when the current on-period started
    (the moment the raw condition first became true, not when it was confirmed).
    """

    def __init__(self, on_seconds: float, off_seconds: float):
        self.on_seconds = on_seconds
        self.off_seconds = off_seconds
        self.state = False
        self.since: float | None = None
        self._raw_true_since: float | None = None
        self._raw_false_since: float | None = None

    def update(self, t: float, raw: bool) -> bool:
        if raw:
            self._raw_false_since = None
            if self._raw_true_since is None:
                self._raw_true_since = t
            if not self.state and t - self._raw_true_since >= self.on_seconds:
                self.state = True
                self.since = self._raw_true_since
        else:
            self._raw_true_since = None
            if self._raw_false_since is None:
                self._raw_false_since = t
            if self.state and t - self._raw_false_since >= self.off_seconds:
                self.state = False
                self.since = None
        return self.state
