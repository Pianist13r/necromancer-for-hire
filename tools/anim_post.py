#!/usr/bin/env python3
"""anim_post.py — постобработка сгенерированных кадров в игровые спрайты.

По рецепту .claude/skills/ai-game-art-pipeline/references/battle-sprites.md:
  хромакей magenta -> крупнейшая связная компонента -> единый масштаб (dual cap
  по высоте/ширине) -> якорь по подошве -> PNG-кадры + GIF приёмки + GIF в игровом
  масштабе (~90 px, правило v7: принимать только в движении и в игровом размере).

Запуск: python tools/anim_post.py assets/anim-lab/out/walk_v1 [--game-px 90] [--fps 10]
"""
import argparse
import sys
from pathlib import Path

import numpy as np
from PIL import Image

KEY = np.array([255, 0, 255])  # magenta
KEY_TOL = 90
# Кадры переноса движения приходят не на magenta, а на ровном сером фоне ролика.
# Держим оба варианта: конвейер один, а источники кадров разные.
FLAT_BG: tuple[int, int, int] | None = None
FLAT_TOL = 42


def keyout(im: Image.Image) -> np.ndarray:
    if FLAT_BG is not None:
        a = np.array(im.convert("RGB")).astype(np.int16)
        return np.abs(a - np.array(FLAT_BG, dtype=np.int16)).max(axis=2) > FLAT_TOL
    return _keyout_magenta(im)


def _keyout_magenta(im: Image.Image) -> np.ndarray:
    """Маска персонажа: не-magenta пиксели. Дополнительно выкидывает «семью magenta» —
    тень под ногами модель рисует тёмно-розовой, она касается подошв и выживает в кейинге."""
    a = np.array(im.convert("RGB")).astype(int)
    dist = np.abs(a - KEY).sum(axis=2)
    r, g, b = a[:, :, 0], a[:, :, 1], a[:, :, 2]
    # Qwen рисует "magenta" как кримсон ~(229,8,134), тень — его затемнение.
    # Семья: красный заметно > зелёного, синий > зелёного. Персонаж (белый/оранж/
    # зелёный/коричневый) под это не попадает — проверено по палитре кадра.
    magenta_family = (r - g > 50) & (b - g > 15) & (r > 40) & (b > 25)
    return (dist > KEY_TOL * 3) & ~magenta_family


def largest_component(mask: np.ndarray) -> np.ndarray:
    """Оставляет крупнейшую связную компоненту (4-связность, простой flood fill)."""
    from collections import deque

    h, w = mask.shape
    seen = np.zeros_like(mask, dtype=bool)
    best = np.zeros_like(mask, dtype=bool)
    best_n = 0
    for y0 in range(h):
        row = np.where(mask[y0] & ~seen[y0])[0]
        for x0 in row:
            if seen[y0, x0] or not mask[y0, x0]:
                continue
            comp = np.zeros_like(mask, dtype=bool)
            q = deque([(y0, x0)])
            seen[y0, x0] = True
            n = 0
            while q:
                y, x = q.popleft()
                comp[y, x] = True
                n += 1
                for ny, nx in ((y - 1, x), (y + 1, x), (y, x - 1), (y, x + 1)):
                    if 0 <= ny < h and 0 <= nx < w and mask[ny, nx] and not seen[ny, nx]:
                        seen[ny, nx] = True
                        q.append((ny, nx))
            if n > best_n:
                best_n = n
                best = comp
    return best


def head_center_x(mask: np.ndarray) -> int:
    """Горизонтальный центр ГОЛОВЫ — верхних 18 % силуэта.

    Скилл ai-game-art-pipeline (battle-sprites) прямо запрещает якорить ходьбу и бег
    по центру bbox: движение ног смещает рамку, и персонаж качается вбок. Голова при
    ходьбе почти не гуляет — по ней и якорим.
    """
    ys, xs = np.where(mask)
    if len(xs) == 0:
        return 0
    top, bottom = ys.min(), ys.max()
    band = ys <= top + max(1, int((bottom - top) * 0.18))
    return int(np.median(xs[band]))


