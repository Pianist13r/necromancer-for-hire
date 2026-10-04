extends SceneTree
## Кадры входа в «Схватку» из меню для приёмки (P6) — только в окне, не headless (нужен GPU):
##   "$GODOT" --path godot --fixed-fps 60 --resolution 1280x720 --script res://tests/pvp_menu_shots.gd
##       -- --mute --out C:/AI/necro/batches/legion/pvp-0929/p6/frames
## Кадры: menu, select, match_start, match_esc (меню боя), result (после сдачи), menu_after.
## Всё нажимается сигналом pressed настоящих кнопок; сохранение — временный файл.

var main: LegionMain
var out := ""
var failed := false


func _initialize() -> void:
	_run.call_deferred()


func _arg(name: String, default: String) -> String:
	var argv := OS.get_cmdline_user_args()
	var pos := argv.find(name)
	return argv[pos + 1] if pos >= 0 and pos + 1 < argv.size() else default


func _run() -> void:
	out = _arg("--out", "user://pvp-menu")
	DirAccess.make_dir_recursive_absolute(out)
	Campaign.set_save_path("user://pvp_menu_shots.cfg")
	Campaign.reset()
	Campaign.set_intro_cutscene_seen()
	main = (load("res://scenes/legion.tscn") as PackedScene).instantiate() as LegionMain
	root.add_child(main)
	await _frames(30)
	await _shot("menu")
	(main.screen.find_child("PvpAction", true, false) as Button).pressed.emit()
	await _frames(20)
	await _shot("select")
	(main.screen.find_child("PvpFieldRandom", true, false) as Button).pressed.emit()
	await _frames(90)
	await _shot("match_start_random")
	main.world.command(0, PvpCmd.surrender())
	await _frames(30)
	main.world.hud.pvp_result.button("В меню").pressed.emit()
	await _frames(10)
	(main.screen.find_child("PvpAction", true, false) as Button).pressed.emit()
	await _frames(5)
	(main.screen.find_child("PvpFieldDuel", true, false) as Button).pressed.emit()
	await _frames(120)
	await _shot("match_start")
	var ev := InputEventAction.new()
	ev.action = &"pause"
	ev.pressed = true
	Input.parse_input_event(ev)
	await _frames(10)
	await _shot("match_esc")
	for b in main.world.pvp_menu.find_children("*", "Button", true, false):
		if (b as Button).text == "Сдаться":
			(b as Button).pressed.emit()
	await _frames(5)
	for b in main.world.pvp_menu.find_children("*", "Button", true, false):
		if (b as Button).text == "Да, сдаюсь":
			(b as Button).pressed.emit()
	await _frames(30)
	await _shot("result")
	main.world.hud.pvp_result.button("В меню").pressed.emit()
	await _frames(15)
	await _shot("menu_after")
	Campaign.reset()
	print("PVP_MENU_SHOTS exit%d" % (1 if failed else 0))
	quit(1 if failed else 0)


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _shot(name: String) -> void:
	await process_frame
	await RenderingServer.frame_post_draw
	var picture := root.get_texture().get_image()
	if picture == null or picture.is_empty():
		failed = true
		push_error("PVP_MENU_SHOTS empty GPU frame")
		return
	failed = picture.save_png(out.path_join(name + ".png")) != OK or failed
