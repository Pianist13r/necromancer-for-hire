class_name LegionResult
extends Control
##
## Экран итога боя: «Договор исполнен» / «Договор расторгнут», звёзды, статистика (любых
## полей может не быть — показываем только то, что пришло), «Дальше»/«Ещё раз»/«Карты»/«Меню».
##

signal next
signal retry
signal maps
signal menu
## D-0927-162: «В коллекцию» — сохранить сгенерированную карту объекта (см. show_collect).
signal collect_pressed


func _ready() -> void:
	UiStyle.fill_rect(self)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


## victory — исход; stats — вольный набор ключей (kills, lost, charges, refreshes, releases,
## releases_manual, cauldron_hp, cauldron_max, time, map_title); stars — заработанные за этот бой
## (0 при поражении); has_next — есть ли ещё непройденная карта дальше по кампании (кнопка
## «Дальше»); campaign_complete — победа на последней карте кампании (ревью, п.7) — отдельный
## текст итога вместо общего «Договор исполнен», «Дальше» всё равно нет (has_next всегда false).
## rewards — meta: Campaign.record_rewards() (задание meta п.7): "bounty"/"xp" сколько получено
## за этот бой, "leveled_up"/"level" — новый уровень героя, если он вырос. {} — не показывать
## строку (напр. dev-кадр без реального боя).
## show_retry/show_maps — mode (verifier 27.09, п.3): «Бесконечный подряд»/«Вызов дня» скрывает
## обе кнопки на экране ПОБЕДЫ объекта — «Ещё раз» переигрывала СТАРУЮ карту уже засчитанного
## объекта и заново его засчитывала (стаж рос 1→2→3 на одном объекте, LegionMain больше не
## подключает retry для забега), «Карты» ведёт на экран карт КАМПАНИИ, которого у забега нет.
## Кампания оба параметра не трогает (default true — прежнее поведение).
## show_collect — D-0927-162: «В коллекцию» на итоге объекта (кампания/переигровка из
## коллекции — false, у них своих сгенерированных карт нет либо карта уже в коллекции).
func show_result(victory: bool, stats: Dictionary, stars: int, has_next: bool,
		campaign_complete: bool = false, rewards: Dictionary = {}, show_retry: bool = true,
		show_maps: bool = true, show_collect: bool = false) -> void:
	for c in get_children():
		c.queue_free()

	var backdrop := ColorRect.new()
	backdrop.color = Color(0.02, 0.01, 0.04, 0.88)
	UiStyle.fill_rect(backdrop)
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(backdrop)

	var box := UiStyle.card_box(self, 560.0, 12)

	var map_title := String(stats.get("map_title", ""))
	var stamp_text := "Договор расторгнут"
	if victory:
		stamp_text = "Кампания пройдена" if campaign_complete else "Договор исполнен"
	var stamp := UiStyle.label(stamp_text, 40, UiStyle.FONT_TITLE,
		UiStyle.GOOD if victory else UiStyle.BAD)
	stamp.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(stamp)

	if map_title != "":
		var sub := UiStyle.label(map_title, 18, UiStyle.FONT_TEXT, UiStyle.TEXT_DIM)
		sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		box.add_child(sub)

	# mode: «Бесконечный подряд»/«Вызов дня» переиспользует этот экран для итога объекта, но
	# звёзд там нет (stars == 0 не значит «худший результат» — значит «эта шкала не при деле»,
	# ставить три пустых было бы неверным сигналом игроку).
	if victory and stars > 0:
		var stars_label := UiStyle.label("★".repeat(stars) + "☆".repeat(3 - stars), 30,
			UiStyle.FONT_TITLE, UiStyle.GOLD)
		stars_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		box.add_child(stars_label)

	box.add_child(_stats_block(stats))
	box.add_child(BattleDebrief.panel(stats.get("debrief", {})))

	if not rewards.is_empty():
		box.add_child(_rewards_block(rewards, victory))

	var primary := "Дальше: выбор поправки" if victory and has_next else "Ещё раз"
	var action := func() -> void:
		if victory and has_next:
			next.emit()
		else:
			retry.emit()
	if not show_retry and not has_next:
		primary = ""
	LegionUi.nav_bar(self, "В главное меню", func() -> void: menu.emit(),
		primary, action)
	if show_maps:
		box.add_child(_make_button("Карты", func() -> void: maps.emit()))
	if show_retry and victory and has_next:
		box.add_child(_make_button("Ещё раз", func() -> void: retry.emit()))
	if show_collect:
		box.add_child(_make_button("В коллекцию", func() -> void: collect_pressed.emit()))