def process_fixed(frames: list[Image.Image], target_h: int = 460) -> list[Image.Image]:
    """Режим --anchor fixed: кадры УЖЕ выровнены источником (рендер рига неподвижной
    камерой) — кропаем все одним ОБЩИМ bbox и не переякориваем. Якорение по голове здесь
    вредно: у замаха голова ДОЛЖНА гулять, а стопы стоять; пере-якорь по голове превращал
    наклон корпуса в «ноги едут под неподвижной головой» (замер 2026-08-26)."""
    masks = []
    for im in frames:
        masks.append(largest_component(keyout(im)))
    union = np.zeros_like(masks[0], dtype=bool)
    for m in masks:
        union |= m
    ys, xs = np.where(union)
    if len(ys) == 0:
        raise SystemExit("ни одного кадра после кеинга")
    x0, x1, y0, y1 = xs.min(), xs.max() + 1, ys.min(), ys.max() + 1
    scale = min(target_h * 0.92 / (y1 - y0), target_h * 0.96 / (x1 - x0))
    out = []
    for im, m in zip(frames, masks):
        crop = im.convert("RGBA").crop((x0, y0, x1, y1))
        a = np.array(crop)
        a[~m[y0:y1, x0:x1]] = (0, 0, 0, 0)
        img = Image.fromarray(a)
        img = img.resize((max(1, int(img.width * scale)), max(1, int(img.height * scale))),
                         Image.LANCZOS)
        canvas = Image.new("RGBA", (target_h, target_h), (0, 0, 0, 0))
        canvas.paste(img, ((target_h - img.width) // 2,
                           target_h - img.height - int(target_h * 0.02)), img)
        out.append(canvas)
    return out


def process(frames: list[Image.Image], target_h: int = 460) -> list[Image.Image]:
    """Ключит, чистит, масштабирует единым коэффициентом, якорит по подошве и голове."""
    keyed = []
    heights, widths = [], []
    for im in frames:
        m = largest_component(keyout(im))
        ys, xs = np.where(m)
        if len(ys) == 0:
            keyed.append(None)
            continue
        x0, x1, y0, y1 = xs.min(), xs.max() + 1, ys.min(), ys.max() + 1
        crop = im.convert("RGBA").crop((x0, y0, x1, y1))
        a = np.array(crop)
        a[~m[y0:y1, x0:x1]] = (0, 0, 0, 0)
        head_x = head_center_x(m) - x0  # координата головы ВНУТРИ кропа
        keyed.append((Image.fromarray(a), (x1 - x0, y1 - y0), head_x))
        heights.append(y1 - y0)
        widths.append(x1 - x0)
    if not heights:
        raise SystemExit("ни одного кадра после кеинга")
    ref_h = float(np.median(heights))
    max_w = float(max(widths))
    scale = min(target_h * 0.92 / ref_h, target_h * 0.96 / max_w)

    out = []
    for item in keyed:
        if item is None:
            continue
        img, (cw, ch), head_x = item
        img = img.resize((max(1, int(cw * scale)), max(1, int(ch * scale))), Image.LANCZOS)
        # канва: якорь — низ (подошва) и центр ГОЛОВЫ по горизонтали.
        # По центру bbox якорить нельзя: шаг двигает рамку и персонаж качается вбок.
        canvas = Image.new("RGBA", (target_h, target_h), (0, 0, 0, 0))
        ox = int(round(target_h / 2 - head_x * scale))
        ox = max(min(ox, target_h - img.width), 0) if img.width <= target_h else ox
        canvas.paste(img, (ox, target_h - img.height - int(target_h * 0.02)), img)
        out.append(canvas)
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("indir")
    ap.add_argument("--game-px", type=int, default=90)
    ap.add_argument("--fps", type=float, default=10.0)
    ap.add_argument("--loop", action="store_true", help="зациклить GIF (для ходьбы)")
    ap.add_argument("--bg", default="", help="ровный фон кадров, напр. 128,128,128 (кадры переноса движения)")
    ap.add_argument("--anchor", choices=("head", "fixed"), default="head",
                    help="head — якорь по голове (сгенерированные кадры гуляют); "
                         "fixed — общий bbox без пере-якоря (кадры рига уже выровнены)")
    a = ap.parse_args()
    if a.bg:
        globals()["FLAT_BG"] = tuple(int(x) for x in a.bg.split(","))
    indir = Path(a.indir)
    files = sorted(indir.glob("frame_*.png"))
    print(f"кадров: {len(files)}")
    frames = [Image.open(f) for f in files]
    sprites = process_fixed(frames) if a.anchor == "fixed" else process(frames)
    spr_dir = indir / "sprites"
    spr_dir.mkdir(exist_ok=True)
    for i, s in enumerate(sprites):
        s.save(spr_dir / f"spr_{i:02d}.png")
    dur = int(1000 / a.fps)
    # GIF приёмки крупно и в игровом масштабе (на тёмном фоне игры)
    for tag, size in (("big", 460), ("game", a.game_px)):
        gifs = []
        for s in sprites:
            bg = Image.new("RGBA", s.size, (24, 20, 32, 255))
            bg.paste(s, (0, 0), s)
            bg = bg.resize((size, size), Image.LANCZOS)
            gifs.append(bg.convert("P", palette=Image.ADAPTIVE, colors=128))
        loop = 0 if a.loop else 0
        gifs[0].save(indir / f"preview_{tag}.gif", save_all=True, append_images=gifs[1:],
                     duration=dur, loop=loop, disposal=1)
    print(f"готово: {spr_dir}, preview_big.gif, preview_game.gif ({a.game_px}px)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
