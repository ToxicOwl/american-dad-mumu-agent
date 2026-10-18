from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
import time

from .adb import AdbClient, AdbError
from .config import AppConfig
from .logging_utils import log_event
from .vision import VisionError, dimensions, match_template


@dataclass(frozen=True)
class Observation:
    timestamp: str
    screenshot: Path
    width: int
    height: int
    screen: str
    score: float | None


def _timestamp_name() -> str:
    return datetime.now().strftime("%Y%m%d-%H%M%S")


def observe(config: AppConfig, adb: AdbClient) -> Observation:
    screenshot = config.root / "captures" / f"screen-{_timestamp_name()}.png"
    adb.screenshot(screenshot)
    width, height = dimensions(screenshot)

    template = config.templates.get(config.monitor.main_screen_template)
    screen = "unrecognized"
    score: float | None = None
    if template and template.path.is_file():
        match = match_template(screenshot, template.path)
        score = match.score
        if match.score >= template.min_score:
            screen = "main_base"

    observation = Observation(
        timestamp=_timestamp_name(),
        screenshot=screenshot,
        width=width,
        height=height,
        screen=screen,
        score=score,
    )
    log_event(
        config.root / "logs" / "agent.jsonl",
        "observation",
        mode=config.safety.mode,
        screenshot=str(screenshot.relative_to(config.root)),
        size=f"{width}x{height}",
        detected_screen=screen,
        template_score=score,
    )
    return observation


def monitor(config: AppConfig, adb: AdbClient, iterations: int | None = None) -> int:
    """Watch the emulator. This function intentionally sends no Android input commands."""
    if config.safety.mode != "monitor":
        raise RuntimeError("Only monitor mode is allowed.")

    print("SAFE MODE: monitor only. No taps, swipes, text input, or purchases will be sent.")
    failures = 0
    count = 0
    while iterations is None or count < iterations:
        try:
            item = observe(config, adb)
            result = f"[{item.timestamp}] {item.width}x{item.height} — {item.screen}"
            if item.score is not None:
                result += f" (template score {item.score:.3f})"
            print(result)
            failures = 0
            count += 1
            if not config.monitor.save_unchanged_screenshots and item.screen != "unrecognized":
                item.screenshot.unlink(missing_ok=True)
        except (AdbError, VisionError) as exc:
            failures += 1
            print(f"[{_timestamp_name()}] ERROR: {exc}")
            log_event(config.root / "logs" / "agent.jsonl", "error", message=str(exc), failures=failures)
            if failures >= config.safety.max_consecutive_errors:
                print("Stopped after the configured number of consecutive errors.")
                return 1
        if iterations is None or count < iterations:
            time.sleep(config.monitor.interval_seconds)
    return 0
