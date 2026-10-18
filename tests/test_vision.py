from pathlib import Path

import cv2
import numpy as np

from ad_agent.vision import crop_template, dimensions, match_template


def test_crop_and_match_template(tmp_path: Path) -> None:
    image = np.zeros((100, 160, 3), dtype=np.uint8)
    cv2.rectangle(image, (42, 31), (82, 66), (20, 180, 250), thickness=-1)
    cv2.circle(image, (60, 48), 8, (255, 0, 0), thickness=-1)
    screenshot = tmp_path / "screen.png"
    assert cv2.imwrite(str(screenshot), image)

    template = tmp_path / "template.png"
    crop_template(screenshot, template, 42, 31, 41, 36)
    found = match_template(screenshot, template)

    assert dimensions(screenshot) == (160, 100)
    assert found.score > 0.999
    assert (found.x, found.y) == (42, 31)
