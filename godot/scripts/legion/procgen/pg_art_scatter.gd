class_name PgArtScatter
extends RefCounted
## Россыпь мелких украшений по свободной земле и площадка под Котлом (линия art3, D-0927-210,
## Игорь: «чуть скучновато карты смотрятся… рандомно расставлять… под котёл можно место
## вставлять… без коллизий»).
##
## Только картинка: предметы role "scatter" и "cauldron_base" (catalog.json, pass D, без следа)
## не входят ни в коллизию, ни в словарь карты — раскладка, фильтр годности и детерминизм карты
## (ProcGen.digest) их не видят. Расстановка детерминирована от id карты (свой ГСЧ, RNG мира не
## тратится): одна и та же карта — одна и та же россыпь.
##
## Как: центры кучек — синий шум (случайные броски с минимальным расстоянием между центрами),
## в кучке 2–5 предметов рядом, с малым поворотом, отражением и разбросом масштаба. Свободная
## земля — не на дороге (±ROAD_CLEAR от оси), не на участках (r PLOT_CLEAR), не на воде, топи и
## мостах, не ближе OBST_CLEAR к препятствиям и стенам, не под Котлом и его площадкой, не у края.
##
## Поле «Схватки» (P5b, B-CX-B-06): кучки выбираются на половине стороны 0 и отражаются
## (x' = W − x) — стороны одинаковы; площадка — под Котлом каждой стороны; точка свободна, только
## если свободно и её зеркало (зоны Котлов обеих сторон исключены).

const ROAD_CLEAR := 30.0
const PLOT_CLEAR := 40.0
const OBST_CLEAR := 12.0
const EDGE_CLEAR := 28.0
const PROP_CLEAR := 18.0 ## до якоря другого предмета (надгробие, дерево, свеча)
const CAULDRON_CLEAR := 70.0
## Кучек на карту по биому: ориентир — плотность мелких деталей на фонах кампании (там ≈ 40–70
## пятнышек-деталей на кадр). Больше — «каша», меньше — пусто.
const CLUSTERS := {"grave": 17, "swamp": 15, "ash": 15, "site": 17, "office": 12, "winter": 15,
	"boiler": 13, "hell": 13}
const CLUSTERS_DEFAULT := 14
const CLUSTER_GAP := 95.0 ## минимум между центрами кучек (синий шум)
const CLUSTER_R := 26.0
const PER_CLUSTER := Vector2i(2, 5)
const ITEM_GAP := 16.0
const TRIES := 60
const ITEM_TRIES := 10
const SCALE := Vector2(0.55, 0.8)
const TURN := 0.35 ## рад: плоские предметы лежат на земле — малый поворот не ломает ракурс
## Декор на краю дороги (build_edge, road-1003): виды по окончанию id, шаг вдоль дороги, ширина
## пучка, центр относительно края ленты (− внутрь, + наружу) и чистая середина полотна (доля
## полуширины от оси, куда пучок не заходит ни краем).
## Кирпичи и уголь стройки/котельной пробовали (кадр boss 03.10): мелкие пёстрые пятнышки на
## кромке читались сором — у этих биомов кромка без декора.
const EDGE_KINDS := ["_grass", "_leaves", "_pebbles", "_moss", "_contracts"]
const EDGE_STEP := Vector2(60.0, 140.0)
const EDGE_W := Vector2(17.0, 25.0)
const EDGE_OUT := Vector2(-3.0, 4.0)
const EDGE_CORE := 0.5
const EDGE_GAP := 34.0
const EDGE_ACCENT_CLEAR := 60.0
## Площадка под Котёл: ширина в мире (Котёл — ≈ 90 px, площадка чуть шире).
const BASE_W := 116.0
const BASE_LIFT := 6.0 ## центр площадки чуть ниже точки Котла — туда падает его «дно»


