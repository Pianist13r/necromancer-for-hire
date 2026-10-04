class_name SettingsScreen
extends Control
##
## Экран настроек (§7F плана): громкости шин, мьют, полноэкранный режим, VSync. Открывается
## и из меню, и из паузы (один и тот же оверлей — LegionMain._show_settings переиспользует).
## Хранение и применение — Settings (F0); здесь только виджеты. Владелец — пакет P6.
## Из главного меню (allow_reset) — ещё «Сбросить прогресс» с подтверждением; сам экран
## ничего не стирает, только шлёт reset_confirmed (стирает вызывающий — он знает, что пересобрать).
##
## interface-safety (03.10.2026): экран стал настоящим модальным. Esc закрывает только его,
## событие гасится до LegionWorld._unhandled_input (там «pause» = Esc И латинская P — без
## потребления одно нажатие цепочкой закрыло бы и настройки, и паузу боя); боевые клавиши
## под экраном миром не управляют, а Tab/стрелки/Enter по-прежнему работают в GUI. Карточка —
## секции Звук/Изображение/Управление с прокруткой: в 1280×720 и 960×540 ничего не обрезается,
## «Готово» всегда на виду; фокус при закрытии возвращается экрану, открывшему настройки.
##

signal closed
signal reset_confirmed

const BUSES: Array[StringName] = [&"Master", &"Music", &"SFX", &"Voice"]
const BUS_LABELS := {&"Master": "Общая", &"Music": "Музыка", &"SFX": "Звуки", &"Voice": "Голос"}

## Карточка: ширина — как у прежней card_box (строка громкости 90+10+260 плюс поля рамки),
## высота — вьюпорт минус поля. Меньшее окно сжимает ширину, всё, что не влезло по высоте,
## уходит в прокрутку — потому и константы, а не «растёт под контент».
const CARD_W := 560.0
const CARD_MIN_W := 360.0
const MARGIN := 24.0

## Показывать ли сброс прогресса. Ставится до add_child; из паузы боя — false (стирать
## кампанию посреди боя незачем, а бой потом записал бы итог в уже пустой файл).
var allow_reset := false

## Владелец фокуса до открытия (кнопка «Настройки» паузы или меню): закрыв экран, вернём
## клавиатуру ему — иначе Tab/Enter после закрытия терялись бы в никуда.
var _focus_before: Control = null
var _closing := false


