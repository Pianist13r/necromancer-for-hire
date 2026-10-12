class_name LegionPentagonGuide
extends Node2D
## Добровольная направляющая для свободного штриха. Не создаёт договор и не списывает ману.

const MIN_RADIUS := 65.0
const MAX_RADIUS := 130.0
const STEP := 10.0
const TARGET_R := 18.0
const CORNER_PROBE := 20.0
const CORNER_TURN := 0.75
const GOLD := Color(1.0, 0.78, 0.2, 0.95)
const DIM := Color(1.0, 0.78, 0.2, 0.4)
const BLOCKED := Color(1.0, 0.25, 0.25, 0.8)

var field
var floating := false
var anchored := false
var consume_release := false
var center := Vector2.ZERO
var radius := 85.0
var last_result: StringName = &""
var blocked := false


func _init(owner) -> void:
	field = owner
	z_index = 60


func start(at: Vector2) -> void:
	center = _visible_center(at)
	floating = true
	anchored = false
	consume_release = false
	last_result = &""
	blocked = false
	queue_redraw()


func stop() -> void:
	floating = false
	anchored = false
	consume_release = false
	last_result = &""
	blocked = false
	queue_redraw()


func enabled() -> bool:
	return floating or anchored


func follow(at: Vector2) -> void:
	if floating:
		center = _visible_center(at)
		blocked = false
		queue_redraw()


func resize(up: bool) -> void:
	if enabled() and not field._drawing:
		radius = clampf(radius + (STEP if up else -STEP), MIN_RADIUS, MAX_RADIUS)
		center = _visible_center(center)
		blocked = false
		queue_redraw()


func anchor(at: Vector2) -> void:
	if not floating:
		return
	center = _visible_center(at)
	if not placement_valid():
		blocked = true
		queue_redraw()
		return
	floating = false
	anchored = true
	consume_release = true
	queue_redraw()


func _visible_center(at: Vector2) -> Vector2:
	if field.world == null:
		return at
	var view: Rect2 = field.world.view_rect()
	var pad := radius + 24.0
	return Vector2(clampf(at.x, view.position.x + pad, view.end.x - pad),
		clampf(at.y, view.position.y + pad, view.end.y - pad))


func result(shape: StringName) -> void:
	if anchored:
		last_result = shape
		queue_redraw()


func targets() -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in 5:
		out.append(center + Vector2.from_angle(-PI * 0.5 + TAU * float(i) / 5.0) * radius)
	return out


func placement_valid() -> bool:
	if field.world == null:
		return false
	var pts := targets()
	var terrain: LegionTerrain = field.world.terrain
	for i in 5:
		if not terrain.walkable(pts[i]):
			return false
		if terrain.segment_clear(pts[i], pts[(i + 1) % 5]).distance_to(pts[(i + 1) % 5]) > 1.0:
			return false
	return true


## Цели засчитываются только по последовательному обходу; круг, прошедший внутри углов,
## остаётся кругом. Подсказка не влияет на ContractShape.classify.
func corners_seen(stroke: PackedVector2Array) -> int:
	var points := targets()
	var at := 0
	for corner in 5:
		var found := -1
		for i in range(at, stroke.size()):
			if stroke[i].distance_to(points[corner]) > TARGET_R:
				continue
			if corner > 0 and not _turns_at(stroke, i):
				continue
			found = i
			break
		if found < 0:
			return corner
		at = found + 1
	return 5


static func _turns_at(stroke: PackedVector2Array, at: int) -> bool:
	var before := at - 1
	while before >= 0 and stroke[before].distance_to(stroke[at]) < CORNER_PROBE:
		before -= 1
	var after := at + 1
	while after < stroke.size() and stroke[after].distance_to(stroke[at]) < CORNER_PROBE:
		after += 1
	if before < 0 or after >= stroke.size():
		return false
	return absf((stroke[at] - stroke[before]).angle_to(stroke[after] - stroke[at])) \
		>= CORNER_TURN


func _process(_dt: float) -> void:
	visible = enabled() and field.world != null and not field.world.paused \
		and field.world.phase == LegionWorld.Phase.BATTLE
	if visible:
		queue_redraw()


func _draw() -> void:
	if not enabled():
		return
	var pts := targets()
	var valid := placement_valid()
	var stroke: PackedVector2Array = field._draft if field._drawing else PackedVector2Array()
	var seen := corners_seen(stroke)
	var outline := pts.duplicate()
	outline.append(pts[0])
	draw_polyline(outline, DIM if valid else BLOCKED, 2.0, true)
	var font := ThemeDB.fallback_font
	for i in 5:
		var hit := i < seen
		draw_circle(pts[i], 10.0, GOLD if hit else Color(0.12, 0.08, 0.12, 0.85))
		draw_arc(pts[i], 10.0, 0.0, TAU, 24, GOLD if valid else BLOCKED, 2.0, true)
		draw_string(font, pts[i] + Vector2(-5.0, 5.0), str(i + 1),
			HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color.WHITE)
	var hint := ""
	if floating and (blocked or not valid):
		hint = I18n.t("Здесь стена: сдвиньте ориентиры или уменьшите размер")
	elif floating:
		hint = I18n.t("Колесо — размер · щелчок — закрепить")
	elif field._drawing:
		var shape := ContractShape.classify(stroke)
		var result_name := I18n.t("Комиссия") if shape == ContractShape.PENTAGON else \
			I18n.t("Оцепление") if shape == ContractShape.RING else I18n.t("Пока линия")
		hint = I18n.t("Углы %d/5 · %s") % [seen, result_name]
		if seen == 5 and stroke.size() > 1 and stroke[stroke.size() - 1].distance_to(stroke[0]) \
				> ContractShape.FIG_GAP_MIN:
			hint += " · " + I18n.t("замкните у начала")
	elif last_result != &"":
		hint = I18n.t("Получилось: Комиссия") if last_result == ContractShape.PENTAGON else \
			I18n.t("Получилось кольцо · проведите ближе к пяти углам") if last_result == \
			ContractShape.RING else I18n.t("Фигура не распознана · повторите по углам")
	else:
		hint = Controls.text(I18n.t(
			"ЛКМ: обведите 1–5 и замкните · Esc — выход"))
	var view: Rect2 = field.world.view_rect()
	var y := center.y + radius + 40.0
	if y > view.end.y - 84.0:
		y = center.y - radius - 24.0
	var width := font.get_string_size(hint, HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x
	var x := clampf(center.x - radius, view.position.x + 12.0,
		view.end.x - width - 12.0)
	draw_string(font, Vector2(x, y), hint,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color.WHITE)
