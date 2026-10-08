class_name PlotMenu
extends CanvasLayer
##
## Меню площадки (пакет staff, DESIGN_V15 §5, §12 п.5): короткий клик (ContractField.tap) по
## площадке или постройке (LegionStaff.plot_at) открывает всплывающую карточку у точки —
## построить (открытые виды, цена; серое при нехватке душ) / улучшить / продать. Бой идёт.
##
## Закрытие: кнопка-действие, Esc, клик мимо. Клик мимо ловит ContractField.press_consumer:
## меню закрывается сразу на нажатии, но нажатие НЕ съедается — если это протяжка, она идёт в
## рисование (§12 п.5), а если короткий клик — следующий tap проглатывается здесь, и закрывающий
## клик ничего больше не делает. Кнопки — только мышью (фокус выключен, клавиши у рун свои).
##

const W := 250.0
const MARGIN := 8.0
const FONT := 16
const TITLE_FONT := 17
const NOTE_FONT := 13
## Отступ пояснения ≈ ширина значка души у кнопки: текст встаёт под названием, а не под значком.
const NOTE_INDENT := 34.0
## Пояснение под кнопкой срочного найма: за что платим и чем это лучше ожидания.
const RUSH_NOTE := "павшие возвращаются сейчас\n%d душ за бойца"

var world: LegionWorld = null
## Открытый участок ({} — меню закрыто).
var plot: Dictionary = {}

var _panel: PanelContainer = null
var _box: VBoxContainer = null
var _anchor := Vector2.ZERO
var _swallow_tap := false
var _field: ContractField = null
var _wait_note: Label = null


func setup(w: LegionWorld) -> void:
	world = w
	layer = 6
	process_mode = Node.PROCESS_MODE_ALWAYS
	_panel = PanelContainer.new()
	# v17: бланк LegionUi, рамка золотом — это «ведомость участка», не боевой HUD
	_panel.add_theme_stylebox_override("panel",
		LegionUi.blank_style(LegionUi.GOLD, LegionUi.PAPER_HI, 12.0, 10.0))
	_panel.custom_minimum_size = Vector2(W, 0.0)
	_panel.visible = false
	add_child(_panel)
	_box = VBoxContainer.new()
	_box.add_theme_constant_override("separation", 6)
	_panel.add_child(_box)
	_bind_field()
	# сеть: поле человека за этим экраном известно только на старте матча (local_side)
	world.match_started.connect(func(_id: String) -> void: _bind_field())
	# души меняются в бою постоянно (каждое убийство) — только перекрасить доступность кнопок;
	# пересобирать меню нельзя: нажатая, но ещё не отпущенная кнопка удалялась, и клик по
	# «Бытовке» пропадал (приёмка обучения 25.09.2026: button_down есть, pressed — нет)
	world.souls_changed.connect(func(_v: int) -> void: _update_states())
	world.building_changed.connect(func(_b: Object) -> void: _refresh())


## Меню слушает щелчки поля человека за этим экраном (вне сети — поле стороны 0, как было).
func _bind_field() -> void:
	var mine := world.my_field()
	if _field == mine:
		return
	if _field != null and is_instance_valid(_field):
		if _field.tap.is_connected(_on_tap):
			_field.tap.disconnect(_on_tap)
		_field.press_consumer = Callable()
	_field = mine
	_field.tap.connect(_on_tap)
	_field.press_consumer = _consume_press


## Действие кнопки: вне сети — сразу штатом стороны (как было), в сети — командой PLOT.
func _act(target: Dictionary, action: String, kind: StringName, direct: Callable) -> void:
	if world.net_mode:
		world.local_cmd(PvpCmd.plot(String(target["id"]), action, kind))
	else:
		direct.call()


func is_open() -> bool:
	return not plot.is_empty()


## Открыть меню участка у точки МИРА at (tap или бот/тест); карточка — на экране у неё
## (вид поля мира, P5a: в «Схватке» ×0,8).
func open(p: Dictionary, at: Vector2) -> void:
	plot = p
	_anchor = world.world_to_hud(at)
	_rebuild()
	_panel.visible = true


func close() -> void:
	plot = {}
	if _panel != null:
		_panel.visible = false


## Кнопки открытого меню (для тестов и обучения).
func buttons() -> Array[Button]:
	var out: Array[Button] = []
	for c in _box.get_children():
		if c is Button:
			out.append(c)
	return out


func _on_tap(pos: Vector2) -> void:
	if _swallow_tap:
		_swallow_tap = false
		return
	if world.phase != LegionWorld.Phase.BATTLE:
		return
	# радиус выбора — экранный, как в одиночке: в «Схватке» (вид ×0,8) не ужимается (P5a)
	var p := world.my_side().staff.plot_at(pos, LegionCfg.PLOT_PICK_R / world.view_scale())
	if not p.is_empty():
		open(p, pos)


