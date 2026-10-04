#!/usr/bin/env python3
"""
pose_grid.py — сборка ОДНОЙ картинки-сетки из отдельных поз и нарезка результата обратно.

Зачем. Две болезни покадровой генерации, каждая доказана замером в этом проекте:
  * кадры по одному (даже с ControlNet) -> персонаж плывёт: пропорции, длина кирки, детали;
  * лист одной генерацией без ControlNet -> стиль держится, но фазы неравномерны (1.4-12.4 %).
Лечение — соединить: все кадры рисуются ОДНОЙ генерацией (стиль держится по построению),
а поза каждой ячейки жёстко задана карточкой позы из рига (фазы равномерны по построению).

Этот скрипт — «слой 1» конвейера: превращает N поз в одну сетку и запоминает координаты
ячеек в JSON, чтобы результат генерации нарезался ровно по тем же клеткам, а не «на глаз».

Запуск:
    # собрать сетку 4x2 из поз (ячейка 512) -> grid.png + grid.json
    python tools/pose_grid.py build ПАПКА_ПОЗ ВЫХОД.png --cols 4 --cell 512

    # нарезать результат генерации по паспорту сетки
    python tools/pose_grid.py slice РЕЗУЛЬТАТ.png ВЫХОД.png.json ПАПКА_КАДРОВ
"""
from __future__ import annotations

import argparse
import json
import pathlib
import sys

import numpy as np
from PIL import Image

# Поза должна заполнять ячейку: InstantX-ControlNet игнорирует мелкую фигуру
# (проверено в сессии 2026-08-24: поза на 28 % ширины кадра не читается).
FILL = 0.88
# Порог «пиксель не фон» при кропе позы по фигуре.
INK = 30


def figure_bbox(im: Image.Image, bg: tuple[int, int, int] | None = None) -> tuple[int, int, int, int] | None:
    """Границы видимой фигуры.

    bg=None — карточка позы на чёрном фоне (маска «ярче порога»).
    bg=(r,g,b) — кадр рига на ровном фоне (маска «достаточно отличается от фона»):
    так сетку можно собирать не только из карт поз, но и из готовых кадров рига,
    чтобы модель ПЕРЕКРАШИВАЛА готовую позу, а не придумывала её заново.
    """
    a = np.array(im.convert("RGB")).astype(np.int16)
    if bg is None:
        mask = a.sum(axis=2) > INK
    else:
        # фон кадров переноса движения не идеально ровный (модель кладёт лёгкие
        # градиенты), поэтому порог выше и остаётся только крупнейшая связная
        # область — иначе bbox растягивается на весь кадр и фигура в ячейке мельчает
        mask = np.abs(a - np.array(bg, dtype=np.int16)).max(axis=2) > 42
        sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
        from anim_post import largest_component
        mask = largest_component(mask)
    ys, xs = np.where(mask)
    if len(xs) == 0:
        return None
    return int(xs.min()), int(ys.min()), int(xs.max()), int(ys.max())


def series_bbox(images: list[Image.Image], bg: tuple[int, int, int] | None = None) -> tuple[int, int, int, int]:
    """Общий bbox по ВСЕЙ серии поз.

    Ключевая деталь, без которой конвейер ломается ровно там, где должен лечить:
    если кропать и масштабировать каждую позу по её собственной фигуре, персонаж
    начинает «дышать» — в широком шаге фигура ниже, в сведённом выше, и после
    вписывания в ячейку он в каждом кадре разного роста. Масштаб обязан быть
    ОДИН на всю серию, а низ фигуры — на общей линии земли.
    """
    boxes = [b for b in (figure_bbox(im, bg) for im in images) if b is not None]
    if not boxes:
        raise SystemExit("во всех позах пусто — нечего собирать")
    return (min(b[0] for b in boxes), min(b[1] for b in boxes),
            max(b[2] for b in boxes), max(b[3] for b in boxes))