func _ready() -> void:
	UiStyle.fill_rect(self)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	var backdrop := ColorRect.new()
	backdrop.color = Color(0.0, 0.0, 0.0, 0.78)
	UiStyle.fill_rect(backdrop)
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(backdrop)

	# Захватить ДО собственного grab_focus ниже: это фокус нижнего экрана, его и вернём.
	_focus_before = get_viewport().gui_get_focus_owner()

	var panel := _card_panel()
	add_child(panel)
	resized.connect(_fit_card)
	_fit_card()

	# Каркас: заголовок и «Готово» — вне прокрутки (всегда на виду), между ними — скролл.
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 8)
	panel.add_child(outer)

	var title := UiStyle.label("Настройки", 34, UiStyle.FONT_TITLE)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	outer.add_child(title)

	var scroll := ScrollContainer.new()
	scroll.name = "SettingsScroll"
	scroll.follow_focus = true
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	# Единственный растягиваемый ребёнок карточки фиксированной высоты: сколько дали —
	# столько и листаем, заголовок с «Готово» не участвуют в прокрутке.
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer.add_child(scroll)

	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 8)
	scroll.add_child(content)

	_section(content, "Звук")

	var mute_check := CheckBox.new()
	mute_check.text = "Без звука"
	mute_check.button_pressed = Settings.is_muted()
	mute_check.toggled.connect(func(on: bool) -> void: Settings.set_muted(on))
	mute_check.add_theme_font_override("font", ThemeDB.fallback_font)
	mute_check.add_theme_font_size_override("font_size", 18)
	_style_check(mute_check)
	content.add_child(mute_check)

	for bus in BUSES:
		content.add_child(_build_volume_row(bus))

	content.add_child(HSeparator.new())
	_section(content, "Изображение")

	var fullscreen_check := CheckBox.new()
	fullscreen_check.text = "Полноэкранный режим"
	fullscreen_check.button_pressed = Settings.is_fullscreen()
	fullscreen_check.toggled.connect(func(on: bool) -> void: Settings.set_fullscreen(on))
	fullscreen_check.add_theme_font_override("font", ThemeDB.fallback_font)
	fullscreen_check.add_theme_font_size_override("font_size", 18)
	_style_check(fullscreen_check)
	content.add_child(fullscreen_check)

	# v20: «Графика: экономная» (B-053/B-054) — без слоя эффектов, теней и «живости»; применяется
	# сразу (LegionWorld._sync_gfx_layers каждый кадр, докстринг Settings.set_economy_graphics).
	var economy_check := CheckBox.new()
	economy_check.text = "Экономная графика"
	economy_check.tooltip_text = (
		"Выключает фоновые эффекты, тени и движение бойцов. "
		+ "Может помочь слабому ПК.")
	economy_check.button_pressed = Settings.is_economy_graphics()
	economy_check.toggled.connect(func(on: bool) -> void: Settings.set_economy_graphics(on))
	economy_check.add_theme_font_override("font", ThemeDB.fallback_font)
	economy_check.add_theme_font_size_override("font_size", 18)
	_style_check(economy_check)
	content.add_child(economy_check)

	var vsync_check := CheckBox.new()
	vsync_check.text = "Вертикальная синхронизация"
	vsync_check.button_pressed = Settings.is_vsync()
	vsync_check.toggled.connect(func(on: bool) -> void: Settings.set_vsync(on))
	vsync_check.add_theme_font_override("font", ThemeDB.fallback_font)
	vsync_check.add_theme_font_size_override("font_size", 18)
	_style_check(vsync_check)
	content.add_child(vsync_check)

	content.add_child(HSeparator.new())
	_section(content, "Управление")

	# v17: «Управление: рогатка» — снято — классика (ПКМ только щелчок, без натяжки)
	var sling_check := CheckBox.new()
	sling_check.text = "Рывок оттяжкой ПКМ (рогатка)"
	sling_check.tooltip_text = (
		"Включено: зажмите правую кнопку на линии с бойцами,\n"
		+ "оттяните от врага и отпустите — бойцы рванут к нему.\n"
		+ "Выключено: щелчок правой кнопкой сразу выпускает\n"
		+ "бойцов по стрелке линии.")
	sling_check.button_pressed = Settings.control_scheme() == Settings.SCHEME_SLING
	sling_check.toggled.connect(func(on: bool) -> void: Settings.set_control_scheme(
		Settings.SCHEME_SLING if on else Settings.SCHEME_CLASSIC))
	sling_check.add_theme_font_override("font", ThemeDB.fallback_font)
	sling_check.add_theme_font_size_override("font_size", 18)
	_style_check(sling_check)
	content.add_child(sling_check)

	# slow/intuit: советы боя — когда жать Ку/Дубль-вэ/Е, «щёлкни золотой», «сорви пружину»
	var hints_check := CheckBox.new()
	hints_check.text = "Боевые подсказки"
	hints_check.tooltip_text = (
		"Короткие советы: когда применять навыки, где золото "
		+ "и как сорвать пружину.")
	hints_check.button_pressed = Settings.hints_enabled()
	hints_check.toggled.connect(func(on: bool) -> void: Settings.set_hints(on))
	hints_check.add_theme_font_override("font", ThemeDB.fallback_font)
	hints_check.add_theme_font_size_override("font_size", 18)
	_style_check(hints_check)
	content.add_child(hints_check)

	var close_btn := Button.new()
	close_btn.name = "SettingsClose"
	close_btn.text = "Готово"
	close_btn.custom_minimum_size = Vector2(180.0, 44.0)
	close_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	close_btn.add_theme_font_override("font", UiStyle.FONT_TITLE)
	close_btn.add_theme_font_size_override("font_size", 20)
	UiStyle.style_button(close_btn)
	close_btn.pressed.connect(func() -> void: _close())
	outer.add_child(close_btn)

	# «Лицензии»: тексты лицензий третьих сторон внутри игры (exe раздаётся один). Открывается
	# дочерним модальным оверлеем; пока он открыт, этот экран на ввод не реагирует (_input).
	content.add_child(HSeparator.new())
	_section(content, "О игре")
	var version := UiStyle.label("Версия " + ReleaseInfo.VERSION, 17,
		UiStyle.FONT_TEXT, UiStyle.TEXT_DIM)
	version.name = "SettingsVersion"
	content.add_child(version)
	var releases_btn := _small_button("Версии и обновления")
	releases_btn.name = "SettingsReleases"
	releases_btn.pressed.connect(_on_releases)
	content.add_child(releases_btn)
	var update_note := UiStyle.label(
		"Новый выпуск скачайте со страницы версий. Замените игру — прогресс сохранится.",
		16, UiStyle.FONT_TEXT, UiStyle.TEXT_DIM)
	update_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(update_note)
	var licenses_btn := _small_button("Лицензии")
	licenses_btn.name = "SettingsLicenses"
	licenses_btn.pressed.connect(_open_licenses)
	content.add_child(licenses_btn)

	if allow_reset:
		# Сброс — в конец прокручиваемого контента: редкое действие не растягивает карточку,
		# а подтверждение по-прежнему прячет «Готово», вынуждая явный выбор.
		content.add_child(_build_reset_block(close_btn))

	# Начальный фокус — первый виджет: клавиатура сразу ведёт экран (Tab идёт по строкам,
	# Esc закрывает). Отложенно: экран ещё строится, фокус — после входа в дерево.
	mute_check.grab_focus.call_deferred()


