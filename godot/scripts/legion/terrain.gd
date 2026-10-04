class_name LegionTerrain
extends RefCounted
##
## Логика рельефа карты: скалы, вода, мосты, болото — сетка клеток CELL px и A* по ней.
## Отрисовка — не здесь (TerrainView пакета MAPS или серая подложка мира).
##
## Почему AStarGrid2D, а не свой A*: поиск на C++ стоит микросекунды, а раздача мест дёргает
## его десятками раз за тик на старте боя. Полигоны при этом хранятся точно: скала режет
## штрих руны по контуру, а не по клеткам 32 px (иначе руна обрывалась бы за 30 px до камня).
##

const F_ROCK := 1
const F_WATER := 2
const F_BRIDGE := 4
const F_SWAMP := 8

## Размер мира карты (map.size; одиночка — LegionCfg.WORLD_SIZE): сетка и край «за кадром».
var size := LegionCfg.WORLD_SIZE
var cols := 0
var rows := 0
## Все непроходимые твёрдые препятствия полигонами: скалы карты и контуры её тонких стен.
var rocks: Array[PackedVector2Array] = []
## v19 «стены по рисунку» (медленная сессия d26f8623; Игорь 26.09: «каменная стена, а через
## неё юниты проходят свободно… через препятствия, которые выглядят как препятствие, проходить
## не могли», на всех уровнях). Каменные стены и ограды — ломаные с толщиной: так их проще
## обвести по рисунку, чем полигонами. {"path": PackedVector2Array, "w": float, "kind": String}.
## Их контуры лежат и в rocks — для штриха руны, проверки проходимости и подсветки это одно.
var walls: Array[Dictionary] = []
var water: Array[PackedVector2Array] = []
var bridges: Array[PackedVector2Array] = []
var swamp: Array[PackedVector2Array] = []

## Поле «Схватки» (в карте больше одной стороны, ширина кратна CELL): клетка точки правой
## половины считается от правого края (B-290). Точка ровно на границе клеток (x кратен 16 —
## а Котлы, участки и проёмы процгена стоят на сетке 16) иначе попадала бы в клетку справа от
## себя на обеих половинах, т. е. у стороны 1 — не в отражение клетки стороны 0: путь A* от её
## Котла к чужому не был отражением пути стороны 0 (gen:7:3:pvp — 1070 px против 1084). Одиночка
## — false.
var mirror_x := false
var _flags := PackedByteArray()
var _astar := AStarGrid2D.new()
## v19: номер связной области проходимых клеток (-1 — клетка непроходима). Вербовка спрашивает
## «дойдёт ли боец до места» сотни раз за раздачу; на сетке 16 px A* на каждый вопрос стоил
## +60 % к раздаче (legion_recruit_test, плотная армия: 40 → 65 мс). Одна область — путь есть.
var _comp := PackedInt32Array()


## Размер мира карты: поле `size` [W, H] (PvP, docs/pvp/DESIGN.md §3.3), иначе 1280×720.
static func map_size(map: Dictionary) -> Vector2:
	var s: Array = map.get("size", [])
	if s.size() >= 2:
		return Vector2(float(s[0]), float(s[1]))
	return LegionCfg.WORLD_SIZE


## Поле «Схватки» из половины и её зеркала x' = W − x (PvpMaps, PgPvp): ширина поля W — рисунок
## земли кладётся на половину стороны 0 и отражается, чтобы стороны выглядели одинаково и стык
## не давал шва (P5b). Не зеркальное поле (одиночка) — 0.
static func mirror_width(map: Dictionary) -> float:
	var pg: Variant = map.get("procgen", {})
	if map.has("pvp") or (pg is Dictionary and (pg as Dictionary).has("pvp")):
		return map_size(map).x
	return 0.0


