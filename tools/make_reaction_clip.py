#!/usr/bin/env python3
"""
make_reaction_clip.py — короткие служебные клипы прямо из готового спрайта, без генерации.

Зачем. Не всякое состояние персонажа стоит генеративной модели. Ходьба и удар — это
хореография, там генерация оправдана. А «отшатнулся от удара» и «вылез из земли» —
это движение целой фигуры: сдвиг, наклон, обрезка по линии земли. Такое честнее и
надёжнее посчитать арифметикой: результат детерминирован, занимает секунду и не зависит
от того, сколько сегодня свободно видеопамяти.

Клипы получаются «картонными» (фигура не перерисовывается), но оба состояния короткие —
5 кадров за треть секунды, и в игровом масштабе читаются как надо.

Запуск:
    python tools/make_reaction_clip.py hit   assets/anim-lab/out/idle_v1/sprites/spr_00.png
    python tools/make_reaction_clip.py spawn assets/anim-lab/out/idle_v1/sprites/spr_00.png
    python tools/make_reaction_clip.py hit ИСТОЧНИК.png --name hit_v5   # своя папка, старые клипы целы
"""
from __future__ import annotations

import argparse
import math
import pathlib
import sys

import numpy as np
from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parent.parent


def figure(im: Image.Image) -> Image.Image:
    """Обрезает спрайт по фигуре, сохраняя прозрачность."""
    a = np.array(im.convert("RGBA"))
    m = a[:, :, 3] > 30
    ys, xs = np.where(m)
    if len(xs) == 0:
        raise SystemExit("в спрайте нет фигуры")
    return im.crop((int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(ys.max()) + 1))


def render(fig: Image.Image, canvas_px: int, kind: str, n: int,
           ts: list[float] | None = None) -> list[Image.Image]:
    out = []
    for i in range(n):
        t = ts[i] if ts else i / max(1, n - 1)
        canvas = Image.new("RGBA", (canvas_px, canvas_px), (0, 0, 0, 0))
        ground = canvas_px - int(canvas_px * 0.02)      # та же линия земли, что в anim_post
        if kind == "hit":
            # резкий отскок назад с наклоном и быстрым возвратом
            k = math.sin(math.pi * min(1.0, t * 1.15)) ** 0.6
            f = fig.rotate(-12.0 * k, resample=Image.BICUBIC, expand=True)
            x = (canvas_px - f.width) // 2 - int(round(canvas_px * 0.055 * k))
            y = ground - f.height - int(round(canvas_px * 0.012 * k))
        else:
            # подъём из земли: фигура выезжает снизу, нижняя часть обрезана линией земли
            vis = max(1, int(round(fig.height * (0.12 + 0.88 * t))))
            f = fig.crop((0, 0, fig.width, vis))
            x = (canvas_px - f.width) // 2
            y = ground - f.height
        canvas.paste(f, (x, y), f)
        out.append(canvas)
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("kind", choices=["hit", "spawn"])
    ap.add_argument("sprite")
    ap.add_argument("--frames", type=int, default=0)
    ap.add_argument("--canvas", type=int, default=460)
    ap.add_argument("--ts", default="", help="моменты t (0…1) через запятую вместо равномерных: "
                    "hit счетовода — 0,0.25,0.375,0.5,0.625,0.75,1 (7 кадров; середины — та же "
                    "арифметика, что и опорные, вместо RIFE)")
    ap.add_argument("--dest", default="", help="писать кадры прямо в эту папку (godot/assets/anim/<char>/<clip>)")
    ap.add_argument("--name", default="", help="папка клипа в assets/anim-lab/out (по умолчанию <kind>_v1)")
    a = ap.parse_args()

    ts = [float(v) for v in a.ts.split(",")] if a.ts else None
    n = len(ts) if ts else (a.frames or (5 if a.kind == "hit" else 8))
    fig = figure(Image.open(a.sprite))
    frames = render(fig, a.canvas, a.kind, n, ts)

    out = pathlib.Path(a.dest) if a.dest else ROOT / "assets/anim-lab/out" / (a.name or f"{a.kind}_v1") / "sprites"
    out.mkdir(parents=True, exist_ok=True)
    for f in out.glob("spr_*.png"):
        f.unlink()
    for i, im in enumerate(frames):
        im.save(out / f"spr_{i:02d}.png")

    if not a.dest:   # в папку игры гиф не кладём
        # GIF приёмки в игровом масштабе — принимать всё равно только в движении
        gif = []
        for im in frames:
            bg = Image.new("RGBA", im.size, (24, 20, 32, 255))
            bg.paste(im, (0, 0), im)
            gif.append(bg.resize((115, 115), Image.LANCZOS).convert("P", palette=Image.ADAPTIVE, colors=128))
        gif[0].save(out.parent / "preview_game.gif", save_all=True, append_images=gif[1:],
                    duration=int(1000 / (14 if a.kind == "hit" else 10)), loop=0, disposal=2)
    print(f"{a.kind}: {n} кадров -> {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
