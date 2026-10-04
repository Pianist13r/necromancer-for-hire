extends SceneTree
## Кадры HUD «Схватки» для приёмки (P5c) — только в окне, не headless (нужен GPU):
##   "$GODOT" --path godot --fixed-fps 60 --resolution 1280x720 --script res://tests/pvp_hud_shots.gd
##       -- --mute --out C:/AI/necro/batches/legion/pvp-0929/p5c/after [--seed 3]
## Кадры: duel_start (60-я секунда до волны), duel_fight (драка, оба бота), result_win /
## result_lose / result_draw (экран итога), single (одиночка для контроля: HUD прежний).
## «Ещё раз» на итоге жмётся настоящим сигналом кнопки.

var w: LegionWorld
var out := ""
var failed := false


func _initialize() -> void:
	_run.call_deferred()


func _arg(name: String, default: String) -> String:
	var argv := OS.get_cmdline_user_args()
	var pos := argv.find(name)
	return argv[pos + 1] if pos >= 0 and pos + 1 < argv.size() else default


func _run() -> void:
	out = _arg("--out", "user://pvp-hud")
	DirAccess.make_dir_recursive_absolute(out)
	var seed_n := int(_arg("--seed", "3"))
	Campaign.set_save_path("user://pvp_hud_shots.cfg")
	Campaign.reset()
	w = (load("res://scenes/legion_world.tscn") as PackedScene).instantiate() as LegionWorld
	w.embedded = true
	root.add_child(w)
	await process_frame
	w.args["pvp_bots"] = true
	w._base_seed = seed_n
	w.start_map("pvp:duel")
	await _until(2.0)
	await _shot("duel_start")
	await _until(100.0)
	await _shot("duel_fight")
	w.surrender(1)
	await _shot("result_win")
	w.hud.pvp_result.button("Ещё раз").pressed.emit()
	await _until(3.0)
	print("PVP_HUD restart open=%s now=%.1f" % [w.hud.pvp_result.is_open(), w.now])
	w.surrender(0)
	await _shot("result_lose")
	w.hud.pvp_result.button("Ещё раз").pressed.emit()
	await _until(3.0)
	w.pvp_match.limit = w.now + 0.5
	await _until(w.now + 1.5)
	await _shot("result_draw")
	await _draft_shot()
	w.start_map("wasteland")
	await _until(3.0)
	await _shot("single")
	w.queue_free()
	await process_frame
	Campaign.reset()
	print("PVP_HUD_SHOTS exit%d" % (1 if failed else 0))
	quit(1 if failed else 0)


## Ждать, пока время боя мира не дойдёт до t секунд (мир идёт сам, кадр = 1/60 с при --fixed-fps).
func _until(t: float) -> void:
	var guard := 0
	while w.now < t and guard < 60000:
		await process_frame
		guard += 1


func _shot(name: String) -> void:
	await process_frame
	await RenderingServer.frame_post_draw
	var picture := root.get_texture().get_image()
	if picture == null or picture.is_empty():
		failed = true
		push_error("PVP_HUD_SHOTS empty GPU frame")
		return
	failed = picture.save_png(out.path_join(name + ".png")) != OK or failed
	print("PVP_HUD_SHOT " + name)


## B-303: подпись «наберёт N / мест M» у черновика в PvP — на экране прежнего размера.
func _draft_shot() -> void:
	w.args.erase("pvp_bots")
	w.dev = {"no_waves": "1", "pvp_nobot": "1"}
	w.start_map("pvp:duel")
	await _until(3.0)
	var a := Vector2(580.0, 150.0)
	var pts: Array[Vector2] = []
	for i in 11:
		pts.append(a + Vector2(0.0, 15.0 * i))
	_click(a, true)
	for p in pts:
		_move(p)
		await process_frame
	await _shot("draft")
	_click(pts[pts.size() - 1], false)
	await process_frame


## Мышь в точке МИРА: мир → экран (world_to_screen) → окно (растяжение canvas_items).
func _window(world_p: Vector2) -> Vector2:
	return root.get_final_transform() * w.world_to_screen(world_p)


func _move(world_p: Vector2) -> void:
	var m := InputEventMouseMotion.new()
	m.button_mask = MOUSE_BUTTON_MASK_LEFT
	m.position = _window(world_p)
	m.global_position = m.position
	Input.parse_input_event(m)


func _click(world_p: Vector2, down: bool) -> void:
	var b := InputEventMouseButton.new()
	b.button_index = MOUSE_BUTTON_LEFT
	b.pressed = down
	b.button_mask = MOUSE_BUTTON_MASK_LEFT if down else 0
	b.position = _window(world_p)
	b.global_position = b.position
	Input.parse_input_event(b)
