extends SceneTree
## Presentation regression: formatted UI and joined metadata must not bypass translation.

var _checks := 0
var _fails := 0
var _cyrillic := RegEx.create_from_string("[А-Яа-яЁё]")


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, label: String) -> void:
	_checks += 1
	if not ok:
		_fails += 1
		print("FAIL ", label)


func _english(value: String, label: String) -> void:
	if value == "Language / Язык":
		return # Language discovery deliberately keeps both native names visible.
	_check(_cyrillic.search(value) == null, label + ": " + value.left(160))
	_check(not value.contains("{key") and not value.contains("{mouse:"), label + " bindings")


func _scan(node: Node) -> void:
	if node is Label or node is Button:
		_english(node.tr(node.text), String(node.name))
	if node is Control and not node.tooltip_text.is_empty():
		_english(node.tr(node.tooltip_text), String(node.name) + " tooltip")
	for child in node.get_children():
		_scan(child)


func _run() -> void:
	Settings.path = "user://ui_localization_settings.cfg"
	Campaign.set_save_path("user://ui_localization_campaign.cfg")
	I18n.language = "en"
	I18n.t("Досье")
	TranslationServer.set_locale("en")
	_english(I18n.t(PlayMetrics.NOTICE), "full consent notice")
	var original := JSON.stringify(LegionItemDb.ITEMS)
	var inventory := LegionItems.new()
	var strip := LegionItemBar.new()
	strip.inventory = inventory
	_check(Controls.rebind(&"cast_q", KEY_Z).is_empty(), "English ability remap accepted")
	strip.shown = [&"clip_of_fate"]
	strip.shown_counts = {&"clip_of_fate": 1}
	_check(String(strip.slot_info(0)["text"]).contains("Z"),
		"item instructions use the actual rebound English key")
	var dossier := DossierView.new()
	root.add_child(dossier)
	for id in LegionItemDb.ids():
		strip.shown = [id]
		strip.shown_counts = {id: 1}
		var info := strip.slot_info(0)
		for key in ["title", "text", "sub"]:
			_english(info[key], String(id) + " " + key)
		var card := dossier._card(id)
		dossier.add_child(card)
		_scan(card)
		card.free()
	_check(JSON.stringify(LegionItemDb.ITEMS) == original, "item simulation data unchanged")
	Controls.reset()
	dossier.free()
	strip.free()
	for id: String in AmendmentDb.ORDER:
		var row := ProgressionRow.new()
		root.add_child(row)
		row.configure(StringName(id), AmendmentDb.card(StringName(id)), "",
			{"expanded": true, "interactive": false, "chips": true})
		_scan(row)
		row.free()
	var result := LegionResult.new()
	root.add_child(result)
	var stats := result._stats_block({"kills": 17, "lost": 2, "time": 72,
		"cauldron_hp": 90, "cauldron_max": 100, "kassa": 3, "bounty": 4})
	result.add_child(stats)
	_scan(stats)
	_check(stats.find_child("CauldronHealth", true, false) != null,
		"translated result keeps health bar and icon classification")
	result.free()
	var settings := SettingsScreen.new()
	root.add_child(settings)
	_scan(settings)
	var saved_settings_path := Settings.path
	# Указываем каталог вместо файла: отказ записи без изменения прав или чужих файлов.
	Settings.path = "user://"
	settings._begin_capture(&"cast_q")
	var event := InputEventKey.new()
	event.physical_keycode = KEY_Z
	event.keycode = KEY_Z
	event.pressed = true
	settings._capture_input(event)
	_check(settings._capture == &"", "failed save still finishes English binding capture")
	Settings.path = saved_settings_path
	Controls.reset()
	settings.queue_free()
	await process_frame
	var active := SlotStrip.new()
	root.add_child(active)
	active.configure([StringName(AmendmentDb.ORDER[0])], false, false)
	_scan(active)
	active.free()
	var licences := LicensesScreen.new()
	root.add_child(licences)
	_english(licences.full_text(), "complete licence page")
	licences.queue_free()
	await process_frame
	var raw_notice := "Не удалось сохранить изменения. " \
		+ "Проверьте свободное место и доступ к папке сохранений."
	SafeConfig.notices[Settings.path] = raw_notice
	var notice := SaveNotice.new()
	root.add_child(notice)
	notice._process(0.0)
	_english(notice._text.text, "save error banner")
	_check(SafeConfig.notices[Settings.path] == raw_notice and notice._retry.visible,
		"translation preserves raw save state and retry classification")
	SafeConfig.notices.erase(Settings.path)
	notice.free()
	I18n.language = "ru"
	TranslationServer.set_locale("ru")
	_check(I18n.t(PlayMetrics.NOTICE) == PlayMetrics.NOTICE, "Russian notice unchanged")
	_check(Controls.text("{key:cast_q}") == "Ку", "Russian bindings unchanged")
	print("UI LOCALIZATION: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails else 0)
