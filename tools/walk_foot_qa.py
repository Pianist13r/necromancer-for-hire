#!/usr/bin/env python3
"""
walk_foot_qa.py — футпланинг и темп ходьбы рига ПО ПИКСЕЛЯМ ботинка.

Зачем (2026-09-23): anim_qa.py меряет движение и «дыхание» силуэта, но не отвечает на
два вопроса приёмки ходьбы: скользит ли опорная стопа и совпадает ли темп клипа со
скоростью персонажа в бою (Cfg.SKELETON_SPEED = 135 px/с). Цель IK рига в опоре стоит
идеально (лог --drive), но зритель видит не цель, а ботинок — а ботинок крутится вокруг
«колена» рига и садится на землю не ровно в цель. Поэтому мерить надо по пикселям, и по
каждой ноге ОТДЕЛЬНО: в профиль ноги перекрываются.

Вход — три прогона харнесса с одинаковыми параметрами ходьбы:
  полный кадр (для масштаба постобработки) и два QA-прогона `--drive-solo-leg near|far`;
  лог полного прогона (JSON-строка харнесса с "feet") — скорость цели IK в опоре.

Запуск:
  python tools/walk_foot_qa.py --clip ПАПКА --near ПАПКА --far ПАПКА --log ЛОГ.json [--fps 12]

Что печатает (render px — пиксели кадра харнесса 832x480, game px — экран боя):
  * земля ботинка и «зарывание» (насколько ниже земли уходит носок в переносе);
  * скольжение опорной стопы: отклонение шага ботинка от шага цели IK за кадр опоры;
  * темп: при каком fps клипа ботинок в опоре едет назад ровно со скоростью персонажа.
"""
from __future__ import annotations

import argparse
import json
import pathlib
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from anim_post import FLAT_TOL, largest_component  # noqa: E402

BG = np.array([128, 128, 128])
# Экран боя: CharAnim рисует холст 460 px с масштабом body_h / (460 * 0.85),
# body_h = ANCHOR_PX * VIS_SKELETON.visual = 137.65 * 0.80 (godot/scripts/game/cfg.gd).
GAME_SCALE = 137.65 * 0.80 / (460.0 * 0.85)
CANVAS = 460
SPEED = 135.0


def masks(d: pathlib.Path) -> list[np.ndarray]:
    out = []
    for f in sorted(d.glob("frame_*.png")):
        a = np.array(Image.open(f).convert("RGB")).astype(np.int16)
        out.append(np.abs(a - BG).max(axis=2) > FLAT_TOL)
    return out


def post_scale(full: list[np.ndarray]) -> float:
    """Тот же коэффициент, что anim_post.process_fixed (общий bbox клипа → холст 460)."""
    union = np.zeros_like(full[0])
    for m in full:
        union |= largest_component(m)
    ys, xs = np.where(union)
    return min(CANVAS * 0.92 / (ys.max() + 1 - ys.min()), CANVAS * 0.96 / (xs.max() + 1 - xs.min()))


def sole(m: np.ndarray, band: int = 25) -> tuple[float, float]:
    """x — середина ботинка (размах пикселей в нижних 25 px), y — нижний пиксель.
    Середину размаха, а не среднее самой нижней полоски: при перекате самой нижней
    оказывается то пятка, то носок, и среднее полоски прыгает на полботинка."""
    ys, xs = np.where(m)
    bot = ys.max()
    sel = ys >= bot - band
    return 0.5 * float(xs[sel].min() + xs[sel].max()), float(bot)


