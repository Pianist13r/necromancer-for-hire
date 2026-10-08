extends SceneTree
## Рендерный зонд: mobile, фиксированный seed/шаг, реальные интервалы кадров без VSync.
## -- --mute --out=<каталог> --count=300; только изолированный APPDATA.

var out := ""
var count := 300
var frames := PackedFloat64Array()
var steps := PackedFloat64Array()


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			out = arg.trim_prefix("--out=")
		if arg.begins_with("--count="):
			count = int(arg.trim_prefix("--count="))
	assert(not out.is_empty())
	DirAccess.make_dir_recursive_absolute(out)
	Settings.use_dev_save("user://visual_probe.cfg")
	Settings._cfg = ConfigFile.new()
	Settings.economy_override = "off"
	Settings.hints_override = "off"
	Campaign.set_save_path("user://visual_probe.cfg")
	Campaign.reset()
	root.size = Vector2i(1920, 1080)
	root.content_scale_size = Vector2i(1280, 720)
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var w := (load("res://scenes/legion_world.tscn") as PackedScene).instantiate() as LegionWorld
	root.add_child(w)
	w.args["seed"] = "1008"
	w.dev["no_waves"] = "1"
	w.dev["spawn_units"] = "0"
	w.start_map("fork")
	w.dev_invuln = true
	w.set_process(false)
	var places: Array[Vector2] = []
	for i in count:
		w._spawn_bench_foe(i)
		places.append(w.foes[-1].position)
	for i in 24:
		var kind: StringName = [LegionCfg.KIND_LABORER, LegionCfg.KIND_GUARD,
			LegionCfg.KIND_CLERK][i % 3]
		w.spawn_unit(kind, Vector2(570 + (i % 8) * 22, 330 + (i / 8) * 28))
	var fx := w.get_node_or_null("LegionFx") as LegionFx
	if fx != null:
		fx.rng.seed = 1008
		fx.impact.rng.seed = 1008
	var last := Time.get_ticks_usec()
	for frame in 780:
		# Постоянная нагрузка: настоящие шаги/поиск целей, без исчезновения толпы к концу.
		for i in count:
			w.foes[i].position = places[i]
			w.foes[i].hp = 1000000.0
		for u in w.units:
			u.hp = 1000000.0
		var started := Time.get_ticks_usec()
		w._step(1.0 / 60.0)
		var step_ms := (Time.get_ticks_usec() - started) / 1000.0
		await process_frame
		await RenderingServer.frame_post_draw
		var now := Time.get_ticks_usec()
		if frame >= 180:
			frames.append((now - last) / 1000.0)
			steps.append(step_ms)
		last = now
		if frame == 179:
			root.get_texture().get_image().save_png(out.path_join("crowd.png"))
			last = Time.get_ticks_usec()  # запись PNG относится к прогреву, не к замеру.
	var result := {"frames": stats(frames), "world_step": stats(steps), "foes": w.active_foes(),
		"resolution": [root.size.x, root.size.y],
		"renderer": RenderingServer.get_current_rendering_method(),
		"gpu": RenderingServer.get_video_adapter_name(), "version": Engine.get_version_info(),
		"samples": frames.size(), "raw_frame_ms": Array(frames)}
	var file := FileAccess.open(out.path_join("performance.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(result, "\t"))
	file.close()
	print("VISUAL PROBE ", JSON.stringify({"frames": result.frames, "world_step": result.world_step}))
	w.queue_free()
	await process_frame
	quit()


func stats(values: PackedFloat64Array) -> Dictionary:
	var sorted := values.duplicate()
	sorted.sort()
	var sum := 0.0
	for value in sorted:
		sum += value
	return {"mean_ms": sum / sorted.size(), "p99_ms": sorted[ceili(sorted.size() * 0.99) - 1]}
