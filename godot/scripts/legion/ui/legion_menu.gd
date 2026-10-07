class_name LegionMenu
extends Control
##
## Главное меню режима «По истечении договора». Самодостаточный экран — интегратор ставит
## его корнем сцены и слушает сигналы; сам ни на что боевое не ссылается (docs/legion/SLICE_SPEC.md
## этот пакет не описывает, дом мете и экранам — здесь).
##
## Композиция (редизайн 09.2026): асимметричный кадр — слева узкая колонка контента (~540 px),
## справа крупная фигура некроманта на графическом руническом круге; фон офиса остаётся видимым
## (затемнение градиентом слева, а не плашкой на весь экран).
##

signal continue_pressed(map_id: String)
signal maps_pressed
signal hero_pressed
signal howto_pressed
signal settings_pressed
signal quit_pressed
## mode (BOOK §1): «Бесконечный подряд» и «Вызов дня».
signal endless_pressed
signal daily_pressed
## D-0927-162: «Коллекция» — виден только когда в ней есть хоть одна карта (см. _ready()).
signal collection_pressed
## P6: «Схватка» — матч против бота (PvpFlow), доступна сразу.
signal pvp_pressed

## --dev endless_open=1 (debug build) — открыть «Бесконечный подряд»/«Вызов дня» без прохождения
## кампании, для проверки (BOOK §1, docs/procgen/STAGE2.md линия mode). LegionMain ставит его ДО
## add_child(), иначе _ready() уже собрал бы кнопки без учёта флага.
## Геометрия кадра 1280×720: безопасное поле и ширина левой колонки контента.
const SAFE := 48.0
const COLUMN_W := 540.0

var dev_force_open := false
var _rune_bg: Control


func _ready() -> void:
	UiStyle.fill_rect(self)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	_build_background()
	_build_hero_composition()
	_build_content_column()


## Фон: офисная картина, поверх — градиентная вуаль (плотно слева под текст, прозрачно справа,
## чтобы офис читался за фигурой) и медленно ползущие рунные линии кодом (_draw).
func _build_background() -> void:
	var bg := TextureRect.new()
	var tex: Texture2D = load("res://assets/img/bg_office.png")
	if tex != null:
		bg.texture = tex
		bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		bg.stretch_mode = TextureRect.STRETCH_SCALE
		UiStyle.fill_rect(bg)
		bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(bg)

	# Градиент вместо ровной плашки: ровная затемняла бы и героя, ради которого кадр и собран.
	var shade := TextureRect.new()
	var grad := Gradient.new()
	grad.colors = PackedColorArray([Color(0.02, 0.01, 0.05, 0.8), Color(0.02, 0.01, 0.05, 0.12)])
	var gtex := GradientTexture2D.new()
	gtex.gradient = grad
	gtex.fill_from = Vector2.ZERO
	gtex.fill_to = Vector2(1.0, 0.0)
	gtex.width = 64
	gtex.height = 64
	shade.texture = gtex
	shade.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	shade.stretch_mode = TextureRect.STRETCH_SCALE
	UiStyle.fill_rect(shade)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(shade)

	_rune_bg = _MenuRunes.new()
	UiStyle.fill_rect(_rune_bg)
	_rune_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_rune_bg)


## Правая половина кадра: фигура героя (существующий спрайт) на руническом круге, тень и
## летающие листья договора — всё векторное (_draw), без новых ассетов. Декор рисуется ДО
## контентной колонки, поэтому клики всегда достаются кнопкам.
func _build_hero_composition() -> void:
	var back := _HeroDecor.new()
	UiStyle.fill_rect(back)
	back.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(back)

	var hero := TextureRect.new()
	hero.texture = load("res://assets/img/necromancer.png")
	hero.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	hero.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	hero.position = Vector2(700.0, 120.0)
	hero.size = Vector2(540.0, 540.0)
	hero.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(hero)

	var front := _HeroDecor.new()
	front.leaves_only = true
	UiStyle.fill_rect(front)
	front.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(front)


