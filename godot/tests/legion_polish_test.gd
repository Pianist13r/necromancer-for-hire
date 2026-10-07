extends SceneTree
##
## Регресс полировки прокачки перед рекламой (07.10.2026, сессия 57cf698e, D-1007-P1…P4):
## находки живой партии camp-1007 (B-421, B-423, B-424, B-426) и прохода мышью по экранам меты.
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_polish_test.gd -- --mute
##
## Этап 1 (тексты и мелкие поломки):
##  1) B-423: цена на кнопке вида («12 маны за аршин») обновляется, когда множитель цены меняется
##     без смены выбранного вида (раньше подпись пересчитывалась только при смене состояния кнопки);
##  2) B-424: молния Ку в текстах карт и метках чипов — «молния», слово «разряд» осталось ступени;
##  3) итог боя называет новый разряд и что он открыл, а не «Новый уровень героя! (N)»;
##  4) экран замены: подсказка «что вычеркнуть» — широкая строка над полосой, а не столбик по букве;
##  5) B-426: поправка к способности, которую игрок ещё не видел, помечена картой, где та появится;
##  6) у каждой поправки своя иконка, не иконка артефакта; пакеты подготовки — тоже свои;
##  7) подзаголовок выбора говорит «кампания», а не «забег»; B-421 — как поправка попадает в слот;
##  8) чипы прибавочных ключей со сроком — с единицей («−2 с»), минус — типографский.
##
## Этап 3 (D-1007-P1/P2/P5): «Контора» как экран убрана — подготовка на брифинге (PrepPanel):
##  9) на брифинге кампании и забега нет кнопки «Контора…», есть панель подготовки; в меню нет
##     карточки CardOffice;
## 10) щелчок по «Подъёмным» списывает 35 премии и кладёт пакет, повторный — полный возврат;
##     при одном месте второй пакет недоступен;
## 11) «Действует»: полоса поправок — когда они есть, строка артефактов — когда они есть;
## 12) D-1007-P5: взятое запоминается — после боя следующий брифинг берёт его сам (премия
##     списана), снятое щелчком не возвращается, при нехватке премии ничего не берётся.
##
## Этап 4 (D-1007-P2): одно «Досье» вместо «Героя», «Досье некроманта» и «Досье артефактов»:
## 13) в меню карточка «Досье», «Героя» нет; экран из меню — вкладки «Поправки» (по умолчанию)
##     и «Артефакты (N)» с артефактами Campaign.run_items(), без счётчиков боя; вкладки
##     переключаются;
## 14) в паузе кнопка «Досье» (в бою кампании — даже без артефактов); оверлей — тот же виджет на
##     вкладке «Артефакты» со счётчиком срабатываний, переключается на «Поправки».
## Итог «LEGION POLISH: N/M OK»; код выхода 1, если что-то упало. Сохранение временное.
##

const SAVE := "user://legion_polish_test.cfg"
const WORLD_SCENE := "res://scenes/legion_world.tscn"
const MAIN_SCENE := "res://scenes/legion.tscn"

var _fails := 0
var _checks := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(cond: bool, what: String) -> void:
	_checks += 1
	if cond:
		print("  ok   ", what)
	else:
		_fails += 1
		print("  FAIL ", what)


