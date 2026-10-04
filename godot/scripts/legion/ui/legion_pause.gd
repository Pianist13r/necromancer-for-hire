class_name LegionPause
extends Control
##
## Пауза боя нового режима: Продолжить / Заново / Настройки / Как играть / Меню.
## Паттерн — `scripts/ui/pause_screen.gd`, без общей шпаргалки клавиш (у режима свои).
##

signal resume_pressed
signal restart_pressed
signal settings_pressed
signal howto_pressed
signal menu_pressed
## Пакет tutorial: «Пропустить обучение» (docs/legion/TUTORIAL_SPEC.md).
signal skip_tutorial_pressed
## D-0927-162: «сохранения сидов в коллекцию… лучше во время [боя], чтобы можно было переиграть,
## если ты проигрываешь или тебе надо бежать» (Игорь) — главное место сохранения.
signal collect_pressed

## Выставляется вызывающим (legion_main.gd) ДО add_child — читается в _ready(), поэтому кнопка
## либо есть с первого кадра, либо её нет вовсе (не плодим show/hide после построения экрана).
var show_skip_tutorial := false
## D-0927-96 («Вызов дня» — одна попытка в день): «Заново» посреди объекта своей попытки не
## предлагаем — переиграть объект без последствий было бы обходом лимита (Котёл ещё цел, но
## получить тот же объект заново «почестному» нельзя, раз выйти из боя уже значит сдаться).
var hide_restart := false
## "" — «Меню» уходит сразу (как раньше); непустая строка — сперва показываем предупреждение с
## этим текстом и кнопку подтверждения, «Меню» саму по себе не эмитит, пока не подтвердили
## (D-0927-96: выход посреди объекта «Вызова дня» без подтверждения молча сжигал бы попытку).
var confirm_menu_text := ""
## D-0927-162: показывает «В коллекцию» — только пока карта объекта СГЕНЕРИРОВАНА (не карта
## кампании), ставится вызывающим ДО add_child.
var show_collect := false
## B-113: чьи CanvasLayer (боевой HUD — слой 5, плашки уроков/подсказки поля, панель навыков —
## слой 6) спрятать, пока открыта пауза. Сама пауза — Control на слое 0 под LegionMain: без этого
## плашка подсказки карты и нижние панели ложились ПОВЕРХ «Пауза»/«Продолжить» (кадр координатора
## pause_collect.png). Ставится вызывающим ДО add_child; вернуть — restore_covered().
var cover: Node = null

var _hidden_layers: Array[CanvasLayer] = []
var _box: VBoxContainer = null
var _confirm_box: Control = null


## B-068: числа берутся из LegionCfg (как в «Как играть»), а не пишутся словами — поменяешь
## W_RAISE_MAX / E_PRESS_HOLD_MULT, шпаргалка не устареет.
static func cheatsheet() -> Array[String]:
	return [
		"ЛКМ — чертить договор · ПКМ по участку: оттянуть, отпустить в золото — натиск",
		# рогатка — главная строка выше; Пробел/колесо и щелчок — второстепенные приёмы, в этом
		# порядке (Игорь 26.09: зажатое колесо — то же самое, что Пробел)
		"Пробел или колесо (зажать) — стрелка для таяния · щелчок ПКМ — натиск по стрелке",
		# slow/intuit: правило для игрока одно — золотой щёлкни; пружина сама говорит свой множитель
		"Золотой участок (враг в зоне) — щелчок ПКМ: «Точно!» · «пружина ×N» — сорви, ударит сильнее",
		"Круг ЛКМ — «Оцепление»: ПКМ по кольцу срывает его целиком (Пробел снаружи — наружу)",
		# slow/tab-erase (Игорь 29.09): стереть кусок линии, бойцы — в натиск
		"Таб над линией — стереть кусок под курсором: его бойцы в натиск, мана не вернётся",
		"Восьмёрка — бьют чаще · треугольник — «Обряд»: набери полстроя и сорви · квадрат — «Каре»",
		# clarity (26.09): по строке на навык — что делает (v20, D-0926-39: у каждого своя работа);
		# как целиться — общей строкой
		"Ку (Q) — молния по цепи врагов: оглушает, срывает Юриста и печать",
		"Дубль-вэ (W) — до %d свежих трупов врага воюют за вас" % LegionCfg.W_RAISE_MAX,
		"Е (E) — «Аврал»: свои быстрее и сильнее, строй держит напор ×%s"
		% LegionAbilityAim.num(LegionCfg.E_PRESS_HOLD_MULT),
		"Q W E: зажать — видно, кого заденет, отпустить — каст · R — сбор к курсору · F — волна",
		"Прокрутка колеса или 1/2/3 — вид договора · Esc / П — пауза",
		"Предметы — из элитных (в короне), на кампанию или забег; наведите на иконку",
	]


