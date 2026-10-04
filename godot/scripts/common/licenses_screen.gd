class_name LicensesScreen
extends Control
##
## «Лицензии»: тексты лицензий третьих сторон внутри игры (exe раздаётся один, без папки с
## файлами). Открывается кнопкой из SettingsScreen как её ДОЧЕРНИЙ модальный оверлей: Esc
## закрывает только его и возвращает фокус кнопке «Лицензии» (settings при открытом оверлее
## молчит — см. SettingsScreen._input). Паттерн модалки — HowtoLegion/SettingsScreen: свой
## фон, глотающий мышь, карточка фиксированного прямоугольника, «Закрыть» вне прокрутки,
## замкнутый круг Tab/Shift+Tab через ModalFocus.
##
## Содержимое: свод по игре (по-русски) + тексты лицензий дословно (по-английски): Godot из
## Engine.get_license_text/get_copyright_info/get_license_info, остальное — копии файлов в
## res://assets/legal (в exe они пакуются через include_filter пресетов). Текст собирается один
## раз в _ready в один RichTextLabel (сам листается колесом и клавишами; ScrollContainer не нужен).
##

signal closed

const LEGAL_DIR := "res://assets/legal/"
const REPO_URL := "https://github.com/Pianist13r/necromancer-for-hire"

## Порядок и подписи блоков со сторонними текстами: [заголовок, пояснение, файлы].
const THIRD_PARTY: Array = [
	["Juicee (MIT)", "Аддон эффектов «сочности» (godot/addons/juicee).", ["JUICEE_LICENSE.txt"]],
	["godot-mcp (MIT)", "Мост разработчика; в игровой сборке отключён.",
		["GODOT_MCP_LICENSE.txt"]],
	["Шрифты (SIL Open Font License 1.1)", "Underdog и Neucha.",
		["OFL-Underdog.txt", "OFL-Neucha.txt"]],
	["Kenney (CC0)", "Текстуры частиц Kenney (kenney.nl). Kenney Light Masks (световые маски) "
		+ "тоже распространяются на условиях CC0 (kenney.nl).", ["KENNEY_LICENSE.txt"]],
]

var _focus_before: Control = null
var _closing := false
var _text: RichTextLabel = null


func _ready() -> void:
	UiStyle.fill_rect(self)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	var backdrop := ColorRect.new()
	backdrop.color = Color(0.0, 0.0, 0.0, 0.85)
	UiStyle.fill_rect(backdrop)
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(backdrop)

	# Фокус нижнего экрана (кнопка «Лицензии») — его и вернём при закрытии.
	_focus_before = get_viewport().gui_get_focus_owner()

	var vp := get_viewport_rect().size
	var side := clampf(vp.x * 0.1, 24.0, 140.0)
	var top := clampf(vp.y * 0.04, 12.0, 28.0)
	var panel := PanelContainer.new()
	panel.name = "LicensesPanel"
	panel.anchor_right = 1.0
	panel.anchor_bottom = 1.0
	panel.offset_left = side
	panel.offset_right = -side
	panel.offset_top = top
	panel.offset_bottom = -top
	var pst := UiStyle.panel_style(Color(0.07, 0.05, 0.11, 0.98), 16)
	pst.border_color = Color(Cfg.RUNE_COLOR, 0.7)
	pst.set_border_width_all(2)
	pst.content_margin_left = 28.0
	pst.content_margin_right = 28.0
	pst.content_margin_top = 18.0
	pst.content_margin_bottom = 20.0
	panel.add_theme_stylebox_override("panel", pst)
	add_child(panel)
	resized.connect(_fit_panel)

	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 10)
	panel.add_child(outer)

	var title := UiStyle.label("Лицензии", 34, UiStyle.FONT_TITLE)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	outer.add_child(title)

	_text = RichTextLabel.new()
	_text.name = "LicensesText"
	_text.bbcode_enabled = false
	_text.scroll_active = true
	_text.fit_content = false
	_text.focus_mode = Control.FOCUS_ALL
	_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_text.add_theme_font_override("normal_font", UiStyle.FONT_TEXT)
	_text.add_theme_font_size_override("normal_font_size", 16)
	_text.add_theme_color_override("default_color", UiStyle.TEXT)
	outer.add_child(_text)
	_build_text(_text)

	var close_btn := Button.new()
	close_btn.name = "LicensesClose"
	close_btn.text = "Закрыть"
	close_btn.custom_minimum_size = Vector2(180.0, 44.0)
	close_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	close_btn.add_theme_font_override("font", UiStyle.FONT_TITLE)
	close_btn.add_theme_font_size_override("font_size", 20)
	UiStyle.style_button(close_btn)
	close_btn.pressed.connect(func() -> void: _close())
	outer.add_child(close_btn)

	# Фокус на тексте: стрелки/PgUp/PgDn/Home/End листают сразу, Tab ведёт к «Закрыть».
	_text.grab_focus.call_deferred()


