class_name PgArtFill
extends RefCounted
## Крупные декоративные группы в больших пустотах поля (gen-art-polish, 03.10.2026, D-1003-06).
## Игорь: «чтобы красивый был в остальных режимах» — у нарисованных фонов композицию держат
## крупные формы (ряды надгробий, кучи хлама, кусты), у сборки между дорогой и россыпью оставались
## голые куски земли. Здесь: после россыпи и жизни карты найти точки, где ближайший объект
## (спрайт, дорога, вода/топь, препятствие, Котёл) дальше EMPTY_R, и поставить в них группу —
## ряд 3–5 вертикальных предметов своего биома (надгробия/конусы/кресла) и россыпь плоских
## пятен вокруг. Всё из библиотеки (catalog.json, role decor/scatter), без коллизии, словарь карты
## и ProcGen.digest не трогает; свой ГСЧ от id карты; поле PvP — сторона 0 и зеркало.

## Расстояние до ближайшего объекта, дальше которого земля считается «пустой» (мира px).
const EMPTY_R := 50.0
## Пустота = доля клеток кадра с таким зазором (метрика приёмки).
const CELL := 24.0
const ROAD_HALF := 36.0
const COUNT := 7 ## групп на кадр 1280×720
const GROUP_R := 62.0 ## радиус группы — столько же отнимаем от зазора вокруг неё
const TRIES_GAP := 70.0
## Роды групп по биому: вертикальные предметы ОДНОГО рода (ups) и плоское пятно ОДНОГО вида (flat),
## близкое к земле по цвету. Группа берёт один род целиком: надгробия не мешаются ни с кристаллами,
## ни с шестернями россыпи. Фиолетовые кристаллические плиты пустыря в группы не входят.
## Мебель конторы светлее тёмного пола: чуть темнее и теплее, чтобы стояла в полу (B-399 п.3).
const OFFICE_UP := Color(0.76, 0.72, 0.68)
const KINDS := {
	"grave": [
		{"ups": ["grave_tomb_01", "grave_tomb_02"], "flat": "grave_dec_grass"},
		{"ups": ["grave_cross_01"], "flat": "grave_dec_leaves"},
		{"ups": ["grave_bench_01"], "flat": "grave_dec_pebbles"},
	],
	"ash": [
		{"ups": ["grave_tomb_01", "grave_tomb_02"], "flat": "ash_dec_pebbles"},
		{"ups": ["grave_cross_01"], "flat": "ash_dec_grass"},
		{"ups": ["ash_slab_01"], "flat": "ash_bones_01"},
	],
	"swamp": [
		{"ups": ["swamp_reeds_s_01"], "flat": "swamp_dec_grass"},
		{"ups": ["swamp_dec_log"], "flat": "swamp_dec_moss"},
	],
	"winter": [
		{"ups": ["winter_tomb_01", "winter_tomb_02"], "flat": "winter_dec_grass"},
		{"ups": ["winter_cross_01"], "flat": "winter_dec_pebbles"},
	],
	"site": [
		# опилки site_dec_sawdust нарисованы кольцом-шиной и читались белым кольцом (B-399)
		{"ups": ["site_cones_01"], "flat": "site_dec_nails"},
		{"ups": ["site_rebar_01"], "flat": "site_dec_bricks"},
		{"ups": ["site_barrow_01"], "flat": "site_dec_cement"},
	],
	"office": [
		{"ups": ["office_chair_01"], "flat": "office_papers_01", "tone": Color(0.7, 0.67, 0.64),
			"up_tone": OFFICE_UP},
		{"ups": ["office_plant_01"], "flat": "office_papers_01", "tone": Color(0.7, 0.67, 0.64),
			"up_tone": OFFICE_UP},
		{"ups": ["office_coatrack_01"], "flat": "office_papers_01", "tone": Color(0.7, 0.67, 0.64),
			"up_tone": OFFICE_UP},
	],
}
## Выключатель для замеров «было»: тест и скрипт приёмки гасят группы.
static var enabled := true