## Печатает только те строки, для которых есть данные — задание прямо требует не выдумывать
## недостающие поля (kills, lost, charges, refreshes, releases, cauldron_hp/_max, time).
func _stats_block(stats: Dictionary) -> Control:
	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 3)

	var lines: Array[String] = []
	# mode: «Бесконечный подряд»/«Вызов дня» кладёт сюда стаж и души забега ПОСЛЕ этого объекта
	# (LegionMain._on_endless_match_ended) — кампания этих ключей не пишет, строка не появится.
	if stats.has("tenure"):
		lines.append("Стаж: %d · Души: %d" % [int(stats["tenure"]), int(stats.get("souls", 0))])
	if stats.has("bounty"):
		lines.append("Премия за объект: +%d" % int(stats["bounty"]))
	if stats.has("kassa"):   # «Касса» (D-1001-01): в забеге — только с победой (поражение — некролог)
		lines.append("Касса: +%d премии" % int(stats["kassa"]))
	if _breach_closed(stats):
		lines.append("Закрыл трещину")
	if stats.has("cauldron_hp") and stats.has("cauldron_max"):
		var hp := float(stats["cauldron_hp"])
		var max_hp := float(stats["cauldron_max"])
		var pct := roundi(100.0 * hp / max_hp) if max_hp > 0.0 else 0
		lines.append("HP Котла: %d / %d (%d%%)" % [int(hp), int(max_hp), pct])
	if stats.has("kills"):
		lines.append("Упокоено проверяющих: %d" % int(stats["kills"]))
	if stats.has("lost"):
		lines.append("Потеряно подрядчиков: %d" % int(stats["lost"]))
	if stats.has("charges"):
		lines.append("Натисков: %d" % int(stats["charges"]))
	if stats.has("refreshes"):
		lines.append("Продлений договора: %d" % int(stats["refreshes"]))
	# Ревью, п.6: раньше все выпуски строя назывались «досрочными», включая естественное
	# таяние срока — оно не решение игрока и не должно звучать как расторжение договора.
	# releases_manual — счётчик именно ручных выпусков (ПКМ), считает LegionWorld.release_segment().
	if stats.has("releases_manual"):
		var manual := int(stats["releases_manual"])
		if manual > 0:
			lines.append("Досрочных расторжений (вручную): %d" % manual)
	elif stats.has("releases"):
		lines.append("Досрочных расторжений: %d" % int(stats["releases"]))
	if stats.has("time"):
		var t := float(stats["time"])
		lines.append("Время на объекте: %d:%02d" % [int(t) / 60, int(t) % 60])

	for line in lines:
		var l := UiStyle.label(line, 17, UiStyle.FONT_TEXT)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		box.add_child(l)
	return box


## meta: премия и опыт за бой, «Новый уровень героя!» при повышении (задание meta п.7).
func _rewards_block(rewards: Dictionary, victory := true) -> Control:
	var box := VBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 2)

	var line := UiStyle.label(
		"Премия: +%d · Опыт героя: +%d" % [int(rewards.get("bounty", 0)), int(rewards.get("xp", 0))],
		16, UiStyle.FONT_TEXT, UiStyle.GOLD)
	line.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 6)
	row.add_child(LegionIcons.rect("premium", 22.0))
	row.add_child(line)
	box.add_child(row)

	# «Касса» (D-1001-01): строка — только если в бою закладывали (LegionMain._grant_kassa)
	if rewards.has("kassa_souls"):
		var kassa := int(rewards.get("kassa", 0))
		var text := "Касса: +%d премии" % kassa
		if not victory:
			text = "Касса сгорела: %d душ" % int(rewards["kassa_souls"])
		var kl := UiStyle.label(text, 16, UiStyle.FONT_TEXT,
			UiStyle.GOLD if victory else UiStyle.BAD)
		kl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		box.add_child(kl)

	if bool(rewards.get("leveled_up", false)):
		var up := UiStyle.label("Новый уровень героя! (%d)" % int(rewards.get("level", 0)), 18,
			UiStyle.FONT_TITLE, UiStyle.GOOD)
		up.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		box.add_child(up)

	return box


func _make_button(text: String, on_pressed: Callable) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.custom_minimum_size = Vector2(150.0, 46.0)
	btn.add_theme_font_override("font", UiStyle.FONT_TITLE)
	btn.add_theme_font_size_override("font_size", 18)
	UiStyle.style_button(btn)
	btn.pressed.connect(on_pressed)
	return btn


func _breach_closed(stats: Dictionary) -> bool:
	var source := stats
	# LegionMain фильтрует поля итога: пока пакет flow не расширил список, читаем мир боя.
	if not source.has("has_breaches") and get_parent() is LegionMain:
		var main := get_parent() as LegionMain
		if main.world != null and main.world.phase in [
				LegionWorld.Phase.VICTORY, LegionWorld.Phase.DEFEAT]:
			source = main.world.stats
	# Отметка — за реально закрытую трещину: были враги из неё и никто не дошёл (verifier 25.09:
	# без проверки breach_spawned отметка вставала даже на поражении в нулевой волне).
	return bool(source.get("has_breaches", false)) and int(source.get("breach_spawned", 0)) > 0 \
		and int(source.get("breach_leaks", 0)) == 0
