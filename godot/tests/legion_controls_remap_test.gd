extends SceneTree

var checks := 0
var fails := 0

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		fails += 1
	print("  %s %s" % ["ok" if ok else "FAIL", message])

func key_event(code: Key, pressed := true) -> InputEventKey:
	var event := InputEventKey.new()
	event.keycode = code
	event.physical_keycode = code
	event.pressed = pressed
	return event

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	Settings.path = "user://controls_test_settings.cfg"
	Settings._cfg = ConfigFile.new()
	Settings.apply()
	check(InputMap.has_action(&"rally"), "startup registers keyboard actions")
	check(Controls.rebind(&"cast_q", KEY_G).is_empty(), "can rebind ability")
	check(key_event(KEY_G).is_action_pressed(&"cast_q"), "new ability key matches")
	check(not key_event(KEY_Q).is_action_pressed(&"cast_q"), "old ability key removed")
	check(not Controls.rebind(&"cast_w", KEY_G).is_empty(), "conflicting key rejected")
	check(Controls.key(&"cast_w") == KEY_W, "conflict leaves previous mapping intact")
	check(not Controls.rebind(&"cast_w", KEY_N).is_empty(), "default wave alias reserves N")
	check(not Controls.rebind(&"pause", KEY_ESCAPE).is_empty(), "Esc cannot be removed")
	Settings._cfg = null
	Settings.apply()
	check(Controls.key(&"cast_q") == KEY_G, "mapping survives config reload")
	check(key_event(KEY_G).is_action_pressed(&"cast_q"), "reloaded map applied")
	check(Controls.text("Ку Q; Наберёт N / мест M; 12 души") == "G G; Наберёт N / мест M; 12 души", "prompts translate keys without numbers or variable N")
	check(key_event(KEY_ESCAPE).is_action_pressed(&"pause"), "fixed cancel fallback")
	var external := key_event(KEY_G)
	external.device = 7
	check(external.is_action_pressed(&"cast_q"), "rebinding accepts virtual keyboards used by playtest drivers")
	var drawing := InputMap.action_get_events(&"draw").duplicate()
	Controls.reset()
	check(Controls.key(&"cast_q") == KEY_Q and key_event(KEY_N).is_action_pressed(&"call_wave"), "reset restores defaults and wave alias")
	check(InputMap.action_get_events(&"draw") == drawing, "mouse drawing preserved")
	Settings.set_control_scheme(Settings.SCHEME_CLASSIC)
	Controls.reset()
	check(Settings.control_scheme() == Settings.SCHEME_CLASSIC, "keyboard reset preserves sling scheme choice")
	Settings.set_control_scheme(Settings.SCHEME_SLING)
	Settings.set_value(Controls.SECTION, "keyboard", {"cast_q": KEY_W})
	Controls.apply()
	check(Controls.key(&"cast_q") == KEY_Q and Controls.key(&"cast_w") == KEY_W, "duplicate saved mapping recovers safely")
	Settings.set_value(Controls.SECTION, "keyboard", {"cast_q": "not a key"})
	Controls.apply()
	check(Controls.key(&"cast_q") == KEY_Q, "malformed saved mapping recovers safely")
	Controls.reset()
	await _ui()
	await _battle()
	print("LEGION CONTROLS REMAP: %d/%d OK" % [checks - fails, checks])
	quit(1 if fails else 0)

func _ui() -> void:
	var screen := SettingsScreen.new()
	root.add_child(screen)
	await process_frame
	var closed := [false]
	screen.closed.connect(func() -> void: closed[0] = true)
	var button := screen.find_child("Bind_cast_q", true, false) as Button
	check(button != null, "settings exposes rebind buttons")
	if button != null:
		await _shots(screen, button)
		button.pressed.emit()
		Input.parse_input_event(key_event(KEY_G))
		await process_frame
		Input.parse_input_event(key_event(KEY_G, false))
		await process_frame
		check(Controls.key(&"cast_q") == KEY_G and button.text == "G", "real UI event binds and refreshes")
		check(root.gui_get_focus_owner() == button, "focus returns to changed action")
		button.pressed.emit()
		Input.parse_input_event(key_event(KEY_W))
		await process_frame
		check(screen.get("_capture") == &"cast_q" and Controls.key(&"cast_q") == KEY_G, "UI conflict keeps capture pending")
		Input.parse_input_event(key_event(KEY_ESCAPE))
		await process_frame
		check(screen.get("_capture") == &"" and not closed[0], "Esc cancels capture without closing settings")
		Input.parse_input_event(key_event(KEY_ESCAPE, false))
		await process_frame
		Input.parse_input_event(key_event(KEY_ESCAPE))
		await process_frame
		check(closed[0], "second Esc closes settings")
	screen.queue_free()
	await process_frame
	Controls.reset()

