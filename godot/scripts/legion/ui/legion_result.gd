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

var _reward_tween: Tween


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
	if _reward_tween != null:
		_reward_tween.kill()
	var map_title := String(stats.get("map_title", ""))
	var stamp_text := "Договор расторгнут"
	if victory:
		stamp_text = "Кампания пройдена" if campaign_complete else "Договор исполнен"
	var shell := ProgressionUi.shell(self, stamp_text, map_title,
		{"shade": 0.64, "title_color": UiStyle.GOOD if victory else UiStyle.BAD})
	var columns := HBoxContainer.new()
	columns.add_theme_constant_override("separation", 24)
	shell["body"].add_child(columns)
	var box := _result_panel(columns, "Этот бой")
	var reward_box := _result_panel(columns, "Награда")

	# mode: «Бесконечный подряд»/«Вызов дня» переиспользует этот экран для итога объекта, но
	# звёзд там нет (stars == 0 не значит «худший результат» — значит «эта шкала не при деле»,
	# ставить три пустых было бы неверным сигналом игроку).
	if victory and stars > 0:
		var stars_label := UiStyle.label("★".repeat(stars) + "☆".repeat(3 - stars), 20,
			UiStyle.FONT_TITLE, UiStyle.GOLD)
		stars_label.name = "ResultStars"
		box.get_node("PanelHeading").add_child(stars_label)

	box.add_child(_stats_block(stats))
	# Полная ширина сохраняет три строки разбора даже с длинными названиями подходов.
	# Он не растягивает ни статистику, ни награду до высоты соседней панели.
	shell["body"].add_child(_debrief_panel(stats.get("debrief", {})))

	if not rewards.is_empty():
		reward_box.add_child(_rewards_block(rewards, victory))
	elif stats.has("tenure"):
		reward_box.add_child(ProgressionUi.text("Премия — на подготовку и переброску. "
			+ "В забеге опыт не начисляется: разряд растёт в кампании.", 19))
	else:
		reward_box.add_child(ProgressionUi.text("Разряд и подписанные поправки — в «Досье».", 19))
	if victory and has_next:
		reward_box.add_child(ProgressionUi.text("Дальше — выберите и подпишите поправку. "
			+ "Она действует до конца %s." % ("забега" if stats.has("tenure") else "кампании"),
			18, UiStyle.GOLD))
	elif not victory:
		reward_box.add_child(ProgressionUi.text("Дальше — «Ещё раз»: подготовьтесь "
			+ "на брифинге и повторите бой." if show_retry else
			"Дальше — в главное меню, чтобы начать новый подряд.", 18, UiStyle.GOLD))

	var primary := "Дальше: выбор поправки" if victory and has_next else "Ещё раз"
	var action := func() -> void:
		if victory and has_next:
			next.emit()
		else:
			retry.emit()
	if not show_retry and not has_next:
		primary = ""
	var nav := LegionUi.nav_bar(self, "В главное меню", func() -> void: menu.emit(),
		primary, action)
	var main_button := nav.get_node_or_null("NavPrimary") as Button
	if main_button != null:
		# Enter принадлежит кнопке в фокусе: глобальный shortcut вызывал ещё и «Ещё раз».
		main_button.shortcut = null
	# После победы с наградой «Карты» нет (D-1007-P4): главное — «Дальше: выбор поправки»,
	# а экран карт уводил мимо выбора.
	if show_maps and not (victory and has_next):
		_add_secondary(nav, _make_button("Карты", func() -> void: maps.emit()))
	if show_retry and victory and has_next:
		var again := _make_button("Ещё раз", func() -> void: retry.emit())
		again.tooltip_text = "Сначала забрать поправку, затем подготовиться к повторному бою."
		_add_secondary(nav, again)
	if show_collect:
		_add_secondary(nav, _make_button("В коллекцию", func() -> void: collect_pressed.emit()))
	ModalFocus.contain.call_deferred(self)
	if main_button != null:
		main_button.grab_focus.call_deferred()
	var appear := create_tween()
	columns.modulate.a = 0.0
	appear.tween_property(columns, "modulate:a", 1.0, 0.2)


