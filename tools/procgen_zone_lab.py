"""Статистика цвета по зонам нарисованных фонов кампании — образец для переноса цвета PgArt
(линия art3, D-0927-210: «обработка как предложил инстанс», прототип C:/AI/necro/assets/procgen/npr/).

Зачем: собранная карта должна быть «в той же краске», что фоны кампании. Перенос по Рейнхарду в
Lab (среднее и разброс) делается ПО ЗОНАМ — земля к земле, дорога к дороге, предметы к
препятствиям фона того же биома: общий перенос по кадру тянул бы землю к цвету дороги и наоборот
(прототип, шаг 1 «по зонам»). Игра считает статистику своей сборки сама (PgArt), а статистику
образца — берёт отсюда: офлайн, один раз.

Зоны — по геометрии JSON карты (как npr_lib.geo_masks): дорога — сердцевина полотна (≤ 0,75
полуширины от оси), препятствия — многоугольники rocks, сжатые на 7 px, земля — всё дальше 22 px
от края дороги, вне препятствий, стен, декора, воды и мостов, без полосы 40 px у края кадра.

Lab — своя формула (sRGB → линейный → XYZ D65 → Lab), та же, что в pg_post.gdshader и
PgArt._lab: OpenCV для float-картинок гамму не снимает, и числа разошлись бы с шейдером.

Запуск: python tools/procgen_zone_lab.py   → godot/assets/legion/procgen/road/zones_lab.json
"""
import json
import os

import cv2
import numpy as np

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "godot")
MAPS = os.path.join(ROOT, "assets", "legion", "maps")
OUT = os.path.join(ROOT, "assets", "legion", "procgen", "road", "zones_lab.json")
S = 1.5
ROAD_HALF = 23.0

# Биом процгена → фоны кампании этого биома. Биомы без своего фона — ближайший по палитре.
SOURCES = {
	"grave": ["fork", "bridge", "maze"],
	"swamp": ["swamp"],
	"ash": ["wasteland"],
	"office": ["archive", "gatehouse"],
	"site": ["boss"],
}
NEAREST = {"winter": "grave", "boiler": "site", "hell": "ash"}


def srgb_to_lab(rgb):
	c = np.where(rgb <= 0.04045, rgb / 12.92, ((rgb + 0.055) / 1.055) ** 2.4)
	m = np.array([[0.4124564, 0.3575761, 0.1804375],
		[0.2126729, 0.7151522, 0.0721750],
		[0.0193339, 0.1191920, 0.9503041]], np.float64)
	xyz = c @ m.T
	xyz /= np.array([0.95047, 1.0, 1.08883])
	f = np.where(xyz > 0.008856, np.cbrt(xyz), 7.787 * xyz + 16.0 / 116.0)
	L = 116.0 * f[..., 1] - 16.0
	a = 500.0 * (f[..., 0] - f[..., 1])
	b = 200.0 * (f[..., 1] - f[..., 2])
	return np.stack([L, a, b], -1)


def masks(m, W, H):
	cl = np.full((H, W), 255, np.uint8)
	for r in m.get("roads", []):
		pts = (np.array(r["path"], np.float64) * S).round().astype(np.int32)
		cv2.polylines(cl, [pts], False, 0, 1)
	d = cv2.distanceTransform(cl, cv2.DIST_L2, 5)
	R = ROAD_HALF * S
	road = d < R * 0.75
	near_road = d < R + 22
	obst = np.zeros((H, W), np.uint8)
	core = np.zeros((H, W), np.uint8)
	for poly in m.get("rocks", []):
		pts = (np.array(poly) * S).round().astype(np.int32)
		cv2.fillPoly(obst, [pts], 255)
		cv2.fillPoly(core, [pts], 255)
	for wl in m.get("walls", []):
		pts = (np.array(wl["path"]) * S).round().astype(np.int32)
		cv2.polylines(obst, [pts], False, 255, max(1, int(wl["w"] * S + 30)))
		cv2.polylines(core, [pts], False, 255, max(1, int(wl["w"] * S * 0.6)))
	for dc in m.get("decor", []):
		x, y = dc["pos"]
		cv2.circle(obst, (int(x * S), int((y - 15) * S)), 55, 255, -1)
	for key in ("water", "swamp", "bridges"):
		for poly in m.get(key, []):
			pts = (np.array(poly) * S).round().astype(np.int32)
			cv2.fillPoly(obst, [pts], 255)
	obst = cv2.dilate(obst, np.ones((25, 25), np.uint8)) > 0
	frame = np.zeros((H, W), bool)
	frame[40:H - 40, 40:W - 40] = True
	core = cv2.erode(core, np.ones((15, 15), np.uint8)) > 0
	return {"ground": (~near_road) & (~obst) & frame, "road": road & frame, "items": core & frame}


def main():
	out = {}
	for biome, maps in SOURCES.items():
		acc = {"ground": [], "road": [], "items": []}
		for mid in maps:
			m = json.load(open(os.path.join(MAPS, mid + ".json"), encoding="utf-8"))
			bgr = cv2.imread(os.path.join(MAPS, mid + "_bg.jpg"))
			rgb = bgr[..., ::-1].astype(np.float64) / 255.0
			H, W = rgb.shape[:2]
			lab = srgb_to_lab(rgb)
			for zone, mk in masks(m, W, H).items():
				acc[zone].append(lab[mk])
		out[biome] = {"src": maps}
		for zone, parts in acc.items():
			px = np.concatenate(parts) if parts else np.zeros((0, 3))
			if len(px) < 500:
				continue
			out[biome][zone] = {"mu": [round(float(v), 3) for v in px.mean(0)],
				"sd": [round(float(v), 3) for v in px.std(0)], "n": int(len(px))}
		print(biome, {z: out[biome][z]["mu"] for z in ("ground", "road", "items") if z in out[biome]})
	for biome, near in NEAREST.items():
		out[biome] = dict(out[near])
		out[biome]["nearest"] = near
	with open(OUT, "w", encoding="utf-8") as f:
		json.dump(out, f, ensure_ascii=False, indent=1)
	print("→", OUT)


if __name__ == "__main__":
	main()
