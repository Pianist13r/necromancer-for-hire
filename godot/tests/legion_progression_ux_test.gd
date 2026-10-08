extends SceneTree
## Прокачка 08.10: читаемость условий, новые клавиши, опыт и совместимость v3.

var _checks := 0
var _fails := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, label: String) -> void:
	_checks += 1
	if not ok:
		_fails += 1
	print("  %s %s" % ["ok" if ok else "FAIL", label])


func _text(node: Node) -> String:
	var out := ""
	if node is Label or node is Button:
		out = node.text + "\n"
	for child in node.get_children():
		out += _text(child)
	return out


func _run() -> void:
	Campaign.set_save_path("user://legion_progression_ux.cfg")
	Settings.path = "user://progression_ux_settings.cfg"
	Settings._cfg = null
	Campaign.reset()
	Controls.reset()
	_check(Controls.rebind(&"cast_q", KEY_Z) == "", "Q → Z переназначается")
	await _test_battle_item_text()
	var settings := SettingsScreen.new()
	root.add_child(settings)
	var close_button := Button.new()
	settings.add_child(close_button)
	var reset_block := settings._build_reset_block(close_button)
	settings.add_child(reset_block)
	var reset_text := _text(reset_block)
	_check(not reset_text.contains("Контору") and reset_text.contains("забеги")
		and reset_text.contains("коллекцию"), "сброс перечисляет настоящий прогресс без Конторы")
	settings.queue_free()
	var row := ProgressionRow.new()
	root.add_child(row)
	row.configure(&"carbon_copy", AmendmentDb.card(&"carbon_copy"), "", {"expanded": true})
	_check(_text(row).contains("Z") and not _text(row).contains("Ку"),
		"карта: короткий эффект, условия и цена называют Z")
	row.queue_free()
	await process_frame
	var strip := SlotStrip.new()
	root.add_child(strip)
	strip.configure([&"carbon_copy"])
	var slot := strip.get_child(0) as Button
	_check(slot.tooltip_text.contains("Z") and slot.tooltip_text.contains("Мелкий шрифт"),
		"подписанная поправка: подсказка с новой клавишей и ценой")
	_check(slot.focus_mode == Control.FOCUS_ALL, "слот читается с клавиатуры")
	slot.grab_focus()
	slot.pressed.emit()
	await process_frame
	var popup := strip.find_child("AmendmentDetails", true, false) as AcceptDialog
	_check(popup != null and popup.visible and _text(popup).contains("Мелкий шрифт"),
		"нажатие на слот открывает полные условия")
	if popup != null:
		_check(popup.size.y < 500, "окно условий ограничено по высоте")
		for i in 4:
			await process_frame
		_check(popup.size.y < 300, "окно коротких условий подогнано под содержимое")
		popup.hide()
		await process_frame
		_check(slot.has_focus(), "закрытие условий возвращает фокус слоту")
	strip.queue_free()
	await process_frame
	var howto := HowtoLegion.new()
	root.add_child(howto)
	var guide := _text(howto)
	for word: String in ["Прокачка", "поправк", "разряд", "опыт", "подготовк", "Досье", "переброс"]:
		_check(guide.to_lower().contains(word.to_lower()), "Как играть объясняет: " + word)
	_check(not guide.contains("В «Конторе»"), "Как играть не отправляет в удалённую Контору")
	howto.queue_free()
	await process_frame
	Campaign._add_hero_xp(90)
	var rewards := Campaign.record_rewards(true, 3, 10)
	_check(int(rewards.get("xp_before", -1)) == 90 and int(rewards.get("xp_after", -1)) == 210,
		"итог хранит оба значения опыта для анимации через разряд")
	var result := LegionResult.new()
	root.add_child(result)
	result.show_result(true, {"map_title": "Пустырь", "cauldron_hp": 185,
		"cauldron_max": 200, "kills": 10, "lost": 2, "time": 173.0}, 3, true, false, rewards)
	_check(result.find_child("ExperienceBar", true, false) != null, "итог показывает полосу опыта")
	await create_timer(1.0).timeout
	var experience := result.find_child("ExperienceBar", true, false) as ProgressBar
	_check(experience.value == 110.0 and experience.max_value == 150.0
		and (result.find_child("ExperienceCaption", true, false) as Label).text.contains("40 опыта"),
		"анимация завершилась в правильном разряде")
	var counters := result.find_child("RewardCounters", true, false) as Label
	_check(counters.text == "Премия: +75 · Опыт: +120",
		"счётчики дошли до выданной награды")
	var hp := result.find_child("CauldronHealth", true, false) as ProgressBar
	_check(hp != null and hp.value == 185 and hp.max_value == 200,
		"HP Котла показаны полосой")
	var navigation := result.find_child("Navigation", true, false)
	var same_row := true
	for button in result.find_children("*", "Button", true, false):
		if button.get_parent() != navigation:
			same_row = false
	_check(same_row, "все кнопки итога стоят в одной нижней строке")
	var backdrop := result.get_child(0) as ColorRect
	_check(backdrop != null and backdrop.color.a < 0.8, "под итогом виден затемнённый бой")
	var loss := LegionResult.new()
	root.add_child(loss)
	loss.show_result(false, {}, 0, false)
	var loss_title: Label
	for label in loss.find_children("*", "Label", true, false):
		if label.text == "Договор расторгнут":
			loss_title = label
	_check(loss_title != null and loss_title.get_theme_color("font_color") == UiStyle.BAD,
		"заголовок поражения красный")
	await process_frame
	loss.queue_free()
	result.queue_free()
	await process_frame
	var dossier := DossierView.new()
	root.add_child(dossier)
	UiStyle.fill_rect(dossier)
	dossier.configure()
	_check(dossier.find_child("RankLine", true, false) == null,
		"разряд и оставшийся опыт не дублируются в шапке")
	var interactive := 0
	for btn in dossier.find_children("RowButton", "Button", true, false):
		if btn.focus_mode == Control.FOCUS_ALL:
			interactive += 1
	_check(interactive == AmendmentDb.ORDER.size(), "все 20 карт каталога открывают условия")
	_check(dossier.find_child("RankTrack", true, false) != null, "Досье показывает цепочку разрядов")
	await process_frame
	var catalog_button := dossier.find_child("RowButton", true, false) as Button
	await _check_detail_focus(catalog_button, "AmendmentDetails", "строке каталога")
	var rank_button := dossier.find_child("Rank10", true, false) as Button
	var scrollbar := dossier.scroll().get_v_scroll_bar()
	_check(not scrollbar.visible or not rank_button.get_global_rect().intersects(
		scrollbar.get_global_rect()), "Разряд 10 не перекрыт полосой прокрутки")
	await _check_detail_focus(rank_button, "RankDetails", "кнопке разряда")
	var artifacts: Array[StringName] = [&"clip_of_fate", &"lightning_rod", &"golden_pen"]
	Campaign.set_run_items(artifacts)
	dossier.show_tab(DossierView.TAB_ITEMS)
	_check(_text(dossier).contains("Z") and not _text(dossier).contains("Ку"),
		"описания и синергии артефактов называют переназначенную молнию")
	dossier.queue_free()
	await process_frame
	Campaign.unlock_all()
	Controls.rebind(&"cast_w", KEY_X)
	Controls.rebind(&"rally", KEY_V)
	var briefing := Briefing.new()
	root.add_child(briefing)
	briefing.populate(Campaign.maps()[2])
	_check(_text(briefing).contains("X") and _text(briefing).contains("V")
		and not _text(briefing).contains("Дубль-вэ") and not _text(briefing).contains("Эр (R)"),
		"плашка «Новое» подставляет текущие клавиши навыка и Сбора")
	briefing.queue_free()
	await process_frame
	_test_v3()
	_test_chips()
	await _test_keyboard_actions()
	await _test_result_fit()
	_check(ProgressionUi.rank_openings(2).contains("Ночная смена")
		and ProgressionUi.rank_openings(2).contains("Бесплатная смета"),
		"разряд 2 обещает обе карты, а не только первую")
	_check(ProgressionUi.rank_openings(4).contains("второе место"),
		"разряд 4 заранее показывает второе место подготовки")
	Controls.reset()
	print("LEGION PROGRESSION UX: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails else 0)


func _check_detail_focus(button: Button, popup_name: String, label: String) -> void:
	button.grab_focus()
	await _enter()
	var popup := root.find_child(popup_name, true, false) as AcceptDialog
	_check(popup != null and popup.visible, "Enter открывает условия: " + label)
	if popup != null:
		popup.get_ok_button().grab_focus()
		popup.get_ok_button().pressed.emit()
		await process_frame
		_check(button.has_focus(), "закрытие условий возвращает фокус " + label)


func _test_battle_item_text() -> void:
	var world := (load("res://scenes/legion_world.tscn") as PackedScene).instantiate() as LegionWorld
	world.embedded = true
	root.add_child(world)
	await process_frame
	world.dev["spawn_units"] = "0"
	world.dev["no_waves"] = "1"
	world.start_map("wasteland")
	world.set_process(false)
	var bar := LegionItemBar.new()
	root.add_child(bar)
	bar.setup(world)
	world.items.grant(&"golden_pen", Vector2.INF)
	var tooltip := String(bar.slot_info(0)["text"])
	_check(tooltip.contains("Z") and not tooltip.contains("Ку"),
		"боевой tooltip артефакта использует Z после Q → Z")
	bar._land(&"golden_pen", true)
	var card := String(bar.current_card()["text"])
	_check(card.contains("Z") and not card.contains("Ку"),
		"карточка выпадения артефакта использует Z")
	var messages: Array[String] = []
	var on_text := func(kind: StringName, data: Dictionary) -> void:
		if kind == &"text":
			messages.append(String(data["text"]))
	world.items.fx_event.connect(on_text)
	world.hero._cd[LegionHero.SLOT_Q] = 5.0
	world._charge_feedback(Vector2(600, 300), true)
	_check(messages.has("Z готова!"), "точный срыв с Золотым пером сообщает «Z готова!»")
	world.items.fx_event.disconnect(on_text)
	bar.queue_free()
	world.queue_free()
	await process_frame


func _test_v3() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("progression", "version", 3)
	cfg.set_value("hero", "xp", 450)
	cfg.set_value("meta", "bounty", 117)
	cfg.set_value("meta", "upgrades", ["bulk_ink"])
	cfg.set_value("meta", "pending_reward", "bridge")
	cfg.set_value("meta", "draft_options", ["carbon_copy", "ghost_contract"])
	cfg.set_value("meta", "preparations", ["souls"])
	cfg.set_value("meta", "prep_last", ["souls"])
	cfg.set_value("meta", "shop_mana", 0)
	cfg.set_value(Campaign.ENDLESS_SECTION, "shop_range_laborer", 2)
	var legacy := cfg.encode_to_text()
	var path := "user://progression_ux_v3.cfg"
	_check(RunProgression.migrate(cfg, path), "старое сохранение v3 читается")
	_check(not cfg.has_section_key("meta", "shop_mana")
		and not cfg.has_section_key(Campaign.ENDLESS_SECTION, "shop_range_laborer"),
		"миграция убирает мёртвые shop_* из v3")
	_check(int(cfg.get_value("hero", "xp")) == 450
		and int(cfg.get_value("meta", "bounty")) == 117
		and cfg.get_value("meta", "upgrades") == ["bulk_ink"]
		and cfg.get_value("meta", "pending_reward") == "bridge"
		and cfg.get_value("meta", "preparations") == ["souls"]
		and cfg.get_value("meta", "prep_last") == ["souls"]
		and cfg.get_value("meta", "draft_options") == ["carbon_copy", "ghost_contract"],
		"миграция сохраняет опыт, премию, сборку, награду, предложение и подготовку")
	var first := cfg.encode_to_text()
	_check(RunProgression.migrate(cfg, path) and cfg.encode_to_text() == first,
		"повторная миграция не меняет сохранение и не начисляет премию снова")
	var disk := SafeConfig.load_file(path)
	_check(disk.encode_to_text() == first, "миграция v3 действительно сохранена и перечитывается")
	_check(cfg.get_value(Campaign.ENDLESS_SECTION, "legacy_purchases", {}).get(
		"shop_range_laborer", 0) == 2, "ненулевые старые покупки сохранены в архиве")
	var blocked := "user://progression_ux_blocked.cfg"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(blocked + ".tmp"))
	cfg.clear()
	cfg.parse(legacy)
	_check(not RunProgression.migrate(cfg, blocked) and cfg.encode_to_text() == legacy,
		"ошибка записи откатывает миграцию целиком, награда не теряется")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(blocked + ".tmp"))
	_check(RunProgression.migrate(cfg, blocked), "миграция повторяется после освобождения диска")


