class_name Briefing
extends Control
##
## Экран перед картой: название, подзаголовок, подсказка карты, состав угроз (по-русски),
## «В бой» / «Назад». Данные — из словаря карты (см. docs/legion/SLICE_SPEC.md §2), угрозы
## читает из `waves[].groups[].type`, без обращения к боевым классам.
##

signal start(map_id: String)
signal back

## Ключ типа (LegionCfg.FOES в CORE) → русское имя для игрока (CONCEPT.md, «проверяющие»).
const FOE_NAMES := {
	"zombie": "Инспектор", "beetle": "Курьер", "signer": "Нотариус",
	"ghost": "Призрак", "mimic": "Надгробие", "boss": "Прораб Ада",
	"lawyer": "Юрист", "shield_inspector": "Щитоносец",
}

var _map_id := ""


func _ready() -> void:
	UiStyle.fill_rect(self)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


## Пересобрать экран под конкретную карту.
func populate(map_data: Dictionary) -> void:
	for c in get_children():
		c.queue_free()

	_map_id = String(map_data.get("id", ""))

	var backdrop := ColorRect.new()
	backdrop.color = Color(0.02, 0.01, 0.04, 0.88)
	UiStyle.fill_rect(backdrop)
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(backdrop)

	var box := UiStyle.card_box(self, 620.0, 12)

	var title := UiStyle.label(
		String(map_data.get("title", _map_id)), 34, UiStyle.FONT_TITLE, UiStyle.GOLD)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)

	var subtitle := UiStyle.label(
		String(map_data.get("subtitle", "")), 18, UiStyle.FONT_TEXT, UiStyle.TEXT_DIM)
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.autowrap_mode = TextServer.AUTOWRAP_WORD
	box.add_child(subtitle)

	var hint := String(map_data.get("hint", ""))
	if hint != "":
		var hint_label := UiStyle.label(hint, 17, UiStyle.FONT_TEXT, UiStyle.TEXT)
		hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD
		box.add_child(hint_label)

	# meta: правка чужого файла (задание meta п.4) — плашка «Новое: …» про открытия кампанией
	# (вид бойца/способность), показывается один раз, дальше не повторяется
	# (Campaign.mark_unlocks_seen сразу после показа).
	var new_labels := Campaign.pending_unlock_labels()
	if not new_labels.is_empty():
		var new_label := UiStyle.label("Новое: " + ", ".join(new_labels), 16, UiStyle.FONT_TITLE,
			UiStyle.GOOD)
		new_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		new_label.autowrap_mode = TextServer.AUTOWRAP_WORD
		box.add_child(new_label)
		Campaign.mark_unlocks_seen()

	var threats := _threat_list(map_data)
	if not threats.is_empty():
		var threats_title := UiStyle.label(
			"Кто идёт по объекту", 16, UiStyle.FONT_TITLE, UiStyle.TEXT_DIM)
		threats_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		box.add_child(threats_title)
		var threats_row := UiStyle.label(", ".join(threats), 17, UiStyle.FONT_TEXT, UiStyle.WARN)
		threats_row.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		threats_row.autowrap_mode = TextServer.AUTOWRAP_WORD
		box.add_child(threats_row)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 14)
	box.add_child(row)

	var back_btn := Button.new()
	back_btn.text = "Назад"
	back_btn.custom_minimum_size = Vector2(160.0, 46.0)
	back_btn.add_theme_font_override("font", UiStyle.FONT_TITLE)
	back_btn.add_theme_font_size_override("font_size", 20)
	UiStyle.style_button(back_btn)
	back_btn.pressed.connect(func() -> void: back.emit())
	row.add_child(back_btn)

	var start_btn := Button.new()
	start_btn.text = "В бой"
	start_btn.custom_minimum_size = Vector2(200.0, 46.0)
	start_btn.add_theme_font_override("font", UiStyle.FONT_TITLE)
	start_btn.add_theme_font_size_override("font_size", 22)
	UiStyle.style_button(start_btn)
	start_btn.pressed.connect(func() -> void: start.emit(_map_id))
	row.add_child(start_btn)


## Собирает уникальные русские имена типов врагов из waves[].groups[].type — любых полей
## может не быть (карта-заглушка, ранняя версия JSON MAPS), пропускаем молча.
func _threat_list(map_data: Dictionary) -> Array[String]:
	var seen: Dictionary = {}
	var out: Array[String] = []
	# волны — с уровнем боя (slow/challenge): на «Стажёре» врагов «Штатного» не будет
	var waves: Array = LegionChallenge.apply_map(map_data,
		LegionChallenge.campaign_level(String(map_data.get("id", "")))).get("waves", [])
	for wave in waves:
		if not (wave is Dictionary):
			continue
		var groups: Array = wave.get("groups", [])
		for group in groups:
			if not (group is Dictionary):
				continue
			var type_id := String(group.get("type", ""))
			if type_id == "" or seen.has(type_id):
				continue
			seen[type_id] = true
			out.append(String(FOE_NAMES.get(type_id, type_id)))
	return out
