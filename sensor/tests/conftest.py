from __future__ import annotations

import pytest

from opencourt.config import RotationConfig, TimerConfig


@pytest.fixture
def rot() -> RotationConfig:
    return RotationConfig()


@pytest.fixture
def timer() -> TimerConfig:
    return TimerConfig(threshold_seconds=1200, warning_seconds=120)
