"""Тайлы фактуры дороги для сборки процедурных карт (PgArt, линия art3, 27.09.2026).

Зачем: дорога сборки была плоской бежевой полосой. На фонах кампании дорога нарисована — тёплая,
светлая, с фактурой камня/утоптанной земли и каймой. Геометрия этой дороги известна из JSON карты
(ось `roads[].path`, ширина 46 мира = 69 px фона 1920×1080), поэтому прямые участки можно
вырезать из фона и сделать из них бесшовную вдоль длины полосу — «как нарисовано», без нейросети
у игрока (D-0927-71, -97): картинку делает этот скрипт один раз, игра только тайлит её по оси.

Как:
  1. по каждой дороге карты — прямые участки ≥ SEG_MIN мира, без концов у поворотов (TRIM);
  2. полоса ±HALF_SCAN px поперёк оси, вертикальные повёрнуты «вдоль x»;
  3. поперёк — строки от внешнего края верхней каймы до нижней (PICKS, сняты глазом по листу
     --bands: ось JSON не всегда совпадает с серединой нарисованной дороги), полоса
     пересчитывается симметрично вокруг их середины;
  4. бесшовность вдоль: период L выбирается так, чтобы начало и продолжение полосы были
     похожи, шов закрыт кроссфейдом OVERLAP px;
  5. альфа поперёк — мягкий спад в крайних FADE px (земля сборки видна за каймой).

Выбор участка на биом — ручной, после взгляда на лист кандидатов (--sheet): у некоторых
участков на дороге стоят свечи, участки-кружки и ворота.

Запуск:
  python tools/procgen_road_tiles.py --sheet C:/AI/necro/batches/procgen/art3/road_cands.jpg
  python tools/procgen_road_tiles.py --bands C:/AI/necro/batches/procgen/art3/road_bands.png
  python tools/procgen_road_tiles.py            # пишет godot/assets/legion/procgen/road/
"""
import argparse
import json
import os

import numpy as np
from PIL import Image, ImageDraw

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "godot")
MAPS = os.path.join(ROOT, "assets", "legion", "maps")
OUT = os.path.join(ROOT, "assets", "legion", "procgen", "road")

SCALE = 1.5          # мир → px фона
SEG_MIN = 150.0      # мир: короче — не прямой участок, а колено
TRIM = 42.0          # мир: отступ от поворота (там кайма заворачивает)
HALF_SCAN = 64       # px: половина окна поперёк оси для поиска краёв
PAD = 2              # px: запас за краем каймы (его съедает мягкий спад FADE)
FADE = 4             # px: мягкий спад альфы к краю полосы (шире — съедает тёмную кайму)
OVERLAP = 36         # px: кроссфейд шва по длине
MIN_PERIOD = 150     # px: короче — повтор заметен глазу

# Биом процгена → (фон, дорога, индекс прямого участка в списке кандидатов этой дороги).
# Индексы выбраны по листу кандидатов (--sheet) — самый длинный чистый участок без свечей,
# кружков участков и ворот на полотне. Последнее — строки окна (0…2·HALF_SCAN) от внешнего края
# верхней каймы до внешнего края нижней, сняты глазом по листу с линейкой (--bands): поиск
# края автоматически путал кайму с оградой за травой (fork) и с полосами фактуры (boss, пустырь).
# Второй участок (B-170) — другая вырезка того же биома: игра чередует их по длине дороги
# (pg_road.gdshader), и повтор тайла перестаёт читаться. Высота второго подгоняется к первому.
PICKS = {
	"grave": ("fork", "north", 1, (26, 100)),
	"swamp": ("swamp", "north", 4, (20, 99)),
	"ash": ("wasteland", "east", 1, (25, 102)),
	"office": ("archive", "north", 2, (25, 101)),
	"site": ("boss", "north", 4, (17, 99)),
}
PICKS_B = {
	"grave": ("fork", "south", 1, (26, 102)),
	"swamp": ("swamp", "south", 1, (21, 104)),
	"ash": ("wasteland", "east", 2, (18, 102)),
	"office": ("archive", "south", 2, (25, 101)),
	"site": ("boss", "north", 2, (13, 104)),
}


