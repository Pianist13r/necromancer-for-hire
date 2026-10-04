class_name PgProps
extends RefCounted
##
## Предметы карты: препятствия (коллизия из «следа» предмета), коридоры лабиринта, декор по
## правилам соседства BOOK §6.6, «клей» у подножий, свет, фоновая жизнь из точек эффектов
## предметов (§8.5 п.1) и точки эффектов логики уровня (quirk_fx, §8.5 п.2 — рисует линия
## terrain, здесь только данные).
##

## Доля кадра под препятствиями (мягкое правило §7: проходимо 65–92 %).
const COVER := Vector2(0.10, 0.17)
const COVER_WALLED := Vector2(0.05, 0.09)
const EDGE_MASSES := Vector2i(2, 4)
const FILL_TRIES := 420
## Акценты у колен: мелкие камни во внутреннем углу поворота ближе коридора, но ≥ 56 px от
## оси (≥ 45, BOOK «отступы препятствий от оси»).
const ACCENT_KEEP := 56.0
const ACCENTS := Vector2i(1, 3)
## Полуширина «следа» по размеру (доля w каталога) — для выбора размера по месту.
const SIZE_HALF := {"S": 18.0, "M": 40.0, "L": 70.0, "XL": 110.0}
const LANTERN_GAP := 150.0
## Декор не ближе к оси дороги (надгробие ≥ 30 от края = 53, дерево ≥ 40 от края = 63).
const DECOR_KEEP := 54.0
const TREE_KEEP := 66.0
const CORRIDOR_OFF := Vector2i(116, 132)
## Доли размеров при расстановке: меньше, но крупнее (замечание координатора 27.09).
const SIZE_WEIGHT := {"XL": 0.7, "L": 1.2, "M": 0.6}
## Сколько соседей подсаживается к крупному предмету (куча).
const CLUSTER := Vector2i(1, 3)
## Шаг параллельных стеллажей: толщина 54 + проход ≥ 64 (У-12).
const SHELF_PITCH := 128.0
## Полутолщина самой толстой стены квартала (стеллаж 54) — запас к краю кадра.
const QUARTER_WALL := 28.0


## Доля кадра под твёрдым (по рамкам): считается по новым рамкам с прошлого вызова.
static func _cover(lay: PgLayout) -> float:
	while lay.cover_n < lay.boxes.size():
		var b: Dictionary = lay.boxes[lay.cover_n]
		lay.cover_n += 1
		if String(b["kind"]) != "water":
			var box: Rect2 = b["box"]
			lay.cover_area += box.intersection(Rect2(Vector2.ZERO, PgGeom.world)).get_area()
	return lay.cover_area / (PgGeom.world.x * PgGeom.world.y)


## Поставить препятствие, если оно не лезет в коридор дороги, резерв, Котёл и зазоры.
static func try_solid(lay: PgLayout, item: Dictionary, pos: Vector2, flip: bool,
		accent: bool) -> bool:
	if item.is_empty():
		return false
	var foot := PgCatalog.foot_at(item, pos, flip)
	var box := PgGeom.poly_box(foot)
	var keep := ACCENT_KEEP if accent else PgLayout.ROAD_KEEP
	if lay.field.poly_road_dist(foot) < keep:
		return false
	if box.grow(PgLayout.CAULDRON_FREE).has_point(lay.cauldron):
		return false
	if lay.field.any_rect(box, lay.field.reserve) or not lay.box_fits(box, not accent):
		return false
	for i in foot.size():
		var a := foot[i]
		var b := foot[(i + 1) % foot.size()]
		if not lay.road_at_least(a, keep) or not lay.road_at_least(a.lerp(b, 0.5), keep):
			return false
	for poly in lay.swamp:
		if not Geometry2D.intersect_polygons(foot, poly).is_empty():
			return false
	# куча: рамки пересекаются — значит, и сами «следы» должны сомкнуться, иначе между ними
	# остаётся щель в несколько px (У-12, verifier 27.09: проходы 3–15 px в кучах)
	for s in lay.solids:
		var sb: Rect2 = s["box"]
		if sb.intersects(box) and Geometry2D.intersect_polygons(foot, s["foot"]).is_empty():
			return false
	lay.add_solid(item, pos, flip)
	return true


