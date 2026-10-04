class_name PgLayout
extends RefCounted
##
## Раскладка карты по карточке (BOOK §2): скелет архетипа → отражение → изюминки → участки →
## рубежи бота → препятствия предметами каталога → декор, свет, фоновая жизнь → словарь карты
## формата кампании + поля процгена (STAGE2 §3). Удобство (BOOK §7) — по построению: вокруг
## дороги коридор без препятствий (≥ 100 px от оси), зазоры между препятствиями ≥ 64 px,
## участки в 70–140 px от дороги, рубежи там, где поперёк дороги ≥ 200 px свободно.
## Быстрая самопроверка (self_check) — движком: LegionTerrain по готовому словарю.
##
## Состояние раскладки — поля этого объекта; шаги живут в PgQuirks, PgPlace, PgProps.
##

## Коридор без препятствий вокруг оси дороги (У-2: пролёт ≥ 200 = по 100 с каждой стороны).
const ROAD_KEEP := 100.0
## Зазор между препятствиями и до края кадра (У-12: проходы ≥ 60 px).
const GAP := 64.0
## Свободный круг вокруг Котла (У-8).
const CAULDRON_FREE := 96.0
## Полоса дороги (половина MAP_ROAD_WIDTH 23) + кайма: стена сюда не заходит.
const WALL_ROAD := 31.0
## Наибольший перебор поля расстояний против точного (две полудиагонали клетки 16 px).
const FIELD_SLACK := 28.0
## Сколько вариантов фона на биом (ground/<биом>_NN.jpg, D-0927-72: ≈ 5 на биом).
const GROUND_VARIANTS := 5
const GROUND_DIR := "res://assets/legion/procgen/ground/"
const ROAD_NAMES: Array[String] = ["north", "south", "east", "west"]

## Замер шагов раскладки (мс по шагу, копится за процесс) — для зонда производительности.
static var prof: Dictionary = {}

var rng: RandomNumberGenerator
var card: Dictionary
var biome := ""
var field := PgField.new()
var cauldron := Vector2.ZERO
var roads: Array[Dictionary] = []
var water: Array[PackedVector2Array] = []
var bridges: Array[PackedVector2Array] = []
var swamp: Array[PackedVector2Array] = []
var walls: Array[Dictionary] = []
var solids: Array[Dictionary] = []
## Рамки всего твёрдого (препятствия, стены, вода): проверка зазоров.
var boxes: Array[Dictionary] = []
var props: Array[Dictionary] = []
var plots: Array[Dictionary] = []
var lines: Array[Dictionary] = []
var breaches: Array[Dictionary] = []
var sleepers: Array[Vector2] = []
var crypts: Array[Vector2] = []
var flights: Array[Dictionary] = []
var quirk_fx: Array[Dictionary] = []
var nodes: Dictionary = {}
## Точки, у которых нужен участок: {"pos", "r", "why"} (горло, трещина, мост).
var needs: Array[Dictionary] = []
var extra: Dictionary = {}
## Площадь твёрдого по рамкам и сколько рамок уже учтено (PgProps._cover).
var cover_area := 0.0
var cover_n := 0
var flipped := false
var fail := ""


## Словарь карты без волн и названий (их кладёт ProcGen) или {} с причиной в fail.
func build(p_card: Dictionary, p_rng: RandomNumberGenerator) -> Dictionary:
	card = p_card
	rng = p_rng
	biome = String(card["biome"])
	var t0 := Time.get_ticks_usec()
	# половина поля PvP (PgPvp): свои скелеты в рамке половины, дальше — тот же конвейер
	var sk := PgHalf.build(String(card["archetype"]), rng, card) if bool(card.get("half", false)) \
		else PgArch.build(String(card["archetype"]), rng, card)
	if sk.is_empty():
		fail = "скелет архетипа не сложился"
		return {}
	if not _take(sk):
		return {}
	field.build_roads(roads)
	_mark_structure()
	_prof("скелет", t0)
	var names := ["pre", "plots", "post", "lines", "corridors", "fill", "flight", "decor"]
	var steps: Array[Callable] = [PgQuirks.pre, PgPlace.plots, PgQuirks.post, PgPlace.lines,
		PgProps.corridors, PgProps.fill, PgQuirks.flight, PgProps.decor]
	for i in steps.size():
		t0 = Time.get_ticks_usec()
		steps[i].call(self)
		_prof(names[i], t0)
		if not fail.is_empty():
			return {}
	t0 = Time.get_ticks_usec()
	var out := _assemble()
	_prof("assemble", t0)
	return out


