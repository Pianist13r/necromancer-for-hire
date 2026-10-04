"""Замер характерного цвета бойцов по их настоящим спрайтам (линии-договоры красятся в него).

Почему так: «цвет бойца» — это доминирующий НАСЫЩЕННЫЙ цвет одежды/снаряжения, а не кость
и не контур. Поэтому берём все кадры всех клипов вида, отбрасываем прозрачное, серое
(кость, рубашка, контур — низкая насыщенность) и тёмное, раскладываем остаток по кольцу
оттенков (24 корзины по 15°) и печатаем кластеры по доле площади со средним цветом.

Запуск: python tools/kind_colors.py --godot <Godot executable>
Либо --sources <JSON>, экспортированный legion_lines_test.gd -- --export-sources <JSON>.
Клипы берутся из действующего CfgAnim, включая пять ракурсов; старые соседние папки не меряются.
"""
from __future__ import annotations

import argparse
import colorsys
import glob
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

from PIL import Image

PROJECT = Path(__file__).resolve().parents[1] / "godot"
MIN_ALPHA = 200
MIN_SAT = 0.30  # ниже — кость, белая рубашка, серые детали
MIN_VAL = 0.33  # ниже — тёмно-синий контур (V≈0,26, S≈0,7) и глубокие тени
BINS = 24


def measure(clip_dirs: list[str]) -> tuple[int, list[tuple[float, float, tuple[int, int, int], float, float]]]:
	sums = [[0.0, 0.0, 0.0, 0, 0.0, 0.0] for _ in range(BINS)]
	opaque = 0
	paths = {path for folder in clip_dirs for path in glob.glob(os.path.join(folder, "spr_*.png"))}
	for path in sorted(paths):
		im = Image.open(path).convert("RGBA")
		pixels = im.get_flattened_data() if hasattr(im, "get_flattened_data") else im.getdata()
		for r, g, b, a in pixels:
			if a < MIN_ALPHA:
				continue
			opaque += 1
			h, s, v = colorsys.rgb_to_hsv(r / 255.0, g / 255.0, b / 255.0)
			if s < MIN_SAT or v < MIN_VAL:
				continue
			k = int(h * BINS) % BINS
			acc = sums[k]
			acc[0] += r
			acc[1] += g
			acc[2] += b
			acc[3] += 1
			acc[4] += s
			acc[5] += v
	out = []
	for k, acc in enumerate(sums):
		n = acc[3]
		if n == 0:
			continue
		rgb = (round(acc[0] / n), round(acc[1] / n), round(acc[2] / n))
		out.append((n / opaque, k * 360.0 / BINS, rgb, acc[4] / n, acc[5] / n))
	out.sort(reverse=True)
	return opaque, out


def main() -> None:
	parser = argparse.ArgumentParser(description=__doc__)
	parser.add_argument("--sources", type=Path, help="CfgAnim manifest exported by legion_lines_test.gd")
	parser.add_argument("--godot", default=os.environ.get("GODOT_BIN") or shutil.which("godot"))
	args = parser.parse_args()
	if args.sources:
		sources = json.loads(args.sources.read_text(encoding="utf-8"))
	else:
		if not args.godot:
			parser.error("provide --godot, GODOT_BIN, or --sources; sources must reflect current CfgAnim")
		with tempfile.TemporaryDirectory(prefix="necro-kind-colors-") as scratch:
			output = Path(scratch) / "sources.json"
			env = os.environ.copy()
			env.update(APPDATA=str(Path(scratch) / "appdata"), XDG_DATA_HOME=str(Path(scratch) / "data"), NECRO_NO_DEV_BRIDGE="1")
			subprocess.run([args.godot, "--headless", "--mute", "--path", str(PROJECT),
				"--script", "res://tests/legion_lines_test.gd", "--", "--export-sources", str(output)],
				check=True, env=env, stdout=subprocess.DEVNULL)
			sources = json.loads(output.read_text(encoding="utf-8"))
	for kind, source in sources["kinds"].items():
		folders = [str(PROJECT / path.removeprefix("res://")) if path.startswith("res://") else path
			for path in source["dirs"]]
		opaque, clusters = measure(folders)
		print(f"== {kind} ({source['char_id']}): {len(folders)} runtime clip dirs, непрозрачных px {opaque}")
		for share, hue, rgb, s, v in clusters[:5]:
			hx = "#%02x%02x%02x" % rgb
			print(f"  {share * 100:5.1f}%  оттенок {hue:5.1f}°  {hx}  S={s:.2f} V={v:.2f}"
				+ f"  Color({rgb[0] / 255:.3f}, {rgb[1] / 255:.3f}, {rgb[2] / 255:.3f})")


if __name__ == "__main__":
	main()