## Один путь закрытия для Esc и «Готово»: сначала вернуть фокус прежнему владельцу (по closed
## подписчик делает queue_free — позже возвращать было бы некому), затем сигнал.
func _close() -> void:
	if _closing:
		return
	_closing = true
	if _focus_before != null and is_instance_valid(_focus_before) \
			and _focus_before.is_inside_tree():
		_focus_before.grab_focus()
	closed.emit()


## Esc закрывает только этот экран. _input с потреблением: мир и экран паузы под нами слушают
## «pause» (Esc и P) ниже по цепочке — без потребления одно нажатие ушло бы дальше и следом
## сняло бы паузу боя. echo гасим: автоповтор Esc не должен захлопнуть то, что откроется на этом
## же месте. Берём только ui_cancel — Tab, стрелки и Enter уходят в GUI (навигация клавиатурой
## по настройкам работает, GUI не глушим).
func _input(event: InputEvent) -> void:
	if event.is_echo() or not is_visible_in_tree():
		return
	if _licenses_open():
		return   # оверлей лицензий (наш ребёнок, он получает ввод раньше) сам владеет Esc и Tab
	if _closing:
		get_viewport().set_input_as_handled()
		return
	if event is InputEventKey or event is InputEventJoypadButton or event is InputEventJoypadMotion:
		ModalFocus.contain(self)
	if event.is_action_pressed(&"ui_cancel"):
		get_viewport().set_input_as_handled()
		_close()


func _licenses_open() -> bool:
	var overlay := get_node_or_null("LicensesScreen")
	return overlay != null and not overlay.is_queued_for_deletion()


func _on_releases() -> void:
	_open_release_page(ReleaseInfo.RELEASES_URL)


func _open_release_page(url: String) -> void:
	OS.shell_open(url)


func _open_licenses() -> void:
	if _licenses_open():
		return
	var overlay := LicensesScreen.new()
	overlay.name = "LicensesScreen"
	overlay.process_mode = Node.PROCESS_MODE_ALWAYS   # настройки живут и в паузе боя
	add_child(overlay)