## Площадка и россыпь под parent. Возвращает {scatter, cauldron_base} — счётчики для отчёта.
static func build(parent: Node2D, map: Dictionary) -> Dictionary:
	var biome := String(map.get("biome", map.get("theme", "grave")))
	var out := {"scatter": 0, "cauldron_base": 0}
	var c := _cauldron(map)
	var base := _pick_base(biome)
	var tex_base := PgArtSprites._tex(base, "tex") if not base.is_empty() else null
	var cps := cauldrons(map)
	for ci in cps.size():
		if tex_base == null:
			break
		var it := base.duplicate()
		it["w"] = BASE_W
		var sp := PgArtSprites.item_sprite(it, tex_base, cps[ci] + Vector2(0, BASE_LIFT), false)
		sp.name = "CauldronBase" if ci == 0 else "CauldronBase%d" % (ci + 1)
		parent.add_child(sp)
		out["cauldron_base"] = int(out["cauldron_base"]) + 1
	var pool := PgCatalog.find(biome, "scatter")
	if pool.is_empty():
		return out
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(String(map.get("id", "")) + "|scatter")
	var free := Free.new(map, c)
	# Composed accents have their own open breathing room.
	var accents := PgArtLife.positions(map)
	var mw := LegionTerrain.mirror_width(map)
	var area := area_size(map)
	var want := area_count(map, int(CLUSTERS.get(biome, CLUSTERS_DEFAULT)))
	var centers := PackedVector2Array()
	var taken := PackedVector2Array() ## центры и (поле PvP) их зеркала
	for t in want * TRIES:
		if centers.size() >= want:
			break
		var p := Vector2(rng.randf_range(EDGE_CLEAR, area.x - EDGE_CLEAR),
			rng.randf_range(EDGE_CLEAR, area.y - EDGE_CLEAR))
		var near := false
		for q in taken:
			if q.distance_to(p) < CLUSTER_GAP:
				near = true
				break
		for accent in accents:
			if accent.distance_to(p) < 90.0:
				near = true
		if mw > 0.0 and (mirror(p, mw).distance_to(p) < CLUSTER_GAP
				or not free.ok(mirror(p, mw))):
			near = true
		if near or not free.ok(p):
			continue
		centers.append(p)
		taken.append(p)
		if mw > 0.0:
			taken.append(mirror(p, mw))
	var placed := PackedVector2Array()
	for ci in centers.size():
		var center := centers[ci]
		# в кучке — предметы одного-двух видов: так кучка читается «местом», а не лотереей
		var kind_a: Dictionary = pool[rng.randi_range(0, pool.size() - 1)]
		var kind_b: Dictionary = pool[rng.randi_range(0, pool.size() - 1)]
		var n := rng.randi_range(PER_CLUSTER.x, PER_CLUSTER.y)
		for k in n:
			var item: Dictionary = (kind_a if rng.randf() < 0.65 else kind_b).duplicate()
			item["w"] = float(item.get("w", 48.0)) * rng.randf_range(SCALE.x, SCALE.y)
			var radius := float(item["w"]) * 0.65
			for t in ITEM_TRIES:
				var p := center if k == 0 else center + Vector2.from_angle(rng.randf() * TAU) \
					* rng.randf_range(ITEM_GAP, CLUSTER_R + ITEM_GAP)
				var crowd := false
				for q in placed:
					if q.distance_to(p) < ITEM_GAP:
						crowd = true
						break
				if mw > 0.0 and not free.ok(mirror(p, mw), radius):
					crowd = true
				if crowd or not free.ok(p, radius):
					continue
				var tex := PgArtSprites._tex(item, "tex")
				if tex == null:
					break
				var flip := rng.randf() < 0.5
				var sp := PgArtSprites.item_sprite(item, tex, p, flip)
				sp.rotation = rng.randf_range(-TURN, TURN)
				parent.add_child(sp)
				placed.append(p)
				out["scatter"] = int(out["scatter"]) + 1
				if mw > 0.0:
					# зеркальный близнец на стороне 1: отражены место, разворот и поворот
					var twin := PgArtSprites.item_sprite(item, tex, mirror(p, mw), not flip)
					twin.rotation = -sp.rotation
					parent.add_child(twin)
					placed.append(mirror(p, mw))
					out["scatter"] = int(out["scatter"]) + 1
				break
	return out


