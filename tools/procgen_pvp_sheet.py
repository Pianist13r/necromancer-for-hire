"""Лист схем полей PvP из половин процгена (линия L2, docs/pvp/DESIGN.md §3, BOOK §12).

Читает JSON полей из дампа godot/tests/procgen_pvp_dump.gd и рисует схему каждого поля в
масштабе показа (поле 1600x900 мира при 0,8 = кадр 1280x720): дороги кремом (дорога волн PvE
оранжевее), препятствия и стены тёмным, вода/топь, участки кругами (сторона 0 — белые, 1 —
голубые), оба Котла, ворота PvE, проёмы стыка зелёным, нейтральная полоса, панели HUD
полупрозрачно (свои — красным, зеркальные — пурпурным: второй игрок видит поле отражённым).

    python tools/procgen_pvp_sheet.py <папка дампа> <префикс выхода> [--cols 4] [--scale 0.3]
        [--per 20] [--view 1.0]

--view — масштаб показа (0,8 — как в игре: кадр 1280x720); лист мельче — меньше --scale.
Выход: <префикс>_01.png, … по --per полей на лист.
"""
import argparse
import glob
import json
import os
import re

from PIL import Image, ImageDraw, ImageFont

ROAD_W = 46
BIOME_BG = {"grave": (44, 48, 66), "office": (58, 50, 44), "swamp": (40, 62, 56),
            "ash": (74, 60, 66), "site": (78, 66, 52)}
# панели HUD одиночной игры в координатах экрана 1280x720 (PgGeom.HUD_RECTS)
HUD = [(960, 0, 1280, 130), (340, 630, 940, 720), (960, 630, 1280, 720), (0, 0, 820, 50)]
FONT_PATHS = ["C:/Windows/Fonts/segoeui.ttf", "C:/Windows/Fonts/arial.ttf"]


def font(size):
    for p in FONT_PATHS:
        if os.path.exists(p):
            return ImageFont.truetype(p, size)
    return ImageFont.load_default()


def pts(raw, s):
    return [(x * s, y * s) for x, y in raw]


