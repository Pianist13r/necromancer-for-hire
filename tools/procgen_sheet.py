"""Контактный лист схем процедурных карт (глаза координатора, BOOK §11).

Читает JSON карт из дампа godot/tests/procgen_dump.gd и рисует схему каждой: дорога кремом
шириной 46, препятствия и стены тёмным, вода/топь, участки кругами, Котёл, ворота, рубежи
бота, трещины, мимики, склепы, трассы призраков, зоны HUD полупрозрачно; подпись —
сид:k, архетип, биом, изюминки, необычность N (цель), сложность D.

    python tools/procgen_sheet.py <папка дампа> <префикс выхода> [--cols 12] [--scale 0.25]
        [--per 60] [--only gen_3_7,gen_4_2]

Выход: <префикс>_01.png, _02.png, … по --per карт на лист.
"""
import argparse
import glob
import json
import os
import re

from PIL import Image, ImageDraw, ImageFont

W, H = 1280, 720
ROAD_W = 46
BIOME_BG = {"grave": (44, 48, 66), "office": (58, 50, 44), "swamp": (40, 62, 56),
            "ash": (74, 60, 66), "site": (78, 66, 52)}
HUD = [(960, 0, 1280, 130), (340, 630, 940, 720), (960, 630, 1280, 720), (0, 0, 820, 50)]
FONT_PATHS = ["C:/Windows/Fonts/segoeui.ttf", "C:/Windows/Fonts/arial.ttf"]


def font(size):
    for p in FONT_PATHS:
        if os.path.exists(p):
            return ImageFont.truetype(p, size)
    return ImageFont.load_default()


def pts(raw, s):
    return [(x * s, y * s) for x, y in raw]


def draw_map(m, s):
    img = Image.new("RGB", (int(W * s), int(H * s)), BIOME_BG.get(m.get("biome"), (50, 50, 50)))
    over = Image.new("RGBA", img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    o = ImageDraw.Draw(over)
    for poly in m.get("water", []):
        d.polygon(pts(poly, s), fill=(40, 90, 130))
    for poly in m.get("swamp", []):
        d.polygon(pts(poly, s), fill=(60, 110, 90))
    for road in m["roads"]:
        p = pts(road["path"], s)
        d.line(p, fill=(236, 214, 178), width=max(2, int(ROAD_W * s)), joint="curve")
    for poly in m.get("bridges", []):
        d.polygon(pts(poly, s), fill=(150, 110, 70), outline=(90, 60, 40))
    for poly in m.get("rocks", []):
        d.polygon(pts(poly, s), fill=(30, 26, 40), outline=(12, 10, 16))
    for wl in m.get("walls", []):
        d.line(pts(wl["path"], s), fill=(22, 18, 28), width=max(2, int(wl["w"] * s)))
    for fl in m.get("flights", []):
        p = pts(fl["path"], s)
        for a, b in zip(p, p[1:]):
            n = 20
            for i in range(0, n, 2):
                x0 = a[0] + (b[0] - a[0]) * i / n
                y0 = a[1] + (b[1] - a[1]) * i / n
                x1 = a[0] + (b[0] - a[0]) * (i + 1) / n
                y1 = a[1] + (b[1] - a[1]) * (i + 1) / n
                d.line([(x0, y0), (x1, y1)], fill=(120, 240, 230), width=max(1, int(3 * s)))
    for pr in m.get("props", []):
        x, y = pr["pos"][0] * s, pr["pos"][1] * s
        item = pr["item"]
        if item.startswith("light"):
            d.ellipse([x - 3 * s * 2, y - 3 * s * 2, x + 3 * s * 2, y + 3 * s * 2],
                      fill=(255, 200, 110))
        elif item.startswith("dec_tree"):
            d.ellipse([x - 12 * s, y - 12 * s, x + 12 * s, y + 12 * s], outline=(120, 140, 90))
        elif item.startswith("dec_"):
            d.rectangle([x - 2, y - 2, x + 2, y + 2], fill=(150, 150, 150))
    for bl in m.get("bot_lines", []):
        col = (90, 170, 255) if bl.get("role") == "front" else (255, 120, 220)
        d.line(pts([bl["a"], bl["b"]], s), fill=col, width=max(2, int(6 * s)))
    for pl in m.get("plots", []):
        x, y = pl["pos"][0] * s, pl["pos"][1] * s
        r = 24 * s
        d.ellipse([x - r, y - r, x + r, y + r], outline=(255, 255, 255), width=max(1, int(3 * s)))
    for c in m.get("crypts", []):
        x, y = c["pos"][0] * s, c["pos"][1] * s
        d.rectangle([x - 18 * s, y - 18 * s, x + 18 * s, y + 18 * s], fill=(200, 200, 170))
    for sl in m.get("sleepers", []):
        x, y = sl["pos"][0] * s, sl["pos"][1] * s
        d.ellipse([x - 12 * s, y - 12 * s, x + 12 * s, y + 12 * s], fill=(220, 120, 255))
    paths = {r["id"]: r["path"] for r in m["roads"]}
    for br in m.get("breaches", []):
        p = point_at(paths[br["road"]], br["at"])
        x, y = p[0] * s, p[1] * s
        k = 14 * s
        d.line([(x - k, y - k), (x + k, y + k)], fill=(255, 150, 40), width=max(2, int(5 * s)))
        d.line([(x - k, y + k), (x + k, y - k)], fill=(255, 150, 40), width=max(2, int(5 * s)))
    cx, cy = m["cauldron"][0] * s, m["cauldron"][1] * s
    r = 38 * s
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(150, 70, 220))
    for road in m["roads"]:
        g = gate_point(road["path"])
        x, y = g[0] * s, g[1] * s
        d.rectangle([x - 8 * s, y - 8 * s, x + 8 * s, y + 8 * s], fill=(230, 40, 40))
    for x0, y0, x1, y1 in HUD:
        o.rectangle([x0 * s, y0 * s, x1 * s, y1 * s], fill=(255, 60, 60, 48))
    img = Image.alpha_composite(img.convert("RGBA"), over).convert("RGB")
    return img


