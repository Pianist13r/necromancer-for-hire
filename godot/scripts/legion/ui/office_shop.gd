class_name OfficeShop
extends Control
##
## «Контора» — покупки за премию между картами кампании (DESIGN_V15 §7, §12 п.9) в виде дерева
## (slow/tree, Игорь 26.09: «очень непонятная… надо читать до фига текста»). Четыре ветки:
## по одной на вид бойца (корень — печать договора вида) и «Общие» (корень — портфель конторы).
## В ветке — цепочки покупок из LegionMetaCfg.OFFICE_SHOP, каждый уровень покупки — свой узел
## сверху вниз: видно, сколько уже куплено, что следующее и сколько стоит.
## Данные, цены и сама покупка — прежние (Campaign.shop_buy), экран меняет только вид.
## Ветка ещё не открытого вида видна закрытой с замком (раньше скрывалась) — дерево показывает,
## что будет дальше, а купить в ней по-прежнему ничего нельзя.
##

signal back
signal hero_pressed
## integrate1: покупка состоялась (озвучка «Покупка оформлена» — у LegionMain, он знает звук боя).
signal bought

const COL_W := 94.0
const GROUP_GAP := 24.0
const HEADER_Y := 138.0
const CAPTION_Y := 244.0
const ROW_Y: Array[float] = [300.0, 410.0, 520.0]
const GENERAL := "general"
## Строка «что даёт» одного уровня покупки; числа подставляются из per_level (для unit "%" —
## в процентах по модулю), чтобы текст не разошёлся с балансом при правке чисел.
const EFFECT_TEXT := {
	"range": "+%s px к радиусу набора договора",
	"staff": "+%s %% мест в штате построек",
	"respawn": "Возрождение на %s %% быстрее",
	"mana": "+%s маны про запас и +%s/с восстановления",
	"souls": "+%s душ на старте объекта",
	"settlement": "+%s %% к расчёту — здоровью за отстоянный срок",
}
const PREMIUM_TEX := preload("res://assets/legion/icons/premium.png")

var _tree: UpgradeTree
var _bounty_label: Label
var _hero_btn: Button
var _next_btn: Button


func _ready() -> void:
	UiStyle.fill_rect(self)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	var backdrop := ColorRect.new()
	backdrop.color = Color(0.02, 0.01, 0.04, 0.94)
	UiStyle.fill_rect(backdrop)
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(backdrop)

	var title := UiStyle.label("Контора", 32, UiStyle.FONT_TITLE, UiStyle.GOLD)
	title.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	title.offset_top = 14.0
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(title)

	var bounty_row := HBoxContainer.new()
	bounty_row.alignment = BoxContainer.ALIGNMENT_CENTER
	bounty_row.add_theme_constant_override("separation", 8)
	bounty_row.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	bounty_row.offset_top = 56.0
	bounty_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bounty_row)
	bounty_row.add_child(LegionIcons.rect("premium", 32.0))
	_bounty_label = UiStyle.label("", 26, UiStyle.FONT_TITLE, UiStyle.GOLD)
	bounty_row.add_child(_bounty_label)

	_tree = UpgradeTree.new()
	add_child(_tree)
	_tree.node_pressed.connect(_on_node_pressed)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 14)
	row.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	row.offset_top = -62.0
	row.offset_bottom = -16.0
	add_child(row)

	_hero_btn = _make_button("Герой", 20)
	_hero_btn.pressed.connect(func() -> void: hero_pressed.emit())
	row.add_child(_hero_btn)

	_next_btn = _make_button("Дальше", 20)
	_next_btn.pressed.connect(func() -> void: back.emit())
	row.add_child(_next_btn)

	_build_tree()
	refresh()
	_focus_start.call_deferred()


func tree() -> UpgradeTree:
	return _tree


## Группы дерева: сначала виды бойцов по LegionCfg.KIND_ORDER, потом «Общие».
func _groups() -> Array[String]:
	var out: Array[String] = []
	for kind in LegionCfg.KIND_ORDER:
		out.append(String(kind))
	out.append(GENERAL)
	return out


func _chain_ids(group: String) -> Array[String]:
	var out: Array[String] = []
	for id: String in LegionMetaCfg.OFFICE_SHOP_ORDER:
		var per_kind := bool(LegionMetaCfg.OFFICE_SHOP[id].get("per_kind", false))
		if per_kind == (group != GENERAL):
			out.append(id)
	return out


func _build_tree() -> void:
	var groups := _groups()
	var chains_total := 0
	for g in groups:
		chains_total += _chain_ids(g).size()
	var full_w := COL_W * chains_total + GROUP_GAP * (groups.size() - 1)
	var x := (UpgradeTree.DESIGN.x - full_w) * 0.5 + COL_W * 0.5
	var col := 0
	for g in groups:
		var ids := _chain_ids(g)
		var accent := _group_accent(g)
		var header_key := "group:%s" % g
		var header_x := x + COL_W * (ids.size() - 1) * 0.5
		var header_tex := "shop_general" if g == GENERAL else "contract_%s" % g
		var header_title := "Общие" if g == GENERAL else \
			String(LegionMetaCfg.KIND_LABELS.get(StringName(g), g))
		_tree.add_header(header_key, Vector2(header_x, HEADER_Y), header_tex, header_title, accent)
		for id in ids:
			var data: Dictionary = LegionMetaCfg.OFFICE_SHOP[id]
			_tree.add_caption(String(data.get("title", id)), Vector2(x, CAPTION_Y))
			var kind := "" if g == GENERAL else g
			var prev := header_key
			for lvl in range(1, Campaign.shop_max_level(id) + 1):
				var n := UpgradeNode.new()
				var k := node_key(id, kind, lvl)
				n.setup(k, "shop_%s" % id, accent, "", Vector2i(col, lvl - 1))
				_tree.add_node(n, Vector2(x, ROW_Y[mini(lvl - 1, ROW_Y.size() - 1)]), COL_W)
				_tree.add_link(prev, k)
				prev = k
			x += COL_W
			col += 1
		x += GROUP_GAP
	_tree.wire_focus(_next_btn)
	_hero_btn.focus_neighbor_top = _hero_btn.get_path_to(_tree.nodes()[0])
	_next_btn.focus_neighbor_top = _next_btn.get_path_to(_tree.nodes()[0])