static func _prof(step: String, t0: int) -> void:
	prof[step] = float(prof.get(step, 0.0)) + (Time.get_ticks_usec() - t0) / 1000.0


# ── скелет → раскладка ───────────────────────────────────────────────────────

## Отражение (архетип 18) и переворот; переворот — косметика: если с ним ворота уходят под
## HUD, карта остаётся без него.
func _take(sk: Dictionary) -> bool:
	var mirror := bool(card.get("mirror", false))
	for flip: bool in ([true, false] if bool(card.get("flip", false)) else [false]):
		var t := _transformed(sk, mirror, flip)
		var why := PgHalf.check(t) if bool(card.get("half", false)) \
			else PgArch.check(t, String(card["archetype"]) == "spiral")
		if why.is_empty():
			flipped = flip
			_adopt(t)
			return true
	fail = "после отражения ворота или Котёл под HUD"
	return false


static func _transformed(sk: Dictionary, mirror: bool, flip: bool) -> Dictionary:
	var out := {"cauldron": _tp(sk["cauldron"], mirror, flip), "roads": [], "water": [],
		"bridges": [], "swamp": [], "walls": [], "nodes": {}}
	for road: Dictionary in sk["roads"]:
		out["roads"].append({"id": road["id"],
			"pts": PgGeom.map_points(road["pts"], mirror, flip)})
	for key: String in ["water", "bridges", "swamp"]:
		for poly: PackedVector2Array in sk[key]:
			out[key].append(PgGeom.map_points(poly, mirror, flip))
	for wl: Dictionary in sk["walls"]:
		var w := wl.duplicate()
		w["path"] = PgGeom.map_points(PackedVector2Array(wl["path"]), mirror, flip)
		out["walls"].append(w)
	for key: String in sk["nodes"]:
		var v: Variant = sk["nodes"][key]
		if v is Vector2:
			v = _tp(v, mirror, flip)
		elif v is Rect2:
			var r: Rect2 = v
			v = Rect2(_tp(r.position, mirror, flip), Vector2.ZERO).expand(
				_tp(r.end, mirror, flip))
		out["nodes"][key] = v
	return out


static func _tp(p: Vector2, mirror: bool, flip: bool) -> Vector2:
	var q := p
	if mirror:
		q = PgGeom.mirror_x(q)
	if flip:
		q = PgGeom.flip_y(q)
	return q


func _adopt(t: Dictionary) -> void:
	cauldron = t["cauldron"]
	for road: Dictionary in t["roads"]:
		roads.append({"id": road["id"], "pts": road["pts"], "skel": road["id"]})
	for key: String in ["water", "bridges", "swamp"]:
		for poly: PackedVector2Array in t[key]:
			(get(key) as Array).append(poly)
	for wl: Dictionary in t["walls"]:
		walls.append(wl)
	nodes = t["nodes"]
	_name_roads()


## Имена дорог — как у кампании (их знают превью и HUD: LegionCfg.ROAD_TITLES): одни ворота на
## стороне — имя стороны; несколько дорог с одной стороны — верхняя «north», нижняя «south».
func _name_roads() -> void:
	var by_side := {}
	for road: Dictionary in roads:
		var side := PgGeom.gate_side(road["pts"])
		if not by_side.has(side):
			by_side[side] = []
		by_side[side].append(road)
	var taken: Array[String] = []
	var multi: Array = []
	for side: String in ["north", "south", "west", "east"]:
		var list: Array = by_side.get(side, [])
		if list.size() == 1:
			list[0]["id"] = side
			taken.append(side)
		elif list.size() > 1:
			multi.append([side, list])
	for entry: Array in multi:
		var side: String = entry[0]
		var list: Array = entry[1]
		var by_y := side == "east" or side == "west"
		list.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return _mean(a["pts"], by_y) < _mean(b["pts"], by_y))
		for i in list.size():
			var prefs: Array = []
			if side == "east" or side == "west":
				prefs = ["north", side, "south"] if i == 0 else ["south", side, "north"]
				if i > 0 and i < list.size() - 1:
					prefs = [side, "north", "south"]
			else:
				prefs = ["west", side, "east"] if i == 0 else ["east", side, "west"]
			prefs.append_array(ROAD_NAMES)
			for n in prefs:
				if not taken.has(n):
					list[i]["id"] = n
					taken.append(n)
					break
	var tag := {}
	for key: String in ["short", "long", "express"]:
		if nodes.has(key):
			tag[int(nodes[key])] = key
	for i in roads.size():
		roads[i]["tag"] = String(tag.get(i, ""))