func _build_content_column() -> void:
	var margin := MarginContainer.new()
	UiStyle.fill_rect(margin)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_theme_constant_override("margin_left", int(SAFE))
	margin.add_theme_constant_override("margin_right", int(SAFE))
	margin.add_theme_constant_override("margin_top", int(SAFE))
	margin.add_theme_constant_override("margin_bottom", int(SAFE))
	add_child(margin)

	var col := VBoxContainer.new()
	col.custom_minimum_size.x = COLUMN_W
	col.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override("separation", 6)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(col)

	var title := UiStyle.label("Некромант\nпо найму", 50, UiStyle.FONT_TITLE, UiStyle.TEXT)
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(title)

	var subtitle := UiStyle.label("По истечении договора", 22, UiStyle.FONT_TITLE, UiStyle.GOLD)
	subtitle.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(subtitle)

	# Название карты — отдельной вторичной строкой (не раздувает подпись CTA).
	var map_title := _next_map_title()
	if map_title != "":
		var map_line := UiStyle.label(
			("Первый договор: %s" if not Campaign.has_progress() else "Следующий договор: %s")
				% map_title, 17, ThemeDB.fallback_font, UiStyle.TEXT_DIM)
		map_line.mouse_filter = Control.MOUSE_FILTER_IGNORE
		col.add_child(map_line)

	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0.0, 8.0)
	gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(gap)

	var cta := _make_button(_continue_label(), 40)
	cta.name = "CampaignAction"
	cta.custom_minimum_size = Vector2(0.0, 80.0)
	cta.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cta.icon = LegionIcons.tex("menu_play")
	cta.add_theme_constant_override("icon_max_width", 45)
	cta.tooltip_text = map_title
	_style_menu_button(cta, true)
	# Основное действие — заголовочным шрифтом: цифры/подписи уходят в системный, заголовок остаётся.
	cta.add_theme_font_override("font", UiStyle.FONT_TITLE)
	cta.pressed.connect(func() -> void: continue_pressed.emit(_next_map_id()))
	col.add_child(cta)
	cta.grab_focus.call_deferred()

	var picker := DifficultyPicker.new()
	col.add_child(picker)
	# _ready() создаёт кнопки и подпись; оформляем после входа в дерево.
	_polish_picker(picker)

	_build_pvp_row(col)
	_build_mode_row(col)
	_build_cards_row(col)
	_build_bottom_strip(col)


## «Бесконечный подряд» / «Вызов дня» / «Коллекция» — один ряд второстепенных действий.
## Полные названия и счётчики — в tooltip: подписи держим короткими, ряд не разъезжается.
func _build_mode_row(col: VBoxContainer) -> void:
	var endless_open := dev_force_open or LegionRunStore.campaign_completed()
	# D-0927-96: «Вызов дня» — ОДНА попытка в день; сегодня уже сыграна и закрыта до завтра,
	# если попытка началась и закончилась и сейчас не идёт заново.
	var today := LegionEndless.today_date()
	var daily_running := LegionRunStore.endless_active(true) \
		and LegionRunStore.endless_daily_date() == today
	var daily_done_today := LegionRunStore.daily_attempt_done(today) and not daily_running
	var daily_open := endless_open and not daily_done_today

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 8)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(row)

	var endless_btn := _make_button(_endless_label(), 16)
	endless_btn.name = "EndlessAction"
	endless_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	endless_btn.icon = LegionIcons.tex("menu_endless")
	endless_btn.add_theme_constant_override("icon_max_width", 22)
	endless_btn.disabled = not endless_open
	endless_btn.focus_mode = Control.FOCUS_ALL if endless_open else Control.FOCUS_NONE
	# Полное название режима — в tooltip: подпись держим короткой, чтобы ряд не разъезжался.
	endless_btn.tooltip_text = "Бесконечный подряд"
	endless_btn.pressed.connect(func() -> void: endless_pressed.emit())
	row.add_child(endless_btn)

	var daily_btn := _make_button(_daily_label(daily_done_today), 16)
	daily_btn.name = "DailyAction"
	daily_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	daily_btn.icon = LegionIcons.tex("menu_daily")
	daily_btn.add_theme_constant_override("icon_max_width", 22)
	daily_btn.disabled = not daily_open
	daily_btn.focus_mode = Control.FOCUS_ALL if daily_open else Control.FOCUS_NONE
	if daily_done_today:
		var done := LegionRunStore.daily_done_result(today)
		daily_btn.tooltip_text = "Сегодняшний подряд сдан — приходите завтра. Стаж: %d · Души: %d" \
			% [int(done.get("tenure", 0)), int(done.get("souls", 0))]
	elif daily_running:
		daily_btn.tooltip_text = "«Вызов дня» — продолжение сегодняшней попытки"
	daily_btn.pressed.connect(func() -> void: daily_pressed.emit())
	row.add_child(daily_btn)

	# D-0927-162: «Коллекция» — виден, только когда в ней есть хоть одна сохранённая карта.
	if not LegionCollection.entries().is_empty():
		var collection_btn := _make_button(
			"Коллекция (%d)" % LegionCollection.entries().size(), 16)
		collection_btn.name = "CollectionAction"
		collection_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		collection_btn.icon = LegionIcons.tex("menu_collection")
		collection_btn.add_theme_constant_override("icon_max_width", 22)
		collection_btn.tooltip_text = "Сохранённые договоры"
		collection_btn.pressed.connect(func() -> void: collection_pressed.emit())
		row.add_child(collection_btn)

	if not endless_open:
		var lock_note := UiStyle.label("Откроется после прохождения кампании.", 15,
			ThemeDB.fallback_font, UiStyle.TEXT_DIM)
		lock_note.mouse_filter = Control.MOUSE_FILTER_IGNORE
		col.add_child(lock_note)