def point_at(path, at):
    left = at
    for a, b in zip(path, path[1:]):
        seg = ((b[0] - a[0]) ** 2 + (b[1] - a[1]) ** 2) ** 0.5
        if left <= seg and seg > 0:
            t = left / seg
            return (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t)
        left -= seg
    return path[-1]


def gate_point(path):
    (x0, y0), (x1, y1) = path[0], path[1]
    t = 0.0
    if x0 < 0:
        t = -x0 / (x1 - x0)
    elif x0 > W:
        t = (x0 - W) / (x0 - x1)
    elif y0 < 0:
        t = -y0 / (y1 - y0)
    elif y0 > H:
        t = (y0 - H) / (y0 - y1)
    t = max(0.0, min(1.0, t))
    return (x0 + (x1 - x0) * t, y0 + (y1 - y0) * t)


def caption(m):
    pg = m.get("procgen", {})
    card = pg.get("card", {})
    q = ",".join(card.get("quirks", []))
    mir = "·зерк" if card.get("mirror") else ""
    return (f"{pg.get('seed')}:{pg.get('k')} {card.get('archetype')}{mir} {card.get('biome')}",
            f"{q} N={card.get('unusual', 0):.2f}/{card.get('target', 0):.2f} "
            f"D={card.get('difficulty', 1):.2f} a{pg.get('attempt')}")


def key(path):
    nums = re.findall(r"\d+", os.path.basename(path))
    return tuple(int(n) for n in nums)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dump")
    ap.add_argument("out")
    ap.add_argument("--cols", type=int, default=12)
    ap.add_argument("--scale", type=float, default=0.25)
    ap.add_argument("--per", type=int, default=60)
    ap.add_argument("--only", default="")
    a = ap.parse_args()
    files = sorted(glob.glob(os.path.join(a.dump, "gen_*.json")), key=key)
    if a.only:
        want = set(a.only.split(","))
        files = [f for f in files if os.path.splitext(os.path.basename(f))[0] in want]
    tw, th = int(W * a.scale), int(H * a.scale)
    cap_h = 34 if a.scale <= 0.3 else 44
    f1 = font(12 if a.scale <= 0.3 else 16)
    pages = [files[i:i + a.per] for i in range(0, len(files), a.per)]
    for pi, page in enumerate(pages):
        cols = min(a.cols, len(page))
        rows = (len(page) + cols - 1) // cols
        sheet = Image.new("RGB", (cols * (tw + 6), rows * (th + cap_h + 6)), (16, 16, 18))
        for i, f in enumerate(page):
            with open(f, encoding="utf-8") as fh:
                m = json.load(fh)
            x = (i % cols) * (tw + 6)
            y = (i // cols) * (th + cap_h + 6)
            sheet.paste(draw_map(m, a.scale), (x, y))
            d = ImageDraw.Draw(sheet)
            c1, c2 = caption(m)
            d.text((x + 2, y + th + 1), c1, fill=(235, 235, 235), font=f1)
            d.text((x + 2, y + th + 1 + cap_h // 2), c2, fill=(190, 190, 150), font=f1)
        out = f"{a.out}_{pi + 1:02d}.png"
        sheet.save(out)
        print(out, len(page))


if __name__ == "__main__":
    main()
