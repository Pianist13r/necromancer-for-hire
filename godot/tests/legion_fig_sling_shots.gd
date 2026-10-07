extends SceneTree
##
## Кадры приёмки: ПРЕВЬЮ РОГАТКИ ПО ФИГУРАМ настоящими событиями мыши (как legion_sling_shots).
## Показывает треугольник «Обряд», восьмёрку «Двойная смена» и кольцо в натяжке — сравнить ДО/ПОСЛЕ
## правки превью. Окном, не headless:
##
##   "$GODOT" --path godot --fixed-fps 60 --script res://tests/legion_fig_sling_shots.gd
##       -- --mute --out C:/AI/necro/batches/ui-1006-fig/after
##
## Схема управления — только в памяти (Settings.scheme_override), сохранение — тестовый файл мира,
## настоящая мышь владельца глушится (_Mute).
##

const DEVICE := 7
const FC := Vector2(1130.0, 405.0)

var w: LegionWorld
var _out := ""
var _frame := 0


class _Mute:
	extends Node

	func _input(event: InputEvent) -> void:
		if event.device != DEVICE and (event is InputEventMouse or event is InputEventKey):
			get_viewport().set_input_as_handled()


func _initialize() -> void:
	_run.call_deferred()


func _screen(p: Vector2) -> Vector2:
	return root.get_final_transform() * p


func _tick(n := 1) -> void:
	for i in n:
		await process_frame
		_frame += 1


func _shot(name: String) -> void:
	root.get_texture().get_image().save_png(_out.path_join(name))


func _move(p: Vector2, mask: int = MOUSE_BUTTON_MASK_RIGHT) -> void:
	var ev := InputEventMouseMotion.new()
	ev.device = DEVICE
	ev.position = _screen(p)
	ev.global_position = ev.position
	ev.button_mask = mask
	Input.parse_input_event(ev)
	await _tick(1)


func _button(p: Vector2, pressed: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.device = DEVICE
	ev.position = _screen(p)
	ev.global_position = ev.position
	ev.button_index = MOUSE_BUTTON_RIGHT
	ev.pressed = pressed
	ev.button_mask = MOUSE_BUTTON_MASK_RIGHT if pressed else 0
	Input.parse_input_event(ev)
	await _tick(1)


func _dense(pts: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array([pts[0]])
	for i in range(1, pts.size()):
		var a := pts[i - 1]
		var b := pts[i]
		var n := maxi(1, ceili(a.distance_to(b) / 6.0))
		for k in range(1, n + 1):
			out.append(a.lerp(b, float(k) / n))
	return out


func _ngon(n: int, r: float, rot := 0.0) -> Array[Vector2]:
	var out: Array[Vector2] = []
	for i in n:
		out.append(FC + Vector2.from_angle(rot + TAU * i / n) * r)
	return out


## Закрытый штрих по углам (start — доля первого ребра, как в тесте фигур).
func _shape(corners: Array[Vector2], start := 0.0) -> PackedVector2Array:
	var m := corners.size()
	var s0 := corners[0].lerp(corners[1 % m], start)
	var path := PackedVector2Array([s0])
	for i in range(1, m + 1):
		path.append(corners[i % m])
	if start > 0.0:
		path.append(s0)
	return _dense(path)


func _eight() -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in 105:
		var t := PI * 0.5 + TAU * i / 104.0
		out.append(FC + Vector2(45 * sin(t), 110 * sin(t) * cos(t)).rotated(PI * 0.5))
	return out


func _man(c: Contract) -> void:
	for p in c.posts:
		if p["unit"] == null and not p["dead"]:
			var u := w.spawn_unit(c.kind, p["pos"])
			u.assign(c, p)
			u._arrive()


func _still(at: Vector2) -> void:
	var f := w.spawn_foe_on_path("zombie", PackedVector2Array([at, at + Vector2(0, 60)]), at)
	f.speed = 0.0
	f.hp = 4000.0
	f.max_hp = 4000.0


## Захват участка seg фигуры c, оттяжка на pull, кадр в name.
func _sling_shot(c: Contract, seg: int, pull: Vector2, name: String) -> void:
	_man(c)
	# враг в зоне «Точно!»: над серединой строя по оси оттяжки (ось = -pull)
	var mid := Vector2.ZERO
	var n := 0
	for p in c.posts:
		if p["unit"] != null:
			mid += p["unit"].position
			n += 1
	if n > 0:
		_still(mid / float(n) + (-pull.normalized()) * 70.0)
	await _tick(6)
	var at := c.seg_center(seg)
	await _move(at + Vector2(0, -2), 0)
	await _button(at, true)
	for k in range(1, 41):
		await _move(at + pull * (k / 40.0))
	await _tick(4)
	await _shot(name)
	var aim := w.contracts.sling_aim()
	print("%s: сегментов=%d мест=%d aim.dir=%s perfect=%s" % [name, c.seg_count(),
		c.posts.size(), aim.get("dir", "?"), aim.get("perfect", "?")])
	await _button(at + pull, false)
	await _tick(3)


func _run() -> void:
	var argv := OS.get_cmdline_user_args()
	var i := argv.find("--out")
	_out = argv[i + 1] if i >= 0 and i + 1 < argv.size() else "user://fig_sling_shots"
	var j := argv.find("--fig")
	var fig := argv[j + 1] if j >= 0 and j + 1 < argv.size() else "triangle"
	DirAccess.make_dir_recursive_absolute(_out)
	Settings.scheme_override = Settings.SCHEME_SLING
	root.add_child(_Mute.new())
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	w = scene.instantiate() as LegionWorld
	root.add_child(w)
	await _tick(2)
	w.dev["no_waves"] = "1"
	w.dev["spawn_units"] = "0"
	w.start_map("_gray")
	await _tick(60)
	var f := w.contracts
	var c: Contract = null
	var pull := Vector2(0, 170)
	match fig:
		"triangle":
			c = f.call("_create", _shape(_ngon(3, 80, -PI * 0.5 + 0.1), 0.2), 1,
				LegionCfg.KIND_LABORER, false, ContractShape.TRIANGLE) as Contract
		"square":
			c = f.call("_create", _shape(_ngon(4, 85, PI * 0.25), 0.3), 1,
				LegionCfg.KIND_LABORER, false, ContractShape.SQUARE) as Contract
		"eight":
			c = f.call("_create", _dense(_eight()), 1, LegionCfg.KIND_LABORER, false,
				ContractShape.EIGHT) as Contract
		"ring":
			c = f.call("_create", _dense(_ngon(24, 80)), 1, LegionCfg.KIND_LABORER, true) as Contract
	if c == null:
		print("НЕ СОЗДАЛОСЬ: %s" % fig)
		quit(1)
		return
	await _sling_shot(c, 0 if fig != "eight" else 6, pull, "%s_pull.png" % fig)
	Settings.scheme_override = ""
	quit(0)