## «Схватка» — открыта сразу (D-0927-199), а не после кампании: широкая кнопка и короткая подпись.
func _build_pvp_row(col: VBoxContainer) -> void:
	var btn := _make_button("Схватка", 20)
	btn.name = "PvpAction"
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.icon = LegionIcons.tex("menu_pvp")
	btn.add_theme_constant_override("icon_max_width", 26)
	btn.add_theme_font_override("font", UiStyle.FONT_TITLE)
	btn.tooltip_text = "Матч против бота или другого игрока по сети"
	btn.pressed.connect(func() -> void: pvp_pressed.emit())
	col.add_child(btn)
	var note := UiStyle.label("Против бота или по сети · разрушьте Котёл соперника", 15,
		ThemeDB.fallback_font, UiStyle.TEXT_DIM)
	note.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(note)


## Две карточки-ссылки («Карты», «Досье»): настоящий Button с декоративным наполнением
## (иконка + подпись), наполнение мышь не перехватывает. Кликит сама карточка.
func _build_cards_row(col: VBoxContainer) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(row)

	row.add_child(_make_card("CardMaps", "Карты", "menu_map",
		"Выбор договора", func() -> void: maps_pressed.emit()))
	# D-1007-P1: «Контора» как экран убрана — подготовка живёт на брифинге; две карточки ровно.
	# D-1007-P2: одно «Досье» вместо «Героя» — разряд, поправки и артефакты на одном экране.
	row.add_child(_make_card("CardDossier", "Досье", "menu_hero",
		"Разряд, поправки, артефакты", func() -> void: hero_pressed.emit()))


func _make_card(card_name: String, caption: String, icon_name: String, tip: String,
		handler: Callable) -> Button:
	var card := Button.new()
	card.name = card_name
	card.custom_minimum_size = Vector2(168.0, 124.0)
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.tooltip_text = tip
	card.add_theme_font_override("font", ThemeDB.fallback_font)
	card.add_theme_font_size_override("font_size", 18)
	card.add_theme_color_override("font_color", UiStyle.TEXT_DIM)
	card.add_theme_color_override("font_hover_color", UiStyle.TEXT)
	_style_menu_button(card)
	card.pressed.connect(handler)

	var inner := VBoxContainer.new()
	inner.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 12)
	inner.alignment = BoxContainer.ALIGNMENT_CENTER
	inner.add_theme_constant_override("separation", 6)
	inner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(inner)

	inner.add_child(LegionIcons.rect(icon_name, 52.0))
	var cap := UiStyle.label(caption, 18, UiStyle.FONT_TITLE, UiStyle.TEXT_DIM)
	cap.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inner.add_child(cap)
	return card


