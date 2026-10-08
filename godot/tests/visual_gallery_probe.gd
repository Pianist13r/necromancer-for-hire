extends SceneTree
## Кадры движка: реальные бои бота, настройки и существующие эффекты на тестовой сцене.

var out := ""
var w: LegionWorld


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			out = arg.trim_prefix("--out=")
	assert(not out.is_empty())
	DirAccess.make_dir_recursive_absolute(out)
	Settings.use_dev_save("user://visual_gallery.cfg")
	Settings._cfg = ConfigFile.new()
	Settings.hints_override = "off"
	Campaign.set_save_path("user://visual_gallery.cfg")
	Campaign.reset()
	root.size = Vector2i(1920, 1080)
	root.content_scale_size = Vector2i(1280, 720)
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	w = (load("res://scenes/legion_world.tscn") as PackedScene).instantiate() as LegionWorld
	root.add_child(w)
	w.args["seed"] = "1008"
	w.args["bot"] = "selective"
	w.start_map("fork")
	w.set_process(false)
	for frame in 2400:
		w._process(1.0 / 60.0)
		await process_frame
		if frame in [599, 1199, 2399]:
			await shot("battle_%d" % frame)
	# Полная галочка настройки видна в настоящем ScrollContainer.
	var layer := CanvasLayer.new()
	layer.layer = 20
	root.add_child(layer)
	var screen := SettingsScreen.new()
	layer.add_child(screen)
	for i in 24:
		await process_frame
	var scroll := screen.find_child("SettingsScroll", true, false) as ScrollContainer
	scroll.scroll_vertical = 250
	await shot("settings")
	for id: String in ["Flashes", "ScreenShake", "WorldGrade"]:
		var check := screen.find_child(id, true, false) as CheckBox
		if check != null:
			check.button_pressed = false
	await shot("settings_off")
	layer.queue_free()
	var settings := Settings.new()
	for method: String in ["set_flashes", "set_screen_shake", "set_world_grade"]:
		if settings.has_method(method):
			settings.call(method, true)
	w.args.erase("bot")
	w.dev["no_waves"] = "1"
	w.dev["spawn_units"] = "0"
	for map_id: String in ["fork", "bridge", "gatehouse", "wasteland", "boss", "swamp",
			"archive", "maze"]:
		w.start_map(map_id)
		for i in 20:
			await process_frame
		await shot("cauldron_" + map_id)
		if map_id == "fork":
			await cauldron_motion()
			w.cauldron_hp = 30
			await shot("cauldron_low_hp")
	w.queue_free()
	await process_frame
	print("VISUAL GALLERY OK")
	quit()


func cauldron_motion() -> void:
	var frames: Array[Image] = []
	w.cauldron_hit.emit(20)
	for frame in 12:
		await process_frame
		await RenderingServer.frame_post_draw
		frames.append(root.get_texture().get_image())
	# Кодирование PNG после записи: оно не растягивает интервалы самой анимации.
	for frame in frames.size():
		var path := out.path_join("cauldron_motion_%02d.png" % frame)
		assert(frames[frame].save_png(path) == OK)
	assert(frames[3].save_png(out.path_join("cauldron_hit.png")) == OK)


func shot(label: String) -> void:
	await process_frame
	await RenderingServer.frame_post_draw
	var error := root.get_texture().get_image().save_png(out.path_join(label + ".png"))
	assert(error == OK)
