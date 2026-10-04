#!/usr/bin/env python3
"""Приёмочный ролик финальной сборки: фрагменты покадровой записи -> контактный лист + mp4.

Зачем: весь матч в PNG — десятки гигабайт и 10 минут просмотра. Приёмке нужны узловые
места (меню, волна 1, волна 5, передышка с ларьком, Акт, босс, итог). Скрипт берёт их
диапазонами кадров, склеивает лист с подписями (один взгляд) и, если есть ffmpeg,
ролик на 30 fps.

Запись (--fixed-fps 30; меню — отдельным прогоном без --autostart):
    GODOT --path godot --write-movie C:/AI/necro/batches/proto/ship/movie/menu/frame.png \
          --fixed-fps 30 --quit-after 75 -- --mute
    GODOT --path godot --write-movie C:/AI/necro/batches/proto/ship/movie/match/frame.png \
          --fixed-fps 30 --quit-after N -- --mute --autostart --demo --seed 1 --trace

Сборка:
    python tools/ship_reel.py segments.json --sheet contact.png --mp4 demo.mp4 [--ffmpeg PATH]

segments.json — список {"label": "...", "dir": "папка кадров", "from": N, "to": M,
"sheet": K} (K — сколько кадров фрагмента положить на лист, равным шагом).
ffmpeg: --ffmpeg, иначе из PATH; нет — только лист.
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw, ImageFont

CELL_W = 426
CELL_H = 240
COLS = 6
CAPTION_H = 22


def frame_path(d: str, i: int) -> str:
    return os.path.join(d, "frame%08d.png" % i)


def font(size: int) -> ImageFont.ImageFont:
    for f in ("C:/Windows/Fonts/segoeui.ttf", "C:/Windows/Fonts/arial.ttf"):
        if os.path.exists(f):
            return ImageFont.truetype(f, size)
    return ImageFont.load_default()


def build_sheet(segs: list, out: str) -> int:
    cells = []
    for s in segs:
        k = int(s.get("sheet", 4))
        a, b = int(s["from"]), int(s["to"])
        for j in range(k):
            i = a + round((b - a) * j / max(1, k - 1))
            cells.append((s["label"], i, frame_path(s["dir"], i)))
    rows = (len(cells) + COLS - 1) // COLS
    sheet = Image.new("RGB", (COLS * CELL_W, rows * (CELL_H + CAPTION_H)), (16, 12, 24))
    draw = ImageDraw.Draw(sheet)
    fnt = font(14)
    for n, (label, i, p) in enumerate(cells):
        x = (n % COLS) * CELL_W
        y = (n // COLS) * (CELL_H + CAPTION_H)
        im = Image.open(p).convert("RGB").resize((CELL_W, CELL_H), Image.LANCZOS)
        sheet.paste(im, (x, y + CAPTION_H))
        draw.text((x + 6, y + 3), "%s · кадр %d" % (label, i), fill=(235, 225, 255), font=fnt)
    sheet.save(out)
    return len(cells)


def build_mp4(segs: list, out: str, ffmpeg: str) -> int:
    tmp = tempfile.mkdtemp(prefix="ship_reel_")
    n = 0
    try:
        for s in segs:
            for i in range(int(s["from"]), int(s["to"]) + 1):
                shutil.copyfile(frame_path(s["dir"], i), os.path.join(tmp, "%06d.png" % n))
                n += 1
        subprocess.run([ffmpeg, "-y", "-loglevel", "error", "-framerate", "30",
                        "-i", os.path.join(tmp, "%06d.png"), "-c:v", "libx264",
                        "-pix_fmt", "yuv420p", "-crf", "22", "-preset", "medium", out],
                       check=True)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return n


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("segments")
    ap.add_argument("--sheet", required=True)
    ap.add_argument("--mp4")
    ap.add_argument("--ffmpeg")
    args = ap.parse_args()
    segs = json.load(open(args.segments, encoding="utf-8"))
    print("лист: %d кадров -> %s" % (build_sheet(segs, args.sheet), args.sheet))
    if args.mp4:
        ff = args.ffmpeg or shutil.which("ffmpeg")
        if not ff:
            print("ffmpeg не найден — mp4 пропущен")
            return 0
        print("mp4: %d кадров -> %s" % (build_mp4(segs, args.mp4, ff), args.mp4))
    return 0


if __name__ == "__main__":
    sys.exit(main())