## Боевые горячие клавиши (P из «pause», F/N — волна, R — «Сбор», Ку/Дубль-вэ/Е) под модальным
## экраном миром не управляют. Стадия _unhandled_key_input — ПОСЛЕ GUI (клавиатура виджетов
## жива: фокус, Tab, Enter уже получили своё) и ДО LegionWorld._unhandled_input.
func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and is_visible_in_tree():
		get_viewport().set_input_as_handled()


## Страховка от путей в обход _unhandled_key_input (например, echo-события): пока экран
## открыт, клавиатура не доходит до мира ни одной дорогой.
func _unhandled_input(event: InputEvent) -> void:
	if is_visible_in_tree() and (event is InputEventKey \
			or event is InputEventJoypadButton or event is InputEventJoypadMotion):
		get_viewport().set_input_as_handled()


## Карточка фиксированного прямоугольника с прокруткой внутри. UiStyle.card_box центрирует
## панель анкорами и растёт ПОД содержимое — со ScrollContainer это не сочетается (нечему
## считать протяжённость прокрутки; тот же вывод — HowtoLegion), поэтому своя панель, а стиль
## и рамка — те же, что у card_box: экран остаётся в общем визуальном языке модалок.
## Прямоугольник — от вьюпорта: в 1280×720 и 960×540 карточка целиком в окне, лишнее листается.
func _card_panel() -> PanelContainer:
	var vp := get_viewport_rect().size
	var panel := PanelContainer.new()
	panel.name = "SettingsCard"
	var w := clampf(vp.x - 2.0 * MARGIN, CARD_MIN_W, CARD_W)
	var side := maxf(MARGIN, (vp.x - w) * 0.5)
	panel.anchor_left = 0.0
	panel.anchor_top = 0.0
	panel.anchor_right = 1.0
	panel.anchor_bottom = 1.0
	panel.offset_left = side
	panel.offset_right = -side
	panel.offset_top = MARGIN
	panel.offset_bottom = -MARGIN
	var st := StyleBoxTexture.new()
	st.texture = load("res://assets/legion/ui/panel_frame.svg") as Texture2D
	st.texture_margin_left = 24.0
	st.texture_margin_top = 24.0
	st.texture_margin_right = 24.0
	st.texture_margin_bottom = 24.0
	st.content_margin_left = 32.0
	st.content_margin_right = 32.0
	st.content_margin_top = 20.0
	st.content_margin_bottom = 24.0
	panel.add_theme_stylebox_override("panel", st)
	return panel


func _fit_card() -> void:
	var panel := get_node_or_null("SettingsCard") as PanelContainer
	if panel == null:
		return
	var width := minf(CARD_W, maxf(CARD_MIN_W, size.x - 2.0 * MARGIN))
	var side := maxf(MARGIN, (size.x - width) * 0.5)
	panel.offset_left = side
	panel.offset_right = -side


## Заголовок раздела: список настроек стал длиннее экрана, без подписей Звук/Изображение/
## Управление сливаются в одну простыню (тот же приём, что у HowtoLegion._section).
func _section(box: Control, text: String) -> void:
	box.add_child(UiStyle.label(text, 20, UiStyle.FONT_TITLE, UiStyle.GOLD))


