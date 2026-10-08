class_name LegionHud
extends CanvasLayer
##
## Боевой HUD v17 «бюрократия преисподней» (docs/legion/DESIGN_V17.md §1). Стиль — LegionUi.
##
## Состав (снизу вверх по отрисовке): телеграф угрозы и виньетка урона (LegionThreatEdge),
## верхняя плашка-бланк Котёл · Мана · Армия · Души · Волна (LegionTopPlate), «+N» душ у убийств
## (SoulsCounter), превью волны справа сверху, тосты-бумажки по центру, карточки договоров
## (LegionKindBar) и слоты способностей (AbilityBar) внизу; для compat-пути без LegionMain —
## свои надпись-пауза и итог.
##
## Все корни — MOUSE_FILTER_IGNORE: HUD, ловящий мышь, съедает клики по арене и руна не чертится.
## Карточки вида и «Вызвать» тоже IGNORE (B-055: штрих, начатый над ними, иначе не начинался) —
## их короткий щелчок разбирает ui_tap() из ContractField._release; ловят мышь пауза и «Касса».
##
## Счётчики армии и строка волны пересчитываются 4 раза в секунду (REFRESH), а не каждый кадр:
## обход всех бойцов и форматирование строк — лишние аллокации, глаз разницы не видит.
##

const REFRESH := 0.25
const TOAST_MAX := 4
## Верх столбика тостов, когда сверху ничего нет: под плашкой статов (5 + 40) с зазором.
const TOAST_TOP := 56.0
const TOAST_FONT := 18

var world: LegionWorld = null
var pause_button: Button
## Пакет flow: false — LegionMain ведёт бой через свои экраны (LegionPause/LegionResult), этот
## HUD прячет собственные надпись-паузу и панель итога, чтобы не дублировать поверх них.
## По умолчанию true — совместимость с compat-путём (гейт/бот/серии/тесты не трогают LegionMain).
var show_native_ui := true
## Запись промо (scripts/dev/legion_director.gd, REC-06): тосты и превью волны спрятаны —
## плашки поверх боя не перекрывают кадр. Бой и остальной HUD не меняются.
var cinematic := false
## «Схватка» (P5c): плашка соперника с часами и экран итога; создаются на первом матче PvP.
var pvp_plate: PvpTopPlate = null
var pvp_result: PvpResult = null
## «Касса» (D-1001-01): кнопка одиночного боя между плашками.
var kassa_button: LegionKassaButton = null

## Текстовая сводка плашки одной строкой: не рисуется (плашка рисует себя сама), нужна тестам
## и отладке — «Мана 93 · Армия 26 (строй 13, свободно 12) · Волна 1/5 через 12 с · Котёл 200».
var _stats: Label
var _plate: LegionTopPlate
var _threat: LegionThreatEdge
var _toasts: VBoxContainer
var _pause: Label
var _result: PanelContainer
var _result_text: Label
var _t := 0.0
var _ability_bar: AbilityBar
var _preview: PanelContainer
var _preview_text: RichTextLabel
## Альфа, к которой стремится превью: бледнеет, когда под ним враги (_foes_under_preview).
var _preview_alpha := 1.0
## Кегль, которым набраны строки превью прямо сейчас (ставится по числу строк, L).
var _preview_font_size_now := 0
var _call: Button
## B-055: «Вызвать» мышь не ловит (MOUSE_FILTER_IGNORE) — подсветку наведения ставим сами.
var _call_styles: Dictionary = {}
var _call_hover := false
var _kind_bar: LegionKindBar
## Подписи дорог gen-карты (B-355) — считаются один раз на карту (_road_labels).
var _labels_map := "<ещё не считали>"
var _labels: Dictionary = {}


