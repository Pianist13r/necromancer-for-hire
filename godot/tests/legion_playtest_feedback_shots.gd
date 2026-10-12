extends SceneTree
## Reproducible visual acceptance of the optional pentagon guide in an actual campaign battle.
## Run with isolated APPDATA, --mute and --out <scratch directory>; never uses the owner's save.

var _out := ""
var _main: LegionMain


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var i := args.find("--out")
	if i >= 0 and i + 1 < args.size():
		_out = args[i + 1]
	_run.call_deferred()


func _run() -> void:
	if _out == "" or OS.get_user_data_dir().replace("\\", "/").contains("/AppData/Roaming/"):
		push_error("Need --out and isolated APPDATA")
		quit(2)
		return
	DisplayServer.window_set_size(Vector2i(1280, 720))
	DirAccess.make_dir_recursive_absolute(_out)
	Campaign.set_save_path("user://legion_playtest_feedback_shots.cfg")
	Campaign.reset()
	Campaign.unlock_all()
	_main = load("res://scenes/legion.tscn").instantiate() as LegionMain
	_main.process_mode = Node.PROCESS_MODE_ALWAYS
	root.add_child(_main)
	await _frames(3)
	_main.start_battle("maze")
	var deadline := Time.get_ticks_msec() + 60000
	while (_main.world == null or _main.world.is_ground_loading()
			or _main.world.tutorial == null) and Time.get_ticks_msec() < deadline:
		await process_frame
	if _main.world == null or _main.world.tutorial == null:
		push_error("campaign battle did not finish loading")
		quit(1)
		return
	await _frames(3)
	var w := _main.world
	w.tutorial.force_lesson(&"pentagon")
	var marks := w.tutorial._marks
	marks._process(0.016)
	marks._process(6.1)
	if not marks.shows_template() or marks.template_motion_active(marks._step_t) \
			or ContractShape.classify(w.tutorial.figure_points()) != ContractShape.PENTAGON:
		push_error("frozen tutorial pentagon is incomplete")
		quit(1)
		return
	await _frames(2)
	await _shot("00-frozen-template")
	w.set_paused(true)
	await _frames(3)
	_main._show_howto()
	await _frames(2)
	var howto := _main.find_child("HowtoLegion", true, false) as HowtoLegion
	if howto == null:
		for child in _main.get_children():
			if child is HowtoLegion:
				howto = child
	var button := howto.find_child("HowtoPentagonHelp", true, false) as Button
	if button == null:
		push_error("pentagon help button missing")
		quit(1)
		return
	button.grab_focus()
	await _frames(5)
	await _shot("00-howto")
	button.pressed.emit()
	await _frames(3)
	var field := w.contracts
	var guide := field.pentagon_guide
	var spot := _find_guide_spot(guide)
	print("GUIDE SPOT ", spot, " radius ", guide.radius)
	guide.follow(spot)
	await _frames(3)
	if w.tutorial._marks.shows_template():
		push_error("tutorial pentagon duplicated during guide")
		quit(1)
		return
	await _shot("01-floating")
	var escape := InputEventKey.new()
	escape.keycode = KEY_ESCAPE
	escape.pressed = true
	field._input(escape)
	if not w.tutorial._marks.shows_template():
		push_error("tutorial pentagon did not return after Esc")
		quit(1)
		return
	await _frames(2)
	await _shot("01b-esc-restored")
	field.start_pentagon_guide()
	guide.follow(spot)
	var click := InputEventMouseButton.new()
	click.button_index = MouseBind.physical(&"draw")
	click.position = w.world_to_screen(spot)
	click.pressed = true
	field._unhandled_input(click)
	click.pressed = false
	field._unhandled_input(click)
	await _frames(3)
	await _shot("02-anchored")
	var pts := LegionLessonBot.template("pentagon", guide.center, guide.radius)
	field.begin(pts[0])
	for k in range(1, pts.size() - 12):
		field.extend(pts[k])
	await _frames(3)
	await _shot("03-stroke")
	for k in range(pts.size() - 12, pts.size()):
		field.extend(pts[k])
	field.finish()
	await _frames(3)
	await _shot("04-result")
	guide.stop()
	await _frames(2)
	await _shot("05-off")
	quit(0)


func _frames(n: int) -> void:
	for _i in n:
		await process_frame


func _find_guide_spot(guide: LegionPentagonGuide) -> Vector2:
	for r: float in [85.0, 75.0, 65.0]:
		guide.radius = r
		for y in range(460, 139, -30):
			for x in range(200, 1101, 30):
				guide.follow(Vector2(x, y))
				if guide.placement_valid():
					return guide.center
	return Vector2.INF


func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := root.get_texture().get_image()
	if img.get_size() != Vector2i(1280, 720):
		img.resize(1280, 720, Image.INTERPOLATE_LANCZOS)
	var path := _out.path_join(name + ".png")
	if img.save_png(path) != OK:
		push_error("save failed: " + path)
	print("SHOT ", path)