static func fill(lay: PgLayout) -> void:
	var walled := lay.nodes.has("corridors") or String(lay.card["archetype"]) == "shelves"
	var span := COVER_WALLED if walled else COVER
	var target := lay.rng.randf_range(span.x, span.y)
	_quarters(lay)
	_edge_masses(lay)
	var cells := PackedVector2Array(PgRng.shuffled(lay.rng,
		Array(lay.field.open_cells(PgLayout.ROAD_KEEP + 30.0, INF))))
	var tries := 0
	for c in cells:
		if tries >= FILL_TRIES or _cover(lay) >= target:
			break
		tries += 1
		var room := lay.field.road_dist(c) - PgLayout.ROAD_KEEP
		var sizes: Array[String] = []
		for s: String in ["XL", "L", "M"]:
			if float(SIZE_HALF[s]) <= room and not PgCatalog.find(lay.biome, "obstacle",
					s).is_empty():
				sizes.append(s)
		if sizes.is_empty():
			continue
		# меньше, но крупнее: читаемые массы, как скалы кампании; мелочь — только кучей рядом
		var w: Array = []
		for s in sizes:
			w.append(SIZE_WEIGHT[s])
		var size := sizes[PgRng.pick_weighted(lay.rng, w)]
		var item := PgCatalog.pick(lay.rng, lay.biome, "obstacle", size)
		var jitter := Vector2(lay.rng.randi_range(-8, 8), lay.rng.randi_range(-8, 8))
		if try_solid(lay, item, (c + jitter).round(), lay.rng.randf() < 0.5, false):
			_cluster(lay, lay.solids[-1])
	_accents(lay)


## Куча вокруг крупного предмета: 1–3 соседа впритык (плотное касание разрешено box_fits).
static func _cluster(lay: PgLayout, s: Dictionary) -> void:
	var box: Rect2 = s["box"]
	var half := maxf(box.size.x, box.size.y) * 0.5
	for i in lay.rng.randi_range(CLUSTER.x, CLUSTER.y):
		var size := "M" if lay.rng.randf() < 0.5 else "S"
		var item := PgCatalog.pick(lay.rng, lay.biome, "obstacle", size)
		if item.is_empty():
			continue
		var dir := Vector2.RIGHT.rotated(lay.rng.randi_range(0, 7) * PI / 4.0)
		var pos: Vector2 = (s["pos"] as Vector2) + dir * (half * 0.8 + float(item["w"]) * 0.3)
		try_solid(lay, item, pos.round(), lay.rng.randf() < 0.5, false)


## «Кварталы» по биому (§6.6): кладбищенский участок — ограда П с проёмом и ряды надгробий;
## архив — параллельные стеллажи с проходами ≥ 64 px.
static func _quarters(lay: PgLayout) -> void:
	match lay.biome:
		"grave":
			for i in lay.rng.randi_range(1, 2):
				_graveyard(lay)
		"office":
			for i in lay.rng.randi_range(1, 2):
				_shelf_rows(lay)


