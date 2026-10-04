class_name PgField
extends RefCounted
##
## Растр раскладки на сетке 16 px (та же, что у A* движка): расстояние до оси ближайшей дороги,
## занятость твёрдым (препятствия, стены, вода) и резерв (участки, рубежи, Котёл, ловушки).
## Зачем свой растр, а не LegionTerrain: генератор ставит сотни пробных предметов, и точное
## «расстояние до всех дорог» по каждой пробе стоило бы десятки миллисекунд; поле расстояний
## считается один раз двумя проходами (распространение ближайшей точки оси, почти евклидово).
##

const CELL := 16
## Шаг выборки оси дороги при посеве поля.
const SEED_STEP := 4.0

## Размер растра — по рамке PgGeom.world на момент build_roads (одиночная карта 80×45 клеток,
## половина PvP 800×900 — 50×57).
var cols := 80
var rows := 45
var road_d := PackedFloat32Array()
var block := PackedByteArray()
var reserve := PackedByteArray()
var _near := PackedVector2Array()


func build_roads(roads: Array) -> void:
	cols = ceili(PgGeom.world.x / CELL)
	rows = ceili(PgGeom.world.y / CELL)
	var n := cols * rows
	road_d.resize(n)
	road_d.fill(INF)
	_near.resize(n)
	_near.fill(Vector2.INF)
	block.resize(n)
	block.fill(0)
	reserve.resize(n)
	reserve.fill(0)
	for road: Dictionary in roads:
		var path: PackedVector2Array = road["pts"]
		for i in range(1, path.size()):
			var a := path[i - 1]
			var b := path[i]
			var steps := maxi(1, ceili(a.distance_to(b) / SEED_STEP))
			for s in steps + 1:
				_seed(a.lerp(b, float(s) / steps))
	_sweep()


func _seed(p: Vector2) -> void:
	var cx := int(floor(p.x / CELL))
	var cy := int(floor(p.y / CELL))
	if cx < 0 or cy < 0 or cx >= cols or cy >= rows:
		return
	var i := cy * cols + cx
	var c := _center(cx, cy)
	var d := c.distance_to(p)
	if d < road_d[i]:
		road_d[i] = d
		_near[i] = p


## Два прохода: вперёд (сосед слева и три сверху) и назад (справа и три снизу) — кандидат
## «ближайшая точка оси соседа» проверяется от центра своей клетки.
func _sweep() -> void:
	var fwd: Array[Vector2i] = [Vector2i(-1, 0), Vector2i(-1, -1), Vector2i(0, -1),
		Vector2i(1, -1)]
	var bwd: Array[Vector2i] = [Vector2i(1, 0), Vector2i(1, 1), Vector2i(0, 1), Vector2i(-1, 1)]
	for y in rows:
		for x in cols:
			_relax(x, y, fwd)
	for y in range(rows - 1, -1, -1):
		for x in range(cols - 1, -1, -1):
			_relax(x, y, bwd)


func _relax(x: int, y: int, dirs: Array[Vector2i]) -> void:
	var i := y * cols + x
	var c := _center(x, y)
	for d in dirs:
		var nx := x + d.x
		var ny := y + d.y
		if nx < 0 or ny < 0 or nx >= cols or ny >= rows:
			continue
		var q := _near[ny * cols + nx]
		if q == Vector2.INF:
			continue
		var dist := c.distance_to(q)
		if dist < road_d[i]:
			road_d[i] = dist
			_near[i] = q


static func _center(x: int, y: int) -> Vector2:
	return Vector2((x + 0.5) * CELL, (y + 0.5) * CELL)


func _cell(p: Vector2) -> Vector2i:
	return Vector2i(clampi(int(floor(p.x / CELL)), 0, cols - 1),
		clampi(int(floor(p.y / CELL)), 0, rows - 1))


