extends Node2D
## Просмотрщик не зависит от ядра, поэтому пригоден до сборки боевой сцены.

const TERRAIN := preload("res://scripts/legion/terrain_view.gd")
## Тонкий контрольный слой не скрывает рельеф.
const LINE_COLOR := Color(0.7, 1.0, 0.85, 0.7)
const LINE_WIDTH := 1.0
const ARROW_LENGTH := 24.0
const CAULDRON_RADIUS := 28.0
const CIRCLE_SEGMENTS := 48
## Проверяем коридор шириной 64 px, включая берега переправ.
const WALK_RADIUS := 32.0
const SAMPLE_STEP := 4.0
const SAMPLE_SIDES := 16
const REQUIRED := ["id", "order", "title", "subtitle", "theme", "cauldron", "cauldron_hp",
	"start_army", "army_cap", "rocks", "water", "bridges", "swamp", "roads", "crypts",
	"decor", "bot_lines", "waves", "hint"]
const FOES := ["zombie", "beetle", "signer", "ghost", "mimic", "boss"]

var _map: Dictionary = {}


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var map_id := "bridge"
	var shot := ""
	for i in args.size():
		if args[i] in ["--map", "--shot"]:
			if i + 1 >= args.size():
				_fail("Missing value for " + args[i])
				return
			if args[i] == "--map":
				map_id = args[i + 1]
			else:
				shot = args[i + 1]
	var path := "res://assets/legion/maps/%s.json" % map_id
	if not FileAccess.file_exists(path):
		_fail("Map not found: " + path)
		return
	var parser := JSON.new()
	if parser.parse(FileAccess.get_file_as_string(path)) != OK:
		_fail(parser.get_error_message())
		return
	if not parser.data is Dictionary:
		_fail("Map root must be a dictionary")
		return
	_map = parser.data
	if not _validate():
		get_tree().quit(1)
		return
	if args.has("--validate-only"):
		get_tree().quit()
		return
	_build(shot)


func _build(shot: String) -> void:
	var terrain := TERRAIN.new()
	add_child(terrain)
	terrain.setup(_map)
	queue_redraw()
	await _save_shot(shot)


func _save_shot(shot: String) -> void:
	if shot.is_empty():
		return
	if DisplayServer.get_name() == "headless":
		_fail("Screenshots require a rendering display")
		return
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var error := DirAccess.make_dir_recursive_absolute(shot.get_base_dir())
	if error != OK:
		_fail("Cannot create screenshot directory: %s" % error)
		return
	error = get_viewport().get_texture().get_image().save_png(shot)
	if error != OK:
		_fail("Cannot save screenshot: %s" % error)
		return
	print("MAP_PREVIEW_OK ", _map.id, " ", shot)
	get_tree().quit()


func _draw() -> void:
	if _map.is_empty():
		return
	for line: Dictionary in _map.bot_lines:
		var a := Vector2(line.a[0], line.a[1])
		var b := Vector2(line.b[0], line.b[1])
		var center := (a + b) / 2.0
		var direction := (b - a).normalized().orthogonal() * float(line.release)
		draw_line(a, b, LINE_COLOR, LINE_WIDTH, true)
		draw_line(center, center + direction * ARROW_LENGTH, LINE_COLOR, LINE_WIDTH, true)
	var cauldron := Vector2(_map.cauldron[0], _map.cauldron[1])
	draw_arc(cauldron, CAULDRON_RADIUS, 0, TAU, CIRCLE_SEGMENTS,
		LINE_COLOR, LINE_WIDTH, true)


func _fail(message: String) -> void:
	push_error(message)
	get_tree().quit(1)


func _validate() -> bool:
	var errors: Array[String] = []
	for key: String in REQUIRED:
		if not _map.has(key):
			errors.append("Missing field: " + key)
	if not errors.is_empty():
		_fail(str(errors))
		return false
	var cauldron := _point(_map.cauldron)
	if not Rect2(150, 150, 980, 420).has_point(cauldron):
		errors.append("Cauldron too close to edge")
	var ids: Array[String] = []
	for road: Dictionary in _map.roads:
		ids.append(road.id)
		var first := _point(road.path[0])
		if not (first.x < -40 or first.x > 1320 or first.y < -40 or first.y > 760):
			errors.append("Road must start offscreen: " + str(road.id))
		if _point(road.path[-1]) != cauldron:
			errors.append("Road must end at cauldron: " + str(road.id))
		for i in range(1, road.path.size()):
			if not _corridor_clear(_point(road.path[i - 1]), _point(road.path[i])):
				errors.append("Blocked 64px road corridor: " + str(road.id))
	for line: Dictionary in _map.bot_lines:
		var length := _point(line.a).distance_to(_point(line.b))
		if line.road not in ids or length < LegionCfg.LINE_MIN or length > LegionCfg.LINE_MAX:
			errors.append("Invalid bot line: " + str(line))
		if not _segment_clear(_point(line.a), _point(line.b)):
			errors.append("Bot line crosses obstacle: " + str(line.road))
		if absf(float(line.release)) != 1.0:
			errors.append("Invalid release direction")
	for wave: Dictionary in _map.waves:
		if not wave.has("pause") or not wave.has("groups"):
			errors.append("Invalid wave")
			continue
		for group: Dictionary in wave.groups:
			for key: String in ["road", "type", "count", "interval", "delay"]:
				if not group.has(key):
					errors.append("Missing group field: " + key)
			if group.get("road") not in ids or group.get("type") not in FOES:
				errors.append("Unknown road or enemy")
	for error: String in errors:
		push_error(str(_map.id) + ": " + error)
	if errors.is_empty():
		print("MAP_VALIDATION_OK ", _map.id)
	return errors.is_empty()


func _point(raw: Array) -> Vector2:
	return Vector2(raw[0], raw[1])


func _inside(p: Vector2, key: String) -> bool:
	for raw: Array in _map[key]:
		var poly := PackedVector2Array()
		for pair: Array in raw:
			poly.append(_point(pair))
		if Geometry2D.is_point_in_polygon(p, poly):
			return true
	return false


func _walkable(p: Vector2) -> bool:
	return not _inside(p, "rocks") and (not _inside(p, "water") or _inside(p, "bridges"))


func _segment_clear(a: Vector2, b: Vector2) -> bool:
	var steps := maxi(1, ceili(a.distance_to(b) / SAMPLE_STEP))
	for i in range(steps + 1):
		if not _walkable(a.lerp(b, float(i) / steps)):
			return false
	return true


func _corridor_clear(a: Vector2, b: Vector2) -> bool:
	if not _segment_clear(a, b):
		return false
	for side in SAMPLE_SIDES:
		var offset := Vector2.from_angle(TAU * side / SAMPLE_SIDES) * WALK_RADIUS
		if not _segment_clear(a + offset, b + offset):
			return false
	return true