func _run() -> void:
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	Campaign.use_campaign_scope()
	await _test_kind_price_refresh()
	_test_lightning_word()
	await _test_result_rank_line()
	await _test_replace_hint()
	await _test_unseen_ability_note()
	_test_icons_distinct()
	await _test_picker_texts()
	_test_chip_units()
	# Этап 2 (D-1007-P4, B-422)
	await _test_picker_select_then_sign()
	await _test_result_no_maps_after_win()
	await _test_map_select_offers_pending()
	# Этап 3 (D-1007-P1/P2/P5)
	await _test_stage3_briefing_prep()
	# Этап 4 (D-1007-P2)
	await _test_stage4_menu_dossier()
	await _test_stage4_pause_dossier()
	await _test_dossier_upgrades_off()
	await _test_prep_double_click()
	await _test_picker_real_input()
	Campaign.reset()
	var abs_path := ProjectSettings.globalize_path(SAVE)
	if FileAccess.file_exists(SAVE):
		DirAccess.remove_absolute(abs_path)
	print("LEGION POLISH: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


## Все Label-потомки узла (текст для проверок).
func _labels(node: Node) -> Array[Label]:
	var out: Array[Label] = []
	for c in node.find_children("*", "Label", true, false):
		out.append(c as Label)
	return out


func _texts(node: Node) -> String:
	var parts: PackedStringArray = []
	for l in _labels(node):
		parts.append(l.text)
	return "\n".join(parts)


func _test_kind_price_refresh() -> void:
	print("— B-423: цена вида на кнопке следует за множителем")
	var scene: PackedScene = load(WORLD_SCENE)
	var w := scene.instantiate() as LegionWorld
	w.dev["no_waves"] = "1"
	w.dev["spawn_units"] = "0"
	root.add_child(w)
	await process_frame
	w.start_map("wasteland")
	await process_frame
	var bars := w.hud.find_children("*", "LegionKindBar", true, false)
	_check(bars.size() == 1, "полоса видов найдена")
	if bars.size() != 1:
		w.queue_free()
		return
	var bar := bars[0] as LegionKindBar
	var kind: StringName = LegionCfg.KIND_ORDER[0]
	bar._process(LegionCfg.ASSIGN_INTERVAL + 0.01)
	var price := bar.buttons[0].find_child("Price", true, false) as Label
	var before := price.text
	w.my_field().mana_cost_mult *= 1.25
	bar._process(LegionCfg.ASSIGN_INTERVAL + 0.01)
	_check(price.text == bar._price_text(kind) and price.text != before,
		"подпись пересчитана без смены вида: «%s» → «%s»" % [before, price.text])
	w.queue_free()
	await process_frame


func _test_lightning_word() -> void:
	print("— B-424: молния Ку — «молния», не «разряд»")
	var bad: Array[String] = []
	for id: String in AmendmentDb.CARDS:
		var c: Dictionary = AmendmentDb.CARDS[id]
		for field: String in ["text", "tradeoff", "hint"]:
			if String(c.get(field, "")).to_lower().contains("разряд"):
				bad.append("%s.%s" % [id, field])
		if AmendmentDb.short_text(StringName(id)).to_lower().contains("разряд"):
			bad.append("%s.short" % id)
	for key: String in MetaMods.KEY_LABELS:
		if String(MetaMods.KEY_LABELS[key]).contains("разряд"):
			bad.append("KEY_LABELS." + key)
	_check(bad.is_empty(), "«разряд» в текстах молнии: %s" % [bad])
	_check(String(Controls.TITLES[&"cast_q"]).contains("олни"),
		"клавиша Ку в настройках — «Молния»")
	_check(AmendmentDb.short_text(&"carbon_copy").contains("олни"),
		"«Копия верна» говорит о молнии")


func _test_result_rank_line() -> void:
	print("— итог боя: новый разряд и что он открыл")
	var r := LegionResult.new()
	root.add_child(r)
	await process_frame
	r.show_result(true, {"map_title": "Пустырь", "kills": 3}, 3, true, false,
		{"bounty": 75, "xp": 110, "leveled_up": true, "level": 2, "level_before": 1})
	await process_frame
	var text := _texts(r)
	_check(not text.contains("уровень героя"), "нет «уровня героя»")
	_check(text.contains("Новый разряд 2"), "строка «Новый разряд 2»")
	_check(text.contains("«Ночная смена»") and text.contains("«Бесплатная смета»"),
		"названы обе открытые поправки разряда 2")
	_check(text.contains("Премия") and text.contains("перед боем"),
		"сказано, на что премия")
	r.show_result(true, {"map_title": "Проходная"}, 3, true, false,
		{"bounty": 75, "xp": 110, "leveled_up": true, "level": 4, "level_before": 3})
	await process_frame
	text = _texts(r)
	_check(text.contains("Новый разряд 4") and text.contains("второе место подготовки"),
		"разряд 4 называет второе место подготовки")
	r.queue_free()
	await process_frame


func _test_replace_hint() -> void:
	print("— экран замены: подсказка строкой над полосой")
	Campaign.reset()
	Campaign.use_campaign_scope()
	Campaign.unlock_all()
	var raw := Campaign.raw_file()
	raw.set_value("meta", "upgrades", ["ghost_clause", "living_queue", "bulk_ink"])
	Campaign.save_raw()
	var p := UpgradePicker.new()
	root.add_child(p)
	await process_frame
	p.offer([&"lean_staff", &"paper_shield"])
	await process_frame
	p.choose(&"lean_staff")
	await process_frame
	await process_frame
	var hint: Label = null
	for l in _labels(p):
		if l.is_visible_in_tree() and l.text.contains("которую вычеркнуть"):
			hint = l
	_check(hint != null, "подсказка про вычёркивание видна")
	if hint != null:
		_check(hint.size.x >= 300.0, "подсказка широкая (%.0f px), не столбик" % hint.size.x)
		_check(hint.get_global_rect().position.y < p._strip.get_global_rect().position.y,
			"подсказка над полосой слотов")
	p.queue_free()
	await process_frame


func _test_unseen_ability_note() -> void:
	print("— B-426: поправка к ещё не виденной способности помечена")
	Campaign.reset()
	Campaign.use_campaign_scope()
	Campaign.unlock_all()   # «Два отдела» открыта, но не пройдена — Аврал игрок ещё не видел
	var p := UpgradePicker.new()
	root.add_child(p)
	await process_frame
	p.offer([&"overtime_cycle", &"bulk_ink"])
	await process_frame
	var rows := p.find_children("*", "ProgressionRow", true, false)
	var aurral := ""
	var plain := ""
	for row in rows:
		var pr := row as ProgressionRow
		if pr.amendment_id == &"overtime_cycle":
			aurral = _texts(pr)
		elif pr.amendment_id == &"bulk_ink":
			plain = _texts(pr)
	_check(aurral.contains("«Два отдела»"), "«Ненормированный день» называет карту Аврала")
	_check(not plain.contains("появится"), "у обычной поправки пометки нет")
	p.queue_free()
	await process_frame
	# Пройденная «Два отдела» — пометка не нужна.
	Campaign.raw_file().set_value("progress", "fork_stars", 2)
	Campaign.save_raw()
	var p2 := UpgradePicker.new()
	root.add_child(p2)
	await process_frame
	p2.offer([&"overtime_cycle"])
	await process_frame
	_check(not _texts(p2).contains("«Два отдела»"), "после победы на «Двух отделах» пометки нет")
	p2.queue_free()
	await process_frame


func _test_icons_distinct() -> void:
	print("— иконки поправок и подготовки свои и разные")
	var seen := {}
	var dup: Array[String] = []
	var item_like: Array[String] = []
	for id: String in AmendmentDb.CARDS:
		var icon := String(AmendmentDb.CARDS[id].get("icon", ""))
		if seen.has(icon):
			dup.append("%s=%s" % [id, seen[icon]])
		seen[icon] = id
		if icon.begins_with("item_") or icon == "perk_brisk_exit":
			item_like.append("%s:%s" % [id, icon])
		_check(LegionIcons.tex(icon) != null, "иконка %s существует (%s)" % [icon, id])
	for id: String in AmendmentDb.PREPARATIONS:
		var icon := String(AmendmentDb.PREPARATIONS[id].get("icon", ""))
		if seen.has(icon):
			dup.append("%s=%s" % [id, seen[icon]])
		seen[icon] = id
	_check(dup.is_empty(), "без повторов: %s" % [dup])
	_check(item_like.is_empty(), "не иконки артефактов и не тёмная brisk_exit: %s" % [item_like])


func _test_picker_texts() -> void:
	print("— подзаголовок выбора: кампания; B-421 — откуда поправки")
	Campaign.reset()
	Campaign.use_campaign_scope()
	var p := UpgradePicker.new()
	root.add_child(p)
	await process_frame
	p.offer([&"bulk_ink"])
	await process_frame
	var text := _texts(p)
	_check(text.contains("кампани") and not text.contains("правило забега"),
		"выбор говорит о кампании")
	p.queue_free()
	var h := HeroScreen.new()
	root.add_child(h)
	await process_frame
	text = _texts(h)
	_check(text.contains("после каждой победы"), "досье: поправку предлагают после победы (B-421)")
	_check(not text.contains("в базе"), "досье без жаргона «в базе»")
	h.queue_free()
	await process_frame


func _test_chip_units() -> void:
	print("— чипы: единица срока и типографский минус")
	var chips := MetaMods.delta_chips({"seg_ttl_bonus": -2.0})
	_check(chips.size() == 1 and chips[0].contains("−2 с"), "срок участка «−2 с»: %s" % [chips])
	var pct := MetaMods.delta_chips({"mana_cost_mult": -0.35})
	_check(pct.size() == 1 and pct[0].begins_with("−35"), "процент с «−»: %s" % [pct])


## Этап 2: щелчок по строке выделяет, подписывает кнопка с названием; двойной щелчок — сразу.
func _test_picker_select_then_sign() -> void:
	print("— B-422: выбрать, потом подписать")
	Campaign.reset()
	Campaign.use_campaign_scope()
	Campaign.unlock_all()
	var p := UpgradePicker.new()
	root.add_child(p)
	await process_frame
	var got: Array[StringName] = []
	p.picked.connect(func(id: StringName) -> void: got.append(id))
	p.offer([&"bulk_ink", &"paper_shield", &"ghost_clause"])
	await process_frame
	var primary := p.find_child("NavPrimary", true, false) as Button
	_check(primary != null and primary.text.contains("Подписать «Мелкий оптовый шрифт»"),
		"главная кнопка называет выделенную: «%s»" % (primary.text if primary else "—"))
	var rows: Array[ProgressionRow] = []
	for c in p.find_children("*", "ProgressionRow", true, false):
		rows.append(c as ProgressionRow)
	_check(rows.size() == 3, "три строки предложения")
	if rows.size() == 3:
		rows[1].button().pressed.emit()   # щелчок по второй строке
		await process_frame
		_check(got.is_empty(), "щелчок по строке НЕ подписывает")
		_check(p.has_method("chosen") and p.call("chosen") == &"paper_shield",
			"щелчок выделил вторую строку")
		_check(rows[1].details().visible and not rows[0].details().visible,
			"детали раскрыты только у выделенной")
		_check(primary.text.contains("«Бумажная броня»"), "кнопка переименовалась: " + primary.text)
		primary.pressed.emit()
		await process_frame
		_check(got == [&"paper_shield"], "кнопка подписала выделенную: %s" % [got])
		got.clear()
		if rows[2].has_signal("activated"):
			rows[2].emit_signal("activated", &"ghost_clause")
		_check(got == [&"ghost_clause"], "двойной щелчок подписывает сразу: %s" % [got])
	p.queue_free()
	await process_frame


func _test_result_no_maps_after_win() -> void:
	print("— итог победы: без «Карт», главное — «Дальше»")
	var r := LegionResult.new()
	root.add_child(r)
	await process_frame
	r.show_result(true, {"map_title": "Пустырь"}, 3, true, false, {})
	await process_frame
	var names: Array[String] = []
	for b in r.find_children("*", "Button", true, false):
		names.append((b as Button).text)
	_check(not names.has("Карты"), "после победы с наградой «Карт» нет: %s" % [names])
	_check(names.has("Дальше: выбор поправки"), "«Дальше: выбор поправки» на месте")
	r.show_result(false, {"map_title": "Пустырь"}, 0, false, false, {})
	await process_frame
	names.clear()
	for b in r.find_children("*", "Button", true, false):
		if not b.is_queued_for_deletion():
			names.append((b as Button).text)
	_check(names.has("Карты"), "после поражения «Карты» остаются")
	r.queue_free()
	await process_frame


## Экран карт при висящей награде: сперва выбор поправки, потом брифинг ВЫБРАННОЙ карты.
func _test_map_select_offers_pending() -> void:
	print("— экран карт не обходит незабранную поправку")
	Campaign.reset()
	Campaign.use_campaign_scope()
	Campaign.set_intro_cutscene_seen()
	Campaign.unlock_all()
	Campaign.set_pending_reward("bridge")
	var scene: PackedScene = load(MAIN_SCENE)
	var main := scene.instantiate() as LegionMain
	root.add_child(main)
	for i in 3:
		await process_frame
	main.show_map_select()
	await process_frame
	var ms := main.screen as MapSelect
	_check(ms != null, "экран карт открыт")
	if ms != null:
		ms.map_chosen.emit("fork")
	for i in 3:
		await process_frame
	_check(main.screen is UpgradePicker, "выбор карты при висящей награде открыл выбор поправки")
	if main.screen is UpgradePicker:
		var p := main.screen as UpgradePicker
		var opts := p.offered()
		if not opts.is_empty():
			p.picked.emit(opts[0])
		for i in 3:
			await process_frame
		_check(Campaign.pending_reward() == "", "награда забрана")
		var text := _texts(main.screen) if main.screen != null else ""
		_check(main.screen is Briefing and text.contains("Два отдела"),
			"после подписи — брифинг выбранной карты «Два отдела»")
	main.queue_free()
	for i in 2:
		await process_frame


# ── Этап 3: подготовка на брифинге ─────────────────────────────────────────────────────────────

## Строка пакета подготовки id на экране (ProgressionRow по amendment_id) или null. Без ссылок на
## новые классы — раздел должен давать FAIL, а не падать разбором, на коде до этапа 3.
func _prep_row(screen: Node, id: String) -> Node:
	if screen == null:
		return null
	var panel := screen.find_child("PrepPanel", true, false)
	if panel == null:
		return null
	for n in panel.find_children("*", "", true, false):
		if n.is_queued_for_deletion():
			continue
		if n.has_method("button") and n.get("amendment_id") == StringName(id):
			return n
	return null


func _press_prep(screen: Node, id: String) -> void:
	var row := _prep_row(screen, id)
	if row != null:
		(row.call("button") as Button).pressed.emit()
	await process_frame


func _open_briefing(main: LegionMain, map_id: String) -> Control:
	main.show_briefing(map_id)
	for i in 3:
		await process_frame
	return main.screen


func _office_buttons(screen: Node) -> Array[String]:
	var out: Array[String] = []
	if screen == null:
		return out
	for b in screen.find_children("*", "Button", true, false):
		if (b as Button).text.begins_with("Контора"):
			out.append((b as Button).text)
	return out


func _test_stage3_briefing_prep() -> void:
	print("— этап 3: подготовка на брифинге, «Конторы» нет")
	Campaign.reset()
	Campaign.use_campaign_scope()
	Campaign.set_intro_cutscene_seen()
	Campaign.unlock_all()
	Campaign.add_bounty(100)
	var map_id := String(Campaign.maps()[1].get("id", ""))
	var scene: PackedScene = load(MAIN_SCENE)
	var main := scene.instantiate() as LegionMain
	root.add_child(main)
	for i in 3:
		await process_frame
	var b := await _open_briefing(main, map_id)
	_check(b is Briefing, "брифинг кампании открыт")
	_check(_office_buttons(b).is_empty(), "на брифинге нет кнопки «Контора…»: %s"
		% [_office_buttons(b)])
	_check(b != null and b.find_child("PrepPanel", true, false) != null,
		"на брифинге есть панель подготовки")
	_check(b != null and _texts(b).contains("второе место — с разряда 4"),
		"при одном месте сказано, когда откроется второе")
	_check(b != null and b.find_child("ActiveStrip", true, false) == null
		and b.find_child("ActiveItems", true, false) == null,
		"без поправок и артефактов блока «Действует» нет")
	await _press_prep(b, "souls")
	_check(Campaign.bounty() == 65, "щелчок по «Подъёмным» списал 35 премии (%d)"
		% Campaign.bounty())
	_check(RunProgression.preparations() == ["souls"], "пакет взят: %s"
		% [RunProgression.preparations()])
	var souls := _prep_row(b, "souls")
	_check(souls != null and bool(souls.call("is_selected")), "взятая строка выделена")
	var mana := _prep_row(b, "mana")
	_check(mana != null and (mana.call("button") as Button).disabled,
		"при одном месте второй пакет недоступен")
	_check(b != null and _texts(b).contains("мест больше нет"), "причина недоступности названа")
	await _press_prep(b, "souls")
	_check(Campaign.bounty() == 100, "повторный щелчок вернул премию полностью (%d)"
		% Campaign.bounty())
	_check(RunProgression.preparations().is_empty(), "пакет снят")

	print("— этап 3: «Действует» — поправки и артефакты")
	Campaign.add_upgrade(StringName(AmendmentDb.ORDER[0]))
	var arts: Array[StringName] = [&"clip_of_fate"]
	Campaign.set_run_items(arts)
	b = await _open_briefing(main, map_id)
	_check(b != null and b.find_child("ActiveStrip", true, false) != null,
		"есть поправка — на брифинге полоса поправок")
	var items := b.find_child("ActiveItems", true, false) as Label if b != null else null
	_check(items != null and items.text.contains("Скрепка судьбы"),
		"есть артефакт — строка «Артефакты: …» с названием")
	var empty_items: Array[StringName] = []
	Campaign.set_run_items(empty_items)

	print("— этап 3: подготовка запоминается (D-1007-P5)")
	await _press_prep(b, "souls")
	_check(Campaign.bounty() == 65, "взяли «Подъёмные» (%d)" % Campaign.bounty())
	RunProgression.consume_preparation_for_battle()
	_check(RunProgression.preparations().is_empty(), "бой списал подготовку")
	b = await _open_briefing(main, map_id)
	_check(RunProgression.preparations() == ["souls"] and Campaign.bounty() == 30,
		"следующий брифинг взял «Подъёмные» сам и списал премию (%s, %d)"
		% [RunProgression.preparations(), Campaign.bounty()])
	_check(b != null and _texts(b).contains("Взято как в прошлый раз"),
		"пояснение про автоматически взятое")
	await _press_prep(b, "souls")
	_check(Campaign.bounty() == 65 and RunProgression.preparations().is_empty(),
		"снятое щелчком вернуло премию")
	RunProgression.consume_preparation_for_battle()
	b = await _open_briefing(main, map_id)
	_check(RunProgression.preparations().is_empty() and Campaign.bounty() == 65,
		"снятое щелчком в следующий раз не берётся")
	await _press_prep(b, "souls")
	RunProgression.consume_preparation_for_battle()
	Campaign.add_bounty(-Campaign.bounty() + 10)
	b = await _open_briefing(main, map_id)
	_check(RunProgression.preparations().is_empty() and Campaign.bounty() == 10,
		"при нехватке премии не берётся и ничего не списано (%d)" % Campaign.bounty())

	print("— этап 3: брифинг забега и меню без «Конторы»")
	var eb := EndlessBriefing.new()
	root.add_child(eb)
	eb.populate(Campaign.map(map_id), 1, 0, 0, false, "")
	await process_frame
	_check(_office_buttons(eb).is_empty(), "на брифинге забега нет «Контора…»")
	_check(eb.find_child("PrepPanel", true, false) != null, "на брифинге забега есть подготовка")
	eb.queue_free()
	var menu := LegionMenu.new()
	root.add_child(menu)
	await process_frame
	_check(menu.find_child("CardOffice", true, false) == null, "в меню нет карточки «Контора»")
	_check(menu.find_child("CardMaps", true, false) != null
		and menu.find_child("CardDossier", true, false) != null, "«Карты» и «Досье» на месте")
	menu.queue_free()
	main.queue_free()
	for i in 2:
		await process_frame


# ── Этап 4: одно «Досье» ───────────────────────────────────────────────────────────────────────

## Видимые тексты узла построчно (только живые и видимые Label/Button).
func _visible_texts(node: Node) -> Array[String]:
	var out: Array[String] = []
	if node == null:
		return out
	for c in node.find_children("*", "", true, false):
		if c.is_queued_for_deletion() or not (c is Label or c is Button):
			continue
		if not (c as Control).is_visible_in_tree():
			continue
		out.append(String(c.get("text")))
	return out


func _live_child(node: Node, child_name: String) -> Node:
	if node == null:
		return null
	for c in node.find_children(child_name, "", true, false):
		if not c.is_queued_for_deletion():
			return c
	return null


func _press_named(node: Node, child_name: String) -> void:
	var b := _live_child(node, child_name) as Button
	if b != null:
		b.pressed.emit()
	await process_frame


func _test_stage4_menu_dossier() -> void:
	print("— этап 4: «Досье» в меню")
	Campaign.reset()
	Campaign.use_campaign_scope()
	var arts: Array[StringName] = [&"clip_of_fate", &"lightning_rod"]
	Campaign.set_run_items(arts)
	var menu := LegionMenu.new()
	root.add_child(menu)
	await process_frame
	var texts := _visible_texts(menu)
	_check(texts.has("Досье"), "в меню карточка «Досье»")
	_check(not texts.has("Герой"), "карточки «Герой» больше нет")
	menu.queue_free()
	var h := HeroScreen.new()
	root.add_child(h)
	await process_frame
	var t_up := _live_child(h, "TabUpgrades") as Button
	var t_it := _live_child(h, "TabItems") as Button
	_check(t_up != null and t_it != null, "в досье две вкладки")
	_check(t_it != null and t_it.text == "Артефакты (2)", "вкладка артефактов со счётом: %s"
		% (t_it.text if t_it != null else "—"))
	_check(t_up != null and t_up.button_pressed and _live_child(h, "Cards") == null
		and _texts(h).contains("Новую поправку"), "из меню по умолчанию — «Поправки»")
	_check(_texts(h).contains("Разряд 1 · опыт 0. До разряда 2:"), "строка разряда и опыта")
	await _press_named(h, "TabItems")
	var cards := _live_child(h, "Cards")
	_check(cards != null and cards.get_child_count() == 2, "вкладка «Артефакты»: две карточки")
	_check(_texts(h).contains("Скрепка судьбы") and _texts(h).contains("Громоотвод"),
		"артефакты — из Campaign.run_items()")
	_check(_live_child(h, "Uses") == null, "из меню без счётчиков боя")
	_check(_texts(h).contains("Громовая канцелярия · Собрана"), "синергия собрана")
	await _press_named(h, "TabUpgrades")
	_check(_live_child(h, "Cards") == null and _texts(h).contains("Новую поправку"),
		"вкладки переключаются обратно")
	h.queue_free()
	var empty_items: Array[StringName] = []
	Campaign.set_run_items(empty_items)
	h = HeroScreen.new()
	root.add_child(h)
	await process_frame
	await _press_named(h, "TabItems")
	_check(_texts(h).contains("элитные"), "пусто — объяснение, откуда артефакты")
	h.queue_free()
	await process_frame


func _test_stage4_pause_dossier() -> void:
	print("— этап 4: «Досье» из паузы")
	Campaign.reset()
	Campaign.use_campaign_scope()
	Campaign.set_intro_cutscene_seen()
	Campaign.unlock_all()
	var scene: PackedScene = load(MAIN_SCENE)
	var main := scene.instantiate() as LegionMain
	root.add_child(main)
	for i in 3:
		await process_frame
	main.start_battle(String(Campaign.maps()[1].get("id", "")))
	for i in 3:
		await process_frame
	main.world.set_paused(true)
	for i in 3:
		await process_frame
	_check(_visible_texts(main._pause_screen).has("Досье"),
		"в паузе боя кампании без артефактов есть «Досье»")
	main.world.set_paused(false)
	await process_frame
	main.world.items.grant(&"golden_pen")
	main.world.set_paused(true)
	for i in 3:
		await process_frame
	var texts := _visible_texts(main._pause_screen)
	_check(texts.has("Досье") and not texts.has("Досье артефактов"), "кнопка паузы — «Досье»")
	for b in main._pause_screen.find_children("*", "Button", true, false):
		if (b as Button).text.begins_with("Досье"):
			(b as Button).pressed.emit()
			break
	for i in 2:
		await process_frame
	var d: Node = main.get("_dossier")
	var t_it := _live_child(d, "TabItems") as Button
	_check(t_it != null and t_it.button_pressed, "оверлей паузы открыт на вкладке «Артефакты»")
	var uses := _live_child(d, "Uses") as Label
	_check(uses != null and uses.text == "Срабатываний: 0", "у артефакта в бою — счётчик")
	_check(_live_child(d, "TabUpgrades") != null, "в паузе то же досье: есть «Поправки»")
	await _press_named(d, "TabUpgrades")
	_check(_texts(d).contains("Новую поправку"), "из паузы переключается на «Поправки»")
	_check(main.world.paused, "бой остался на паузе")
	if d != null and d.has_method("close"):
		d.call("close")
	main.world.set_paused(false)
	main.queue_free()
	for i in 2:
		await process_frame


## Двойной щелчок по строке подготовки — одно действие «взять», а не «взял и сразу снял»
## (verifier этапа 3): второй щелчок приходит с double_click — строка шлёт activated до pressed.
func _test_prep_double_click() -> void:
	print("— подготовка: двойной щелчок не снимает только что взятое")
	Campaign.reset()
	Campaign.use_campaign_scope()
	Campaign.add_bounty(100)
	var panel := PrepPanel.new()
	panel.name = "PrepPanel"   # _prep_row ищет узел по имени, как на брифинге
	root.add_child(panel)
	await process_frame
	var row := _prep_row(root, "souls")
	_check(row != null, "строка «Подъёмные» найдена")
	if row != null:
		(row.call("button") as Button).pressed.emit()   # первый щелчок — взять
		await process_frame
		var again := _prep_row(root, "souls")   # панель пересобрала строки
		again.emit_signal("activated", &"souls")   # нажатие второго щелчка с double_click
		(again.call("button") as Button).pressed.emit()   # его отпускание
		await process_frame
		_check(RunProgression.preparations().has("souls") and Campaign.bounty() == 65,
			"после двойного щелчка пакет взят, премия 65 (%s, %d)"
			% [RunProgression.preparations(), Campaign.bounty()])
		var third := _prep_row(root, "souls")
		(third.call("button") as Button).pressed.emit()   # отдельный щелчок — снять
		await process_frame
		_check(not RunProgression.preparations().has("souls") and Campaign.bounty() == 100,
			"обычный следующий щелчок снимает с возвратом")
	panel.queue_free()
	await process_frame


## Доводка этапа 2 (verifier): настоящие события через вьюпорт, а не прямой emit сигналов.
func _click(at: Vector2, double := false) -> void:
	# Как в clickwalk_menu: Input.parse_input_event (движение, нажатие, отпускание) по кадрам.
	var sp := root.get_final_transform() * at
	var mv := InputEventMouseMotion.new()
	mv.device = 8
	mv.position = sp
	mv.global_position = sp
	Input.parse_input_event(mv)
	await process_frame
	var down := InputEventMouseButton.new()
	down.device = 8
	down.button_index = MOUSE_BUTTON_LEFT
	down.pressed = true
	down.double_click = double
	down.button_mask = MOUSE_BUTTON_MASK_LEFT
	down.position = sp
	down.global_position = sp
	Input.parse_input_event(down)
	await process_frame
	var up := down.duplicate() as InputEventMouseButton
	up.pressed = false
	up.double_click = false
	up.button_mask = 0
	Input.parse_input_event(up)
	await process_frame
	await process_frame


func _test_picker_real_input() -> void:
	print("— выбор поправки: двойной щелчок по нижней строке, Esc в замене, возврат выделения")
	Campaign.reset()
	Campaign.use_campaign_scope()
	Campaign.unlock_all()
	var p := UpgradePicker.new()
	root.add_child(p)
	await process_frame
	var got: Array[StringName] = []
	p.picked.connect(func(id: StringName) -> void: got.append(id))
	var backs := [0]
	p.back.connect(func() -> void: backs[0] += 1)
	p.offer([&"bulk_ink", &"paper_shield", &"ghost_clause"])
	await process_frame
	await process_frame
	var third: ProgressionRow = null
	for c in p.find_children("*", "ProgressionRow", true, false):
		if (c as ProgressionRow).amendment_id == &"ghost_clause":
			third = c as ProgressionRow
	var at := third.button().get_global_rect().get_center() + Vector2(0.0, 20.0)
	await _click(at)               # первый щелчок — выделить (строка уезжает вверх)
	await _click(at, true)         # второй, с double_click, в ту же точку экрана
	_check(got == [&"ghost_clause"], "двойной щелчок по нижней строке подписал её: %s" % [got])
	p.queue_free()
	await process_frame

	Campaign.raw_file().set_value("meta", "upgrades", ["living_queue", "temp_agency", "lean_staff"])
	Campaign.save_raw()
	var q := UpgradePicker.new()
	root.add_child(q)
	await process_frame
	backs[0] = 0
	q.back.connect(func() -> void: backs[0] += 1)
	q.offer([&"bulk_ink", &"paper_shield", &"ghost_clause"])
	await process_frame
	q.select(&"ghost_clause")
	q.choose(&"ghost_clause")      # три занято — режим замены
	await process_frame
	var esc := InputEventKey.new()
	esc.keycode = KEY_ESCAPE
	esc.physical_keycode = KEY_ESCAPE
	esc.pressed = true
	root.push_input(esc)
	var esc_up := esc.duplicate() as InputEventKey
	esc_up.pressed = false
	root.push_input(esc_up)
	for i in 3:
		await process_frame
	_check(backs[0] == 0, "Esc в замене не уводит в меню (уходов: %d)" % backs[0])
	_check(q._replacing == &"" and q._cards_box.visible, "Esc вернул к предложению")
	_check(q.chosen() == &"ghost_clause",
		"выделение осталось на «Договоре с привидением»: %s" % q.chosen())
	q.queue_free()
	await process_frame
	var chips := MetaMods.delta_chips({"hold_armor": 0.999})
	_check(not chips[0].contains(",") or not chips[0].contains(", "),
		"чип без висячей запятой: %s" % [chips])
	_check(not chips[0].split(" ")[0].ends_with(","), "число чипа не кончается запятой: %s" % [chips])


## Доводка этапа 4 (verifier): в «Схватке» и переигровке вкладка «Поправки» не показывает
## поправки кампании — там они не действуют.
func _test_dossier_upgrades_off() -> void:
	print("— досье: поправки кампании не выдаются за действующие в «Схватке» и переигровке")
	Campaign.reset()
	Campaign.use_campaign_scope()
	Campaign.unlock_all()
	Campaign.raw_file().set_value("meta", "upgrades", ["living_queue", "bulk_ink"])
	Campaign.save_raw()
	var scene: PackedScene = load(WORLD_SCENE)
	var w := scene.instantiate() as LegionWorld
	w.dev["no_waves"] = "1"
	root.add_child(w)
	await process_frame
	w.start_map("wasteland")
	await process_frame
	var camp := DossierView.new()
	root.add_child(camp)
	camp.configure(w.items, DossierView.TAB_UPGRADES)
	await process_frame
	_check(_texts(camp).contains("Живая очередь") and not _texts(camp).contains("не действуют"),
		"бой кампании: поправки в слотах")
	camp.queue_free()
	w.pvp = true
	var duel := DossierView.new()
	root.add_child(duel)
	duel.configure(w.items, DossierView.TAB_UPGRADES)
	await process_frame
	var strip_text := ""
	for s in duel.find_children("*", "SlotStrip", true, false):
		strip_text += _texts(s)
	_check(not strip_text.contains("Живая очередь") and _texts(duel).contains("не действуют"),
		"«Схватка»: слоты пусты, сказано, что поправки не действуют")
	duel.queue_free()
	w.pvp = false
	w.queue_free()
	await process_frame
	Campaign.use_replay_scope()
	var rep := DossierView.new()
	root.add_child(rep)
	rep.configure(null, DossierView.TAB_UPGRADES)
	await process_frame
	_check(_texts(rep).contains("не действуют"), "переигровка: сказано, что поправки не действуют")
	rep.queue_free()
	Campaign.use_campaign_scope()
	await process_frame
