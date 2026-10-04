"""Сверка препятствий карты с её фоном: кроп фона в мировых координатах, сетка и коллизия.

Зачем (v19 «стены по рисунку», сессия d26f8623, 26.09.2026): коллизия карт разошлась с
нарисованным фоном — стены на рисунке были проходимы, а на траве стояли невидимые скалы.
Этим видом обводились препятствия всех шести карт; он же нужен, если фон перерисуют.

  python tools/map_obstacles_view.py <map> [x0 y0 x1 y1] [--scale 2] [--draft файл.json] [--out файл.png]

Сетка — через 10 px мира (яркая с подписью — через 50). Красное — rocks, оранжевое — walls
(толщина w), жёлтое — оси дорог, голубое — площадки, зелёное — рубежи бота. Черновик
(--draft, {"rocks": [...], "walls": [...]}) показывается вместо того, что в карте.
Полосу ROAD_CLEAR у дорог (игра срезает по ней препятствия) вид не вычитает.
"""
import argparse
import json
import os

from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

ap = argparse.ArgumentParser()
ap.add_argument("map")
ap.add_argument("box", nargs="*", type=float, help="x0 y0 x1 y1 (по умолчанию вся карта)")
ap.add_argument("--scale", type=float, default=1.0)
ap.add_argument("--draft")
ap.add_argument("--out")
a = ap.parse_args()
x0, y0, x1, y1 = a.box if len(a.box) == 4 else (0.0, 0.0, 1280.0, 720.0)
maps = f"{ROOT}/godot/assets/legion/maps"
m = json.load(open(f"{maps}/{a.map}.json", encoding="utf8"))
draft = json.load(open(a.draft, encoding="utf8")) if a.draft else {}
bg = Image.open(f"{maps}/{a.map}_bg.jpg").convert("RGB")
k = bg.size[0] / 1280.0
W, H = int((x1 - x0) * a.scale), int((y1 - y0) * a.scale)
img = bg.crop((int(x0 * k), int(y0 * k), int(x1 * k), int(y1 * k))).resize((W, H), Image.LANCZOS)
img = img.convert("RGBA")
ov = Image.new("RGBA", (W, H), (0, 0, 0, 0))
d = ImageDraw.Draw(ov)


def P(p):
    return ((p[0] - x0) * a.scale, (p[1] - y0) * a.scale)


for r in m.get("roads", []):
    d.line([P(p) for p in r["path"]], fill=(255, 230, 0, 160), width=2)
for poly in draft.get("rocks", m.get("rocks", [])):
    # только контур: заливка закрывала рисунок, и нарисованные валуны «Моста» и «Болота»
    # сочли невидимыми скалами и убрали (verifier сессии d26f8623 опроверг)
    d.line([P(p) for p in poly] + [P(poly[0])], fill=(255, 40, 40, 255), width=2)
for key in ("water", "bridges"):
    for poly in m.get(key, []):
        d.polygon([P(p) for p in poly], outline=(0, 160, 255, 255))
for wl in draft.get("walls", m.get("walls", [])):
    pts = [P(p) for p in wl["path"]]
    # стена — осевая и две кромки, без заливки (рисунок под ней должен быть виден)
    d.line(pts, fill=(255, 255, 255, 230), width=1)
    half = wl["w"] * 0.5 * a.scale
    for i in range(1, len(pts)):
        # не x0/y0: это рамка кадра, P() и сетка ниже читают её
        (ax, ay), (bx, by) = pts[i - 1], pts[i]
        L = max(((bx - ax) ** 2 + (by - ay) ** 2) ** 0.5, 0.001)
        nx, ny = -(by - ay) / L * half, (bx - ax) / L * half
        for s in (1, -1):
            d.line([(ax + s * nx, ay + s * ny), (bx + s * nx, by + s * ny)], fill=(255, 140, 0, 255), width=2)
for p in m.get("plots", []):
    c = P(p["pos"])
    d.rectangle([c[0] - 3, c[1] - 3, c[0] + 3, c[1] + 3], fill=(0, 255, 255, 255))
for b in m.get("bot_lines", []):
    d.line([P(b["a"]), P(b["b"])], fill=(0, 255, 120, 255), width=2)
for axis, lo, hi, span in (("x", x0, x1, H), ("y", y0, y1, W)):
    v = int(lo // 10 * 10)
    while v <= hi:
        t = (v - lo) * a.scale
        major = v % 50 == 0
        line = [(t, 0), (t, span)] if axis == "x" else [(0, t), (span, t)]
        d.line(line, fill=(255, 255, 255, 110 if major else 35), width=1)
        if major:
            d.text((t + 2, 2) if axis == "x" else (2, t + 2), str(v), fill=(255, 255, 255, 255))
        v += 10
out = a.out or f"{a.map}_obstacles.png"
Image.alpha_composite(img, ov).convert("RGB").save(out)
print(out, W, H)