func _test_chips() -> void:
	var entries := MetaMods.delta_entries({"respawn_mult_laborer": -0.4,
		"respawn_mult_guard": -0.4, "ability_mana_mult": 0.25, "q_dmg": 0.4})
	_check(entries.size() == 3, "одинаковый эффект трёх видов объединён в один чип")
	_check(entries[0]["benefit"] and String(entries[0]["text"]).begins_with("Польза:")
		and String(entries[0]["text"]).contains("время возврата"),
		"меньше времени возврата — польза со словами, а не только цветом")
	_check(not entries[1]["benefit"] and String(entries[1]["text"]).contains("Цена:")
		and String(entries[1]["text"]).contains("цена способностей"),
		"больше расхода маны — цена, а не запас")
	_check(LegionMetaCfg.rank_progress(3200)["maxed"]
		and int(LegionMetaCfg.rank_progress(450)["level"]) == 4,
		"полоса опыта корректна на пороге и максимальном разряде")


func _enter() -> void:
	var key := InputEventKey.new()
	key.keycode = KEY_ENTER
	key.pressed = true
	Input.parse_input_event(key)
	await process_frame
	key.pressed = false
	Input.parse_input_event(key)
	for i in 4:
		await process_frame


func _test_keyboard_actions() -> void:
	var result := LegionResult.new()
	root.add_child(result)
	var actions: Array[String] = []
	result.next.connect(func() -> void: actions.append("next"))
	result.retry.connect(func() -> void: actions.append("retry"))
	result.show_result(true, {}, 3, true)
	for i in 5:
		await process_frame
	await _enter()
	_check(actions == ["next"], "Enter на итоге вызывает только главное действие")
	result.queue_free()
	await process_frame
	Campaign.reset()
	Campaign.unlock_all()
	Campaign.add_bounty(90)
	Campaign.set_pending_reward("gatehouse")
	var picker := UpgradePicker.new()
	root.add_child(picker)
	var choices: Array[StringName] = []
	picker.picked.connect(func(id: StringName) -> void: choices.append(id))
	picker.call_deferred("offer", [&"bulk_ink", &"ghost_clause", &"carbon_copy"])
	for i in 5:
		await process_frame
	await _enter()
	_check(choices == [&"bulk_ink"] and Campaign.bounty() == 90,
		"Enter подписывает один раз, не списывая премию за переброску")
	choices.clear()
	picker._reroll.grab_focus()
	await _enter()
	_check(choices.is_empty() and Campaign.bounty() == 60,
		"Enter на переброске оплачивает только переброску, не подписывает")
	var row := picker._cards_box.get_child(1) as ProgressionRow
	row.button().grab_focus()
	await _enter()
	_check(choices == [row.amendment_id] and Campaign.bounty() == 60,
		"Enter на строке подписывает только выбранную карту")
	picker.queue_free()
	await process_frame


