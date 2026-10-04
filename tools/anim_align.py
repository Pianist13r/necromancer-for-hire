#!/usr/bin/env python3
"""
anim_align.py — подогнать клип к опорному клипу по масштабу и точке опоры.

Зачем (2026-09-23). anim_post.py масштабирует каждый клип по ЕГО общему bbox. У замаха в bbox
попадает кирка, уходящая ниже подошвы, поэтому персонаж в замахе выходит на ~3 % мельче и
на 6 px холста выше, чем в покое: при смене клипа в бою фигура «подпрыгивает» и сжимается.
Скрипт берёт ПЕРВЫЙ кадр клипа и опорный кадр (обычно покой), сравнивает ширину каски
(верхние 30 % фигуры — её не двигает ни походка, ни замах) и нижнюю точку ботинков, и
переписывает все кадры клипа с одним и тем же масштабом и сдвигом.

Запуск:
    python tools/anim_align.py ПАПКА_КЛИПА/sprites ОПОРНЫЙ_КАДР.png
"""
from __future__ import annotations

import argparse
import pathlib
import sys

import numpy as np
from PIL import Image


def measure(im: Image.Image) -> tuple[float, float, float]:
    """(ширина каски, x центра каски, нижняя строка фигуры)."""
    a = np.array(im.convert("RGBA"))[:, :, 3] > 30
    ys, xs = np.where(a)
    top, bot = ys.min(), ys.max()
    head = ys < top + 0.3 * (bot - top)
    return float(xs[head].max() - xs[head].min()), float(xs[head].mean()), float(bot)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("sprites")
    ap.add_argument("reference")
    a = ap.parse_args()

    frames = sorted(pathlib.Path(a.sprites).glob("spr_*.png"))
    if not frames:
        print("нет кадров spr_*.png", file=sys.stderr)
        return 1
    ref_w, ref_x, ref_bot = measure(Image.open(a.reference))
    w0, x0, bot0 = measure(Image.open(frames[0]))
    s = ref_w / w0
    # точка опоры (центр каски по x, низ фигуры по y) первого кадра -> та же точка опорного
    for f in frames:
        im = Image.open(f).convert("RGBA")
        size = im.size
        big = im.resize((round(size[0] * s), round(size[1] * s)), Image.LANCZOS)
        out = Image.new("RGBA", size, (0, 0, 0, 0))
        out.paste(big, (round(ref_x - x0 * s), round(ref_bot - bot0 * s)), big)
        out.save(f)
    print(f"{len(frames)} кадров: масштаб x{s:.3f}, сдвиг ({ref_x - x0 * s:+.1f}, {ref_bot - bot0 * s:+.1f}) px")
    return 0


if __name__ == "__main__":
    sys.exit(main())