def luma(a):
	return a[..., 0] * 0.299 + a[..., 1] * 0.587 + a[..., 2] * 0.114


def candidates(map_id):
	"""Прямые участки дорог карты: [(road_id, idx, strip RGB float, длина px)]."""
	data = json.load(open(os.path.join(MAPS, map_id + ".json"), encoding="utf-8"))
	img = np.asarray(Image.open(os.path.join(MAPS, map_id + "_bg.jpg")).convert("RGB"),
		dtype=np.float32) / 255.0
	h, w, _ = img.shape
	out = []
	for road in data.get("roads", []):
		path = road["path"]
		idx = 0
		for a, b in zip(path, path[1:]):
			ax, ay, bx, by = (float(v) for v in (*a, *b))
			if ax != bx and ay != by:
				continue
			length = abs(bx - ax) + abs(by - ay)
			if length < SEG_MIN:
				continue
			if ay == by:
				x0, x1 = sorted((ax, bx))
				x0 = max(x0 + TRIM, 4.0 / SCALE)
				x1 = min(x1 - TRIM, (w - 4) / SCALE)
				cy = int(round(ay * SCALE))
				if x1 - x0 < SEG_MIN * 0.5 or cy - HALF_SCAN < 0 or cy + HALF_SCAN > h:
					continue
				strip = img[cy - HALF_SCAN:cy + HALF_SCAN, int(x0 * SCALE):int(x1 * SCALE)]
			else:
				y0, y1 = sorted((ay, by))
				y0 = max(y0 + TRIM, 4.0 / SCALE)
				y1 = min(y1 - TRIM, (h - 4) / SCALE)
				cx = int(round(ax * SCALE))
				if y1 - y0 < SEG_MIN * 0.5 or cx - HALF_SCAN < 0 or cx + HALF_SCAN > w:
					continue
				strip = img[int(y0 * SCALE):int(y1 * SCALE), cx - HALF_SCAN:cx + HALF_SCAN]
				# вдоль x: верх полосы — левый край дороги (свет сверху слева остаётся сверху)
				strip = np.rot90(strip, k=-1)[:, ::-1]
			out.append((road["id"], idx, np.ascontiguousarray(strip), strip.shape[1]))
			idx += 1
	return out


