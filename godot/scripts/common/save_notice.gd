class_name SaveNotice
extends CanvasLayer
## Ошибка диска должна быть видна игроку, а не только в консоли.

var _panel: PanelContainer
var _text: Label
var _dismiss: Button
var _paths: Array[String] = []
var _last := ""


func _ready() -> void:
	layer = 1200
	process_mode = Node.PROCESS_MODE_ALWAYS
	_panel = PanelContainer.new()
	_panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_panel.offset_left = -624.0
	_panel.offset_right = -24.0
	_panel.offset_top = 24.0
	_panel.offset_bottom = 124.0
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_theme_stylebox_override("panel", UiStyle.panel_style(Color("#251c16"), 12))
	add_child(_panel)
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 20)
	_panel.add_child(row)
	_text = UiStyle.label("", 18, UiStyle.FONT_TEXT, UiStyle.WARN)
	_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(_text)
	_dismiss = Button.new()
	_dismiss.text = "Понятно"
	UiStyle.style_button(_dismiss)
	_dismiss.pressed.connect(func() -> void:
		for path: String in _paths:
			SafeConfig.notices.erase(path))
	row.add_child(_dismiss)
	_panel.hide()


func _process(_delta: float) -> void:
	_paths.clear()
	var messages: PackedStringArray = []
	var recoverable := true
	for path: String in [Campaign._path, Settings.path]:
		if not SafeConfig.notices.has(path):
			continue
		_paths.append(path)
		var message := String(SafeConfig.notices[path])
		var label := "Настройки" if path == Settings.path else "Прогресс"
		messages.append(label + ": " + message)
		recoverable = recoverable and message.contains("резервной копии")
	var combined := "\n".join(messages)
	if combined == _last:
		return
	_last = combined
	_text.text = combined
	_panel.visible = not combined.is_empty()
	_dismiss.visible = recoverable
