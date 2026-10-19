from __future__ import annotations

from dataclasses import dataclass
import json
from pathlib import Path
from typing import Any


class ConfigError(RuntimeError):
    """Raised when the local profile is missing or invalid."""


@dataclass(frozen=True)
class EmulatorConfig:
    adb_path: Path
    device: str
    expected_width: int
    expected_height: int


@dataclass(frozen=True)
class SafetyConfig:
    mode: str
    forbid_diamond_spend: bool
    max_consecutive_errors: int


@dataclass(frozen=True)
class MonitorConfig:
    interval_seconds: float
    save_unchanged_screenshots: bool
    main_screen_template: str


@dataclass(frozen=True)
class TemplateConfig:
    name: str
    path: Path
    min_score: float


@dataclass(frozen=True)
class AppConfig:
    root: Path
    emulator: EmulatorConfig
    safety: SafetyConfig
    monitor: MonitorConfig
    templates: dict[str, TemplateConfig]


def _expect_mapping(value: Any, key: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ConfigError(f"'{key}' must be an object in config.json.")
    return value


def _expect_string(value: Any, key: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ConfigError(f"'{key}' must be a non-empty string in config.json.")
    return value


def _expect_int(value: Any, key: str, minimum: int = 1) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value < minimum:
        raise ConfigError(f"'{key}' must be an integer >= {minimum} in config.json.")
    return value


def _expect_number(value: Any, key: str, minimum: float = 0.0) -> float:
    if not isinstance(value, (int, float)) or isinstance(value, bool) or value < minimum:
        raise ConfigError(f"'{key}' must be a number >= {minimum} in config.json.")
    return float(value)


def load_config(path: Path) -> AppConfig:
    path = path.resolve()
    if not path.exists():
        raise ConfigError(
            f"Profile not found: {path}. Copy config.example.json to config.json first."
        )

    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise ConfigError(f"Cannot parse {path.name}: {exc}") from exc

    raw = _expect_mapping(raw, "root")
    emulator_raw = _expect_mapping(raw.get("emulator"), "emulator")
    screenshot_raw = _expect_mapping(emulator_raw.get("expected_screenshot"), "emulator.expected_screenshot")
    safety_raw = _expect_mapping(raw.get("safety"), "safety")
    monitor_raw = _expect_mapping(raw.get("monitor"), "monitor")
    templates_raw = _expect_mapping(raw.get("templates"), "templates")

    mode = _expect_string(safety_raw.get("mode"), "safety.mode")
    if mode not in {"monitor", "actions"}:
        raise ConfigError("safety.mode must be either 'monitor' or 'actions'.")

    emulator = EmulatorConfig(
        adb_path=Path(_expect_string(emulator_raw.get("adb_path"), "emulator.adb_path")),
        device=_expect_string(emulator_raw.get("device"), "emulator.device"),
        expected_width=_expect_int(screenshot_raw.get("width"), "emulator.expected_screenshot.width"),
        expected_height=_expect_int(screenshot_raw.get("height"), "emulator.expected_screenshot.height"),
    )
    safety = SafetyConfig(
        mode=mode,
        forbid_diamond_spend=bool(safety_raw.get("forbid_diamond_spend", True)),
        max_consecutive_errors=_expect_int(safety_raw.get("max_consecutive_errors", 3), "safety.max_consecutive_errors"),
    )
    monitor = MonitorConfig(
        interval_seconds=_expect_number(monitor_raw.get("interval_seconds", 5), "monitor.interval_seconds", 0.2),
        save_unchanged_screenshots=bool(monitor_raw.get("save_unchanged_screenshots", False)),
        main_screen_template=_expect_string(monitor_raw.get("main_screen_template"), "monitor.main_screen_template"),
    )

    templates: dict[str, TemplateConfig] = {}
    for name, values in templates_raw.items():
        values = _expect_mapping(values, f"templates.{name}")
        path_value = Path(_expect_string(values.get("path"), f"templates.{name}.path"))
        if not path_value.is_absolute():
            path_value = path.parent / path_value
        score = _expect_number(values.get("min_score"), f"templates.{name}.min_score", 0.0)
        if score > 1.0:
            raise ConfigError(f"templates.{name}.min_score must be at most 1.0.")
        templates[name] = TemplateConfig(name=name, path=path_value, min_score=score)

    return AppConfig(root=path.parent, emulator=emulator, safety=safety, monitor=monitor, templates=templates)