static func node_key(id: String, kind: String, lvl: int) -> String:
	return "shop:%s:%s:%d" % [id, kind, lvl]


func _group_accent(g: String) -> Color:
	if g == GENERAL:
		return Cfg.RUNE_COLOR
	var kd: Dictionary = LegionCfg.UNIT_KINDS.get(StringName(g), {})
	return kd.get("color", Cfg.RUNE_COLOR)


## Пересчитывает состояния всех узлов (дерево не перестраивается — фокус и подсказка остаются
## на месте после покупки).
func refresh() -> void:
	var bounty := Campaign.bounty()
	_bounty_label.text = str(bounty)
	for n in _tree.nodes():
		var parts := n.key.split(":")
		_apply_state(n, parts[1], parts[2], int(parts[3]), bounty)
	for kind in LegionCfg.KIND_ORDER:
		_tree.set_header_dim("group:%s" % kind, Campaign.stat("kind_unlocked_%s" % kind) < 0.5)
	_tree.refresh_links()


func _apply_state(n: UpgradeNode, id: String, kind: String, lvl: int, bounty: int) -> void:
	var data: Dictionary = LegionMetaCfg.OFFICE_SHOP[id]
	var costs: Array = data.get("costs", [])
	var cost := int(costs[lvl - 1])
	var owned := Campaign.shop_level(id, kind)
	var title := String(data.get("title", id))
	if kind != "":
		title += " · " + String(LegionMetaCfg.KIND_LABELS.get(StringName(kind), kind))
	n.tip_title = "%s · ур. %d" % [title, lvl]
	n.tip_what = effect_text(id)
	var st := UpgradeNode.State.LOCKED
	var need := ""
	if lvl <= owned:
		st = UpgradeNode.State.OWNED
		need = "Куплено"
	elif kind != "" and Campaign.stat("kind_unlocked_%s" % kind) < 0.5:
		need = _kind_lock_reason(kind)
	elif lvl > owned + 1:
		need = "Сначала уровень %d" % (lvl - 1)
	elif bounty >= cost:
		st = UpgradeNode.State.BUYABLE
		need = "Купить за %d премии" % cost
	else:
		st = UpgradeNode.State.POOR
		need = "Не хватает %d премии" % (cost - bounty)
	n.tip_need = need
	n.set_state(st, cost, PREMIUM_TEX)


## Вид бойца открывается прохождением карты перед той, где он появляется (Campaign._unlock_mods):
## вахтёр — после первой карты, счетовод — после второй.
func _kind_lock_reason(kind: String) -> String:
	var idx := LegionCfg.KIND_ORDER.find(StringName(kind))
	var maps := Campaign.maps()
	if idx >= 1 and idx - 1 < maps.size():
		return "Вид откроется после карты «%s»" % String(maps[idx - 1].get("title", ""))
	return "Вид ещё не открыт"


## Одна строка «что даёт» уровень покупки, с числами из per_level.
static func effect_text(id: String) -> String:
	var data: Dictionary = LegionMetaCfg.OFFICE_SHOP.get(id, {})
	var tmpl := String(EFFECT_TEXT.get(id, ""))
	if tmpl == "":
		return String(data.get("desc", ""))
	var pct := String(data.get("unit", "")) == "%"
	var vals: Array = []
	for v in data.get("per_level", []):
		vals.append(fmt_num(absf(float(v)) * 100.0 if pct else float(v)))
	return tmpl % vals


## Число без хвоста «.0», с запятой (русская запись): 40, 2, 0,5.
static func fmt_num(v: float) -> String:
	if is_equal_approx(v, roundf(v)):
		return str(int(roundf(v)))
	return String.num(v, 2).replace(".", ",")


func _on_node_pressed(n: UpgradeNode) -> void:
	match n.state:
		UpgradeNode.State.OWNED:
			return
		UpgradeNode.State.BUYABLE:
			var parts := n.key.split(":")
			if Campaign.shop_buy(parts[1], parts[2]):
				bought.emit()
				refresh()
				n.flash_bought()
				_tree.show_tip(n)
				return
	n.flash_denied()
	_tree.show_tip(n, true)


## Фокус при открытии — на первую доступную покупку (иначе на первый узел): с клавиатуры и
## геймпада сразу есть что нажать. Подсказку при этом не показываем — мышь её вызовет сама.
func _focus_start() -> void:
	var first: UpgradeNode = null
	for n in _tree.nodes():
		if n.state == UpgradeNode.State.BUYABLE:
			first = n
			break
	if first == null and not _tree.nodes().is_empty():
		first = _tree.nodes()[0]
	if first != null and is_inside_tree():
		first.grab_focus()


func _make_button(text: String, font_size: int) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.custom_minimum_size = Vector2(160.0, 44.0)
	btn.add_theme_font_override("font", UiStyle.FONT_TITLE)
	btn.add_theme_font_size_override("font_size", font_size)
	UiStyle.style_button(btn)
	return btn
