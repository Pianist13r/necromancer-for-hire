extends SceneTree
##
## Кадры приёмки «рогатка — сила сразу полная» (26.09, не тест гейта): натяжка НАСТОЯЩИМИ
## событиями мыши. Окном, не headless:
##
##   "$GODOT" --path godot --fixed-fps 60 --script res://tests/legion_sling_easy_shots.gd
##       -- --mute --out C:/AI/necro/batches/legion/sling
##
## Кадры 1280×720: натяжка вне зоны («Жди врага в зоне»), в зоне («Срывай!»), «Точно!» после
## отпускания, у верхнего края экрана (курсор упёрся в y = 0), кольцо. Настоящая мышь и клавиатура
## глушатся (_Mute), схема управления — только в памяти, сохранение — тестовый файл.
##

const DEVICE := 7
const SAVE := "user://legion_sling_easy_shots.cfg"

var w: LegionWorld
var _out := ""


## Глушит настоящие события мыши/клавиатуры (не наши device) — рука над окном не испортит кадр.
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
	await _tick(2)
	var img := root.get_texture().get_image()
	img.save_png(_out.path_join(name))
	print("%s %dx%d · %s" % [name, img.get_width(), img.get_height(), w.contracts.sling_hint()])


func _move(p: Vector2, mask: int = MOUSE_BUTTON_MASK_RIGHT) -> void:
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


func _pull(from: Vector2, to: Vector2, steps := 6) -> void:
	await _move(from, 0)
	await _button(from, MOUSE_BUTTON_RIGHT, true)
	for i in range(1, steps + 1):
		await _move(from.lerp(to, float(i) / steps))


func _man(c: Contract) -> void:
	for p in c.posts:
		if p["unit"] == null and not p["dead"]:
			var u := w.spawn_unit(c.kind, p["pos"])
			u.assign(c, p)
			u._arrive()


func _still(at: Vector2) -> Foe:
	var f := w.spawn_foe_on_path("zombie", PackedVector2Array([at]), at)
	f.speed = 0.0
	f.hp = 400.0
	f.max_hp = 400.0
	return f


func _line(a: Vector2, b: Vector2) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in 17:
		pts.append(a.lerp(b, i / 16.0))
	return pts


func _fresh() -> void:
	w.dev["no_waves"] = "1"
	w.dev["spawn_units"] = "0"
	w.start_map("_gray")
	w.contracts.mana = w.contracts.mana_max
	await _tick(90)   # вводный тост карты уходит


func _run() -> void:
	var argv := OS.get_cmdline_user_args()
	var i := argv.find("--out")
	_out = argv[i + 1] if i >= 0 and i + 1 < argv.size() else "user://sling_easy_shots"
	DirAccess.make_dir_recursive_absolute(_out)
	Campaign.set_save_path(SAVE)
	Settings.scheme_override = Settings.SCHEME_SLING
	root.add_child(_Mute.new())
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	w = scene.instantiate() as LegionWorld
	root.add_child(w)
	await _tick(2)
	await _fresh()
	var f := w.contracts
	# 1–3. Столбик в полосе между рекой и скалой, стрелка +x; враг сперва далеко
	var c := f.add_contract(_line(Vector2(760, 150), Vector2(760, 278)), 1, false)
	_man(c)
	var foe := _still(c.seg_center(0) + c.dir * 160.0)
	await _tick(10)
	var at := c.seg_center(0)
	var to := at - c.dir * 30.0 + Vector2(0, 4)
	await _pull(at, to)
	await _shot("sling_01_wait_out_of_zone.png")
	foe.position = c.seg_center(0) + c.dir * 70.0
	await _shot("sling_02_gold_in_zone.png")
	await _button(to, MOUSE_BUTTON_RIGHT, false)
	await _tick(4)
	await _shot("sling_03_perfect_after_release.png")
	# 4. Участок у правого края: курсор упёрся в x = 1279, оттяжка всего ~15 px (верхний край
	# закрыт полосой HUD — там проверка только в тесте)
	await _fresh()
	var edge := f.add_contract(_line(Vector2(1264, 300), Vector2(1264, 428)), 1, false)
	_man(edge)
	var efoe := _still(edge.seg_center(0) + Vector2(-150, 0))
	await _tick(10)
	var e0 := edge.seg_center(0)
	var pinned := Vector2(1279.0, e0.y + 3.0)
	await _pull(e0, pinned)
	await _shot("sling_04_edge_right_wait.png")
	efoe.position = edge.seg_center(0) + Vector2(-60, 0)
	await _shot("sling_05_edge_right_gold.png")
	await _button(pinned, MOUSE_BUTTON_RIGHT, false)
	await _tick(6)
	await _shot("sling_06_edge_right_released.png")
	# 6. Кольцо: короткая натяжка наружу — стрелки на всём круге полной длины
	await _fresh()
	var rc := Vector2(790.0, 330.0)
	var pts := PackedVector2Array()
	for k in 61:
		var a := -2.2 + (TAU - 0.3) * k / 60.0
		pts.append(rc + Vector2(cos(a), sin(a)) * 55.0)
	await _move(pts[0], 0)
	await _button(pts[0], MOUSE_BUTTON_LEFT, true)
	for k in range(1, pts.size()):
		await _move(pts[k], MOUSE_BUTTON_MASK_LEFT)
	await _button(pts[pts.size() - 1], MOUSE_BUTTON_LEFT, false)
	var ring: Contract = f.contracts[f.contracts.size() - 1] if not f.contracts.is_empty() else null
	if ring != null and ring.ring:
		_man(ring)
		_still(ring.seg_center(2).lerp(ring.center, 0.45))
		await _tick(70)   # всплывашка «Оцепление!» гаснет
		var r1 := ring.seg_center(1)
		await _pull(r1, r1 + (r1 - ring.center).normalized() * 30.0)
		await _shot("sling_07_ring.png")
		await _button(r1 + (r1 - ring.center).normalized() * 30.0, MOUSE_BUTTON_RIGHT, false)
	else:
		print("кольцо не вышло")
	Settings.scheme_override = ""
	quit(0)
