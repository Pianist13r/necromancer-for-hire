class_name RoleReleasePreview
extends RefCounted
## Прицел новых ролей читает ту же геометрию, что выпуск. Золото отмечает ближнее окно
## точного срыва, прозрачный контур — весь путь фронта или последовательного огня.

const LANE_ALPHA := 0.075
const EDGE_ALPHA := 0.65
const LABEL_SIZE := 17
const LABEL_GAP := 23.0
const SAFE_MARGIN := Vector2(18.0, 100.0)


static func handles(kind: StringName) -> bool:
	return kind == LegionCfg.KIND_GUARD or kind == LegionCfg.KIND_CLERK


static func aim(field: ContractField, c: Contract, seg: int, pull: Vector2,
		axis: Vector2, power: float) -> Dictionary:
	var geometries: Array[Dictionary] = []
	var perfect := false
	var cohesive := c.shaped() and not c.ring
	var shared: Dictionary = {}
	if cohesive:
		shared = field.world.role_release_geometry(c, seg, axis, power, true)
	var first := 0 if c.shaped() else seg
	var end := c.seg_count() if c.shaped() else seg + 1
	for s in range(first, end):
		if not c.seg_alive(s):
			continue
		var direction := c.seg_dir(s) if c.ring else axis
		var g := shared if cohesive else field.world.role_release_geometry(c, s, direction, power)
		if not cohesive or geometries.is_empty():
			geometries.append(g)
		var near := float(g["depth"]) * field.world.perfect_zone_frac(field.owner_side)
		var zone_depth := near
		if c.kind == LegionCfg.KIND_GUARD:
			near = minf(near, float(g["clear_depth"]))
			# Передний ряд начинается дальше общей ближней плоскости строя.
			zone_depth = near + _origin_span(g)
		var zone := field.zone_foes(g["center"], g["dir"], g["half_w"], zone_depth)
		if c.figure != ContractShape.TRIANGLE and c.seg_manned(s) > 0 \
				and LegionRoleRelease.strike_clear(field.world, c, s, g["dir"], near, zone, g):
			perfect = true
	var g := shared if cohesive else field.world.role_release_geometry(c, seg,
		c.seg_dir(seg) if c.ring else axis, power)
	return {"dir": g["dir"], "power": power, "pull": pull, "center": g["center"],
		"half_w": g["half_w"], "depth": float(g["depth"])
		* field.world.perfect_zone_frac(field.owner_side), "perfect": perfect,
		"role_geometries": geometries}


static func _origin_span(g: Dictionary) -> float:
	var span := 0.0
	for origin: Vector2 in g["origins"]:
		span = maxf(span, (origin - (g["center"] as Vector2)).dot(g["dir"]))
	return span


static func draw(field: ContractField) -> void:
	var c: Contract = field._grab["contract"]
	var col := field.line_color(c.kind, "core").lerp(Color.WHITE, 0.2)
	var gold := bool(field._aim["perfect"])
	var geometries: Array = field._aim.get("role_geometries", [])
	var blocked := false
	for g: Dictionary in geometries:
		_draw_lane(field, g, col, gold, c.kind)
		blocked = blocked or bool(g["blocked"])
	var center: Vector2 = field._aim["center"]
	field.overlay.draw_dashed_line(center, field._pull, Color(col, 0.7), 2.0, 6.0, true)
	field.overlay.draw_circle(field._pull, 5.0, col)
	_draw_caption(field, c, col, gold, blocked)


static func _draw_lane(field: ContractField, g: Dictionary, col: Color,
		gold: bool, kind: StringName) -> void:
	var from: Vector2 = g["center"]
	var dir: Vector2 = g["dir"]
	var side := dir.orthogonal() * float(g["half_w"])
	var depth := float(g["depth"])
	var clear := float(g["clear_depth"])
	var span := _origin_span(g) if kind == LegionCfg.KIND_GUARD else 0.0
	var to := from + dir * (depth + span)
	var zone := PackedVector2Array([from + side, to + side, to - side, from - side])
	field.overlay.draw_colored_polygon(zone, Color(col, LANE_ALPHA))
	field.overlay.draw_dashed_line(from + side, to + side, Color(col, EDGE_ALPHA), 1.5, 5.0)
	field.overlay.draw_dashed_line(from - side, to - side, Color(col, EDGE_ALPHA), 1.5, 5.0)
	var near := depth * field.world.perfect_zone_frac(field.owner_side)
	var origins: PackedVector2Array = g["origins"]
	var ends: PackedVector2Array = g["ends"]
	if kind == LegionCfg.KIND_GUARD:
		near = minf(near, clear)
	if gold and near > 0.0:
		if kind == LegionCfg.KIND_GUARD and span > LegionCfg.GUARD_FRONT_STEP:
			for origin in origins:
				_gold_zone(field.overlay, origin, dir, dir.orthogonal() * LegionCfg.UNIT_RADIUS, near)
		else:
			_gold_zone(field.overlay, from, dir, side, near)
	if kind == LegionCfg.KIND_GUARD:
		var facings: PackedVector2Array = g["facings"]
		for i in origins.size():
			var final := ends[i]
			field.overlay.draw_dashed_line(origins[i], final, Color(col, 0.35), 1.0, 7.0)
			_shield(field.overlay, final, facings[i], col)
		if span <= LegionCfg.GUARD_FRONT_STEP:
			field.overlay.draw_line(from + dir * clear - side, from + dir * clear + side,
				Color(col, 0.9), 3.0, true)
	else:
		for origin in origins:
			field.overlay.draw_arc(origin, 7.0, 0.0, TAU, 20, col, 2.0, true)
		# Нумеровать каждую полосу в бою шумно: бегущий свет показывает порядок ближе → дальше.
		var bands := LegionCfg.CLERK_BARRAGE_BANDS
		var phase := fmod(FxClock.ms() / 170.0, float(bands))
		for i in bands:
			var at := from + dir * depth * float(i + 1) / float(bands)
			var alpha := 0.85 if i == int(phase) else 0.28
			field.overlay.draw_line(at - side, at + side, Color(col, alpha), 2.0, true)
	_arrow(field.overlay, from + dir * minf(18.0, depth * 0.2),
		from + dir * minf(depth, 75.0), col)
	if bool(g["blocked"]) and kind == LegionCfg.KIND_GUARD:
		for final in ends:
			var lane := dir.orthogonal() * LegionCfg.UNIT_RADIUS
			field.overlay.draw_line(final - lane, final + lane, Color(1.0, 0.45, 0.3), 4.0, true)
	elif bool(g["blocked"]):
		# Огонь обрезается по каждой линии видимости: соседняя открытая полоса идёт дальше.
		for i in origins.size():
			if not clerk_lane_blocked(g, i):
				continue
			var lane := dir.orthogonal() * LegionCfg.CLERK_BARRAGE_LANE_PAD
			field.overlay.draw_line(ends[i] - lane, ends[i] + lane,
				Color(1.0, 0.45, 0.3), 3.0, true)