## Средний y ломаной (для east/west) — сравнение «верхняя/нижняя»; для верх/низ — средний x.
static func _mean(p: PackedVector2Array, by_y: bool) -> float:
	var s := 0.0
	for q in p:
		s += q.y if by_y else q.x
	return s / p.size()


## Подписи дорог для игрока (B-355, 30.09.2026): id дорог gen-карты — не стороны света
## (_name_roads зовёт две восточные дороги north/south), а превью волны показывало id как сторону.
## Здесь подпись — по фактической стороне ворот и положению дороги среди соседей по стороне.
## Карта без "procgen" (кампания, там ворота настоящие) → {}: вызывающий берёт подписи по id.
## Поле «Схватки» (procgen.pvp) → тоже {} (B-356): дороги сторон начинаются со шва посередине
## поля, а не за краем кадра, — «сторона ворот» там не определена; превью в «Схватке» скрыто.
## Ответ: id дороги → {"side": east|…, "gate": ключ ворот (у развилки — общий), "fork": дорога
## делит ворота с соседом, "branch": "верх."/"ниж."/… ("" — одна на стороне), "short": «вост.» /
## «вост. верх.», "title": «восточные ворота[, верхняя ветка|дорога]», "letter": буква стороны}.
static func road_labels(map: Dictionary) -> Dictionary:
	if not map.has("procgen") or Dictionary(map["procgen"]).has("pvp"):
		return {}
	var by_side := {}
	for r: Dictionary in map.get("roads", []):
		var pts := PackedVector2Array()
		for q: Array in r.get("path", []):
			pts.append(Vector2(float(q[0]), float(q[1])))
		if pts.size() < 2:
			continue
		var side := _side_of(pts[0])
		if not by_side.has(side):
			by_side[side] = []
		(by_side[side] as Array).append({"id": String(r.get("id", "")), "gate": PgGeom.gate_point(pts),
			"mean": _mean(pts, side == "east" or side == "west")})
	var out := {}
	for side: String in by_side:
		var list: Array = by_side[side]
		var ew := side == "east" or side == "west"
		# сверху вниз / слева направо — по воротам; у развилки ворота общие, решает сама дорога
		list.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			var ga: float = (a["gate"] as Vector2).y if ew else (a["gate"] as Vector2).x
			var gb: float = (b["gate"] as Vector2).y if ew else (b["gate"] as Vector2).x
			if absf(ga - gb) > LegionCfg.ROAD_SAME_GATE_PX:
				return ga < gb
			return float(a["mean"]) < float(b["mean"]))
		var words: Array[String] = LegionCfg.ROAD_BRANCH_EW if ew else LegionCfg.ROAD_BRANCH_NS
		for i in list.size():
			var e: Dictionary = list[i]
			var g: Vector2 = e["gate"]
			# ключ ворот — первая дорога списка с воротами рядом (у развилки он общий)
			var first := -1
			var fork := false
			for j in list.size():
				if (list[j]["gate"] as Vector2).distance_to(g) <= LegionCfg.ROAD_SAME_GATE_PX:
					if first < 0:
						first = j
					if j != i:
						fork = true
			var gate_key := "%s:%d" % [side, first]
			var branch := ""
			if list.size() == 2:
				branch = words[0] if i == 0 else words[2]
			elif list.size() == 3:
				branch = words[i]
			elif list.size() > 3:
				branch = "%d-я" % (i + 1)
			var short := String(LegionCfg.ROAD_SHORT.get(side, "ворота"))
			var title := String(LegionCfg.ROAD_TITLES.get(side, "ворота"))
			if branch != "":
				short += " " + branch
				title += ", %s %s" % [String(LegionCfg.ROAD_BRANCH_FULL.get(branch, branch)),
					"ветка" if fork else "дорога"]
			out[String(e["id"])] = {"side": side, "gate": gate_key, "fork": fork, "branch": branch,
				"short": short, "title": title,
				"letter": String(LegionCfg.ROAD_LETTER.get(side, "?"))}
	return out


