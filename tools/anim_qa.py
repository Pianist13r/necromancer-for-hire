#!/usr/bin/env python3
"""
anim_qa.py — числовая приёмка клипа анимации.

Зачем: три захода подряд клипы принимались и отвергались «на глаз», и каждый раз спор
упирался в ощущения. Здесь считаются те свойства, по которым клип реально разваливается:

  * дрейф якоря      — качается ли персонаж вбок и не уезжает ли линия земли;
  * постоянство тела — не «дышит» ли персонаж (рост, ширина, площадь силуэта, размер головы);
  * равномерность фаз — не рвётся ли движение (разница силуэтов соседних кадров);
  * замыкание петли  — стыкуется ли последний кадр с первым (для циклов).

Пороги взяты из практики проекта и скилла ai-game-art-pipeline:
дрейф якоря — единицы пикселей; «дыхание» тела — до нескольких процентов;
разница соседних кадров около 100/N процентов, разброс не шире ±40 % относительно.

Запуск:
    python tools/anim_qa.py assets/anim-lab/out/walk_v2/sprites [--loop]
"""
from __future__ import annotations

import argparse
import pathlib
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from anim_post import head_center_x


def feet_spread(mask: np.ndarray) -> tuple[float, float]:
    """Разнос стоп (ширина силуэта в нижней пятой части) и высота фигуры.

    ЗАЧЕМ ЭТО ГЛАВНАЯ МЕТРИКА. В сессии 2026-08-26 клип был принят по «стабильности
    тела» — а у статуи стабильность идеальная. Персонаж почти не двигал ногами, и
    все прочие метрики от этого только улучшались. Проверять НАЛИЧИЕ движения надо
    ПЕРВЫМ делом, иначе приёмка поощряет неподвижность.
    """
    ys, xs = np.where(mask)
    if len(xs) == 0:
        return 0.0, 0.0
    top, bot = ys.min(), ys.max()
    band = ys >= bot - max(1, int((bot - top) * 0.20))
    return float(xs[band].max() - xs[band].min()), float(bot - top)


def spread(values: list[float]) -> float:
    return max(values) - min(values) if values else 0.0


