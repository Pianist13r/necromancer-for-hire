class_name ProgressionUi
extends RefCounted
## Прокручивается содержимое; выход всегда виден.

static func shell(screen: Control, title: String, subtitle: String, options := {}) -> Dictionary:
	UiStyle.fill_rect(screen)
	screen.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var backdrop := ColorRect.new()
	backdrop.color = Color(0.035, 0.025, 0.065, float(options.get("shade", 0.98)))
	UiStyle.fill_rect(backdrop)
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	screen.add_child(backdrop)
	var margin := MarginContainer.new()
	UiStyle.fill_rect(margin)
	for side: String in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 92 if side == "bottom" else 24)
	screen.add_child(margin)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 12)
	margin.add_child(column)
	column.add_child(UiStyle.label(title, 32, UiStyle.FONT_TITLE,
		options.get("title_color", UiStyle.GOLD)))
	var note := text(subtitle, 19, UiStyle.TEXT_DIM)
	column.add_child(note)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.follow_focus = true
	column.add_child(scroll)
	var body := VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if bool(options.get("fill_body", false)):
		body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 14)
	scroll.add_child(body)
	var footer := HBoxContainer.new()
	footer.add_theme_constant_override("separation", 14)
	column.add_child(footer)
	return {"body": body, "footer": footer, "note": note}


## Сток клавиш экранов прокачки (D-1008-PROG4, D-1008-K1): зовущие Controls.text сами не
## применяют — двойной проход вернул бы обменянные клавиши обратно.
static func text(value: String, size := 18, color := UiStyle.TEXT) -> Label:
	var label := UiStyle.label(Controls.text(value), size, UiStyle.FONT_TEXT, color)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label


static func button(value: String, callback: Callable) -> Button:
	var btn := Button.new()
	btn.text = value
	btn.custom_minimum_size = Vector2(150.0, 48.0)
	btn.add_theme_font_override("font", UiStyle.FONT_TITLE)
	btn.add_theme_font_size_override("font_size", 19)
	UiStyle.style_button(btn)
	btn.pressed.connect(callback)
	return btn


static func clear(container: Node) -> void:
	for child in container.get_children():
		container.remove_child(child)
		child.queue_free()


static func grid() -> GridContainer:
	var out := GridContainer.new()
	out.columns = 3
	out.add_theme_constant_override("h_separation", 16)
	out.add_theme_constant_override("v_separation", 16)
	out.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return out


static func resize_grid(grid_node: GridContainer, width: float) -> void:
	grid_node.columns = clampi(int((width - 48.0) / 285.0), 1, 3)


## Условия открываются отдельным окном: каталог не прыгает, доступно мышью и Enter.
static func inspect_card(owner: Control, id: StringName) -> AcceptDialog:
	var data := AmendmentDb.card(id)
	var dialog := _detail_dialog(owner, String(data.get("title", id)))
	dialog.name = "AmendmentDetails"
	# ScrollContainer ограничивает минимум окна: до первой раскладки ширина текста нулевая,
	# и AcceptDialog иначе принимает высоту «по букве в строке» за несжимаемый минимум.
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(560.0, 80.0)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	dialog.add_child(scroll)
	var row := ProgressionRow.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(row)
	var availability := RunProgression.unseen_note(id)
	var level := int(data.get("unlock_level", 1))
	if level > Campaign.hero_level():
		availability = "Для предложения нужен разряд %d. " % level + availability
	row.configure(id, data, availability,
		{"expanded": true, "interactive": false, "together": true})
	var fit := func() -> void: _fit_details(dialog, scroll, row)
	row.minimum_size_changed.connect(func() -> void: fit.call_deferred())
	dialog.popup_centered(Vector2i(mini(740, int(owner.get_viewport_rect().size.x) - 80), 0))
	fit.call_deferred()
	return dialog


