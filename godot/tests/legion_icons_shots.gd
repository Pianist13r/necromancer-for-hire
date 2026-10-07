extends SceneTree
##
## Одноразовые кадры приёмки иконок (генерация 06.10.2026) — не тест гейта. Окном, не headless:
##
##   "$GODOT" --path godot --fixed-fps 60 --resolution 1280x720
##       --script res://tests/_agent_icons_shots.gd -- --mute --out <dir>
##
## Боевой кадр: способности открыты (Campaign.unlock_all), своя армия, враги в волне, выданные
## предметы — видно плашку HUD, панель навыков Q/W/E/R и полоску предметов. Сохранение — свой
## файл, user://legion.cfg владельца не читается и не пишется.
##

const SAVE := "user://agent_icons_shots.cfg"

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
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	w = scene.instantiate() as LegionWorld
	w.in_campaign = true
	root.add_child(w)
	await process_frame
	w.start_map("fork")
	w.dev_invuln = true
	for f in 150:
		await process_frame
	for k in 6:
		w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(520.0 + 20.0 * float(k), 470.0))
	w.souls = 64
	w.souls_changed.emit(w.souls)
	for id in [&"wholesale_ink", &"megaphone", &"lightning_rod", &"clip_of_fate"]:
		w.items.grant(id)
	for f in 260:
		await process_frame
	await _shot("battle_hud.png")
	Campaign.reset()
	quit(0)


func _shot(file: String) -> void:
	for f in 3:
		await process_frame
	await RenderingServer.frame_post_draw
	var path := out.path_join(file)
	var err := root.get_texture().get_image().save_png(path)
	print(JSON.stringify({"shot": path, "error": err}))
