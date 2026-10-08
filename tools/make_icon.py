#!/usr/bin/env python3
"""Иконка exe: godot/assets/img/icon.ico (256/128/64/48/32/16) из котла cauldron.png.

Котёл обрезается по непрозрачной области с полями 4 %, чтобы на 16–32 px он не тонул
в пустом холсте 832×832. Нужен Pillow.

    python -X utf8 tools/make_icon.py
"""
from pathlib import Path

from PIL import Image

REPO = Path(__file__).resolve().parents[1]
SRC = REPO / "godot/assets/img/cauldron.png"
DST = REPO / "godot/assets/img/icon.ico"
SIZES = [(256, 256), (128, 128), (64, 64), (48, 48), (32, 32), (16, 16)]


def main() -> None:
    im = Image.open(SRC).convert("RGBA")
    left, top, right, bottom = im.getbbox()
    side = int(max(right - left, bottom - top) * 1.08)
    cx, cy = (left + right) // 2, (top + bottom) // 2
    square = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    square.paste(im.crop((cx - side // 2, cy - side // 2, cx - side // 2 + side,
                          cy - side // 2 + side)), (0, 0))
    big = square.resize((256, 256), Image.LANCZOS)
    big.save(DST, format="ICO", sizes=SIZES)
    check = Image.open(DST)
    print(f"[OK] {DST} sizes={sorted(check.info.get('sizes', []))}")


if __name__ == "__main__":
    main()
