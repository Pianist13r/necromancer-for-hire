class_name TerrainView
extends Node2D
## Статичный рельеф: команды CanvasItem сохраняются до следующего setup.

## LegionFx подписывается, чтобы досэмплировать цвет пыли, когда PgArt дособирает фон
## (B-107) — на кампанийных картах эмитится сразу же вместе с setup(), фон уже есть.
signal background_ready(texture: Texture2D)
## Завершение сборки, включая отказ; background_ready остаётся сигналом только для успеха.
signal background_build_finished(success: bool)

## Кадр одиночной карты; размер рисунка — размер мира карты (_size: поле «Схватки» 1600×900).
const WORLD := Vector2(1280, 720)
const TERRAIN_Z := -20
## Палитры сохраняют контраст тропы во всех темах.
const THEMES := {"grave": Color("202434"), "swamp": Color("1d302e"),
	"ash": Color("302937"), "office": Color("272d3b")}
const ROAD := Color("635866")
const ROAD_EDGE := Color("34313f")
const WATER := Color("16394c")
const WATER_LIGHT := Color("4d8792")
const MARSH := Color("254c40")
const STONE := Color("535970")
const STONE_LIGHT := Color("798299")
const STONE_DARK := Color("34394e")
const SHADOW := Color(0.025, 0.035, 0.07, 0.65)
const WOOD := Color("84705f")
const WARM := Color("ffc17c")
const BONE := Color("aaa69b")
## Ширина тропы и растушёвки не меняет игровую проходимость.
const ROAD_WIDTH := LegionCfg.MAP_ROAD_WIDTH
const EDGE_WIDTH := 70.0
const SOFT_STEPS := 6
const HAIR := 1.0
const OUTLINE := 2.0
## Низкоконтрастная почва — детерминированный узор без расходования RNG мира.
const GRAIN_COUNT := 1800
const GRAIN_STEP := Vector2(137.37, 79.73)
const GRAIN_RADIUS := 1.4
const GRAIN_COLOR := Color(0.55, 0.58, 0.67, 0.07)
## Нерегулярный почвенный рисунок и следы колеи убирают вид геометрической схемы.
const HASH_SCALE := 43758.5453
const HASH_PHASE := 12.9898
const SOIL_PATCHES := 85
const SOIL_RADIUS := 48.0
const SOIL_COLOR := Color(0.34, 0.36, 0.48, 0.025)
const TRACK_STEP := 15.0
const TRACK_LENGTH := 5.0
const TRACK_COLOR := Color(0.78, 0.70, 0.66, 0.15)
## Коэффициенты оттенков вынесены, чтобы палитра правилась без обхода функций.
const BANK_DARKEN := 0.35
const MARSH_EDGE_LIGHTEN := 0.12
const RIPPLE_ALPHA := 0.28
const MARSH_ROAD := Color("555b50")
const SURFACE_JITTER := 0.7
const HUMMOCK_LIGHTEN := 0.09
const BOARD_BASE_DARKEN := 0.45
const FORD_DARKEN := 0.18
## Блики и кочки редкие, чтобы вода не выглядела проходимой землёй.
const SURFACE_STEP := Vector2(27, 23)
const RIPPLE_LENGTH := 12.0
const HUMMOCK_RADIUS := 5.0
## Грани внутри исходного контура: видимая скала совпадает с коллизией.
const ROCK_INSET := 0.67
const ROCK_LIFT := Vector2(-5, -9)
const SHADOW_OFFSET := Vector2(9, 13)
## Доски поперёк горизонтальных переправ; нижняя переправа — брод без перил.
const BOARD_STEP := 12.0
const BOARD_GAP := 2.0
const FORD_INDEX := 1
## Декор компактный и не заходит на тропу даже кроной.
const DECOR_CLEARANCE := 62.0
const DECOR_SCALE := 22.0
const GRAVE_RECT := Rect2(-0.38, -0.85, 0.76, 0.9)
const CRYPT_RECT := Rect2(-1.5, -1.4, 3.0, 1.8)
const CRYPT_DOOR := Rect2(-0.45, -0.8, 0.9, 1.2)
const TREE_BRANCHES := [Vector2(0, 0.25), Vector2(-0.1, -1.9),
	Vector2(-0.1, -0.6), Vector2(-0.9, -1.15), Vector2(-0.9, -1.15),
	Vector2(-1.05, -1.8), Vector2(-0.1, -1.1), Vector2(0.85, -1.65)]
