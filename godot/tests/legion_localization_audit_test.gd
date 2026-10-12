extends SceneTree
## Карты, составные подсказки и настоящие виджеты проверяются после выбора языка.

const Teaching := preload("res://scripts/legion/legion_teaching_text.gd")
const MAP_ROOT := "res://assets/legion/maps/"
var _checks := 0
var _fails := 0
var _cyrillic := RegEx.create_from_string("[А-Яа-яЁё]")
var _english_targets: Dictionary = {}
var _key_caps: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, label: String) -> void:
	_checks += 1
	if not ok:
		_fails += 1
		print("FAIL ", label)


func _english(text: String, label: String) -> void:
	# Названия языков остаются узнаваемыми до переключения интерфейса.
	if text in ["Русский", "Language / Язык"]:
		return
	_check(_cyrillic.search(text) == null, label + ": " + text.left(180))
	_check(not text.contains("{key") and not text.contains("{mouse:")
		and not text.contains("{cfg:") and not text.contains("{charge:"), label + " tokens")


func _scan(node: Node, label: String) -> void:
	if node is Label or node is Button or node is RichTextLabel:
		var display: String = node.tr(node.text)
		if I18n.language == "en":
			_english(display, label + "/" + String(node.name))
		else:
			_check(not _english_targets.has(display) or display in _key_caps,
				label + " Russian UI: " + display.left(180))
	if node is OptionButton:
		for index in node.item_count:
			if I18n.language == "en":
				_english(node.tr(node.get_item_text(index)), label + " option")
	if node is Control and not node.tooltip_text.is_empty():
		if I18n.language == "en":
			_english(node.tr(node.tooltip_text), label + " tooltip")
		else:
			_check(not _english_targets.has(node.tr(node.tooltip_text)), label + " Russian tooltip")
	for child in node.get_children():
		_scan(child, label)


func _maps(locale: String) -> void:
	for filename in DirAccess.get_files_at(MAP_ROOT):
		if not filename.ends_with(".json"):
			continue
		var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(MAP_ROOT + filename))
		var original := JSON.stringify(data)
		for key in ["title", "subtitle", "hint"]:
			var source := String(data.get(key, ""))
			var display := Controls.text(I18n.map_text(source))
			if locale == "en":
				_english(display, filename + " " + key)
			else:
				_check(I18n.map_text(source) == source, filename + " Russian " + key)
		for lesson: Dictionary in data.get("lessons", []):
			var source := String(lesson.get("text", ""))
			var display := Controls.text(Teaching.render(source))
			if locale == "en":
				_english(display, filename + " lesson " + String(lesson.get("id", "")))
			else:
				_check(source.is_empty() or _cyrillic.search(display) != null,
					filename + " Russian lesson " + String(lesson.get("id", "")))
		_check(JSON.stringify(data) == original, filename + " canonical data unchanged")


func _generated(locale: String) -> void:
	for pool: Array in PgNames.TITLES.values():
		for template: String in pool:
			for biome: String in PgNames.GEN:
				for genitive: String in PgNames.GEN[biome]:
					for place: String in PgNames.PLACE[biome]:
						var source := template.replace("{gen}", genitive).replace("{place}", place)
						for suffix: String in ["", " особой важности"]:
							var raw := source + suffix
							if locale == "en":
								_english(I18n.map_text(raw), "generated title")
							else:
								_check(I18n.map_text(raw) == raw, "Russian generated title")
	var hints: Array = PgNames.QUIRK_HINT.values() + PgNames.ROSTER_HINT.values()
	for q_hint: String in hints:
		for arch_hint: String in PgNames.ARCH_HINT.values():
			for wave in [1, 7, 14]:
				var prefix := q_hint % wave if q_hint.contains("%d") else q_hint
				var source := prefix + " " + arch_hint
				var display := Controls.text(I18n.map_text(source))
				if locale == "en":
					_english(display, "joined generated hint")
				else:
					_check(I18n.map_text(source) == source, "Russian joined generated hint")


func _screens() -> void:
	var screens: Array[Control] = [LegionMenu.new(), MapSelect.new(), SettingsScreen.new(),
		HowtoLegion.new(), DossierView.new(), LegionCollectionScreen.new()]
	for screen in screens:
		root.add_child(screen)
		_scan(screen, screen.get_class())
		screen.free()
	for map_data: Dictionary in Campaign.maps():
		var briefing := Briefing.new()
		root.add_child(briefing)
		briefing.populate(map_data)
		_scan(briefing, "briefing " + String(map_data.get("id", "")))
		briefing.free()
	var world := LegionWorld.new()
	world.embedded = true
	root.add_child(world)
	world.set_process(false)
	for map_id in ["_gray", "_plots", "bridge"]:
		world.hud.drop_toasts()
		await process_frame
		world.start_map(map_id)
		_scan(world.hud, "actual HUD " + map_id)
	# Оснастка разрывает существующий RefCounted-цикл инвентарь ↔ эффекты перед выходом.
	world.items.effects.items = null
	world.queue_free()
	await process_frame
	await process_frame


func _run() -> void:
	Settings.path = "user://localization_audit_settings.cfg"
	Campaign.set_save_path("user://localization_audit_campaign.cfg")
	Campaign.reset()
	I18n._load_catalogs()
	# Настройки показывают надписи физических клавиш (Space/Tab), проза — «Пробел»/«Таб».
	for action: StringName in Controls.ACTIONS:
		_key_caps.append(Controls.label(action))
	for source: String in I18n._english:
		var target := String(I18n._english[source])
		if target.length() > 4 and target != source and _cyrillic.search(target) == null:
			_english_targets[target] = true
	for locale in ["en", "ru"]:
		I18n.language = locale
		I18n.t("Обучение")
		TranslationServer.set_locale(locale)
		Settings.lefty_override = "off"
		_maps(locale)
		_generated(locale)
		_check(Controls.rebind(&"cast_q", KEY_Z).is_empty(), locale + " rebound key")
		var rendered := Controls.text("Нажмите {key:cast_q} и зажмите {mouse:draw}.")
		_check(rendered.contains("Z") and rendered.contains("LMB" if locale == "en" else "ЛКМ"),
			locale + " actual keyboard and right-handed mouse")
		Settings.lefty_override = "on"
		rendered = Controls.text("Нажмите {key:cast_q} и зажмите {mouse:draw}.")
		_check(rendered.contains("Z") and rendered.contains("RMB" if locale == "en" else "ПКМ"),
			locale + " actual keyboard and left-handed mouse")
		Settings.lefty_override = "off"
		Controls.reset()
		await _screens()
	print("LOCALIZATION AUDIT: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails else 0)