## Высоту берём после раскладки текста по ширине. Длинные условия остаются прокручиваемыми.
static func _fit_details(dialog: AcceptDialog, scroll: ScrollContainer, row: Control) -> void:
	if not is_instance_valid(dialog) or not dialog.visible:
		return
	var available := dialog.get_parent().get_viewport().get_visible_rect().size
	var height := minf(row.get_combined_minimum_size().y, available.y - 180.0)
	if is_equal_approx(scroll.custom_minimum_size.y, height):
		return
	scroll.custom_minimum_size.y = height
	dialog.size.y = 0
	dialog.position = Vector2i((available - Vector2(dialog.size)) / 2.0)


static func experience_meter(xp: int) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.name = "Experience"
	box.add_theme_constant_override("separation", 6)
	var caption := text("", 17, UiStyle.GOLD)
	caption.name = "ExperienceCaption"
	box.add_child(caption)
	var bar := ProgressBar.new()
	bar.name = "ExperienceBar"
	bar.custom_minimum_size.y = 10.0
	bar.show_percentage = false
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.add_theme_stylebox_override("background", UiStyle.panel_style(Color(0.13, 0.11, 0.17), 5))
	bar.add_theme_stylebox_override("fill", UiStyle.panel_style(UiStyle.GOLD, 5))
	box.add_child(bar)
	update_experience(box, xp)
	return box


static func update_experience(box: VBoxContainer, xp: int) -> void:
	var progress := LegionMetaCfg.rank_progress(xp)
	var level := int(progress["level"])
	var caption := box.get_node("ExperienceCaption") as Label
	var bar := box.get_node("ExperienceBar") as ProgressBar
	if bool(progress["maxed"]):
		caption.text = "Разряд %d · колода открыта целиком" % level
		bar.max_value = 1.0
		bar.value = 1.0
	else:
		caption.text = "Разряд %d · до разряда %d осталось %d опыта" % [
			level, level + 1, int(progress["need"]) - int(progress["cur"])]
		bar.max_value = float(progress["need"])
		bar.value = float(progress["cur"])


static func rank_openings(level: int) -> String:
	var names: Array[String] = []
	for id: String in AmendmentDb.ORDER:
		var data := AmendmentDb.card(StringName(id))
		if int(data.get("unlock_level", 1)) == level:
			names.append("«%s»" % String(data["title"]))
	if level == AmendmentDb.PREP_SLOT2_LEVEL:
		names.append("второе место подготовки")
	return ", ".join(names)


static func inspect_rank(owner: Control, level: int) -> AcceptDialog:
	var dialog := _detail_dialog(owner, "Разряд %d" % level)
	dialog.name = "RankDetails"
	var required := 0 if level == 1 else LegionMetaCfg.HERO_LEVEL_THRESHOLDS[level - 2]
	var state := "Открыт" if Campaign.hero_level() >= level else "Нужно ещё %d опыта" % (
		required - Campaign.hero_xp())
	dialog.dialog_text = "%s · %d опыта всего\n\nОткрывает: %s\n\n%s" % [state, required,
		rank_openings(level), "Это варианты для будущих предложений. Подписываются после победы."]
	dialog.popup_centered(Vector2i(mini(650, int(owner.get_viewport_rect().size.x) - 80), 0))
	return dialog


static func _detail_dialog(owner: Control, title: String) -> AcceptDialog:
	var before := owner.get_viewport().gui_get_focus_owner()
	var dialog := AcceptDialog.new()
	dialog.exclusive = true
	dialog.transient = true
	dialog.dialog_hide_on_ok = true
	dialog.ok_button_text = "Понятно"
	UiStyle.style_dialog(dialog, title)
	owner.add_child(dialog)
	dialog.visibility_changed.connect(func() -> void:
		if not dialog.visible:
			if is_instance_valid(before):
				before.grab_focus()
			dialog.queue_free())
	var viewport := owner.get_viewport()
	var recenter := func() -> void:
		if is_instance_valid(dialog) and dialog.visible:
			dialog.position = Vector2i((viewport.get_visible_rect().size - Vector2(dialog.size)) / 2.0)
	viewport.size_changed.connect(recenter)
	dialog.tree_exiting.connect(func() -> void: viewport.size_changed.disconnect(recenter))
	return dialog