## Те же полные вводы используются для кадров; последний — запас на сочетание всех полей.
static func result_cases() -> Array[Dictionary]:
	var stats := {"map_title": "Пустырь", "cauldron_hp": 120, "cauldron_max": 200,
		"kills": 87, "lost": 14, "charges": 6, "refreshes": 9, "releases_manual": 2,
		"time": 312.0, "debrief": {"damage": 80.0, "sources": {"shield_inspector": 80.0},
			"roads": {"north": 80.0}, "road_titles": {"north": "северные ворота"},
			"waves": {"3": 80.0}, "first_at": 132.0}}
	var reward := {"bounty": 75, "xp": 120, "xp_before": 110, "xp_after": 230,
		"kassa": 15, "kassa_souls": 30}
	var rank := reward.duplicate(true)
	rank.merge({"xp_before": 90, "xp_after": 210, "leveled_up": true,
		"level_before": 1, "level": 2}, true)
	var defeat := stats.duplicate(true)
	defeat["cauldron_hp"] = 0
	defeat["debrief"].merge({"damage": 200.0, "sources": {"shield_inspector": 200.0},
		"roads": {"north": 200.0}, "waves": {"3": 200.0}}, true)
	var run := stats.duplicate(true)
	run.merge({"map_title": "Объект 7", "tenure": 3, "souls": 120, "bounty": 20,
		"kassa": 15, "has_breaches": true, "breach_spawned": 4, "breach_leaks": 0}, true)
	return [
		{"id": "campaign_victory", "stats": stats, "rewards": reward},
		{"id": "campaign_rankup", "stats": stats, "rewards": rank},
		{"id": "campaign_defeat", "stats": defeat, "victory": false,
			"rewards": {"bounty": 10, "xp": 42, "xp_before": 210, "xp_after": 252,
				"kassa_souls": 30}},
		{"id": "campaign_complete", "stats": stats, "rewards": rank, "complete": true},
		{"id": "endless_victory", "stats": run, "endless": true},
		{"id": "full_stress", "stats": run, "endless": true, "rewards": rank, "stars": 2},
	]


