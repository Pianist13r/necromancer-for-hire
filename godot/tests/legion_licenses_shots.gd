extends SceneTree
## Оконная приёмка минимального окна и фокуса игрового контроллера.


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	Settings.path = "user://licenses_shots.cfg"
	Settings._cfg = null
	AudioServer.set_bus_mute(0, true)
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.content_scale_size = Vector2i.ZERO
	root.size = Vector2i(960, 540)
	var args := OS.get_cmdline_user_args()
	var index := args.find("--out")
	var out := args[index + 1] if index >= 0 else "user://licenses.png"
	var settings := SettingsScreen.new()
	root.add_child(settings)
	await process_frame
	await process_frame
	var button := settings.find_child("SettingsLicenses", true, false) as Button
	button.grab_focus()
	await process_frame
	button.pressed.emit()
	await process_frame
	await process_frame
	var overlay := settings.get_node("LicensesScreen") as LicensesScreen
	var down := InputEventJoypadButton.new()
	down.button_index = JOY_BUTTON_DPAD_DOWN
	down.pressed = true
	Input.parse_input_event(down)
	await process_frame
	down = down.duplicate() as InputEventJoypadButton
	down.pressed = false
	Input.parse_input_event(down)
	await process_frame
	await RenderingServer.frame_post_draw
	var result := root.get_texture().get_image().save_png(out)
	var focus := root.gui_get_focus_owner()
	var focus_ok := focus != null and overlay.is_ancestor_of(focus)
	print("LICENSES SHOT result=%s gamepad_focus_inside=%s" % [result, focus_ok])
	settings.free()
	quit(0 if result == OK and focus_ok else 1)