## Свободный прямоугольник size (все края ≥ 110 от осей дорог, без резерва и твёрдого).
static func _free_rect(lay: PgLayout, size: Vector2) -> Rect2:
	var cells := lay.field.open_cells(PgLayout.ROAD_KEEP + 10.0 + maxf(size.x, size.y) * 0.5,
		INF)
	for t in mini(cells.size(), 40):
		var c := cells[lay.rng.randi_range(0, cells.size() - 1)]
		var r := Rect2(PgGeom.snap(c - size * 0.5), size)
		# квартал целиком в кадре и не ближе GAP к краю (с толщиной стен): щель ограды у края —
		# узкий проход У-12, а ряд за кадром — не квартал (verifier 27.09: ограда на x −80)
		var inner := Rect2(Vector2.ZERO, PgGeom.world).grow(-(PgLayout.GAP + QUARTER_WALL))
		if not inner.encloses(r) or lay.field.any_rect(r.grow(8.0), lay.field.block) \
				or lay.field.any_rect(r, lay.field.reserve) or not lay.box_fits(r, false) \
				or r.grow(PgLayout.CAULDRON_FREE).has_point(lay.cauldron) or PgGeom.in_hud(
				r.get_center(), 40.0):
			continue
		var ok := true
		for p in [r.position, r.end, Vector2(r.end.x, r.position.y),
				Vector2(r.position.x, r.end.y), r.get_center()]:
			ok = ok and lay.road_at_least(p, PgLayout.ROAD_KEEP + 10.0)
		if ok:
			return r
	return Rect2()


static func _graveyard(lay: PgLayout) -> void:
	var size := Vector2(PgRng.grid(lay.rng, 176, 224), PgRng.grid(lay.rng, 128, 160))
	var r := _free_rect(lay, size)
	if r.size == Vector2.ZERO:
		return
	# проём снизу — к зрителю (вид 3/4), ограда замыкает участок с трёх сторон
	lay.add_wall(PackedVector2Array([Vector2(r.position.x, r.end.y), r.position,
		Vector2(r.end.x, r.position.y), r.end]), 18.0, "fence", "graveyard")
	for row in 2:
		var y := r.position.y + 44.0 + row * 44.0
		var x := r.position.x + 32.0
		while x <= r.end.x - 28.0:
			lay.add_prop(PgCatalog.pick(lay.rng, lay.biome, "decor", "", "tomb"), Vector2(x, y))
			x += 32.0
	lay.field.mark_rect(r, lay.field.reserve)


static func _shelf_rows(lay: PgLayout) -> void:
	var n := lay.rng.randi_range(2, 3)
	var length := float(PgRng.grid(lay.rng, 160, 224))
	var size := Vector2(length, (n - 1) * SHELF_PITCH + 54.0)
	var r := _free_rect(lay, size)
	if r.size == Vector2.ZERO:
		return
	for i in n:
		var y := r.position.y + 27.0 + i * SHELF_PITCH
		lay.add_wall(PackedVector2Array([Vector2(r.position.x, y), Vector2(r.end.x, y)]), 54.0,
			"shelf", "archive")
	lay.field.mark_rect(r, lay.field.reserve)


## Крупные массы у краёв кадра (как скалы «Пустыря» по углам): рамка карты.
static func _edge_masses(lay: PgLayout) -> void:
	var want := lay.rng.randi_range(EDGE_MASSES.x, EDGE_MASSES.y)
	var got := 0
	for t in 60:
		if got >= want:
			return
		var item := PgCatalog.pick(lay.rng, lay.biome, "obstacle", "XL")
		if item.is_empty() or lay.rng.randf() < 0.4:
			item = PgCatalog.pick(lay.rng, lay.biome, "obstacle", "L")
		if item.is_empty():
			return
		var half := float(item.get("w", 100)) * 0.46
		var side := lay.rng.randi_range(0, 3)
		var pos := Vector2.ZERO
		var w := PgGeom.world
		match side:
			0:
				pos = Vector2(lay.rng.randf_range(80, w.x - 80.0), lay.rng.randf_range(-half * 0.3, 8))
			1:
				pos = Vector2(lay.rng.randf_range(80, w.x - 80.0), w.y - lay.rng.randf_range(
					-half * 0.3, 8))
			2:
				pos = Vector2(lay.rng.randf_range(-half * 0.4, 8), lay.rng.randf_range(80,
					w.y - 80.0))
			_:
				pos = Vector2(w.x - lay.rng.randf_range(-half * 0.4, 8), lay.rng.randf_range(80,
					w.y - 80.0))
		if try_solid(lay, item, pos.round(), lay.rng.randf() < 0.5, false):
			got += 1


