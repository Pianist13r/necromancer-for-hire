extends SceneTree
##
## Кадры приёмки пакета staff (не тест гейта): постройки на участках карты _plots и меню
## участка. Окном, не headless:
##
##   "$GODOT" --path godot --fixed-fps 60 --script res://tests/legion_staff_shots.gd
##       -- --mute --out C:/AI/necro/batches/legion/v15/staff
##

var w: LegionWorld


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var argv := OS.get_cmdline_user_args()
	var i := argv.find("--out")
	var out := argv[i + 1] if i >= 0 and i + 1 < argv.size() else "user://"
	DirAccess.make_dir_recursive_absolute(out)
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	w = scene.instantiate() as LegionWorld
	root.add_child(w)
	await process_frame
	w.dev["no_waves"] = "1"
	w.start_map("_plots")
	w.souls = 1000
	var st := w.staff
	var guard := st.build(st.plots[0], LegionCfg.KIND_GUARD)
	st.upgrade(guard)
	var shack := st.build(st.plots[1], LegionCfg.KIND_LABORER)
	st.upgrade(shack)
	st.upgrade(shack)
	st.build(st.plots[2], LegionCfg.KIND_CLERK)
	w.souls = 75
	w.souls_changed.emit(w.souls)
	for k in 40:
		w.spawn_foe("zombie", "north" if k % 2 == 0 else "south")
	for f in 420:
		await process_frame
	# убийство рядом — видно «+N»
	for f in w.foes:
		if f.alive and f.is_active():
			f.take_damage(1000.0, f.position)
			break
	var p4: Dictionary = st.plots[3]
	w.plot_menu.open(p4, p4["pos"])
	await _shot(out.path_join("staff_empty_plot_menu.png"))
	var p3: Dictionary = st.plots[2]
	w.plot_menu.open(p3, p3["pos"])
	await _shot(out.path_join("staff_building_menu.png"))
	w.plot_menu.close()
	await _shot(out.path_join("staff_buildings.png"))
	quit(0)


func _shot(path: String) -> void:
	for f in 6:
		await process_frame
	await RenderingServer.frame_post_draw
	var err := root.get_texture().get_image().save_png(path)
	print(JSON.stringify({"shot": path, "error": err}))