## ContractField.press_consumer: нажатие мимо открытого меню закрывает его. false — нажатие
## не съедено (протяжка рисует), а короткий клик станет tap, который мы проглотим.
func _consume_press(_at: Vector2) -> bool:
	_swallow_tap = is_open()
	if is_open():
		close()
	return false


func _input(event: InputEvent) -> void:
	if is_open() and event.is_action_pressed(&"pause"):
		close()
		get_viewport().set_input_as_handled()


func _refresh() -> void:
	if not is_open():
		return
	# участок продали/перестроили из другого места — показываем актуальное
	_rebuild()


func _rebuild() -> void:
	_wait_note = null
	for c in _box.get_children():
		_box.remove_child(c)
		c.queue_free()
	var me := world.my_side()   # площадки и души — человека за этим экраном
	var st := me.staff
	# лямбды кнопок держат СВОЮ ссылку: close() до действия обнуляет поле plot
	var target := plot
	var b: LegionBuilding = target["building"]
	if st.plot_near_road(target):
		_note(road_note(st.plot_safe_share(target)))
	if b == null:
		_title("Площадка — построить")
		for kind: StringName in LegionCfg.KIND_ORDER:
			if not st.kind_unlocked(kind):
				continue
			var data: Dictionary = LegionCfg.BUILDINGS[kind]
			var price := LegionStaff.build_price(kind)
			var k := kind
			# B-094: штат — с бонусами «Конторы» и поправок (staff_cap), как получит постройка:
			# меню писало «штат 8», а построенная Бытовка получала 11
			var cap := st.staff_cap(kind, LegionStaff.paced(int(data["cap"][0])))
			_button("%s · штат %d — %d душ" % [data["name"], cap, price],
				func() -> bool: return not st.can_build(target, k),
				func() -> void: _act(target, PvpCmd.BUILD, k, func() -> void: st.build(target, k)),
				func() -> bool: return me.souls < price)
			_note(String(data.get("hint", "")))
	else:
		var data: Dictionary = LegionCfg.BUILDINGS[b.kind]
		_title("%s, ур. %d · штат %d/%d" % [data["name"], b.level, b.alive_count(), b.cap])
		_note(String(data.get("hint", "")))
		var up := LegionStaff.upgrade_price(b)
		if up < 0:
			_button("Уровень максимальный", func() -> bool: return true, Callable())
		else:
			_button("Улучшить до ур. %d — %d душ" % [b.level + 1, up],
				func() -> bool: return not st.can_upgrade(b),
				func() -> void: _act(target, PvpCmd.UPGRADE, &"", func() -> void: st.upgrade(b)),
				func() -> bool: return me.souls < up)
			var cap := st.staff_cap(b.kind, LegionStaff.paced(int(data["cap"][b.level])))
			_note("Штат постройки: +%d\nВозрождение: %.0f → %.0f с" % [
				cap - b.cap, b.respawn_t, st.staff_respawn(b.kind, float(data["respawn"][b.level]))])
		# срочный найм (D-0927-135): текст и доступность перечитываются каждый кадр — павшие
		# и души меняются, пока меню открыто
		var rush_text := func() -> String:
			var price := st.rush_price(b)
			if price <= 0:
				return "Срочный найм — все на местах"
			return "Срочный найм · %d — %d душ" % [price / LegionStaff.rush_each(b), price]
		_button(String(rush_text.call()),
			func() -> bool: return st.rush_price(b) <= 0 or me.souls < st.rush_price(b),
			func() -> void: _act(target, PvpCmd.RUSH, &"", func() -> void: st.rush(b)),
			func() -> bool: return st.rush_price(b) > 0 and me.souls < st.rush_price(b),
			rush_text)
		_note(RUSH_NOTE % LegionStaff.rush_each(b))
		_wait_note = LegionUi.label(_waiting_text(b), NOTE_FONT, LegionUi.FONT_TEXT, LegionUi.TEXT_DIM)
		_wait_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_wait_note.custom_minimum_size.x = W - NOTE_INDENT
		_box.add_child(_wait_note)
		_button("Продать — +%d душ" % LegionStaff.sell_value(b), func() -> bool: return false,
			func() -> void: _act(target, PvpCmd.SELL, &"", func() -> void: st.sell(b)))
	_panel.reset_size()
	var size := _panel.get_combined_minimum_size()
	var at := _anchor + Vector2(MARGIN * 2.0, -size.y * 0.5)
	if at.x + size.x > LegionCfg.WORLD_SIZE.x - MARGIN:
		at.x = _anchor.x - size.x - MARGIN * 2.0
	at.y = clampf(at.y, MARGIN, LegionCfg.WORLD_SIZE.y - size.y - MARGIN)
	_panel.position = at


