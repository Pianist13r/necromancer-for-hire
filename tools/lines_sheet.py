"""Контактный лист кадров приёмки линий (tests/legion_lines_shots.gd) в игровом масштабе.

    python tools/lines_sheet.py C:/AI/necro/batches/legion/lines [--gfx full] [--maps fork,maze]
        [--crop 240,190,580,500] [--out sheet.png]

Кадры режутся по одной области (1:1, без масштабирования — «как в игре»), под каждым подпись
из shots_<gfx>.json. Ровные кадры всех карт идут первыми, затем сюжет (черчение → растворение).
"""
from __future__ import annotations

import argparse
import json
import os

from PIL import Image, ImageDraw, ImageFont


def main() -> int:
	ap = argparse.ArgumentParser()
	ap.add_argument("src")
	ap.add_argument("--gfx", default="full")
	ap.add_argument("--maps", default="")
	ap.add_argument("--only", default="", help="подстроки имён кадров через запятую")
	ap.add_argument("--crop", default="240,190,580,500")
	ap.add_argument("--cols", type=int, default=3)
	ap.add_argument("--out", default="")
	a = ap.parse_args()
	rows = json.load(open(os.path.join(a.src, f"shots_{a.gfx}.json"), encoding="utf-8"))
	maps = [m for m in a.maps.split(",") if m]
	only = [o for o in a.only.split(",") if o]
	if maps:
		rows = [r for r in rows if r["map"] in maps]
	if only:
		rows = [r for r in rows if any(o in r["file"] for o in only)]
	x, y, w, h = (int(v) for v in a.crop.split(","))
	label_h = 22
	cols = min(a.cols, len(rows))
	n_rows = (len(rows) + cols - 1) // cols
	sheet = Image.new("RGB", (cols * w, n_rows * (h + label_h)), (16, 14, 20))
	draw = ImageDraw.Draw(sheet)
	try:
		font = ImageFont.truetype("arial.ttf", 14)
	except OSError:
		font = ImageFont.load_default()
	for i, r in enumerate(rows):
		im = Image.open(os.path.join(a.src, r["file"])).convert("RGB").crop((x, y, x + w, y + h))
		cx, cy = (i % cols) * w, (i // cols) * (h + label_h)
		sheet.paste(im, (cx, cy + label_h))
		draw.text((cx + 6, cy + 3), f"{r['map']}: {r['what']}", fill=(235, 230, 245), font=font)
	out = a.out or os.path.join(a.src, f"sheet_{a.gfx}.png")
	sheet.save(out)
	print(out, sheet.size)
	return 0


if __name__ == "__main__":
	raise SystemExit(main())