func setup(w: LegionWorld) -> void:
	world = w
	layer = 5
	process_mode = Node.PROCESS_MODE_ALWAYS
	_threat = LegionThreatEdge.new()
	add_child(_threat)
	_threat.setup(w)
	_plate = LegionTopPlate.new()
	add_child(_plate)
	_plate.setup(w)
	_stats = Label.new()
	_stats.visible = false
	_stats.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_stats)
	add_child(SoulsCounter.new().setup(w))  # «+N» душ у места убийства
	kassa_button = LegionKassaButton.new().setup(w, _plate)
	add_child(kassa_button)
	_ability_bar = AbilityBar.new()
	add_child(_ability_bar)
	_ability_bar.setup(w)  # слоты Q/W/E, сами читают world.hero
	_toasts = VBoxContainer.new()
	_toasts.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_toasts.offset_top = TOAST_TOP
	# Тосты живут в средней трети экрана и переносятся по словам: длинная подсказка карты
	# уезжала под панель превью волны справа (кадр Лабиринта 25.09).
	_toasts.offset_left = LegionCfg.TOAST_SIDE_MARGIN
	_toasts.offset_right = -LegionCfg.TOAST_SIDE_MARGIN
	_toasts.add_theme_constant_override("separation", 6)
	_toasts.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_toasts)
	_build_pause()
	_build_result()
	_build_preview()
	_kind_bar = LegionKindBar.attach(self, w)
	w.match_started.connect(func(_id: String) -> void: _sync_pvp())


func _build_pause() -> void:
	pause_button = ProgressionUi.button("❚❚ Пауза", func() -> void:
		if world.pvp and world.pvp_menu != null:
			world.pvp_menu.toggle()
		elif world.phase == LegionWorld.Phase.BATTLE:
			world.set_paused(true))
	pause_button.name = "PauseAction"
	add_child(pause_button)
	pause_button.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	pause_button.offset_left = -184
	pause_button.offset_right = -12
	pause_button.offset_top = 12
	pause_button.offset_bottom = 60
	_pause = LegionUi.label("Пауза (Esc)", 34, LegionUi.FONT_TITLE, LegionUi.TEXT)
	_pause.position = Vector2(560, 320)
	_pause.visible = false
	add_child(_pause)


func _build_result() -> void:
	_result = PanelContainer.new()
	_result.position = Vector2(440, 230)
	_result.custom_minimum_size = Vector2(400, 220)
	_result.add_theme_stylebox_override("panel", LegionUi.blank_style(LegionUi.GOLD,
		LegionUi.PAPER_HI, 24.0, 18.0))
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	_result.add_child(box)
	_result_text = LegionUi.label("", 20, LegionUi.FONT_TEXT, LegionUi.TEXT)
	_result_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_result_text)
	var again := Button.new()
	again.text = "Ещё раз"
	LegionUi.style_button(again, LegionUi.GOLD, 20)
	again.pressed.connect(func() -> void: world.restart())
	box.add_child(again)
	_result.visible = false
	add_child(_result)


func tick(delta: float) -> void:
	_t -= delta
	_pause.visible = world.paused and show_native_ui
	pause_button.visible = world.phase == LegionWorld.Phase.BATTLE and not world.paused
	_sync_pvp()
	_preview.modulate.a = move_toward(_preview.modulate.a, _preview_alpha,
		delta * LegionCfg.WAVE_PREVIEW_FADE_SPEED)
	_hover_call()
	if _t > 0.0:
		return
	_t = REFRESH
	_preview_alpha = LegionCfg.WAVE_PREVIEW_DIM_ALPHA if _foes_under_preview() else 1.0
	_update_preview()
	var free := 0
	var posted := 0
	for u in world.units:
		if not u.alive or u.side != world.local_side:   # «Схватка»: только свои (B-340)
			continue
		if u.state == Legionnaire.State.POSTED:
			posted += 1
		else:
			free += 1       # все живые вне строя: свободные, Сбор, марш и натиск
	_plate.set_army(posted, free)
	_threat.avoid = panel_rects()
	var wr := world.wave_runner
	var wave_txt := "%d/%d" % [wr.wave_no(), wr.total()] if wr != null else "-"
	_plate.wave_hint = _wave_hint()
	_stats.text = "Мана %d · Армия %d (строй %d, свободно %d) · Волна %s %s · Котёл %d" % [
		int(world.my_field().mana), world.army_alive(world.local_side), posted, free, wave_txt,
		_plate.wave_hint,
		int(ceilf(world.my_side().cauldron_hp)),
	]