## Сторона кадра 1280×720, за которой лежит первая точка дороги (ворота — на краю, путь начинается
## за ним). Как PgGeom.gate_side, но без статической рамки PgGeom (её переставляет PgPvp).
static func _side_of(p: Vector2) -> String:
	if p.x < 0.0:
		return "west"
	if p.x > PgGeom.WORLD.x:
		return "east"
	if p.y < 0.0:
		return "north"
	return "south"


## Стены, вода, мосты скелета — в растр; Котёл — в резерв.
func _mark_structure() -> void:
	for wl: Dictionary in walls:
		var item := PgCatalog.wall(String(wl["kind"]), biome)
		wl["item"] = String(item.get("id", "wall_stone"))
		if not wall_clear(PackedVector2Array(wl["path"]), float(wl["w"])):
			fail = "стена скелета заходит на дорогу"
		add_wall_geom(wl)
	for poly in water:
		field.mark_poly(poly, field.block)
		boxes.append({"box": PgGeom.poly_box(poly), "kind": "water"})
	for poly in bridges:
		_unblock(poly)
		field.mark_rect(PgGeom.poly_box(poly).grow(40.0), field.reserve)
	for poly in swamp:
		field.mark_poly(poly, field.reserve)
	# нейтральная полоса у стыка PvP (BOOK §12.2): ни участков, ни препятствий, ни ловушек —
	# там сходятся встречные перебежки
	if nodes.has("neutral"):
		field.mark_rect(nodes["neutral"], field.reserve)
	# круг у Котла в резерв не кладём: участок тыла стоит в 120–240 px, и его дверь/фундамент
	# задели бы круг; препятствия, стены и топь проверяют расстояние до Котла сами


func _unblock(poly: PackedVector2Array) -> void:
	var box := PgGeom.poly_box(poly)
	var a := field._cell(box.position + Vector2.ONE)
	var b := field._cell(box.end - Vector2.ONE)
	for y in range(a.y, b.y + 1):
		for x in range(a.x, b.x + 1):
			field.block[y * field.cols + x] = 0


## Стена: полоса в растр и рамка в список зазоров. Стены у нас вдоль осей (terrain.gd), так
## что рамка = контур.
func add_wall_geom(wl: Dictionary) -> void:
	var path: PackedVector2Array = PackedVector2Array(wl["path"])
	wl["path"] = path
	var half := float(wl["w"]) * 0.5
	for i in range(1, path.size()):
		var box := Rect2(path[i - 1], Vector2.ZERO).expand(path[i]).grow(half)
		field.mark_rect(box, field.block)
		boxes.append({"box": box, "kind": "wall"})


func add_wall(path: PackedVector2Array, w: float, kind: String, role: String) -> void:
	if not wall_clear(path, w):
		return
	var item := PgCatalog.wall(kind, biome)
	var wl := {"path": path, "w": w, "kind": kind, "role": role,
		"item": String(item.get("id", "wall_stone"))}
	walls.append(wl)
	add_wall_geom(wl)


## Стена не пересекает ось дороги и не заходит в её полосу (±23 px + кайма): ни одна точка
## осевой линии стены не ближе WALL_ROAD + половины толщины к оси любой дороги.
func wall_clear(path: PackedVector2Array, w: float) -> bool:
	for i in range(1, path.size()):
		var n := ceili(path[i - 1].distance_to(path[i]) / 8.0)
		for s in n + 1:
			var q := path[i - 1].lerp(path[i], float(s) / n)
			if Rect2(Vector2.ZERO, PgGeom.world).grow(8.0).has_point(q) \
					and exact_road_dist(q) < WALL_ROAD + w * 0.5:
				return false
		for r in roads:
			var p: PackedVector2Array = r["pts"]
			for j in range(1, p.size()):
				if Geometry2D.segment_intersects_segment(path[i - 1], path[i], p[j - 1], p[j]) \
						!= null:
					return false
	return true