func _result_panel(parent: HBoxContainer, title: String) -> VBoxContainer:
	var panel := PanelContainer.new()
	panel.name = "BattlePanel" if title == "Этот бой" else "RewardPanel"
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	var style := UiStyle.panel_style(Color(0.09, 0.075, 0.13, 0.9), 10)
	style.border_color = Color(UiStyle.GOLD, 0.4)
	style.set_border_width_all(1)
	for side: String in ["left", "right", "top", "bottom"]:
		style.set("content_margin_" + side, 12.0)
	panel.add_theme_stylebox_override("panel", style)
	parent.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	panel.add_child(box)
	var heading := HBoxContainer.new()
	heading.name = "PanelHeading"
	box.add_child(heading)
	heading.add_child(ProgressionUi.text(title, 24, UiStyle.GOLD))
	return box


func _debrief_panel(report: Dictionary) -> Control:
	var panel := PanelContainer.new()
	panel.visible = not BattleDebrief.lines(report).is_empty()
	var style := UiStyle.panel_style(Color(0.09, 0.075, 0.13, 0.94), 6)
	style.border_color = Color(UiStyle.GOLD, 0.3)
	style.set_border_width_all(1)
	style.content_margin_left = 12
	style.content_margin_right = 12
	style.content_margin_top = 6
	style.content_margin_bottom = 6
	panel.add_theme_stylebox_override("panel", style)
	panel.add_child(BattleDebrief.panel(report, UiStyle.TEXT))
	return panel


func _add_secondary(nav: HBoxContainer, button: Button) -> void:
	nav.add_child(button)
	# Перед растяжкой: второстепенные действия слева, главное остаётся у правого края.
	for i in nav.get_child_count():
		if not nav.get_child(i) is Button:
			nav.move_child(button, i)
			break



## Печатает только те строки, для которых есть данные — задание прямо требует не выдумывать
## недостающие поля (kills, lost, charges, refreshes, releases, cauldron_hp/_max, time).
func _stats_block(stats: Dictionary) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)

	var lines: Array[String] = []
	# mode: «Бесконечный подряд»/«Вызов дня» кладёт сюда стаж и души забега ПОСЛЕ этого объекта
	# (LegionMain._on_endless_match_ended) — кампания этих ключей не пишет, строка не появится.
	if stats.has("tenure"):
		lines.append("Объектов пройдено: %d · Души: %d" % [
			int(stats["tenure"]), int(stats.get("souls", 0))])
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
		var icon := ""
		if line.begins_with("HP Котла"):
			icon = "hud_cauldron"
		elif line.begins_with("Упокоено"):
			icon = "soul"
		elif line.begins_with("Потеряно"):
			icon = "hud_army"
		elif line.begins_with("Время"):
			icon = "perk_short_cd"
		elif line.begins_with("Премия") or line.begins_with("Касса"):
			icon = "premium"
		var row := _stat_row(icon, line)
		row.name = "StatRow%d" % box.get_child_count()
		box.add_child(row)
		if icon == "hud_cauldron":
			box.add_child(_health_bar(stats))
	return box


func _health_bar(stats: Dictionary) -> ProgressBar:
	var bar := ProgressBar.new()
	bar.name = "CauldronHealth"
	bar.custom_minimum_size.y = 8
	bar.max_value = maxf(1.0, float(stats["cauldron_max"]))
	bar.value = float(stats["cauldron_hp"])
	bar.show_percentage = false
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.add_theme_stylebox_override("background", UiStyle.panel_style(Color(0.2, 0.1, 0.16), 4))
	bar.add_theme_stylebox_override("fill", UiStyle.panel_style(
		UiStyle.GOOD if bar.value / bar.max_value > 0.3 else UiStyle.BAD, 4))
	return bar


func _stat_row(icon_name: String, value: String) -> Control:
	var row := HBoxContainer.new()
	row.name = "StatRow"
	row.custom_minimum_size.y = 26
	row.add_theme_constant_override("separation", 8)
	var badge := PanelContainer.new()
	badge.custom_minimum_size = Vector2(24, 24)
	badge.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var background: StyleBox = StyleBoxEmpty.new()
	if icon_name in ["hud_cauldron", "perk_short_cd"]:
		background = UiStyle.panel_style(Color(0.72, 0.66, 0.54), 4)
	badge.add_theme_stylebox_override("panel", background)
	row.add_child(badge)
	if icon_name != "":
		var icon := LegionIcons.rect(icon_name, 22.0)
		if icon_name == "soul":
			icon.texture = load("res://assets/img/icons/soul.png") as Texture2D
		badge.add_child(icon)
	var label := ProgressionUi.text(value, 20)
	label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(label)
	return row