## Служебная полоса: Как играть / Настройки / Выход — компактные кнопки с иконками.
func _build_bottom_strip(col: VBoxContainer) -> void:
	var strip := HBoxContainer.new()
	strip.add_theme_constant_override("separation", 8)
	strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(strip)

	var howto_btn := _make_button("Как играть", 17)
	howto_btn.name = "HowtoAction"
	howto_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	howto_btn.icon = LegionIcons.tex("menu_guide")
	howto_btn.add_theme_constant_override("icon_max_width", 20)
	howto_btn.pressed.connect(func() -> void: howto_pressed.emit())
	strip.add_child(howto_btn)

	var settings_btn := _make_button("Настройки", 17)
	settings_btn.name = "SettingsAction"
	settings_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	settings_btn.icon = LegionIcons.tex("menu_settings")
	settings_btn.add_theme_constant_override("icon_max_width", 20)
	settings_btn.pressed.connect(func() -> void: settings_pressed.emit())
	strip.add_child(settings_btn)

	var quit_btn := _make_button("Выход", 17)
	quit_btn.name = "QuitAction"
	quit_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	quit_btn.icon = LegionIcons.tex("menu_exit")
	quit_btn.add_theme_constant_override("icon_max_width", 20)
	quit_btn.pressed.connect(func() -> void: quit_pressed.emit())
	strip.add_child(quit_btn)


func _endless_label() -> String:
	if LegionRunStore.endless_active(false):
		return "Забег (объект %d)" % LegionRunStore.endless_k(false)
	return "Бесконечный"


## Метка «Вызов дня»: сегодня уже сыгран (done_today, D-0927-96) — подпись говорит об этом
## прямо; идёт незакрытый забег — короткая форма с номером объекта.
func _daily_label(done_today: bool) -> String:
	if LegionRunStore.endless_active(true) \
			and LegionRunStore.endless_daily_date() == LegionEndless.today_date():
		return "Вызов (объект %d)" % LegionRunStore.endless_k(true)
	if done_today:
		return "«Вызов дня» сдан"
	return "Вызов дня"


## Следующая карта: первая непройденная из открытых, иначе первая открытая (кампания добита —
## идти переигрывать). Пустой список карт — вернёт "".
func _next_map_id() -> String:
	var all := Campaign.maps()
	if all.is_empty():
		return ""
	var first_unlocked := ""
	for m in all:
		var id := String(m.get("id", ""))
		if not Campaign.is_unlocked(id):
			continue
		if first_unlocked == "":
			first_unlocked = id
		if Campaign.stars(id) == 0:
			return id
	return first_unlocked


func _next_map_title() -> String:
	var id := _next_map_id()
	if id == "":
		return ""
	return String(Campaign.map(id).get("title", id))


## CTA — короткая форма; какое именно продолжение, говорит строка названия карты над кнопкой.
func _continue_label() -> String:
	return "Начать смену" if not Campaign.has_progress() else "Продолжить"


## Сложность: пояснение уровня — в tooltip кнопки (строка-описание под кнопками убрана,
## колонка компактнее), выбор осознанным остаётся за счёт подсказки.
func _polish_picker(picker: DifficultyPicker) -> void:
	for id: String in picker.buttons:
		var button: Button = picker.buttons[id]
		button.add_theme_font_override("font", ThemeDB.fallback_font)
		button.tooltip_text = String(LegionChallenge.TABLE[id]["desc"])
		_style_menu_button(button)
		var selected := button.get_theme_stylebox("pressed").duplicate() as StyleBoxTexture
		if selected != null:
			selected.modulate_color = selected.modulate_color.lerp(DifficultyPicker.COLORS[id], 0.45)
		button.add_theme_stylebox_override("pressed", selected)
		button.add_theme_stylebox_override("hover_pressed", selected)
		button.add_theme_color_override("font_pressed_color", DifficultyPicker.COLORS[id])
	for child in picker.find_children("*", "Label", true, false):
		var label := child as Label
		if label.text == "Сложность:":
			label.add_theme_font_override("font", ThemeDB.fallback_font)
			label.add_theme_font_size_override("font_size", 16)
		else:
			# Строка-описание: дублирует tooltip кнопок, в колонке только место берёт.
			label.visible = false