def draw_field(m, s):
    fw, fh = m["size"]
    seam = fw / 2
    view = m.get("scale", 0.8)
    img = Image.new("RGB", (int(fw * s), int(fh * s)), BIOME_BG.get(m.get("biome"), (50, 50, 50)))
    over = Image.new("RGBA", img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    o = ImageDraw.Draw(over)
    pg = m["procgen"]["pvp"]
    n = pg["neutral"]
    o.rectangle([(seam - n) * s, 0, (seam + n) * s, fh * s], fill=(120, 200, 255, 26))
    for poly in m.get("water", []):
        d.polygon(pts(poly, s), fill=(40, 90, 130))
    for poly in m.get("swamp", []):
        d.polygon(pts(poly, s), fill=(60, 110, 90))
    for road in m["roads"]:
        col = (236, 190, 130) if road.get("kind") == "pve" else (236, 214, 178)
        d.line(pts(road["path"], s), fill=col, width=max(2, int(ROAD_W * s)), joint="curve")
    for poly in m.get("bridges", []):
        d.polygon(pts(poly, s), fill=(150, 110, 70), outline=(90, 60, 40))
    for poly in m.get("rocks", []):
        d.polygon(pts(poly, s), fill=(30, 26, 40), outline=(12, 10, 16))
    for wl in m.get("walls", []):
        d.line(pts(wl["path"], s), fill=(22, 18, 28), width=max(2, int(wl["w"] * s)))
    for pr in m.get("props", []):
        x, y = pr["pos"][0] * s, pr["pos"][1] * s
        item = pr["item"]
        if item.startswith("light"):
            d.ellipse([x - 5 * s, y - 5 * s, x + 5 * s, y + 5 * s], fill=(255, 200, 110))
        elif item.startswith("dec_tree"):
            d.ellipse([x - 12 * s, y - 12 * s, x + 12 * s, y + 12 * s], outline=(120, 140, 90))
    for bl in m.get("bot_lines", []):
        col = (90, 170, 255) if bl.get("role") == "front" else (255, 120, 220)
        d.line(pts([bl["a"], bl["b"]], s), fill=col, width=max(2, int(6 * s)))
    for pl in m.get("plots", []):
        x, y = pl["pos"][0] * s, pl["pos"][1] * s
        r = 24 * s
        col = (255, 255, 255) if pl["side"] == 0 else (140, 220, 255)
        d.ellipse([x - r, y - r, x + r, y + r], outline=col, width=max(1, int(3 * s)))
    for c in m["cauldrons"]:
        cx, cy = c["pos"][0] * s, c["pos"][1] * s
        r = 38 * s
        d.ellipse([cx - r, cy - r, cx + r, cy + r],
                  fill=(150, 70, 220) if c["side"] == 0 else (220, 110, 60))
    for g in m.get("gates", []):
        x, y = g["pos"][0] * s, g["pos"][1] * s
        d.rectangle([x - 10 * s, y, x + 10 * s, y + 16 * s], fill=(230, 40, 40))
    for sp in pg["spans"]:
        d.line([(seam * s, sp[0] * s), (seam * s, sp[1] * s)], fill=(80, 255, 120),
               width=max(2, int(8 * s)))
    for x0, y0, x1, y1 in HUD:
        a = (x0 / view, y0 / view, x1 / view, y1 / view)
        o.rectangle([a[0] * s, a[1] * s, a[2] * s, a[3] * s], fill=(255, 60, 60, 60))
        o.rectangle([(fw - a[2]) * s, a[1] * s, (fw - a[0]) * s, a[3] * s],
                    fill=(200, 60, 255, 40))
    return Image.alpha_composite(img.convert("RGBA"), over).convert("RGB")


def caption(m):
    pg = m["procgen"]
    card = pg.get("card", {})
    pv = pg["pvp"]
    spans = " ".join(f"{a}-{b}" for a, b in pv["spans"])
    q = pv.get("quirk") or "-"
    return (f"{pg.get('seed')}:{pg.get('k')} {card.get('archetype')} {card.get('biome')} "
            f"a{pg.get('attempt')}",
            f"стык {pv['seam']} ({q}) проёмы {spans} нейтр {pv['neutral']} "
            f"участков {len(m['plots']) // 2}")


def key(path):
    return tuple(int(n) for n in re.findall(r"\d+", os.path.basename(path)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dump")
    ap.add_argument("out")
    ap.add_argument("--cols", type=int, default=4)
    ap.add_argument("--scale", type=float, default=0.3)
    ap.add_argument("--per", type=int, default=20)
    a = ap.parse_args()
    files = sorted(glob.glob(os.path.join(a.dump, "pvp_*.json")), key=key)
    maps = []
    for f in files:
        with open(f, encoding="utf-8") as fh:
            maps.append(json.load(fh))
    if not maps:
        print("нет полей")
        return
    fw, fh = maps[0]["size"]
    tw, th = int(fw * a.scale), int(fh * a.scale)
    cap_h = 40
    f1 = font(13)
    for pi in range(0, len(maps), a.per):
        page = maps[pi:pi + a.per]
        cols = min(a.cols, len(page))
        rows = (len(page) + cols - 1) // cols
        sheet = Image.new("RGB", (cols * (tw + 6), rows * (th + cap_h + 6)), (16, 16, 18))
        for i, m in enumerate(page):
            x = (i % cols) * (tw + 6)
            y = (i // cols) * (th + cap_h + 6)
            sheet.paste(draw_field(m, a.scale), (x, y))
            d = ImageDraw.Draw(sheet)
            c1, c2 = caption(m)
            d.text((x + 2, y + th + 1), c1, fill=(235, 235, 235), font=f1)
            d.text((x + 2, y + th + 1 + cap_h // 2), c2, fill=(190, 190, 150), font=f1)
        out = f"{a.out}_{pi // a.per + 1:02d}.png"
        sheet.save(out)
        print(out, len(page))


if __name__ == "__main__":
    main()
