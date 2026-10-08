extends SceneTree
## Только настоящий рендер меню; сохранение и настройки — в APPDATA стенда.


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	Settings.path = "user://tutorial_1008_shots_settings.cfg"
	Settings._cfg = ConfigFile.new()
	Campaign.set_save_path("user://tutorial_1008_shots.cfg")
	Campaign.reset()
	root.size = Vector2i(1280, 720)
	var packed: PackedScene = load("res://scenes/legion.tscn")
	var main := packed.instantiate() as LegionMain
	root.add_child(main)
	for i in 20:
		await process_frame
	await RenderingServer.frame_post_draw
	var out := ProjectSettings.globalize_path("res://../batches/tutorial-1008/frames/menu-final.png")
	root.get_texture().get_image().save_png(out)
	var exit_button := main.screen.find_child("QuitAction", true, false) as Button
	var fits := exit_button != null and exit_button.get_global_rect().end.y <= 720.0
	print("TUTORIAL MENU FITS: ", fits)
	Controls.rebind(&"cast_q", KEY_Z)
	var pause := LegionPause.new()
	root.add_child(pause)
	pause._show_keys()
	for i in 6:
		await process_frame
	await RenderingServer.frame_post_draw
	out = ProjectSettings.globalize_path("res://../batches/tutorial-1008/frames/keys-final.png")
	root.get_texture().get_image().save_png(out)
	quit(0 if fits else 1)
