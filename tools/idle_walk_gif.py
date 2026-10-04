#!/usr/bin/env python3
"""
idle_walk_gif.py — переход покой → ходьба → покой в ИГРОВОМ масштабе, наборы рядами.

Зачем (2026-09-23): прежний набор снимался с разных ригов — в покое ноги сливались в одну,
в ходьбе стояли порознь, и на смене клипа ноги «прыгали». Стоячий лист этого не покажет:
нужен сам момент смены клипа. Каждый ряд — набор клипов: покой, затем ходьба с продвижением
со скоростью боя (Cfg.SKELETON_SPEED), затем снова покой; масштаб — как у CharAnim в бою.

Запуск:
  python tools/idle_walk_gif.py OUT.gif IDLE_DIR:FPS WALK_DIR:FPS:ПОДПИСЬ [IDLE2:FPS WALK2:FPS:ПОДПИСЬ ...]
      [--png-at 0.58,0.62]   дополнительно сохранить кадры в эти моменты (секунды) как PNG
"""
from __future__ import annotations

import argparse
import pathlib

from PIL import Image, ImageDraw

SCALE = 137.65 * 0.80 / (460.0 * 0.85)
SPEED = 135.0
STEP_MS = 20
IDLE_S = 0.6
WALK_S = 1.4
W = 420
ROW_H = 150


def load(spec: str) -> tuple[list[Image.Image], float, str]:
    parts = spec.split(":")
    # путь Windows с буквой диска («C:/...») — первые два куска склеиваем обратно
    if len(parts[0]) == 1:
        parts = [parts[0] + ":" + parts[1]] + parts[2:]
    d, fps = parts[0], float(parts[1])
    label = parts[2] if len(parts) > 2 else pathlib.Path(d).parent.name
    frames = []
    for f in sorted(pathlib.Path(d).glob("spr_*.png")):
        im = Image.open(f).convert("RGBA")
        frames.append(im.resize((round(im.width * SCALE), round(im.height * SCALE)), Image.LANCZOS))
    return frames, fps, label


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("clips", nargs="+")
    ap.add_argument("--png-at", default="")
    ap.add_argument("--starts", nargs="*", default=[],
                    help="intro DIR:FPS для каждого ряда; '-' — без intro")
    a = ap.parse_args()
    if len(a.clips) % 2:
        raise SystemExit("клипы задаются парами: покой ходьба")
    rows = [(load(a.clips[i]), load(a.clips[i + 1])) for i in range(0, len(a.clips), 2)]
    if a.starts and len(a.starts) != len(rows):
        raise SystemExit("--starts: по одному intro или '-' на каждый ряд")
    starts = [None if s == '-' else load(s) for s in a.starts] if a.starts else [None] * len(rows)

    total = IDLE_S * 2 + WALK_S
    n = int(total * 1000 / STEP_MS)
    out = []
    for k in range(n):
        t = k * STEP_MS / 1000.0
        canvas = Image.new("RGB", (W, ROW_H * len(rows)), (72, 64, 58))
        dr = ImageDraw.Draw(canvas)
        for r, ((idle, idle_fps, _), (walk, walk_fps, label)) in enumerate(rows):
            y0 = r * ROW_H
            if t < IDLE_S:
                im, x = idle[int(t * idle_fps) % len(idle)], 0.0
            elif t < IDLE_S + WALK_S:
                tw = t - IDLE_S
                intro = starts[r]
                duration = len(intro[0]) / intro[1] if intro else 0.0
                if intro and tw < duration:
                    im = intro[0][min(len(intro[0]) - 1, int(tw * intro[1]))]
                else:
                    im = walk[int((tw - duration) * walk_fps) % len(walk)]
                x = tw * SPEED
            else:
                im, x = idle[int((t - IDLE_S - WALK_S) * idle_fps) % len(idle)], WALK_S * SPEED
            ground = y0 + ROW_H - 16
            dr.line([(0, ground), (W, ground)], fill=(110, 100, 90), width=1)
            for gx in range(10, W, 40):
                dr.line([(gx, ground), (gx, ground + 6)], fill=(140, 128, 115), width=1)
            px = int(20 + x)
            canvas.paste(im, (px, ground - im.height + 3), im)
            dr.text((6, y0 + 4), label, fill=(235, 225, 210))
        out.append(canvas)
    out[0].save(a.out, save_all=True, append_images=out[1:], duration=STEP_MS, loop=0)
    print(f"{a.out}  ({len(out)} кадров по {STEP_MS} мс)")
    for s in [v for v in a.png_at.split(",") if v]:
        idx = min(n - 1, int(float(s) * 1000 / STEP_MS))
        p = pathlib.Path(a.out).with_name(pathlib.Path(a.out).stem + f"_t{int(float(s) * 1000):04d}.png")
        out[idx].resize((out[idx].width * 2, out[idx].height * 2), Image.NEAREST).save(p)
        print(p)


if __name__ == "__main__":
    main()