static func clerk_lane_blocked(g: Dictionary, i: int) -> bool:
	var origin: Vector2 = g["origins"][i]
	var end: Vector2 = g["ends"][i]
	# Передняя полоса короче: её свободный конец всё равно у общей дальней плоскости.
	var projected := (origin - (g["center"] as Vector2)).dot(g["dir"])
	var remaining := maxf(0.0, float(g["depth"]) - projected)
	return bool(g["blocked"]) and origin.distance_to(end) + LegionCfg.GUARD_FRONT_STEP \
		< remaining


static func _gold_zone(canvas: CanvasItem, from: Vector2, dir: Vector2,
		side: Vector2, near: float) -> void:
	var hit := PackedVector2Array([from + side, from + side + dir * near,
		from - side + dir * near, from - side])
	canvas.draw_colored_polygon(hit, Color(LegionCfg.PERFECT_COLOR, 0.19))


static func _shield(canvas: CanvasItem, at: Vector2, facing: Vector2, col: Color) -> void:
	var side := facing.orthogonal() * 7.0
	canvas.draw_line(at - side, at + side, col, 3.0, true)
	canvas.draw_line(at - side, at - side - facing * 5.0, col, 2.0, true)
	canvas.draw_line(at + side, at + side - facing * 5.0, col, 2.0, true)


static func _arrow(canvas: CanvasItem, from: Vector2, to: Vector2, col: Color) -> void:
	var dir := (to - from).normalized()
	var side := dir.orthogonal() * 5.0
	canvas.draw_line(from, to, col, 2.5, true)
	canvas.draw_polyline(PackedVector2Array([to - dir * 9.0 + side, to,
		to - dir * 9.0 - side]), col, 2.5, true)


static func _draw_caption(field: ContractField, c: Contract, col: Color,
		gold: bool, blocked: bool) -> void:
	var label := I18n.t("Щиты идут строем") if c.kind == LegionCfg.KIND_GUARD \
		else I18n.t("Огневой вал · стрелки остаются")
	var limits := LegionCfg.GUARD_FRONT_DEPTH if c.kind == LegionCfg.KIND_GUARD \
		else LegionCfg.CLERK_BARRAGE_DEPTH
	var reach := lerpf(limits.x, limits.y, float(field._aim["power"])) / limits.y
	label += " · " + I18n.t("дальность %d%%") % roundi(reach * 100.0)
	var help := I18n.t("Тяни дальше — длиннее путь. Отпусти — выполнить.")
	if blocked:
		help = I18n.t("Преграда ограничит путь — красная черта.") if c.kind == LegionCfg.KIND_GUARD \
			else I18n.t("Красные отметки — преграды на пути огня.")
	elif gold:
		help = I18n.t("Точно! Отпусти сейчас.")
	var men := c.manned_posts() if c.shaped() else c.seg_manned(int(field._grab["seg"]))
	if c.figure != &"" and not c.charge_ready():
		help = I18n.t("Отпусти — обычный приказ, без эффекта фигуры.")
	if men == 0:
		help = I18n.t("Дождись, пока бойцы займут места.")
	var font: Font = UiStyle.FONT_TITLE
	var size := field._fsz(LABEL_SIZE)
	var lines: Array[String] = [label, help]
	if c.shaped():
		lines.append(ContractField.figure_status(c))
	var width := 0.0
	for text in lines:
		width = maxf(width, font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x)
	var view := field.get_viewport().get_visible_rect()
	# Под горизонтальной полосой, а не поперёк голов и последовательных попаданий.
	var at := field._pull + Vector2(24.0, 72.0)
	if c.shaped():
		for g: Dictionary in field._aim.get("role_geometries", []):
			for key: String in ["origins", "ends"]:
				for point: Vector2 in g[key]:
					at.y = maxf(at.y, point.y + 82.0)
	at.x = clampf(at.x, view.position.x + SAFE_MARGIN.x, view.end.x - width - SAFE_MARGIN.x)
	at.y = clampf(at.y, view.position.y + SAFE_MARGIN.y,
		view.end.y - LABEL_GAP * (lines.size() - 1) - 108.0)
	for text in lines:
		field.overlay.draw_string_outline(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1,
			size, 5, Color(0, 0, 0, 0.9))
		field.overlay.draw_string(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size,
			LegionCfg.PERFECT_COLOR if gold else col)
		at.y += LABEL_GAP