## «Сбросить прогресс…» → подтверждение на месте («Стереть» / «Отмена»), без отдельного окна.
func _build_reset_block(close_btn: Button) -> Control:
	var block := VBoxContainer.new()
	block.add_theme_constant_override("separation", 8)
	block.add_child(HSeparator.new())

	var reset_btn := _small_button("Сбросить прогресс…")
	block.add_child(reset_btn)

	var confirm := VBoxContainer.new()
	confirm.add_theme_constant_override("separation", 8)
	confirm.visible = false
	var warn := UiStyle.label(
		"Удалить кампанию, премию, Контору, героя и обучение? "
			+ "Настройки останутся. Отменить нельзя.",
		16, UiStyle.FONT_TEXT, UiStyle.BAD)
	warn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	warn.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	warn.custom_minimum_size.x = 400.0
	confirm.add_child(warn)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 16)
	var yes_btn := _small_button("Стереть")
	yes_btn.name = "ResetYes"
	yes_btn.add_theme_color_override("font_color", UiStyle.BAD)
	yes_btn.pressed.connect(func() -> void: reset_confirmed.emit())
	var no_btn := _small_button("Отмена")
	no_btn.pressed.connect(func() -> void:
		confirm.visible = false
		close_btn.visible = true
		reset_btn.visible = true)
	row.add_child(yes_btn)
	row.add_child(no_btn)
	confirm.add_child(row)
	block.add_child(confirm)

	reset_btn.name = "ResetAsk"
	reset_btn.pressed.connect(func() -> void:
		reset_btn.visible = false
		close_btn.visible = false
		confirm.visible = true
		no_btn.grab_focus())
	return block


func _small_button(text: String) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.custom_minimum_size = Vector2(180.0, 38.0)
	btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	btn.add_theme_font_override("font", UiStyle.FONT_TEXT)
	btn.add_theme_font_size_override("font_size", 17)
	UiStyle.style_button(btn)
	return btn


## Явная рамка и светлая галочка читаются и без наведения, и с клавиатурным фокусом.
func _style_check(check: CheckBox) -> void:
	check.custom_minimum_size.y = 40.0
	check.add_theme_constant_override("h_separation", 12)
	for state in [
		"font_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color",
	]:
		check.add_theme_color_override(state, UiStyle.TEXT)
	for checked: bool in [false, true]:
		var svg := '<svg xmlns="http://www.w3.org/2000/svg" width="36" height="36" '
		svg += 'viewBox="0 0 36 36">'
		svg += '<defs><linearGradient id="brass" x2="0" y2="1"><stop stop-color="#ffe8a7"/>'
		svg += '<stop offset=".45" stop-color="#c19155"/><stop offset="1" stop-color="#76502f"/>'
		svg += '</linearGradient><linearGradient id="enamel" x2="0" y2="1">'
		svg += '<stop stop-color="#382b49"/>'
		svg += '<stop offset="1" stop-color="#1c1726"/></linearGradient></defs>'
		svg += '<path d="M8 3h20l5 5v20l-5 5H8l-5-5V8z" '
		svg += 'fill="#09070d" opacity=".65"'
		svg += ' transform="translate(0 1)"/>'
		svg += '<path d="M8 2h20l5 5v20l-5 5H8l-5-5V7z" '
		svg += 'fill="url(#brass)"'
		svg += ' stroke="#382a34" stroke-width="1.5"/>'
		svg += '<path d="M9 5h18l3 3v18l-3 3H9l-3-3V8z" '
		svg += 'fill="url(#enamel)"'
		svg += ' stroke="#f3cf88" stroke-width="1"/>'
		svg += '<path d="M9 6h18" stroke="#fff0c2" stroke-width="1" opacity=".65"/>'
		if checked:
			svg += '<path d="M9 17l6 6 12-14" fill="none" stroke="#244638"'
			svg += ' stroke-width="5" stroke-linecap="round" stroke-linejoin="round"/>'
			svg += '<path d="M9 16l6 6 12-14" fill="none" stroke="#9dffc4"'
			svg += ' stroke-width="3.2" stroke-linecap="round" stroke-linejoin="round"/>'
		svg += '</svg>'
		var image := Image.new()
		image.load_svg_from_string(svg)
		check.add_theme_icon_override("checked" if checked else "unchecked",
			ImageTexture.create_from_image(image))
	var focus := StyleBoxFlat.new()
	focus.bg_color = Color(1.0, 0.82, 0.48, 0.10)
	focus.border_color = UiStyle.GOLD
	focus.set_border_width_all(1)
	focus.set_corner_radius_all(5)
	check.add_theme_stylebox_override("focus", focus)
	check.add_theme_stylebox_override("hover", focus)
	check.add_theme_stylebox_override("hover_pressed", focus)


