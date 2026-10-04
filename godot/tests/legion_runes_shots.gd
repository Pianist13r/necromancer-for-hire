extends SceneTree
##
## Кадры приёмки фигур «Двойная смена» (восьмёрка), «Обряд» (треугольник, до D-1002-03 — звезда)
## и «Каре» (квадрат) — не тест гейта. Фигуры
## чертятся НАСТОЯЩИМИ событиями мыши на карте _gray. Окном, не headless:
##
##   "$GODOT" --path godot --fixed-fps 60 --resolution 1280x720
##       --script res://tests/legion_runes_shots.gd -- --mute --out C:/AI/necro/batches/legion/runes
##
## Кадры: 1_eight_draft — черновик восьмёрки с подписью; 2_eight_posted — строй в восьмёрке;
## 3_eight_cross — миг «Крест-накрест!»; 4_overtime_* — «Сверхурочные» (второй натиск);
## 5_tri_draft — черновик треугольника с подписью; 6_tri_posted — строй в треугольнике, враги
## внутри; 7_rite_* — «Обряд!» по времени; 8_square_draft / 9_square_posted — «Каре».
## Настоящие мышь и клавиатура на время прогона глушатся (_Mute), схема — только в памяти.
##

const DEVICE := 7
const SAVE := "user://legion_runes_shots.cfg"
const FC := Vector2(1130.0, 405.0)

var w: LegionWorld
var _out := ""


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


func _shot(name: String) -> void:
	await _tick(1)
	await RenderingServer.frame_post_draw
	var img := root.get_texture().get_image()
	if img.get_size() != Vector2i(1280, 720):
		img.resize(1280, 720, Image.INTERPOLATE_LANCZOS)
	img.save_png(_out.path_join(name))
	print("кадр ", name)


func _move(p: Vector2, mask: int) -> void:
	var ev := InputEventMouseMotion.new()
	ev.device = DEVICE
	ev.position = _screen(p)
	ev.global_position = ev.position
	ev.button_mask = mask
	Input.parse_input_event(ev)
	await _tick(1)


