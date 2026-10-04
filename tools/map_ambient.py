"""Данные фоновой жизни карты (godot/assets/legion/ambient/<map>.json) по нарисованному фону.

Зачем (v19, 26.09.2026, Игорь: «чтобы при разглядывании было прямо красиво»): на фонах
нарисованы свечи, фонари, лавовые трещины, огоньки, вода — но всё это стоит. Слой LegionFx
(scripts/legion/fx) оживляет их по данным: мерцающие ореолы, угли, огоньки, блики, туман.
Руками размечать сотни свечей долго и неточно, поэтому точки берутся с самой картинки:

- glows — яркие тёплые пятна (свечи, фонари, окна): светлота > 0,82 и R − B > 0,25;
- embers — области с плотными красно-оранжевыми трещинами (лава);
- wisps — бирюзовые/мятные светящиеся пятна (нарисованные огоньки);
- water — полигоны воды из карты (json), кроме маленьких луж;
- fog — задаётся вручную (FOG ниже), по рисунку.

  python tools/map_ambient.py <map> [--show out.png]

Координаты — мира (1280×720), фон 1920×1080 = ×1,5.
"""
import argparse
import json
import os

import cv2
import numpy as np
from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MAPS = f"{ROOT}/godot/assets/legion/maps"
K = 1.5
MAX_GLOWS = 18
## туман — по рисунку: где на фоне нарисована дымка (прямоугольники мира)
FOG = {
    "fork": [{"rect": [0, 120, 260, 480], "count": 4, "color": "b8f0e6", "alpha": 0.10, "drift": [5, 1]}],
    "swamp": [{"rect": [380, 300, 380, 300], "count": 4, "color": "c8f0dc", "alpha": 0.08, "drift": [4, 0]}],
    "bridge": [{"rect": [560, 0, 220, 720], "count": 3, "color": "d6f2ff", "alpha": 0.07, "drift": [0, 4]}],
    "maze": [{"rect": [0, 0, 1280, 720], "count": 3, "color": "d8d0f0", "alpha": 0.05, "drift": [5, 0]}],
    # «Архив»: пыльная взвесь над залами стеллажей
    "archive": [{"rect": [440, 0, 840, 720], "count": 3, "color": "f0e2c8", "alpha": 0.05, "drift": [3, 1]}],
}
## «Прораб» — тёплая терракота: оранжевая земля сходит за лаву, трещин с огнём там нет
EMBER_MAPS = {"wasteland"}
## без ореолов: на «Архиве» все свечи стоят на площадках (там постройка), а «ярко и тёпло» ловит
## освещённую мостовую и листы бумаги (проба: 18 и 11 ложных огней)
NO_GLOW_MAPS = {"archive"}
WISP_MAPS = {"maze", "swamp"}