## Поставить препятствие каталога: «след» → rocks, растр, рамка, props.
func add_solid(item: Dictionary, pos: Vector2, flip: bool) -> void:
	var foot := PgCatalog.foot_at(item, pos, flip)
	var box := PgGeom.poly_box(foot)
	solids.append({"item": String(item["id"]), "pos": pos, "flip": flip, "foot": foot,
		"box": box, "tags": item.get("tags", [])})
	field.mark_poly(foot, field.block)
	field.mark_rect(box, field.block)
	boxes.append({"box": box, "kind": "solid"})
	props.append({"item": String(item["id"]), "pos": pos, "flip": flip, "role": "obstacle"})


func add_prop(item: Dictionary, pos: Vector2, flip := false) -> void:
	if item.is_empty():
		return
	props.append({"item": String(item["id"]), "pos": pos, "flip": flip,
		"role": String(item.get("role", "decor"))})


## Не ближе keep к осям дорог. Поле даёт расстояние до ближайшей к клетке точки оси — оно не
## меньше точного и больше его не более чем на ~25 px (две полудиагонали клетки 16 px и шаг
## выборки оси; берём 28), так что точный счёт нужен только в этой полосе.
func road_at_least(p: Vector2, keep: float) -> bool:
	var f := field.road_dist(p)
	if f < keep:
		return false
	if f - FIELD_SLACK >= keep:
		return true
	return exact_road_dist(p) >= keep


## Точное расстояние до осей всех дорог (для окончательного решения; поле — для отсева).
func exact_road_dist(p: Vector2) -> float:
	var best := INF
	for road in roads:
		best = minf(best, PgGeom.dist_to_path(p, road["pts"]))
	return best


func road(id: String) -> Dictionary:
	for r in roads:
		if String(r["id"]) == id:
			return r
	return {}


## Годится ли рамка под твёрдое: зазор ≥ GAP до прочего твёрдого (или плотное касание
## препятствия — «куча»), до края кадра — либо заходит за край, либо ≥ GAP.
func box_fits(box: Rect2, cluster: bool) -> bool:
	var world := Rect2(Vector2.ZERO, PgGeom.world)
	for side in 4:
		var d: float = [box.position.x, box.position.y, world.end.x - box.end.x,
			world.end.y - box.end.y][side]
		if d > 0.0 and d < GAP:
			return false
	for b: Dictionary in boxes:
		var other: Rect2 = b["box"]
		if box.intersects(other):
			var inter := box.intersection(other)
			if not (cluster and String(b["kind"]) == "solid" and inter.size.x >= 16.0
					and inter.size.y >= 16.0):
				return false
		elif PgGeom.box_gap(box, other) < GAP:
			return false
	return true


# ── сборка словаря ───────────────────────────────────────────────────────────