static func show_case(result: LegionResult, data: Dictionary) -> void:
	var victory := bool(data.get("victory", true))
	var endless := bool(data.get("endless", false))
	var complete := bool(data.get("complete", false))
	result.show_result(victory, data["stats"], int(data.get("stars", 0 if endless else 2)),
		victory and not complete, complete, data.get("rewards", {}), not endless,
		not endless, endless)


func _test_result_fit() -> void:
	var previous_size := root.size
	for window_size: Vector2i in [Vector2i(1280, 720), Vector2i(960, 540)]:
		root.size = window_size
		for data in result_cases():
			var result := LegionResult.new()
			root.add_child(result)
			show_case(result, data)
			await create_timer(1.0).timeout
			var scroll := result.find_children("*", "ScrollContainer", true, false)[0] as ScrollContainer
			var content := scroll.get_child(0) as Control
			var tag := "%s %dx%d" % [data["id"], window_size.x, window_size.y]
			print("RESULT FIT %s content=%.0f visible=%.0f viewport=%s" % [tag,
				content.size.y, scroll.size.y, root.get_visible_rect().size])
			_check(content.size.y <= scroll.size.y and not scroll.get_v_scroll_bar().visible,
				"итог целиком без прокрутки: " + tag)
			var debrief := result.find_child("BattleDebrief", true, false) as Control
			_check(debrief.visible and debrief.get_child_count() == 4
				and scroll.get_global_rect().encloses(debrief.get_global_rect()),
				"разбор из трёх строк полностью виден: " + tag)
			var nav := result.find_child("Navigation", true, false) as Control
			_check(root.get_visible_rect().encloses(nav.get_global_rect()),
				"кнопки в пределах экрана: " + tag)
			var rows := result.find_children("StatRow*", "Control", true, false)
			var compact := rows.size() >= 7
			for row in rows:
				compact = compact and row.size.y <= 28.0
			_check(compact, "строки статистики не растягиваются: " + tag)
			var stars := result.find_child("ResultStars", true, false) as Control
			_check(stars == null or stars.size.y <= 32, "звёзды не выше 32 px: " + tag)
			var counters := result.find_child("RewardCounters", true, false) as Label
			var reward_panel := result.find_child("RewardPanel", true, false) as Control
			_check(counters == null or counters.global_position.y - reward_panel.global_position.y < 64,
				"награда сразу под заголовком: " + tag)
			if data.has("endless"):
				_check(_text(rows[0]).contains("Объектов пройдено")
					and _text(rows[4]).contains("HP Котла"), "строки забега перед HP, как на базе")
			if data["id"] == "campaign_defeat":
				_check(_text(result).contains("Премия: +10 · Опыт: +42")
					and _text(result).contains("Дальше —"), "поражение: награда и следующий шаг")
			result.queue_free()
			await process_frame
	root.size = previous_size
