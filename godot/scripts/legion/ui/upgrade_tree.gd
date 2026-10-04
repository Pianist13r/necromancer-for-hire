class_name UpgradeTree
extends Control
##
## Полотно дерева покупок (slow/tree): корни-печати групп, узлы UpgradeNode, линии связей между
## ними, всплывающая подсказка и фокус с клавиатуры/геймпада. Один на «Контору» и экран героя —
## экраны только раскладывают узлы по сетке и считают их состояния из Campaign.
##
## Почему раскладка в абсолютных координатах 1280×720, а не контейнерами: проект растягивает
## холст целиком (stretch canvas_items, логический экран всегда 1280×720, полный экран владельца
## лишь масштабирует его), а связи дерева — это линии между центрами узлов, которые контейнеры
## не рисуют. Само полотно стоит по центру родителя фиксированным прямоугольником — при другом
## соотношении сторон оно не расползается, а остаётся цельной картинкой посередине.
##

signal node_pressed(node: UpgradeNode)

const DESIGN := Vector2(1280.0, 720.0)
const HEADER_ICON := 52.0

var _nodes: Array[UpgradeNode] = []
var _by_key: Dictionary = {}
## Корни групп: {key, pos, tex, title, accent} — не кликаются, только подписывают ветку.
var _headers: Array[Dictionary] = []
## Подписи цепочек (имя покупки над первым узлом): {text, pos}.
var _captions: Array[Dictionary] = []
## Связи: [from_key, to_key]; from — узел или корень группы.
var _links: Array = []
var _tip: PanelContainer
var _tip_title: Label
var _tip_what: Label
var _tip_need: Label
var _tip_node: UpgradeNode
## Последний ввод — мышь: подсказку показывает наведение; с клавиатуры/геймпада — фокус.
var _mouse_mode := true


func _ready() -> void:
	anchor_left = 0.5
	anchor_right = 0.5
	anchor_top = 0.5
	anchor_bottom = 0.5
	offset_left = -DESIGN.x * 0.5
	offset_right = DESIGN.x * 0.5
	offset_top = -DESIGN.y * 0.5
	offset_bottom = DESIGN.y * 0.5
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_tip()


func nodes() -> Array[UpgradeNode]:
	return _nodes


func node(node_key: String) -> UpgradeNode:
	return _by_key.get(node_key, null)


## center — центр печати узла в координатах полотна 1280×720.
func add_node(n: UpgradeNode, center: Vector2, width: float) -> void:
	n.size = Vector2(width, 104.0)
	n.position = center - Vector2(width * 0.5, UpgradeNode.CIRCLE_Y)
	add_child(n)
	if _tip != null:
		move_child(_tip, -1)   # подсказка всегда поверх узлов
	_nodes.append(n)
	_by_key[n.key] = n
	n.pressed.connect(func() -> void: node_pressed.emit(n))
	n.mouse_entered.connect(func() -> void: show_tip(n))
	n.mouse_exited.connect(func() -> void:
		if _tip_node == n and _mouse_mode:
			hide_tip())
	n.focus_entered.connect(func() -> void:
		if not _mouse_mode:
			show_tip(n))


func add_header(header_key: String, center: Vector2, tex_name: String, title: String,
		accent: Color) -> void:
	_headers.append({"key": header_key, "pos": center, "tex": LegionIcons.tex(tex_name),
		"title": title, "accent": accent})
	queue_redraw()


## Корень закрытой ветки (вид бойца ещё не открыт) — серый, с замком.
func set_header_dim(header_key: String, dim: bool) -> void:
	for h in _headers:
		if String(h["key"]) == header_key:
			h["dim"] = dim
	queue_redraw()


func add_caption(text: String, center: Vector2) -> void:
	_captions.append({"text": text, "pos": center})
	queue_redraw()


func add_link(from_key: String, to_key: String) -> void:
	_links.append([from_key, to_key])
	queue_redraw()


