from pathlib import Path

import cv2
import numpy as np

from ad_agent.actions import ASSETS, guarded_action
from ad_agent.config import AppConfig, EmulatorConfig, MonitorConfig, SafetyConfig


class SequentialFakeAdb:
    def __init__(self, screenshots: list[Path]) -> None:
        self.screenshots = screenshots
        self.index = 0
        self.taps: list[tuple[int, int]] = []

    def screenshot(self, destination: Path) -> Path:
        destination.parent.mkdir(parents=True, exist_ok=True)
        source = self.screenshots[min(self.index, len(self.screenshots) - 1)]
        self.index += 1
        destination.write_bytes(source.read_bytes())
        return destination

    def tap(self, x: int, y: int) -> str:
        self.taps.append((x, y))
        return ""


def _place_asset(tmp_path: Path, filename: str, output_name: str) -> Path:
    canvas = np.zeros((720, 1280, 3), dtype=np.uint8)
    asset = cv2.imread(str(ASSETS / filename), cv2.IMREAD_COLOR)
    assert asset is not None
    height, width = asset.shape[:2]
    canvas[50 : 50 + height, 50 : 50 + width] = asset
    output = tmp_path / output_name
    assert cv2.imwrite(str(output), canvas)
    return output


def test_no_space_action_taps_claim_only_after_exact_dialog_match(tmp_path: Path) -> None:
    gifts_screen = _place_asset(tmp_path, "gifts_screen.png", "gifts.png")
    no_space_screen = _place_asset(tmp_path, "no_space_modal.png", "no-space.png")
    config = AppConfig(
        root=tmp_path,
        emulator=EmulatorConfig(Path("adb.exe"), "127.0.0.1:7555", 1280, 720),
        safety=SafetyConfig("actions", True, 3),
        monitor=MonitorConfig(5, False, "main_base"),
        templates={},
    )
    adb = SequentialFakeAdb([gifts_screen, no_space_screen, no_space_screen])

    assert guarded_action(config, adb, "gifts-claim-all-despite-no-space", dry_run=False, confirm=True) == 0
    assert adb.taps == [(899, 595), (748, 478)]


def test_current_no_space_dialog_can_be_checked_without_tapping(tmp_path: Path) -> None:
    no_space_screen = _place_asset(tmp_path, "no_space_modal.png", "no-space.png")
    config = AppConfig(
        root=tmp_path,
        emulator=EmulatorConfig(Path("adb.exe"), "127.0.0.1:7555", 1280, 720),
        safety=SafetyConfig("monitor", True, 3),
        monitor=MonitorConfig(5, False, "main_base"),
        templates={},
    )
    adb = SequentialFakeAdb([no_space_screen])

    assert guarded_action(config, adb, "gifts-confirm-no-space", dry_run=True, confirm=False) == 0
    assert adb.taps == []
