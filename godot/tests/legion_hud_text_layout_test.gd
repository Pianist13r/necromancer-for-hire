extends SceneTree
## Real font geometry for RU/EN counters and contract cards; optional 1280x720 battle shots.

var checks := 0
var fails := 0


func _initialize() -> void:
	_run.call_deferred()


func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		fails += 1
		print("FAIL ", message)


func _head(available: float, caption: String, value: String) -> void:
	for bump in [0.0, 0.5, 1.0]:
		var row := LegionHudTextLayout.header(available, caption, value, bump)
		check(row.number_left - row.caption_right >= LegionHudTextLayout.GAP - 0.01,
			"separate caption and animated number: %s %s" % [caption, value])
		check(row.number_right + LegionHudTextLayout.NUMBER_EDGE <= available + 0.01,
			"number outline remains inside panel")
		check(row.caption_size >= 12 and row.number_size >= 15,
			"readable fonts %s %s: %s" % [caption, value, row])


func _run() -> void:
	print("HUD layout geometry starting")
	Settings.path = "user://hud_layout_settings.cfg"
	Campaign.set_save_path("user://hud_layout_campaign.cfg")
	Campaign.reset()
	Campaign.unlock_all()
	# initialize registers the EN catalog even on a fresh RU start. Godot must not use
	# that catalog as the fallback for Russian source labels without a RU catalog.
	Settings._cfg = ConfigFile.new()
	Settings.set_value("language", "locale", "ru")
	I18n.initialize("ru")
	var probe := Label.new()
	probe.text = "Подряд"
	probe.hide()
	root.add_child(probe)
	check(probe.tr(probe.text) == "Подряд", "fresh RU startup label stays Russian")
	for locale in ["en", "ru"]:
		print("HUD layout locale: ", locale)
		I18n.select(locale)
		I18n.t("Души")
		TranslationServer.set_locale(locale)
		check(probe.tr(probe.text) == I18n.t("Подряд"),
			"actual Label.tr follows locale switch to " + locale)
		for pvp in [false, true]:
			var widths := LegionTopPlate.block_widths(pvp)
			var total := 0.0
			for item in widths:
				total += item
			check(is_equal_approx(total, 752.0), "outer HUD width unchanged")
			var captions := [I18n.t("Ваш Котёл") if pvp else I18n.t("Котёл"),
				I18n.t("Мана"), I18n.t("Армия"), I18n.t("Души"), I18n.t("Волна")]
			for i in widths.size():
				for amount in ["226", "300", "999", "1000", "9999"]:
					_head(widths[i] - LegionTopPlate.ICON - 2.0, captions[i], amount)
			_head(widths[4] - LegionTopPlate.ICON - 2.0, captions[4], "99/99")
			await _cards_and_shot(locale, pvp)
		var rival_widths := PvpTopPlate.block_widths()
		check(is_equal_approx(rival_widths[0] + rival_widths[1] + PvpTopPlate.SEP
			+ PvpTopPlate.PAD * 2.0, 336.0), "outer PvP plate width unchanged")
		for amount in ["300", "999", "1000", "9999"]:
			_head(rival_widths[0] - PvpTopPlate.ICON - 2.0,
				I18n.t("Котёл соперника"), amount)
		_head(rival_widths[1], I18n.t("Осталось"), "11:51")
	probe.free()
	print("LEGION HUD TEXT LAYOUT: %d/%d OK" % [checks - fails, checks])
	quit(1 if fails else 0)


func _cards_and_shot(locale: String, pvp: bool) -> void:
	print("HUD layout scene: ", locale, " PvP=", pvp)
	var world := load("res://scenes/legion_world.tscn").instantiate() as LegionWorld
	world.embedded = true
	root.add_child(world)
	await process_frame
	world.dev["no_waves"] = "1"
	world.start_map("pvp:duel" if pvp else "wasteland")
	world.phase = LegionWorld.Phase.BATTLE
	world.set_process(false)
	world.my_side().souls = 9999
	world.my_side().cauldron_hp = 1000
	world.my_side().cauldron_max = 1000
	world.my_field().mana = 999
	if pvp:
		world.sides[1].cauldron_hp = 1000
		world.sides[1].cauldron_max = 1000
	var plate := world.hud.get("_plate") as LegionTopPlate
	plate._souls.bump = 1.0
	plate.set_army(226, 999)
	for i in 20:
		await process_frame
	var bars := world.find_children("*", "LegionKindBar", true, false)
	check(bars.size() == 1, "real contract bar exists")
	for bar: LegionKindBar in bars:
		bar._refresh_t = 0.0
		bar._process(0.0)
		check(bar.is_visible_in_tree(), "contract bar visible in battle")
		for button in bar.buttons:
			var title := button.find_child("Title", true, false) as Label
			var actual := LegionHudTextLayout.width(LegionUi.FONT_TITLE, title.text,
				title.get_theme_font_size("font_size"))
			check(actual <= title.size.x - 2.0 + 0.01, "complete contract title fits: " + title.text)
			check(title.text == I18n.t(LegionCfg.KIND_CARD_NAMES[bar.buttons.find(button)]),
				"contract title uses selected locale")
			check(title.tr(title.text) == title.text, "rendered title matches selected locale")
			check(title.get_global_rect().end.x <= button.get_global_rect().end.x - 6.0,
				"contract title stays within card padding")
			check(button.size == LegionCfg.KIND_CARD_SIZE, "card hit target unchanged")
	var out := OS.get_environment("NECRO_HUD_LAYOUT_SHOTS")
	if not out.is_empty() and DisplayServer.get_name() != "headless":
		DisplayServer.window_set_position(Vector2i(-32000, -32000))
		root.size = Vector2i(1280, 720)
		DisplayServer.window_set_size(Vector2i(1280, 720))
		for i in 3:
			await process_frame
		await RenderingServer.frame_post_draw
		var file := "%s-%s-1280x720.png" % [locale, "pvp" if pvp else "pve"]
		check(root.get_texture().get_image().save_png(out.path_join(file)) == OK, "capture " + file)
	world.queue_free()
	await process_frame
	await process_frame
