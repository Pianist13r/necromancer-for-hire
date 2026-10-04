#!/usr/bin/env python3
"""walk_audit.py — аудит ходьбы всех персонажей числом: шагают ли ноги и не скользят ли ступни.

Зачем (Игорь 29.09.2026: «зелёные чуваки в котелках практически не ходят, а просто дрыгаются»):
клипы anim_v4 нарисованы генерацией по одной позе, и у части персонажей ноги за цикл почти не
меняются. Слой живости (char_view.gd) при этом качает корпус, а фигура едет по земле с
неподвижными ступнями — «дрыгается на месте». На глаз это спорно, числом — нет.

Что меряется по кадрам `godot/assets/anim/<char>/walk` (альфа > 16, длительности из clip.json):
  * опора/ход   — ГЛАВНОЕ: скорость опорной ступни назад (медиана по кадрам; сдвиг профиля
                  самых нижних рядов силуэта, ≈1,8 % роста — там остаётся одна опорная ступня;
                  лучший по корреляции), делённая на скорость персонажа в бою. 1 — ступня стоит
                  на земле, 0 — фигура едет по земле «на коньках», больше 1 — ноги перебирают
                  быстрее, чем идёт тело. Проверено на кадрах walk_legs_rig.py, где скорость
                  опоры задана: 0,71–0,93 при заданных 0,70–0,85;
  * касаний     — сколько раз за цикл обе ступни на земле широко (пики ширины той же нижней
                  полосы, запас 8 % роста). У ровного шага 2; 1 — хромота или одна поза;
  * шаг, %      — размах ширины силуэта у земли (нижние 10 % роста) за цикл, в % роста;
  * смена ног   — наибольшая за цикл доля несовпадения силуэта нижней четверти (1 − IoU).
    Последние два — справочные: у застывшей позы с дрожанием генерации они тоже большие
    (нотариус anim_v4: шаг 24,9 %, смена 0,52 при опоре 0), поэтому вердикт по ним не строится,
    кроме «смена < 0,25» (ноги буквально стоят).
Скорость и рост в бою — legion_cfg.gd (FOES[*].speed/body, UNIT_KINDS[*].speed/body_h), темп и
холст — cfg_anim.gd; BATTLE ниже — снимок этих чисел. Тест legion_walk_anim_test.gd считает ту
же опору по живым константам и валится, если она уходит из коридора [0,5; 1,6].

Запуск:  python tools/walk_audit.py [--root godot/assets/anim] [--cfg cfg_anim.gd] [--json out.json]
         [--char signer]
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import re
import sys

import numpy as np
from PIL import Image

ROOT = os.path.join(os.path.dirname(__file__), "..", "godot", "assets", "anim")
CFG_ANIM = os.path.join(os.path.dirname(__file__), "..", "godot", "scripts", "common", "cfg_anim.gd")

## персонаж → (скорость в бою, px мира/с; рост body_h, px; figure_fill из CfgAnim.CHARS;
## ходит ли ногами). Источник: legion_cfg.gd FOES/UNIT_KINDS, cfg_anim.gd CHARS.
BATTLE = {
    "zombie": (34.0, 44.0, 0.75, True),
    "beetle": (70.0, 30.0, 0.75, True),
    "signer": (34.0, 44.0, 0.78, True),
    "ghost": (30.0, 44.0, 0.77, False),   # парит, шага нет
    "mimic": (40.0, 42.0, 0.75, True),
    "boss": (22.0, 46.0 * 2.3, 0.78, True),
    "lawyer": (42.0, 46.0, 0.78, True),
    "skeleton": (70.0, 46.0, 0.85, True),  # подрядчик, UNIT_SPEED
    "guard": (55.0, 50.0, 0.85, True),
    "clerk": (65.0, 42.0, 0.85, True),
}

ALPHA = 16
FOOT_BAND = 0.10      # доля роста у земли для «шага»
LEG_BAND = 0.25       # доля роста для «смены ног»
## Профиль опоры — только самые нижние ряды (≈3 px холста 224): ступня в переносе поднята
## выше, и в полосе остаётся одна опорная. Полоса 5 % роста ловила и переносимую ступню —
## корреляция мешала её бег вперёд с опорой назад и занижала опору вдвое (проверено на кадрах
## walk_legs_rig, где скорость опоры известна точно).
CONTACT_BAND = 0.018
PEAK_PROM = 0.08      # касание — пик ширины опоры (две ступни на земле) с запасом 8 % роста


def walk_fps(char: str, cfg_path: str = CFG_ANIM) -> float:
    src = open(cfg_path, encoding="utf-8").read()
    m = re.search(r'"res://assets/anim/%s/walk",\s*"fps":\s*([0-9.]+)' % char, src)
    return float(m.group(1)) if m else 12.0


def load_clip(char: str, root: str):
    d = os.path.join(root, char, "walk")
    files = sorted(glob.glob(os.path.join(d, "spr_*.png")))
    masks = [np.asarray(Image.open(f).convert("RGBA"))[:, :, 3] > ALPHA for f in files]
    meta = {}
    if os.path.exists(os.path.join(d, "clip.json")):
        meta = json.load(open(os.path.join(d, "clip.json"), encoding="utf-8"))
    durs = meta.get("durations", [1.0] * len(files))
    return masks, [float(x) for x in durs]


def peaks_cyclic(v: np.ndarray, prom: float) -> int:
    """Число пиков цикла с перепадом ≥ prom до соседнего провала с обеих сторон."""
    n = len(v)
    if n < 3 or v.max() - v.min() < prom:
        return 0
    # начинаем с глобального минимума, чтобы петля не резала пик пополам
    start = int(np.argmin(v))
    seq = np.concatenate([v[start:], v[:start], v[start:start + 1]])
    count, lo, hi, rising = 0, seq[0], seq[0], True
    for x in seq[1:]:
        if rising:
            hi = max(hi, x)
            if hi - x >= prom and hi - lo >= prom:
                count += 1
                rising, lo = False, x
        else:
            lo = min(lo, x)
            if x - lo >= prom:
                rising, hi = True, x
    return count


def contact_shift(p0: np.ndarray, p1: np.ndarray, max_d: int) -> int:
    """Сдвиг d профиля опоры p0 → p1 (p1(x) ≈ p0(x − d)); лучшая корреляция, при равенстве — меньший |d|."""
    best, best_d = -1.0, 0
    n = len(p0)
    for d in sorted(range(-max_d, max_d + 1), key=abs):
        if d >= 0:
            a, b = p0[: n - d], p1[d:]
        else:
            a, b = p0[-d:], p1[: n + d]
        s = float(np.minimum(a, b).sum())
        if s > best + 1e-6:
            best, best_d = s, d
    return best_d


def audit(char: str, root: str, cfg_path: str = CFG_ANIM) -> dict:
    masks, durs = load_clip(char, root)
    speed, body_h, fill, legged = BATTLE[char]
    fps = walk_fps(char, cfg_path)
    canvas = masks[0].shape[1]
    scale = body_h / (canvas * fill)             # px мира на px холста
    rows = [np.where(m.any(axis=1))[0] for m in masks]
    tops = np.array([r.min() for r in rows])
    bots = np.array([r.max() for r in rows])
    h = float(np.median(bots - tops))
    ground = int(np.median(bots))
    n = len(masks)

    def band(m, frac):
        out = np.zeros_like(m)
        y0 = int(ground - frac * h)
        out[y0: ground + 1] = m[y0: ground + 1]
        return out

    spread = []
    for m in masks:
        xs = np.where(band(m, FOOT_BAND).any(axis=0))[0]
        spread.append(float(xs.max() - xs.min()) if len(xs) else 0.0)
    spread = np.array(spread)
    legs = [band(m, LEG_BAND) for m in masks]
    change = 0.0
    for i in range(n):
        for j in range(i + 1, n):
            u = np.logical_or(legs[i], legs[j]).sum()
            if u:
                change = max(change, 1.0 - np.logical_and(legs[i], legs[j]).sum() / u)
    prof = [band(m, CONTACT_BAND).sum(axis=0).astype(float) for m in masks]
    ground_w = []
    for p in prof:
        xs = np.where(p > 0)[0]
        ground_w.append(float(xs.max() - xs.min()) if len(xs) else 0.0)
    ground_w = np.array(ground_w)
    max_d = int(0.25 * h)
    speeds = []
    for i in range(n):
        d = contact_shift(prof[i], prof[(i + 1) % n], max_d)
        dt = durs[i] / fps
        speeds.append(-d * scale / dt)             # назад (−x) — положительно
    cycle = sum(durs) / fps
    foot_v = float(np.median(speeds))
    res = {
        "char": char, "frames": n, "fps": fps, "cycle_s": round(cycle, 3),
        "speed": speed, "height_px": round(h, 1),
        "step_pct": round(100.0 * (spread.max() - spread.min()) / h, 1),
        "leg_change": round(change, 3),
        "contacts": peaks_cyclic(ground_w / h, PEAK_PROM),
        "foot_speed": round(foot_v, 1),
        "support_ratio": round(foot_v / speed, 2) if speed else 0.0,
        # какой длины шаг нужен, чтобы ступни не скользили: путь за полцикла, в % роста
        "need_step_pct": round(100.0 * speed * cycle / 2.0 / (h * scale), 1),
        "legged": legged,
    }
    res["verdict"] = verdict(res)
    return res


def verdict(r: dict) -> str:
    if not r["legged"]:
        return "парит — шаг не нужен"
    bad = []
    if r["contacts"] < 2 or r["leg_change"] < 0.25:
        bad.append("ноги не шагают")
    if r["support_ratio"] < 0.5:
        bad.append("скользит")
    elif r["support_ratio"] > 1.6:
        bad.append("ноги быстрее тела")
    return "OK" if not bad else "ПЛОХО: " + ", ".join(bad)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=ROOT)
    ap.add_argument("--json")
    ap.add_argument("--char", action="append")
    ap.add_argument("--cfg", default=CFG_ANIM, help="cfg_anim.gd с темпом клипов (для старых снимков)")
    a = ap.parse_args()
    chars = a.char or list(BATTLE)
    out = [audit(c, a.root, a.cfg) for c in chars if os.path.isdir(os.path.join(a.root, c, "walk"))]
    hdr = f"{'персонаж':9} {'кадр':>4} {'цикл,с':>6} {'шаг%':>5} {'смена':>6} {'касан':>5} " \
          f"{'ступня':>6} {'ход':>5} {'опора':>5}  вердикт"
    print(hdr)
    for r in out:
        print(f"{r['char']:9} {r['frames']:4d} {r['cycle_s']:6.2f} {r['step_pct']:5.1f} "
              f"{r['leg_change']:6.3f} {r['contacts']:5d} {r['foot_speed']:6.1f} {r['speed']:5.0f} "
              f"{r['support_ratio']:5.2f}  {r['verdict']}")
    if a.json:
        json.dump(out, open(a.json, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    return 0


if __name__ == "__main__":
    sys.exit(main())