## Вторичные кнопки — 40px высотой (нижняя граница удобного нажатия, тест держит порог).
func _make_button(text: String, font_size: int) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.custom_minimum_size = Vector2(0.0, 40.0)
	btn.add_theme_font_override("font", ThemeDB.fallback_font)
	btn.add_theme_font_size_override("font_size", font_size)
	btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_style_menu_button(btn)
	return btn


## Крупный акцент — только у продолжения. Фокус отдельной рамкой не скрывает выбранный режим.
func _style_menu_button(btn: Button, primary := false) -> void:
	UiStyle.style_button(btn)
	var normal := UiStyle.button_style(primary, 16.0, 8.0)
	var hover := UiStyle.button_style(primary, 16.0, 8.0)
	hover.modulate_color = Color(1.14, 1.12, 1.08)
	var pressed := UiStyle.button_style(primary, 16.0, 8.0)
	pressed.modulate_color = Color(0.78, 0.72, 0.68)
	pressed.expand_margin_left = -1.0
	pressed.expand_margin_top = -1.0
	pressed.expand_margin_right = -1.0
	pressed.expand_margin_bottom = -1.0
	var disabled := UiStyle.button_style(false, 16.0, 8.0)
	disabled.modulate_color = Color(0.62, 0.58, 0.62, 0.55)
	btn.add_theme_stylebox_override("normal", normal)
	btn.add_theme_stylebox_override("hover", hover)
	btn.add_theme_stylebox_override("pressed", pressed)
	btn.add_theme_stylebox_override("hover_pressed", pressed)
	btn.add_theme_stylebox_override("disabled", disabled)
	btn.add_theme_color_override("font_color", Color("fff0d2") if primary else UiStyle.TEXT)
	btn.add_theme_color_override("font_hover_color", Color.WHITE)
	btn.add_theme_color_override("font_pressed_color", UiStyle.TEXT)
	btn.add_theme_color_override("font_disabled_color", Color(UiStyle.TEXT_DIM, 0.45))


