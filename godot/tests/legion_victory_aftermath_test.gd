extends SceneTree
## Этап 5 ROADMAP: следствие победы на картах кампании 1–7 — поле `aftermath` JSON и строка
## «VictoryAftermath» под штампом итога. Прораб, поражение, забег и карта без поля — прежний
## экран. RU/EN через каталог, без кириллицы и клавишных токенов в EN; награда и кнопки на месте.
##
##   bash tools/legion_quick.sh legion_victory_aftermath_test

## Следствие каждой карты называет следующий объект (основа — title следующей карты по order).
const NEXT_STEM := {
	"wasteland": "Проходн",
	"gatehouse": "Два отдела",
	"fork": "Архив",
	"archive": "Стикс",
	"bridge": "лабиринт",
	"maze": "Болот",
	"swamp": "Прораб",
}

var _checks := 0
var _fails := 0
var _cyrillic := RegEx.create_from_string("[А-Яа-яЁё]")


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, label: String) -> void:
	_checks += 1
	if not ok:
		_fails += 1
	print("  %s %s" % ["ok" if ok else "FAIL", label])


func _story(screen: LegionResult) -> Label:
	return screen.find_child("VictoryAftermath", true, false) as Label


## Свежий экран на каждый случай: show_result чистит прежних детей через queue_free, и старый
## узел ещё виден find_child до конца кадра.
func _shown(victory: bool, stats: Dictionary, complete := false,
		rewards := {}) -> LegionResult:
	var screen := LegionResult.new()
	root.add_child(screen)
	await process_frame
	screen.show_result(victory, stats, 3 if victory else 0, victory and not complete, complete,
		rewards)
	await process_frame
	return screen


