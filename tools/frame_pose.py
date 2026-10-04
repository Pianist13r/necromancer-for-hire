#!/usr/bin/env python3
"""frame_pose.py — кадрирование OpenPose-позы: кроп по фигуре, вписывание в квадрат.

Почему нужно: позы Civitai занимают ~28 % кадра и смещены — InstantX Union обучен
на позах, где фигура заполняет кадр (см. эталон conds/pose.png). Мелкую офф-центр
позу ControlNet читает слабо (проверено прогоном cn_w4 в сессии 2026-08-24).

Запуск: python tools/frame_pose.py ВХОД.png ВЫХОД.png [--size 832]
        python tools/frame_pose.py --batch ПАПКА_ВХОД ПАПКА_ВЫХОД
"""
import argparse
import sys
from pathlib import Path

import numpy as np
from PIL import Image


def frame_pose(src: Path, dst: Path, size: int = 832, fill: float = 0.91) -> None:
    im = Image.open(src).convert("RGB")
    a = np.array(im)
    mask = a.sum(axis=2) > 30
    ys, xs = np.where(mask)
    if len(xs) == 0:
        raise SystemExit(f"пустая поза: {src}")
    x0, x1, y0, y1 = xs.min(), xs.max(), ys.min(), ys.max()
    pad = int(max(x1 - x0, y1 - y0) * 0.12)
    x0 = max(0, x0 - pad); y0 = max(0, y0 - pad)
    x1 = min(im.width, x1 + pad); y1 = min(im.height, y1 + pad)
    crop = im.crop((x0, y0, x1, y1))
    canvas = Image.new("RGB", (size, size), (0, 0, 0))
    s = min(size * fill / crop.width, size * fill / crop.height)
    crop = crop.resize((max(1, int(crop.width * s)), max(1, int(crop.height * s))), Image.LANCZOS)
    canvas.paste(crop, ((size - crop.width) // 2, (size - crop.height) // 2))
    dst.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(dst)
    print(f"{src.name} -> {dst}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("dst", nargs="?")
    ap.add_argument("--batch", action="store_true")
    ap.add_argument("--size", type=int, default=832)
    a = ap.parse_args()
    if a.batch:
        src_dir, dst_dir = Path(a.src), Path(a.dst)
        for f in sorted(src_dir.glob("*.png")):
            frame_pose(f, dst_dir / f.name, a.size)
        return 0
    frame_pose(Path(a.src), Path(a.dst), a.size)
    return 0


if __name__ == "__main__":
    sys.exit(main())