## Полный отображаемый текст (для теста и проверок).
func full_text() -> String:
	return _text.get_parsed_text() if _text != null else ""


func _close() -> void:
	if _closing:
		return
	_closing = true
	if _focus_before != null and is_instance_valid(_focus_before) \
			and _focus_before.is_inside_tree():
		_focus_before.grab_focus()
	closed.emit()
	if get_parent() != null:
		get_parent().remove_child(self)
	queue_free()


func _input(event: InputEvent) -> void:
	if event.is_echo() or not is_visible_in_tree():
		return
	if _closing:
		get_viewport().set_input_as_handled()
		return
	if event is InputEventKey or event is InputEventJoypadButton or event is InputEventJoypadMotion:
		ModalFocus.contain(self)
	if event.is_action_pressed(&"ui_cancel"):
		get_viewport().set_input_as_handled()
		_close()


## Боевые клавиши под модальным экраном миром не управляют (как у SettingsScreen).
func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and is_visible_in_tree():
		get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	if is_visible_in_tree() and (event is InputEventKey \
			or event is InputEventJoypadButton or event is InputEventJoypadMotion):
		get_viewport().set_input_as_handled()


func _fit_panel() -> void:
	var panel := get_node_or_null("LicensesPanel") as PanelContainer
	if panel == null:
		return
	var side := clampf(size.x * 0.1, 24.0, 140.0)
	var top := clampf(size.y * 0.04, 12.0, 28.0)
	panel.offset_left = side
	panel.offset_right = -side
	panel.offset_top = top
	panel.offset_bottom = -top


# --- содержимое ---------------------------------------------------------------------------


func _build_text(rt: RichTextLabel) -> void:
	_heading(rt, "Некромант по найму (Necromancer for Hire)")
	_para(rt, "Код игры распространяется по лицензии PolyForm Noncommercial 1.0.0. Графика, "
		+ "музыка, озвучка, тексты и персонажи — все права принадлежат автору. Играть в игру, "
		+ "стримить и снимать видео можно. Название и логотип — товарные знаки.")
	_para(rt, "© 2026 Губанов Игорь Андреевич")
	_para(rt, REPO_URL)

	_heading(rt, "Godot Engine")
	_para(rt, "Игра сделана на Godot Engine. Ниже — лицензия движка, его сторонние компоненты "
		+ "и тексты лицензий (дословно, по-английски).")
	_para(rt, Engine.get_license_text())
	_build_godot_components(rt)

	for block: Array in THIRD_PARTY:
		_heading(rt, String(block[0]))
		_para(rt, String(block[1]))
		for file_name: String in block[2]:
			_para(rt, _read_legal(file_name))


func _build_godot_components(rt: RichTextLabel) -> void:
	_subheading(rt, "Сторонние компоненты Godot")
	for comp: Dictionary in Engine.get_copyright_info():
		var notices := PackedStringArray()
		var licenses := PackedStringArray()
		for part: Dictionary in comp.get("parts", []):
			for line: String in part.get("copyright", PackedStringArray()):
				if not notices.has(line):
					notices.append(line)
			var lic := String(part.get("license", ""))
			if lic != "" and not licenses.has(lic):
				licenses.append(lic)
		rt.push_color(UiStyle.GOLD)
		rt.add_text(String(comp.get("name", "?")) + "\n")
		rt.pop()
		for line in notices:
			rt.add_text("    " + line + "\n")
		rt.add_text("    License: " + ", ".join(licenses) + "\n")
	_subheading(rt, "Тексты лицензий компонентов Godot")
	var info: Dictionary = Engine.get_license_info()
	for lic_name: String in info:
		rt.push_color(UiStyle.GOLD)
		rt.add_text(lic_name + "\n")
		rt.pop()
		_para(rt, String(info[lic_name]))


func _read_legal(file_name: String) -> String:
	var path := LEGAL_DIR + file_name
	if not FileAccess.file_exists(path):
		return "[%s: файл не найден]" % file_name
	return FileAccess.get_file_as_string(path).strip_edges()


func _heading(rt: RichTextLabel, text: String) -> void:
	rt.add_text("\n")
	rt.push_font(UiStyle.FONT_TITLE, 26)
	rt.push_color(UiStyle.GOLD)
	rt.add_text(text + "\n")
	rt.pop()
	rt.pop()


func _subheading(rt: RichTextLabel, text: String) -> void:
	rt.add_text("\n")
	rt.push_font(UiStyle.FONT_TITLE, 20)
	rt.push_color(UiStyle.GOLD)
	rt.add_text(text + "\n")
	rt.pop()
	rt.pop()


func _para(rt: RichTextLabel, text: String) -> void:
	rt.add_text(text + "\n\n")