func _ready() -> void:
	UiStyle.fill_rect(self)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	if cover != null:
		for c in cover.find_children("*", "CanvasLayer", true, false):
			var layer := c as CanvasLayer
			if layer.visible:
				layer.visible = false
				_hidden_layers.append(layer)

	var backdrop := ColorRect.new()
	backdrop.color = Color(0.0, 0.0, 0.0, 0.72)
	UiStyle.fill_rect(backdrop)
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(backdrop)

	var box := UiStyle.card_box(self, 460.0, 12)
	box.alignment = BoxContainer.ALIGNMENT_CENTER

	var title := UiStyle.label("Пауза", 40, UiStyle.FONT_TITLE)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)

	_box = box
	box.add_child(_make_button("Продолжить", func() -> void: resume_pressed.emit()))
	if not hide_restart:
		box.add_child(_make_button("Заново", func() -> void: restart_pressed.emit()))
	box.add_child(_make_button("Настройки", func() -> void: settings_pressed.emit()))
	box.add_child(_make_button("Как играть", func() -> void: howto_pressed.emit()))
	if show_skip_tutorial:
		box.add_child(_make_button("Пропустить обучение", func() -> void: skip_tutorial_pressed.emit()))
	if show_collect:
		# тост «Карта сохранена» прячется вместе с HUD (cover) — отклик на самой кнопке
		var collect_btn := _make_button("В коллекцию", func() -> void: collect_pressed.emit())
		collect_btn.pressed.connect(func() -> void:
			collect_btn.text = "Сохранено в коллекцию"
			collect_btn.disabled = true)
		box.add_child(collect_btn)
	box.add_child(_make_button("Меню", _on_menu_pressed))

	var sep := UiStyle.label("Напоминание", 17, UiStyle.FONT_TEXT, UiStyle.TEXT_DIM)
	sep.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(sep)

	var sheet := VBoxContainer.new()
	sheet.alignment = BoxContainer.ALIGNMENT_CENTER
	sheet.add_theme_constant_override("separation", 2)
	box.add_child(sheet)
	for line in cheatsheet():
		var l := UiStyle.label(line, 15, UiStyle.FONT_TEXT, UiStyle.TEXT_DIM)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		sheet.add_child(l)


## Вернуть то, что спрятал cover, — СИНХРОННО из LegionMain._hide_pause(), а не в _exit_tree:
## go_to_menu() снимает паузу и сразу за ней прячет HUD — отложенное восстановление вернуло бы
## HUD поверх меню. Вернуть только спрятанное нами (что было скрыто и до паузы — не трогаем).
func restore_covered() -> void:
	for layer in _hidden_layers:
		if is_instance_valid(layer):
			layer.visible = true
	_hidden_layers.clear()


## «Меню» без подтверждения (confirm_menu_text == "") эмитит сразу, как раньше. С текстом —
## первый клик показывает предупреждение и две кнопки («Да, уйти» / «Отмена») ВМЕСТО того, чтобы
## тихо сжечь попытку «Вызова дня»; второй клик по самой кнопке «Меню» ничего не плодит повторно
## (_confirm_box уже показан).
func _on_menu_pressed() -> void:
	if confirm_menu_text == "":
		menu_pressed.emit()
		return
	if _confirm_box != null:
		return
	_confirm_box = VBoxContainer.new()
	_confirm_box.alignment = BoxContainer.ALIGNMENT_CENTER
	_confirm_box.add_theme_constant_override("separation", 8)
	var warn := UiStyle.label(confirm_menu_text, 16, UiStyle.FONT_TEXT, UiStyle.WARN)
	warn.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	warn.autowrap_mode = TextServer.AUTOWRAP_WORD
	warn.custom_minimum_size = Vector2(380.0, 0.0)
	_confirm_box.add_child(warn)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 10)
	_confirm_box.add_child(row)
	row.add_child(_make_button("Да, уйти", func() -> void: menu_pressed.emit()))
	row.add_child(_make_button("Отмена", func() -> void:
		_confirm_box.queue_free()
		_confirm_box = null))
	_box.add_child(_confirm_box)


func _make_button(text: String, on_pressed: Callable) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.custom_minimum_size = Vector2(220.0, 44.0)
	btn.add_theme_font_override("font", UiStyle.FONT_TITLE)
	btn.add_theme_font_size_override("font_size", 22)
	btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	UiStyle.style_button(btn)
	btn.pressed.connect(on_pressed)
	return btn