def blobs(mask: np.ndarray, min_area: int, max_area: int) -> list[tuple[float, float, float]]:
    n, _, stats, cent = cv2.connectedComponentsWithStats(mask.astype(np.uint8), 8)
    out = []
    for i in range(1, n):
        a = stats[i, cv2.CC_STAT_AREA]
        if min_area <= a <= max_area:
            out.append((float(cent[i][0]), float(cent[i][1]), float(a)))
    return out


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("map")
    ap.add_argument("--show")
    a = ap.parse_args()
    bg = np.asarray(Image.open(f"{MAPS}/{a.map}_bg.jpg").convert("RGB"), dtype=np.float32) / 255.0
    m = json.load(open(f"{MAPS}/{a.map}.json", encoding="utf8"))
    r, g, b = bg[..., 0], bg[..., 1], bg[..., 2]
    lum = 0.299 * r + 0.587 * g + 0.114 * b
    data: dict = {}
    # ореолы: самые яркие тёплые пятна; сильные — первыми
    warm = (lum > 0.82) & (r - b > 0.25)
    warm = cv2.morphologyEx(warm.astype(np.uint8), cv2.MORPH_CLOSE, np.ones((5, 5), np.uint8))
    gl = sorted(blobs(warm, 12, 4000), key=lambda t: -t[2])
    glows, taken = [], []
    # золотые диски площадок и круг Котла — не огни: ореол там мерцал бы под постройкой
    busy = [np.array(pl["pos"], dtype=float) for pl in m.get("plots", [])]
    if "cauldron" in m:
        busy.append(np.array(m["cauldron"], dtype=float))
    for x, y, area in ([] if a.map in NO_GLOW_MAPS else gl):
        p = np.array([x, y]) / K
        if any(np.linalg.norm(p - q) < 26 for q in taken):
            continue
        if any(np.linalg.norm(p - q) < 44 for q in busy):
            continue
        taken.append(p)
        rad = float(np.clip(10 + np.sqrt(area) * 0.9, 14, 42))
        glows.append({"pos": [round(p[0]), round(p[1])], "r": round(rad), "color": "ffb35c",
                      "flicker": 0.25})
        if len(glows) >= MAX_GLOWS:
            break
    data["glows"] = glows
    if a.map in EMBER_MAPS:
        lava = (r > 0.75) & (g > 0.25) & (g < 0.65) & (b < 0.35) & (r - g > 0.3)
        # плотность лавы по сетке 80×80 мира — угли там, где трещины гуще
        cell = int(80 * K)
        embers = []
        for y0 in range(0, lava.shape[0] - cell + 1, cell):
            for x0 in range(0, lava.shape[1] - cell + 1, cell):
                if lava[y0:y0 + cell, x0:x0 + cell].mean() > 0.0025:
                    embers.append({"rect": [round(x0 / K), round(y0 / K), 80, 80], "rate": 0.6,
                                   "color": "ff7a30"})
        data["embers"] = embers[:14]
    if a.map in WISP_MAPS:
        cyan = (g > 0.75) & (b > 0.6) & (r < 0.6) & (lum > 0.6)
        wp = sorted(blobs(cyan, 30, 6000), key=lambda t: -t[2])[:6]
        data["wisps"] = [{"rect": [round(x / K) - 40, round(y / K) - 30, 80, 60], "count": 1,
                          "color": "7fffd8"} for x, y, _ in wp]
    water = []
    # вода (река) — частые холодные блики; топь — реже и зеленоватые
    for key, rate, color in (("water", 3.0, "e0f6ff"), ("swamp", 1.2, "d0ffe8")):
        for poly in m.get(key, []):
            arr = np.array(poly, dtype=np.float32)
            if cv2.contourArea(arr) > 4000:
                water.append({"poly": [[round(float(px)), round(float(py))] for px, py in poly],
                              "rate": rate, "color": color})
    if water:
        data["water"] = water
    if a.map in FOG:
        data["fog"] = FOG[a.map]
    # своя папка: Campaign.maps() берёт в кампанию любой *.json из папки карт
    out = f"{ROOT}/godot/assets/legion/ambient/{a.map}.json"
    with open(out, "w", encoding="utf8", newline="\n") as fh:
        json.dump(data, fh, ensure_ascii=False, indent=1)
    print(out, {k: len(v) for k, v in data.items()})
    if a.show:
        im = Image.open(f"{MAPS}/{a.map}_bg.jpg").convert("RGB").resize((1280, 720))
        d = ImageDraw.Draw(im)
        for gw in glows:
            x, y, rr = gw["pos"][0], gw["pos"][1], gw["r"]
            d.ellipse([x - rr, y - rr, x + rr, y + rr], outline=(255, 255, 0))
        for e in data.get("embers", []):
            x, y, w, h = e["rect"]
            d.rectangle([x, y, x + w, y + h], outline=(255, 80, 0))
        for w_ in data.get("wisps", []):
            x, y, w, h = w_["rect"]
            d.rectangle([x, y, x + w, y + h], outline=(0, 255, 200))
        for f in data.get("fog", []):
            x, y, w, h = f["rect"]
            d.rectangle([x, y, x + w, y + h], outline=(200, 200, 255))
        for wt in water:
            d.polygon([tuple(p) for p in wt["poly"]], outline=(0, 160, 255))
        im.save(a.show)


if __name__ == "__main__":
    main()