const DECOR_STROKE := 0.13
const GRAVE_RADIUS := 0.38
const GLOW_RADIUS := 1.25
const FLAME_RADIUS := 0.12
const FLAME_OFFSET := Vector2(0, -0.4)
const CROSS_TOP := Vector2(0, -1.3)
const CROSS_LEFT := Vector2(-0.5, -0.9)
const CROSS_RIGHT := Vector2(0.5, -0.9)
## Нормализованные размеры декора масштабируются вместе с DECOR_SCALE.
const DECOR_SHADOW_POS := Vector2(0.2, 0.15)
const DECOR_SHADOW_RADIUS := 0.65
const CRYPT_ROOF := [Vector2(-1.7, -1.4), Vector2(0, -2.4), Vector2(1.7, -1.4)]
const CRYPT_ARCH_POS := Vector2(0, -0.8)
const CRYPT_ARCH_RADIUS := 0.45
const CANDLE_GLOW_ALPHA := 0.025
## Арка стоит внутри кадра; просвет шире дороги.
const GATE_MARGIN := 28.0
const GATE_HALF := 43.0
const GATE_PILLAR := 14.0
const GATE_SEGMENTS := 20

var _map: Dictionary = {}
## Размер мира карты (LegionTerrain.map_size) и ширина зеркального поля PvP (0 — одиночка).
var _size := WORLD
var _mirror_w := 0.0
var _background: Texture2D = null
## Заявка на сборку PgArt, пока не пришёл сигнал ready (B-107): держим ссылку — PgArt это
## RefCounted, без неё сборка освободится раньше, чем эмитит сигнал.
var _pgart_req: PgArt = null
## setup() зовут ДО add_child (legion_world.gd:_build_ground) — SubViewport для рендера
## нельзя завести на узле, которого ещё нет в дереве. Откладываем запуск сборки до _ready().
var _pending_pgart := false
var _art_life: PgArtLife = null
var _depth_split := false
var _depth_entries: Array[Dictionary] = []
var _request_generation := 0
var _background_build_pending := false


## force_pgart — дев-ключ `--dev pgart=1` (B-109): собрать карту через PgArt из ГЕОМЕТРИИ
## обычной кампанийной карты, игнорируя её нарисованный bg, чтобы видеть сборку рядом со
## знакомой раскладкой, пока у процедурных карт своей библиотеки предметов ещё нет.
## Полная сборка PgArt: процедурное поле, дев-ключ `--dev pgart=1` и поле «Схватки» без своего
## нарисованного фона (B-381: «Дуэль» — ключ `pvp`, bg пуст — выглядела голой заливкой). Карта с
## нарисованным bg (вся кампания) рисуется как раньше.
static func wants_pgart(map: Dictionary, force_pgart := false) -> bool:
	if force_pgart or map.has("procgen"):
		return true
	return map.has("pvp") and String(map.get("bg", "")).is_empty()


func setup(map: Dictionary, force_pgart := false, depth_split := false) -> void:
	_request_generation += 1
	if is_instance_valid(_art_life):
		_art_life.queue_free()
		_art_life = null
	_map = map.duplicate(true)
	_size = LegionTerrain.map_size(_map)
	_mirror_w = LegionTerrain.mirror_width(_map)
	_background = null
	_pgart_req = null
	_pending_pgart = false
	_depth_split = depth_split
	_depth_entries.clear()
	var use_pgart := wants_pgart(_map, force_pgart)
	_background_build_pending = use_pgart
	var bg := "" if use_pgart else String(_map.get("bg", ""))
	# Художник отдаёт фон отдельно: отсутствие PNG не мешает играть в раскладку.
	if not bg.is_empty() and ResourceLoader.exists(bg, "Texture2D"):
		_background = load(bg) as Texture2D
	elif use_pgart:
		_pending_pgart = true
		if is_inside_tree():
			_start_pgart()
	z_index = TERRAIN_Z
	queue_redraw()