## Мелкие камни во внутренних углах поворотов — дорога «обнимает» препятствие.
static func _accents(lay: PgLayout) -> void:
	var want := lay.rng.randi_range(ACCENTS.x, ACCENTS.y)
	var got := 0
	var knees: Array = []
	for r in lay.roads:
		var p: PackedVector2Array = r["pts"]
		for i in range(1, p.size() - 1):
			if PgGeom.turn_at(p, i) > 1.0 and Rect2(Vector2(64, 64), PgGeom.world - Vector2(
					128, 128)).has_point(p[i]) and p[i].distance_to(lay.cauldron) > 220.0:
				var bis := ((p[i - 1] - p[i]).normalized() + (p[i + 1] - p[i]).normalized())
				knees.append([p[i], bis.normalized()])
	for k: Array in PgRng.shuffled(lay.rng, knees):
		if got >= want:
			return
		var pos: Vector2 = (k[0] as Vector2) + (k[1] as Vector2) * lay.rng.randf_range(100, 124)
		var size := "S" if lay.rng.randf() < 0.5 else "M"
		if try_solid(lay, PgCatalog.pick(lay.rng, lay.biome, "obstacle", size), pos.round(),
				lay.rng.randf() < 0.5, true):
			got += 1


# ── коридоры лабиринта ───────────────────────────────────────────────────────

## Стены вдоль колен дороги по обе стороны (на 116–132 px от оси — пролёт ≥ 200 сохраняется),
## с разрывами у участков, рубежей и чужих дорог.
static func corridors(lay: PgLayout) -> void:
	if not lay.nodes.has("corridors"):
		return
	var kind := "stone"
	var w := 24.0
	if lay.biome == "office":
		kind = "shelf"
		w = 56.0
	elif lay.biome == "site":
		kind = "fence"
		w = 18.0
	for r in lay.roads:
		var p: PackedVector2Array = r["pts"]
		for i in range(1, p.size() - 2):
			var a := p[i]
			var b := p[i + 1]
			if a.distance_to(b) < 192.0 or (a.x != b.x and a.y != b.y):
				continue
			var t := (b - a).normalized()
			for s: float in [1.0, -1.0]:
				var off := float(PgRng.grid(lay.rng, CORRIDOR_OFF.x, CORRIDOR_OFF.y, 4)) + w * 0.5 \
					- 12.0
				_corridor_run(lay, a + t * 56.0 + t.orthogonal() * s * off,
					b - t * 56.0 + t.orthogonal() * s * off, off, w, kind)


static func _corridor_run(lay: PgLayout, a: Vector2, b: Vector2, off: float, w: float,
		kind: String) -> void:
	var n := ceili(a.distance_to(b) / 16.0)
	var run: Array[Vector2] = []
	for s in n + 1:
		var q := a.lerp(b, float(s) / n).round()
		var ok := lay.exact_road_dist(q) >= off - 6.0 and not lay.field.at(q, lay.field.reserve) \
			and not lay.field.at(q, lay.field.block) \
			and Rect2(Vector2.ZERO, PgGeom.world).has_point(q) \
			and q.distance_to(lay.cauldron) > PgLayout.CAULDRON_FREE + w
		if ok:
			run.append(q)
		if (not ok or s == n) and run.size() >= 7:
			var path := PackedVector2Array([run[0], run[-1]])
			var box := Rect2(run[0], Vector2.ZERO).expand(run[-1]).grow(w * 0.5)
			if lay.box_fits(box, false):
				lay.add_wall(path, w, kind, "corridor")
		if not ok:
			run.clear()


# ── декор ────────────────────────────────────────────────────────────────────

static func _decor_ok(lay: PgLayout, q: Vector2, keep: float) -> bool:
	if not Rect2(Vector2(8, 8), PgGeom.world - Vector2(16, 16)).has_point(q):
		return false
	if lay.field.at(q, lay.field.block) or not lay.road_at_least(q, keep):
		return false
	for p in lay.plots:
		if q.distance_to(p["pos"]) < 44.0:
			return false
	return true