## Группы под parent; sources — узлы-родители уже построенных спрайтов (для зазоров).
## Возвращает число поставленных предметов.
static func build(parent: Node2D, map: Dictionary, sources: Array,
		extra := PackedVector2Array()) -> int:
	if not enabled:
		return 0
	var biome := String(map.get("biome", map.get("theme", "grave")))
	var kinds: Array[Dictionary] = []
	for k: Dictionary in KINDS.get(biome, []):
		var ups: Array[Dictionary] = []
		for id: String in k["ups"]:
			var it := PgCatalog.by_id(id)
			if not it.is_empty() and PgArtSprites._tex(it, "tex") != null:
				ups.append(it)
		var flat := PgCatalog.by_id(String(k["flat"]))
		if not ups.is_empty() and not flat.is_empty() and PgArtSprites._tex(flat, "tex") != null:
			kinds.append({"ups": ups, "flat": flat, "id": "%s|%s" % [k["flat"], ",".join(k["ups"])],
				"tone": k.get("tone", Color.WHITE),
				"up_tone": k.get("up_tone", Color.WHITE)})
	if kinds.is_empty():
		return 0
	var field := Field.new(map, sources)
	for q in extra:
		field.add(q, 40.0)
	var mw := LegionTerrain.mirror_width(map)
	var area := PgArtScatter.area_size(map)
	var want := PgArtScatter.area_count(map, COUNT)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(String(map.get("id", "")) + "|fill")
	var free := PgArtScatter.Free.new(map, PgArtScatter._cauldron(map))
	var entries: Array[Dictionary] = []
	var groups := 0
	for g in want:
		var best := Vector2.ZERO
		var best_d := EMPTY_R
		var y := PgArtScatter.EDGE_CLEAR + GROUP_R * 0.5
		while y < area.y - PgArtScatter.EDGE_CLEAR - GROUP_R * 0.5:
			var x := PgArtScatter.EDGE_CLEAR + GROUP_R * 0.5
			while x < area.x - PgArtScatter.EDGE_CLEAR - GROUP_R * 0.5:
				var p := Vector2(x, y)
				x += CELL
				var d := field.clearance(p)
				if d > best_d and free.ok(p, GROUP_R * 0.7) \
						and (mw <= 0.0 or (free.ok(PgArtScatter.mirror(p, mw), GROUP_R * 0.7)
						and field.clearance(PgArtScatter.mirror(p, mw)) > EMPTY_R)):
					best = p
					best_d = d
			y += CELL
		if best_d <= EMPTY_R:
			break
		groups += 1
		_group(entries, kinds[rng.randi_range(0, kinds.size() - 1)], best, rng, mw, free, groups)
		field.add(best, GROUP_R)
		if mw > 0.0:
			field.add(PgArtScatter.mirror(best, mw), GROUP_R)
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["y"] < b["y"])
	for e: Dictionary in entries:
		parent.add_child(e["node"])
	return entries.size()


static func _group(entries: Array[Dictionary], kind: Dictionary, c: Vector2,
		rng: RandomNumberGenerator, mw: float, free: PgArtScatter.Free, index: int) -> void:
	var start := entries.size()
	var dir := Vector2.from_angle(rng.randf_range(-0.3, 0.3))
	var ups: Array = kind["ups"]
	var flat: Dictionary = kind["flat"]
	var base: Dictionary = ups[rng.randi_range(0, ups.size() - 1)]
	var scale := rng.randf_range(0.97, 1.08)
	var step := maxf(30.0, float(base.get("w", 30.0)) * scale * 1.15) * rng.randf_range(1.0, 1.1)
	var n_up := 3 if step > 50.0 else rng.randi_range(3, 4)
	var half := (n_up - 1) * 0.5
	# ряд: предметы одного рода по одной прямой, ровный шаг, лёгкий разброс масштаба и поворота
	for k in n_up:
		var item: Dictionary = ups[rng.randi_range(0, ups.size() - 1)].duplicate()
		item["w"] = float(item.get("w", 30.0)) * scale * rng.randf_range(0.96, 1.04)
		var p := c + dir * (float(k) - half) * step + Vector2(0.0, rng.randf_range(-1.5, 1.5))
		_put(entries, item, p, rng.randf() < 0.5, rng.randf_range(-0.04, 0.04), mw, true, free)
	# плоские пятна одного вида — в промежутках ряда и по краям, чуть впереди (ниже по кадру)
	for k in n_up + 1:
		var item: Dictionary = flat.duplicate()
		item["w"] = float(item.get("w", 48.0)) * rng.randf_range(1.0, 1.2)
		var p := c + dir * (float(k) - half - 0.5) * step + Vector2(0.0, 11.0)
		_put(entries, item, p, rng.randf() < 0.5, rng.randf_range(-0.12, 0.12), mw, false, free)
	# метка рода и номера группы — тест проверяет однородность
	for i in range(start, entries.size()):
		var holder := entries[i]["node"] as Node2D
		if holder.get_child_count() == 1:
			# плоское пятно (у вертикальных есть тень-полигон): тон рода — ближе к земле
			(holder.get_child(0) as CanvasItem).modulate = kind["tone"]
		elif holder.get_child_count() == 2:
			(holder.get_child(1) as CanvasItem).modulate = kind["up_tone"]
		holder.set_meta("kind", kind["id"])
		holder.set_meta("group", index)


static func _put(entries: Array[Dictionary], item: Dictionary, p: Vector2, flip: bool,
		turn: float, mw: float, shadow: bool, free: PgArtScatter.Free) -> void:
	var tex := PgArtSprites._tex(item, "tex")
	if tex == null:
		return
	# каждый предмет отдельно: группа большая, а проверка центра её края не гарантирует
	var r := float(item.get("w", 30.0)) * 0.5
	if not free.ok(p, r) or (mw > 0.0 and not free.ok(PgArtScatter.mirror(p, mw), r)):
		return
	for side in (2 if mw > 0.0 else 1):
		var q := p if side == 0 else PgArtScatter.mirror(p, mw)
		var f := flip if side == 0 else not flip
		var holder := Node2D.new()
		if shadow:
			var ell := PackedVector2Array()
			var hw := float(item.get("w", 30.0)) * 0.42
			for i in 12:
				ell.append(q + Vector2(cos(TAU * i / 12.0) * hw, sin(TAU * i / 12.0) * hw * 0.32))
			var sh := Polygon2D.new()
			sh.polygon = ell
			sh.color = Color(0.02, 0.02, 0.05, 0.28)
			holder.add_child(sh)
		var sp := PgArtSprites.item_sprite(item, tex, q, f)
		sp.rotation = turn if side == 0 else -turn
		holder.add_child(sp)
		entries.append({"node": holder, "y": q.y})


