"""Light drivers. One logical light per court; whether that is a beacon on each court or a
labelled panel at the queue is only a wiring/config choice (docs/PLAN.md §8)."""

from __future__ import annotations

import sys
from typing import Protocol

from .config import LightsConfig
from .types import LightMode


class LightDriver(Protocol):
    def set(self, court: int, mode: LightMode) -> None: ...
    def close(self) -> None: ...


class _ChangeOnly:
    def __init__(self) -> None:
        self.modes: dict[int, LightMode] = {}

    def set(self, court: int, mode: LightMode) -> None:
        if self.modes.get(court) is mode:
            return
        self.modes[court] = mode
        self._apply(court, mode)

    def _apply(self, court: int, mode: LightMode) -> None:
        pass

    def close(self) -> None:
        for court in list(self.modes):
            self.set(court, LightMode.OFF)


class NullLights(_ChangeOnly):
    pass


class ConsoleLights(_ChangeOnly):
    def __init__(self, stream=sys.stderr, clock=None):
        super().__init__()
        self._stream = stream
        self._clock = clock

    def _apply(self, court: int, mode: LightMode) -> None:
        stamp = f"[{self._clock():8.0f}s] " if self._clock else ""
        symbol = {LightMode.OFF: "○", LightMode.PULSE: "◐", LightMode.SOLID: "●"}[mode]
        print(f"{stamp}light court {court}: {symbol} {mode.value}", file=self._stream)


class GpioLights(_ChangeOnly):
    """Amber beacons / LED strips switched by a logic-level MOSFET on each BCM pin.

    Uses gpiozero (lgpio backend on the Pi 5; RPi.GPIO does not work there).
    """

    def __init__(self, cfg: LightsConfig):
        super().__init__()
        from gpiozero import PWMLED

        self._fade = cfg.pulse_fade_seconds
        self._leds = {c: PWMLED(pin, active_high=cfg.active_high) for c, pin in cfg.pins.items()}
        for led in self._leds.values():
            led.off()

    def _apply(self, court: int, mode: LightMode) -> None:
        led = self._leds.get(court)
        if led is None:
            return
        if mode is LightMode.OFF:
            led.off()
        elif mode is LightMode.SOLID:
            led.on()
        else:
            led.pulse(fade_in_time=self._fade, fade_out_time=self._fade)

    def close(self) -> None:
        super().close()
        for led in self._leds.values():
            led.close()


def make_lights(cfg: LightsConfig, override: str | None = None, clock=None) -> LightDriver:
    kind = override or cfg.driver
    if kind == "gpio":
        return GpioLights(cfg)
    if kind == "console":
        return ConsoleLights(clock=clock)
    return NullLights()
