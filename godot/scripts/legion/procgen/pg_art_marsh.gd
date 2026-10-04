class_name PgArtMarsh
extends RefCounted
## Топь (проходимая, ×0,5) на карте биома, кроме «Болота»: настоящая картинка вместо плоской
## полупрозрачной заливки (gen-art-polish, 03.10.2026, D-1003-06).
##
## Что было: PgArtCanvas._marsh на пустыре/кладбище/стройке/конторе лил в полигон цвет с
## альфой 0,74 — тёмная «капсула» или «Н» без рисунка поверх дороги и земли (gen:4:12,
## gen:10:3). На «Болоте» топь — бирюзовая заводь как на нарисованном фоне, её код не трогаем.
##
## Что теперь (только узлы, не draw_*: текстуры в draw_* внутри вложенного SubViewport дают
## белый кадр): мокрая кайма → тело — подложка карты, затемнённая и окрашенная жижей биома
## (Polygon2D с текстурой подложки) → блики сверху → «мозаика» спрайтов библиотеки жижи
## (пятна масла/цемента/лужи) внутри полигона и по кромке. Словарь карты не меняется, свой
## ГСЧ от id карты и координат полигона.

const WET := Color(0.08, 0.07, 0.04, 0.22)
const WET_GROW := 5.0
const WARP_AMP := 6.0 ## размах неровности края (px), см. _warp
const WARP_STEP := 12.0
const ZONE_ALPHA := 0.72 ## непрерывная мокрая земля показывает всю зону замедления
const SMOOTH := 7.0 ## скругление контура: выступы и впадины радиусом SMOOTH
const FEATHER := [1.5, 3.5] ## мягкая кромка — слои шире тела, альфа падает
## Жижа биома: цвет тела, доля подложки (0 — гладкая заливка), спрайты библиотеки.
const LOOK := {
	"ash": {"col": Color("1b1520"), "mix": 0.25, "items": ["under_dec_oil"],
		"edge": ["ash_dec_burn"], "tint": Color("b69ad0"), "edge_tint": Color("d8c0e8")},
	"grave": {"col": Color("172a24"), "mix": 0.25, "items": ["swamp_dec_puddle"],
		"edge": ["swamp_dec_moss"], "tint": Color("86a89a"), "edge_tint": Color.WHITE},
	# стройка и контора: тёмная жижа цвета земли, без мха и зелени, края не обрамлены спрайтами
	"site": {"col": Color("46331f"), "mix": 0.5, "items": ["under_dec_oil"],
		"edge": [], "tint": Color("8a6a4c"), "edge_tint": Color.WHITE},
	"office": {"col": Color("2d1d12"), "mix": 0.5, "items": ["under_dec_oil"],
		"edge": [], "tint": Color("9a7452"), "edge_tint": Color.WHITE},
}
const LOOK_DEFAULT := {"col": Color("22212a"), "mix": 0.25, "items": ["under_dec_oil"],
	"edge": ["under_dec_oil"], "tint": Color.WHITE, "edge_tint": Color.WHITE}
const BODY_ALPHA := 0.97
const SHEEN_INSET := [9.0, 20.0]
const SHEEN_ALPHA := [0.10, 0.08]
const STEP := 34.0 ## шаг сетки пятен внутри, мир px
const CHANCE := 0.5 ## доля узлов сетки с пятном
const SPRITE_W := Vector2(30.0, 62.0)
const EDGE_STEP := 22.0
const EDGE_W := Vector2(22.0, 38.0)
const RIM := Color(0.05, 0.04, 0.06, 0.55)
const RIM_W := 2.0


## Рисует ли PgArtMarsh топь карты этого биома (иначе — код PgArtCanvas: бирюзовая заводь «Болота»).
static func covers(biome: String) -> bool:
	return biome != "swamp"


## Топь под parent (мировые px). Возвращает число спрайтов жижи.
static func build(parent: Node2D, map: Dictionary, ground_tex: Texture2D) -> int:
	var biome := String(map.get("biome", map.get("theme", "grave")))
	if biome == "swamp":
		return 0
	var polys := polys_of(map)
	if polys.is_empty():
		return 0
	var look: Dictionary = LOOK.get(biome, LOOK_DEFAULT)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(String(map.get("id", "")) + "|marsh")
	var items := _items(look["items"])
	var edge := _items(look["edge"])
	var n := 0
	# Край тела немного гуляет, но замедление — по точному контуру карты. Непрерывный
	# мокрый слой под ним не позволяет принять механически вязкую землю за сухой просвет.
	for raw: Array in map.get("swamp", []):
		var zone := PgArtRoad._points(raw)
		if zone.size() >= 3:
			var wet := _fill(parent, zone, Color(look["col"], ZONE_ALPHA), null, map)
			wet.set_meta("pgart_swamp_zone", true)
	for poly in polys:
		_body(parent, poly, look, map, ground_tex)
	for poly in polys:
		n += _blots(parent, poly, look, items, edge, rng)
	return n


