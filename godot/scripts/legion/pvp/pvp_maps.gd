class_name PvpMaps
extends RefCounted
##
## Карты «Схватки», сделанные руками (линия L1). Настоящие половины строит процген (линия L2,
## BOOK §12); здесь — симметричная заготовка для тестов, серий «бот против бота» и замера
## процессора. Задана ПОЛОВИНА стороны 0 (x ∈ [0, 800]); поле 1600×900 собирается зеркалом
## x' = W − x, поэтому симметрия — по построению, а не по аккуратности рук.
##
## Формат — словарь карты кампании (docs/procgen/STAGE2.md §3) плюс поля PvP:
##   size: [W, H] — размер мира (одиночка — 1280×720 по умолчанию);
##   sides: [{cauldron: [x, y]}, …] — Котлы сторон по порядку; cauldron — Котёл стороны 0;
##   plots[].side — чья площадка; pvp: {seam_x, passages: [[y0, y1], …]} — стык половин и
##   проходы в нём (боту — куда вести наступление).
##

const DUEL := "pvp:duel"
const HALF_W := 800.0
## Стык: сплошные глыбы поперёк поля с двумя проходами по 170 px (сверху и снизу от центра).
const SEAM_BLOCKS := [[-20.0, 160.0], [330.0, 570.0], [740.0, 920.0]]
const SEAM_HALF := 30.0
const PASSAGES := [[160.0, 330.0], [570.0, 740.0]]
## Половина стороны 0.
const CAULDRON := [170.0, 450.0]
const ROADS := [
	{"id": "top", "path": [[360, -40], [360, 120], [250, 260], [200, 400], [185, 420]]},
	{"id": "bot", "path": [[360, 940], [360, 780], [250, 640], [200, 500], [185, 480]]},
]
## Валуны половины: центр и радиус (многоугольник — восьмиугольник).
const BOULDERS := [[480.0, 250.0, 42.0], [480.0, 650.0, 42.0], [640.0, 450.0, 36.0]]
const PLOTS := [
	{"id": "a", "pos": [300, 320], "bot_priority": 3, "preferred_kinds": ["laborer"]},
	{"id": "b", "pos": [300, 580], "bot_priority": 2, "preferred_kinds": ["laborer"]},
	{"id": "c", "pos": [400, 450], "bot_priority": 1, "preferred_kinds": ["laborer"]},
	{"id": "d", "pos": [470, 380], "bot_priority": 0, "preferred_kinds": ["laborer"]},
	{"id": "e", "pos": [470, 520], "bot_priority": 0, "preferred_kinds": ["laborer"]},
]
const START_ARMY := 60
const WAVES := 15
## Зомби первой волны 10 (было 6) и прирост от волны к волне 3 (было 2): к 5-й минуте волна
## ломает оборону, пока армия в наступлении, и матч кончается Котлом (серии P3, BALANCE.md 30.09).
const WAVE_ZOMBIES := 10
const WAVE_ZOMBIES_STEP := 3
const BEETLES_FROM := 2
const SIGNERS_FROM := 4


## Карта по id («pvp:duel»); чужой id — {}.
static func load_map(id: String) -> Dictionary:
	if id == DUEL:
		return duel()
	return {}


## Геометрия L2 хранит Котлы в cauldrons, игровой мир L1 — в sides.
## Копия обязательна: ProcGen кэширует словарь, адаптация не должна менять его digest.
## Дороги и владение площадками остаются сгенерированными и симметричными; волны — waves() на
## дорогах PvE сторон.
static func adapt_generated(raw: Dictionary) -> Dictionary:
	var cauldrons: Array = raw.get("cauldrons", [])
	if cauldrons.size() < 2:
		return raw
	var out := raw.duplicate(true)
	var sides: Array = []
	for c: Dictionary in cauldrons:
		sides.append({"cauldron": (c["pos"] as Array).duplicate()})
	out["sides"] = sides
	out["cauldron_hp"] = PvpRules.CAULDRON_HP
	out["start_army"] = START_ARMY
	var pg: Dictionary = out.get("procgen", {}).get("pvp", {})
	out["pvp"] = {"seam_x": float(out["size"][0]) / cauldrons.size(),
		"passages": pg.get("spans", []).duplicate(true)}
	# Волны — расписание «Дуэли» на дорогах PvE поля, а не PgWaves одиночного объекта: тех 5, до
	# 204-й секунды, по 2–4 проверяющих, а DESIGN §2.6 — волны весь матч, одни у всех полей (B-291)
	var pve: Array = []
	for side in cauldrons.size():
		pve.append([])
	for r: Dictionary in out.get("roads", []):
		var side := int(r.get("side", -1))
		if String(r.get("kind", "")) == "pve" and side >= 0 and side < pve.size():
			(pve[side] as Array).append(String(r["id"]))
	if not (pve[0] as Array).is_empty():
		out["waves"] = waves(pve)
	return out