static func decor(lay: PgLayout) -> void:
	_lights(lay)
	match lay.biome:
		"grave":
			_trees(lay, 3, 5)
			_scatter(lay, "decor", "glue", 3)
		"ash":
			_trees(lay, 1, 3)
			_scatter(lay, "decor", "crack", 5)
			_scatter(lay, "decor", "glue", 3)
		"swamp":
			_trees(lay, 3, 6)
		"office":
			_near_tag(lay, ["furniture", "paper", "crate"], "paper", 0.8)
		"site":
			_near_tag(lay, ["junk", "crate", "wood"], "glue", 0.7)
	_water_edges(lay)
	_glue(lay)


## Предмет роли role с тегом tag в биоме (по тегам, не по id — библиотека подменит записи).
static func _item(lay: PgLayout, role: String, tag: String) -> Dictionary:
	return PgCatalog.pick(lay.rng, lay.biome, role, "", tag)


## Свечи у участков и во внутренних углах поворотов, фонари у ворот, мостов и горла —
## свет ведёт глаз по пути врага (§6.6).
static func _lights(lay: PgLayout) -> void:
	for p in lay.plots:
		var pos: Vector2 = p["pos"]
		for t in 6:
			var q := (pos + Vector2(lay.rng.randf_range(-58, 58),
				lay.rng.randf_range(-40, 30))).round()
			if absf(q.x - pos.x) > 34.0 and _decor_ok(lay, q, DECOR_KEEP):
				lay.add_prop(_item(lay, "light", "candle"), q)
				break
	for r in lay.roads:
		var path: PackedVector2Array = r["pts"]
		for i in range(1, path.size() - 1):
			if PgGeom.turn_at(path, i) < 1.0 or lay.rng.randf() > 0.45:
				continue
			var bis := (path[i - 1] - path[i]).normalized() + (path[i + 1] - path[i]).normalized()
			var q := (path[i] + bis.normalized() * 84.0).round()
			if _decor_ok(lay, q, DECOR_KEEP):
				lay.add_prop(_item(lay, "light", "candle"), q)
	var spots: Array[Vector2] = []
	for r in lay.roads:
		var path: PackedVector2Array = r["pts"]
		var g := PgGeom.gate_point(path)
		var d := (path[1] - path[0]).normalized()
		spots.append(g + d * 72.0 + d.orthogonal() * 60.0)
	for b in lay.bridges:
		var box := PgGeom.poly_box(b)
		var along := Vector2(1, 0) if box.size.x >= box.size.y else Vector2(0, 1)
		var across := along.orthogonal()
		for s: float in [1.0, -1.0]:
			spots.append(box.get_center() + along * s * (box.size.dot(along) * 0.5 + 20.0)
				+ across * 64.0)
	if lay.extra.has("throat"):
		var tp := Vector2(lay.extra["throat"]["pos"][0], lay.extra["throat"]["pos"][1])
		spots.append(tp + Vector2(70, -70))
		spots.append(tp + Vector2(-70, 70))
	var placed: Array[Vector2] = []
	for q0 in spots:
		var q := q0.round()
		var far := true
		for p in placed:
			far = far and p.distance_to(q) >= LANTERN_GAP
		if far and _decor_ok(lay, q, DECOR_KEEP):
			lay.add_prop(_item(lay, "light", "lamp"), q)
			placed.append(q)


static func _open_spot(lay: PgLayout, keep: float) -> Vector2:
	var cells := lay.field.open_cells(keep, INF)
	if cells.is_empty():
		return Vector2.INF
	for t in 12:
		var c := cells[lay.rng.randi_range(0, cells.size() - 1)]
		var q := (c + Vector2(lay.rng.randi_range(-6, 6), lay.rng.randi_range(-6, 6))).round()
		if _decor_ok(lay, q, keep):
			return q
	return Vector2.INF