func _run() -> void:
	Settings.path = "user://victory_aftermath_settings.cfg"
	Campaign.set_save_path("user://victory_aftermath_campaign.cfg")
	Campaign.reset()
	Controls.reset()
	I18n.language = "ru"
	TranslationServer.set_locale("ru")
	await _test_catalog()
	await _test_screen_ru()
	await _test_screen_en()
	I18n.language = "ru"
	TranslationServer.set_locale("ru")
	print("VICTORY AFTERMATH: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails else 0)


func _test_catalog() -> void:
	print("— каталог: семь следствий, у финала нет")
	var maps := Campaign.maps()
	_check(maps.size() == 8, "восемь карт кампании")
	var last: Dictionary = maps[maps.size() - 1]
	_check(String(last.get("id", "")) == "boss", "последняя карта — Прораб")
	_check(not last.has("aftermath"), "у Прораба поля нет: финал — своя катсцена")
	var seen := {}
	for i in maps.size() - 1:
		var m: Dictionary = maps[i]
		var id := String(m.get("id", ""))
		var text := String(m.get("aftermath", ""))
		_check(text.length() >= 40 and text.length() <= 220, id + ": следствие 40–220 символов")
		_check(not text.contains("{") and not text.contains("%"), id + ": без токенов и форматов")
		_check(not seen.has(text), id + ": текст не повторяет другую карту")
		seen[text] = id
		var stem := String(NEXT_STEM.get(id, ""))
		_check(stem != "" and text.contains(stem), id + ": назван следующий объект «%s»" % stem)
		_check(text.ends_with("."), id + ": законченное предложение")
	I18n.language = "en"
	TranslationServer.set_locale("en")
	for i in maps.size() - 1:
		var m: Dictionary = maps[i]
		var id := String(m.get("id", ""))
		var text := String(m.get("aftermath", ""))
		var english := I18n.map_text(text)
		_check(I18n.t(text) != text, id + ": EN-перевод есть в каталоге")
		_check(_cyrillic.search(english) == null, id + ": EN без кириллицы")
		_check(not english.contains("{") and english.length() >= 40, id + ": EN без токенов")
	I18n.language = "ru"
	TranslationServer.set_locale("ru")
	await process_frame


func _test_screen_ru() -> void:
	print("— экран итога RU: строка под штампом, награда и кнопки на месте")
	var swamp := Campaign.map("swamp")
	var text := String(swamp.get("aftermath", ""))
	var stats := {"map_title": String(swamp.get("title", "")), "aftermath": text,
		"cauldron_hp": 160.0, "cauldron_max": 200.0, "kills": 84, "lost": 12, "time": 187.0}
	var rewards := {"bounty": 45, "xp": 134, "xp_before": 0, "xp_after": 134}
	var win := await _shown(true, stats, false, rewards)
	var story := _story(win)
	_check(story != null, "победа: строка «VictoryAftermath» есть")
	if story != null:
		_check(story.text == text, "победа: текст следствия карты без изменений")
		_check(story.autowrap_mode == TextServer.AUTOWRAP_WORD_SMART, "перенос по словам")
		var note: Label = null
		for child in story.get_parent().get_children():
			if child is Label and (child as Label).text == I18n.map_text(
					String(swamp.get("title", ""))):
				note = child as Label
		_check(note != null and story.get_index() == note.get_index() + 1,
			"строка стоит сразу под названием карты, до прокрутки")
		var scroll := win.find_children("*", "ScrollContainer", true, false)[0] as Control
		_check(story.get_index() < scroll.get_index(), "строка вне прокручиваемого итога")
	var primary := win.find_child("NavPrimary", true, false) as Button
	_check(primary != null and primary.text == I18n.t("Дальше: выбор поправки"),
		"главная кнопка «Дальше: выбор поправки» сохранена")
	_check(win.find_child("ShareChat", true, false) != null, "ссылка на чат сохранена")
	_check(win.find_child("RewardPanel", true, false) != null
		and win.find_child("RewardCounters", true, false) != null, "панель награды сохранена")
	win.queue_free()

	var lose := await _shown(false, stats)
	_check(_story(lose) == null, "поражение: строки нет даже с полем")
	var retry := lose.find_child("NavPrimary", true, false) as Button
	_check(retry != null and retry.text == I18n.t("Ещё раз"),
		"поражение: главная кнопка «Ещё раз» прежняя")
	lose.queue_free()

	var finale := await _shown(true, stats, true, rewards)
	_check(_story(finale) == null, "финал кампании: строки нет — у него своя катсцена")
	finale.queue_free()

	var plain := await _shown(true, {"map_title": "Пустырь", "kills": 3}, false, rewards)
	_check(_story(plain) == null, "карта без поля: прежний экран")
	plain.queue_free()

	var endless := await _shown(true, {"map_title": "Объект 3", "tenure": 3, "souls": 40,
		"bounty": 12, "kills": 20})
	_check(_story(endless) == null, "забег (tenure без aftermath): прежний экран")
	endless.queue_free()

	var tokens := await _shown(true, {"map_title": "Пустырь", "aftermath": "{key:cast_q} раз."},
		false, rewards)
	var tokened := _story(tokens)
	_check(tokened != null and tokened.text == "Ку раз.",
		"клавишный токен раскрыт один раз (урок B-523), не сырой и не дважды")
	tokens.queue_free()
	await process_frame


func _test_screen_en() -> void:
	print("— экран итога EN: перевод из каталога, без кириллицы")
	I18n.language = "en"
	TranslationServer.set_locale("en")
	for id: String in ["wasteland", "archive", "swamp"]:
		var m := Campaign.map(id)
		var text := String(m.get("aftermath", ""))
		var win := await _shown(true, {"map_title": String(m.get("title", "")),
			"aftermath": text, "kills": 10}, false, {"bounty": 5, "xp": 20, "xp_before": 0,
			"xp_after": 20})
		var story := _story(win)
		_check(story != null and story.text == I18n.t(text), id + ": EN-строка из каталога")
		_check(story != null and _cyrillic.search(story.text) == null, id + ": EN без кириллицы")
		var all_text := ""
		for label: Label in win.find_children("*", "Label", true, false):
			if label.is_visible_in_tree():
				all_text += label.text + "\n"
		_check(_cyrillic.search(all_text) == null, id + ": на экране итога нет кириллицы")
		win.queue_free()
	await process_frame