## Экранные прямоугольники панелей HUD, которые закрывают арену: телеграф угрозы не ставит
## маркер под них (ворота Развилки выходят ровно под превью волны и под слоты способностей).
func panel_rects() -> Array[Rect2]:
	var out: Array[Rect2] = [_plate.get_global_rect()]
	if pvp_plate != null and pvp_plate.visible:
		out.append(pvp_plate.panel_rect())
	if pause_button != null and pause_button.visible:
		out.append(pause_button.get_global_rect())
	if kassa_button != null and kassa_button.visible:
		out.append(kassa_button.get_global_rect())
	if _preview.visible:
		out.append(_preview.get_global_rect())
	if _kind_bar != null and _kind_bar.visible:
		out.append(_kind_bar.get_global_rect())
	var slots := _ability_bar.slot_rect(AbilityBar.SLOT_RALLY).merge(_ability_bar.slot_rect(2))
	out.append(slots.grow_individual(0.0, 8.0, 0.0, AbilityBar.MARGIN_BOTTOM))
	return out


## «Схватка» (P5c, B-302): панель превью волны спрятана (закрывала правый верхний угол поля,
## «Вызвать» в PvP нет), справа встаёт плашка соперника и часов, итог — свой экран.
func _sync_pvp() -> void:
	_preview.visible = not world.pvp and not cinematic
	# «Схватка»: правый верхний угол занят плашкой соперника (та же строка, до y=45), поэтому
	# пауза встаёт НИЖЕ верхней строки (y 100…148) — верхние плашки остаются одной строкой
	# (legion_pvp_hud_test: всё, что начинается выше y=100, обязано кончаться к y=50).
	# Обе позиции — внутри резерва генератора справа сверху (960,0,320,200).
	pause_button.offset_top = 100 if world.pvp else 12
	pause_button.offset_bottom = pause_button.offset_top + 48
	if not world.pvp or pvp_plate != null:
		return
	pvp_plate = PvpTopPlate.new().setup(world)
	add_child(pvp_plate)
	pvp_result = PvpResult.new()
	add_child(pvp_result)
	pvp_result.again.connect(func() -> void: world.restart())
	pvp_result.menu.connect(_pvp_to_menu)


## «В меню» после матча: мир внутри LegionMain — главное меню (B-321, P6); запущен сам по себе
## (`legion_world.tscn -- --map pvp:duel`) — вернуться некуда, закрываем игру.
func _pvp_to_menu() -> void:
	world.go_to_menu()
	if world.embedded:
		world.pvp_menu_requested.emit()
	else:
		get_tree().quit()


## Прямоугольник панели волн на экране (совет «F» встаёт под ней, B-078); пустой — панели нет.
func preview_rect() -> Rect2:
	return _preview.get_global_rect() if _preview != null and _preview.visible else Rect2()


## Враг под превью волны (с запасом): на Развилке и Стиксе северные ворота лежат под панелью,
## и драка у ворот шла вслепую (партия по переписке 25.09.2026). Враги — в мировых координатах
## под камерой (тряска), панель — в экранных: переводим через canvas transform.
func _foes_under_preview() -> bool:
	if not _preview.visible:
		return false
	var rect := _preview.get_global_rect().grow(LegionCfg.WAVE_PREVIEW_DIM_MARGIN)
	var xf := get_viewport().get_canvas_transform()
	for f in world.foes:
		if f.is_active() and rect.has_point(xf * f.position):
			return true
	return false


## Вторая строка блока «Волна». Во время обучения волны стоят (WaveRunner.held) — отсчёт
## замирал бы и врал, поэтому «обучение».
func _wave_hint() -> String:
	var wr := world.wave_runner
	if wr == null:
		return ""
	if world.tutorial != null and world.tutorial.holding():
		return "обучение"
	var left := wr.next_start_in()
	if left < 0.0:
		return "последняя" if wr.phase != WaveRunner.Phase.DONE else "все пройдены"
	if is_finite(left):
		return "через %d с" % ceili(left)
	return "идёт проверка" if wr.phase == WaveRunner.Phase.RUN else "после клира"


## Сдвинуть столбик тостов ниже y (плашка обучения сверху — legion_tutorial.gd). 0 — вернуть
## на обычное место. Тосты не должны налезать на плашку: владелец 25.09 видел их поверх неё.
func set_toast_floor(y: float) -> void:
	_toasts.offset_top = maxf(TOAST_TOP, y)


