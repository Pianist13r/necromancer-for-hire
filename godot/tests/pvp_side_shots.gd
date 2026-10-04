extends SceneTree
## GPU-only visual acceptance fixture; no headless. CPU preparation is not a passed capture.
## -- --mute --out C:/AI/necro/batches/pvp-side-look
const DEVICE := 7
const KINDS: Array[StringName] = [&"laborer", &"guard", &"clerk"]
const CENTER := Vector2(800, 245)
var w: LegionWorld
var out := ""
var failed := false


class _Mute:
	extends Node

	func _input(event: InputEvent) -> void:
		if event.device != DEVICE and (event is InputEventMouse or event is InputEventKey):
			get_viewport().set_input_as_handled()


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var argv := OS.get_cmdline_user_args()
	var pos := argv.find("--out")
	out = argv[pos + 1] if pos >= 0 and pos + 1 < argv.size() else "user://pvp-side-look"
	DirAccess.make_dir_recursive_absolute(out)
	Campaign.set_save_path("user://pvp_side_shots.cfg")
	Campaign.reset()
	root.size = Vector2i(1280, 720)
	root.content_scale_size = Vector2i(1600, 900)
	root.add_child(_Mute.new())
	w = (load("res://scenes/legion_world.tscn") as PackedScene).instantiate() as LegionWorld
	w.embedded = true
	root.add_child(w)
	await process_frame
	w.set_process(false)
	for mode in ["full", "economy"]:
		Settings.economy_override = "on" if mode == "economy" else "off"
		w._sync_gfx_layers()
		_prepare()
		await _shot(mode + "-plain")
		_artifacts_and_haste()
		for i in 3:
			w._step(1.0 / 60.0)
			await process_frame
		await _shot(mode + "-artifacts-e")
		for side in w.sides:
			side.hero._end_haste()
		if w.gfx_fx() != null:
			w.gfx_fx().impact._tick_haste(0.2)
		await _shot(mode + "-after-e")
	Settings.economy_override = ""
	w.queue_free()
	await process_frame
	Campaign.reset()
	print("PVP_SIDE_SHOTS exit%d" % (1 if failed else 0))
	quit(1 if failed else 0)


func _prepare() -> void:
	seed(7140)
	w.args.erase("pvp_bots")
	w.dev = {"pvp_nobot": "1", "no_waves": "1", "spawn_units": "0"}
	w._base_seed = 7140
	w.start_map("pvp:duel")
	w.set_process(false)
	for side in w.sides:
		side.souls = 10000
		for i in KINDS.size():
			side.staff.build(side.staff.plots[i], KINDS[i])
		# Pairs of equal professions interleaved; owner is not inferable from profession.
		for row in 3:
			for col in 4:
				var at := CENTER + Vector2((col * 2 + side.index - 3.5) * 22, (row - 1) * 36)
				var unit := w.spawn_unit(KINDS[row], at, null, side.index)
				unit.hp = 2000.0
				unit.max_hp = unit.hp
				unit.queue_redraw()
		side.hero._vis_rng.seed = 7140 + side.index
	if w.gfx_fx() != null:
		w.gfx_fx().rng.seed = 7140
		w.gfx_fx().impact.rng.seed = 7140
	w.queue_redraw()


func _artifacts_and_haste() -> void:
	for side in w.sides:
		for id in ["exploding_stamp", "burning_seal", "staff_schedule", "overtime_sheet",
				"cauldron_ward", "clip_of_fate", "lightning_rod"]:
			side.items.grant(StringName(id))
		side.hero.cast(LegionHero.SLOT_E, CENTER)
		side.hero.cast(LegionHero.SLOT_Q, CENTER)
		for unit in w.units:
			if unit.side == side.index:
				unit.queue_redraw()


func _shot(name: String) -> void:
	await process_frame
	await RenderingServer.frame_post_draw
	var picture := root.get_texture().get_image()
	if picture == null or picture.is_empty():
		failed = true
		push_error("PVP_SIDE_SHOTS empty GPU frame")
		return
	failed = picture.save_png(out.path_join(name + ".png")) != OK or failed
	var crop := picture.get_region(Rect2i(470, 95, 340, 210))
	failed = crop.save_png(out.path_join(name + "-mixed-crop.png")) != OK or failed
	picture.convert(Image.FORMAT_L8)
	failed = picture.save_png(out.path_join(name + "-gray.png")) != OK or failed
	print("PVP_SIDE_SHOT " + name)