func _ready() -> void:
	if _pending_pgart:
		_start_pgart()


func _start_pgart() -> void:
	_pending_pgart = false
	_pgart_req = PgArt.build(_map, self, _depth_split)
	if _pgart_req == null:
		_finish_background_build(false, _request_generation)
		return
	_watch_pgart_request(_pgart_req, _request_generation)


func _watch_pgart_request(request: PgArt, generation: int) -> void:
	_pending_pgart = false
	_pgart_req = request
	request.ready.connect(_on_pgart_ready.bind(generation, request), CONNECT_ONE_SHOT)


## Пока сборка не готова (или headless — PgArt.build вернул null), рисуем запасной
## _draw_procedural(): игрок никогда не видит пустой экран из-за одного кадра ожидания GPU.
func _on_pgart_ready(texture: Texture2D, generation: int, request: PgArt) -> void:
	if generation != _request_generation or request != _pgart_req:
		return
	_depth_entries.assign(request.depth_entries)
	_pgart_req = null
	if texture != null:
		_background = texture
		_art_life = PgArtLife.new()
		_art_life.name = "GroundLife"
		_art_life.setup(_map, true)
		add_child(_art_life)
		queue_redraw()
		background_ready.emit(texture)
	_finish_background_build(texture != null, generation)


func _finish_background_build(success: bool, generation: int) -> void:
	if generation != _request_generation or not _background_build_pending:
		return
	_background_build_pending = false
	background_build_finished.emit(success)


func cancel_background_build() -> void:
	_request_generation += 1
	_background_build_pending = false
	_pgart_req = null
	_pending_pgart = false


func background_build_pending() -> bool:
	return _background_build_pending


## Для LegionFx._load_ground (B-107): цвет пыли берётся из ЭТОЙ картинки, не из map.bg —
## у процедурной карты bg пуст, фон собирает PgArt.
func background_texture() -> Texture2D:
	return _background


func depth_entries() -> Array[Dictionary]:
	return _depth_entries


func _draw() -> void:
	if _map.is_empty():
		return
	if _background != null:
		draw_texture_rect(_background, Rect2(Vector2.ZERO, _size), false)
	else:
		_draw_procedural()
	for plot: Dictionary in _map.get("plots", []):
		_plot(Vector2(plot.pos[0], plot.pos[1]))
	for crypt: Dictionary in _map.get("crypts", []):
		_decor(Vector2(crypt.pos[0], crypt.pos[1]), "crypt")
	var entries: Array[Vector2] = []
	for road: Dictionary in _map.get("roads", []):
		var path := _points(road.path)
		if path.size() < 2 or entries.has(path[0]):
			continue
		entries.append(path[0])
		_gate(path)


func _plot(p: Vector2) -> void:
	var rect := Rect2(p - LegionCfg.MAP_PLOT_SIZE * 0.5, LegionCfg.MAP_PLOT_SIZE)
	draw_rect(rect, LegionCfg.MAP_PLOT_FILL)
	draw_rect(rect, LegionCfg.MAP_PLOT_EDGE, false, LegionCfg.MAP_PLOT_STROKE)
	# Углы фундамента видны под будущей постройкой, середина остаётся тихой.
	for corner in [rect.position, Vector2(rect.end.x, rect.position.y),
			rect.end, Vector2(rect.position.x, rect.end.y)]:
		var toward: Vector2 = (p - corner).sign() * LegionCfg.MAP_PLOT_CORNER
		draw_line(corner, corner + Vector2(toward.x, 0), LegionCfg.MAP_PLOT_ACCENT,
			LegionCfg.MAP_PLOT_STROKE, true)
		draw_line(corner, corner + Vector2(0, toward.y), LegionCfg.MAP_PLOT_ACCENT,
			LegionCfg.MAP_PLOT_STROKE, true)
	draw_circle(p, LegionCfg.MAP_PLOT_DOT, LegionCfg.MAP_PLOT_EDGE)


