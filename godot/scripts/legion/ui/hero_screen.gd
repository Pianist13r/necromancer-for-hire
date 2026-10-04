class_name HeroScreen
extends Control
##
## Экран героя (DESIGN_V15 §6, §12 п.8–9) деревом (slow/tree, Игорь 26.09: «дерево… с иконками»):
## слева три способности Ку/Дубль-вэ/Е — корень-иконка и цепочка из двух рангов сверх базового,
## справа три ветки перков — корень-значок ветки и цепочка перков по `requires`
## (LegionMetaCfg.HERO_PERKS). Цена каждого узла — одно очко героя (самоцвет). Сверху — уровень,
## полоска опыта и свободные очки. Логика прежняя: Campaign.hero_rank_up / hero_take_perk /
## hero_reset; экран меняет только вид. Доступен из меню и из «Конторы» (legion_main.gd).
##

signal back

const COL_W := 150.0
const GROUP_GAP := 80.0
const HEADER_Y := 160.0
const ROW_Y: Array[float] = [292.0, 408.0, 524.0]
const POINT_TEX := preload("res://assets/legion/icons/hero_point.png")
## Цвет ветки перков — рамка корня и кольца узлов.
const BRANCH_ACCENT := {
	"hr": Color(1.0, 0.81, 0.42), "law": Color(0.45, 0.65, 1.0), "warlock": Color(0.588, 0.353, 1.0),
}

var _level_label: Label
var _xp_bar: ProgressBar
var _xp_label: Label
var _points_label: Label
var _tree: UpgradeTree
var _reset_btn: Button
var _back_btn: Button


func _ready() -> void:
	UiStyle.fill_rect(self)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	var backdrop := ColorRect.new()
	backdrop.color = Color(0.02, 0.01, 0.04, 0.94)
	UiStyle.fill_rect(backdrop)
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(backdrop)

	var title := UiStyle.label("Некромант", 30, UiStyle.FONT_TITLE, UiStyle.GOLD)
	title.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	title.offset_top = 12.0
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(title)

	var head := HBoxContainer.new()
	head.alignment = BoxContainer.ALIGNMENT_CENTER
	head.add_theme_constant_override("separation", 12)
	head.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	head.offset_top = 56.0
	head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(head)
	_level_label = UiStyle.label("", 22, UiStyle.FONT_TITLE, UiStyle.TEXT)
	head.add_child(_level_label)
	_xp_bar = ProgressBar.new()
	_xp_bar.show_percentage = false
	_xp_bar.custom_minimum_size = Vector2(300.0, 14.0)
	_xp_bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_xp_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Тема по умолчанию рисует полоску почти невидимой на тёмном фоне (кадр slow/tree) —
	# своя подложка и заливка фирменным фиолетовым.
	var bar_bg := UiStyle.panel_style(Color(0.14, 0.10, 0.22, 1.0), 7)
	bar_bg.border_color = Color(Cfg.RUNE_COLOR, 0.6)
	bar_bg.set_border_width_all(1)
	_xp_bar.add_theme_stylebox_override("background", bar_bg)
	_xp_bar.add_theme_stylebox_override("fill", UiStyle.panel_style(Cfg.RUNE_COLOR, 7))
	head.add_child(_xp_bar)
	_xp_label = UiStyle.label("", 16, UiStyle.FONT_TEXT, UiStyle.TEXT_DIM)
	head.add_child(_xp_label)
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(16.0, 0.0)
	head.add_child(gap)
	head.add_child(LegionIcons.rect("hero_point", 30.0))
	_points_label = UiStyle.label("", 24, UiStyle.FONT_TITLE, UiStyle.GOOD)
	head.add_child(_points_label)

	_tree = UpgradeTree.new()
	add_child(_tree)
	_tree.node_pressed.connect(_on_node_pressed)

	var footer := HBoxContainer.new()
	footer.alignment = BoxContainer.ALIGNMENT_CENTER
	footer.add_theme_constant_override("separation", 14)
	footer.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	footer.offset_top = -62.0
	footer.offset_bottom = -16.0
	add_child(footer)

	_reset_btn = _make_button("Сбросить очки", 18)
	_reset_btn.pressed.connect(func() -> void:
		Campaign.hero_reset()
		refresh())
	footer.add_child(_reset_btn)

	_back_btn = _make_button("Назад", 18)
	_back_btn.pressed.connect(func() -> void: back.emit())
	footer.add_child(_back_btn)

	_build_tree()
	refresh()
	_focus_start.call_deferred()