## Непрерывные тела с неровным краем; сухих разрывов внутри зоны замедления нет.
static func polys_of(map: Dictionary) -> Array[PackedVector2Array]:
	var polys: Array[PackedVector2Array] = []
	var wrng := RandomNumberGenerator.new()
	wrng.seed = hash(String(map.get("id", "")) + "|marsh_warp")
	for raw: Array in map.get("swamp", []):
		var source := PgArtRoad._points(raw)
		if source.size() < 3:
			continue
		var poly := _smooth(_warp(source, wrng))
		if poly.size() >= 3:
			polys.append(poly)
	return polys


## Контур «живой», а не чертёж: вершины через ~12 px, сдвиг каждой по нормали на гладкий шум
## (до ±WARP_AMP, период ~100 px). Прямые стороны и прямые углы зоны словаря (из них на gen:5:9
## складывалась тёмная «Н») превращаются в пятна с неровным краем; форма зоны та же в пределах
## этого сдвига, словарь не трогаем (B-399 п.2).
static func _warp(poly: PackedVector2Array, rng: RandomNumberGenerator) -> PackedVector2Array:
	if poly.size() < 3:
		return poly
	var dense := PackedVector2Array()
	for i in poly.size():
		var a := poly[i]
		var b := poly[(i + 1) % poly.size()]
		var steps := maxi(1, int(a.distance_to(b) / WARP_STEP))
		for k in steps:
			dense.append(a.lerp(b, float(k) / steps))
	var ph := [rng.randf() * TAU, rng.randf() * TAU, rng.randf() * TAU, rng.randf() * TAU]
	var out := PackedVector2Array()
	var n := dense.size()
	for i in n:
		var p := dense[i]
		var t := (dense[(i + 1) % n] - dense[(i + n - 1) % n]).normalized()
		var wob := sin(p.x * 0.05 + ph[0]) * sin(p.y * 0.06 + ph[1]) \
			+ 0.6 * sin(p.x * 0.11 + p.y * 0.09 + ph[2]) \
			+ 0.4 * sin(p.y * 0.14 - p.x * 0.07 + ph[3])
		out.append(p + t.orthogonal() * wob * WARP_AMP / 2.0)
	return out


## Скруглённый контур: сперва выступы (сжать и раздуть), потом впадины (раздуть и сжать), круглые
## стыки. Тонкая полоса (24 px) переживает: SMOOTH × 2 < её ширины.
static func _smooth(poly: PackedVector2Array) -> PackedVector2Array:
	var cur := poly
	for d: float in [-SMOOTH, SMOOTH, SMOOTH, -SMOOTH]:
		var out := Geometry2D.offset_polygon(cur, d, Geometry2D.JOIN_ROUND)
		if out.is_empty():
			return poly
		var best: PackedVector2Array = out[0]
		for o in out:
			if o.size() > best.size():
				best = o
		cur = best
	return cur


static func _items(ids: Array) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for id: String in ids:
		var it := PgCatalog.by_id(id)
		if not it.is_empty() and PgArtSprites._tex(it, "tex") != null:
			out.append(it)
	return out


static func _body(parent: Node2D, poly: PackedVector2Array, look: Dictionary, map: Dictionary,
		ground_tex: Texture2D) -> void:
	for grown in Geometry2D.offset_polygon(poly, WET_GROW, Geometry2D.JOIN_ROUND):
		_fill(parent, grown, WET, null, map)
	var col: Color = look["col"]
	for i in FEATHER.size():
		for soft in Geometry2D.offset_polygon(poly, float(FEATHER[i]), Geometry2D.JOIN_ROUND):
			_fill(parent, soft, Color(col, 0.22 - 0.08 * i), null, map)
	_fill(parent, poly, Color(col, BODY_ALPHA), null, map)
	if ground_tex != null:
		# подложка проступает сквозь жижу — фактура, а не плоский цвет
		var tinted := Color(col.lerp(Color.WHITE, 0.2), float(look["mix"]) * 0.5)
		_fill(parent, poly, tinted, ground_tex, map)
	var tint: Color = look["tint"]
	for i in SHEEN_INSET.size():
		for inner in Geometry2D.offset_polygon(poly, -float(SHEEN_INSET[i]), Geometry2D.JOIN_ROUND):
			_fill(parent, inner, Color(tint, float(SHEEN_ALPHA[i])), null, map)


