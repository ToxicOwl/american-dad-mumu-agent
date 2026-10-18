from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

import cv2
import numpy as np


class VisionError(RuntimeError):
    """Raised for invalid screenshots, templates, or crop coordinates."""


@dataclass(frozen=True)
class TemplateMatch:
    score: float
    x: int
    y: int
    width: int
    height: int


def read_color_image(path: Path) -> np.ndarray:
    image = cv2.imread(str(path), cv2.IMREAD_COLOR)
    if image is None:
        raise VisionError(f"Could not read image: {path}")
    return image


def dimensions(path: Path) -> tuple[int, int]:
    image = read_color_image(path)
    height, width = image.shape[:2]
    return width, height


def crop_template(source: Path, destination: Path, x: int, y: int, width: int, height: int) -> Path:
    image = read_color_image(source)
    image_height, image_width = image.shape[:2]
    if x < 0 or y < 0 or width < 8 or height < 8:
        raise VisionError("Crop coordinates must be non-negative and the crop must be at least 8×8 pixels.")
    if x + width > image_width or y + height > image_height:
        raise VisionError(
            f"Crop ({x}, {y}, {width}, {height}) lies outside screenshot size {image_width}×{image_height}."
        )
    crop = image[y : y + height, x : x + width]
    destination.parent.mkdir(parents=True, exist_ok=True)
    if not cv2.imwrite(str(destination), crop):
        raise VisionError(f"Could not write template: {destination}")
    return destination


def match_template(screenshot: Path, template: Path) -> TemplateMatch:
    scene = read_color_image(screenshot)
    reference = read_color_image(template)
    scene_height, scene_width = scene.shape[:2]
    template_height, template_width = reference.shape[:2]
    if template_height > scene_height or template_width > scene_width:
        raise VisionError("Template is larger than the screenshot.")

    result = cv2.matchTemplate(scene, reference, cv2.TM_CCOEFF_NORMED)
    _, score, _, location = cv2.minMaxLoc(result)
    return TemplateMatch(
        score=float(score),
        x=int(location[0]),
        y=int(location[1]),
        width=int(template_width),
        height=int(template_height),
    )