## meta: премия и опыт за бой, «Новый уровень героя!» при повышении (задание meta п.7).
func _rewards_block(rewards: Dictionary, victory := true) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)

	var line := UiStyle.label(
		"Премия: +%d · Опыт: +%d" % [int(rewards.get("bounty", 0)), int(rewards.get("xp", 0))],
		24, UiStyle.FONT_TITLE, UiStyle.GOLD)
	line.name = "RewardCounters"
	line.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 6)
	row.add_child(LegionIcons.rect("premium", 22.0))
	row.add_child(line)
	box.add_child(row)
	_reward_tween = create_tween().set_parallel(true)
	var count := func(fraction: float) -> void:
		line.text = "Премия: +%d · Опыт: +%d" % [
			roundi(float(rewards.get("bounty", 0)) * fraction),
			roundi(float(rewards.get("xp", 0)) * fraction)]
	count.call(0.0)
	_reward_tween.tween_method(count, 0.0, 1.0, 0.65).set_trans(Tween.TRANS_CUBIC).set_ease(
		Tween.EASE_OUT)
	if rewards.has("xp"):
		var after := int(rewards.get("xp_after", Campaign.hero_xp()))
		var before := int(rewards.get("xp_before", maxi(0, after - int(rewards.get("xp", 0)))))
		var meter := ProgressionUi.experience_meter(before)
		box.add_child(meter)
		_reward_tween.tween_method(func(value: float) -> void:
			ProgressionUi.update_experience(meter, roundi(value)), float(before), float(after),
			0.85).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)

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

	# Новичку: на что премия и зачем опыт (D-1007-P3) — одна строка, без экрана объяснений.
	if rewards.has("xp"):
		var why := UiStyle.label("Премия — на подготовку перед боем. Опыт растит разряд: "
			+ "разряд открывает новые поправки.", 15, UiStyle.FONT_TEXT, UiStyle.TEXT_DIM)
		why.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		why.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		box.add_child(why)

	if bool(rewards.get("leveled_up", false)):
		var up := UiStyle.label(rank_up_text(int(rewards.get("level_before",
			int(rewards.get("level", 0)) - 1)), int(rewards.get("level", 0))), 18,
			UiStyle.FONT_TITLE, UiStyle.GOOD)
		up.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		up.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		box.add_child(up)
		up.name = "RankUp"
		LegionAudio.ui(&"rank_up")
		up.modulate = Color(1.15, 1.1, 0.8, 0.0)
		_reward_tween.tween_property(up, "modulate", Color.WHITE, 0.3).set_delay(0.55)
		var icons := HFlowContainer.new()
		icons.alignment = FlowContainer.ALIGNMENT_CENTER
		icons.add_theme_constant_override("h_separation", 16)
		box.add_child(icons)
		for id: String in AmendmentDb.ORDER:
			var data := AmendmentDb.card(StringName(id))
			var rank := int(data.get("unlock_level", 1))
			if rank > int(rewards.get("level_before", 1)) and rank <= int(rewards.get("level", 1)):
				var opening := VBoxContainer.new()
				opening.custom_minimum_size.x = 170
				icons.add_child(opening)
				var icon := LegionIcons.rect(String(data["icon"]), 44.0)
				icon.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
				opening.add_child(icon)
				var caption := ProgressionUi.text(String(data["title"]), 18, UiStyle.GOLD)
				caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
				opening.add_child(caption)

	return box


## «Новый разряд 2 — открыты поправки «Ночная смена», «Бесплатная смета»» (D-1007-P3): что дал
## разряд, словами игрока. Открытия — карты колоды с unlock_level в (before, after] и второе место
## подготовки (AmendmentDb.PREP_SLOT2_LEVEL).
static func rank_up_text(before: int, after: int) -> String:
	var names: Array[String] = []
	for id: String in AmendmentDb.ORDER:
		var ul := int(AmendmentDb.card(StringName(id)).get("unlock_level", 1))
		if ul > before and ul <= after:
			names.append("«%s»" % String(AmendmentDb.card(StringName(id)).get("title", id)))
	var parts: Array[String] = []
	if names.size() == 1:
		parts.append("открыта поправка " + names[0])
	elif names.size() > 1:
		parts.append("открыты поправки " + ", ".join(names))
	if before < AmendmentDb.PREP_SLOT2_LEVEL and after >= AmendmentDb.PREP_SLOT2_LEVEL:
		parts.append("второе место подготовки перед боем")
	var out := "Новый разряд %d" % after
	if not parts.is_empty():
		out += " — " + "; ".join(parts)
	return out


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
