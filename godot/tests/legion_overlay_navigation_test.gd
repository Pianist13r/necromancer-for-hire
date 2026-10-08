extends SceneTree
##
## Регрессия навигации модальных экранов (interface-safety, 03.10.2026) — без сети и живых
## данных. Ввод синтетический, но путь НАСТОЯЩИЙ: Input.parse_input_event гоняет событие по
## всей цепочке (окно → _input → GUI → _unhandled_key_input → _unhandled_input), как от ОС;
## «мир» снизу — probe-узел с _unhandled_input, как LegionWorld. Настройки пишут в песочный
## user://legion_overlay_navigation_test.cfg, файлы владельца не трогаются.
##
##   export APPDATA=<песочница> NECRO_NO_DEV_BRIDGE=1
##   "$GODOT" --headless --path godot --fixed-fps 60 \
##       --script res://tests/legion_overlay_navigation_test.gd -- --mute
##
## 1) Настройки: P/F/Q под экраном не доходят до «мира»; Esc закрывает ровно раз и гасится до
##    probe «pause»; echo Esc не закрывает повторно; Enter переключает галочку, Tab переводит
##    фокус (GUI не заглушено); начальный фокус внутри экрана, после закрытия возвращается
##    прежнему владельцу; секции Звук/Изображение/Управление; карточка и «Готово» целиком в
##    вьюпорте 1280×720 и 960×540, «Готово» вне прокрутки; сброс на месте при allow_reset.
## 2) Как играть: «Понятно» вне прокрутки, строки не вылезают за 960×540, Esc/фокус/буфер
##    клавиш — как у настроек.
## 3) Лобби сети: P в поле имени не закрывает лобби (регрессия: «pause» = Esc+P, _input раньше
##    GUI), Esc — «Назад» ровно раз, echo не дублирует. Сессия — живой NetSession без
##    соединения: сеть не открывается.
## 4) Выбор поля «Схватки»: P не «Назад», Esc — «Назад» ровно раз.
## Итог «LEGION OVERLAY NAV: N/M OK», код выхода 1 при провале.
##

const SAVE := "user://legion_overlay_navigation_test.cfg"

var _checks := 0
var _fails := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_fails += 1
		print("FAIL ", what)


