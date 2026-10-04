#!/usr/bin/env python3
"""Контактный лист из покадрового ролика — дешёвая приёмка анимации.

Зачем: анимацию нельзя принимать по стоп-кадру (footplanting и вес на нём не видны),
но и смотреть 700 PNG глазами агент не может. Лист склеивает N кадров с равным шагом
в одну картинку — движение читается как раскадровка, а стоит один взгляд вместо сотен.

Как пользоваться:

    GODOT --path godot --write-movie C:/AI/necro/assets/v7/clip/f.png \
          --fixed-fps 30 --quit-after 240 -- --autostart --mute --demo
    python tools/contact_sheet.py C:/AI/necro/assets/v7/clip C:/AI/necro/assets/v7/sheet.png \
          --count 6 --from-frame 120 --cols 2

Аргументы:
    src           папка с кадрами (или маска glob)
    out           куда сохранить лист
    --count N     сколько кадров взять (по умолчанию 6)
    --from-frame  с какого кадра начинать выборку (по умолчанию с середины ролика)
    --to-frame    по какой кадр
    --cols N      колонок в сетке (по умолчанию 2)
    --width N     ширина одной ячейки (по умолчанию 640)
    --crop x,y,w,h  вырезать область КАЖДОГО кадра до масштабирования — так на лист
                    попадает крупный план персонажа, а не вся арена мелко

Требует Pillow (стоит в системном python: PIL 12.1.1 на 2026-08-22).
"""

import argparse
import glob
import os
import sys

from PIL import Image


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("out")
    ap.add_argument("--count", type=int, default=6)
    ap.add_argument("--from-frame", type=int, default=-1)
    ap.add_argument("--to-frame", type=int, default=-1)
    ap.add_argument("--cols", type=int, default=2)
    ap.add_argument("--width", type=int, default=640)
    ap.add_argument("--crop", default="")
    args = ap.parse_args()

    pattern = args.src if "*" in args.src else os.path.join(args.src, "*.png")
    files = sorted(glob.glob(pattern))
    if not files:
        print("кадров не найдено:", pattern)
        return 1

    lo = args.from_frame if args.from_frame >= 0 else len(files) // 2
    hi = args.to_frame if args.to_frame >= 0 else len(files) - 1
    lo = max(0, min(lo, len(files) - 1))
    hi = max(lo, min(hi, len(files) - 1))
    if args.count <= 1:
        picks = [files[lo]]
    else:
        step = (hi - lo) / float(args.count - 1)
        picks = [files[int(round(lo + step * i))] for i in range(args.count)]

    crop = None
    if args.crop:
        crop = tuple(int(v) for v in args.crop.split(","))
        if len(crop) != 4:
            print("--crop ждёт x,y,w,h")
            return 1

    first = Image.open(picks[0])
    src_w, src_h = (crop[2], crop[3]) if crop else first.size
    cell_w = args.width
    cell_h = max(1, int(round(cell_w * src_h / float(src_w))))
    cols = max(1, args.cols)
    rows = (len(picks) + cols - 1) // cols

    sheet = Image.new("RGB", (cell_w * cols, cell_h * rows), (12, 10, 18))
    for i, path in enumerate(picks):
        im = Image.open(path).convert("RGB")
        if crop:
            im = im.crop((crop[0], crop[1], crop[0] + crop[2], crop[1] + crop[3]))
        im = im.resize((cell_w, cell_h), Image.LANCZOS)
        sheet.paste(im, ((i % cols) * cell_w, (i // cols) * cell_h))
    sheet.save(args.out)
    names = [os.path.basename(p) for p in picks]
    print("лист:", args.out, sheet.size, "кадры:", ", ".join(names))
    return 0


if __name__ == "__main__":
    sys.exit(main())