## Прямоугольники видимых тостов (экранные) — тест обучения проверяет, что они не лезут на плашку.
func toast_rects() -> Array[Rect2]:
	var out: Array[Rect2] = []
	for c in _toasts.get_children():
		var l := c as Control
		if l != null and l.visible and not l.is_queued_for_deletion():
			out.append(l.get_global_rect())
	return out


## Тост-бумажка: бланк по ширине текста (длинный — переносится), рамка по виду сообщения —
## warn красными чернилами печати, wave — золотом, остальное — обычными чернилами.
## time > 0 — держать тост столько секунд вместо LegionCfg.TOAST_TIME (длинная подсказка).
## Единственный сток клавиш для тостов (KB-02): {key:…} и штатные имена — в текущие клавиши.
## Зовущие (мир, уроки, разовые подсказки, поправки) Controls.text сами не применяют.
func toast(raw: String, kind: StringName, time := -1.0) -> void:
	var text := Controls.text(raw)
	var ink := LegionUi.INK
	match kind:
		&"warn":
			ink = LegionUi.STAMP
		&"wave":
			ink = LegionUi.GOLD
	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	panel.add_theme_stylebox_override("panel",
		LegionUi.blank_style(ink, LegionUi.PAPER_HI, 16.0, 6.0))
	var l := LegionUi.label(text, TOAST_FONT, LegionUi.FONT_TEXT,
		LegionUi.TEXT if kind != &"wave" else LegionUi.GOLD.lightened(0.3))
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var w := LegionUi.FONT_TEXT.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, TOAST_FONT).x
	if w > LegionCfg.HUD_TOAST_MAX_W:
		l.autowrap_mode = TextServer.AUTOWRAP_WORD
		l.custom_minimum_size.x = LegionCfg.HUD_TOAST_MAX_W
	panel.add_child(l)
	_toasts.add_child(panel)
	while _toasts.get_child_count() > TOAST_MAX:
		var old := _toasts.get_child(0)
		_toasts.remove_child(old)
		old.queue_free()
	# Tween живёт на самом тосте: если его раньше убрал вытеснитель или очистка мира, таймер
	# умирает вместе с ним. Лямбда на таймере дерева держала захват освобождённой метки, и
	# движок писал «Lambda capture was freed». PAUSE_PROCESS — тост гаснет и во время паузы.
	panel.modulate.a = 0.0
	var tw := panel.create_tween()
	tw.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	tw.tween_property(panel, "modulate:a", 1.0, 0.12)
	tw.tween_interval(maxf(0.1, (time if time > 0.0 else LegionCfg.TOAST_TIME) - 0.42))
	tw.tween_property(panel, "modulate:a", 0.0, 0.3)
	tw.tween_callback(panel.queue_free)


func show_result(victory: bool, stats: Dictionary) -> void:
	if world.pvp:   # итог «Схватки» — свой экран, при любом show_native_ui (P5c)
		_sync_pvp()
		pvp_result.show_for(world)
		return
	if not show_native_ui:
		return
	_result_text.text = "%s\nКотёл: %d   Убито: %d   Потери: %d\nНатисков: %d   Продлений: %d" % [
		"Победа! Проверка пройдена" if victory else "Котёл пал. Договор расторгнут",
		int(ceilf(world.cauldron_hp)), int(stats["kills"]), int(stats["lost"]),
		int(stats["charges"]), int(stats["refreshes"]),
	]
	if bool(stats.get("has_breaches", false)) and int(stats.get("breach_leaks", 0)) == 0:
		_result_text.text += "\nЗакрыл трещину"
	_result.visible = true


func hide_result() -> void:
	_result.visible = false
	if pvp_result != null:
		pvp_result.hide_result()
	drop_toasts()


## Убрать все тосты разом. Урок начала боя занимает верх экрана сам — вводный тост карты
## (тот же текст, что был на брифинге) под ним давал стопку из двух плашек поверх верхней дороги
## (corr 29.09, находка 9): его гасит legion_tutorial.gd, когда встаёт урок начала боя.
func drop_toasts() -> void:
	for c in _toasts.get_children():
		c.queue_free()


