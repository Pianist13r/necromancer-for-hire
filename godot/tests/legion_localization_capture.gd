extends SceneTree
## Кадры настоящих экранов LegionMain с изолированным профилем и выгрузкой видимого текста.

var _locale := "en"
var _screen := "menu"
var _out := ""
var _texts: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _scan(node: Node) -> void:
	if (node is Label or node is Button or node is RichTextLabel) and node.is_visible_in_tree():
		_texts.append(node.tr(node.text))
	for child in node.get_children():
		_scan(child)


func _run() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--language="):
			_locale = arg.trim_prefix("--language=")
		if arg.begins_with("--audit-screen="):
			_screen = arg.trim_prefix("--audit-screen=")
		if arg.begins_with("--audit-out="):
			_out = arg.trim_prefix("--audit-out=")
	Settings.path = "user://localization_capture_settings.cfg"
	Campaign.set_save_path("user://localization_capture_campaign.cfg")
	Campaign.reset()
	I18n.initialize(_locale)
	var main := LegionMain.new()
	root.add_child(main)
	await process_frame
	match _screen:
		"settings":
			main._show_settings(true)
		"howto", "howto_roles", "howto_figures", "howto_preparation", "howto_rally", \
				"howto_combo", "howto_spring":
			main._show_howto()
		"briefing":
			main.show_briefing("bridge")
		"tutorial":
			main.start_battle("wasteland")
		"bridge_hint":
			for lesson: Dictionary in Campaign.map("bridge").get("lessons", []):
				Campaign.mark_hint_seen(LegionTutorial.flag("bridge", StringName(lesson["id"])))
			main.start_battle("bridge")
		"gray_hint":
			main.start_battle("_gray")
		"intro":
			main._play_cutscene(main._intro_frames(), main._ensure_audio(), Callable())
	for frame in 30:
		await process_frame
	if _screen.begins_with("howto_"):
		var prefixes := {
			"howto_roles": I18n.t("Три вида — три приказа"),
			"howto_figures": I18n.t(
				"Восьмёрка — «Двойная смена»: строй бьёт чаще, ПКМ — приказы крест-накрест; "),
			"howto_preparation": I18n.t(
				"Подготовка: у фигуры копится обод заряда, пока на местах стоит "),
			"howto_rally": I18n.t("«Сбор» также прерывает приказы щитов и стрелков в круге; "),
			"howto_combo": "Combo:" if _locale == "en" else "Комбо:",
			"howto_spring": I18n.t("Давка и пружина"),
		}
		var target := Controls.text(String(prefixes[_screen]))
		var matched := false
		for scroll: ScrollContainer in main.find_children("*", "ScrollContainer", true, false):
			for label: Label in scroll.find_children("*", "Label", true, false):
				if label.text.contains(target):
					matched = true
					var row: Control = label if label.get_parent() == scroll.get_child(0) \
						else label.get_parent()
					scroll.scroll_vertical = int(row.position.y)
		if not matched:
			push_error("Localization capture section not found: " + _screen)
			quit(1)
			return
		await process_frame
	_scan(main)
	var failures: Array[String] = []
	var cyrillic := RegEx.create_from_string("[А-Яа-яЁё]")
	for value in _texts:
		if _locale == "en" and value not in ["Language / Язык", "Русский"] \
				and cyrillic.search(value) != null:
			failures.append(value)
		if value.contains("{key") or value.contains("{mouse:"):
			failures.append(value)
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	var error := image.save_png(_out + ".png")
	var proof := {"locale": _locale, "screen": _screen, "texts": _texts,
		"failures": failures, "image_error": error,
		"campaign": Campaign._path, "settings": Settings.path,
		"appdata": OS.get_environment("APPDATA")}
	var file := FileAccess.open(_out + ".json", FileAccess.WRITE)
	file.store_string(JSON.stringify(proof, "\t"))
	file.close()
	print("LOCALIZATION CAPTURE ", _locale, " ", _screen, " ", failures.size(), " failures")
	if main.world != null:
		main.world.items.effects.items = null
	main.queue_free()
	await process_frame
	await process_frame
	quit(1 if not failures.is_empty() or error != OK else 0)