func setup(map: Dictionary) -> LegionTerrain:
	rocks = _polys(map.get("rocks", []))
	walls = _walls(map.get("walls", []))
	for wl in walls:
		rocks.append_array(_wall_polys(wl))
	rocks = _clear_roads(rocks, map.get("roads", []))
	water = _polys(map.get("water", []))
	bridges = _polys(map.get("bridges", []))
	swamp = _polys(map.get("swamp", []))
	size = map_size(map)
	cols = ceili(size.x / LegionCfg.CELL)
	rows = ceili(size.y / LegionCfg.CELL)
	mirror_x = (map.get("sides", []) as Array).size() > 1 \
		and is_equal_approx(float(cols * LegionCfg.CELL), size.x)
	_flags.resize(cols * rows)
	_astar.region = Rect2i(0, 0, cols, rows)
	_astar.cell_size = Vector2(LegionCfg.CELL, LegionCfg.CELL)
	_astar.offset = Vector2(LegionCfg.CELL, LegionCfg.CELL) * 0.5
	_astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	_astar.default_compute_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	_astar.update()
	var boxes := _boxes(rocks)
	for y in rows:
		for x in cols:
			# правая половина поля «Схватки» — по отражённой клетке (то же, что is_rock, B-365)
			var mx := cols - 1 - x if mirror_x and x >= cols / 2 else x
			var c := Vector2((mx + 0.5) * LegionCfg.CELL, (y + 0.5) * LegionCfg.CELL)
			var f := 0
			if _inside_boxed(rocks, boxes, c):
				f |= F_ROCK
			if _inside_any(water, c):
				f |= F_WATER
			if _inside_any(bridges, c):
				f |= F_BRIDGE
			if _inside_any(swamp, c):
				f |= F_SWAMP
			_flags[y * cols + x] = f
			var cell := Vector2i(x, y)
			_astar.set_point_solid(cell, not _flag_walkable(f))
			if f & F_SWAMP:
				_astar.set_point_weight_scale(cell, LegionCfg.SWAMP_WEIGHT)
	_label_regions()
	return self


## Связные области по четырём соседям. Путь A* (диагональ — только если оба соседа по осям
## открыты) существует ровно тогда, когда клетки в одной области.
func _label_regions() -> void:
	_comp.resize(cols * rows)
	_comp.fill(-1)
	var region := 0
	for start in cols * rows:
		if _comp[start] != -1 or not _flag_walkable(_flags[start]):
			continue
		_comp[start] = region
		var stack := PackedInt32Array([start])
		while not stack.is_empty():
			var k := stack[stack.size() - 1]
			stack.resize(stack.size() - 1)
			var x := k % cols
			var y := k / cols
			for n: int in [k - 1 if x > 0 else -1, k + 1 if x < cols - 1 else -1,
					k - cols if y > 0 else -1, k + cols if y < rows - 1 else -1]:
				if n >= 0 and _comp[n] == -1 and _flag_walkable(_flags[n]):
					_comp[n] = region
					stack.append(n)
		region += 1


## Сама p, если проходима; иначе ближайшая к ней точка проходимой земли (в клетке, на 1 px от
## края) на любой глубине; INF — на карте нет земли. Кольца клеток вокруг p, пока следующее кольцо
## не станет заведомо дальше найденного (ближняя точка клетки кольца R — не ближе (R−1)·CELL).
## Для «Сбора» по курсору на ограде и для врага, попавшего в скалу (foe.gd _in_rock). Не
## _nearest_open: тот берёт первую открытую клетку по порядку обхода и ищет лишь в 5 клетках
## (verifier d26f8623: земля в 10 px, а ответ — клетка в 30 px; из угла скалы враг не выходил).
func nearest_open(p: Vector2) -> Vector2:
	if walkable(p):
		return p
	var c := cell_of(p)
	var best := Vector2.INF
	var best_d := INF
	# равные по расстоянию клетки: первая по обходу; в правой половине «Схватки» — зеркально (B-292)
	var sx := -1 if mirror_x and c.x >= cols / 2 else 1
	for r in range(1, maxi(cols, rows)):
		if best_d < INF and float(r - 1) * LegionCfg.CELL > sqrt(best_d):
			break
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if maxi(absi(dx), absi(dy)) != r:
					continue
				var n := c + Vector2i(dx * sx, dy)
				if n.x < 0 or n.y < 0 or n.x >= cols or n.y >= rows \
						or not _flag_walkable(_flags[n.y * cols + n.x]):
					continue
				var lo := Vector2(n) * LegionCfg.CELL + Vector2.ONE
				var q := p.clamp(lo, lo + Vector2.ONE * (LegionCfg.CELL - 2.0))
				var d := p.distance_squared_to(q)
				if d < best_d:
					best_d = d
					best = q
	return best


## Дойдёт ли пеший от a до b (обе точки проходимы и в одной связной области).
func connected(a: Vector2, b: Vector2) -> bool:
	var ca := cell_of(a)
	var cb := cell_of(b)
	var ra := _comp[ca.y * cols + ca.x]
	return ra >= 0 and ra == _comp[cb.y * cols + cb.x]


static func _polys(src: Array) -> Array[PackedVector2Array]:
	var out: Array[PackedVector2Array] = []
	for poly in src:
		var p := PackedVector2Array()
		for pt in poly:
			p.append(Vector2(float(pt[0]), float(pt[1])))
		out.append(p)
	return out


