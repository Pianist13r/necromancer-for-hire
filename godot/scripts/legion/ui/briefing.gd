class_name Briefing
extends Control
##
## Экран перед картой: название, подзаголовок, подсказка карты, состав угроз (по-русски),
## «В бой» / «Назад». Данные — из словаря карты (см. docs/legion/SLICE_SPEC.md §2), угрозы
## читает из `waves[].groups[].type`, без обращения к боевым классам.
##

signal start(map_id: String)
signal back
## Игрок взял пакет подготовки на брифинге (озвучка покупки — у LegionMain).
signal prep_bought

## Ключ типа (LegionCfg.FOES в CORE) → русское имя для игрока (CONCEPT.md, «проверяющие»).
const FOE_NAMES := {
	"zombie": "Инспектор", "beetle": "Курьер", "signer": "Нотариус",
	"ghost": "Призрак", "mimic": "Надгробие", "boss": "Прораб Ада",
	"lawyer": "Юрист", "shield_inspector": "Щитоносец",
}

var back_label := "← Назад"
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
		var hint_label := UiStyle.label(Controls.text(hint), 17, UiStyle.FONT_TEXT, UiStyle.TEXT)
		hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD
		box.add_child(hint_label)

	# meta: правка чужого файла (задание meta п.4) — плашка «Новое: …» про открытия кампанией
	# (вид бойца/способность), показывается один раз, дальше не повторяется
	# (Campaign.mark_unlocks_seen сразу после показа).
	var new_labels := Campaign.pending_unlock_labels()
	if not new_labels.is_empty():
		var new_label := UiStyle.label(Controls.text("Новое: " + ", ".join(new_labels)), 16,
			UiStyle.FONT_TITLE, UiStyle.GOOD)
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

	add_prep_block(box).changed.connect(func(bought: bool) -> void:
		if bought:
			prep_bought.emit())

	LegionUi.nav_bar(self, back_label, func() -> void: back.emit(),
		"В бой", func() -> void: start.emit(_map_id))


## D-1007-P1/P2: под угрозами — что уже действует (полоса поправок, артефакты кампании) и
## подготовка к бою прямо здесь, без отдельного экрана «Контора». Общий для брифинга забега.
static func add_prep_block(box: VBoxContainer) -> PrepPanel:
	var active := Campaign.upgrades()
	var items := Campaign.run_items()
	if not active.is_empty() or not items.is_empty():
		var head := UiStyle.label("Действует", 15, UiStyle.FONT_TITLE, UiStyle.TEXT_DIM)
		head.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		box.add_child(head)
	if not active.is_empty():
		var strip := SlotStrip.new()
		strip.name = "ActiveStrip"
		box.add_child(strip)
		strip.configure(active, false, true)
	if not items.is_empty():
		var names: PackedStringArray = []
		for id in items:
			names.append(String(LegionItemDb.item(id).get("title", id)))
		var line := UiStyle.label("Артефакты: " + ", ".join(names), 15, UiStyle.FONT_TEXT,
			UiStyle.SOUL.lightened(0.35))
		line.name = "ActiveItems"
		line.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		line.autowrap_mode = TextServer.AUTOWRAP_WORD
		box.add_child(line)
	var panel := PrepPanel.new()
	panel.name = "PrepPanel"
	box.add_child(panel)
	return panel


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