## Кино-режим записи (см. `cinematic`): включить — тосты и превью волны прочь, выключить — вернуть.
func set_cinematic(on: bool) -> void:
	cinematic = on
	_toasts.visible = not on
	_preview.visible = not on and not world.pvp


func _build_preview() -> void:
	_preview = PanelContainer.new()
	_preview.position = LegionCfg.WAVE_PREVIEW_POS
	_preview.custom_minimum_size = LegionCfg.WAVE_PREVIEW_SIZE
	# Панель пропускает мышь (кликабельна только кнопка) и просвечивает: на Лабиринте под ней
	# площадка p6 (1020,110), на Прорабе/Стиксе/Развилке — начало северной дороги (verifier 25.09:
	# с MOUSE_FILTER_STOP человек не мог построить на p6).
	_preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var preview_style := UiStyle.panel_style(
		Color(LegionUi.PAPER, LegionCfg.WAVE_PREVIEW_BG.a + 0.18))
	preview_style.content_margin_left = 10.0
	preview_style.content_margin_right = 10.0
	preview_style.content_margin_top = 2.0
	preview_style.content_margin_bottom = 2.0
	_preview.add_theme_stylebox_override("panel", preview_style)
	add_child(_preview)
	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", 4)
	_preview.add_child(box)
	_preview_text = RichTextLabel.new()
	_preview_text.bbcode_enabled = true
	_preview_text.fit_content = true
	_preview_text.scroll_active = false
	_preview_text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_preview_text.add_theme_font_size_override("normal_font_size", LegionCfg.WAVE_PREVIEW_FONT)
	_preview_text.add_theme_font_size_override("bold_font_size", LegionCfg.WAVE_PREVIEW_FONT + 2)
	# заголовок — рукописным ([b] = Underdog), строки групп — чистым шрифтом ради чисел
	_preview_text.add_theme_font_override("bold_font", LegionUi.FONT_TITLE)
	_preview_text.add_theme_color_override("default_color", LegionUi.TEXT)
	_preview_text.add_theme_color_override("font_outline_color", LegionUi.OUTLINE)
	_preview_text.add_theme_constant_override("outline_size", 3)
	# Межстрочный интервал — ровный. Пяти строкам видов под кнопкой паузы (WAVE_PREVIEW_POS.y 64,
	# бюджет 136 px) тесно, но сжимать ИНТЕРВАЛ нельзя: строки наезжали друг на друга и на заголовок
	# («Зомби ×4» поверх «Следующая волна через 3 с», находка L). Тесно — режут кегль (прикидка
	# по строкам плюс добор по замеру) и число показанных видов, но не читаемость.
	_preview_text.add_theme_constant_override("line_separation", 0)
	box.add_child(_preview_text)
	_call = Button.new()
	_call.text = "Вызвать (%s)" % Controls.label(&"call_wave")
	_call.focus_mode = Control.FOCUS_NONE
	# B-055: кнопка мышь не ловит — штрих, начатый на ней, чертится; щелчок разбирает ui_tap()
	_call.mouse_filter = Control.MOUSE_FILTER_IGNORE
	LegionUi.style_button(_call, LegionUi.STAMP, 16)
	_call_styles = {"normal": _call.get_theme_stylebox("normal"),
		"hover": _call.get_theme_stylebox("hover")}
	_call.pressed.connect(_press_call)
	box.add_child(_call)


func _press_call() -> void:
	world.call_wave()
	_update_preview()


## B-055: короткий щелчок поля (ContractField._release, экран вьюпорта) по кнопке HUD, которая
## сама мышь не ловит, — карточке вида или «Вызвать». true — щелчок разобран (не tap площадки).
## act=false — только проверить попадание (ничего не нажимать).
func ui_tap(screen: Vector2, act := true) -> bool:
	if _kind_bar != null and _kind_bar.tap(screen, act):
		return true
	if _call != null and _call.is_visible_in_tree() and _call.get_global_rect().has_point(screen):
		if act and not _call.disabled:
			_press_call()
		return true
	return false