## Толщина стены — больше клетки (WALL_MIN_W): клетка непроходима, если её центр внутри
## препятствия, и полоса уже клетки могла бы лечь между рядами центров — ограда в 6 px
## пропускала бы сквозь себя. Ровно в клетку тоже нельзя: края полосы ложатся точно на центры
## клеток, и на границе «внутри или нет» решает случай (гейт 26.09: ограда y = 112 то держала,
## то нет). Стены на картах идут вдоль осей; на косой стене пошаговый ход мог бы проскочить угол
## двух непроходимых клеток — такие обводить скалой-полигоном.
static func _walls(src: Array) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for raw: Dictionary in src:
		var path := PackedVector2Array()
		for pt in raw.get("path", []):
			path.append(Vector2(float(pt[0]), float(pt[1])))
		if path.size() < 2:
			continue
		out.append({"path": path,
			"w": maxf(float(raw.get("w", LegionCfg.WALL_MIN_W)), LegionCfg.WALL_MIN_W),
			"kind": String(raw.get("kind", "stone"))})
	return out


## Контур стены: прямые углы на изломах, торцы — ровно по концам ломаной (концы стен у дорог
## обведены впритык, лишний выступ торца лёг бы на проезжую часть).
static func _wall_polys(wl: Dictionary) -> Array[PackedVector2Array]:
	var out: Array[PackedVector2Array] = []
	var polys := Geometry2D.offset_polyline(wl["path"], float(wl["w"]) * 0.5,
		Geometry2D.JOIN_MITER, Geometry2D.END_BUTT)
	for poly in polys:
		# у простой ломаной дыр нет, но на петле offset вернул бы и дыру — её не берём
		if polys.size() > 1 and _inside_other(poly, polys):
			continue
		out.append(poly)
	return out


## Проезжая часть неприкосновенна: скалы и стены подрезаются полосой ROAD_CLEAR от оси дороги.
## Оси дорог в картах местами на 5–8 px в стороне от нарисованной дороги, а коридоры
## «Лабиринта» — ~50 px от стены до стены; клетка 16 px добавляет до 11 px к краю. Без подрезки
## стена по рисунку закрывала край дороги (±23 px), и колонна шла бы гуськом. Подсветка
## (ObstacleHint) рисует уже подрезанные контуры — ровно то, что держит бойцов.
static func _clear_roads(polys: Array[PackedVector2Array],
		roads: Array) -> Array[PackedVector2Array]:
	var bands: Array[PackedVector2Array] = []
	for road: Dictionary in roads:
		var path := PackedVector2Array()
		for pt in road.get("path", []):
			path.append(Vector2(float(pt[0]), float(pt[1])))
		if path.size() >= 2:
			bands.append_array(Geometry2D.offset_polyline(path, LegionCfg.ROAD_CLEAR,
				Geometry2D.JOIN_ROUND, Geometry2D.END_ROUND))
	var out: Array[PackedVector2Array] = []
	for poly in polys:
		var pieces: Array[PackedVector2Array] = [poly]
		for band in bands:
			var rest: Array[PackedVector2Array] = []
			for piece in pieces:
				# дорога сквозь скалу оставила бы дыру — её не берём (такой карты нет, это
				# ловит legion_maps_test: «дорога и её края проходимы»)
				var parts := Geometry2D.clip_polygons(piece, band)
				for part in parts:
					if part.size() >= 3 and not (parts.size() > 1 and _inside_other(part, parts)):
						rest.append(part)
			pieces = rest
		out.append_array(pieces)
	return out


static func _inside_other(poly: PackedVector2Array, polys: Array[PackedVector2Array]) -> bool:
	for other in polys:
		if other != poly and Geometry2D.is_point_in_polygon(poly[0], other):
			return true
	return false


static func _boxes(polys: Array[PackedVector2Array]) -> Array[Rect2]:
	var out: Array[Rect2] = []
	for poly in polys:
		var box := Rect2(poly[0], Vector2.ZERO)
		for p in poly:
			box = box.expand(p)
		# правый и нижний край Rect2.has_point не считает — запас, чтобы решал сам контур
		out.append(box.grow(1.0))
	return out


## Как _inside_any, но сперва рамка: разметка 3600 клеток по двум десяткам контуров.
static func _inside_boxed(polys: Array[PackedVector2Array], boxes: Array[Rect2],
		p: Vector2) -> bool:
	for i in polys.size():
		if boxes[i].has_point(p) and Geometry2D.is_point_in_polygon(p, polys[i]):
			return true
	return false