## Мелкий плоский декор, заходящий на край дороги (road-1003, Игорь 03.10: дорога «прямо
## выделяется» — на рисованных фонах трава и камешки лежат на кромке, у сборки кромка была
## голой). Только виды без коллизии из той же россыпи (трава, листья, камешки, мох, бумаги) и
## только край: центр пучка — у края ленты (EDGE_OUT от края), пучок не заходит ни одним краем
## глубже EDGE_CORE полуширины от оси ЛЮБОЙ дороги — середина полотна, по которой читается путь
## врага, остаётся чистой. Те же запреты, что у россыпи (участки, предметы, вода, топь, мосты,
## стены, Котёл, край кадра), кроме самой дороги; поле PvP — сторона 0 и зеркало. Свой ГСЧ от
## id карты, словарь карты не меняется. half_w — видимая полуширина ленты (мира px).
## Возвращает число пучков.
static func build_edge(parent: Node2D, map: Dictionary, half_w: float) -> int:
	var biome := String(map.get("biome", map.get("theme", "grave")))
	var pool: Array = []
	for it: Dictionary in PgCatalog.find(biome, "scatter"):
		for suffix: String in EDGE_KINDS:
			if String(it.get("id", "")).ends_with(suffix):
				pool.append(it)
	if pool.is_empty() or half_w <= 0.0:
		return 0
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(String(map.get("id", "")) + "|road-edge")
	var free := Free.new(map, _cauldron(map))
	# оси — скруглённые, как рисует PgArtRoad: на коленах полотно срезает угол ломаной
	var axes: Array[PackedVector2Array] = []
	for raw in free.roads:
		axes.append(PgArtRoad.rounded(raw))
	free.roads.clear()
	var accents := PgArtLife.positions(map)
	var mw := LegionTerrain.mirror_width(map)
	var placed := PackedVector2Array()
	var n := 0
	for line in axes:
		var next := rng.randf_range(EDGE_STEP.x, EDGE_STEP.y) * 0.5
		for i in line.size() - 1:
			var a := line[i]
			var b := line[i + 1]
			var seg := a.distance_to(b)
			if seg < 0.01:
				continue
			var at := next
			while at < seg:
				var dir := (b - a) / seg
				var side := 1.0 if rng.randf() < 0.5 else -1.0
				var w := rng.randf_range(EDGE_W.x, EDGE_W.y)
				var item: Dictionary = pool[rng.randi_range(0, pool.size() - 1)]
				var q := a + dir * at \
					+ dir.orthogonal() * side * (half_w + rng.randf_range(EDGE_OUT.x, EDGE_OUT.y))
				var flip := rng.randf() < 0.5
				var turn := rng.randf_range(-TURN, TURN)
				at += rng.randf_range(EDGE_STEP.x, EDGE_STEP.y)
				if not _edge_ok(q, w * 0.5, half_w, axes, free, accents, placed, mw):
					continue
				var tex := PgArtSprites._tex(item, "tex")
				if tex == null:
					continue
				var it := item.duplicate()
				it["w"] = w
				var sp := PgArtSprites.item_sprite(it, tex, q, flip)
				sp.rotation = turn
				parent.add_child(sp)
				placed.append(q)
				n += 1
				if mw > 0.0:
					var twin := PgArtSprites.item_sprite(it, tex, mirror(q, mw), not flip)
					twin.rotation = -turn
					parent.add_child(twin)
					placed.append(mirror(q, mw))
					n += 1
			next = at - seg
	return n


static func _edge_ok(q: Vector2, r: float, half_w: float, axes: Array, free: Free,
		accents: PackedVector2Array, placed: PackedVector2Array, mw: float) -> bool:
	if mw > 0.0 and q.x > mw * 0.5 - r:
		return false
	for path: PackedVector2Array in axes:
		var dist := axis_distance(q, path)
		if dist - r < half_w * EDGE_CORE or dist < half_w - absf(EDGE_OUT.x) - 0.01:
			return false
	for p in placed:
		if p.distance_to(q) < EDGE_GAP:
			return false
	for accent in accents:
		if accent.distance_to(q) < EDGE_ACCENT_CLEAR:
			return false
	return free.ok(q, r) and (mw <= 0.0 or free.ok(mirror(q, mw), r))


## Расстояние от точки до оси дороги (ломаная, мира px).
static func axis_distance(p: Vector2, path: PackedVector2Array) -> float:
	var best := INF
	for i in path.size() - 1:
		best = minf(best, p.distance_to(Geometry2D.get_closest_point_to_segment(p, path[i],
			path[i + 1])))
	return best


## Котлы карты: у поля «Схватки» — каждой стороны (sides[].cauldron, иначе cauldrons[].pos),
## у одиночной — один map.cauldron.
static func cauldrons(map: Dictionary) -> PackedVector2Array:
	var out := PackedVector2Array()
	for key: String in ["sides", "cauldrons"]:
		for entry: Variant in map.get(key, []):
			if not entry is Dictionary:
				continue
			var c: Variant = (entry as Dictionary).get("cauldron" if key == "sides" else "pos")
			if c is Array and (c as Array).size() >= 2:
				out.append(Vector2(float(c[0]), float(c[1])))
		if not out.is_empty():
			return out
	var one := _cauldron(map)
	if one.x > -9000.0:
		out.append(one)
	return out


## Где выбирать россыпь и композиции: одиночка — весь кадр, поле PvP — половина стороны 0
## (выбранное отражается на сторону 1).
static func area_size(map: Dictionary) -> Vector2:
	var mw := LegionTerrain.mirror_width(map)
	var world := LegionTerrain.map_size(map)
	return Vector2(mw * 0.5, world.y) if mw > 0.0 else world


