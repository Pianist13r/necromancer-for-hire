extends SceneTree
## Живые кадры экранов прокачки; --out=<каталог>. Один процесс, два размера.

const SIZES: Array[Vector2i] = [Vector2i(1280, 720), Vector2i(960, 540)]
const RESULT_CASES = preload("res://tests/legion_progression_ux_test.gd")
var _out := "res://../batches/progression/after"
var _results_only := false
var _failures := 0


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			_out = arg.trim_prefix("--out=")
		if arg == "--results-only":
			_results_only = true
	_run.call_deferred()


func _run() -> void:
	Campaign.set_save_path("user://progression_ux_shots.cfg")
	Settings.path = "user://progression_ux_shots_settings.cfg"
	Settings._cfg = null
	Controls.reset()
	_out = ProjectSettings.globalize_path(_out).simplify_path()
	if DirAccess.make_dir_recursive_absolute(_out) != OK:
		push_error("Не удалось создать каталог кадров: " + _out)
		quit(1)
		return
	Campaign.reset()
	for data in RESULT_CASES.result_cases():
		var full_result := LegionResult.new()
		await _capture(full_result, "result_" + String(data["id"]), func() -> void:
			RESULT_CASES.show_case(full_result, data))
	if _results_only:
		print("PROGRESSION UX RESULT SHOTS: done")
		quit(1 if _failures else 0)
		return
	Campaign.unlock_all()
	Campaign._add_hero_xp(220)
	Campaign.record_result("wasteland", true, 0.9)
	Campaign.add_bounty(85)
	var picker := UpgradePicker.new()
	await _capture(picker, "01_picker", func() -> void:
		picker.offer([&"ghost_clause", &"night_duty", &"high_voltage"]))
	Campaign.add_upgrade(&"night_duty")
	Campaign.add_upgrade(&"living_queue")
	Campaign.add_upgrade(&"temp_agency")
	var replacement := UpgradePicker.new()
	await _capture(replacement, "02_replacement", func() -> void:
		replacement.offer([&"ghost_clause", &"bulk_ink", &"high_voltage"])
		replacement.select(&"high_voltage")
		replacement.choose(&"high_voltage"))
	var artifacts: Array[StringName] = [&"clip_of_fate"]
	Campaign.set_run_items(artifacts)
	await _capture(HeroScreen.new(), "03_dossier")
	var details := HeroScreen.new()
	await _capture(details, "04_card_details", func() -> void:
		ProgressionUi.inspect_card(details, &"carbon_copy"))
	var future := HeroScreen.new()
	await _capture(future, "05_rank_details", func() -> void:
		ProgressionUi.inspect_rank(future, 4))
	Campaign._add_hero_xp(230)
	Campaign.add_bounty(150)
	RunProgression.buy_service("souls")
	RunProgression.buy_service("mana")
	var brief := Briefing.new()
	await _capture(brief, "06_briefing", func() -> void:
		brief.populate(Campaign.maps()[2]))
	Campaign.reset()
	Campaign._add_hero_xp(90)
	var reward := Campaign.record_rewards(true, 3, 10)
	var result := LegionResult.new()
	await _capture(result, "07_result_rank_up", func() -> void:
		result.show_result(true, {"map_title": "Пустырь", "kills": 10, "lost": 2,
			"cauldron_hp": 120, "cauldron_max": 200, "time": 173.0,
			"releases_manual": 2, "debrief": RESULT_CASES.result_cases()[0]["stats"]["debrief"]},
			2, true, false, reward))
	var defeat := LegionResult.new()
	await _capture(defeat, "12_result_defeat", func() -> void:
		defeat.show_result(false, {"map_title": "Пустырь", "kills": 42, "lost": 17,
			"cauldron_hp": 0, "cauldron_max": 200, "time": 243.0, "charges": 8,
			"refreshes": 12, "releases_manual": 4,
			"debrief": RESULT_CASES.result_cases()[2]["stats"]["debrief"]}, 0, false, false,
			{"bounty": 10, "xp": 42, "xp_before": 210, "xp_after": 252}))
	var help := HowtoLegion.new()
	await _capture(help, "08_howto", func() -> void:
		for btn in help.find_children("*", "Button", true, false):
			if btn.text.begins_with("Прокачка:"):
				btn.pressed.emit())
	Campaign.unlock_all()
	Campaign.use_endless_scope()
	var endless := EndlessBriefing.new()
	await _capture(endless, "09_endless", func() -> void:
		endless.populate(Campaign.maps()[1], 3, 2, 140, false, ""))
	Campaign.use_campaign_scope()
	Controls.rebind(&"cast_q", KEY_Z)
	var rebound := UpgradePicker.new()
	await _capture(rebound, "10_rebound_Z", func() -> void:
		rebound.offer([&"carbon_copy", &"high_voltage", &"bulk_ink"]))
	Campaign.set_run_items(artifacts)
	var item_dossier := HeroScreen.new()
	await _capture(item_dossier, "11_artifacts_Z", func() -> void:
		item_dossier.view.show_tab(DossierView.TAB_ITEMS))
	Controls.reset()
	print("PROGRESSION UX SHOTS: done")
	quit(1 if _failures else 0)


func _capture(screen: Control, title: String, setup := Callable()) -> void:
	DisplayServer.window_set_size(SIZES[0])
	var battle: LegionWorld
	if screen is LegionResult:
		# Итог — оверлей над настоящим миром, а не отдельный экран на пустом viewport.
		battle = (load("res://scenes/legion_world.tscn") as PackedScene).instantiate() as LegionWorld
		battle.embedded = true
		root.add_child(battle)
		battle.dev["no_waves"] = "1"
		battle.start_map("wasteland")
		battle.hold = true
		battle.phase = LegionWorld.Phase.DEFEAT if title.contains("defeat") else LegionWorld.Phase.VICTORY
		# Как LegionMain._set_screen/_cover_battle: HUD мира не лежит поверх итога.
		for layer in battle.find_children("*", "CanvasLayer", true, false):
			(layer as CanvasLayer).visible = false
		screen.z_index = LegionMain.OVERLAY_Z
	root.add_child(screen)
	await _frames(4)
	if setup.is_valid():
		setup.call()
	await _frames(4)
	if title == "07_result_rank_up":
		for frame in [4, 20, 60]:
			await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png("%s/reward_frame_%02d.png" % [_out, frame])
			await _frames(16 if frame == 4 else 40)
	for size: Vector2i in SIZES:
		DisplayServer.window_set_size(size)
		await _frames(65)
		await RenderingServer.frame_post_draw
		var path := "%s/%s_%dx%d.png" % [_out, title, size.x, size.y]
		var err := root.get_texture().get_image().save_png(path)
		if err != OK:
			_failures += 1
		print(JSON.stringify({"shot": path, "error": err}))
		if screen is LegionResult:
			var scroll := screen.find_children("*", "ScrollContainer", true, false)[0] as ScrollContainer
			print(JSON.stringify({"case": title, "window": str(size),
				"viewport": str(root.get_visible_rect().size),
				"content": (scroll.get_child(0) as Control).size.y, "visible": scroll.size.y,
				"scrollbar": scroll.get_v_scroll_bar().visible}))
	screen.queue_free()
	if battle != null:
		battle.queue_free()
	await _frames(2)


func _frames(count: int) -> void:
	for i in count:
		await process_frame