func _assemble() -> Dictionary:
	var out := {}
	out["theme"] = PgTables.BIOME_THEME.get(biome, "grave")
	out["biome"] = biome
	out["cauldron"] = PgGeom.arr(cauldron)
	var rocks: Array = []
	for s in solids:
		rocks.append(PgGeom.arr_path(s["foot"]))
	out["rocks"] = rocks
	var wl_out: Array = []
	for wl in walls:
		# item — звено каталога для картинки (terrain.gd читает только path/w/kind)
		wl_out.append({"path": PgGeom.arr_path(wl["path"]), "w": wl["w"], "kind": wl["kind"],
			"item": wl["item"]})
	out["walls"] = wl_out
	var roads_out: Array = []
	for r in roads:
		roads_out.append({"id": r["id"], "path": PgGeom.arr_path(r["pts"])})
	out["roads"] = roads_out
	out["breaches"] = breaches.duplicate(true)
	out["bot_lines"] = lines.duplicate(true)
	out["water"] = _polys_out(water)
	out["bridges"] = _polys_out(bridges)
	out["swamp"] = _polys_out(swamp)
	var cr: Array = []
	for p in crypts:
		cr.append({"pos": PgGeom.arr(p)})
	out["crypts"] = cr
	var sl: Array = []
	for p in sleepers:
		sl.append({"pos": PgGeom.arr(p)})
	out["sleepers"] = sl
	out["flights"] = flights.duplicate(true)
	out["decor"] = PgProps.legacy_decor(self)
	var pl: Array = []
	for p in plots:
		pl.append({"id": p["id"], "pos": PgGeom.arr(p["pos"]), "bot_priority": p["bot_priority"],
			"serves_lines": p["serves_lines"], "preferred_kinds": p["preferred_kinds"]})
	out["plots"] = pl
	out["bg"] = ""
	out["ground"] = GROUND_DIR + "%s_%02d.jpg" % [biome, rng.randi_range(1, GROUND_VARIANTS)]
	# мосты — предметом каталога роли bridge поверх полигона bridges (vertical — дорога по y)
	var bridge_item := PgCatalog.pick(rng, biome, "bridge")
	for b in bridges:
		var box := PgGeom.poly_box(b)
		if not bridge_item.is_empty():
			props.append({"item": String(bridge_item["id"]), "pos": box.get_center(),
				"flip": false, "role": "bridge", "vertical": box.size.y > box.size.x})
	var pr: Array = []
	for p in props:
		var e := {"item": p["item"], "pos": PgGeom.arr(p["pos"]), "flip": p["flip"]}
		if p.has("vertical"):
			e["vertical"] = p["vertical"]
		pr.append(e)
	out["props"] = pr
	out["ambient"] = PgProps.ambient(self)
	out["edges"] = _edges()
	out["cauldron_hp"] = 200
	var n_roads := roads.size()
	out["start_army"] = 18 + 2 * n_roads + rng.randi_range(0, 2) * 2
	out["army_cap"] = 100 + 10 * (n_roads - 1) + (10 if int(card["k"]) >= 6 else 0)
	var pg := {"flip": flipped, "layout": extra.duplicate(true)}
	if extra.has("throat"):
		pg["throat"] = extra["throat"]
	out["procgen"] = pg
	return out


static func _polys_out(src: Array[PackedVector2Array]) -> Array:
	var out: Array = []
	for poly in src:
		out.append(PgGeom.arr_path(poly))
	return out


## Края с проходами (BOOK §12.2): в одиночной карте — края с воротами; сосед всегда null.
func _edges() -> Array:
	var by_side := {}
	for r in roads:
		var side := PgGeom.gate_side(r["pts"])
		var g := PgGeom.gate_point(r["pts"])
		var v := int(g.y) if side == "west" or side == "east" else int(g.x)
		if not by_side.has(side):
			by_side[side] = []
		var span := [v - 48, v + 48]
		if not (by_side[side] as Array).has(span):
			by_side[side].append(span)
	var out: Array = []
	for side: String in ["west", "north", "east", "south"]:
		if by_side.has(side):
			out.append({"id": "edge_" + side, "side": side, "spans": by_side[side],
				"neighbor": null})
	return out


# ── самопроверка движком ─────────────────────────────────────────────────────

## Быстрая самопроверка того, что генератор обещает по построению и чего фильтр годности не
## меряет так же: скелет дорог (ворота на свободных отрезках края, извилистость, повороты,
## дороги не пересекаются, кроме слияния, каждая кончается в Котле), 3–8 участков, рубежи
## есть. Проходимость и достижимость по сетке движка (LegionTerrain) меряет PgFilter («Тест»):
## вторая сборка сетки здесь стоила ~15 мс на карту без новой информации.
static func self_check(map: Dictionary) -> Array[String]:
	var out: Array[String] = []
	var c := Vector2(map["cauldron"][0], map["cauldron"][1])
	var sk := {"cauldron": c, "roads": []}
	for r: Dictionary in map["roads"]:
		var p := PackedVector2Array()
		for q: Array in r["path"]:
			p.append(Vector2(q[0], q[1]))
		sk["roads"].append({"id": r["id"], "pts": p})
	var card: Dictionary = map.get("procgen", {}).get("card", {})
	var why := PgArch.check(sk, String(card.get("archetype", "")) == "spiral")
	if not why.is_empty():
		out.append("скелет: " + why)
	var plots: Array = map["plots"]
	if plots.size() < 3 or plots.size() > 8:
		out.append("участков %d" % plots.size())
	for pl: Dictionary in plots:
		if PgGeom.in_hud(Vector2(pl["pos"][0], pl["pos"][1]), 8.0):
			out.append("%s под HUD" % pl["id"])
	if (map["bot_lines"] as Array).is_empty():
		out.append("нет рубежей бота")
	return out