func _draw_procedural() -> void:
	draw_rect(Rect2(Vector2.ZERO, _size), THEMES.get(_map.get("theme", "grave")))
	var area := _pattern_area()
	for i in _pattern_count(SOIL_PATCHES):
		var p := area.position + Vector2(_hash(i) * area.size.x,
			_hash(i + SOIL_PATCHES) * area.size.y)
		for q in _mirrored(p):
			for step in SOFT_STEPS:
				draw_circle(q, SOIL_RADIUS * (1.0 + float(step) / SOFT_STEPS), SOIL_COLOR)
	for i in _pattern_count(GRAIN_COUNT):
		var p := area.position + Vector2(_hash(i * GRAIN_STEP.x) * area.size.x,
			_hash(i * GRAIN_STEP.y) * area.size.y)
		for q in _mirrored(p):
			draw_circle(q, GRAIN_RADIUS, GRAIN_COLOR)
	for raw: Array in _map.get("swamp", []):
		_surface(_points(raw), false)
	for road: Dictionary in _map.get("roads", []):
		var path := _points(road.path)
		for step in range(SOFT_STEPS, 0, -1):
			var width := lerpf(ROAD_WIDTH, EDGE_WIDTH, float(step) / SOFT_STEPS)
			_stroke(path, ROAD_EDGE.lerp(ROAD, 1.0 - float(step) / SOFT_STEPS), width)
		_stroke(path, ROAD, ROAD_WIDTH)
		# Грязная колея остаётся видна, но цвет показывает замедляющий грунт.
		for raw: Array in _map.get("swamp", []):
			for strip in Geometry2D.offset_polyline(path, ROAD_WIDTH / 2.0):
				for patch in Geometry2D.intersect_polygons(strip, _points(raw)):
					draw_colored_polygon(patch, MARSH_ROAD)
		_tracks(path)
	for raw: Array in _map.get("water", []):
		_surface(_points(raw), true)
	var bridges: Array = _map.get("bridges", [])
	for i in bridges.size():
		_bridge(_points(bridges[i]), i == FORD_INDEX)
	for raw: Array in _map.get("rocks", []):
		_rock(_points(raw))
	for item: Dictionary in _map.get("decor", []):
		var p := Vector2(item.pos[0], item.pos[1])
		if _decor_clear(p):
			_decor(p, item.get("kind", "grave"))


## Где раскладывается узор почвы: одиночка — весь кадр; поле PvP — половина стороны 0 (узор
## отражается _mirrored, стороны одинаковы, по стыку шва нет).
func _pattern_area() -> Rect2:
	if _mirror_w > 0.0:
		return Rect2(Vector2.ZERO, Vector2(_mirror_w * 0.5, _size.y))
	return Rect2(Vector2.ZERO, _size)


## Сколько пятен узора на площадь _pattern_area (плотность кадра 1280×720; одиночка — n).
func _pattern_count(n: int) -> int:
	if _mirror_w <= 0.0 and _size == WORLD:
		return n
	var a := _pattern_area().size
	return roundi(float(n) * a.x * a.y / (WORLD.x * WORLD.y))


## Точка узора и её зеркало на поле PvP (одиночка — только сама точка).
func _mirrored(p: Vector2) -> PackedVector2Array:
	if _mirror_w > 0.0:
		return PackedVector2Array([p, Vector2(_mirror_w - p.x, p.y)])
	return PackedVector2Array([p])


func _points(raw: Array) -> PackedVector2Array:
	var result := PackedVector2Array()
	for p: Array in raw:
		result.append(Vector2(p[0], p[1]))
	return result


func _hash(value: float) -> float:
	return fposmod(sin(value * HASH_PHASE) * HASH_SCALE, 1.0)


func _tracks(path: PackedVector2Array) -> void:
	for i in range(1, path.size()):
		var delta := path[i] - path[i - 1]
		var direction := delta.normalized()
		for step in int(delta.length() / TRACK_STEP):
			var p := path[i - 1] + direction * step * TRACK_STEP
			p += direction.orthogonal() * (_hash(step + i) - 0.5) * ROAD_WIDTH
			draw_line(p, p + direction * TRACK_LENGTH, TRACK_COLOR, HAIR, true)