## Деревья — у препятствий, не над участками, ≥ 40 px от края дороги (§6.6).
static func _trees(lay: PgLayout, lo: int, hi: int) -> void:
	var placed: Array[Vector2] = []
	for i in lay.rng.randi_range(lo, hi):
		var q := _open_spot(lay, TREE_KEEP)
		if q == Vector2.INF:
			continue
		var far := true
		for p in placed:
			far = far and p.distance_to(q) > 120.0
		for p in lay.plots:
			far = far and q.distance_to(p["pos"]) > 70.0
		if far:
			lay.add_prop(_item(lay, "decor", "tree"), q, lay.rng.randf() < 0.5)
			placed.append(q)


static func _scatter(lay: PgLayout, role: String, tag: String, n: int) -> void:
	for i in n:
		var q := _open_spot(lay, DECOR_KEEP + 8.0)
		if q != Vector2.INF:
			lay.add_prop(_item(lay, role, tag), q, lay.rng.randf() < 0.5)


## Декор у подножия препятствий с тегом (бумаги у стеллажей и столов, мусор у куч).
static func _near_tag(lay: PgLayout, tags: Array, tag: String, chance: float) -> void:
	for s in lay.solids:
		var hit := false
		for t: String in tags:
			hit = hit or (s["tags"] as Array).has(t)
		if not hit or lay.rng.randf() > chance:
			continue
		var box: Rect2 = s["box"]
		var q := Vector2(box.get_center().x + lay.rng.randf_range(-box.size.x * 0.4,
			box.size.x * 0.4), box.end.y + 12.0).round()
		if _decor_ok(lay, q, DECOR_KEEP - 10.0):
			lay.add_prop(_item(lay, "decor", tag), q, lay.rng.randf() < 0.5)
	for wl in lay.walls:
		if String(wl["kind"]) == "shelf" and lay.rng.randf() < chance:
			var p: PackedVector2Array = wl["path"]
			var q := (p[-1] + Vector2(18, 18)).round()
			if _decor_ok(lay, q, DECOR_KEEP - 10.0):
				lay.add_prop(_item(lay, "decor", tag), q)


## Камыш по кромке воды и топи, кувшинки на воде (§6.6).
static func _water_edges(lay: PgLayout) -> void:
	var polys: Array[PackedVector2Array] = []
	polys.append_array(lay.water)
	if lay.biome != "office":
		polys.append_array(lay.swamp)
	for poly in polys:
		for i in range(0, poly.size(), 2):
			var q := poly[i].round()
			if Rect2(Vector2(8, 8), PgGeom.world - Vector2(16, 16)).has_point(q) \
					and lay.road_at_least(q, 40.0) and lay.rng.randf() < 0.5:
				var on_bridge := false
				for b in lay.bridges:
					on_bridge = on_bridge or PgGeom.poly_box(b).grow(24.0).has_point(q)
				if not on_bridge:
					lay.add_prop(_item(lay, "decor", "reed"), q, lay.rng.randf() < 0.5)
	for poly in lay.water:
		var box := PgGeom.poly_box(poly).intersection(Rect2(Vector2.ZERO, PgGeom.world))
		for t in 6:
			var q := Vector2(lay.rng.randf_range(box.position.x, box.end.x),
				lay.rng.randf_range(box.position.y, box.end.y)).round()
			if Geometry2D.is_point_in_polygon(q, poly) and lay.rng.randf() < 0.5:
				lay.add_prop(_item(lay, "decor", "water_only"), q)