## Наведение на «Вызвать»: та же рамка «hover», что дала бы кнопка, ловящая мышь.
func _hover_call() -> void:
	if _call == null or _call_styles.is_empty():
		return
	var on := _call.is_visible_in_tree() and not _call.disabled \
		and not world.my_field().has_draft() \
		and _call.get_global_rect().has_point(_call.get_viewport().get_mouse_position())
	if on == _call_hover:
		return
	_call_hover = on
	_call.add_theme_stylebox_override("normal", _call_styles["hover" if on else "normal"])
	_call.add_theme_color_override("font_color", Color.WHITE if on else LegionUi.TEXT)


func _update_preview() -> void:
	_call.text = "Вызвать (%s)" % Controls.label(&"call_wave")
	var wr := world.wave_runner
	if wr == null:
		return
	_call.visible = not wr.held
	_call.disabled = not world.contracts.human_input or not wr.can_call()
	_apply_preview_font(_preview_font_size(1))   # короткие строки — полным кеглем
	if wr.held:
		_preview_text.text = "Обучение"
		return
	var left := wr.next_start_in()
	if left < 0.0:
		_preview_text.text = "[b]Все волны вызваны[/b]"
		return
	var title := "[b]Следующая волна после клира[/b]"
	if is_finite(left):
		var hot := left <= LegionCfg.HUD_THREAT_LEAD
		title = "[b]Следующая волна через [color=#%s]%d с[/color][/b]" % [
			(LegionUi.GOLD if hot else LegionUi.TEXT).to_html(false), ceili(left)]
	var lines := PackedStringArray([title])
	# Кульминация читается заранее: пик и чем отвечать (вызов — это когда видно, чем ответить)
	var has_hint := false
	var hint := ""
	if wr.is_climax(wr.index + 1):
		lines[0] = title.replace("Следующая волна", "[color=#%s]КУЛЬМИНАЦИЯ[/color]"
			% LegionUi.STAMP.to_html(false))
		hint = LegionChallenge.answer_hint(wr.next_wave_groups())
		has_hint = hint != ""
	# Одна строка на ВИД врага, без переносов (B-203): панель ограничена 200 px по нижнему краю
	# (генератор резервирует под неё только y 0–200), а старая раскладка «вид × ворота» на трёх
	# дорогах и полудюжине видов растягивала панель до 493 px и закрывала правые ворота.
	var order: Array[String] = []
	var per_type: Dictionary = {}          # вид → {источник: сколько}
	var per_source: Dictionary = {}        # источник → сколько (сводка по воротам, B-204)
	var source_order: Array[String] = []
	for g in wr.next_wave_groups():
		var t := String(g["type"])
		var source := String(g["from"])
		if not per_type.has(t):
			per_type[t] = {}
			order.append(t)
		var per: Dictionary = per_type[t]
		per[source] = int(per.get(source, 0)) + int(g["count"])
		if not per_source.has(source):
			per_source[source] = 0
			source_order.append(source)
		per_source[source] = int(per_source[source]) + int(g["count"])
	var dim := LegionUi.TEXT_DIM.to_html(false)
	# Больше двух дорог — сводная строка по воротам не влезла бы (B-204), вместо неё однобуквенные
	# метки прямо у вида, но только у видов, которые реально идут с нескольких ворот.
	var many_gates := source_order.size() > 2
	# Подсказка кульминации уже забрала свою строку — потолок видов на одну строку ниже:
	# кульминация со всеми пятью видами вместе с подсказкой рвала 200 px (B-203).
	var max_kinds := LegionCfg.WAVE_PREVIEW_MAX_KINDS - (1 if has_hint else 0)
	var gate_line := not has_hint and source_order.size() in [1, 2]
	# Кегль — по числу строк, а межстрочный интервал ровный: строки не наезжают друг на друга
	# (находка L), а панель всё равно укладывается под кнопкой паузы. Подсказка кульминации —
	# длинное предложение, ей тот же кегль, что и строке ворот (мельче вида, B-203); оно почти
	# всегда переносится, поэтому считаем её за две строки.
	var shown := mini(order.size(), max_kinds)
	var rows := _preview_rows(shown, order.size(), has_hint, gate_line)
	# Места не хватает — режем СПИСОК ВИДОВ, а не кегль: состав всё равно читается по меткам у
	# края экрана, а кегль ниже нижнего не читается нигде.
	var max_rows := _preview_max_rows()
	while shown > 0 and rows > max_rows:
		shown -= 1
		rows = _preview_rows(shown, order.size(), has_hint, gate_line)
	var size := _preview_font_size(rows)
	_apply_preview_font(size)
	var gate_size := mini(LegionCfg.WAVE_PREVIEW_GATE_FONT, size)
	if has_hint:
		lines.append("[font_size=%d][color=#%s]%s[/color][/font_size]" %
			[gate_size, LegionUi.GOLD.to_html(false), hint])
	for i in shown:
		var t: String = order[i]
		var per: Dictionary = per_type[t]
		var total := 0
		for c in per.values():
			total += int(c)
		# Цвет — тот же, что у телеграфа угрозы у края: игрок связывает строку и свечение.
		var col := LegionThreatEdge.foe_color(t).to_html(false)
		var line := "[color=#%s]%s ×%d[/color]" % [col, LegionWorld.foe_caption(t), total]
		if many_gates and per.size() > 1:
			var letters: Array[String] = []
			for source: String in per:
				var l := _source_letter(source)
				if not letters.has(l):
					letters.append(l)
			line += " [color=#%s](%s)[/color]" % [dim, "·".join(letters)]
		lines.append(line)
	if order.size() > shown:
		lines.append("[color=#%s]+ ещё %d %s[/color]" % [dim, order.size() - shown,
			LegionAbilityAim.plural(order.size() - shown, "вид", "вида", "видов")])
	# Мелкая подпись воротами — только если дорог не больше двух (B-204) и панель не занята
	# подсказкой кульминации (та ценнее и тоже забирает высоту — иначе вдвоём рвали потолок 200 px).
	if gate_line:
		lines.append("[font_size=%d][color=#%s]%s[/color][/font_size]" %
			[gate_size, dim, gate_summary(source_order, per_source)])
	_preview_text.text = "\n".join(lines)
	# Прикидка по числу строк не знает переносов (длинная строка занимает две) — подтягиваем по
	# ФАКТИЧЕСКОЙ высоте содержимого: замер синхронный, а от кегля высота зависит почти линейно.
	_fit_preview_font(size)