func _title(text: String) -> void:
	var l := LegionUi.label(text, TITLE_FONT, LegionUi.FONT_TITLE, LegionUi.GOLD)
	_box.add_child(l)
	var rule := ColorRect.new()
	rule.custom_minimum_size = Vector2(0.0, 1.0)
	rule.color = LegionUi.INK_FAINT
	rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_box.add_child(rule)


## B-043: предупреждение «у дороги» называет долю рождений под удар (с шагом 10 %, «около»):
## игрок видит, насколько площадка плоха, а не только что она «у дороги».
static func road_note(safe_share: float) -> String:
	var hit := roundi((1.0 - safe_share) * 10.0) * 10
	if hit >= 100:
		return "У дороги: почти все бойцы рождаются под удар. Прикройте выход строем."
	return "У дороги: около %d %% бойцов рождаются под удар. Прикройте выход строем." % hit


## Пояснение под пунктом: мелко, тусклыми чернилами, с переносом по ширине карточки — читается
## вторым взглядом и не спорит с кнопкой. Пустой текст — ничего не добавляем.
func _note(text: String) -> void:
	if text.is_empty():
		return
	var l := LegionUi.label(text, NOTE_FONT, LegionUi.FONT_TEXT, LegionUi.TEXT_DIM)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(W - NOTE_INDENT, 0.0)
	# отступ слева — строка читается как подпись к кнопке над ней, а не как отдельный пункт
	var row := MarginContainer.new()
	row.add_theme_constant_override("margin_left", int(NOTE_INDENT))
	row.add_theme_constant_override("margin_top", -4)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(l)
	_box.add_child(row)


## disabled_fn() -> bool — закрыта ли кнопка сейчас (перечитывается при смене душ,
## _update_states). short_fn() -> bool — закрыта именно нехваткой душ: нажатие по ней
## озвучивается (world.souls_short), остальные закрытые кнопки молчат.
func _button(text: String, disabled_fn: Callable, action: Callable,
		short_fn: Callable = Callable(), text_fn: Callable = Callable()) -> void:
	var btn := Button.new()
	btn.text = text
	btn.disabled = bool(disabled_fn.call())
	btn.set_meta(&"disabled_fn", disabled_fn)
	if text_fn.is_valid():
		btn.set_meta(&"text_fn", text_fn)
	btn.focus_mode = Control.FOCUS_NONE
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	LegionUi.style_button(btn, LegionUi.INK, FONT)
	# цена в душах — значок души у строки: валюту видно, не читая
	if short_fn.is_valid() or text.contains("душ"):
		btn.icon = LegionIcons.tex("soul")
		btn.expand_icon = true
		btn.add_theme_constant_override("icon_max_width", 26)
	if short_fn.is_valid():
		# закрытая кнопка pressed не шлёт, но gui_input получает — ловим сам клик
		btn.gui_input.connect(func(ev: InputEvent) -> void:
			var mb := ev as InputEventMouseButton
			if mb == null or not mb.pressed or mb.button_index != MOUSE_BUTTON_LEFT:
				return
			if btn.disabled and bool(short_fn.call()):
				world.souls_short.emit())
	if action.is_valid():
		# сначала закрыть: действие шлёт building_changed, и пересборка удалила бы эту же
		# кнопку посреди её собственного сигнала
		btn.pressed.connect(func() -> void:
			close()
			action.call())
	_box.add_child(btn)


## Души изменились — перечитать доступность кнопок, не пересобирая меню (см. setup()).
func _update_states() -> void:
	if not is_open():
		return
	for btn in buttons():
		if btn.has_meta(&"disabled_fn"):
			btn.disabled = bool((btn.get_meta(&"disabled_fn") as Callable).call())
		if btn.has_meta(&"text_fn"):
			btn.text = String((btn.get_meta(&"text_fn") as Callable).call())


## Павшие гибнут и без смены душ — кнопку найма перечитываем каждый кадр, пока меню открыто
## (кнопок ≤ 5, это дёшево).
func _process(_dt: float) -> void:
	_update_states()
	if is_open() and is_instance_valid(_wait_note) and plot["building"] != null:
		_wait_note.text = _waiting_text(plot["building"])


func _waiting_text(b: LegionBuilding) -> String:
	var wait := b.next_respawn()
	if is_inf(wait):
		return "Найм возвращает павших, но не увеличивает штат."
	if world.army_alive(b.side) >= LegionCfg.ARMY_HARD_CAP:
		return "Лимит армии: пополнение ждёт свободного места."
	return "Бесплатно через %d с — ближайший боец. Найм не увеличивает штат." % ceili(wait)