static func _ring(parent: Node2D, poly: PackedVector2Array) -> void:
	var ln := Line2D.new()
	ln.points = poly
	ln.closed = true
	ln.width = RIM_W
	ln.default_color = RIM
	ln.antialiased = true
	parent.add_child(ln)


static func _fill(parent: Node2D, poly: PackedVector2Array, color: Color, tex: Texture2D,
		map: Dictionary) -> Polygon2D:
	var pg := Polygon2D.new()
	pg.polygon = poly
	pg.color = color
	pg.antialiased = true
	if tex != null:
		var view := LegionTerrain.map_size(map)
		var src := Vector2(tex.get_size())
		var uv := PackedVector2Array()
		for p in poly:
			uv.append(Vector2(fposmod(p.x, view.x), p.y) / view * src)
		pg.texture = tex
		pg.uv = uv
	parent.add_child(pg)
	return pg


## Пятна жижи: по сетке внутри полигона и вдоль кромки; величина — по узости полигона (у
## полосы 24 px пятно не шире 34), поворот и отражение — от ГСЧ.
static func _blots(parent: Node2D, poly: PackedVector2Array, look: Dictionary,
		items: Array[Dictionary], edge: Array[Dictionary], rng: RandomNumberGenerator) -> int:
	if items.is_empty():
		return 0
	var box := Rect2(poly[0], Vector2.ZERO)
	for p in poly:
		box = box.expand(p)
	var thin := minf(box.size.x, box.size.y)
	var w_hi := clampf(thin * 0.8, SPRITE_W.x, SPRITE_W.y)
	var tint: Color = look["tint"]
	var n := 0
	var y := box.position.y + STEP * 0.5
	while y < box.end.y:
		var x := box.position.x + STEP * 0.5
		while x < box.end.x:
			var p := Vector2(x, y) + Vector2(rng.randf_range(-8.0, 8.0), rng.randf_range(-8.0, 8.0))
			x += STEP
			if not Geometry2D.is_point_in_polygon(p, poly) \
					or PgArtSprites._edge_dist(p, poly) < 5.0:
				continue
			if rng.randf() > CHANCE:
				continue
			n += _blot(parent, items, p, rng.randf_range(w_hi * 0.7, w_hi * 1.15), tint, rng)
		y += STEP
	if n == 0:
		# узкая полоса: сетка не попала внутрь — ставим пятна цепочкой по оси
		var last := Vector2(-1e5, -1e5)
		var fy := box.position.y
		while fy < box.end.y:
			var fx := box.position.x
			while fx < box.end.x:
				var q := Vector2(fx, fy)
				fx += 8.0
				if q.distance_to(last) < STEP * 0.8 or PgArtSprites._edge_dist(q, poly) < 3.0 \
						or not Geometry2D.is_point_in_polygon(q, poly):
					continue
				last = q
				n += _blot(parent, items, q, clampf(thin * 1.1, 24.0, 40.0), tint, rng)
			fy += 8.0
	if edge.is_empty():
		return n
	var ring := poly.duplicate()
	ring.append(poly[0])
	for i in ring.size() - 1:
		var a := ring[i]
		var b := ring[i + 1]
		var ln := a.distance_to(b)
		var d := rng.randf_range(0.0, EDGE_STEP)
		while d < ln:
			var p := a.lerp(b, d / ln) + Vector2.from_angle(rng.randf() * TAU) * 3.0
			d += EDGE_STEP * rng.randf_range(0.6, 1.4)
			n += _blot(parent, edge, p, rng.randf_range(EDGE_W.x, EDGE_W.y), look["edge_tint"], rng)
	return n


static func _blot(parent: Node2D, items: Array[Dictionary], p: Vector2, w: float, tint: Color,
		rng: RandomNumberGenerator) -> int:
	var item: Dictionary = items[rng.randi_range(0, items.size() - 1)].duplicate()
	item["w"] = w
	var sp := PgArtSprites.item_sprite(item, PgArtSprites._tex(item, "tex"), p,
		rng.randf() < 0.5)
	sp.rotation = rng.randf_range(-PI, PI)
	sp.modulate = Color(tint, 0.9)
	parent.add_child(sp)
	return 1