def contact_width(m: np.ndarray, ground: float) -> float:
    """Размах пикселей ботинка в полосе 2 px над землёй (0 — ботинок оторван)."""
    ys, xs = np.where(m)
    sel = ys >= ground - 2
    return float(xs[sel].max() - xs[sel].min()) if sel.any() else 0.0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--clip", required=True)
    ap.add_argument("--near", required=True)
    ap.add_argument("--far", required=True)
    ap.add_argument("--log", required=True)
    ap.add_argument("--fps", type=float, default=12.0)
    a = ap.parse_args()

    log = json.loads(pathlib.Path(a.log).read_text(encoding="utf-8"))
    feet = log["feet"]
    n = len(feet)
    k = post_scale(masks(pathlib.Path(a.clip))) * GAME_SCALE   # render px → game px
    print(f"кадров: {n}   render px → game px: x{k:.4f}")

    speeds = []
    worst = {}
    drifts = {}
    for leg in ("near", "far"):
        ms = masks(pathlib.Path(getattr(a, leg)))
        sx, sy = zip(*(sole(m) for m in ms))
        sx, sy = np.array(sx), np.array(sy)
        tx = np.array([f[leg + "_x"] for f in feet])
        dtx = np.roll(tx, -1) - tx                      # шаг цели IK к следующему кадру
        v = float(-np.median(dtx[dtx < 0]))             # скорость цели в опоре
        # опора = цель едет назад со скоростью опоры (±5 %) на этом и следующем кадре
        planted = np.abs(dtx + v) < 0.05 * v
        ground = float(np.median(sy[planted]))
        # Опора по ПИКСЕЛЯМ (2026-09-23, стопа на своей кости): траектория поднимает цель
        # на отрыве, пока та ещё едет назад со скоростью опоры, а ботинок уже катится на
        # носке и отрывается от земли. Оторванный ботинок скользить не может — в замер
        # опоры идут только кадры, где подошва на земле (±2 render px), и шаг к кадру,
        # где она всё ещё на земле.
        # Ботинок ПЛОСКО на земле: пиксели у земли (±2) тянутся хотя бы на 85 % длины
        # подошвы. Кадры переката на пятке/носке — не скольжение: там точка контакта честно
        # катится по скруглению подошвы, а середина ботинка обязана сдвигаться.
        width = np.array([contact_width(m, ground) for m in ms])
        on_ground = (sy >= ground - 2.0) & (width >= 0.85 * np.median(width[planted]))
        planted = planted & on_ground & np.roll(on_ground, -1)
        dsx = np.roll(sx, -1) - sx
        slip = np.abs(dsx[planted] - dtx[planted])
        # накопленный за опору уход ботинка от цели: сумма расхождений шагов (со знаком)
        drift = float(np.sum(dsx[planted] - dtx[planted]))
        # Главное для боя: едет ли ботинок в опоре РАВНОМЕРНО. Персонаж движется с постоянной
        # скоростью, клип прокручивается с постоянным fps — значит, без скольжения ботинок
        # обязан идти назад по прямой. Подгоняем прямую к x ботинка на кадрах опоры (по
        # порядку от начала опоры, через стык петли) — её наклон задаёт темп, отклонение от
        # неё и есть видимое скольжение при правильном темпе.
        start = next(i for i in range(n) if planted[i] and not planted[i - 1])
        order = [(start + j) % n for j in range(n) if planted[(start + j) % n]]
        run = order[:next((j for j in range(1, len(order)) if (order[j] - order[j - 1]) % n != 1), len(order))]
        run = run + [(run[-1] + 1) % n]                 # опора кончается на кадре после последнего шага
        # Проскальзывание по точке подошвы: средний шаг ботинка против шага цели IK на тех же
        # кадрах опоры. 1.00 — ботинок стоит на земле, как прибитый; меньше — отстаёт.
        steps = run[:-1]
        ratio = float(np.mean(dsx[steps]) / np.mean(dtx[steps]))
        t = np.arange(len(run))
        coef = np.polyfit(t, sx[run], 1)
        resid = sx[run] - np.polyval(coef, t)
        boot_v = float(-coef[0])
        lin_dev = float(np.abs(resid).max())
        sink = float(sy.max() - ground)
        # подъём ботинка над землёй в переносе (render px) — «шаркает» ли нога
        lift = float(ground - sy[~planted].min()) if (~planted).any() else 0.0
        speeds.append(boot_v)
        worst[leg] = lin_dev
        drifts[leg] = drift
        print(f"\n{leg}: кадров опоры {int(planted.sum())}/{n}, шаг цели в опоре {v:.2f} render px/кадр")
        print(f"  ботинок в опоре ({len(run)} кадров): едет назад {boot_v:.2f} render px/кадр "
              f"(цель IK {v:.2f}); неравномерность — макс отклонение от прямой {lin_dev:.1f} render px"
              f" = {lin_dev * k:.1f} game px")
        print(f"  ПРОСКАЛЬЗЫВАНИЕ: шаг ботинка / шаг цели IK в опоре = {ratio:.3f} ({100.0 * (ratio - 1.0):+.1f} %)")
        print(f"  (справочно: расхождение шага ботинка и цели макс {slip.max():.1f} render px/кадр, "
              f"за опору {drift:+.1f} render px)")
        print(f"  земля ботинка y={ground:.0f}; зарывание ниже земли в переносе {sink:.0f} render px"
              f" ({sink * k:.1f} game px); подъём над землёй до {lift:.0f} render px ({lift * k:.1f} game px)")

    v = float(np.mean(speeds))
    game_v = v * k * a.fps
    fps_need = SPEED / (v * k)
    print(f"\nТЕМП: при {a.fps:g} fps ботинок в опоре едет назад со скоростью {game_v:.0f} game px/с "
          f"(персонаж — {SPEED:.0f}); fps без скольжения: {fps_need:.2f}")
    print(f"ИТОГ: неравномерность опоры макс {max(worst.values()) * k:.1f} game px; "
          f"рассогласование темпа при {a.fps:g} fps: {100.0 * (game_v - SPEED) / SPEED:+.0f} %")
    return 0


if __name__ == "__main__":
    sys.exit(main())
