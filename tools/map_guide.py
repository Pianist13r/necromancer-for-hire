"""Flat, text-free artist guides from campaign JSON (Python + Pillow).

Run from any directory: python tools/map_guide.py [map.json ...] [--out DIR]
Without inputs renders all six campaign maps, excluding the _gray test fixture.
World coordinates and road width follow LegionCfg; output is exactly 1920x1080.
"""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
import re

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
MAPS = ROOT / "godot/assets/legion/maps"
SCALE = 1.5
SIZE = (1920, 1080)
THEMES = {"grave": "#343d42", "ash": "#49404b",
          "swamp": "#334b43", "office": "#3b3d4c"}
COLORS = {"roads": "#d9c9a9", "rocks": "#55565b", "water": "#36718a",
          "bridges": "#aa815a", "swamp": "#638052", "plots": "#e5be69",
          "cauldron": "#ad6bcb", "gates": "#b75c4c", "crypts": "#92bcba"}


def road_width() -> float:
    """Read the drawing contract, so a width change cannot silently stale the guide."""
    cfg = (ROOT / "godot/scripts/legion/legion_cfg.gd").read_text(encoding="utf-8")
    match = re.search(r"^const MAP_ROAD_WIDTH := ([0-9.]+)$", cfg, re.MULTILINE)
    if match is None:
        raise ValueError("LegionCfg.MAP_ROAD_WIDTH must be a numeric constant")
    return float(match[1])


def point(p: list[float] | tuple[float, float]) -> tuple[float, float]:
    return p[0] * SCALE, p[1] * SCALE


def circle(draw: ImageDraw.ImageDraw, pos: list[float] | tuple[float, float],
           radius: float, fill: str) -> None:
    x, y = point(pos)
    r = radius * SCALE
    draw.ellipse((x-r, y-r, x+r, y+r), fill=fill)


def render(data: dict, destination: Path) -> None:
    image = Image.new("RGB", SIZE, THEMES.get(data.get("theme"), THEMES["grave"]))
    draw = ImageDraw.Draw(image)
    for polygon in data.get("swamp", []):
        draw.polygon([point(p) for p in polygon], fill=COLORS["swamp"])
    width = road_width()
    for road in data.get("roads", []):
        path = road["path"]
        draw.line([point(p) for p in path], fill=COLORS["roads"],
                  width=round(width*SCALE), joint="curve")
        for p in path:
            circle(draw, p, width/2, COLORS["roads"])
    # Same layering as TerrainView: water covers roads, then bridges cover water.
    for key in ("water", "bridges", "rocks"):
        for polygon in data.get(key, []):
            draw.polygon([point(p) for p in polygon], fill=COLORS[key])
    # v19 walls (fences, stone walls) are solid like rocks; LegionTerrain cuts them by
    # ROAD_CLEAR around roads, so the guide leaves the road visible over them.
    for wall in data.get("walls", []):
        draw.line([point(p) for p in wall["path"]], fill=COLORS["rocks"],
                  width=round(float(wall.get("w", 18))*SCALE), joint="curve")
    for road in data.get("roads", []) if data.get("walls") else []:
        draw.line([point(p) for p in road["path"]], fill=COLORS["roads"],
                  width=round(width*SCALE), joint="curve")
    for plot in data.get("plots", []):
        circle(draw, plot["pos"], 22, COLORS["plots"])
    for crypt in data.get("crypts", []):
        x, y = crypt["pos"]
        draw.rectangle((*point((x-28,y-20)), *point((x+28,y+20))), fill=COLORS["crypts"])
    circle(draw, data["cauldron"], 28, COLORS["cauldron"])
    entries: set[tuple[float, float]] = set()
    for road in data.get("roads", []):
        start, after = road["path"][:2]
        entry = (max(28, min(1252, start[0])), max(28, min(692, start[1])))
        if entry in entries:
            continue
        entries.add(entry)
        length = math.dist(start, after)
        across = ((after[1]-start[1])/length, -(after[0]-start[0])/length)
        for side in (-1,1):
            x, y = (entry[i]+across[i]*43*side for i in (0,1))
            draw.rectangle((*point((x-7,y-7)), *point((x+7,y+7))), fill=COLORS["gates"])
        # Gate threshold: a flat stroke, no label or decorative illustration.
        ends = [(entry[0]+across[0]*43*s, entry[1]+across[1]*43*s) for s in (-1,1)]
        draw.line([point(p) for p in ends], fill=COLORS["gates"], width=6)
    destination.parent.mkdir(parents=True, exist_ok=True)
    image.save(destination)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("maps", type=Path, nargs="*")
    parser.add_argument("--out", type=Path, default=ROOT / "batches/v15/guides")
    args = parser.parse_args()
    paths = args.maps or sorted(p for p in MAPS.glob("*.json") if not p.stem.startswith("_"))
    for path in paths:
        data = json.loads(path.read_text(encoding="utf-8"))
        destination = args.out / f"{data['id']}.png"
        render(data, destination)
        print(destination.resolve())


if __name__ == "__main__":
    main()
