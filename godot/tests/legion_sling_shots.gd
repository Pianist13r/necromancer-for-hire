extends SceneTree
##
## Кадры приёмки рогатки v17 (поток CTL, не тест гейта): натяжка и срыв НАСТОЯЩИМИ событиями
## мыши (Input.parse_input_event в координатах окна) на карте «Пустырь». Окном, не headless:
##
##   "$GODOT" --path godot --fixed-fps 60 --script res://tests/legion_sling_shots.gd
##       -- --mute --out C:/AI/necro/batches/legion/v17/ctl
##
## Пишет каждый 2-й кадр в <out>/frames/ (ролик 30 к/с собирает tools вне игры) и ключевые кадры
## в <out>/: слабая натяжка, сильная, золотая зона, «Точно!», удар, комбо ×2 и ×3.
## Настоящая мышь и клавиатура владельца на время прогона глушатся (_Mute), схема управления —
## только в памяти (Settings.scheme_override), сохранение — тестовый файл мира.
##

const DEVICE := 7

var w: LegionWorld
var _out := ""
var _frame := 0
var _log: Array[String] = []


## Глушит настоящие события мыши/клавиатуры (не наши device) — рука над окном не испортит запись.
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
		if _frame % 2 == 0:
			root.get_texture().get_image().save_png(
				_out.path_join("frames/f_%04d.png" % (_frame / 2)))


func _shot(name: String) -> void:
	await _tick(1)
	root.get_texture().get_image().save_png(_out.path_join(name))
	_log.append("%s кадр %d" % [name, _frame / 2])


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


func _man(c: Contract) -> void:
	for p in c.posts:
		if p["unit"] == null and not p["dead"]:
			var u := w.spawn_unit(c.kind, p["pos"])
			u.assign(c, p)
			u._arrive()


## Зомби идёт по дороге «Пустыря» вниз по x = 1000 и дальше к Котлу.
func _walker(at: Vector2) -> Foe:
	var path := PackedVector2Array([Vector2(1000, 480), Vector2(920, 540), Vector2(700, 540),
		Vector2(620, 460), Vector2(620, 240), Vector2(540, 180), Vector2(400, 180),
		Vector2(320, 260), Vector2(320, 400), Vector2(200, 400)])
	var f := w.spawn_foe_on_path("zombie", path, at)
	f.hp = 400.0
	f.max_hp = 400.0
	return f


func _still(at: Vector2) -> Foe:
	var f := w.spawn_foe_on_path("zombie", PackedVector2Array([at]), at)
	f.speed = 0.0
	f.hp = 400.0
	f.max_hp = 400.0
	return f


func _run() -> void:
	var argv := OS.get_cmdline_user_args()
	var i := argv.find("--out")
	_out = argv[i + 1] if i >= 0 and i + 1 < argv.size() else "user://sling_shots"
	DirAccess.make_dir_recursive_absolute(_out.path_join("frames"))
	Settings.scheme_override = Settings.SCHEME_SLING
	root.add_child(_Mute.new())
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	w = scene.instantiate() as LegionWorld
	root.add_child(w)
	await _tick(2)
	w.dev["no_waves"] = "1"
	w.dev["spawn_units"] = "0"
	w.start_map("wasteland")
	await _tick(90)   # вводный тост карты уходит
	var f := w.contracts
	# рубеж поперёк дороги: участок 0 — ровно на дороге (x 968–1032), стрелка — навстречу (вверх)
	var c := f.add_contract(PackedVector2Array([Vector2(968, 360), Vector2(1096, 360)]), 1, false)
	if c.dir.y > 0.0:
		c.flip_dir()
	_man(c)
	var a := _walker(Vector2(1000, 215))
	_walker(Vector2(994, 180))
	_walker(Vector2(1008, 150))
	_still(c.seg_center(1) + c.dir * 44.0)
	await _tick(20)

	# 1. Рогатка на участке 0: медленно тянем назад (вниз)
	var at := c.seg_center(0)
	await _move(at + Vector2(0, -2), 0)
	await _button(at, true)
	for k in range(1, 41):
		var to := at + Vector2(-4.0 * k / 40.0, 108.0 * k / 40.0)
		await _move(to)
		if k == 12:
			await _shot("ctl_01_pull_weak.png")
		if k == 40:
			await _shot("ctl_02_pull_strong.png")
	var held := 0
	while not bool(f.sling_aim().get("perfect", false)) and held < 200:
		await _tick(1)
		held += 1
	await _tick(6)
	await _shot("ctl_03_pull_gold.png")
	_log.append("золото через %d кадров удержания, Отсрочка %.0f, зомби y=%.0f" % [held, f.delay,
		a.position.y])
	await _button(at + Vector2(-4, 108), false)
	await _tick(3)
	await _shot("ctl_04_perfect_popup.png")
	var t := 0
	while w.combo < 1 and t < 120:
		await _tick(1)
		t += 1
	await _shot("ctl_05_impact.png")
	await _tick(8)

	# 2. Вторая рогатка — участок 1, оттяжка наискось: стрелка противоположна оттяжке
	var at1 := c.seg_center(1)
	await _move(at1, 0)
	await _button(at1, true)
	for k in range(1, 21):
		await _move(at1 + Vector2(40.0, 70.0) * (k / 20.0))
	await _shot("ctl_06_pull_diagonal.png")
	await _button(at1 + Vector2(40, 70), false)
	t = 0
	while w.combo < 2 and t < 150:
		await _tick(1)
		t += 1
	await _tick(4)
	await _shot("ctl_07_combo2.png")

	# 3. Третий натиск — щелчок по новому рубежу со строем и врагом перед ним: комбо ×3
	var c2 := f.add_contract(PackedVector2Array([Vector2(560, 470), Vector2(680, 470)]), 1, false)
	_man(c2)
	_still(c2.seg_center(0) + c2.dir * 40.0)
	await _tick(2)
	var at2 := c2.seg_center(0)
	await _move(at2, 0)
	await _button(at2, true)
	await _button(at2, false)
	t = 0
	while w.combo < 3 and t < 150:
		await _tick(1)
		t += 1
	await _tick(4)
	await _shot("ctl_08_combo3.png")
	await _tick(90)
	_log.append("комбо %d, точных %d, рогаткой %d, душ за комбо %d" % [w.combo,
		int(w.stats.get("perfect_releases", 0)), int(w.stats.get("sling_releases", 0)),
		int(w.stats.get("combo_souls", 0))])
	var log_file := FileAccess.open(_out.path_join("shots_log.txt"), FileAccess.WRITE)
	log_file.store_string("\n".join(_log) + "\n")
	for line in _log:
		print(line)
	Settings.scheme_override = ""
	quit(0)
