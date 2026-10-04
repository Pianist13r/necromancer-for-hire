#!/usr/bin/env python3
"""clerk_attack_legs.py — ноги клипа attack счетовода в форму ног нового покоя/ходьбы (B-207).

Зачем. Ходьба и покой счетовода теперь с ногами-трубками (tools/walk_legs_rig.py), а attack —
прежний косой клин штанов и низкие ботинки: на смене клипа ноги «перескакивают» (форма, ширина,
линия земли). Платная перерисовка не нужна: верх (корпус, руки, швабра-печать) остаётся как есть,
меняется только то, что ниже подола.

Как устроено (те же детали, что у ходьбы — draw_tube/cut_boot из walk_legs_rig.py):
  * исходные кадры атаки лежат в tools/walk_rig_masters/clerk_attack/ (неизменные копии; скрипт
    можно гонять повторно) — таймингов и contact_frame это не касается: число и порядок кадров те же;
  * стирается всё, что относится к штанам и ботинкам: зелёные штаны, два ботинка (тёмная бирюза,
    отдельные связные куски у самой земли) и их контур (тёмный пиксель принадлежит ближайшему
    цветному куску; ничья — остаётся корпусу). Швабра, руки, рубашка не тронуты;
  * позади корпуса рисуются две штанины-трубки цветом штанов мастера ходьбы и его ботинки
    (вырезка из мастера, выровнена в плоскую стойку), обе стопы на земле `GROUND` = 219 — тот же
    ряд, что у покоя/ходьбы/hit/spawn (у attack ботинки стояли на 214–216: клип «парил»/тонул на
    смене). Стойка шире покоя (`SPREAD`): замах — с упором на ноги;
  * верх трубки прячется под подолом: подол = верхний край стёртых штанов.

Запуск: python tools/clerk_attack_legs.py [--out ПАПКА] (по умолчанию — godot/assets/anim/clerk/attack)
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import sys

import numpy as np
from PIL import Image
from scipy import ndimage

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import walk_legs_rig as rig  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "walk_rig_masters", "clerk_attack")
DST = os.path.join(HERE, "..", "godot", "assets", "anim", "clerk", "attack")
GROUND = 219        # ряд холста, на котором стоят подошвы (как у покоя/ходьбы/hit/spawn)
SPREAD = 12.0       # разнос ступней в стойке замаха, px холста (у покоя ~3)
HEM_UP = 6          # верх трубки заходит под подол на столько px


def classify(a: np.ndarray) -> tuple:
    """Маски штанов и ботинок и «стираемые» пиксели (штаны, ботинки, их контур)."""
    r, g, b = (a[:, :, i].astype(int) for i in range(3))
    al = a[:, :, 3] > 128
    yy = np.mgrid[0:a.shape[0], 0:a.shape[1]][0]
    mx = np.maximum(np.maximum(r, g), b)
    mn = np.minimum(np.minimum(r, g), b)
    sat = (mx - mn) / np.maximum(mx, 1)
    # штаны — зелёные (в т.ч. тёмные складки), ботинки/швабра — бирюза (синий выше зелёного-ish)
    green = al & (g == mx) & (sat > 0.28) & (mx > 40) & (g - b > 0.22 * g)
    pants = green & (yy >= 140)
    teal = al & (b > r + 45) & (g > r + 45) & ~green
    lab, n = ndimage.label(teal)
    boots = np.zeros_like(teal)
    for k in range(1, n + 1):
        ys, xs = np.where(lab == k)
        if len(ys) >= 100 and ys.min() >= 195 and ys.mean() >= 204:
            boots |= lab == k
    lum = (0.299 * r + 0.587 * g + 0.114 * b)
    colored = al & (lum > 75) & ~(pants | boots)
    # расстояние до «наших» и до «чужих» цветных пикселей: контур уходит к ближайшему
    d_legs = ndimage.distance_transform_edt(~(pants | boots))
    d_keep = ndimage.distance_transform_edt(~colored)
    dark = (a[:, :, 3] > 0) & ~(pants | boots | colored)
    # контур ног, а также осколки контура, что не прижаты к цветному корпусу (>3 px от него)
    erase = pants | boots | (dark & (d_legs < d_keep) & (d_legs <= 4.0)) | (
        dark & (d_keep > 3.2) & (d_legs <= 10.0))
    # полупрозрачная кайма самих штанов/ботинок
    edge = (a[:, :, 3] > 0) & ~erase & ~colored & (d_legs <= 2.0) & (d_legs < d_keep)
    return pants, boots, erase | edge


def build_frame(a: np.ndarray, tools: dict) -> np.ndarray:
    pants, boots, erase = classify(a)
    body = a.copy()
    body[erase] = 0
    # крошки контура стёртых ног (мелкие отдельные пятна) — прочь, как у ходьбы
    lab, n = ndimage.label(body[:, :, 3] > 0, structure=np.ones((3, 3), bool))
    if n > 1:
        sizes = ndimage.sum(np.ones_like(lab), lab, range(1, n + 1))
        for k, sz in enumerate(sizes, start=1):
            if sz < 60:
                body[lab == k] = 0
    h, w = a.shape[:2]
    ys, xs = np.where(pants)
    tops = []
    for x in range(int(xs.min()), int(xs.max()) + 1):
        col = np.where(pants[:, x])[0]
        if len(col):
            tops.append(col.min())
    hem = float(np.percentile(tops, 15))
    bys, bxs = np.where(boots)
    cx = float(bxs.mean())
    frame = np.zeros_like(a)
    hidden = (np.mgrid[0:h, 0:w][0] < hem) & (body[:, :, 3] == 0)
    boot, ank0, depth = tools["boot"], tools["ank0"], tools["depth"]
    ay = GROUND - depth
    for name, side, shade in (("far", -1, 0.8), ("near", 1, 1.0)):
        ax = cx + side * SPREAD / 2.0
        hx = cx + side * SPREAD / 2.0
        leg = rig.draw_tube((w, h), (hx, hem - HEM_UP), (ax, ay), tools["w_top"], tools["w_bot"],
                            tools["fill"], tools["shade"], tools["ink"], tools["outline"])
        b = rig.shift(boot, ax - ank0[0], ay - ank0[1])
        layer = rig.over(leg, b).copy()
        layer[hidden] = 0
        if shade != 1.0:
            layer[:, :, :3] = (layer[:, :, :3].astype(float) * shade).astype(np.uint8)
        frame = rig.over(frame, layer)
    return rig.over(frame, body)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=DST)
    a = ap.parse_args()
    cfg = json.load(open(os.path.join(rig.MASTERS, "rig.json"), encoding="utf-8"))["clerk"]
    master = np.asarray(Image.open(os.path.join(rig.MASTERS, "clerk.png")).convert("RGBA")).copy()
    d = cfg["draw"]
    ank0 = tuple(d["boot"]["ankle"])
    boot = rig.rotate_piece(rig.cut_boot(master, d["boot"]), float(d["boot"].get("flatten_deg", 0.0)), ank0)
    fill = master[d["fill_at"][1], d["fill_at"][0], :3]
    tools = {
        "boot": boot, "ank0": ank0, "depth": rig.lowest(boot) - ank0[1],
        "w_top": d["w_top"], "w_bot": d["w_bot"], "fill": fill,
        "shade": master[d["shade_at"][1], d["shade_at"][0], :3], "ink": rig.outline_color(master),
        "outline": float(d.get("outline", 2.0)),
    }
    os.makedirs(a.out, exist_ok=True)
    files = sorted(glob.glob(os.path.join(SRC, "spr_*.png")))
    for f in files:
        img = np.asarray(Image.open(f).convert("RGBA")).copy()
        Image.fromarray(build_frame(img, tools), "RGBA").save(os.path.join(a.out, os.path.basename(f)))
    print(f"attack: {len(files)} кадров -> {a.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