## Зазоры поля: сетка CELL с расстоянием до ближайшего объекта (минус его радиус). Дорога,
## вода/топь/препятствия и Котлы считаются один раз; объект добавляется в сетку только по
## клеткам рядом с ним (add) — без перебора всех объектов на каждую клетку.
class Field:
	var size := Vector2i.ZERO
	var grid := PackedFloat32Array()
	var world := Vector2.ZERO

	func _init(map: Dictionary, sources: Array) -> void:
		world = LegionTerrain.map_size(map)
		size = Vector2i(ceili(world.x / PgArtFill.CELL), ceili(world.y / PgArtFill.CELL))
		grid.resize(size.x * size.y)
		grid.fill(1e6)
		var roads: Array[PackedVector2Array] = []
		for raw in map.get("roads", []):
			roads.append(PgArtRoad._points(raw.get("path", [])))
		var blocks: Array[PackedVector2Array] = []
		for key: String in ["water", "swamp", "bridges", "rocks"]:
			for raw: Array in map.get(key, []):
				var poly := PgArtRoad._points(raw)
				if poly.size() >= 3:
					blocks.append(poly)
		# зазор дальше EMPTY_R + запас не важен: куски дальше отбрасываем по рамке (дёшево)
		var cap := PgArtFill.EMPTY_R + 2.0 * PgArtFill.CELL
		var boxes: Array[Rect2] = []
		for poly in blocks:
			var box := Rect2(poly[0], Vector2.ZERO)
			for q in poly:
				box = box.expand(q)
			boxes.append(box.grow(cap))
		for y in size.y:
			for x in size.x:
				var p := center(x, y)
				var best := 1e6
				for path in roads:
					for i in path.size() - 1:
						var d := p.distance_to(Geometry2D.get_closest_point_to_segment(
							p, path[i], path[i + 1])) - PgArtFill.ROAD_HALF
						if d < best:
							best = d
				for k in blocks.size():
					if not boxes[k].has_point(p):
						continue
					if Geometry2D.is_point_in_polygon(p, blocks[k]):
						best = 0.0
						break
					best = minf(best, PgArtSprites._edge_dist(p, blocks[k]))
				grid[y * size.x + x] = best
		for c in PgArtScatter.cauldrons(map):
			add(c, 50.0)
		for src: Node in sources:
			_collect(src)

	func center(x: int, y: int) -> Vector2:
		return (Vector2(x, y) + Vector2.ONE * 0.5) * PgArtFill.CELL

	func _collect(n: Node) -> void:
		if n is Sprite2D:
			var sp := n as Sprite2D
			if sp.texture != null:
				var sz := sp.texture.get_size() * sp.scale.abs()
				add(sp.position + (sp.offset * sp.scale + sz * 0.5 if not sp.centered
					else Vector2.ZERO), maxf(sz.x, sz.y) * 0.4)
		for c in n.get_children():
			_collect(c)

	## Объект радиуса r в точке p: клетки в радиусе r + EMPTY_R получают меньший зазор.
	func add(p: Vector2, r: float) -> void:
		var reach := r + PgArtFill.EMPTY_R + PgArtFill.CELL
		var x0 := maxi(0, int((p.x - reach) / PgArtFill.CELL))
		var x1 := mini(size.x - 1, int((p.x + reach) / PgArtFill.CELL))
		var y0 := maxi(0, int((p.y - reach) / PgArtFill.CELL))
		var y1 := mini(size.y - 1, int((p.y + reach) / PgArtFill.CELL))
		for y in range(y0, y1 + 1):
			for x in range(x0, x1 + 1):
				var d := center(x, y).distance_to(p) - r
				var i := y * size.x + x
				if d < grid[i]:
					grid[i] = d

	func clearance(p: Vector2) -> float:
		var x := clampi(int(p.x / PgArtFill.CELL), 0, size.x - 1)
		var y := clampi(int(p.y / PgArtFill.CELL), 0, size.y - 1)
		return grid[y * size.x + x]


## Доля клеток кадра, где до ближайшего объекта дальше EMPTY_R (метрика пустоты, 0…1).
static func emptiness(map: Dictionary, sources: Array, extra := PackedVector2Array()) -> float:
	var field := Field.new(map, sources)
	for q in extra:
		field.add(q, 40.0)
	var empty := 0
	for d in field.grid:
		if d > EMPTY_R:
			empty += 1
	return float(empty) / maxf(float(field.grid.size()), 1.0)