## Расстояние от точки до оси ближайшей дороги: через ближайшую точку оси клетки (точнее,
## чем расстояние от центра клетки). Вне кадра — от ближайшей клетки края.
func road_dist(p: Vector2) -> float:
	var c := _cell(p)
	var q := _near[c.y * cols + c.x]
	if q == Vector2.INF:
		return INF
	return p.distance_to(q)


## Минимальное расстояние до дорог по точкам многоугольника и серединам его рёбер.
func poly_road_dist(poly: PackedVector2Array) -> float:
	var best := INF
	for i in poly.size():
		var a := poly[i]
		var b := poly[(i + 1) % poly.size()]
		best = minf(best, minf(road_dist(a), road_dist(a.lerp(b, 0.5))))
	return best


## Отрезок: минимальное расстояние до дорог по выборке.
func seg_road_dist(a: Vector2, b: Vector2, step := 12.0) -> float:
	var n := maxi(1, ceili(a.distance_to(b) / step))
	var best := INF
	for s in n + 1:
		best = minf(best, road_dist(a.lerp(b, float(s) / n)))
	return best


func mark_rect(r: Rect2, grid: PackedByteArray) -> void:
	var a := _cell(r.position)
	var b := _cell(r.end)
	for y in range(a.y, b.y + 1):
		for x in range(a.x, b.x + 1):
			grid[y * cols + x] = 1


func mark_poly(poly: PackedVector2Array, grid: PackedByteArray) -> void:
	var box := PgGeom.poly_box(poly)
	var a := _cell(box.position)
	var b := _cell(box.end)
	for y in range(a.y, b.y + 1):
		for x in range(a.x, b.x + 1):
			if Geometry2D.is_point_in_polygon(_center(x, y), poly):
				grid[y * cols + x] = 1


func mark_circle(c: Vector2, r: float, grid: PackedByteArray) -> void:
	var a := _cell(c - Vector2(r, r))
	var b := _cell(c + Vector2(r, r))
	for y in range(a.y, b.y + 1):
		for x in range(a.x, b.x + 1):
			if _center(x, y).distance_to(c) <= r + CELL * 0.5:
				grid[y * cols + x] = 1


## Полоса вдоль отрезка (рубеж, трасса пролёта): клетки ближе half к отрезку.
func mark_band(a: Vector2, b: Vector2, half: float, grid: PackedByteArray) -> void:
	var box := Rect2(a, Vector2.ZERO).expand(b).grow(half)
	var ca := _cell(box.position)
	var cb := _cell(box.end)
	for y in range(ca.y, cb.y + 1):
		for x in range(ca.x, cb.x + 1):
			var c := _center(x, y)
			if c.distance_to(Geometry2D.get_closest_point_to_segment(c, a, b)) <= half:
				grid[y * cols + x] = 1


func any_rect(r: Rect2, grid: PackedByteArray) -> bool:
	var a := _cell(r.position)
	var b := _cell(r.end)
	for y in range(a.y, b.y + 1):
		for x in range(a.x, b.x + 1):
			if grid[y * cols + x] != 0:
				return true
	return false


func at(p: Vector2, grid: PackedByteArray) -> bool:
	var c := _cell(p)
	return grid[c.y * cols + c.x] != 0


## Свободен ли отрезок от твёрдого (для рубежей и «пролёта поперёк»).
func seg_clear(a: Vector2, b: Vector2, step := 8.0) -> bool:
	var n := maxi(1, ceili(a.distance_to(b) / step))
	for s in n + 1:
		var p := a.lerp(b, float(s) / n)
		if p.x < 0.0 or p.y < 0.0 or p.x >= PgGeom.world.x or p.y >= PgGeom.world.y:
			return false
		if at(p, block):
			return false
	return true


## Центры клеток, где расстояние до дорог в [lo, hi] и нет ни твёрдого, ни резерва.
func open_cells(lo: float, hi: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	for y in rows:
		for x in cols:
			var i := y * cols + x
			if road_d[i] >= lo and road_d[i] <= hi and block[i] == 0 and reserve[i] == 0:
				out.append(_center(x, y))
	return out