func tree() -> UpgradeTree:
	return _tree


func _build_tree() -> void:
	var cols := LegionMetaCfg.HERO_ABILITIES.size() + LegionMetaCfg.PERK_BRANCH_ORDER.size()
	var full_w := COL_W * cols + GROUP_GAP
	var x := (UpgradeTree.DESIGN.x - full_w) * 0.5 + COL_W * 0.5
	var col := 0
	for ability: StringName in LegionMetaCfg.HERO_ABILITIES:
		var a := String(ability)
		var accent := _ability_accent(a)
		var header_key := "ability:%s" % a
		var full_title := String(LegionMetaCfg.HERO_ABILITY_TITLES.get(ability, a))
		_tree.add_header(header_key, Vector2(x, HEADER_Y), "ability_%s" % a,
			full_title.get_slice(" — ", 0), accent)
		var prev := header_key
		for r in range(1, LegionMetaCfg.HERO_ABILITY_MAX_RANK + 1):
			var n := UpgradeNode.new()
			var k := "rank:%s:%d" % [a, r]
			n.setup(k, "ability_%s" % a, accent, "Ранг %d" % r, Vector2i(col, r - 1))
			_tree.add_node(n, Vector2(x, ROW_Y[r - 1]), COL_W)
			_tree.add_link(prev, k)
			prev = k
		x += COL_W
		col += 1
	x += GROUP_GAP
	for branch: String in LegionMetaCfg.PERK_BRANCH_ORDER:
		var accent: Color = BRANCH_ACCENT.get(branch, Cfg.RUNE_COLOR)
		var header_key := "branch:%s" % branch
		_tree.add_header(header_key, Vector2(x, HEADER_Y), "branch_%s" % branch,
			String(LegionMetaCfg.PERK_BRANCH_TITLES.get(branch, branch)), accent)
		var ids: Array = LegionMetaCfg.PERK_BRANCH_IDS.get(branch, [])
		for i in ids.size():
			var id := String(ids[i])
			var data: Dictionary = LegionMetaCfg.HERO_PERKS.get(id, {})
			var n := UpgradeNode.new()
			var k := "perk:%s" % id
			n.setup(k, id, accent, String(data.get("title", id)), Vector2i(col, i))
			_tree.add_node(n, Vector2(x, ROW_Y[mini(i, ROW_Y.size() - 1)]), COL_W)
			var req := String(data.get("requires", ""))
			_tree.add_link(header_key if req == "" else "perk:%s" % req, k)
		x += COL_W
		col += 1
	_tree.wire_focus(_reset_btn)
	_reset_btn.focus_neighbor_top = _reset_btn.get_path_to(_tree.nodes()[0])
	_back_btn.focus_neighbor_top = _back_btn.get_path_to(_tree.nodes()[0])


func _ability_accent(a: String) -> Color:
	match a:
		"q":
			return LegionCfg.Q_COLOR
		"w":
			return LegionCfg.W_COLOR
		"e":
			return LegionCfg.E_COLOR
	return Cfg.RUNE_COLOR


## Пересчитывает шапку и состояния узлов — после любой покупки ранга/перка/сброса.
func refresh() -> void:
	var lvl := Campaign.hero_level()
	var progress := Campaign.hero_xp_progress()
	_level_label.text = "Уровень %d" % lvl
	if bool(progress.get("maxed", false)):
		_xp_bar.max_value = 1.0
		_xp_bar.value = 1.0
		_xp_label.text = "максимум"
	else:
		_xp_bar.max_value = maxf(1.0, float(progress.get("need", 1)))
		_xp_bar.value = float(progress.get("cur", 0))
		_xp_label.text = "%d / %d" % [int(progress.get("cur", 0)), int(progress.get("need", 1))]
	var pts := Campaign.hero_points_available()
	_points_label.text = str(pts)
	_points_label.add_theme_color_override("font_color", UiStyle.GOOD if pts > 0 else UiStyle.TEXT_DIM)
	for n in _tree.nodes():
		if n.key.begins_with("rank:"):
			_apply_rank(n, pts)
		else:
			_apply_perk(n, pts)
	_tree.refresh_links()