## Сколько строк займёт панель: заголовок, подсказка кульминации (почти всегда в две строки),
## виды, строка «+ ещё N вида» и подпись воротами.
func _preview_rows(shown: int, total: int, has_hint: bool, gate_line: bool) -> int:
	return 1 + (2 if has_hint else 0) + shown + (1 if total > shown else 0) \
		+ (1 if gate_line else 0)


## Потолок строк панели при САМОМ мелком кегле: выше него панель вылезет из бюджета под кнопкой
## паузы (крайние волны кампании и синтетический максимум — legion_hud_preview_test).
func _preview_max_rows() -> int:
	var room := float(LegionCfg.WAVE_PREVIEW_BUDGET - LegionCfg.WAVE_PREVIEW_CALL_H)
	return int(floor(room / (1.5 * float(LegionCfg.WAVE_PREVIEW_FONT_MIN) - 1.0)))


## Кегль строк панели превью: их бывает до семи, а место под кнопкой паузы конечно
## (WAVE_PREVIEW_POS.y 64, бюджет WAVE_PREVIEW_BUDGET). Высота строки по замеру панели — примерно
## 1,5·кегль − 1 px (заголовок на два пункта крупнее и этой оценкой уже покрыт сверху).
## Тесно — режем кегль, но не интервал: сжатые строки не читаются вовсе (находка L).
func _preview_font_size(rows: int) -> int:
	var size := LegionCfg.WAVE_PREVIEW_FONT
	var room := float(LegionCfg.WAVE_PREVIEW_BUDGET - LegionCfg.WAVE_PREVIEW_CALL_H)
	while size > LegionCfg.WAVE_PREVIEW_FONT_MIN and float(rows) * (1.5 * float(size) - 1.0) > room:
		size -= 1
	return size


