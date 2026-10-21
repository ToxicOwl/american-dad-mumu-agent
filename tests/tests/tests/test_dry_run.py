from pathlib import Path

import cv2
import numpy as np

from ad_agent.actions import ASSETS, guarded_action
from ad_agent.config import AppConfig, EmulatorConfig, MonitorConfig, SafetyConfig


class FakeAdb:
    def __init__(self, screenshot: Path) -> None:
        self.screenshot_source = screenshot
        self.taps: list[tuple[int, int]] = []

    def screenshot(self, destination: Path) -> Path:
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(self.screenshot_source.read_bytes())
        return destination

    def tap(self, x: int, y: int) -> str:
        self.taps.append((x, y))
        return ""


def test_gifts_dry_run_does_not_tap(tmp_path: Path) -> None:
    canvas = np.zeros((720, 1280, 3), dtype=np.uint8)
    template = cv2.imread(str(ASSETS / "gifts_screen.png"), cv2.IMREAD_COLOR)
    assert template is not None
    height, width = template.shape[:2]
    canvas[50 : 50 + height, 50 : 50 + width] = template
    screen = tmp_path / "screen.png"
    assert cv2.imwrite(str(screen), canvas)

    config = AppConfig(
        root=tmp_path,
        emulator=EmulatorConfig(Path("adb.exe"), "127.0.0.1:7555", 1280, 720),
        safety=SafetyConfig("monitor", True, 3),
        monitor=MonitorConfig(5, False, "main_base"),
        templates={},
    )
    adb = FakeAdb(screen)
    assert guarded_action(config, adb, "gifts-claim-all", dry_run=True, confirm=False) == 0
    assert adb.taps == []