func _run() -> void:
	# Песочница: галочки «Настроек» пишут конфиг через Settings.set_* — уводим в свой файл.
	Settings.path = SAVE
	Settings._cfg = null
	# Проверяем логическую геометрию: физический resize при canvas_items оставляет базу 1280.
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED
	root.content_scale_size = Vector2i.ZERO
	root.size = Vector2i(1280, 720)
	await _settle()
	await _case_settings(false)
	await _case_settings(true)
	root.size = Vector2i(960, 540)
	await _settle()
	await _case_settings_fit()
	await _case_howto()
	root.size = Vector2i(1280, 720)
	await _settle()
	await _case_lobby()
	await _case_field_select()
	print("LEGION OVERLAY NAV: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


## «Мир» под оверлеем: слушает _unhandled_input, как LegionWorld. Считает и «pause» (в карте
## ввода это Esc И латинская P), и вообще все клавиши — модальный экран не должен делиться
## с миром ни тем, ни другим.
class _Probe:
	extends Node
	var pauses := 0
	var keys := 0

	func _unhandled_input(event: InputEvent) -> void:
		if event.is_action_pressed(&"pause"):
			pauses += 1
		var k := event as InputEventKey
		if k != null and k.pressed:
			keys += 1


func _settle() -> void:
	# Два кадра: вход в дерево, отложенные grab_focus и контейнерный layout успевают.
	await process_frame
	await process_frame


## Нажатие и отпускание настоящим путём. keycode и physical — оба: событие должно совпасть и с
## действиями по physical («pause»: P), и с ui_cancel по keycode (Esc).
func _press(code: Key, shift := false) -> void:
	var k := InputEventKey.new()
	k.keycode = code
	k.physical_keycode = code
	k.pressed = true
	k.shift_pressed = shift
	if code >= KEY_A and code <= KEY_Z:
		k.unicode = code + 32
	Input.parse_input_event(k)
	await process_frame
	var r := k.duplicate() as InputEventKey
	r.pressed = false
	Input.parse_input_event(r)
	await process_frame


## Автоповтор зажатой клавиши: обработчики экранов обязаны его игнорировать (echo), иначе одно
## удержание Esc закрывало бы и экран, и то, что открылось следом.
func _echo_press(code: Key) -> void:
	var k := InputEventKey.new()
	k.keycode = code
	k.physical_keycode = code
	k.pressed = true
	k.echo = true
	Input.parse_input_event(k)
	await process_frame


func _has_label(where: Node, text: String) -> bool:
	for l in where.find_children("*", "Label", true, false):
		if (l as Label).text == text:
			return true
	return false


func _case_settings(with_reset: bool) -> void:
	var probe := _Probe.new()
	root.add_child(probe)
	var below := Button.new()
	below.text = "Владелец фокуса"
	root.add_child(below)
	below.grab_focus()
	await _settle()
	var s := SettingsScreen.new()
	s.process_mode = Node.PROCESS_MODE_ALWAYS   # как LegionMain._show_settings: живёт в паузе
	s.allow_reset = with_reset
	root.add_child(s)
	# Лямбды GDScript захватывают переменные по значению — счётчики через массив.
	var closes: Array[int] = [0]
	var resets: Array[int] = [0]
	s.closed.connect(func() -> void: closes[0] += 1)
	s.reset_confirmed.connect(func() -> void: resets[0] += 1)
	await _settle()

	var first := root.gui_get_focus_owner()
	_check(first != null and s.is_ancestor_of(first), "настройки: начальный клавиатурный фокус")
	for section_name in ["Звук", "Изображение", "Управление"]:
		_check(_has_label(s, section_name), "настройки: секция «%s»" % section_name)
	_check(s.find_children("*", "CheckBox", true, false).size() == 10,
		"настройки: десять галочек, включая тряску, вспышки и атмосферу мира")
	_check(s.find_children("*", "HSlider", true, false).size() == 4,
		"настройки: четыре громкости")
	_check((s.find_child("ResetAsk", true, false) != null) == with_reset,
		"настройки: сброс прогресса %s" % ["показан" if with_reset else "скрыт"])
	var scroll := s.find_child("SettingsScroll", true, false) as ScrollContainer
	var done := s.find_child("SettingsClose", true, false) as Button
	_check(scroll != null and done != null and not scroll.is_ancestor_of(done),
		"настройки: «Готово» вне прокрутки")
	var vp := Rect2(Vector2.ZERO, Vector2(root.size))
	var card := s.find_child("SettingsCard", true, false) as PanelContainer
	_check(card != null and vp.encloses(card.get_global_rect()),
		"настройки: карточка целиком в 1280×720")
	_check(done != null and vp.encloses(done.get_global_rect()),
		"настройки: «Готово» целиком в 1280×720")
	root.size = Vector2i(960, 540)
	await _settle()
	_check(card != null and Rect2(Vector2.ZERO, Vector2(root.size)).encloses(card.get_global_rect()),
		"открытая карточка переживает изменение размера окна")
	root.size = Vector2i(1280, 720)
	await _settle()

	# Боевые клавиши под модальным экраном — не в мир: P входит в «pause» (старый код пускал
	# её до LegionWorld._unhandled_input и снимал паузу боя), F — вызов волны, Q — Ку.
	await _press(KEY_P)
	await _press(KEY_F)
	await _press(KEY_Q)
	_check(probe.pauses == 0 and probe.keys == 0, "настройки: P/F/Q не доходят до мира")
	_check(closes[0] == 0, "настройки: P не закрывает экран")

	# GUI не заглушено: Enter щёлкает сфокусированную галочку, Tab переводит фокус.
	if first is CheckBox:
		var was := (first as CheckBox).button_pressed
		await _press(KEY_ENTER)
		_check((first as CheckBox).button_pressed != was, "настройки: Enter переключает галочку")
	await _press(KEY_TAB)
	var next := root.gui_get_focus_owner()
	_check(next != null and next != first and s.is_ancestor_of(next),
		"настройки: Tab переводит фокус внутри экрана")
	var stayed_inside := true
	for i in 32:
		await _press(KEY_TAB, i >= 16)
		var focused := root.gui_get_focus_owner()
		stayed_inside = stayed_inside and focused != null and s.is_ancestor_of(focused)
	_check(stayed_inside, "полный круг Tab/Shift+Tab не уходит на нижние кнопки")

	await _press(KEY_ESCAPE)
	_check(closes[0] == 1, "настройки: Esc закрывает ровно раз")
	_check(probe.pauses == 0, "настройки: Esc гасится до «pause» мира")
	await _echo_press(KEY_ESCAPE)
	_check(closes[0] == 1 and probe.pauses == 0, "настройки: echo Esc не закрывает повторно")
	_check(resets[0] == 0, "настройки: сброс сам не срабатывает")
	s.queue_free()   # как LegionMain по closed
	await _settle()
	_check(root.gui_get_focus_owner() == below, "настройки: фокус вернулся прежнему владельцу")

	# Без оверлея P доходит до «мира» — probe жив, проверки выше что-то значат.
	await _press(KEY_P)
	_check(probe.pauses == 1, "probe: без оверлея P доходит до мира")
	below.free()
	probe.free()


func _case_settings_fit() -> void:
	var s := SettingsScreen.new()
	s.process_mode = Node.PROCESS_MODE_ALWAYS
	root.add_child(s)
	var closes: Array[int] = [0]
	s.closed.connect(func() -> void: closes[0] += 1)
	await _settle()
	var vp := Rect2(Vector2.ZERO, Vector2(root.size))
	var card := s.find_child("SettingsCard", true, false) as PanelContainer
	var done := s.find_child("SettingsClose", true, false) as Button
	var scroll := s.find_child("SettingsScroll", true, false) as ScrollContainer
	_check(card != null and vp.encloses(card.get_global_rect()),
		"настройки 960×540: карточка целиком в окне")
	_check(done != null and vp.encloses(done.get_global_rect()),
		"настройки 960×540: «Готово» целиком в окне")
	_check(scroll != null and vp.encloses(scroll.get_global_rect()),
		"настройки 960×540: прокрутка целиком в окне")
	if scroll != null:
		var clipped := false
		for row in scroll.find_children("*", "HSlider", true, false):
			if not vp.encloses((row as Control).get_global_rect()):
				clipped = true
		_check(not clipped, "настройки 960×540: громкости не обрезаны")
		_check((scroll.get_child(0) as Control).size.y > scroll.size.y,
			"настройки 960×540: контент реально прокручивается")
	await _press(KEY_ESCAPE)
	_check(closes[0] == 1, "настройки 960×540: Esc закрывает")
	s.queue_free()
	await _settle()


func _case_howto() -> void:
	var probe := _Probe.new()
	root.add_child(probe)
	var below := Button.new()
	root.add_child(below)
	below.grab_focus()
	await _settle()
	var h := HowtoLegion.new()
	h.process_mode = Node.PROCESS_MODE_ALWAYS   # как LegionMain._show_howto
	root.add_child(h)
	var closes: Array[int] = [0]
	h.closed.connect(func() -> void: closes[0] += 1)
	await _settle()
	var vp := Rect2(Vector2.ZERO, Vector2(root.size))   # всё ещё 960×540
	var scroll := h.find_child("HowtoScroll", true, false) as ScrollContainer
	var done := h.find_child("HowtoClose", true, false) as Button
	_check(scroll != null and done != null and not scroll.is_ancestor_of(done),
		"как играть: «Понятно» вне прокрутки")
	_check(root.gui_get_focus_owner() == done, "как играть: начальный фокус — «Понятно»")
	var panel := h.find_child("HowtoPanel", true, false) as PanelContainer
	_check(panel != null and vp.encloses(panel.get_global_rect()),
		"как играть: панель целиком в 960×540")
	var clipped := false
	if scroll != null:
		for l in scroll.find_children("*", "Label", true, false):
			var rect := (l as Control).get_global_rect()
			if rect.position.x < 0.0 or rect.end.x > vp.end.x:
				clipped = true
	_check(not clipped, "как играть: строки не обрезаются по горизонтали")
	await _press(KEY_P)
	await _press(KEY_F)
	_check(probe.pauses == 0 and probe.keys == 0, "как играть: P/F не доходят до мира")
	_check(closes[0] == 0, "как играть: P не закрывает экран")
	await _press(KEY_ESCAPE)
	_check(closes[0] == 1, "как играть: Esc закрывает ровно раз")
	_check(probe.pauses == 0, "как играть: Esc гасится до «pause» мира")
	h.queue_free()
	await _settle()
	_check(root.gui_get_focus_owner() == below, "как играть: фокус вернулся прежнему владельцу")
	below.free()
	probe.free()


func _case_lobby() -> void:
	# Живая сессия без соединения: NetSession._ready строит только подписи состояния, сеть не
	# открывается — ровно так лобби живёт в меню до «Подключиться».
	var session := NetSession.new()
	root.add_child(session)
	var lobby := NetLobby.new().setup(session)
	root.add_child(lobby)
	var backs: Array[int] = [0]
	lobby.back.connect(func() -> void: backs[0] += 1)
	await _settle()
	var edits := lobby.find_children("*", "LineEdit", true, false)
	_check(edits.size() >= 2, "лобби: поля имени и адреса построены")
	for edit: LineEdit in edits:
		if not edit.is_visible_in_tree():
			continue
		edit.clear()
		edit.grab_focus()
		await _press(KEY_P)
		_check(edit.text == "p", "лобби: P действительно введена в текстовое поле")
	# Регрессия: «pause» = Esc и P, а _input идёт раньше GUI — буква P закрывала лобби при
	# наборе адреса (https…) и имени, до LineEdit событие не доходило. Теперь P — буква.
	await _press(KEY_H)
	await _press(KEY_P)
	_check(backs[0] == 0, "лобби: P в поле не закрывает")
	_check(lobby.is_inside_tree(), "лобби: экран на месте")
	await _press(KEY_ESCAPE)
	_check(backs[0] == 1, "лобби: Esc — «Назад» ровно раз")
	await _echo_press(KEY_ESCAPE)
	_check(backs[0] == 1, "лобби: echo Esc не дублирует «Назад»")
	lobby.free()
	session.free()


func _case_field_select() -> void:
	var s := PvpFieldSelect.new()
	root.add_child(s)
	var backs: Array[int] = [0]
	var nets: Array[int] = [0]
	var chosens: Array[int] = [0]
	s.back.connect(func() -> void: backs[0] += 1)
	s.net.connect(func() -> void: nets[0] += 1)
	s.chosen.connect(func(_map_id: String) -> void: chosens[0] += 1)
	await _settle()
	_check(root.gui_get_focus_owner() is Button, "выбор поля: начальный фокус — кнопка")
	await _press(KEY_P)
	_check(backs[0] == 0 and nets[0] == 0 and chosens[0] == 0,
		"выбор поля: P не «Назад» и не выбор")
	await _press(KEY_ESCAPE)
	_check(backs[0] == 1, "выбор поля: Esc — «Назад» ровно раз")
	await _echo_press(KEY_ESCAPE)
	_check(backs[0] == 1, "выбор поля: echo Esc не дублирует")
	s.free()