static func _inside_any(polys: Array[PackedVector2Array], p: Vector2) -> bool:
	for poly in polys:
		if Geometry2D.is_point_in_polygon(p, poly):
			return true
	return false


static func _flag_walkable(f: int) -> bool:
	if f & F_ROCK:
		return false
	if f & F_WATER and not (f & F_BRIDGE):
		return false
	return true


func cell_of(p: Vector2) -> Vector2i:
	var cx := int(p.x / LegionCfg.CELL)
	if mirror_x and p.x > size.x * 0.5:
		cx = cols - 1 - int((size.x - p.x) / LegionCfg.CELL)
	return Vector2i(clampi(cx, 0, cols - 1), clampi(int(p.y / LegionCfg.CELL), 0, rows - 1))


func _flags_at(p: Vector2) -> int:
	# за краем экрана (ворота) — чистое поле: враги выходят из-за кадра по дороге
	if p.x < 0.0 or p.y < 0.0 or p.x >= size.x or p.y >= size.y:
		return 0
	var c := cell_of(p)
	return _flags[c.y * cols + c.x]


## Точная проверка по полигонам: руна режется о контур скалы. Поле «Схватки» (mirror_x): точка
## правой половины проверяется отражённой по левой (B-365) — края скал у дорог вырезает Clipper
## (Geometry2D.offset_polyline/clip_polygons), и его контуры половин расходятся на сотые доли px:
## точка в такой щели была скалой слева и землёй справа (штрих и рождение у двери площадки шли
## по-разному). W − x для x ≥ W/2 во float точно.
func is_rock(p: Vector2) -> bool:
	if mirror_x and p.x > size.x * 0.5:
		p = Vector2(size.x - p.x, p.y)
	return _inside_any(rocks, p)


## Проходимость для пеших (бойцы и вся пехота, кроме призрака). По сетке: дёшево в кадре.
func walkable(p: Vector2) -> bool:
	return _flag_walkable(_flags_at(p))


func speed_mult(p: Vector2) -> float:
	return LegionCfg.SWAMP_MULT if _flags_at(p) & F_SWAMP else 1.0


## Докуда можно провести отрезок a→b, не задев скалу: возвращает последнюю чистую точку
## (a, если скала уже у самого начала). Шаг CLIP_STEP — точность обрыва руны у камня.
func segment_clear(a: Vector2, b: Vector2) -> Vector2:
	var d := a.distance_to(b)
	if d <= 0.0:
		return a
	var steps := maxi(1, ceili(d / LegionCfg.CLIP_STEP))
	var last := a
	for i in range(1, steps + 1):
		var p := a.lerp(b, float(i) / float(steps))
		if is_rock(p):
			return last
		last = p
	return b


## Путь A* для пешего от from до to. Концы вне проходимых клеток притягиваются к ближайшей
## проходимой; последняя точка — сам to (боец встаёт точно на место, а не в центр клетки).
func find_path(from: Vector2, to: Vector2) -> PackedVector2Array:
	var a := _nearest_open(cell_of(from))
	var b := _nearest_open(cell_of(to))
	var path := cell_path(a, b)
	if path.size() > 0:
		path.remove_at(0)
	path.append(to)
	return path


## Путь A* между клетками (центры клеток, первая — a). На поле «Схватки» (mirror_x) запрос из
## правой половины решается отражённым и отражается обратно (B-292): из равных по цене путей
## AStarGrid2D выбирает по порядку соседей, а он не зеркален — проверяющие и бойцы сторон шли
## разными обходами (серия P3: на gen:11:3:pvp левая половина 17 побед из 20 при тяжёлых волнах).
func cell_path(a: Vector2i, b: Vector2i) -> PackedVector2Array:
	if not mirror_x or a.x < cols / 2:
		return _astar.get_point_path(a, b)
	var path := _astar.get_point_path(_mirror_cell(a), _mirror_cell(b))
	for i in path.size():
		path[i].x = size.x - path[i].x
	return path


func _mirror_cell(c: Vector2i) -> Vector2i:
	return Vector2i(cols - 1 - c.x, c.y)


func _nearest_open(c: Vector2i) -> Vector2i:
	if not _astar.is_point_solid(c):
		return c
	# обход соседей слева направо; в правой половине поля «Схватки» — зеркально (B-292)
	var sx := -1 if mirror_x and c.x >= cols / 2 else 1
	for r in range(1, 6):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				var n := c + Vector2i(dx * sx, dy)
				if _astar.is_in_boundsv(n) and not _astar.is_point_solid(n):
					return n
	return c