## Довести панель до бюджета по ФАКТИЧЕСКОЙ высоте содержимого: строки переносятся, и заранее
## их число не знает никто, а надпись отдаёт высоту сразу после смены текста и кегля.
## Высота почти линейна по кеглю — одной поправкой попадаем, дальше шагаем по одному.
func _fit_preview_font(size: int) -> void:
	var room := float(LegionCfg.WAVE_PREVIEW_BUDGET - LegionCfg.WAVE_PREVIEW_CALL_H)
	var h := float(_preview_text.get_content_height())
	if h <= room:
		return
	var guess := maxi(LegionCfg.WAVE_PREVIEW_FONT_MIN, int(floor(float(size) * room / h)))
	_apply_preview_font(guess)
	while _preview_font_size_now > LegionCfg.WAVE_PREVIEW_FONT_MIN \
			and float(_preview_text.get_content_height()) > room:
		_apply_preview_font(_preview_font_size_now - 1)


## Кегль ставим только при смене: _update_preview зовётся каждый тик.
func _apply_preview_font(size: int) -> void:
	if size == _preview_font_size_now:
		return
	_preview_font_size_now = size
	_preview_text.add_theme_font_size_override("normal_font_size", size)
	_preview_text.add_theme_font_size_override("bold_font_size", size + 2)


## Сводка «откуда сколько» под списком видов. Ветки одних ворот (развилка gen-карты, B-355) —
## под одним названием ворот: «вост. ворота: верх. ×4 · ниж. ×3», а не как двое разных ворот.
func gate_summary(sources: Array[String], per_source: Dictionary) -> String:
	var labels := _road_labels()
	var parts := PackedStringArray()
	var done: Array[String] = []
	for source: String in sources:
		if done.has(source):
			continue
		var lab: Dictionary = labels.get(source.trim_prefix("gate:"), {}) \
			if source.begins_with("gate:") else {}
		if not bool(lab.get("fork", false)):
			done.append(source)
			parts.append("%s ×%d" % [_place_short(source), int(per_source[source])])
			continue
		var branches := PackedStringArray()
		for other: String in sources:
			var ol: Dictionary = labels.get(other.trim_prefix("gate:"), {}) \
				if other.begins_with("gate:") else {}
			if not done.has(other) and String(ol.get("gate", "")) == String(lab["gate"]):
				done.append(other)
				branches.append("%s ×%d" % [String(ol["branch"]), int(per_source[other])])
		parts.append("%s ворота: %s" % [String(LegionCfg.ROAD_SHORT.get(String(lab["side"]),
			"")), " · ".join(branches)])
	return " · ".join(parts)


## Подписи дорог gen-карты (PgLayout.road_labels) — на карту один раз; кампания → {}.
func _road_labels() -> Dictionary:
	if world == null:
		return {}
	if _labels_map != world.map_id:
		_labels_map = world.map_id
		_labels = PgLayout.road_labels(world.map)
	return _labels


## Подпись дороги из road_labels по источнику "gate:<id>" ("" — нет такой, берём по id).
func _label(source: String, key: String) -> String:
	if not source.begins_with("gate:"):
		return ""
	return String(Dictionary(_road_labels().get(source.trim_prefix("gate:"), {})).get(key, ""))


## Игрок видит русское название источника, а не id дороги из JSON («ворота east» — кадр
## приёмки 25.09). Незнакомая дорога — просто «ворота»; у трещины id игроку не нужен.
func _place_title(source: String) -> String:
	if source.begins_with("breach:"):
		return "трещина"
	var lab := _label(source, "title")
	if lab != "":
		return lab
	return String(LegionCfg.ROAD_TITLES.get(source.trim_prefix("gate:"), "ворота"))


## Короткое название источника для строки с несколькими воротами.
func _place_short(source: String) -> String:
	if source.begins_with("breach:"):
		return "трещ."
	var lab := _label(source, "short")
	if lab != "":
		return lab
	return String(LegionCfg.ROAD_SHORT.get(source.trim_prefix("gate:"), "ворота"))


## Однобуквенная метка источника (B-204: три дороги и больше — вместо коротких слов у вида).
## У gen-карты — буква стороны ворот (две восточные дороги обе «в»: их общая метка правдива).
func _source_letter(source: String) -> String:
	if source.begins_with("breach:"):
		return LegionCfg.BREACH_LETTER
	var lab := _label(source, "letter")
	if lab != "":
		return lab
	return String(LegionCfg.ROAD_LETTER.get(source.trim_prefix("gate:"), "?"))
