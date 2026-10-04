#!/usr/bin/env python3
"""
walk_compare_gif.py — сравнение клипов ходьбы в ИГРОВОМ масштабе и в движении.

Зачем (2026-09-23): стоячий GIF не показывает главного дефекта ходьбы — скольжения по
земле. В бою персонаж едет со скоростью Cfg.SKELETON_SPEED (135 px/с), а клип крутится со
своим fps; если ботинок в опоре едет назад медленнее, скелет «катится на коньках». Здесь
каждый клип идёт по полосе с метками на земле с той же скоростью, что в бою, и в том же
масштабе (холст 460 → body_h/(460*0.85), body_h = 137.65*0.80), время общее (шаг 20 мс).

Запуск:
  python tools/walk_compare_gif.py OUT.gif ПАПКА_СПРАЙТОВ:FPS[:ПОДПИСЬ] ... [--still] [--png-at 0.3,0.5]
    --still     без продвижения (персонаж на месте) — крупнее видно фазы;
    --png-at    дополнительно сохранить кадры в эти моменты (секунды) как PNG рядом с GIF.
"""
from __future__ import annotations

import argparse
import pathlib

from PIL import Image, ImageDraw

SCALE = 137.65 * 0.80 / (460.0 * 0.85)
SPEED = 135.0
STEP_MS = 20
W = 520
ROW_H = 150


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("clips", nargs="+")
    ap.add_argument("--seconds", type=float, default=3.4)
    ap.add_argument("--still", action="store_true")
    ap.add_argument("--png-at", default="")
    a = ap.parse_args()

    rows = []
    for spec in a.clips:
        parts = spec.split(":")
        # путь Windows с буквой диска содержит двоеточие — собираем обратно
        if len(parts[0]) == 1:
            parts = [parts[0] + ":" + parts[1]] + parts[2:]
        d, fps = pathlib.Path(parts[0]), float(parts[1])
        label = parts[2] if len(parts) > 2 else d.parent.name
        size = int(round(460 * SCALE))
        frames = [Image.open(f).convert("RGBA").resize((size, size), Image.LANCZOS)
                  for f in sorted(d.glob("spr_*.png"))]
        rows.append((frames, fps, label))

    n_steps = int(a.seconds * 1000 / STEP_MS)
    gif = []
    stills = {}
    want = [float(v) for v in a.png_at.split(",") if v]
    for s in range(n_steps):
        t = s * STEP_MS / 1000.0
        im = Image.new("RGB", (W, ROW_H * len(rows)), (24, 20, 32))
        dr = ImageDraw.Draw(im)
        for j, (frames, fps, label) in enumerate(rows):
            spr = frames[int(t * fps) % len(frames)]
            ground = j * ROW_H + ROW_H - 14
            dr.line([(0, ground), (W, ground)], fill=(90, 80, 100))
            for mx in range(0, W, 24):          # метки на земле — видно, стоит ли ботинок
                dr.line([(mx, ground), (mx, ground + 6)], fill=(90, 80, 100))
            x = W / 2 if a.still else (30 + (t * SPEED) % (W - 60))
            # низ холста = земля (как у CharAnim: канва якорена низом, 2 % поля снизу)
            im.paste(spr, (int(x - spr.width / 2), int(ground - spr.height * 0.99)), spr)
            dr.text((6, j * ROW_H + 4), f"{label}  {fps:g} fps", fill=(210, 210, 210))
        gif.append(im.convert("P", palette=Image.ADAPTIVE, colors=128))
        for w in want:
            if w not in stills and t >= w:
                stills[w] = im.copy()
    out = pathlib.Path(a.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    gif[0].save(out, save_all=True, append_images=gif[1:], duration=STEP_MS, loop=0, disposal=1)
    for w, im in stills.items():
        im.save(out.with_name(f"{out.stem}_t{int(w * 1000):04d}.png"))
    print(f"{out}  ({n_steps} кадров по {STEP_MS} мс)")


if __name__ == "__main__":
    main()
