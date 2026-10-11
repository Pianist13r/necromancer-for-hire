class_name DossierView
extends VBoxContainer
##
## Одно «Досье» вместо трёх имён (D-1007-P2): шапка «Досье» с разрядом и опытом, две вкладки —
## «Поправки» (полоса трёх слотов, что откроет следующий разряд, каталог колоды по трём ветвям) и
## «Артефакты (N)» (карточки артефактов текущего раздела и синергии); третья — «Рекорды»
## (RecordsTable, slow/records 10.10). Один виджет на два входа:
## экран меню HeroScreen (по умолчанию «Поправки») и оверлей паузы LegionItemDossier (по
## умолчанию «Артефакты» — в бою важнее срабатывания). В бою артефакты — живой инвентарь мира со
## счётчиками за бой; из меню — Campaign.run_items() без счётчиков.
##

const TAB_UPGRADES := "upgrades"
const TAB_ITEMS := "items"
## Личные рекорды (LegionRecords, slow/records 10.10) — таблица строится в RecordsTable.
const TAB_RECORDS := "records"
const STYLE_NAMES := {&"hr": "Кадры", &"law": "Договоры", &"warlock": "Некромантия"}

var _inventory: LegionItems = null
var _tab := TAB_UPGRADES
var _tabs := {}
var _scroll: ScrollContainer = null
var _body: VBoxContainer = null
var _cards: GridContainer = null


## inventory — живой инвентарь боя (null — из меню, артефакты раздела без счётчиков).
func configure(inventory: LegionItems = null, tab := TAB_UPGRADES) -> DossierView:
	_inventory = inventory
	_tab = tab
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 8)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 18)
	add_child(head)
	head.add_child(UiStyle.label(I18n.t("Досье"), 32, UiStyle.FONT_TITLE, UiStyle.GOLD))
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	head.add_child(spacer)
	_add_tab(head, "TabUpgrades", TAB_UPGRADES, I18n.t("Поправки"))
	_add_tab(head, "TabItems", TAB_ITEMS, I18n.t("Артефакты (%d)") % _item_ids().size())
	_add_tab(head, "TabRecords", TAB_RECORDS, I18n.t("Рекорды"))
	var meter := ProgressionUi.experience_meter(Campaign.hero_xp())
	# В досье полезен и общий опыт. Это единственная строка разряда, над его полосой.
	(meter.get_node("ExperienceCaption") as Label).text = rank_text()
	add_child(meter)
	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.focus_mode = Control.FOCUS_ALL
	_scroll.follow_focus = true
	add_child(_scroll)
	_body = VBoxContainer.new()
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_theme_constant_override("separation", 8)
	var inset := MarginContainer.new()
	inset.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inset.add_theme_constant_override("margin_right", 12)
	_scroll.add_child(inset)
	inset.add_child(_body)
	resized.connect(_resize_cards)
	show_tab(_tab)
	return self


## Разряд и опыт одной строкой (общая для шапки досье и тестов).
static func rank_text() -> String:
	var progress := Campaign.hero_xp_progress()
	var level := Campaign.hero_level()
	var out := I18n.t("Разряд %d · опыт %d. ") % [level, Campaign.hero_xp()]
	if bool(progress["maxed"]):
		return out + I18n.t("Все записи досье открыты.")
	return out + I18n.t("До разряда %d: %d опыта.") % [level + 1,
		int(progress["need"]) - int(progress["cur"])]


func tab() -> String:
	return _tab


func scroll() -> ScrollContainer:
	return _scroll


func show_tab(id: String) -> void:
	_tab = id
	for key: String in _tabs:
		var btn: Button = _tabs[key]
		btn.button_pressed = key == id
		LegionUi.style_button(btn, LegionUi.GOLD if key == id else LegionUi.INK, 18)
		btn.add_theme_color_override("font_color", UiStyle.GOLD if key == id else UiStyle.TEXT_DIM)
		btn.add_theme_color_override("font_pressed_color", UiStyle.GOLD)
		# Открытая вкладка — яркая, вторая приглушена: рамки одинаковые, без этого не различить.
		btn.modulate = Color.WHITE if key == id else Color(1.0, 1.0, 1.0, 0.6)
	for child in _body.get_children():
		_body.remove_child(child)
		child.queue_free()
	_cards = null
	_scroll.scroll_vertical = 0
	if id == TAB_ITEMS:
		_build_items()
	elif id == TAB_RECORDS:
		_body.add_child(RecordsTable.build())
	else:
		_build_upgrades()


func _add_tab(head: HBoxContainer, node_name: String, id: String, caption: String) -> void:
	var btn := Button.new()
	btn.name = node_name
	btn.text = caption
	btn.toggle_mode = true
	btn.custom_minimum_size = Vector2(150.0, 44.0)
	btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	btn.pressed.connect(func() -> void: show_tab(id))
	head.add_child(btn)
	_tabs[id] = btn