func _button(p: Vector2, button: MouseButton, pressed: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.device = DEVICE
	ev.position = _screen(p)
	ev.global_position = ev.position
	ev.button_index = button
	ev.pressed = pressed
	var bit := MOUSE_BUTTON_MASK_LEFT if button == MOUSE_BUTTON_LEFT else MOUSE_BUTTON_MASK_RIGHT
	ev.button_mask = bit if pressed else 0
	Input.parse_input_event(ev)
	await _tick(1)


func _still(at: Vector2, hp := 400.0) -> Foe:
	var f := w.spawn_foe_on_path("zombie", PackedVector2Array([at, at + Vector2(0, 400)]), at)
	f.speed = 0.0
	f.hp = hp
	f.max_hp = hp
	return f


func _fresh() -> void:
	w.dev = {"no_waves": "1", "spawn_units": "0"}
	w.start_map("_gray")
	await _tick(90)   # вводный тост карты уходит
	w.contracts.mana = w.contracts.mana_max


func _draw(pts: PackedVector2Array, shot: String) -> Contract:
	await _move(pts[0], 0)
	await _button(pts[0], MOUSE_BUTTON_LEFT, true)
	for k in range(1, pts.size()):
		await _move(pts[k], MOUSE_BUTTON_MASK_LEFT)
	w.contracts.update_preview()
	await _shot(shot)
	await _button(pts[pts.size() - 1], MOUSE_BUTTON_LEFT, false)
	return w.contracts.contracts[w.contracts.contracts.size() - 1]


func _man(c: Contract, frac := 1.0) -> Array[Legionnaire]:
	var out: Array[Legionnaire] = []
	for p in c.posts:
		if float(out.size()) >= frac * c.posts.size():
			break
		if p["unit"] == null and not p["dead"]:
			var u := w.spawn_unit(c.kind, p["pos"])
			u.assign(c, p)
			u._arrive()
			u.hp = 1e6   # кадры: строй не должен погибнуть от чучел раньше времени
			u.max_hp = 1e6
			out.append(u)
	return out


func _eight_pts() -> PackedVector2Array:
	var pts := PackedVector2Array()
	var n := 120
	for k in n + 1:
		var t := PI * 0.5 + 0.2 + TAU * float(k) / n
		var s := sin(t)
		var sc := 0.9 if s < 0.0 else 1.0
		var p := Vector2(85.0 * s * sc, 130.0 * s * cos(t) * sc).rotated(PI * 0.5)
		p *= 1.0 + 0.04 * sin(t * 3.0 + 1.1)
		pts.append(FC + p)
	return pts


## Многоугольник «рукой»: n вершин на окружности радиусом r (3 — треугольник, 4 — квадрат).
func _ngon_pts(n: int, r: float) -> PackedVector2Array:
	var tips: Array[Vector2] = []
	var a0 := -PI * 0.5 + 0.15 if n == 3 else -PI * 0.75 + 0.1
	for i in n:
		var a := a0 + TAU * i / n
		tips.append(FC + Vector2.from_angle(a) * r * (1.0 + 0.05 * sin(i * 2.3)))
	var pts := PackedVector2Array()
	var order: Array[int] = []
	for k in n + 1:
		order.append(k % n)
	for k in range(1, order.size()):
		var a: Vector2 = tips[order[k - 1]]
		var b: Vector2 = tips[order[k]]
		var m := ceili(a.distance_to(b) / 6.0)
		for j in m:
			pts.append(a.lerp(b, float(j) / m) + Vector2(sin(j * 1.7) * 1.2, cos(j * 2.1) * 1.2))
	pts.append(tips[0] + Vector2(2, 1))
	return pts


func _run() -> void:
	var argv := OS.get_cmdline_user_args()
	var i := argv.find("--out")
	_out = argv[i + 1] if i >= 0 and i + 1 < argv.size() else "user://runes_shots"
	DirAccess.make_dir_recursive_absolute(_out)
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	Settings.scheme_override = Settings.SCHEME_SLING
	root.add_child(_Mute.new())
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	w = scene.instantiate() as LegionWorld
	root.add_child(w)
	await _tick(2)
	await _eight_shots()
	await _figure_shots()
	Settings.scheme_override = ""
	Campaign.reset()
	quit(0)


func _eight_shots() -> void:
	await _fresh()
	var c := await _draw(_eight_pts(), "1_eight_draft.png")
	print("восьмёрка: ", c.figure, " мест ", c.posts.size(), " длина ", c.length)
	_man(c)
	for off: Vector2 in [Vector2(-95, -40), Vector2(95, 30), Vector2(-90, 50)]:
		_still(FC + off)
	await _tick(70)
	await _shot("2_eight_posted.png")
	var at := c.seg_center(2)
	await _move(at, 0)
	await _button(at, MOUSE_BUTTON_RIGHT, true)
	await _button(at + Vector2(2, 1), MOUSE_BUTTON_RIGHT, false)
	await _tick(12)
	await _shot("3_eight_cross.png")
	# «Сверхурочные»: новая восьмёрка, полный строй, тает сама
	await _fresh()
	c = await _draw(_eight_pts(), "_tmp.png")
	_man(c)
	await _tick(30)
	for s in c.seg_count():
		c.seg_age[s] = c.ttl - 0.05
	await _tick(20)
	await _shot("4_overtime_0_melt.png")
	var t0 := Time.get_ticks_msec()
	while int(w.stats.get("overtimes", 0)) == 0 and Time.get_ticks_msec() - t0 < 6000:
		await _tick(1)
	await _shot("4_overtime_1_fire.png")
	await _tick(20)
	await _shot("4_overtime_2_0.33s.png")


func _figure_shots() -> void:
	await _fresh()
	var c := await _draw(_ngon_pts(3, 80.0), "5_tri_draft.png")
	print("треугольник: ", c.figure, " мест ", c.posts.size(), " длина ", c.length)
	_man(c)
	for off: Vector2 in [Vector2(-8, -6), Vector2(10, 8), Vector2(-4, 14), Vector2(160, -30)]:
		_still(c.center + off, 30.0 if off.x < 0.0 else 400.0)
	# свежий труп в центре — встанет внештатником
	var dead := _still(c.center + Vector2(14, -16), 5.0)
	dead.take_damage(50.0, dead.position)
	await _tick(60)
	await _shot("6_tri_posted.png")
	for s in c.seg_count():
		c.seg_age[s] = c.ttl - 0.02
	var t0 := Time.get_ticks_msec()
	while int(w.stats.get("rites", 0)) == 0 and Time.get_ticks_msec() - t0 < 3000:
		await _tick(1)
	await _shot("7_rite_0_flash.png")
	await _tick(9)
	await _shot("7_rite_1_0.15s.png")
	await _tick(21)
	await _shot("7_rite_2_0.5s.png")
	await _tick(42)
	await _shot("7_rite_3_1.2s.png")
	# «Каре»: черновик и строй, враги снаружи
	await _fresh()
	c = await _draw(_ngon_pts(4, 85.0), "8_square_draft.png")
	print("квадрат: ", c.figure, " мест ", c.posts.size(), " длина ", c.length)
	_man(c)
	for off: Vector2 in [Vector2(-110, 0), Vector2(110, 20), Vector2(0, -115)]:
		_still(c.center + off)
	await _tick(60)
	await _shot("9_square_posted.png")
