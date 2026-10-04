#!/usr/bin/env python3
"""
fit_reference.py — привести референс-картинку персонажа к КОМПОЗИЦИИ управляющего ролика.

Зачем. Wan-Animate-2 берёт референс-кадр как «во что одеть движение», а управляющий ролик —
как «что за движение». Замер 2026-08-26: если персонаж на референсе занимает весь кадр, а в
управляющем ролике стоит в полный рост на 80 % высоты, модель якорится на композицию
референса и движение почти не переносит — на выходе крупный план и лёгкое дрожание.

Лечение: положить персонажа на холст ролика ровно в тот же прямоугольник, который занимает
фигура в кадре-образце. Тогда у модели совпадают масштаб, положение и линия земли, и ей
остаётся только перенести движение.

Запуск:
    python tools/fit_reference.py ПЕРСОНАЖ.png ОБРАЗЕЦ_КАДРА.png ВЫХОД.png --bg 128,128,128
"""
from __future__ import annotations

import argparse
import pathlib
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from anim_post import keyout, largest_component  # проверенный кейинг «семьи magenta»


def figure_mask(im: Image.Image, bg: tuple[int, int, int] | None) -> np.ndarray:
    """Маска фигуры: по альфе, по отличию от ровного фона или кейингом magenta."""
    if im.mode == "RGBA" and np.array(im)[:, :, 3].min() < 250:
        return np.array(im)[:, :, 3] > 30
    if bg is not None:
        a = np.array(im.convert("RGB")).astype(np.int16)
        return np.abs(a - np.array(bg, dtype=np.int16)).max(axis=2) > 18
    return largest_component(keyout(im))


def box_of(mask: np.ndarray) -> tuple[int, int, int, int]:
    ys, xs = np.where(mask)
    if len(xs) == 0:
        raise SystemExit("фигура не найдена")
    return int(xs.min()), int(ys.min()), int(xs.max()), int(ys.max())


def fit_series(src_dir: pathlib.Path, sample: Image.Image, out_dir: pathlib.Path,
               bg: tuple[int, int, int]) -> int:
    """Пакетная подгонка серии кадров под композицию образца.

    Масштаб и линия земли считаются ПО ВСЕЙ СЕРИИ разом: иначе каждый кадр вписался бы
    по своей фигуре, и персонаж менял бы рост от кадра к кадру — та самая болезнь,
    ради лечения которой весь конвейер и затевался.
    """
    sx0, sy0, sx1, sy1 = box_of(figure_mask(sample, bg))
    files = sorted(src_dir.glob("*.png"))
    if not files:
        raise SystemExit(f"кадров не найдено: {src_dir}")

    masks, boxes = [], []
    for f in files:
        im = Image.open(f)
        m = figure_mask(im, None)
        masks.append((im, m))
        boxes.append(box_of(m))
    gx0 = min(b[0] for b in boxes); gy0 = min(b[1] for b in boxes)
    gx1 = max(b[2] for b in boxes); gy1 = max(b[3] for b in boxes)

    scale = min((sx1 - sx0) / (gx1 - gx0), (sy1 - sy0) / (gy1 - gy0))
    out_dir.mkdir(parents=True, exist_ok=True)
    for i, ((im, m), f) in enumerate(zip(masks, files)):
        rgba = np.dstack([np.array(im.convert("RGB")), (m * 255).astype(np.uint8)])
        fig = Image.fromarray(rgba, "RGBA").crop((gx0, gy0, gx1, gy1))
        fig = fig.resize((max(1, int(fig.width * scale)), max(1, int(fig.height * scale))), Image.LANCZOS)
        canvas = Image.new("RGB", sample.size, bg)
        canvas.paste(fig, (sx0 + ((sx1 - sx0) - fig.width) // 2, sy1 - fig.height), fig)
        canvas.save(out_dir / f"frame_{i:03d}.png")
    print(f"серия подогнана: {len(files)} кадров -> {out_dir} (единый масштаб {scale:.3f})")
    return len(files)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("character")
    ap.add_argument("sample")
    ap.add_argument("out")
    ap.add_argument("--bg", default="128,128,128", help="цвет фона образца и выходного холста")
    ap.add_argument("--batch", action="store_true", help="character — папка кадров, out — папка результата")
    a = ap.parse_args()

    if a.batch:
        bg = tuple(int(x) for x in a.bg.split(","))
        fit_series(pathlib.Path(a.character), Image.open(a.sample).convert("RGB"),
                   pathlib.Path(a.out), bg)
        return 0

    bg = tuple(int(x) for x in a.bg.split(","))
    sample = Image.open(a.sample).convert("RGB")
    sx0, sy0, sx1, sy1 = box_of(figure_mask(sample, bg))
    target_w, target_h = sx1 - sx0, sy1 - sy0

    ch = Image.open(a.character)
    ch_mask = figure_mask(ch, None)
    cx0, cy0, cx1, cy1 = box_of(ch_mask)
    # фон вырезаем: иначе на холст ляжет прямоугольник исходного фона,
    # и модель получит не персонажа, а «наклейку» поверх кадра
    rgba = np.dstack([np.array(ch.convert("RGB")), (ch_mask * 255).astype(np.uint8)])
    fig = Image.fromarray(rgba, "RGBA").crop((cx0, cy0, cx1, cy1))

    scale = min(target_w / fig.width, target_h / fig.height)
    fig = fig.resize((max(1, int(fig.width * scale)), max(1, int(fig.height * scale))), Image.LANCZOS)

    canvas = Image.new("RGB", sample.size, bg)
    # ставим по центру X прямоугольника образца и по его НИЖНЕЙ кромке: линия земли важнее центра
    ox = sx0 + (target_w - fig.width) // 2
    oy = sy1 - fig.height
    canvas.paste(fig, (ox, oy), fig)
    pathlib.Path(a.out).parent.mkdir(parents=True, exist_ok=True)
    canvas.save(a.out)
    print(f"образец: фигура {target_w}x{target_h} в ({sx0},{sy0}) на холсте {sample.size}")
    print(f"референс подогнан -> {a.out}  (фигура {fig.width}x{fig.height} в ({ox},{oy}))")
    return 0


if __name__ == "__main__":
    sys.exit(main())