func _stroke(path: PackedVector2Array, color: Color, width: float) -> void:
	draw_polyline(path, color, width, true)
	for p in path:
		draw_circle(p, width / 2.0, color, true, -1.0, true)


func _rim(poly: PackedVector2Array, color: Color, width: float) -> void:
	var closed := poly.duplicate()
	closed.append(poly[0])
	draw_polyline(closed, color, width, true)


func _surface(poly: PackedVector2Array, river: bool) -> void:
	draw_colored_polygon(poly, WATER if river else MARSH)
	_rim(poly, WATER_LIGHT.darkened(BANK_DARKEN) if river
		else MARSH.lightened(MARSH_EDGE_LIGHTEN), OUTLINE)
	for y in range(0, int(_size.y), int(SURFACE_STEP.y)):
		for x in range(0, int(_size.x), int(SURFACE_STEP.x)):
			var p := Vector2(x, y) + Vector2(_hash(x + y), _hash(x - y)) * SURFACE_STEP \
				* SURFACE_JITTER
			var end := p + Vector2(RIPPLE_LENGTH, 0)
			if not Geometry2D.is_point_in_polygon(p, poly):
				continue
			if not Geometry2D.is_point_in_polygon(end, poly):
				continue
			if river:
				draw_line(p, end, Color(WATER_LIGHT, RIPPLE_ALPHA), HAIR, true)
			else:
				draw_circle(p, HUMMOCK_RADIUS, MARSH.lightened(HUMMOCK_LIGHTEN))
				draw_line(p, p - Vector2(0, HUMMOCK_RADIUS), STONE_DARK, HAIR)


func _bridge(poly: PackedVector2Array, ford: bool) -> void:
	var bounds := Rect2(poly[0], Vector2.ZERO)
	for p in poly:
		bounds = bounds.expand(p)
	draw_colored_polygon(poly, WOOD.darkened(BOARD_BASE_DARKEN))
	# Пересечение сохраняет доски внутри произвольного контура переправы.
	var x := bounds.position.x
	while x < bounds.end.x:
		var plank := PackedVector2Array([Vector2(x, bounds.position.y),
			Vector2(x + BOARD_STEP - BOARD_GAP, bounds.position.y),
			Vector2(x + BOARD_STEP - BOARD_GAP, bounds.end.y), Vector2(x, bounds.end.y)])
		for clipped in Geometry2D.intersect_polygons(poly, plank):
			draw_colored_polygon(clipped, WOOD.darkened(FORD_DARKEN) if ford else WOOD)
		x += BOARD_STEP
	_rim(poly, WATER_LIGHT if ford else BONE, HAIR if ford else OUTLINE)
	if not ford:
		for y in [bounds.position.y, bounds.end.y]:
			draw_line(Vector2(bounds.position.x, y), Vector2(bounds.end.x, y), WOOD, OUTLINE)


func _rock(poly: PackedVector2Array) -> void:
	var center := Vector2.ZERO
	var shadow := PackedVector2Array()
	for p in poly:
		center += p
		shadow.append(p + SHADOW_OFFSET)
	center /= poly.size()
	draw_colored_polygon(shadow, SHADOW)
	draw_colored_polygon(poly, STONE_DARK)
	var cap := PackedVector2Array()
	for p in poly:
		cap.append(center + (p - center) * ROCK_INSET + ROCK_LIFT)
	for i in poly.size():
		var next := (i + 1) % poly.size()
		var face := PackedVector2Array([poly[i], poly[next], cap[next], cap[i]])
		var light := clampf((center.y - poly[i].y) / DECOR_CLEARANCE, 0.0, 1.0)
		draw_colored_polygon(face, STONE_DARK.lerp(STONE_LIGHT, light))
	draw_colored_polygon(cap, STONE)
	_rim(cap, STONE_LIGHT, HAIR)
	draw_line(cap[0], center, STONE_DARK, OUTLINE, true)
	draw_line(center, cap[cap.size() / 2], STONE_DARK, HAIR, true)