## Правая композиция: рунический круг (кольца, засечки, разомкнутая «печать»), тень под
## фигурой и листья договора. Внутренний класс: экран самодостаточен, отдельный файл ради
## одного `_draw` был бы лишней сущностью.
class _HeroDecor:
	extends Control

	const CENTER := Vector2(965.0, 390.0)
	const RADIUS := 250.0
	## leaves_only: передний слой — только листья договора поверх фигуры.
	var leaves_only := false


	func _draw() -> void:
		if leaves_only:
			_draw_contract_sheets()
			return
		# Мягкая тень-эллипс под фигурой: сплюснутый круг через трансформ.
		draw_set_transform(CENTER + Vector2(0.0, 195.0), 0.0, Vector2(1.0, 0.24))
		draw_circle(Vector2.ZERO, 170.0, Color(0.0, 0.0, 0.0, 0.5))
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
		draw_arc(CENTER, RADIUS, 0.0, TAU, 96, Color(UiStyle.GOLD, 0.32), 2.0, true)
		draw_arc(CENTER, RADIUS * 0.86, 0.0, TAU, 96, Color(UiStyle.SOUL, 0.26), 1.5, true)
		for i in 24:
			var a := TAU * float(i) / 24.0
			var dir := Vector2(cos(a), sin(a))
			draw_line(CENTER + dir * RADIUS, CENTER + dir * (RADIUS + 14.0),
				Color(UiStyle.GOLD, 0.28), 2.0)
			draw_line(CENTER + dir * RADIUS * 0.86, CENTER + dir * (RADIUS * 0.86 - 10.0),
				Color(UiStyle.SOUL, 0.22), 1.5)
		# Разомкнутая дуга сверху — «печать» круга, чтобы кольцо не читалось идеальной окружностью.
		draw_arc(CENTER, RADIUS * 1.12, -PI * 0.85, -PI * 0.15, 40, Color(UiStyle.GOLD, 0.2), 3.0,
			true)


	func _draw_contract_sheets() -> void:
		# Три закреплённых места по краю композиции: бумага обрамляет фигуру, не летит
		# перед лицом и каской. Не использовать случайное размещение — оно портило кадр.
		_draw_contract_sheet(CENTER + Vector2(-250.0, 10.0), -0.24)
		_draw_contract_sheet(CENTER + Vector2(234.0, -236.0), 0.18)
		_draw_contract_sheet(CENTER + Vector2(248.0, 207.0), -0.11)


	func _draw_contract_sheet(pos: Vector2, angle: float) -> void:
		var paper := PackedVector2Array([
			Vector2(-20.0, -27.0), Vector2(9.0, -27.0), Vector2(20.0, -16.0),
			Vector2(20.0, 27.0), Vector2(-20.0, 27.0),
		])
		draw_set_transform(pos, angle, Vector2.ONE)
		# Несколько близких прозрачных силуэтов дают мягкую тень без тяжёлой рамки.
		for i in 3:
			var shadow := PackedVector2Array()
			for point in paper:
				shadow.append(point + Vector2(2.0 + float(i), 3.0 + float(i)))
			draw_colored_polygon(shadow, Color(0.0, 0.0, 0.0, 0.08 - float(i) * 0.018))
		draw_colored_polygon(paper, Color(0.78, 0.62, 0.39, 0.96))
		var outline := paper.duplicate()
		outline.append(paper[0])
		draw_polyline(outline, Color(0.98, 0.79, 0.49, 0.95), 1.4, true)
		# Загнутый угол светлее листа; две стороны сгиба оставляем тонкими чернилами.
		var fold := PackedVector2Array([
			Vector2(9.0, -27.0), Vector2(9.0, -16.0), Vector2(20.0, -16.0),
		])
		draw_colored_polygon(fold, Color(0.96, 0.79, 0.55, 0.98))
		draw_line(fold[0], fold[1], Color(0.47, 0.3, 0.15, 0.95), 1.1, true)
		draw_line(fold[1], fold[2], Color(0.47, 0.3, 0.15, 0.95), 1.1, true)
		# Строки договора и маленькая восковая печать дают бумаге смысловой рисунок.
		draw_line(Vector2(-13.0, -8.0), Vector2(12.0, -8.0), Color(0.32, 0.22, 0.14, 0.78), 1.2)
		draw_line(Vector2(-13.0, 0.0), Vector2(12.0, 0.0), Color(0.32, 0.22, 0.14, 0.72), 1.2)
		draw_line(Vector2(-13.0, 8.0), Vector2(4.0, 8.0), Color(0.32, 0.22, 0.14, 0.68), 1.2)
		draw_circle(Vector2(11.0, 17.0), 3.2, Color(0.58, 0.18, 0.15, 0.96))
		draw_circle(Vector2(11.0, 17.0), 3.2, Color(0.96, 0.71, 0.42, 0.9), false, 0.8)
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


## Несколько тающих рунных линий, ползущих по фону — тот же язык, что у боевой руны, но
## декоративно и без ввода.
class _MenuRunes:
	extends Control

	const LINES := 4
	const SPEED := 14.0
	const COLOR := Color(0.541, 0.361, 0.965, 0.22)   # UiStyle.SOUL, приглушённо

	var _t := 0.0


	func _process(delta: float) -> void:
		_t += delta
		queue_redraw()


	func _draw() -> void:
		for i in LINES:
			var seed_offset := float(i) * 137.0
			var y := 90.0 + float(i) * 170.0
			var phase := fmod(_t * SPEED + seed_offset, size.x + 240.0) - 120.0
			var points := PackedVector2Array()
			var n := 24
			for p in n:
				var x := phase - 200.0 + float(p) * (400.0 / float(n))
				var wobble := sin((x + seed_offset) * 0.02 + _t) * 18.0
				points.append(Vector2(x, y + wobble))
			if points.size() >= 2:
				draw_polyline(points, COLOR, 2.0, true)
