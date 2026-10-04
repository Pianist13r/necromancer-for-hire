extends SceneTree
##
## Кадры приёмки «Оцепления» (не тест гейта): кольцо чертится и сжимается НАСТОЯЩИМИ событиями
## мыши (Input.parse_input_event в координатах окна) на карте _gray. Окном, не headless:
##
##   "$GODOT" --path godot --fixed-fps 60 --script res://tests/legion_ring_shots.gd
##       -- --mute --out C:/AI/necro/batches/legion/ring
##
## Кадры: 1_draft_hint.png — черновик замкнулся, подсказка «Оцепление» у курсора;
## 2_ring_posted.png — кольцо с бойцами вокруг кучки врагов; 3_sling.png — натяжка по участку
## (стрелки на всём круге);
## 4_squeeze.png — миг «Сжать кольцо!»; 5_squeeze_0.4s.png — через 0,4 с.
## Настоящая мышь и клавиатура владельца на время прогона глушатся (_Mute), схема управления —
## только в памяти (Settings.scheme_override).
##

const DEVICE := 7
const RC := Vector2(1120.0, 400.0)
const RR := 58.0

var w: LegionWorld
var _out := ""


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


func _still(at: Vector2) -> Foe:
	var f := w.spawn_foe_on_path("zombie", PackedVector2Array([at]), at)
	f.speed = 0.0
	f.hp = 400.0
	f.max_hp = 400.0
	return f


func _run() -> void:
	var argv := OS.get_cmdline_user_args()
	var i := argv.find("--out")
	_out = argv[i + 1] if i >= 0 and i + 1 < argv.size() else "user://ring_shots"
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
	await _tick(90)   # вводный тост карты уходит
	w.dev_invuln = true
	for off: Vector2 in [Vector2(-14, -8), Vector2(12, -12), Vector2(0, 10), Vector2(-20, 14),
			Vector2(18, 12)]:
		_still(RC + off)
	# кольцо рукой: неровный круг против часовой, конец чуть не дотянут
	var pts := PackedVector2Array()
	var n := 64
	for k in n + 1:
		var a := -2.2 + (TAU - 0.3) * float(k) / n
		var r := RR * (1.0 + 0.04 * sin(a * 3.0 + 0.7))
		pts.append(RC + Vector2(cos(a) * r, sin(a) * (r - 4.0)))
	w.contracts.mana = w.contracts.mana_max
	await _move(pts[0], 0)
	await _button(pts[0], MOUSE_BUTTON_LEFT, true)
	for k in range(1, pts.size()):
		await _move(pts[k], MOUSE_BUTTON_MASK_LEFT)
	w.contracts.update_preview()
	await _shot("1_draft_hint.png")
	await _button(pts[pts.size() - 1], MOUSE_BUTTON_LEFT, false)
	var c: Contract = w.contracts.contracts[w.contracts.contracts.size() - 1]
	print("кольцо: ", c.ring, " участков ", c.seg_count(), " мест ", c.posts.size())
	for p in c.posts:
		if p["unit"] == null and not p["dead"]:
			var u := w.spawn_unit(c.kind, p["pos"])
			u.assign(c, p)
			u._arrive()
	await _tick(80)   # надпись «Оцепление!» догорает, строй стоит
	await _shot("2_ring_posted.png")
	# тянем за левый участок: подпись силы у курсора остаётся в кадре (кольцо у правого края)
	var at := c.seg_center(0)
	for s in c.seg_count():
		if c.seg_center(s).x < at.x:
			at = c.seg_center(s)
	var away := (at - c.center).normalized()
	await _move(at, 0)
	await _button(at, MOUSE_BUTTON_RIGHT, true)
	for k in range(1, 11):
		await _move(at + away * 95.0 * float(k) / 10.0, MOUSE_BUTTON_MASK_RIGHT)
	await _shot("3_sling.png")
	await _button(at + away * 95.0, MOUSE_BUTTON_RIGHT, false)
	await _tick(2)
	await _shot("4_squeeze.png")
	await _tick(22)   # ~0,4 с при 60 к/с
	await _shot("5_squeeze_0.4s.png")
	Settings.scheme_override = ""
	quit(0)