def rel_spread(values: list[float]) -> float:
    """Разброс в процентах от среднего — «дыхание» персонажа."""
    if not values:
        return 0.0
    m = sum(values) / len(values)
    return 100.0 * (max(values) - min(values)) / m if m else 0.0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("sprites_dir")
    ap.add_argument("--loop", action="store_true", help="клип циклический — проверять стык конца с началом")
    a = ap.parse_args()

    files = sorted(pathlib.Path(a.sprites_dir).glob("*.png"))
    if not files:
        raise SystemExit(f"кадров не найдено: {a.sprites_dir}")

    heads, feet, heights, widths, areas, head_w, masks = [], [], [], [], [], [], []
    step_spreads: list[float] = []
    for f in files:
        im = Image.open(f)
        arr = np.array(im.convert("RGBA"))
        if arr[:, :, 3].min() > 250:
            # кадр без прозрачности (сырой выход генерации на ровном фоне): маску
            # считаем по отличию от фона, иначе «силуэтом» окажется весь кадр и
            # приёмка честно покажет нули, ничего на самом деле не проверив
            rgb = arr[:, :, :3].astype(np.int16)
            corner = rgb[2, 2]
            m = np.abs(rgb - corner).max(axis=2) > 42
        else:
            m = arr[:, :, 3] > 30
        ys, xs = np.where(m)
        if len(xs) == 0:
            print(f"ПУСТОЙ КАДР: {f.name}")
            continue
        masks.append(m)
        heads.append(head_center_x(m))
        feet.append(int(ys.max()))
        heights.append(int(ys.max() - ys.min()))
        widths.append(int(xs.max() - xs.min()))
        areas.append(int(m.sum()))
        top = ys.min()
        band = ys <= top + max(1, int((ys.max() - top) * 0.18))
        head_w.append(int(xs[band].max() - xs[band].min()))
        sp, _ = feet_spread(m)
        step_spreads.append(sp)

    diffs = []
    for i in range(len(masks) - 1):
        diffs.append(100.0 * np.logical_xor(masks[i], masks[i + 1]).sum() / max(1, masks[i].sum()))
    if a.loop and len(masks) > 1:
        diffs.append(100.0 * np.logical_xor(masks[-1], masks[0]).sum() / max(1, masks[-1].sum()))

    n = len(masks)
    target = 100.0 / n
    print(f"клип: {a.sprites_dir}")
    print(f"кадров: {n}")
    print()
    print("ЕСТЬ ЛИ ДВИЖЕНИЕ (главная проверка — её отсутствие однажды стоило целой сессии)")
    if step_spreads and heights:
        amp = spread(step_spreads)
        rel = 100.0 * amp / (sum(heights) / len(heights))
        verdict = "OK" if rel >= 12.0 else ("СЛАБОЕ" if rel >= 6.0 else "ДВИЖЕНИЯ НЕТ")
        print(f"  размах разноса стоп: {amp:.0f} px = {rel:.1f} % роста   {verdict}")
        print(f"  (для ходьбы ждём 12 % и выше; ниже 6 % — персонаж топчется на месте)")
    print()
    print("ЯКОРЬ (персонаж не должен качаться и уезжать)")
    print(f"  центр головы   : разброс {spread(heads):.0f} px      {'OK' if spread(heads) <= 4 else 'ПЛОХО'}")
    print(f"  линия подошвы  : разброс {spread(feet):.0f} px      {'OK' if spread(feet) <= 4 else 'ПЛОХО'}")
    print()
    print("ПОСТОЯНСТВО ТЕЛА (персонаж не должен «дышать» между кадрами)")
    # «Разброс» не отличает ПРЕДНАМЕРЕННОЕ движение (присед/боб у рига или у рисованной
    # анимации — плавная синусоида) от СЛУЧАЙНОГО дрожания идентичности у генерации.
    # Отличает «рывок» — максимум второй разности: у плавной кривой он мал при любом
    # размахе, у случайного дрожания сравним с самим разбросом (добавлено 2026-08-26).
    # Пороги рывка откалиброваны замером 2026-08-26 на трёх известных клипах: риг v3
    # (плавный, рывок роста 5.5 из-за ударного приседа), walk_v2 (дрожь идентичности:
    # 16-50 %), walk_wan16 (статуя: 1.4). Ударный акцент рисованной анимации легитимен
    # до ~8 % роста; дрейф идентичности — двузначный.
    for name, vals, limit, jerk_limit in (
            ("рост", heights, 6.0, 8.0), ("ширина", widths, 25.0, 12.0),
            ("площадь силуэта", areas, 18.0, 9.0), ("ширина головы", head_w, 8.0, 4.0)):
        fvals = [float(v) for v in vals]
        rs = rel_spread(fvals)
        m = sum(fvals) / len(fvals) if fvals else 1.0
        ring = fvals + fvals[:2] if a.loop else fvals
        jerk = max((abs(ring[i - 1] - 2 * ring[i] + ring[i + 1])
                    for i in range(1, len(ring) - 1)), default=0.0)
        jerk_pct = 100.0 * jerk / m if m else 0.0
        rs_mark = "OK" if rs <= limit else "ПЛОХО (порог " + str(limit) + " %)"
        jk_mark = "плавно" if jerk_pct <= jerk_limit else "ДРОЖИТ (порог " + str(jerk_limit) + " %)"
        print(f"  {name:16s}: разброс {rs:5.1f} %   {rs_mark:24s} рывок {jerk_pct:4.1f} %   {jk_mark}")
    print()
    print("ФАЗЫ (движение не должно рваться и топтаться)")
    if diffs:
        lo, hi = min(diffs), max(diffs)
        ratio = hi / lo if lo > 0 else float("inf")
        # Важна РАВНОМЕРНОСТЬ, а не абсолютная величина: у размашистой ходьбы соседние
        # кадры честно отличаются сильно. Рвётся движение тогда, когда одни переходы
        # много больше других — то есть когда велико отношение max/min.
        print(f"  разница соседних кадров: {lo:.1f}…{hi:.1f} % (равномерный цикл дал бы ~{target:.1f} %)")
        print(f"  неравномерность max/min: {ratio:.1f}x   "
              f"{'OK' if ratio <= 1.8 else 'ПЛОХО — часть переходов рвёт движение'}")
        if a.loop:
            print(f"  стык конца с началом    : {diffs[-1]:.1f} % "
                  f"{'OK' if diffs[-1] <= hi else 'ПЛОХО — рывок на стыке петли'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
