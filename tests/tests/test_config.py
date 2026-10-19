from pathlib import Path
import json

from ad_agent.config import load_config


def test_load_monitor_only_profile(tmp_path: Path) -> None:
    config_file = tmp_path / "config.json"
    config_file.write_text(json.dumps({
        "emulator": {
            "adb_path": "C:\\MuMu\\adb.exe",
            "device": "127.0.0.1:7555",
            "expected_screenshot": {"width": 1280, "height": 720},
        },
        "safety": {"mode": "monitor", "forbid_diamond_spend": True, "max_consecutive_errors": 3},
        "monitor": {"interval_seconds": 5, "save_unchanged_screenshots": False, "main_screen_template": "base"},
        "templates": {"base": {"path": "calibration/templates/base.png", "min_score": 0.88}},
    }), encoding="utf-8")

    config = load_config(config_file)
    assert config.emulator.device == "127.0.0.1:7555"
    assert config.safety.mode == "monitor"
    assert config.templates["base"].path == tmp_path / "calibration/templates/base.png"


def test_load_actions_mode(tmp_path: Path) -> None:
    config_file = tmp_path / "config.json"
    config_file.write_text(json.dumps({
        "emulator": {
            "adb_path": "C:\\MuMu\\adb.exe",
            "device": "127.0.0.1:7555",
            "expected_screenshot": {"width": 1280, "height": 720},
        },
        "safety": {"mode": "actions", "forbid_diamond_spend": True, "max_consecutive_errors": 3},
        "monitor": {"interval_seconds": 5, "save_unchanged_screenshots": False, "main_screen_template": "base"},
        "templates": {"base": {"path": "calibration/templates/base.png", "min_score": 0.88}},
    }), encoding="utf-8")
    assert load_config(config_file).safety.mode == "actions"
