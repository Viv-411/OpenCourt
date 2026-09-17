"""Wait estimates (docs/PLAN.md §7). Pure functions."""

from __future__ import annotations

import heapq
import math
from collections.abc import Sequence
from dataclasses import dataclass

from .config import EstimateConfig


@dataclass(frozen=True, slots=True)
class WaitEstimate:
    next_free_seconds: float | None  # when the first court should free up
    wait_seconds: float | None  # for someone who joins the queue now
    groups_ahead: int


def estimate_wait(
    on_court_seconds: Sequence[float | None],
    queue_count: float,
    players_per_group: int,
    cfg: EstimateConfig,
) -> WaitEstimate:
    """``on_court_seconds`` has one entry per court: elapsed time for the group there, or None
    if the court is empty."""
    groups_ahead = math.ceil(max(0.0, queue_count) / players_per_group - 1e-9)
    if not on_court_seconds:
        return WaitEstimate(None, None, groups_ahead)

    L = cfg.typical_game_seconds
    first: list[float] = []
    for elapsed in on_court_seconds:
        if elapsed is None:
            first.append(0.0)
        elif elapsed < L:
            first.append(max(cfg.min_remaining_seconds, L - elapsed))
        else:
            first.append(cfg.overdue_remaining_seconds)

    # k-th smallest of {r_i + m*L}: pop from a heap, pushing each court's next release.
    heap = [(r, i) for i, r in enumerate(first)]
    heapq.heapify(heap)
    next_free = heap[0][0]
    t = next_free
    for _ in range(groups_ahead + 1):
        t, i = heapq.heappop(heap)
        heapq.heappush(heap, (t + L, i))
    return WaitEstimate(next_free, t, groups_ahead)
