class_name PgGeom
extends RefCounted
##
## Геометрия процгена: ломаные, расстояния, отражения, сглаженные «кляксы» для воды и топи.
## Всё статическое и без случайности (кроме blob — он берёт rng снаружи).
##

## Кадр одиночной карты (экран без камеры). Умолчание рамки ниже.
const WORLD := Vector2(1280.0, 720.0)
const GRID := 16
## Прямоугольники HUD (BOOK §7 У-6, У-13): превью волны, карточки видов, способности, плюс
## верхняя строка «Котёл · Мана · Армия · Души · Волна» (x 0–815, y 0–48 — кадр corr-play
## gen:2:3; в списке §7 её не было, B-101). Превью волны — до y 200: панель растёт с составом
## волны (замер 27.09: 4 вида — 217, 6 видов — до 309); её делают компактной (≤ 200) в линии
## HUD, решение координатора — зона 960–1280 × 0–200.
const HUD_RECTS: Array[Rect2] = [Rect2(960, 0, 320, 200), Rect2(340, 630, 600, 90),
	Rect2(960, 630, 320, 90), Rect2(0, 0, 820, 50)]
## Свободные отрезки края для ворот (§7 У-6), с отступом от углов ≥ 60 px. Справа — ниже
## превью волны (y ≥ 200); сверху — от 820, а не 780 книги: плашка статов кончается на x 812.
const GATE_SPANS := {"west": Vector2(60, 660), "east": Vector2(200, 620),
	"north": Vector2(820, 950), "south": Vector2(60, 320)}
## Половина ширины ворот: центр ворот не ближе этого к концу свободного отрезка.
const GATE_HALF := 32.0

## Рамка, в которой сейчас идёт раскладка (размер мира, HUD и свободные отрезки края в
## координатах мира). Одиночная карта — умолчание (ровно константы выше: те же числа → тот же
## словарь); половина PvP (PgPvp) ставит свою рамку на время раскладки и сразу возвращает
## умолчание. Статическое состояние, а не параметр в каждой функции: иначе пришлось бы
## протащить рамку через все шаги раскладки ради одного режима. Генерация однопоточная.
static var world := WORLD
static var hud: Array[Rect2] = HUD_RECTS
static var spans: Dictionary = GATE_SPANS


static func set_frame(size: Vector2, hud_rects: Array[Rect2], gate_spans: Dictionary) -> void:
	world = size
	hud = hud_rects
	spans = gate_spans


static func reset_frame() -> void:
	set_frame(WORLD, HUD_RECTS, GATE_SPANS)


static func snap(p: Vector2) -> Vector2:
	return Vector2(roundi(p.x / GRID) * GRID, roundi(p.y / GRID) * GRID)


static func length(path: PackedVector2Array) -> float:
	var s := 0.0
	for i in range(1, path.size()):
		s += path[i].distance_to(path[i - 1])
	return s


static func point_at(path: PackedVector2Array, at: float) -> Vector2:
	var left := at
	for i in range(1, path.size()):
		var seg := path[i].distance_to(path[i - 1])
		if left <= seg and seg > 0.0:
			return path[i - 1].lerp(path[i], left / seg)
		left -= seg
	return path[-1]


## Касательная (направление движения врага) в точке на расстоянии at от начала.
static func tangent_at(path: PackedVector2Array, at: float) -> Vector2:
	var left := at
	for i in range(1, path.size()):
		var seg := path[i].distance_to(path[i - 1])
		if left <= seg and seg > 0.0:
			return (path[i] - path[i - 1]) / seg
		left -= seg
	return (path[-1] - path[-2]).normalized() if path.size() >= 2 else Vector2.RIGHT


## Индекс отрезка и отступ вдоль пути до его начала для точки at.
static func seg_at(path: PackedVector2Array, at: float) -> Vector2i:
	var left := at
	var acc := 0.0
	for i in range(1, path.size()):
		var seg := path[i].distance_to(path[i - 1])
		if left <= seg:
			return Vector2i(i - 1, int(acc))
		left -= seg
		acc += seg
	return Vector2i(path.size() - 2, int(acc))


## Расстояние вдоль пути до ближайшей к p точки ломаной.
static func project(path: PackedVector2Array, p: Vector2) -> float:
	var best := INF
	var best_at := 0.0
	var acc := 0.0
	for i in range(1, path.size()):
		var q := Geometry2D.get_closest_point_to_segment(p, path[i - 1], path[i])
		var d := p.distance_squared_to(q)
		if d < best:
			best = d
			best_at = acc + path[i - 1].distance_to(q)
		acc += path[i].distance_to(path[i - 1])
	return best_at


static func dist_to_path(p: Vector2, path: PackedVector2Array) -> float:
	var best := INF
	for i in range(1, path.size()):
		best = minf(best, p.distance_to(
			Geometry2D.get_closest_point_to_segment(p, path[i - 1], path[i])))
	return best