def seamless(strip):
	"""Бесшовная вдоль x полоса: период с наименьшим расхождением + кроссфейд шва."""
	n = strip.shape[1]
	best, best_l = None, n - OVERLAP
	for period in range(max(MIN_PERIOD, n // 2), n - OVERLAP + 1, 2):
		d = np.abs(strip[:, period:period + OVERLAP] - strip[:, :OVERLAP]).mean()
		if best is None or d < best:
			best, best_l = d, period
	period = best_l
	tile = strip[:, :period].copy()
	for x in range(OVERLAP):
		t = x / float(OVERLAP)
		tile[:, x] = strip[:, period + x] * (1.0 - t) + strip[:, x] * t
	return tile


def build(strip, rows):
	top, bot = rows
	mid = (top + bot) * 0.5
	half = int(np.ceil(max(mid - top, bot - mid))) + PAD
	a = int(max(0, round(mid - half)))
	b = int(min(strip.shape[0], round(mid + half)))
	core = strip[a:b]
	tile = seamless(core)
	hgt = tile.shape[0]
	alpha = np.ones((hgt,), dtype=np.float32)
	for i in range(FADE):
		t = (i + 0.5) / FADE
		t = t * t * (3.0 - 2.0 * t)
		alpha[i] = t
		alpha[hgt - 1 - i] = t
	rgba = np.dstack([tile, np.repeat(alpha[:, None], tile.shape[1], axis=1)])
	return rgba


def main():
	ap = argparse.ArgumentParser()
	ap.add_argument("--sheet", default="", help="лист кандидатов (jpg) вместо записи тайлов")
	ap.add_argument("--bands", default="", help="лист выбранных участков с линейкой строк")
	ap.add_argument("--second", action="store_true", help="--bands по вторым участкам (PICKS_B)")
	args = ap.parse_args()
	if args.bands:
		picks = PICKS_B if args.second else PICKS
		out = Image.new("RGB", (720, len(picks) * HALF_SCAN * 2), (0, 0, 0))
		for i, (biome, (map_id, road_id, idx, rows)) in enumerate(picks.items()):
			strip = [s for r, j, s, _ in candidates(map_id) if r == road_id and j == idx][0]
			im = Image.fromarray((strip[:, :720] * 255).astype(np.uint8))
			d = ImageDraw.Draw(im)
			for y in range(0, HALF_SCAN * 2, 8):
				d.line((0, y, 30 if y % 16 == 0 else 12, y), fill=(255, 0, 0))
				if y % 16 == 0:
					d.text((34, y - 5), str(y), fill=(255, 255, 0))
			d.line((40, rows[0], 700, rows[0]), fill=(0, 255, 255))
			d.line((40, rows[1], 700, rows[1]), fill=(0, 255, 255))
			d.text((600, 4), biome, fill=(255, 255, 0))
			out.paste(im, (0, i * HALF_SCAN * 2))
		out.save(args.bands)
		print("линейка:", args.bands)
		return
	if args.sheet:
		rows = []
		for biome, (map_id, _road, _i, _rows) in PICKS.items():
			for road_id, idx, strip, n in candidates(map_id):
				rows.append((f"{biome} {map_id} {road_id}#{idx} {n}px", strip))
		width = min(1600, max(s.shape[1] for _, s in rows))
		sheet = Image.new("RGB", (width, len(rows) * (HALF_SCAN * 2 + 18)), (30, 30, 30))
		draw = ImageDraw.Draw(sheet)
		y = 0
		for label, strip in rows:
			im = Image.fromarray((strip[:, :width] * 255).astype(np.uint8))
			sheet.paste(im, (0, y + 16))
			draw.text((4, y + 2), label, fill=(255, 255, 0))
			y += HALF_SCAN * 2 + 18
		sheet.save(args.sheet, quality=88)
		print("лист:", args.sheet, len(rows), "кандидатов")
		return
	os.makedirs(OUT, exist_ok=True)
	meta = {}
	for biome, (map_id, road_id, idx, rows) in PICKS.items():
		picked = [s for r, i, s, _ in candidates(map_id) if r == road_id and i == idx]
		if not picked:
			raise SystemExit(f"{biome}: нет участка {map_id}/{road_id}#{idx}")
		rgba = build(picked[0], rows)
		img = Image.fromarray((np.clip(rgba, 0, 1) * 255).astype(np.uint8), "RGBA")
		name = f"road_{biome}.png"
		img.save(os.path.join(OUT, name))
		core = rgba[FADE:-FADE, :, :3]
		# светлота полотна (середина полосы, без каймы) — PgArt подгоняет яркость дороги к
		# земле подложки по этому числу, а не по цвету пикселя в рантайме
		h = core.shape[0]
		fill = core[h // 4: h - h // 4]
		meta[biome] = {"tex": f"res://assets/legion/procgen/road/{name}",
			"src": f"{map_id}/{road_id}#{idx}", "height_px": int(rgba.shape[0]),
			"period_px": int(rgba.shape[1]), "luma": round(float(luma(fill).mean()), 4)}
		mb, rb, ib, rows_b = PICKS_B[biome]
		pb = [s for r, i, s, _ in candidates(mb) if r == rb and i == ib]
		if pb:
			rgba_b = build(pb[0], rows_b)
			img_b = Image.fromarray((np.clip(rgba_b, 0, 1) * 255).astype(np.uint8), "RGBA")
			img_b = img_b.resize((img_b.width, rgba.shape[0]), Image.LANCZOS)
			name_b = f"road_{biome}_b.png"
			img_b.save(os.path.join(OUT, name_b))
			meta[biome].update({"tex_b": f"res://assets/legion/procgen/road/{name_b}",
				"src_b": f"{mb}/{rb}#{ib}", "period_b_px": int(img_b.width)})
		print(biome, meta[biome])
	with open(os.path.join(OUT, "road.json"), "w", encoding="utf-8") as f:
		json.dump(meta, f, ensure_ascii=False, indent=1)


if __name__ == "__main__":
	main()