## Поле двух сторон с обменом: сторона 0 получает Котёл и площадки стороны 1 и наоборот
## (`--dev pvp_swap=1`). Серия со сменой сторон отделяет перекос «номер стороны» (порядок
## обновления, ГСЧ) от перекоса «половина поля» (геометрия): P3, docs/dev/BALANCE.md 30.09.
static func swap_sides(m: Dictionary) -> Dictionary:
	var out := m.duplicate(true)
	var sides: Array = out.get("sides", [])
	if sides.size() != 2:
		return out
	sides.reverse()
	out["cauldron"] = (sides[0]["cauldron"] as Array).duplicate()
	for p: Dictionary in out.get("plots", []):
		if p.has("side"):
			p["side"] = 1 - int(p["side"])
	# B-365: группы волн — сначала дороги новой стороны 0, как у стороны 0 без смены: порядок
	# рождения (и обхода врагов в шаге) идёт за стороной, а не за левой половиной, и бой со
	# сменой — точное отражение боя без неё
	var ends := {}
	for r: Dictionary in out.get("roads", []):
		var path: Array = r.get("path", [])
		if not path.is_empty():
			var e: Array = path[path.size() - 1]
			ends[String(r.get("id", ""))] = Vector2(float(e[0]), float(e[1]))
	var c0: Array = sides[0]["cauldron"]
	var c1: Array = sides[1]["cauldron"]
	var k0 := Vector2(float(c0[0]), float(c0[1]))
	var k1 := Vector2(float(c1[0]), float(c1[1]))
	for wave: Dictionary in out.get("waves", []):
		var mine: Array = []
		var theirs: Array = []
		for g: Dictionary in wave.get("groups", []):
			var at: Vector2 = ends.get(String(g.get("road", "")), k0)
			(mine if at.distance_squared_to(k0) <= at.distance_squared_to(k1) else theirs).append(g)
		wave["groups"] = mine + theirs
	return out


## Симметричная заготовка «Дуэль»: половина стороны 0 и её зеркало.
static func duel() -> Dictionary:
	var w := PvpRules.FIELD.x
	var rocks: Array = []
	for b: Array in SEAM_BLOCKS:
		var x0 := HALF_W - SEAM_HALF
		var x1 := HALF_W + SEAM_HALF
		rocks.append([[x0, b[0]], [x1, b[0]], [x1, b[1]], [x0, b[1]]])
	var roads: Array = []
	var plots: Array = []
	for side in 2:
		for b: Array in BOULDERS:
			rocks.append(_octagon(_mx(Vector2(b[0], b[1]), side, w), float(b[2])))
		for r: Dictionary in ROADS:
			var path: Array = []
			for p: Array in r["path"]:
				var q := _mx(Vector2(p[0], p[1]), side, w)
				path.append([q.x, q.y])
			roads.append({"id": "s%d_%s" % [side, r["id"]], "path": path})
		for p: Dictionary in PLOTS:
			var q := _mx(Vector2(p["pos"][0], p["pos"][1]), side, w)
			var e := p.duplicate(true)
			e["id"] = "s%d_%s" % [side, p["id"]]
			e["pos"] = [q.x, q.y]
			e["side"] = side
			plots.append(e)
	var c1 := _mx(Vector2(CAULDRON[0], CAULDRON[1]), 1, w)
	return {
		"id": DUEL, "title": "Схватка: Дуэль", "theme": "grave", "bg": "",
		"size": [PvpRules.FIELD.x, PvpRules.FIELD.y],
		"cauldron": CAULDRON.duplicate(), "cauldron_hp": PvpRules.CAULDRON_HP,
		"sides": [{"cauldron": CAULDRON.duplicate()}, {"cauldron": [c1.x, c1.y]}],
		"start_army": START_ARMY,
		"rocks": rocks, "walls": [], "roads": roads, "breaches": [], "bot_lines": [],
		"plots": plots, "waves": waves(), "water": [], "bridges": [], "swamp": [],
		"crypts": [], "sleepers": [], "decor": [],
		"pvp": {"seam_x": HALF_W, "passages": PASSAGES.duplicate(true)},
	}


## Одинаковые обеим сторонам слабые волны по часам (DESIGN §2.6): первая на FIRST_WAVE, дальше
## каждые WAVE_EVERY; ворота — сверху и снизу по очереди, у каждой половины свои. pause после
## отбоя = WAVE_EVERY: отбитая раньше волна не ускоряет следующую (часы общие для обеих сторон).
## roads — дороги волн по сторонам ([[id…], [id…]]); волна k идёт по дороге k % n стороны.
## Пусто — дороги «Дуэли» (s<сторона>_top / _bot).
static func waves(roads: Array = []) -> Array:
	if roads.is_empty():
		roads = [["s0_top", "s0_bot"], ["s1_top", "s1_bot"]]
	var out: Array = []
	for k in WAVES:
		var groups: Array = []
		for side in roads.size():
			var own: Array = roads[side]
			var road := String(own[k % own.size()])
			groups.append({"road": road, "type": "zombie",
				"count": WAVE_ZOMBIES + WAVE_ZOMBIES_STEP * k, "interval": 0.6, "delay": 0.0})
			if k >= BEETLES_FROM:
				groups.append({"road": road, "type": "beetle", "count": 2 + floori(k / 2.0),
					"interval": 0.9, "delay": 6.0})
			if k >= SIGNERS_FROM:
				groups.append({"road": road, "type": "signer", "count": 1 + floori((k - SIGNERS_FROM) / 4.0),
					"interval": 1.5, "delay": 10.0})
		out.append({"pause": PvpRules.FIRST_WAVE if k == 0 else PvpRules.WAVE_EVERY,
			"next_in": PvpRules.WAVE_EVERY, "groups": groups})
	return out


## Точка половины стороны 0 → точка стороны side (зеркало по x у нечётной).
static func _mx(p: Vector2, side: int, w: float) -> Vector2:
	return Vector2(w - p.x, p.y) if side % 2 == 1 else p


static func _octagon(c: Vector2, r: float) -> Array:
	var out: Array = []
	for i in 8:
		var p := c + Vector2.from_angle(TAU * float(i) / 8.0 + PI / 8.0) * r
		out.append([p.x, p.y])
	return out