func _decor_clear(p: Vector2) -> bool:
	for road: Dictionary in _map.get("roads", []):
		var path := _points(road.path)
		for i in range(1, path.size()):
			if p.distance_to(Geometry2D.get_closest_point_to_segment(
				p, path[i - 1], path[i])) < DECOR_CLEARANCE:
				return false
	for key in ["water", "rocks", "bridges"]:
		for raw: Array in _map.get(key, []):
			if Geometry2D.is_point_in_polygon(p, _points(raw)):
				return false
	return true


func _decor(p: Vector2, kind: String) -> void:
	draw_set_transform(p, 0, Vector2.ONE * DECOR_SCALE)
	draw_circle(DECOR_SHADOW_POS, DECOR_SHADOW_RADIUS, SHADOW)
	match kind:
		"tree":
			for i in range(0, TREE_BRANCHES.size(), 2):
				draw_line(TREE_BRANCHES[i], TREE_BRANCHES[i + 1], STONE_DARK,
					DECOR_STROKE * 2.0, true)
				draw_line(TREE_BRANCHES[i], TREE_BRANCHES[i + 1], STONE,
					DECOR_STROKE / 2.0, true)
		"cross":
			draw_line(Vector2.ZERO, CROSS_TOP, STONE_LIGHT, DECOR_STROKE, true)
			draw_line(CROSS_LEFT, CROSS_RIGHT, STONE_LIGHT, DECOR_STROKE, true)
		"candle":
			for step in range(SOFT_STEPS, 0, -1):
				draw_circle(FLAME_OFFSET, GLOW_RADIUS * float(step) / SOFT_STEPS,
					Color(WARM, CANDLE_GLOW_ALPHA))
			draw_line(Vector2.ZERO, FLAME_OFFSET, BONE, DECOR_STROKE)
			draw_circle(FLAME_OFFSET, FLAME_RADIUS, WARM)
		"bones":
			draw_line(CROSS_LEFT / 2.0, CROSS_RIGHT / 2.0, BONE, DECOR_STROKE)
			draw_circle(CROSS_LEFT / 2.0, FLAME_RADIUS, BONE)
			draw_circle(CROSS_RIGHT / 2.0, FLAME_RADIUS, BONE)
		"crypt":
			draw_rect(CRYPT_RECT, STONE_DARK)
			draw_rect(CRYPT_RECT, STONE_LIGHT, false, DECOR_STROKE)
			draw_colored_polygon(PackedVector2Array(CRYPT_ROOF), STONE)
			draw_rect(CRYPT_DOOR, SHADOW)
			draw_arc(CRYPT_ARCH_POS, CRYPT_ARCH_RADIUS, PI, TAU, GATE_SEGMENTS,
				WARM, DECOR_STROKE, true)
		_:
			draw_rect(GRAVE_RECT, STONE)
			draw_circle(Vector2(0, GRAVE_RECT.position.y), GRAVE_RADIUS, STONE)
			draw_line(CROSS_TOP / 2.0, Vector2.ZERO, STONE_LIGHT, DECOR_STROKE / 2.0)
			draw_line(CROSS_LEFT / 2.0, CROSS_RIGHT / 2.0, STONE_LIGHT,
				DECOR_STROKE / 2.0)
	draw_set_transform(Vector2.ZERO)


func _gate(path: PackedVector2Array) -> void:
	var rect := Rect2(Vector2.ONE * GATE_MARGIN, _size - Vector2.ONE * GATE_MARGIN * 2.0)
	var entry := path[0].clamp(rect.position, rect.end)
	var tangent := (path[1] - path[0]).normalized()
	var across := tangent.orthogonal()
	for side in [-1.0, 1.0]:
		var p: Vector2 = entry + across * GATE_HALF * side
		draw_rect(Rect2(p - Vector2.ONE * GATE_PILLAR / 2.0,
			Vector2.ONE * GATE_PILLAR), STONE_LIGHT)
		draw_circle(p, GATE_PILLAR / 4.0, WARM)
	draw_arc(entry, GATE_HALF, across.angle(), across.angle() + PI,
		GATE_SEGMENTS, STONE, OUTLINE * 2.0, true)