func _apply_rank(n: UpgradeNode, pts: int) -> void:
	var parts := n.key.split(":")
	var a := StringName(parts[1])
	var r := int(parts[2])
	var cur := Campaign.hero_rank(a)
	n.tip_title = "%s · ранг %d" % [String(LegionMetaCfg.HERO_ABILITY_TITLES.get(a, a)), r]
	n.tip_what = rank_effect_text(a, r)
	var st := UpgradeNode.State.LOCKED
	if r <= cur:
		st = UpgradeNode.State.OWNED
		n.tip_need = "Взято"
	elif r > cur + 1:
		n.tip_need = "Сначала ранг %d" % (r - 1)
	elif pts > 0:
		st = UpgradeNode.State.BUYABLE
		n.tip_need = "Взять за 1 очко героя"
	else:
		st = UpgradeNode.State.POOR
		n.tip_need = "Нет свободных очков героя"
	n.set_state(st, 1, POINT_TEX)


func _apply_perk(n: UpgradeNode, pts: int) -> void:
	var id := n.key.trim_prefix("perk:")
	var data: Dictionary = LegionMetaCfg.HERO_PERKS.get(id, {})
	var req := String(data.get("requires", ""))
	n.tip_title = String(data.get("title", id))
	n.tip_what = String(data.get("desc", ""))
	var st := UpgradeNode.State.LOCKED
	if Campaign.hero_has_perk(StringName(id)):
		st = UpgradeNode.State.OWNED
		n.tip_need = "Взято"
	elif req != "" and not Campaign.hero_has_perk(StringName(req)):
		var req_data: Dictionary = LegionMetaCfg.HERO_PERKS.get(req, {})
		n.tip_need = "Сначала «%s»" % String(req_data.get("title", req))
	elif pts > 0:
		st = UpgradeNode.State.BUYABLE
		n.tip_need = "Взять за 1 очко героя"
	else:
		st = UpgradeNode.State.POOR
		n.tip_need = "Нет свободных очков героя"
	n.set_state(st, 1, POINT_TEX)


## Что даёт ранг — итог на этом ранге, числа из LegionCfg (владелец чисел — пакет hero).
static func rank_effect_text(a: StringName, r: int) -> String:
	match String(a):
		"q":
			return "Урон молнии ×%s" % OfficeShop.fmt_num(LegionCfg.Q_RANK_DMG_MULT[r])
		"w":
			return "Внештатники служат %s с, урон ×%s" % [
				OfficeShop.fmt_num(LegionCfg.W_DURATION_BY_RANK[r]),
				OfficeShop.fmt_num(LegionCfg.W_DMG_MULT_BY_RANK[r])]
		"e":
			return "Аврал длится %s с" % OfficeShop.fmt_num(
				LegionCfg.E_DURATION_BASE + LegionCfg.E_DURATION_RANK_STEP * r)
	return String(LegionMetaCfg.HERO_ABILITY_RANK_TEXT.get(a, ""))


func _on_node_pressed(n: UpgradeNode) -> void:
	match n.state:
		UpgradeNode.State.OWNED:
			return
		UpgradeNode.State.BUYABLE:
			var ok := false
			if n.key.begins_with("rank:"):
				ok = Campaign.hero_rank_up(StringName(n.key.split(":")[1]))
			else:
				ok = Campaign.hero_take_perk(StringName(n.key.trim_prefix("perk:")))
			if ok:
				refresh()
				n.flash_bought()
				_tree.show_tip(n)
				return
	n.flash_denied()
	_tree.show_tip(n, true)


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
	btn.custom_minimum_size = Vector2(170.0, 44.0)
	btn.add_theme_font_override("font", UiStyle.FONT_TITLE)
	btn.add_theme_font_size_override("font_size", font_size)
	UiStyle.style_button(btn)
	return btn