## Сколько штук на area_size при плотности кадра 1280×720 (одиночка — n как есть).
static func area_count(map: Dictionary, n: int) -> int:
	var a := area_size(map)
	if a == LegionCfg.WORLD_SIZE:
		return n
	var k := a.x * a.y / (LegionCfg.WORLD_SIZE.x * LegionCfg.WORLD_SIZE.y)
	return maxi(1, roundi(float(n) * k))


## Зеркало точки поля PvP (x' = W − x).
static func mirror(p: Vector2, mirror_w: float) -> Vector2:
	return Vector2(mirror_w - p.x, p.y)


static func _cauldron(map: Dictionary) -> Vector2:
	var c: Variant = map.get("cauldron", null)
	if c is Array and (c as Array).size() >= 2:
		return Vector2(float(c[0]), float(c[1]))
	return Vector2(-9999, -9999)


static func _pick_base(biome: String) -> Dictionary:
	var found := PgCatalog.find(biome, "cauldron_base")
	if found.is_empty():
		found = PgCatalog.find("grave", "cauldron_base")
	return {} if found.is_empty() else found[0]


## Свободная земля для россыпи (докстринг класса).
class Free:
	var roads: Array[PackedVector2Array] = []
	var plots := PackedVector2Array()
	var props := PackedVector2Array()
	var cauldron := Vector2(-9999, -9999)
	## Все Котлы карты (поле «Схватки» — обеих сторон), cauldron среди них.
	var cauldron_all := PackedVector2Array()
	var world := LegionCfg.WORLD_SIZE
	var blocks: Array[PackedVector2Array] = [] ## вода, топь, мосты, препятствия (с отступом)
	var walls: Array[Dictionary] = []

	func _init(map: Dictionary, c: Vector2) -> void:
		cauldron = c
		cauldron_all = PgArtScatter.cauldrons(map)
		if not cauldron_all.has(c):
			cauldron_all.append(c)
		world = LegionTerrain.map_size(map)
		for road: Dictionary in map.get("roads", []):
			roads.append(PgArtRoad._points(road.get("path", [])))
		for plot: Dictionary in map.get("plots", []):
			plots.append(Vector2(float(plot.pos[0]), float(plot.pos[1])))
		for key: String in ["props", "decor"]:
			for prop: Dictionary in map.get(key, []):
				props.append(Vector2(float(prop.pos[0]), float(prop.pos[1])))
		for key: String in ["water", "swamp", "bridges"]:
			for raw: Array in map.get(key, []):
				blocks.append(PgArtRoad._points(raw))
		for raw: Array in map.get("rocks", []):
			var poly := PgArtRoad._points(raw)
			if poly.size() >= 3:
				for grown in Geometry2D.offset_polygon(poly, PgArtScatter.OBST_CLEAR):
					blocks.append(grown)
		for w: Dictionary in map.get("walls", []):
			walls.append({"path": PgArtRoad._points(w.get("path", [])),
				"r": float(w.get("w", 24.0)) * 0.5 + PgArtScatter.OBST_CLEAR})

	func ok(p: Vector2, radius: float = 0.0) -> bool:
		# Смещение внутри кучки тоже проверяется: свободный центр не гарантирует,
		# что крайний предмет останется в кадре.
		var margin := maxf(PgArtScatter.EDGE_CLEAR, radius)
		var inside := Rect2(Vector2.ONE * margin,
			world - Vector2.ONE * margin * 2.0).has_point(p)
		for pl in plots:
			if p.distance_to(pl) < PgArtScatter.PLOT_CLEAR + radius:
				return false
		for q in props:
			if p.distance_to(q) < PgArtScatter.PROP_CLEAR + radius:
				return false
		for path in roads:
			if _near(p, path, PgArtScatter.ROAD_CLEAR + radius):
				return false
		for w in walls:
			if _near(p, w["path"], float(w["r"]) + radius):
				return false
		for poly in blocks:
			if poly.size() >= 3 and (Geometry2D.is_point_in_polygon(p, poly)
					or _near(p, poly + PackedVector2Array([poly[0]]), radius)):
				return false
		return inside and not _near_cauldron(p, radius)

	func _near_cauldron(p: Vector2, radius: float) -> bool:
		for cp in cauldron_all:
			if p.distance_to(cp) < PgArtScatter.CAULDRON_CLEAR + radius:
				return true
		return false

	func _near(p: Vector2, path: PackedVector2Array, r: float) -> bool:
		for i in path.size() - 1:
			if p.distance_to(Geometry2D.get_closest_point_to_segment(p, path[i], path[i + 1])) < r:
				return true
		return false
