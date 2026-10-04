extends SceneTree
##
## Кадры приёмки прицела Ку/Дубль-вэ/Е и подписей каста (медленная сессия clarity, 26.09.2026;
## не тест гейта). Окном, не headless (headless кадр не снимает), игровой масштаб 1280×720:
##
##   "$GODOT" --path godot --fixed-fps 60 --resolution 1280x720
##       --script res://tests/legion_ability_aim_shots.gd -- --mute --out C:/AI/necro/batches/legion/clarity
##
## Ввод — настоящий (Input.parse_input_event): клавиша зажата — кадр прицела, отпущена — кадр
## подписей «что произошло». Сохранение — свой файл, user://legion.cfg владельца не трогаем.
##

const SAVE := "user://legion_ability_aim_shots.cfg"
const P := Vector2(640, 300)

var w: LegionWorld
var out := ""


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var argv := OS.get_cmdline_user_args()
	var i := argv.find("--out")
	out = argv[i + 1] if i >= 0 and i + 1 < argv.size() else "user://"
	DirAccess.make_dir_recursive_absolute(out)
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	Campaign.unlock_all()
	Input.use_accumulated_input = false
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	w = scene.instantiate() as LegionWorld
	w.in_campaign = true
	root.add_child(w)
	await process_frame
	w.dev["no_waves"] = "1"
	w.dev["spawn_units"] = "0"
	w.start_map("fork")
	for f in 30:
		await process_frame
	await _q_shots()
	await _w_shots()
	await _e_shots()
	await _pause_shot()
	Campaign.reset()
	quit(0)


func _move(p: Vector2) -> void:
	var m := InputEventMouseMotion.new()
	m.position = root.get_final_transform() * p
	m.global_position = m.position
	Input.parse_input_event(m)
	await process_frame


func _key(code: Key, pressed: bool) -> void:
	var k := InputEventKey.new()
	k.physical_keycode = code
	k.keycode = code
	k.pressed = pressed
	Input.parse_input_event(k)
	await process_frame


func _still_foe(type: String, at: Vector2) -> Foe:
	var f := w.spawn_foe_on_path(type, PackedVector2Array([at]), at)
	f.speed = 0.0
	return f


func _shot(file: String, frames := 3) -> void:
	for f in frames:
		await process_frame
	await RenderingServer.frame_post_draw
	var path := out.path_join(file)
	var err := root.get_texture().get_image().save_png(path)
	print(JSON.stringify({"shot": path, "error": err}))


func _q_shots() -> void:
	# кучка у курсора и двое поодаль — цепь перескакивает к ближайшим
	var at := P
	for off: Vector2 in [Vector2(0, 0), Vector2(40, 16), Vector2(-36, 24), Vector2(80, -30),
			Vector2(150, 40), Vector2(-170, -60)]:
		_still_foe("zombie", at + off)
	await _move(at + Vector2(12, 6))
	await _key(KEY_Q, true)
	await _shot("aim_q.png")
	await _key(KEY_Q, false)
	await _shot("cast_q.png", 12)
	# сразу ещё раз — откат: отказ у курсора
	await _key(KEY_Q, true)
	await _shot("aim_q_cooldown.png")
	await _key(KEY_Q, false)
	await _shot("fail_q_cooldown.png", 6)
	for f in w.foes:
		f.take_damage(100000.0, f.position + Vector2.RIGHT)
	for f in 20:
		await process_frame


func _w_shots() -> void:
	var at := Vector2(360, 480)
	var corpse := _still_foe("beetle", at)
	var other := _still_foe("zombie", at + Vector2(52, -8))
	corpse.take_damage(100000.0, corpse.position + Vector2.RIGHT)
	other.take_damage(100000.0, other.position + Vector2.RIGHT)
	for f in 40:
		await process_frame
	await _move(at + Vector2(-14, 10))
	await _key(KEY_W, true)
	await _shot("aim_w.png")
	await _key(KEY_W, false)
	await _shot("cast_w.png", 10)
	await _move(Vector2(1000, 560))
	await _key(KEY_W, true)
	await _shot("aim_w_empty.png")
	await _key(KEY_W, false)


func _e_shots() -> void:
	var at := Vector2(900, 330)
	for k in 6:
		w.spawn_unit(LegionCfg.KIND_LABORER, at + Vector2.from_angle(k * 1.1) * (40.0 + 25.0 * k))
	w.spawn_unit(LegionCfg.KIND_LABORER, at + Vector2(LegionCfg.E_RADIUS + 50.0, 20.0))
	for f in 10:
		await process_frame
	await _move(at)
	await _key(KEY_E, true)
	await _shot("aim_e.png")
	await _key(KEY_E, false)
	await _shot("cast_e.png", 10)


func _pause_shot() -> void:
	var pause := LegionPause.new()
	var layer := CanvasLayer.new()
	layer.layer = 20
	root.add_child(layer)
	layer.add_child(pause)
	await _shot("pause_cheatsheet.png", 4)
	layer.queue_free()
	var howto := HowtoLegion.new()
	var layer2 := CanvasLayer.new()
	layer2.layer = 20
	root.add_child(layer2)
	layer2.add_child(howto)
	await _shot("howto_top.png", 4)
	# «Как играть» — длинная прокрутка: опускаем к строкам про способности
	var sc: ScrollContainer = null
	for n in howto.find_children("*", "ScrollContainer", true, false):
		sc = n as ScrollContainer
	if sc != null:
		for n in howto.find_children("*", "Label", true, false):
			var l := n as Label
			if l.text.begins_with("Q/W/E"):
				sc.scroll_vertical = int(l.get_global_rect().position.y - sc.get_global_rect().position.y) - 40
				break
	await _shot("howto_abilities.png", 4)