## Соседи фокуса по сетке узлов (col, row): вверх/вниз — по своей колонке, влево/вправо —
## ближайшая по строке в соседней непустой колонке. Явно, а не автопоиском Godot: автопоиск
## по геометрии перескакивал бы через линии в чужую ветку и мог не дойти до крайних узлов.
## bottom_exit — куда уходит «вниз» с нижнего узла колонки (кнопки экрана).
func wire_focus(bottom_exit: Control) -> void:
	var order := _nodes.duplicate()
	order.sort_custom(func(a: UpgradeNode, b: UpgradeNode) -> bool:
		return a.grid.x < b.grid.x or (a.grid.x == b.grid.x and a.grid.y < b.grid.y))
	for i in order.size():
		var n: UpgradeNode = order[i]
		var up := _in_column(n, -1)
		var down := _in_column(n, 1)
		var left := _side(n, -1)
		var right := _side(n, 1)
		n.focus_neighbor_top = n.get_path_to(up if up != null else n)
		n.focus_neighbor_bottom = n.get_path_to(down) if down != null else \
			(n.get_path_to(bottom_exit) if bottom_exit != null else n.get_path_to(n))
		n.focus_neighbor_left = n.get_path_to(left if left != null else n)
		n.focus_neighbor_right = n.get_path_to(right if right != null else n)
		n.focus_next = n.get_path_to(order[(i + 1) % order.size()])
		n.focus_previous = n.get_path_to(order[(i - 1 + order.size()) % order.size()])


func _in_column(n: UpgradeNode, dir: int) -> UpgradeNode:
	var best: UpgradeNode = null
	for o in _nodes:
		if o.grid.x != n.grid.x or signi(o.grid.y - n.grid.y) != dir:
			continue
		if best == null or absi(o.grid.y - n.grid.y) < absi(best.grid.y - n.grid.y):
			best = o
	return best


func _side(n: UpgradeNode, dir: int) -> UpgradeNode:
	var best: UpgradeNode = null
	for o in _nodes:
		var dx := o.grid.x - n.grid.x
		if signi(dx) != dir:
			continue
		if best == null:
			best = o
			continue
		var bdx := absi(best.grid.x - n.grid.x)
		var ody := absi(o.grid.y - n.grid.y)
		var bdy := absi(best.grid.y - n.grid.y)
		if absi(dx) < bdx or (absi(dx) == bdx and ody < bdy):
			best = o
	return best


func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion or event is InputEventMouseButton:
		_mouse_mode = true
	elif event is InputEventKey or event is InputEventJoypadButton \
			or event is InputEventJoypadMotion:
		_mouse_mode = false


# ── Подсказка ─────────────────────────────────────────────────────────────────

func _build_tip() -> void:
	_tip = PanelContainer.new()
	_tip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var st := UiStyle.panel_style(Color(0.06, 0.04, 0.10, 0.97), 10)
	st.border_color = Cfg.RUNE_COLOR
	st.set_border_width_all(2)
	st.content_margin_left = 14.0
	st.content_margin_right = 14.0
	st.content_margin_top = 8.0
	st.content_margin_bottom = 10.0
	_tip.add_theme_stylebox_override("panel", st)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tip.add_child(box)
	_tip_title = UiStyle.label("", 18, UiStyle.FONT_TITLE, UiStyle.GOLD)
	_tip_what = UiStyle.label("", 16, UiStyle.FONT_TEXT, UiStyle.TEXT)
	_tip_need = UiStyle.label("", 15, UiStyle.FONT_TEXT, UiStyle.TEXT_DIM)
	box.add_child(_tip_title)
	box.add_child(_tip_what)
	box.add_child(_tip_need)
	_tip.visible = false
	add_child(_tip)


func show_tip(n: UpgradeNode, denied := false) -> void:
	_tip_node = n
	_tip_title.text = n.tip_title
	_tip_what.text = n.tip_what
	_tip_need.text = n.tip_need
	var need_col := UiStyle.TEXT_DIM
	match n.state:
		UpgradeNode.State.OWNED:
			need_col = UiStyle.GOOD
		UpgradeNode.State.BUYABLE:
			need_col = UiStyle.GOLD
		UpgradeNode.State.POOR:
			need_col = UiStyle.BAD
	if denied:
		need_col = UiStyle.BAD
	_tip_need.add_theme_color_override("font_color", need_col)
	_tip.visible = true
	_tip.reset_size()
	var tip_size := _tip.get_combined_minimum_size()
	var c := n.position + n.circle_center()
	var pos := c + Vector2(UpgradeNode.RADIUS + 14.0, -tip_size.y * 0.5)
	if pos.x + tip_size.x > DESIGN.x - 8.0:
		pos.x = c.x - UpgradeNode.RADIUS - 14.0 - tip_size.x
	pos.y = clampf(pos.y, 8.0, DESIGN.y - tip_size.y - 76.0)
	_tip.position = pos