# ── Вкладка «Поправки» (бывший экран «Досье некроманта») ─────────────────────────────────────

func _build_upgrades() -> void:
	_build_rank_track()
	var strip := SlotStrip.new()
	_body.add_child(strip)
	# В «Схватке» мир сбрасывает поправки (pvp_flow: w.mods = {}), переигровка из коллекции их не
	# копит — слоты кампании там были бы неправдой о бое (verifier этапа 4).
	var off := _upgrades_off()
	strip.configure([] if off else Campaign.upgrades(), false, true)
	if off:
		_body.add_child(ProgressionUi.text(I18n.t("В этом бою поправки не действуют: они работают в ")
			+ I18n.t("кампании и в забеге. ") + _next_unlock_text(), 17, UiStyle.GOLD))
	else:
		# B-421: откуда поправка в слоте — щелчок по каталогу ничего не делает, и это надо
		# сказать. Одной строкой со следующим открытием: вторая сталкивала каталог под прокрутку.
		_body.add_child(ProgressionUi.text(I18n.t("Нажмите поправку — прочитайте пользу и цену. ")
			+ I18n.t("Подписывается после победы. ") + _next_unlock_text(), 16, UiStyle.GOLD))
	var columns := HBoxContainer.new()
	columns.add_theme_constant_override("separation", 14)
	columns.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_child(columns)
	for tag: String in ["hr", "law", "magic"]:
		var col := VBoxContainer.new()
		col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		col.add_theme_constant_override("separation", 4)
		columns.add_child(col)
		col.add_child(ProgressionUi.text(String(AmendmentDb.TAGS[tag]["title"]), 22,
			AmendmentDb.TAGS[tag]["color"]))
		for id: String in AmendmentDb.ORDER:
			var data := AmendmentDb.card(StringName(id))
			if String(data["tag"]) != tag:
				continue
			var level := int(data.get("unlock_level", 1))
			var state := I18n.t("с начала") if level <= 1 else \
				(I18n.t("открыта") if level <= Campaign.hero_level() else I18n.t("с разряда %d") % level)
			var needs := StringName(data.get("needs", ""))
			if level <= Campaign.hero_level() and needs != &"" and Campaign.stat(needs) < 0.5:
				state = I18n.t("по кампании")
			if not off and Campaign.upgrades().has(StringName(id)):
				state = I18n.t("✓ действует")
			var row := ProgressionRow.new()
			col.add_child(row)
			row.configure(StringName(id), data, "", {"right": state, "row_h": 48.0,
				"icon": 30.0, "chips": false, "inspect": true, "title_size": 18, "text_size": 16})
			if level > Campaign.hero_level():
				row.modulate = Color(1.0, 1.0, 1.0, 0.8)


## Первая по колоде карта, которую откроет следующий разряд (ближайший unlock_level выше текущего).
static func _next_unlock_text() -> String:
	var level := Campaign.hero_level()
	if level >= LegionMetaCfg.HERO_MAX_LEVEL:
		return I18n.t("Колода открыта целиком.")
	return I18n.t("Дальше: %s.") % ProgressionUi.rank_openings(level + 1)


func _build_rank_track() -> void:
	var track := HBoxContainer.new()
	track.name = "RankTrack"
	track.add_theme_constant_override("separation", 6)
	_body.add_child(track)
	for level in range(1, LegionMetaCfg.HERO_MAX_LEVEL + 1):
		var btn := Button.new()
		btn.name = "Rank%d" % level
		btn.text = "%s %d" % ["✓" if level < Campaign.hero_level() else I18n.t("Разряд"), level]
		btn.custom_minimum_size.y = 36.0
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var color := UiStyle.GOLD if level == Campaign.hero_level() else UiStyle.TEXT_DIM
		var style := UiStyle.panel_style(Color(0.12, 0.09, 0.16), 5)
		style.set_border_width_all(1)
		style.border_color = color
		btn.add_theme_stylebox_override("normal", style)
		btn.add_theme_stylebox_override("focus", ProgressionRow._focus_style(UiStyle.GOLD))
		btn.add_theme_font_override("font", UiStyle.FONT_TEXT)
		btn.add_theme_font_size_override("font_size", 16)
		btn.add_theme_color_override("font_color", color)
		btn.tooltip_text = ProgressionUi.rank_openings(level)
		btn.pressed.connect(func() -> void: ProgressionUi.inspect_rank(self, level))
		track.add_child(btn)


# ── Вкладка «Артефакты» (бывший оверлей «Досье артефактов») ──────────────────────────────────

func _item_ids() -> Array[StringName]:
	return _inventory.owned() if _inventory != null else Campaign.run_items()


func _has_item(id: StringName) -> bool:
	return _item_ids().has(id)