## «Клей» у подножия каждого препятствия (§8.3): 2–4 кустика/камешка/бумажки по биому.
static func _glue(lay: PgLayout) -> void:
	var pool := PgCatalog.find(lay.biome, "decor", "", "glue")
	if pool.is_empty():
		return
	for s in lay.solids:
		var box: Rect2 = s["box"]
		for i in lay.rng.randi_range(2, 4):
			var q := Vector2(lay.rng.randf_range(box.position.x, box.end.x),
				box.end.y + lay.rng.randf_range(-6, 10)).round()
			if Rect2(Vector2.ZERO, PgGeom.world).has_point(q) and lay.road_at_least(q, 34.0):
				lay.add_prop(pool[lay.rng.randi_range(0, pool.size() - 1)], q,
					lay.rng.randf() < 0.5)


## Поле decor для запасного рисунка движка (terrain_view: tree / grave / candle) — по тегам
## предмета.
static func legacy_decor(lay: PgLayout) -> Array:
	var out: Array = []
	for p in lay.props:
		var tags: Array = PgCatalog.by_id(String(p["item"])).get("tags", [])
		var kind := ""
		if tags.has("tree"):
			kind = "tree"
		elif tags.has("tomb"):
			kind = "grave"
		elif tags.has("candle"):
			kind = "candle"
		if kind != "":
			out.append({"kind": kind, "pos": PgGeom.arr(p["pos"])})
	return out


# ── фоновая жизнь ────────────────────────────────────────────────────────────

## Схема assets/legion/ambient/<карта>.json (glows, embers, fog, wisps, water) из точек
## эффектов поставленных предметов + фон биома + quirk_fx.
static func ambient(lay: PgLayout) -> Dictionary:
	var glows: Array = []
	var embers: Array = []
	var fog: Array = []
	var wisps: Array = []
	for p in lay.props:
		var item := PgCatalog.by_id(String(p["item"]))
		for fx: Dictionary in PgCatalog.fx_at(item, p["pos"], bool(p["flip"])):
			var at: Vector2 = fx["pos"]
			var r := float(fx.get("r", 30))
			match String(fx["kind"]):
				"glow":
					glows.append({"pos": PgGeom.arr(at), "r": int(r), "color": fx["color"],
						"flicker": 0.25})
				"ember":
					embers.append({"rect": [int(at.x - r * 0.5), int(at.y - r * 0.25), int(r),
						int(r * 0.5)], "rate": 1.2, "color": fx["color"]})
				"wisp":
					wisps.append({"rect": [int(at.x - r * 0.6), int(at.y - r * 0.4), int(r * 1.2),
						int(r * 0.8)], "count": 1, "color": fx["color"]})
				"fog", "smoke":
					fog.append({"rect": [int(at.x - r), int(at.y - r * 0.5), int(r * 2), int(r)],
						"count": 1, "color": fx["color"], "alpha": 0.08, "drift": [4, 0]})
	var water: Array = []
	for poly in lay.water:
		water.append({"poly": PgGeom.arr_path(poly), "rate": 3.0, "color": "e0f6ff"})
	for poly in lay.swamp:
		water.append({"poly": PgGeom.arr_path(poly), "rate": 1.2, "color": "d0ffe8"})
		if lay.biome == "swamp" or lay.biome == "grave":
			var box := PgGeom.poly_box(poly)
			wisps.append({"rect": [int(box.position.x), int(box.position.y), int(box.size.x),
				int(box.size.y)], "count": 1, "color": "7fffd8"})
	if lay.biome == "swamp":
		for i in 3:
			fog.append({"rect": [lay.rng.randi_range(0, int(PgGeom.world.x) - 380),
				lay.rng.randi_range(80, int(PgGeom.world.y) - 200), 380, 200],
				"count": 3, "color": "c8f0dc", "alpha": 0.07, "drift": [4, 0]})
	elif lay.biome == "office":
		fog.append({"rect": [lay.rng.randi_range(200, int(PgGeom.world.x) - 480), 60, 280,
			int(PgGeom.world.y) - 200], "count": 2,
			"color": "e8dcc4", "alpha": 0.05, "drift": [2, 3]})
	return {"glows": glows, "embers": embers, "fog": fog, "wisps": wisps, "water": water,
		"quirk_fx": lay.quirk_fx.duplicate(true)}
