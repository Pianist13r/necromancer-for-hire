extends SceneTree
## Кадры приёмки «линии сторон отличаются оттенком» (slow/pvp-line-tints): дуэль, у каждой
## стороны по договору каждого вида, одноимённые — рядом по строкам (слева сторона 0, справа 1).
## host — экран стороны 0 (против бота / хост): сдвинуты линии справа; client — экран стороны 1:
## сдвинуты линии слева. Полная и экономная графика. Только GPU (не headless).
##   "$GODOT" --path godot --position -3000,-3000 --script res://tests/pvp_line_tints_shots.gd
##       -- --mute --out C:/AI/necro/batches/pvp-tints-1010
const KINDS: Array[StringName] = [&"laborer", &"guard", &"clerk"]
const ROWS: Array[float] = [330.0, 450.0, 570.0]
var w: LegionWorld
var out := ""
var failed := false


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var argv := OS.get_cmdline_user_args()
	var pos := argv.find("--out")
	out = argv[pos + 1] if pos >= 0 and pos + 1 < argv.size() else "user://pvp-line-tints"
	DirAccess.make_dir_recursive_absolute(out)
	Campaign.set_save_path("user://pvp_line_tints_shots.cfg")
	Campaign.reset()
	root.size = Vector2i(1280, 720)
	root.content_scale_size = Vector2i(1600, 900)
	w = (load("res://scenes/legion_world.tscn") as PackedScene).instantiate() as LegionWorld
	w.embedded = true
	root.add_child(w)
	await process_frame
	for mode in ["full", "economy"]:
		Settings.economy_override = "on" if mode == "economy" else "off"
		w._sync_gfx_layers()
		_prepare()
		for i in 40:   # рождение линий (CfgLines.BIRTH_T) отыграло — линии в покое
			w._step(1.0 / 60.0)
			await process_frame
		w.local_side = 0
		await _shot(mode + "-host")
		w.local_side = 1   # как у клиента сети: своё поле — 1
		await _shot(mode + "-client")
		w.local_side = 0
	Settings.economy_override = ""
	w.queue_free()
	await process_frame
	Campaign.reset()
	print("PVP_LINE_TINTS_SHOTS exit%d" % (1 if failed else 0))
	quit(1 if failed else 0)


func _prepare() -> void:
	seed(1010)
	w.args.erase("pvp_bots")
	w.dev = {"pvp_nobot": "1", "no_waves": "1", "spawn_units": "0"}
	w._base_seed = 1010
	w.start_map("pvp:duel")
	w.set_process(false)
	for side in w.sides:
		for i in KINDS.size():
			var x0 := 560.0 if side.index == 0 else 830.0
			var pts := PackedVector2Array()
			for j in 12:
				pts.append(Vector2(x0 + j * 20.0, ROWS[i] + sin(j * 0.7) * 8.0))
			var c := side.contracts.add_contract(pts, 1, false, KINDS[i])
			if c == null:
				failed = true
				push_error("PVP_LINE_TINTS_SHOTS no contract side %d %s" % [side.index, KINDS[i]])
	w.queue_redraw()


func _shot(name: String) -> void:
	for side in w.sides:
		side.contracts.queue_redraw()
		side.contracts.overlay.queue_redraw()
	await process_frame
	await RenderingServer.frame_post_draw
	var picture := root.get_texture().get_image()
	if picture == null or picture.is_empty():
		failed = true
		push_error("PVP_LINE_TINTS_SHOTS empty GPU frame")
		return
	failed = picture.save_png(out.path_join(name + ".png")) != OK or failed
	var crop := picture.get_region(Rect2i(400, 220, 480, 280))
	failed = crop.save_png(out.path_join(name + "-crop.png")) != OK or failed
	print("PVP_LINE_TINTS_SHOT " + name)
