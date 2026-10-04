"""Acceptance check: does a generated map background line up with its guide?

Overlays the flat guide (roads/rocks/water masks) on the painted background scaled to
1280x720 (gameplay resolution) and reports a coverage ratio per feature: which fraction
of guide-road pixels land on "light" background pixels, and which fraction of
guide-rock pixels land on "dark/non-road" pixels. The metric is a brightness heuristic
(the generation brief asks for a light worn path and dark boulders/slabs), not exact
color matching — art style differs per map. Also writes a semi-transparent overlay PNG
for eyeballing.

Usage: python tools/check_map_bg.py <guide.png> <bg.png> [--out overlay.png]
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np
from PIL import Image

SIZE = (1280, 720)  # gameplay world, matches TerrainView.WORLD
ROAD_COLOR = (217, 201, 169)  # COLORS["roads"] in tools/map_guide.py
ROCK_COLOR = (85, 86, 91)     # COLORS["rocks"]
WATER_COLOR = (54, 113, 138)  # COLORS["water"]
COLOR_TOL = 30

# Road/rock verdict thresholds: fraction of guide-marked pixels that must land on the
# expected side of the brightness split computed from the generated image itself.
ROAD_PASS = 0.55
ROCK_PASS = 0.55


def mask_for(guide: np.ndarray, color: tuple[int, int, int]) -> np.ndarray:
    diff = np.abs(guide.astype(int) - np.array(color)).sum(axis=-1)
    return diff < COLOR_TOL


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("guide", type=Path)
    parser.add_argument("bg", type=Path)
    parser.add_argument("--out", type=Path, default=None)
    args = parser.parse_args()

    guide_img = Image.open(args.guide).convert("RGB").resize(SIZE, Image.LANCZOS)
    bg_img = Image.open(args.bg).convert("RGB").resize(SIZE, Image.LANCZOS)
    guide = np.array(guide_img)
    bg = np.array(bg_img)

    brightness = bg.astype(float).mean(axis=-1)

    road_mask = mask_for(guide, ROAD_COLOR)
    rock_mask = mask_for(guide, ROCK_COLOR)
    water_mask = mask_for(guide, WATER_COLOR)
    obstacle_mask = rock_mask | water_mask

    # Threshold is the midpoint between the road area's brightness and the obstacle
    # area's brightness, both measured IN THIS image — not a global median. A dark
    # map (bridge at night) and a light map (ash wasteland) both pass fairly: what
    # matters is whether road reads lighter than rock/water at the same spot, not
    # absolute brightness against the whole frame (which the background ground skews).
    if road_mask.any() and obstacle_mask.any():
        road_level = float(brightness[road_mask].mean())
        obstacle_level = float(brightness[obstacle_mask].mean())
        threshold = (road_level + obstacle_level) / 2.0
    else:
        threshold = float(np.median(brightness))
    is_light = brightness > threshold

    def ratio(mask: np.ndarray, want_light: bool) -> tuple[float, int]:
        count = int(mask.sum())
        if count == 0:
            return 1.0, 0
        hit = is_light[mask] if want_light else ~is_light[mask]
        return float(hit.mean()), count

    road_ratio, road_n = ratio(road_mask, True)
    rock_ratio, rock_n = ratio(rock_mask, False)
    water_ratio, water_n = ratio(water_mask, False)

    road_ok = road_ratio >= ROAD_PASS
    rock_ok = rock_ratio >= ROCK_PASS or rock_n == 0
    verdict = "PASS" if road_ok and rock_ok else "FAIL"

    print(f"{args.bg.name}: road={road_ratio:.2f} (n={road_n}) "
          f"rock={rock_ratio:.2f} (n={rock_n}) water_dark={water_ratio:.2f} (n={water_n}) "
          f"threshold={threshold:.1f} -> {verdict}")

    if args.out:
        overlay = Image.blend(bg_img, guide_img, 0.35)
        args.out.parent.mkdir(parents=True, exist_ok=True)
        overlay.save(args.out)
        print(f"overlay: {args.out}")

    return 0 if verdict == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