func _build_items() -> void:
	var ids := _item_ids()
	var scope := _items_scope_name()
	_body.add_child(_text(I18n.t("Артефакты %s%s") % [scope, I18n.t(" · срабатывания за текущий бой")
		if _inventory != null else ""], 18, UiStyle.TEXT_DIM))
	_cards = GridContainer.new()
	_cards.name = "Cards"
	_cards.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_cards.add_theme_constant_override("h_separation", 16)
	_cards.add_theme_constant_override("v_separation", 16)
	_body.add_child(_cards)
	_resize_cards()
	if ids.is_empty():
		_body.add_child(_text(I18n.t("Артефактов пока нет. Их носят элитные проверяющие в короне, ")
			+ I18n.t("с портфелем: победите такого — находка сама попадёт в инвентарь. Артефакт ")
			+ I18n.t("остаётся до конца %s и сохраняется победой в бою.") % scope, 20))
		return
	for id in ids:
		_cards.add_child(_card(id))
	_body.add_child(_text(I18n.t("Синергии — соберите обе части"), 22, UiStyle.GOLD))
	for sid in LegionItemDb.synergy_ids():
		_body.add_child(_synergy(sid))


func _resize_cards() -> void:
	if is_instance_valid(_cards):
		_cards.columns = 2 if get_viewport_rect().size.x >= 900 else 1


## Тексты Досье (KB-08): артефакты и синергии называют способности токенами; раскрывает их
## ProgressionUi.text — единственный сток, второй Controls.text здесь не нужен.
func _text(value: String, font_size := 17, color := UiStyle.TEXT) -> Label:
	var label := ProgressionUi.text(value, font_size, color)
	return label


func _card(id: StringName) -> Control:
	var d := LegionItemDb.item(id)
	var rarity_color: Color = CfgItems.RARITY_COLOR[LegionItemDb.rarity(id)]
	var panel := PanelContainer.new()
	panel.name = String(id)
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", LegionUi.blank_style(rarity_color,
		LegionUi.PAPER_HI, 16, 12, false))
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 6)
	panel.add_child(column)
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 14)
	column.add_child(header)
	header.add_child(LegionIcons.rect(LegionItemDb.icon_name(id), 64.0))
	var heading := VBoxContainer.new()
	heading.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	heading.add_theme_constant_override("separation", 0)
	header.add_child(heading)
	heading.add_child(UiStyle.label(I18n.t(String(d["title"])), 22, UiStyle.FONT_TITLE, rarity_color))
	var tags: Array[String] = []
	for style: StringName in d["styles"]:
		tags.append(I18n.t(String(STYLE_NAMES.get(style, style))))
	heading.add_child(_text(I18n.t(String(CfgItems.RARITY_TITLE[LegionItemDb.rarity(id)]))
		+ " · " + " / ".join(tags), 16, UiStyle.TEXT_DIM))
	if bool(d.get("passive", false)):
		heading.add_child(_text(I18n.t("Действует постоянно"), 17, UiStyle.GOLD))
	elif _inventory != null:
		var uses := _text(I18n.t("Срабатываний: %d") % _inventory.activation_count(id), 17, UiStyle.GOLD)
		uses.name = "Uses"
		heading.add_child(uses)
	column.add_child(_text(I18n.t("Когда: ") + I18n.t(String(d["trigger"]))))
	column.add_child(_text(I18n.t("Эффект: ") + I18n.t(String(d["result"]))))
	column.add_child(_text(I18n.t("Приём: ") + I18n.t(String(d["play_hint"])), 17, UiStyle.GOOD))
	column.add_child(_text(I18n.t("На поле: ") + I18n.t(String(d["cue"])), 16, UiStyle.TEXT_DIM))
	return panel


func _synergy(id: StringName) -> Control:
	var d := LegionItemDb.synergy(id)
	var missing: Array[String] = []
	var parts: Array[String] = []
	for part: String in d["items"]:
		var title := I18n.t(String(LegionItemDb.item(StringName(part))["title"]))
		parts.append(title)
		if not _has_item(StringName(part)):
			missing.append(title)
	var row := VBoxContainer.new()
	row.add_child(_text(I18n.t(String(d["title"])) + " · " + (I18n.t("Собрана") if missing.is_empty()
		else I18n.t("Не хватает: ") + ", ".join(missing)), 20, UiStyle.GOLD))
	row.add_child(_text(" + ".join(parts) + " → " + I18n.t(String(d["text"]))))
	return row


## Поправки в этом бою не действуют: «Схватка» (PvP) или переигровка из коллекции.
func _upgrades_off() -> bool:
	if _inventory != null and _inventory.world != null and _inventory.world.pvp:
		return true
	return Campaign.is_replay_scope()


## Чьи артефакты на вкладке: «кампании», «забега», «этого боя» («Схватка»), «переигровки».
func _items_scope_name() -> String:
	if _inventory != null and _inventory.world != null and _inventory.world.pvp:
		return I18n.t("этого боя")
	if Campaign.is_replay_scope():
		return I18n.t("переигровки")
	return I18n.t("забега") if Campaign.is_endless_scope() else I18n.t("кампании")