func hide_tip() -> void:
	_tip_node = null
	_tip.visible = false


func tip_visible_for(n: UpgradeNode) -> bool:
	return _tip.visible and _tip_node == n


func tip_text() -> String:
	return "%s | %s | %s" % [_tip_title.text, _tip_what.text, _tip_need.text]


# ── Рисунок: связи и корни групп (под узлами — _draw родителя идёт раньше детей) ─────────

func _anchor_of(k: String) -> Dictionary:
	var n: UpgradeNode = _by_key.get(k, null)
	if n != null:
		return {"pos": n.position + n.circle_center(), "r": UpgradeNode.RADIUS, "header": false}
	for h in _headers:
		if String(h["key"]) == k:
			return {"pos": h["pos"], "r": HEADER_ICON * 0.5 + 4.0, "header": true}
	return {}


func _draw() -> void:
	for link in _links:
		var a := _anchor_of(String(link[0]))
		var b := _anchor_of(String(link[1]))
		if a.is_empty() or b.is_empty():
			continue
		var to: UpgradeNode = _by_key.get(String(link[1]), null)
		var col := UpgradeNode.LINE_DIM
		var width := 3.0
		if to != null:
			match to.state:
				UpgradeNode.State.OWNED:
					col = UiStyle.GOLD
					width = 4.0
				UpgradeNode.State.BUYABLE, UpgradeNode.State.POOR:
					col = Color(to.accent, 0.8)
		var pa: Vector2 = a["pos"]
		var pb: Vector2 = b["pos"]
		# От узла линия идёт прямо от кольца: цена и подпись узла лежат на тёмных плашках поверх
		# линии, как бирки на нитке; от корня — из-под его подписи.
		var start := pa + Vector2(0.0, float(a["r"]) + (30.0 if bool(a["header"]) else 1.0))
		var stop := pb - Vector2(0.0, float(b["r"]) + 1.0)
		if absf(pa.x - pb.x) < 1.0:
			draw_line(start, stop, col, width, true)
		else:
			# Колено: вниз от корня, вбок к своей цепочке, вниз к узлу — ветвление видно сразу.
			var mid_y := start.y + (stop.y - start.y) * 0.45
			draw_polyline(PackedVector2Array([start, Vector2(start.x, mid_y), Vector2(pb.x, mid_y),
				stop]), col, width, true)

	for h in _headers:
		var p: Vector2 = h["pos"]
		var dim := bool(h.get("dim", false))
		var acc: Color = UpgradeNode.LINE_DIM if dim else h["accent"]
		var r := HEADER_ICON * 0.5 + 6.0
		draw_circle(p, r, Color(0.10, 0.07, 0.16, 0.98))
		draw_arc(p, r, 0.0, TAU, 48, acc, 3.0, true)
		var tex: Texture2D = h["tex"]
		if tex != null:
			draw_texture_rect(tex, Rect2(p - Vector2(HEADER_ICON, HEADER_ICON) * 0.5,
				Vector2(HEADER_ICON, HEADER_ICON)), false,
				Color(0.45, 0.43, 0.5, 0.8) if dim else Color.WHITE)
		if dim:
			var lc := p + Vector2(r * 0.72, r * 0.72)
			draw_circle(lc, 13.0, Color(0.08, 0.06, 0.12))
			draw_texture_rect(UpgradeNode.LOCK_TEX, Rect2(lc - Vector2(12.0, 12.0), Vector2(24.0, 24.0)),
				false)
		draw_string(UiStyle.FONT_TITLE, Vector2(p.x - 110.0, p.y + r + 22.0), String(h["title"]),
			HORIZONTAL_ALIGNMENT_CENTER, 220.0, 19, UiStyle.TEXT_DIM if dim else acc.lightened(0.35))

	for c in _captions:
		var cp: Vector2 = c["pos"]
		draw_string(UiStyle.FONT_TEXT, Vector2(cp.x - 60.0, cp.y), String(c["text"]),
			HORIZONTAL_ALIGNMENT_CENTER, 120.0, 15, UiStyle.TEXT_DIM)


## Состояния узлов поменялись — перерисовать связи (цвет линии — по состоянию узла-цели).
func refresh_links() -> void:
	queue_redraw()