def build(pose_dir: pathlib.Path, out_png: pathlib.Path, cols: int, cell: int,
          pattern: str = "*.png", keep_ground: bool = True,
          bg: tuple[int, int, int] | None = None, every: int = 1, limit: int = 0) -> dict:
    """Собирает сетку поз. Возвращает паспорт сетки (он же пишется рядом в .json).

    keep_ground=True сажает все фигуры на общую линию низа ячейки — тогда персонажи в
    ячейках стоят на одном уровне, и нарезанные кадры уже почти выровнены по подошве.
    """
    poses = sorted(pose_dir.glob(pattern))[::every]
    if limit:
        poses = poses[:limit]
    if not poses:
        raise SystemExit(f"поз не найдено: {pose_dir}/{pattern}")

    rows = (len(poses) + cols - 1) // cols
    sheet = Image.new("RGB", (cell * cols, cell * rows), bg or (0, 0, 0))
    cells = []

    images = [Image.open(p).convert("RGB") for p in poses]
    bx0, by0, bx1, by1 = series_bbox(images, bg)
    pad = int(max(bx1 - bx0, by1 - by0) * 0.06)
    bx0 = max(0, bx0 - pad)
    by0 = max(0, by0 - pad)
    bx1 = min(images[0].width, bx1 + pad)
    by1 = min(images[0].height, by1 + pad)
    box_w, box_h = bx1 - bx0, by1 - by0
    # один масштаб на всю серию -> персонаж не меняет рост между кадрами
    scale = min(cell * FILL / box_w, cell * FILL / box_h)
    w = max(1, int(round(box_w * scale)))
    h = max(1, int(round(box_h * scale)))
    margin = int(round(cell * (1.0 - FILL) / 2))

    for i, (p, im) in enumerate(zip(poses, images)):
        fig = im.crop((bx0, by0, bx1, by1)).resize((w, h), Image.LANCZOS)
        cx = (i % cols) * cell
        cy = (i // cols) * cell
        ox = cx + (cell - w) // 2
        oy = cy + (cell - h - margin) if keep_ground else cy + (cell - h) // 2
        sheet.paste(fig, (ox, oy))
        cells.append({"index": i, "x": cx, "y": cy, "w": cell, "h": cell, "pose": p.name})

    out_png.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(out_png)

    meta = {
        "grid": out_png.name,
        "cols": cols,
        "rows": rows,
        "cell": cell,
        "width": cell * cols,
        "height": cell * rows,
        "count": len(poses),
        "fill": FILL,
        "keep_ground": keep_ground,
        "source_dir": str(pose_dir),
        "cells": cells,
    }
    meta_path = out_png.with_suffix(out_png.suffix + ".json")
    meta_path.write_text(json.dumps(meta, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"сетка {cols}x{rows} ({cell} px/ячейка) -> {out_png}  [{cell*cols}x{cell*rows}]")
    print(f"паспорт -> {meta_path}")
    return meta


def head_center_x(mask: np.ndarray) -> int:
    """Горизонтальный центр ГОЛОВЫ — верхних 18 % силуэта.

    Скилл ai-game-art-pipeline (battle-sprites) прямо запрещает якорить ходьбу по
    центру bbox: движение ног смещает рамку, и персонаж качается из стороны в сторону.
    Голова при ходьбе почти не гуляет, поэтому якорь берётся по ней.
    """
    ys, xs = np.where(mask)
    if len(xs) == 0:
        return 0
    top, bottom = ys.min(), ys.max()
    band = ys <= top + max(1, int((bottom - top) * 0.18))
    return int(np.median(xs[band]))


def slice_grid(result: pathlib.Path, meta_path: pathlib.Path, out_dir: pathlib.Path) -> int:
    """Режет картинку-результат по паспорту сетки.

    Результат генерации может быть другого размера, чем карта поз (модель отдаёт свой
    холст) — поэтому режем ПРОПОРЦИОНАЛЬНО, а не по абсолютным пикселям паспорта.
    """
    meta = json.loads(meta_path.read_text(encoding="utf-8"))
    im = Image.open(result).convert("RGBA")
    kx = im.width / meta["width"]
    ky = im.height / meta["height"]
    out_dir.mkdir(parents=True, exist_ok=True)

    for c in meta["cells"]:
        box = (int(round(c["x"] * kx)), int(round(c["y"] * ky)),
               int(round((c["x"] + c["w"]) * kx)), int(round((c["y"] + c["h"]) * ky)))
        im.crop(box).save(out_dir / f"frame_{c['index']:02d}.png")
    print(f"нарезано кадров: {meta['count']} -> {out_dir}  (масштаб {kx:.3f}x{ky:.3f})")
    return meta["count"]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    b = sub.add_parser("build", help="собрать сетку поз")
    b.add_argument("pose_dir")
    b.add_argument("out_png")
    b.add_argument("--cols", type=int, default=4)
    b.add_argument("--cell", type=int, default=512)
    b.add_argument("--pattern", default="*.png")
    b.add_argument("--center", action="store_true", help="центрировать по вертикали вместо посадки на линию низа")
    b.add_argument("--bg", default="", help="цвет фона исходных кадров, напр. 128,128,128 (кадры рига)")
    b.add_argument("--every", type=int, default=1, help="брать каждый N-й кадр")
    b.add_argument("--limit", type=int, default=0, help="ограничить число кадров")

    s = sub.add_parser("slice", help="нарезать результат по паспорту сетки")
    s.add_argument("result")
    s.add_argument("meta")
    s.add_argument("out_dir")

    a = ap.parse_args()
    if a.cmd == "build":
        bg = tuple(int(x) for x in a.bg.split(",")) if a.bg else None
        build(pathlib.Path(a.pose_dir), pathlib.Path(a.out_png), a.cols, a.cell,
              a.pattern, keep_ground=not a.center, bg=bg, every=a.every, limit=a.limit)
    else:
        slice_grid(pathlib.Path(a.result), pathlib.Path(a.meta), pathlib.Path(a.out_dir))
    return 0


if __name__ == "__main__":
    sys.exit(main())