func _shots(screen: SettingsScreen, button: Button) -> void:
	var out := OS.get_environment("NECRO_CONTROLS_SHOTS")
	if out.is_empty() or DisplayServer.get_name() == "headless":
		return
	DisplayServer.window_set_position(Vector2i(-32000, -32000))
	for dimensions: Vector2i in [Vector2i(1280, 720), Vector2i(960, 540)]:
		root.size = dimensions
		DisplayServer.window_set_size(dimensions)
		button.grab_focus()
		await process_frame
		var scroll := screen.find_child("SettingsScroll", true, false) as ScrollContainer
		scroll.scroll_vertical += int(screen._binding_note.global_position.y - scroll.global_position.y)
		for i in 5:
			await process_frame
		await RenderingServer.frame_post_draw
		var image := root.get_texture().get_image()
		check(image.save_png(out.path_join("settings-%dx%d.png" % [dimensions.x, dimensions.y])) == OK,
			"rendered settings screenshot")
		var close := screen.find_child("SettingsClose", true, false) as Button
		check(root.get_visible_rect().encloses(close.get_global_rect()), "close button remains on screen")

func _battle() -> void:
	Campaign.set_save_path("user://controls_test_campaign.cfg")
	Campaign.reset()
	Campaign.unlock_all()
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	var world := scene.instantiate() as LegionWorld
	root.add_child(world)
	await process_frame
	world.dev["spawn_units"] = "0"
	world.dev["no_waves"] = "1"
	world.start_map("wasteland")
	world.set_process(false)
	var field := world.contracts
	field.active = true
	field.human_input = true
	Controls.rebind(&"rune_frost", KEY_H)
	field._unhandled_input(key_event(KEY_H))
	check(field.current_kind == LegionCfg.KIND_ORDER[1], "field uses rebound kind key")
	field._unhandled_input(key_event(KEY_1))
	field._unhandled_input(key_event(KEY_2))
	check(field.current_kind == LegionCfg.KIND_ORDER[0], "old kind key no longer changes field")
	Controls.rebind(&"call_wave", KEY_J)
	check(key_event(KEY_J).is_action_pressed(&"call_wave") and not key_event(KEY_F).is_action_pressed(&"call_wave") and not key_event(KEY_N).is_action_pressed(&"call_wave"), "wave rebind removes both default aliases")
	Controls.rebind(&"aim_contract", KEY_L)
	field._unhandled_input(key_event(KEY_L))
	check(field._space, "remapped aim hold starts")
	field._unhandled_input(key_event(KEY_L, false))
	check(not field._space, "remapped aim release stops")
	Controls.rebind(&"rally", KEY_U)
	world._unhandled_input(key_event(KEY_U))
	check(world.rally_aiming, "remapped rally hold starts")
	world.net_mode = true
	var commands: Array[Dictionary] = []
	world.net_out = func(command: Dictionary) -> void: commands.append(command)
	world._unhandled_input(key_event(KEY_U, false))
	check(commands.size() == 1 and commands[0].get("type") == PvpCmd.RALLY,
		"rebound rally emits deterministic PvP command")
	world.net_mode = false
	Controls.rebind(&"pause", KEY_K)
	world._unhandled_input(key_event(KEY_K))
	check(world.paused, "remapped pause reaches world")
	world.set_paused(false)
	var kind_bar := LegionKindBar.new()
	kind_bar.world = world
	root.add_child(kind_bar)
	await process_frame
	kind_bar._process(1.0)
	Controls.rebind(&"rune_normal", KEY_Z)
	kind_bar._process(1.0)
	check(kind_bar._keys[0] == KEY_Z, "kind stamp refreshes after rebind without selection change")
	var kassa_button := LegionKassaButton.new().setup(world, null)
	root.add_child(kassa_button)
	Controls.rebind(&"kassa", KEY_Y)
	kassa_button._process(0.0)
	check(kassa_button.tooltip_text.contains("(Y)"), "cash tooltip follows current key")
	kind_bar.queue_free()
	kassa_button.queue_free()
	Controls.rebind(&"erase_piece", KEY_I)
	Controls.rebind(&"pause", KEY_TAB)
	Input.parse_input_event(key_event(KEY_TAB))
	await process_frame
	check(world.paused, "real Tab binding reaches pause before GUI focus")
	world.set_paused(false)
	world.queue_free()
	await process_frame
	Controls.reset()
	Campaign.reset()