func _build_volume_row(bus: StringName) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)

	var label := UiStyle.label(String(BUS_LABELS.get(bus, String(bus))), 18, ThemeDB.fallback_font)
	label.custom_minimum_size = Vector2(90.0, 0.0)
	row.add_child(label)

	var slider := HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 1.0
	slider.step = 0.01
	slider.value = Settings.get_bus_volume(bus)
	slider.custom_minimum_size = Vector2(260.0, 32.0)
	# Карточка теперь меняет ширину под окно — дорожка громкости тянется за ней, а не торчит
	# фиксированным куском (минимум 260 держит удобный захват).
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_style_volume_slider(slider)
	slider.value_changed.connect(func(v: float) -> void: Settings.set_bus_volume(bus, v))
	row.add_child(slider)
	return row


## Бронзовая дорожка с литым восьмиугольным ползунком; рабочий track остаётся контрастным.
func _style_volume_slider(slider: HSlider) -> void:
	var rail := StyleBoxFlat.new()
	rail.bg_color = Color("211a28")
	rail.border_color = Color("715332")
	rail.content_margin_top = 3.0
	rail.content_margin_bottom = 3.0
	rail.set_border_width_all(1)
	rail.set_corner_radius_all(4)
	var fill := StyleBoxFlat.new()
	fill.bg_color = Color("b7864d")
	fill.content_margin_top = 3.0
	fill.content_margin_bottom = 3.0
	fill.set_corner_radius_all(4)
	var hot_fill := StyleBoxFlat.new()
	hot_fill.bg_color = Color("e1b76f")
	hot_fill.content_margin_top = 3.0
	hot_fill.content_margin_bottom = 3.0
	hot_fill.set_corner_radius_all(4)
	slider.add_theme_stylebox_override("slider", rail)
	slider.add_theme_stylebox_override("grabber_area", fill)
	slider.add_theme_stylebox_override("grabber_area_highlight", hot_fill)
	slider.add_theme_icon_override("grabber", _volume_grabber(false))
	slider.add_theme_icon_override("grabber_highlight", _volume_grabber(true))
	slider.add_theme_icon_override("grabber_disabled", _volume_grabber(false))
	slider.add_theme_constant_override("grabber_offset", 0)


func _volume_grabber(highlighted: bool) -> Texture2D:
	var rim := "#ffe9ac" if highlighted else "#d0a061"
	var svg := '<svg xmlns="http://www.w3.org/2000/svg" width="36" height="36" '
	svg += 'viewBox="0 0 36 36">'
	svg += '<defs><linearGradient id="bronze" x2="0" y2="1"><stop stop-color="#ffe4a0"/>'
	svg += '<stop offset=".4" stop-color="#c39252"/>'
	svg += '<stop offset="1" stop-color="#79502e"/></linearGradient>'
	svg += '<linearGradient id="well" x2="0" y2="1"><stop stop-color="#4b3656"/>'
	svg += '<stop offset="1" stop-color="#241d30"/></linearGradient></defs>'
	svg += '<path d="M18 2l10 5 6 11-6 11-10 5L8 29 2 18 8 7z" '
	svg += 'fill="#100d15" opacity=".8" transform="translate(0 1)"/>'
	svg += '<path d="M18 2l10 5 6 11-6 11-10 5L8 29 2 18 8 7z" '
	svg += 'fill="url(#bronze)" stroke="#382a34" stroke-width="1.5"/>'
	svg += '<path d="M18 5l8 4 5 9-5 9-8 4-8-4-5-9 5-9z" '
	svg += 'fill="url(#well)" stroke="%s" stroke-width="1.5"/>' % rim
	svg += '<path d="M18 10l5 8-5 8-5-8z" fill="#d4aa67" stroke="#f5d997" stroke-width="1"/>'
	svg += '<circle cx="18" cy="18" r="2" fill="#fff0c4"/>'
	svg += '</svg>'
	var image := Image.new()
	image.load_svg_from_string(svg)
	return ImageTexture.create_from_image(image)
