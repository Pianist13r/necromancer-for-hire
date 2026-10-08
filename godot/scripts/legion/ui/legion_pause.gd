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
signal dossier_pressed
## Пакет tutorial: «Пропустить обучение» (docs/legion/TUTORIAL_SPEC.md).
signal skip_tutorial_pressed
## D-0927-162: «сохранения сидов в коллекцию… лучше во время [боя], чтобы можно было переиграть,
## если ты проигрываешь или тебе надо бежать» (Игорь) — главное место сохранения.
signal collect_pressed

## Выставляется вызывающим (legion_main.gd) ДО add_child — читается в _ready(), поэтому кнопка
## либо есть с первого кадра, либо её нет вовсе (не плодим show/hide после построения экрана).
var show_dossier := false
var show_skip_tutorial := false
## D-0927-96 («Вызов дня» — одна попытка в день): «Заново» посреди объекта своей попытки не
## предлагаем — переиграть объект без последствий было бы обходом лимита (Котёл ещё цел, но
## получить тот же объект заново «почестному» нельзя, раз выйти из боя уже значит сдаться).
var hide_restart := false
## Для дня вызывающий заменяет текст предупреждением о засчитанной попытке.
var confirm_menu_text := "Бой будет прерван. Награды прошлых боёв сохранены."
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


## B-068: числа берутся из LegionCfg (как в «Как играть»), а не пишутся словами — поменяешь
## W_RAISE_MAX / E_PRESS_HOLD_MULT, шпаргалка не устареет.
static func cheatsheet() -> Array[String]:
	var rows: Array[String] = [
		"ЛКМ — чертить договор · ПКМ по участку: оттянуть, отпустить в золото — натиск",
		# рогатка — главная строка выше; Пробел/колесо и щелчок — второстепенные приёмы, в этом
		# порядке (Игорь 26.09: зажатое колесо — то же самое, что Пробел)
		"{key:aim_contract} или колесо (зажать) — стрелка для таяния · щелчок ПКМ — натиск по стрелке",
		# slow/intuit: правило для игрока одно — золотой щёлкни; пружина сама говорит свой множитель
		"Золотой участок (враг в зоне) — щелчок ПКМ: «Точно!» · «пружина ×N» — сорвите, ударит сильнее",
		"Круг ЛКМ — «Оцепление»: ПКМ по кольцу срывает его целиком ({key:aim_contract} снаружи — наружу)",
		# slow/tab-erase (Игорь 29.09): стереть кусок линии, бойцы — в натиск
		"{key:erase_piece} над линией — стереть кусок под курсором: его бойцы в натиск, мана не вернётся",
		"Восьмёрка — бьют чаще · квадрат — «Каре»",
		"Треугольник — «Обряд»: {charge:triangle}, заряд {cfg:charge} с, ПКМ — срыв",
		# clarity (26.09): по строке на навык — что делает (v20, D-0926-39: у каждого своя работа);
		# как целиться — общей строкой
		"{key+:cast_q} — молния по цепи врагов: оглушает, срывает Юриста и печать",
		"{key+:cast_w} — до %d свежих трупов врага воюют за вас" % LegionCfg.W_RAISE_MAX,
		"{key+:cast_e} — «Аврал»: свои быстрее и сильнее, строй держит напор ×%s"
		% LegionAbilityAim.num(LegionCfg.E_PRESS_HOLD_MULT),
		"Q W E: зажать — видно, кого заденет, отпустить — каст · R — сбор к курсору · F — волна",
		"Прокрутка колеса или {keys:runes} — вид договора · Esc / {key:pause} — пауза",
		"Предметы — из элитных (в короне), на кампанию или забег; наведите на иконку",
		"{key:kassa} — Касса · {key:mute} — включить / выключить звук",
	]
	for i in rows.size():
		rows[i] = Controls.text(preload("res://scripts/legion/legion_teaching_text.gd").render(rows[i]))
	return rows


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

	var shell := ProgressionUi.shell(self, "Пауза", "Бой приостановлен")
	var box: VBoxContainer = shell["body"]
	_box = box
	box.add_child(_make_button("Настройки", func() -> void: settings_pressed.emit()))
	box.add_child(_make_button("Как играть", func() -> void: howto_pressed.emit()))
	box.add_child(_make_button("Клавиши", _show_keys))
	if show_dossier:
		# D-1007-P2: одно «Досье» (поправки и артефакты) — тот же экран, что из меню.
		box.add_child(_make_button("Досье", func() -> void: dossier_pressed.emit()))
	if not hide_restart:
		box.add_child(_make_button("Заново", func() -> void:
			LegionUi.confirm(self, "Бой будет начат заново. Награды прошлых боёв сохранены.",
				func() -> void: restart_pressed.emit())))
	if show_skip_tutorial:
		box.add_child(_make_button("Пропустить обучение", func() -> void: skip_tutorial_pressed.emit()))
	if show_collect:
		var collect_btn := _make_button("В коллекцию", func() -> void: collect_pressed.emit())
		collect_btn.pressed.connect(func() -> void:
			collect_btn.text = "Сохранено в коллекцию"
			collect_btn.disabled = true)
		box.add_child(collect_btn)
	var nav := LegionUi.nav_bar(self, "В главное меню", _on_menu_pressed,
		"Продолжить", func() -> void: resume_pressed.emit())
	# Esc остаётся дублем продолжения, а не подтверждением выхода.
	(nav.get_node("NavBack") as Button).shortcut = null
	(nav.get_node("NavPrimary") as Button).grab_focus.call_deferred()



func _show_keys() -> void:
	var dialog := AcceptDialog.new()
	dialog.name = "ControlsCheatsheet"
	dialog.dialog_text = "\n".join(cheatsheet())
	dialog.dialog_autowrap = true
	dialog.ok_button_text = "Вернуться к паузе"
	dialog.min_size = Vector2i(900, 480)
	UiStyle.style_dialog(dialog, "Клавиши и приёмы")
	dialog.confirmed.connect(dialog.queue_free)
	dialog.canceled.connect(dialog.queue_free)
	add_child(dialog)
	dialog.popup_centered()


## Вернуть то, что спрятал cover, — СИНХРОННО из LegionMain._hide_pause(), а не в _exit_tree:
## go_to_menu() снимает паузу и сразу за ней прячет HUD — отложенное восстановление вернуло бы
## HUD поверх меню. Вернуть только спрятанное нами (что было скрыто и до паузы — не трогаем).
func restore_covered() -> void:
	for layer in _hidden_layers:
		if is_instance_valid(layer):
			layer.visible = true
	_hidden_layers.clear()


## Любой прерванный бой требует явного подтверждения.
func _on_menu_pressed() -> void:
	LegionUi.confirm(self, confirm_menu_text, func() -> void: menu_pressed.emit())



func _make_button(text: String, on_pressed: Callable) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.custom_minimum_size = Vector2(220.0, 44.0)
	btn.add_theme_font_override("font", UiStyle.FONT_TITLE)
	btn.add_theme_font_size_override("font_size", 22)
	btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	UiStyle.style_button(btn)
	btn.pressed.connect(func() -> void:
		btn.grab_focus()
		on_pressed.call())
	return btn