static func seg_dist(a: Vector2, b: Vector2, c: Vector2, d: Vector2) -> float:
	if Geometry2D.segment_intersects_segment(a, b, c, d) != null:
		return 0.0
	return minf(minf(a.distance_to(Geometry2D.get_closest_point_to_segment(a, c, d)),
		b.distance_to(Geometry2D.get_closest_point_to_segment(b, c, d))),
		minf(c.distance_to(Geometry2D.get_closest_point_to_segment(c, a, b)),
		d.distance_to(Geometry2D.get_closest_point_to_segment(d, a, b))))


## Часть пути, видимая в кадре: [at входа, at выхода] (ворота — первая точка в кадре).
static func visible_range(path: PackedVector2Array) -> Vector2:
	var frame := Rect2(Vector2.ZERO, world)
	var total := length(path)
	var first := -1.0
	var step := 8.0
	var at := 0.0
	while at <= total:
		if frame.has_point(point_at(path, at)):
			first = at
			break
		at += step
	return Vector2(maxf(first, 0.0), total)


## Точка ворот — где дорога входит в кадр.
static func gate_point(path: PackedVector2Array) -> Vector2:
	var p0 := path[0]
	var p1 := path[1]
	var t := 0.0
	if p0.x < 0.0:
		t = (0.0 - p0.x) / (p1.x - p0.x)
	elif p0.x > world.x:
		t = (p0.x - world.x) / (p0.x - p1.x)
	elif p0.y < 0.0:
		t = (0.0 - p0.y) / (p1.y - p0.y)
	elif p0.y > world.y:
		t = (p0.y - world.y) / (p0.y - p1.y)
	return p0.lerp(p1, clampf(t, 0.0, 1.0))


static func gate_side(path: PackedVector2Array) -> String:
	var p := path[0]
	if p.x < 0.0:
		return "west"
	if p.x > world.x:
		return "east"
	if p.y < 0.0:
		return "north"
	return "south"


## Ворота на свободном отрезке края (У-6).
static func gate_ok(path: PackedVector2Array) -> bool:
	var side := gate_side(path)
	var g := gate_point(path)
	var span: Vector2 = spans[side]
	var v := g.y if side == "west" or side == "east" else g.x
	return v >= span.x + GATE_HALF and v <= span.y - GATE_HALF


static func in_hud(p: Vector2, margin := 0.0) -> bool:
	for r in hud:
		if r.grow(margin).has_point(p):
			return true
	return false


static func mirror_x(p: Vector2) -> Vector2:
	return Vector2(world.x - p.x, p.y)


static func flip_y(p: Vector2) -> Vector2:
	return Vector2(p.x, world.y - p.y)


static func map_points(src: PackedVector2Array, mirror: bool, flip: bool) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in src:
		var q := p
		if mirror:
			q = mirror_x(q)
		if flip:
			q = flip_y(q)
		out.append(q)
	# отражение меняет обход многоугольника — для полигонов это не важно, для путей порядок
	# точек сохраняется (враг идёт от ворот к Котлу)
	return out


## Скруглённая «клякса» вокруг прямоугольника: центр, полуоси, дрожь краёв.
static func blob(center: Vector2, half: Vector2, rng: RandomNumberGenerator, n := 12,
		jitter := 0.12) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in n:
		var a := TAU * float(i) / float(n)
		var k := 1.0 + rng.randf_range(-jitter, jitter)
		out.append((center + Vector2(cos(a) * half.x, sin(a) * half.y) * k).round())
	return out


## Та же клякса, повёрнутая по направлению dir (вдоль дороги).
static func blob_along(center: Vector2, dir: Vector2, half: Vector2,
		rng: RandomNumberGenerator, n := 12) -> PackedVector2Array:
	var out := PackedVector2Array()
	var nrm := dir.orthogonal()
	for i in n:
		var a := TAU * float(i) / float(n)
		var k := 1.0 + rng.randf_range(-0.1, 0.1)
		out.append((center + dir * cos(a) * half.x * k + nrm * sin(a) * half.y * k).round())
	return out


static func rect_poly(r: Rect2) -> PackedVector2Array:
	return PackedVector2Array([r.position, Vector2(r.end.x, r.position.y), r.end,
		Vector2(r.position.x, r.end.y)])


static func poly_box(poly: PackedVector2Array) -> Rect2:
	var box := Rect2(poly[0], Vector2.ZERO)
	for p in poly:
		box = box.expand(p)
	return box


## Зазор между прямоугольниками (0 — касаются или пересекаются).
static func box_gap(a: Rect2, b: Rect2) -> float:
	var dx := maxf(0.0, maxf(a.position.x - b.end.x, b.position.x - a.end.x))
	var dy := maxf(0.0, maxf(a.position.y - b.end.y, b.position.y - a.end.y))
	return Vector2(dx, dy).length()


static func arr(p: Vector2) -> Array:
	return [int(round(p.x)), int(round(p.y))]


static func arr_path(path: PackedVector2Array) -> Array:
	var out: Array = []
	for p in path:
		out.append(arr(p))
	return out


## Угол поворота в вершине i ломаной (0 — прямо).
static func turn_at(path: PackedVector2Array, i: int) -> float:
	if i <= 0 or i >= path.size() - 1:
		return 0.0
	return absf((path[i] - path[i - 1]).angle_to(path[i + 1] - path[i]))
