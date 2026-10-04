class_name PgArch
extends RefCounted
##
## Скелеты архетипов BOOK §3: Котёл, дороги (ломаные по сетке 16 px от ворот за краем кадра до
## Котла), вода/мосты/топь и стены, без которых архетип не читается. Скелет строится в
## «каноне» (Котёл слева, у спирали и звезды — в центре); отражение (архетип 18 «зеркало») и
## переворот по вертикали делает PgLayout. Каждый архетип берёт параметры из диапазонов и
## перебирает попытки, пока скелет не пройдёт проверку (PgArch.check): диапазоны широкие, а
## негодные сочетания отсеиваются числом, а не догадкой.
##
## Почему меандры частые: путь ≥ 1,4 прямой (У-11, тест карт) при двух ветвях в половинах
## экрана даётся только вертикалями колен — амплитуда половины ≈ 130 px, колен нужно 3–4.
##
## Скелет: {"cauldron": Vector2, "roads": [{"id", "pts": PackedVector2Array}], "water": [...],
## "bridges": [...], "swamp": [...], "walls": [{"path", "w", "kind"}], "nodes": {...}}.
##

const TRIES := 24
## Длинная прямая «взлётной полосы» — длина линии договора (LegionCfg.LINE_MAX).
const LONG_STRAIGHT := 480.0
## Старт дороги за краем кадра (как в кампании: [1360, 180], [-80, 150], [920, -80]).
const OFF_E := 1360
const OFF_W := -80
const OFF_N := -80
## Ворота справа: ниже превью волны (y 200, + полуворота) и симметрично снизу — переворот по
## вертикали оставляет их на свободном отрезке.
const GATE_HI := Vector2i(240, 272)
const GATE_LO := Vector2i(448, 480)
## Полосы колен меандра во весь рост (змейка) — ≥ 144 от края: пролёт у края ≥ 200.
const BAND_HI := Vector2i(160, 224)
const BAND_LO := Vector2i(496, 560)
## Внешние полосы ветвей в половинах экрана.
const OUT_N := Vector2i(144, 160)
const OUT_S := Vector2i(560, 576)
## Колонна первого колена (правее — ворота, левее — место меандра).
const X0 := Vector2i(1040, 1136)
## Центр верхних ворот: свободный отрезок x 820–950 (плашка статов до x 812) минус полуворота.
const TOP_GATE := Vector2i(864, 912)
const CAULDRON_X := Vector2i(176, 224)
const CAULDRON_Y := Vector2i(336, 384)
## Извилистость (У-11): 1,4–2,6, спираль до 4,0; тест карт — не меньше 1,4 от старта дороги.
const DETOUR_MIN := 1.42
const DETOUR_MAX := 2.6
const DETOUR_MAX_SPIRAL := 4.0
## Последний отрезок к Котлу прямой ≥ 120 (У-8); прочие отрезки — не ближе 120 к Котлу.
const LAST_MIN := 120.0
const CAULDRON_CLEAR := 120.0
## Повороты ≥ 60° разделены отрезком ≥ 80 (У-7).
const TURN_BIG := 1.04
const TURN_GAP := 80.0
## Разные дороги (кроме общих кусков) и дальние колена одной дороги — не ближе этого.
const ROAD_GAP := 96.0
## Оси дорог в кадре не ближе к краю (кроме входа от ворот).
const EDGE_KEEP := 96.0
const RIVER_HALF := 40
const BRIDGE_LEN := 160
const BRIDGE_W := 96
const MOAT := 64
## Котёл не ближе к краю кадра (У-8).
const CAULDRON_EDGE := 110.0
## Скос углов (как колени «Пустыря»): доля углов и длина скоса.
const CHAMFER_CHANCE := 0.3
const CHAMFER := [48, 64]


static func build(arch: String, rng: RandomNumberGenerator, card: Dictionary) -> Dictionary:
	for t in TRIES:
		var sk := _build_one(arch, rng, card)
		if sk.is_empty():
			continue
		_chamfer(sk, rng)
		var runway := (card.get("quirks", []) as Array).has("runway")
		if check(sk, arch == "spiral").is_empty() and (not runway or long_straights(sk) == 1):
			return sk
	return {}


## Сколько на карте прямых ≥ LINE_MAX (480) в кадре; общий кусок нескольких дорог — одна.
## «Взлётная полоса» — ровно одна (§4.1: «не больше одной на карту»).
static func long_straights(sk: Dictionary) -> int:
	var seen := {}
	var world := Rect2(Vector2.ZERO, PgGeom.world)
	for road: Dictionary in sk["roads"]:
		var p: PackedVector2Array = road["pts"]
		var i := 1
		while i < p.size():
			# коллинеарные отрезки подряд — одна прямая
			var a := p[i - 1]
			var j := i
			while j + 1 < p.size() and absf((p[j] - a).angle_to(p[j + 1] - p[j])) < 0.01:
				j += 1
			var b := p[j]
			var clip := Geometry2D.intersect_polyline_with_polygon(PackedVector2Array([a, b]),
				PgGeom.rect_poly(world))
			var inside := 0.0
			for part in clip:
				inside += PgGeom.length(part)
			if inside >= LONG_STRAIGHT:
				seen[[a.round(), b.round()]] = true
			i = j + 1
	return seen.size()


static func _build_one(arch: String, rng: RandomNumberGenerator, card: Dictionary) -> Dictionary:
	var quirks: Array = card.get("quirks", [])
	match arch:
		"snake":
			return _snake(rng, quirks.has("runway"))
		"turnstile":
			return _turnstile(rng, quirks.has("throat"))
		"fork":
			return _fork(rng, quirks.has("runway"))
		"crossing":
			return _crossing(rng)
		"shelves":
			return _shelves(rng)
		"maze":
			return _maze(rng)
		"crypts":
			return _crypts(rng)
		"two_fronts":
			return _two_fronts(rng, quirks.has("runway"))
		"spiral":
			return _spiral(rng)
		"star":
			return _star(rng)
		"pincers":
			return _pincers(rng, quirks.has("runway"))
		"twins":
			return _twins(rng)
		"boulevard":
			return _boulevard(rng, quirks.has("runway"))
		"courtyard":
			return _courtyard(rng, quirks.has("runway"))
		"relay":
			return _relay(rng)
		"island":
			return _island(rng)
		"hub":
			return _hub(rng, quirks.has("center"), quirks.has("runway"))
	return {}


# ── вспомогательное ──────────────────────────────────────────────────────────

static func _r(rng: RandomNumberGenerator, v: Vector2i) -> int:
	return PgRng.grid(rng, v.x, v.y)


static func _sk(c: Vector2, roads: Array) -> Dictionary:
	var out: Array = []
	for i in roads.size():
		out.append({"id": "r%d" % i, "pts": PackedVector2Array(roads[i])})
	return {"cauldron": c, "roads": out, "water": [], "bridges": [], "swamp": [], "walls": [],
		"nodes": {}}


static func _cauldron(rng: RandomNumberGenerator) -> Vector2:
	return Vector2(_r(rng, CAULDRON_X), _r(rng, CAULDRON_Y))


## Внутренние строки ветвей: ближе к середине — амплитуда колен больше. Последнее колено ветви
## идёт по внешней полосе (_branch odd), так что к Котлу ветвь спускается ≥ 150 px.
static func _in_n(cy: int) -> Vector2i:
	return Vector2i(cy - 80, cy - 64)


static func _in_s(cy: int) -> Vector2i:
	return Vector2i(cy + 64, cy + 80)


## Колонны меандра от x_from до x_to (x_from > x_to): n промежутков в [gap.x, gap.y] — берётся
## из верхней половины возможных n (больше колен — длиннее путь). Последняя — ровно x_to.
static func _columns(rng: RandomNumberGenerator, x_from: int, x_to: int, gap: Vector2i) \
		-> Array[int]:
	var total := x_from - x_to
	var opts: Array[int] = []
	for n in range(1, 12):
		var g := float(total) / n
		if g >= gap.x and g <= gap.y:
			opts.append(n)
	var out: Array[int] = []
	if opts.is_empty():
		return out
	var n: int = opts[rng.randi_range(opts.size() / 2, opts.size() - 1)]
	for i in range(1, n):
		out.append(int(PgGeom.snap(Vector2(x_from - float(total) * i / n, 0)).x))
	out.append(x_to)
	return out


## Меандр от последней точки pts (стоит на колонне): вертикаль к полосе, горизонталь к
## следующей колонне и так до x_to. Полосы чередуются, первая — bands[0]. Возвращает y
## последней горизонтали или -1, если колонн не нашлось.
static func _meander(rng: RandomNumberGenerator, pts: Array, x_to: int, bands: Array,
		gap: Vector2i) -> int:
	var cols := _columns(rng, int((pts[-1] as Vector2).x), x_to, gap)
	if cols.is_empty():
		return -1
	var y := 0
	for i in cols.size():
		y = _r(rng, bands[i % 2])
		pts.append(Vector2(int((pts[-1] as Vector2).x), y))
		pts.append(Vector2(cols[i], y))
	return y


## Ветвь от ворот справа: вход по строке g до колонны x0 (подбирается в X0 так, чтобы колонны
## легли в gap), затем меандр до x_to. bands[0] — полоса первого колена (не та, где вход);
## odd — нечётное число колен: последнее идёт по bands[0].
static func _branch(rng: RandomNumberGenerator, g: int, x_to: int, bands: Array,
		gap: Vector2i, odd := true, many := true) -> Array:
	var opts: Array = []
	for n in range(1, 10):
		if odd and n % 2 == 0:
			continue
		var lo := ceili(float(maxi(n * gap.x, X0.x - x_to)) / 16.0) * 16
		var hi := floori(float(mini(n * gap.y, X0.y - x_to)) / 16.0) * 16
		if lo <= hi:
			opts.append([n, lo, hi])
	if opts.is_empty():
		return []
	# many — больше колен (ветвь в половине экрана: иначе путь короче 1,4 прямой); иначе —
	# меньше колен и длиннее прямые (змейка во весь рост набирает длину и так)
	var first := opts.size() / 2 if many else 0
	var last := opts.size() - 1 if many else (opts.size() - 1) / 2
	var pick: Array = opts[rng.randi_range(first, last)]
	var n: int = pick[0]
	var total := PgRng.grid(rng, pick[1], pick[2])
	var x0 := x_to + total
	var pts: Array = [Vector2(OFF_E, g), Vector2(x0, g)]
	for i in n:
		var y := _r(rng, bands[i % 2])
		pts.append(Vector2((pts[-1] as Vector2).x, y))
		var x := x_to if i == n - 1 else x0 - int(PgGeom.snap(Vector2(float(total) * (i + 1) / n,
			0)).x)
		pts.append(Vector2(x, y))
	return pts


## Отразить полосу по вертикали вокруг y0.
static func _band_flip(b: Vector2i, y0: int) -> Vector2i:
	return Vector2i(2 * y0 - b.y, 2 * y0 - b.x)


## Река сверху вниз через весь кадр; у мостов (ys) — ровная, чтобы мост накрыл воду целиком.
static func _river_v(rng: RandomNumberGenerator, x: int, ys: Array[int]) -> PackedVector2Array:
	var left: Array = []
	var right: Array = []
	var y := -40
	while y <= PgGeom.world.y + 40.0:
		var near := false
		for yb in ys:
			near = near or absi(y - yb) <= 80
		var dx := 0 if near else rng.randi_range(-1, 1) * 16
		left.append(Vector2(x - RIVER_HALF + dx, y))
		right.append(Vector2(x + RIVER_HALF + dx, y))
		y += 80
	right.reverse()
	return PackedVector2Array(left + right)


static func _river_h(rng: RandomNumberGenerator, y: int, xs: Array[int]) -> PackedVector2Array:
	var top: Array = []
	var bottom: Array = []
	var x := -40
	while x <= PgGeom.world.x + 40.0:
		var near := false
		for xb in xs:
			near = near or absi(x - xb) <= 80
		var dy := 0 if near else rng.randi_range(-1, 1) * 16
		top.append(Vector2(x, y - RIVER_HALF + dy))
		bottom.append(Vector2(x, y + RIVER_HALF + dy))
		x += 80
	bottom.reverse()
	return PackedVector2Array(top + bottom)


## Мост 160×96 (как в кампании) вдоль дороги: horizontal — дорога идёт по x.
static func _bridge(at: Vector2, horizontal: bool) -> PackedVector2Array:
	var half := Vector2(BRIDGE_LEN * 0.5, BRIDGE_W * 0.5) if horizontal \
		else Vector2(BRIDGE_W * 0.5, BRIDGE_LEN * 0.5)
	return PgGeom.rect_poly(Rect2(at - half, half * 2.0))


## Две ветви справа по половинам экрана: вход на внутренней строке, меандр внешняя↔внутренняя,
## слияние у Котла сверху и снизу. Основа стеллажей, лабиринта, болота со склепами.
static func _two_gate(rng: RandomNumberGenerator, c: Vector2, xm: int, gap: Vector2i) \
		-> Dictionary:
	var cy := int(c.y)
	var out: Array = []
	for north: bool in [true, false]:
		var inner := _in_n(cy) if north else _in_s(cy)
		var outer := OUT_N if north else OUT_S
		var pts := _branch(rng, _r(rng, inner), xm, [outer, inner], gap)
		if pts.is_empty():
			return {}
		pts.append(Vector2(xm, c.y))
		pts.append(c)
		out.append(pts)
	var sk := _sk(c, out)
	sk["nodes"] = {"merge": Vector2(xm, c.y)}
	return sk


# ── архетипы ─────────────────────────────────────────────────────────────────

## 1. Змейка («Пустырь»): одна дорога, колена во весь рост.
static func _snake(rng: RandomNumberGenerator, runway: bool) -> Dictionary:
	var c := _cauldron(rng)
	var top := rng.randf() < 0.5
	var bands: Array = [BAND_LO, BAND_HI] if top else [BAND_HI, BAND_LO]
	var g := _r(rng, GATE_HI if top else GATE_LO)
	var xm := int(c.x) + _r(rng, Vector2i(144, 240))
	var pts: Array
	if runway:
		# взлётная полоса: первое колено после входа ≥ 480 px, за ним ещё колено во весь рост —
		# без него путь короче 1,4 прямой
		xm = int(c.x) + _r(rng, Vector2i(128, 160))
		var x0 := _r(rng, Vector2i(1072, 1120))
		var x1 := x0 - _r(rng, Vector2i(480, 512))
		var y1 := _r(rng, bands[0])
		pts = [Vector2(OFF_E, g), Vector2(x0, g), Vector2(x0, y1), Vector2(x1, y1)]
		if _meander(rng, pts, xm, [bands[1], bands[0]], Vector2i(160, 320)) < 0:
			return {}
	else:
		pts = _branch(rng, g, xm, bands, Vector2i(256, 448), false, false)
		if pts.is_empty():
			return {}
	pts.append(Vector2(xm, c.y))
	pts.append(c)
	return _sk(c, [pts])


## 2. Двор с турникетом («Проходная»): петля по «улице» у ворот, ограда во всю высоту с
## проходом, за ней двор с двумя петлями и слияние у Котла.
static func _turnstile(rng: RandomNumberGenerator, throat: bool) -> Dictionary:
	var c := _cauldron(rng)
	var cy := int(c.y)
	var yt := _r(rng, Vector2i(cy - 32, cy + 32))
	var low := rng.randf() < 0.5
	var g := _r(rng, GATE_LO) if low else _r(rng, GATE_HI)
	# колено «улицы» — по другую сторону прохода и не ближе 96 к его строке (У-7: ≥ 80)
	var g2 := yt - _r(rng, Vector2i(96, 144)) if low else yt + _r(rng, Vector2i(96, 144))
	if g2 < 176 or g2 > 576 or absi(g2 - g) < 96:
		return {}
	var xe1 := _r(rng, Vector2i(1104, 1136))
	var xe2 := xe1 - _r(rng, Vector2i(112, 128))
	var xf := xe2 - _r(rng, Vector2i(112, 144))
	var xs := xf - _r(rng, Vector2i(128, 160))
	var yn := _r(rng, OUT_N)
	var ys := _r(rng, OUT_S)
	var xm := int(c.x) + _r(rng, Vector2i(160, 224))
	var head: Array = [Vector2(OFF_E, g), Vector2(xe1, g), Vector2(xe1, g2), Vector2(xe2, g2),
		Vector2(xe2, yt), Vector2(xs, yt)]
	var north := head + [Vector2(xs, yn), Vector2(xm, yn), Vector2(xm, c.y), c]
	var south := head + [Vector2(xs, ys), Vector2(xm, ys), Vector2(xm, c.y), c]
	var sk := _sk(c, [north, south])
	# проход 112 px (пролёт ≥ 90), с изюминкой «узкое горло» — 86 (турникет, 80–90)
	var half := 43 if throat else 56
	sk["walls"] = [{"path": [Vector2(xf, -4), Vector2(xf, yt - half)], "w": 18.0,
		"kind": "fence", "role": "turnstile"},
		{"path": [Vector2(xf, yt + half), Vector2(xf, 724)], "w": 18.0, "kind": "fence",
		"role": "turnstile"}]
	sk["nodes"] = {"yard": Rect2(xm, yn, xs - xm, ys - yn), "turnstile": Vector2(xf, yt),
		"split": Vector2(xs, yt), "merge": Vector2(xm, c.y)}
	if throat:
		sk["nodes"]["throat"] = Vector2(xf, yt)
	return sk


## Котёл «обхвата»: слева, но правее края (x 368–416 — ещё не средняя треть), чтобы дороги
## успели обойти его и зайти сзади.
static func _cauldron_wrap(rng: RandomNumberGenerator) -> Vector2:
	return Vector2(_r(rng, Vector2i(368, 416)), _r(rng, CAULDRON_Y))


## Обхват: от (x, y) — вертикаль к краевой строке, длинная прямая на запад до x_w, вниз/вверх
## к строке Котла. Длина набирается прямыми, а не зубцами (силуэт «Ω» вокруг Котла). dip —
## одна выемка внутрь на длинной прямой, для разнообразия.
static func _wrap(rng: RandomNumberGenerator, pts: Array, north: bool, x_w: int, cy: int,
		dip: bool) -> void:
	var x := int((pts[-1] as Vector2).x)
	var edge := _r(rng, OUT_N) if north else _r(rng, OUT_S)
	pts.append(Vector2(x, edge))
	if dip and x - x_w >= 720:
		var s := 1 if north else -1
		var xa := x - _r(rng, Vector2i(208, 288))
		var xb := xa - _r(rng, Vector2i(176, 240))
		var depth := edge + s * _r(rng, Vector2i(112, 144))
		if xb - x_w >= 208:
			pts.append(Vector2(xa, edge))
			pts.append(Vector2(xa, depth))
			pts.append(Vector2(xb, depth))
			pts.append(Vector2(xb, edge))
	pts.append(Vector2(x_w, edge))
	pts.append(Vector2(x_w, cy))


## 3. Развилка («Два отдела»): один вход, две ветви обходят карту по верхнему и нижнему краю и
## сходятся за Котлом; резерв — между ветвями, переброска близким договором.
static func _fork(rng: RandomNumberGenerator, runway: bool) -> Dictionary:
	var c := _cauldron_wrap(rng)
	var cy := int(c.y)
	var g := _r(rng, Vector2i(cy - 16, cy + 16))
	var xs := _r(rng, Vector2i(1008, 1088))
	var x_w := _r(rng, Vector2i(144, 176))
	var branches: Array = []
	for north: bool in [true, false]:
		var pts: Array = [Vector2(OFF_E, g), Vector2(xs, g)]
		_wrap(rng, pts, north, x_w, cy, not runway and rng.randf() < 0.5)
		pts.append(c)
		branches.append(pts)
	var sk := _sk(c, branches)
	sk["nodes"] = {"split": Vector2(xs, g), "merge": Vector2(x_w, cy)}
	return sk


## 5. Переправа («Мост через Стикс»): развилка-обхват, река сверху донизу режет обе ветви на
## длинных прямых — два моста 96 px, общий вход и слияние за Котлом.
static func _crossing(rng: RandomNumberGenerator) -> Dictionary:
	var c := _cauldron_wrap(rng)
	var cy := int(c.y)
	var g := _r(rng, Vector2i(cy - 16, cy + 16))
	var xs := _r(rng, Vector2i(1040, 1104))
	var x_w := _r(rng, Vector2i(144, 176))
	var xr := _r(rng, Vector2i(int(c.x) + 224, xs - 208))
	var branches: Array = []
	var yb: Array[int] = []
	for north: bool in [true, false]:
		var pts: Array = [Vector2(OFF_E, g), Vector2(xs, g)]
		_wrap(rng, pts, north, x_w, cy, false)
		pts.append(c)
		branches.append(pts)
		yb.append(int((pts[2] as Vector2).y))
	var sk := _sk(c, branches)
	sk["water"] = [_river_v(rng, xr, yb)]
	sk["bridges"] = [_bridge(Vector2(xr, yb[0]), true), _bridge(Vector2(xr, yb[1]), true)]
	sk["nodes"] = {"split": Vector2(xs, g), "merge": Vector2(x_w, cy)}
	return sk


## 4. Архив-стеллажи: меандры меж стеллажей; стеллажи свисают от края в карманы колен.
static func _shelves(rng: RandomNumberGenerator) -> Dictionary:
	var c := _cauldron(rng)
	var xm := int(c.x) + _r(rng, Vector2i(128, 176))
	var sk := _two_gate(rng, c, xm, Vector2i(256, 320))
	if sk.is_empty():
		return {}
	var walls: Array = []
	for road: Dictionary in sk["roads"]:
		var pts: PackedVector2Array = road["pts"]
		var north := pts[0].y < c.y
		for i in range(2, pts.size() - 2):
			var a := pts[i]
			var b := pts[i + 1]
			if a.y != b.y or absf(a.x - b.x) < 256.0 or absf(a.y - c.y) > 120.0:
				continue
			# карман над внутренним коленом открыт к краю — стеллаж свисает от края
			var x := PgGeom.snap(Vector2((a.x + b.x) * 0.5, 0)).x
			var end_y := a.y - 104.0 if north else a.y + 104.0
			var edge := -4.0 if north else 724.0
			if absf(end_y - edge) >= 96.0:
				walls.append({"path": [Vector2(x, edge), Vector2(x, end_y)], "w": 56.0,
					"kind": "shelf", "role": "shelf"})
	sk["walls"] = walls
	return sk


## 6. Лабиринт коридоров: две ветви справа и третья дорога сверху, врезающаяся во внутреннее
## колено верхней ветви; коридоры — стены вдоль колен (ставит PgProps: nodes.corridors).
static func _maze(rng: RandomNumberGenerator) -> Dictionary:
	var c := _cauldron(rng)
	var cy := int(c.y)
	var xm := int(c.x) + _r(rng, Vector2i(144, 192))
	# верхняя ветвь — с внешним коленом над воротами сверху (c1 ≤ 720, x0 ≥ 1040)
	var x0 := _r(rng, Vector2i(1040, 1104))
	var c1 := _r(rng, Vector2i(640, 704))
	if c1 - xm < 256:
		return {}
	var c2 := _r(rng, Vector2i(xm + 128, c1 - 128))
	var gn := _r(rng, _in_n(cy))
	var o1 := _r(rng, OUT_N)
	var i1 := _r(rng, _in_n(cy))
	var o2 := _r(rng, OUT_N)
	var north: Array = [Vector2(OFF_E, gn), Vector2(x0, gn), Vector2(x0, o1), Vector2(c1, o1),
		Vector2(c1, i1), Vector2(c2, i1), Vector2(c2, o2), Vector2(xm, o2), Vector2(xm, cy), c]
	var south := _branch(rng, _r(rng, _in_s(cy)), xm, [OUT_S, _in_s(cy)], Vector2i(208, 288))
	if south.is_empty():
		return {}
	var sk := _sk(c, [north, south + [Vector2(xm, cy), c]])
	sk["nodes"] = {"merge": Vector2(xm, cy)}
	var top: PackedVector2Array = sk["roads"][0]["pts"]
	# верхние ворота x 864–912: ищем колено верхней ветви (не вход), над которым их можно
	# поставить — вертикаль сверху до колена ничего не пересекает: каждый x принадлежит одному
	# горизонтальному колену ветви
	for i in range(1, top.size() - 3):
		var a := top[i]
		var b := top[i + 1]
		var lo := maxi(int(b.x) + 96, TOP_GATE.x)
		var hi := mini(int(a.x) - 96, TOP_GATE.y)
		if a.y != b.y or lo > hi:
			continue
		var xn := _r(rng, Vector2i(ceili(lo / 16.0) * 16, floori(hi / 16.0) * 16))
		if xn < lo or xn > hi:
			continue
		var j := Vector2(xn, a.y)
		var joined := PackedVector2Array()
		for k in i + 1:
			joined.append(top[k])
		joined.append(j)
		for k in range(i + 1, top.size()):
			joined.append(top[k])
		sk["roads"][0]["pts"] = joined
		var from_top := PackedVector2Array([Vector2(xn, OFF_N)])
		for k in range(i + 1, joined.size()):
			from_top.append(joined[k])
		sk["roads"].append({"id": "r2", "pts": from_top})
		sk["nodes"]["merge2"] = j
		sk["nodes"]["corridors"] = true
		return sk
	return {}


## 7. Болото со склепами: две ветви с широкими петлями, топь в карманах, склепы у дальних петель
## (ставит PgQuirks по nodes.crypts / nodes.bog).
static func _crypts(rng: RandomNumberGenerator) -> Dictionary:
	var c := Vector2(_r(rng, Vector2i(176, 192)), _r(rng, CAULDRON_Y))
	var xm := int(c.x) + _r(rng, Vector2i(128, 160))
	var sk := _two_gate(rng, c, xm, Vector2i(240, 304))
	if not sk.is_empty():
		sk["nodes"]["crypts"] = 2
		sk["nodes"]["bog"] = true
	return sk


## 8. Два фронта («Прораб»): две ветви крупными крючками сходятся посередине, дальше ствол
## петлёй к Котлу — второй рубеж за слиянием.
static func _two_fronts(rng: RandomNumberGenerator, runway: bool) -> Dictionary:
	var c := _cauldron(rng)
	var ym := int(c.y)
	var xm := _r(rng, Vector2i(528, 592))
	var out: Array = []
	for north: bool in [true, false]:
		var outer := OUT_N if north else OUT_S
		var inner := _in_n(ym) if north else _in_s(ym)
		var g := _r(rng, inner)
		var x0 := _r(rng, Vector2i(1024, 1136))
		if runway and not north:
			# «взлётка» — ровно одна: внешнее колено нижней ветви короче 480
			x0 = _r(rng, Vector2i(1024, mini(1136, xm + 464)))
		if runway and north:
			# вход сразу длинным коленом ≥ 480 по внешней полосе
			x0 = _r(rng, Vector2i(1088, 1136))
			if x0 - xm < 480:
				return {}
		var y := _r(rng, outer)
		out.append([Vector2(OFF_E, g), Vector2(x0, g), Vector2(x0, y), Vector2(xm, y),
			Vector2(xm, ym)])
	# ствол: от слияния к Котлу петлёй вниз или вверх
	var s := 1 if rng.randf() < 0.5 else -1
	var xq := int(c.x) + _r(rng, Vector2i(160, 224))
	if xm - xq < 112:
		return {}
	var yb := ym + s * _r(rng, Vector2i(160, 192))
	var trunk: Array = [Vector2(xq, ym), Vector2(xq, yb), Vector2(c.x, yb), c]
	var roads: Array = []
	for pts: Array in out:
		roads.append(pts + trunk)
	var sk := _sk(c, roads)
	sk["nodes"] = {"merge": Vector2(xm, ym)}
	return sk


## 9. Спираль («Винтовая лестница согласований»): Котёл в центре, дорога на виток с четвертью.
static func _spiral(rng: RandomNumberGenerator) -> Dictionary:
	var c := Vector2(_r(rng, Vector2i(576, 640)), _r(rng, Vector2i(352, 368)))
	var g := _r(rng, Vector2i(560, 576))
	var xl := _r(rng, Vector2i(240, 288))
	var yt := _r(rng, Vector2i(144, 160))
	var xr := _r(rng, Vector2i(992, 1040))
	if c.y - yt < 200 or g - c.y < 192:
		return {}
	var pts: Array = [Vector2(OFF_E, g), Vector2(xl, g), Vector2(xl, yt), Vector2(xr, yt),
		Vector2(xr, c.y), c]
	return _sk(c, [pts])


## 10. Звезда с экспрессом: Котёл в центре, трое ворот, заход с севера, юга и запада; западная
## дорога — самая короткая («экспресс»).
static func _star(rng: RandomNumberGenerator) -> Dictionary:
	var c := Vector2(_r(rng, Vector2i(608, 672)), _r(rng, Vector2i(368, 384)))
	var cy := int(c.y)
	var roads: Array = []
	for s: int in [1, -1]:
		# правые ворота ниже превью волны (y ≥ 232): верхняя дорога входит на y 240–256, ныряет
		# вниз и крюком заходит к Котлу сверху; нижняя — зеркально снизу
		var g1 := _r(rng, Vector2i(240, 256)) if s == 1 else 576
		var a := _r(rng, Vector2i(int(c.x) + 336, int(c.x) + 400))
		var y1 := mini(g1 + _r(rng, Vector2i(96, 112)), cy - 16) if s == 1 \
			else cy + _r(rng, Vector2i(80, 96))
		var b := a - _r(rng, Vector2i(160, 192))
		var y2 := cy - s * _r(rng, Vector2i(192, 208))
		if absi(y1 - g1) < 96 or absi(y1 - cy) > 112:
			return {}
		roads.append([Vector2(OFF_E, g1), Vector2(a, g1), Vector2(a, y1), Vector2(b, y1),
			Vector2(b, y2), Vector2(c.x, y2), c])
	var gw := _r(rng, Vector2i(176, 224)) if rng.randf() < 0.5 else _r(rng, Vector2i(496, 544))
	var c1 := _r(rng, Vector2i(272, 320))
	var yw := cy + (1 if gw < 360 else -1) * _r(rng, Vector2i(96, 128))
	var c2 := int(c.x) - _r(rng, Vector2i(144, 176))
	roads.append([Vector2(OFF_W, gw), Vector2(c1, gw), Vector2(c1, yw), Vector2(c2, yw),
		Vector2(c2, c.y), c])
	var sk := _sk(c, roads)
	sk["nodes"] = {"express": 2}
	return sk


## 11. Клещи с опозданием: две дороги берут Котёл с двух сторон — короткая обходит по краю и
## заходит сзади, длинная частым меандром по другой половине заходит спереди; группы
## стартуют одновременно, длинная приходит позже.
static func _pincers(rng: RandomNumberGenerator, runway: bool) -> Dictionary:
	var c := _cauldron_wrap(rng)
	var cy := int(c.y)
	var up := rng.randf() < 0.5
	var x_w := _r(rng, Vector2i(144, 176))
	# короткая: от ворот прямо по краевой строке за Котёл
	# краевая строка — не ближе 128 к строке Котла (прямая проходит мимо Котла, У-8: ≥ 120)
	var g := _r(rng, Vector2i(240, cy - 128)) if up else _r(rng, Vector2i(cy + 128, 576))
	if (up and g > cy - 128) or (not up and g < cy + 128):
		return {}
	var short: Array = [Vector2(OFF_E, g), Vector2(x_w, g), Vector2(x_w, cy), c]
	# длинная: частый меандр по другой половине, заход к Котлу с востока
	var outer := OUT_S if up else OUT_N
	var inner := _in_s(cy) if up else _in_n(cy)
	var xe := int(c.x) + _r(rng, Vector2i(160, 192))
	var gap := Vector2i(144, 600) if runway else Vector2i(136, 208)
	var long := _branch(rng, _r(rng, inner), xe, [outer, inner], gap)
	if long.is_empty():
		return {}
	long.append(Vector2(xe, cy))
	long.append(c)
	var sk := _sk(c, [short, long])
	# «короткая» — по длине, а не по форме: обход по краю за Котёл бывает и длиннее меандра
	var first_short := PgGeom.length(sk["roads"][0]["pts"]) <= PgGeom.length(
		sk["roads"][1]["pts"])
	sk["nodes"] = {"short": 0 if first_short else 1, "long": 1 if first_short else 0}
	return sk


## 12. Ложные близнецы: короткая дорога через топь (×0,5) и длинная по суше; топь на короткой
## ровно такой длины, чтобы группы пришли одновременно (топь кладёт PgQuirks: nodes.twins).
static func _twins(rng: RandomNumberGenerator) -> Dictionary:
	var sk := _pincers(rng, false)
	if sk.is_empty():
		return {}
	var short: PackedVector2Array = sk["roads"][int(sk["nodes"]["short"])]["pts"]
	var long: PackedVector2Array = sk["roads"][int(sk["nodes"]["long"])]["pts"]
	var extra := PgGeom.length(long) - PgGeom.length(short)
	# топь удваивает время на своём отрезке: её длина по дороге = разнице длин
	if extra < 128.0 or extra > 640.0:
		return {}
	sk["nodes"]["twins_swamp"] = extra
	return sk


## 13. Бульвар: две дороги от соседних ворот идут параллельно в 112–144 px через полкарты,
## потом расходятся к верхнему и нижнему краю и сходятся за Котлом.
static func _boulevard(rng: RandomNumberGenerator, _runway: bool) -> Dictionary:
	var c := _cauldron_wrap(rng)
	var cy := int(c.y)
	var yb1 := cy - _r(rng, Vector2i(56, 72))
	var yb2 := yb1 + _r(rng, Vector2i(112, 144))
	var xa := _r(rng, Vector2i(592, 672))
	var x_w := _r(rng, Vector2i(144, 176))
	var roads: Array = []
	for north: bool in [true, false]:
		var pts: Array = [Vector2(OFF_E, yb1 if north else yb2), Vector2(xa, yb1 if north
			else yb2)]
		_wrap(rng, pts, north, x_w, cy, false)
		pts.append(c)
		roads.append(pts)
	var sk := _sk(c, roads)
	sk["nodes"] = {"merge": Vector2(x_w, cy), "boulevard": Rect2(xa, yb1,
		PgGeom.world.x - xa, yb2 - yb1)}
	return sk


## 14. Внутренний двор: дорога обходит двор с трёх сторон, участки — в середине двора;
## четвёртая сторона — ограда с проходами по краям.
static func _courtyard(rng: RandomNumberGenerator, runway: bool) -> Dictionary:
	var g := _r(rng, GATE_LO)
	var xr := _r(rng, Vector2i(1008, 1072))
	var yt := _r(rng, BAND_HI)
	var xl := _r(rng, Vector2i(400, 464)) if not runway else xr - _r(rng, Vector2i(480, 528))
	var yb := _r(rng, Vector2i(512, 544))
	var cx := _r(rng, CAULDRON_X)
	var c := Vector2(cx, yb - _r(rng, Vector2i(128, 176)))
	var pts: Array = [Vector2(OFF_E, g), Vector2(xr, g), Vector2(xr, yt), Vector2(xl, yt),
		Vector2(xl, yb), Vector2(cx, yb), c]
	var sk := _sk(c, [pts])
	var fy := _r(rng, Vector2i(592, 608))
	if xr - xl >= 448:
		sk["walls"] = [{"path": [Vector2(xl + 112, fy), Vector2(xr - 112, fy)], "w": 18.0,
			"kind": "fence", "role": "yard"}]
	sk["nodes"] = {"yard": Rect2(xl, yt, xr - xl, fy - yt)}
	return sk


## 15. Эстафета: одна длинная дорога с прямыми ≥ 480 (длина линии договора), площадок мало.
static func _relay(rng: RandomNumberGenerator) -> Dictionary:
	# вход ниже превью волны (y ≥ 232)
	var y1 := _r(rng, Vector2i(240, 256))
	var xa := _r(rng, Vector2i(304, 352))
	var y2 := _r(rng, Vector2i(368, 400))
	var xb := _r(rng, Vector2i(864, 944))
	var y3 := _r(rng, Vector2i(544, 576))
	var c := Vector2(_r(rng, CAULDRON_X), y3)
	var pts: Array = [Vector2(OFF_E, y1), Vector2(xa, y1), Vector2(xa, y2), Vector2(xb, y2),
		Vector2(xb, y3), c]
	var sk := _sk(c, [pts])
	sk["nodes"] = {"relay": true}
	return sk


## 16. Остров: Котёл на острове (ров с трёх сторон, четвёртая — край кадра), обе дороги
## кончаются мостами — горла у самого Котла.
static func _island(rng: RandomNumberGenerator) -> Dictionary:
	var c := Vector2(_r(rng, Vector2i(208, 240)), _r(rng, CAULDRON_Y))
	var cy := int(c.y)
	var xi := int(c.x) + _r(rng, Vector2i(176, 208))
	var yt := cy - _r(rng, Vector2i(176, 192))
	var yb := cy + _r(rng, Vector2i(176, 192))
	var xj := int(c.x) + _r(rng, Vector2i(128, 144))
	var xk := xi + MOAT + _r(rng, Vector2i(160, 208))
	var roads: Array = []
	var bridge_y: Array[int] = []
	for north: bool in [true, false]:
		var s := -1 if north else 1
		var outer := OUT_N if north else OUT_S
		var inner := _in_n(cy) if north else _in_s(cy)
		var yn := cy + s * _r(rng, Vector2i(96, 112))
		var pts := _branch(rng, _r(rng, inner), xk, [outer, inner], Vector2i(128, 224))
		if pts.is_empty():
			return {}
		# последнее колено — к строке моста и прямо через ров к острову
		if int((pts[-1] as Vector2).y) != yn:
			pts.append(Vector2(xk, yn))
		pts.append(Vector2(xj, yn))
		pts.append(Vector2(xj, cy))
		pts.append(c)
		roads.append(pts)
		bridge_y.append(yn)
	var sk := _sk(c, roads)
	var m := float(MOAT)
	sk["water"] = [
		PgGeom.rect_poly(Rect2(-40, yt - m, xi + m + 40, m)),
		PgGeom.rect_poly(Rect2(xi, yt - m, m, yb - yt + 2 * m)),
		PgGeom.rect_poly(Rect2(-40, yb, xi + m + 40, m)),
	]
	for y in bridge_y:
		sk["bridges"].append(PgGeom.rect_poly(Rect2(xi - 48, y - BRIDGE_W / 2,
			MOAT + 96, BRIDGE_W)))
	sk["nodes"] = {"merge": Vector2(xj, cy), "island": Rect2(0, yt, xi, yb - yt)}
	return sk


## 17. Приёмная (хаб): трое ворот сходятся в «зал ожидания» в средней трети, из него одна
## дорога петлёй к Котлу. С изюминкой «Котёл в центре» Котёл ближе к середине экрана.
static func _hub(rng: RandomNumberGenerator, center: bool, runway: bool) -> Dictionary:
	# зал левее верхних ворот (x 848–880) на ≥ 96: колено северной дороги у зала ≥ 80 (У-7)
	var h := Vector2(_r(rng, Vector2i(704, 752)), _r(rng, Vector2i(336, 368)))
	var hy := int(h.y)
	var g1 := _r(rng, Vector2i(240, hy - 96))
	var x0 := _r(rng, Vector2i(1024, 1088))
	var ne: Array = [Vector2(OFF_E, g1), Vector2(x0, g1), Vector2(x0, h.y), h]
	var se: Array
	# подход к залу снизу ≥ 96: иначе колено перед ним ближе 96 к северному подходу
	var y2 := _r(rng, Vector2i(hy + 96, hy + 112))
	var g2 := _r(rng, Vector2i(y2 + 96, 576))
	if g2 > 576:
		return {}
	if runway:
		# взлётная полоса: нижний вход идёт длинной прямой до самого зала
		se = [Vector2(OFF_E, g2), Vector2(h.x, g2), h]
	else:
		var x2 := _r(rng, Vector2i(912, 976))
		se = [Vector2(OFF_E, g2), Vector2(x2, g2), Vector2(x2, y2), Vector2(h.x, y2), h]
	var xt := _r(rng, TOP_GATE)
	var y1 := _r(rng, Vector2i(176, 208))
	var north: Array = [Vector2(xt, OFF_N), Vector2(xt, y1), Vector2(h.x, y1), h]
	var c: Vector2
	var trunk: Array
	var s := 1 if rng.randf() < 0.5 else -1
	var ya := hy + s * _r(rng, Vector2i(160, 192))
	if center:
		c = Vector2(_r(rng, Vector2i(448, 480)), h.y)
		var x1 := _r(rng, Vector2i(592, 624))
		trunk = [Vector2(x1, h.y), Vector2(x1, ya), Vector2(c.x, ya), c]
	else:
		c = Vector2(_r(rng, CAULDRON_X), h.y)
		var x1 := _r(rng, Vector2i(576, 592))
		var x2 := _r(rng, Vector2i(448, 464))
		var yb := hy - s * _r(rng, Vector2i(160, 192))
		var x3 := x2 - _r(rng, Vector2i(96, 112))
		if x3 - c.x < 128:
			return {}
		trunk = [Vector2(x1, h.y), Vector2(x1, ya), Vector2(x2, ya), Vector2(x2, yb),
			Vector2(x3, yb), Vector2(x3, h.y), c]
	var sk := _sk(c, [north + trunk, ne + trunk, se + trunk])
	sk["nodes"] = {"merge": h, "hub": h}
	return sk


# ── скос углов ───────────────────────────────────────────────────────────────

## Прямые углы, принадлежащие одной дороге (не узлы слияния), местами срезаются скосом 45°:
## карта перестаёт выглядеть разлинованной, а оба новых поворота — по 45° (У-7 их не считает).
static func _chamfer(sk: Dictionary, rng: RandomNumberGenerator) -> void:
	var shared := {}
	var roads: Array = sk["roads"]
	for road: Dictionary in roads:
		for p in road["pts"]:
			shared[p] = int(shared.get(p, 0)) + 1
	var c: Vector2 = sk["cauldron"]
	for road: Dictionary in roads:
		var src: PackedVector2Array = road["pts"]
		var out := PackedVector2Array([src[0]])
		for i in range(1, src.size() - 1):
			var p := src[i]
			var a := src[i - 1]
			var b := src[i + 1]
			var cut: int = CHAMFER[rng.randi_range(0, CHAMFER.size() - 1)]
			var ok := int(shared[p]) == 1 and rng.randf() < CHAMFER_CHANCE \
				and absf(PgGeom.turn_at(src, i) - PI * 0.5) < 0.01 \
				and a.distance_to(p) >= cut + 96 and p.distance_to(b) >= cut + 96 \
				and p.distance_to(c) > 200.0 and out[-1] == a
			if ok:
				out.append(p + (a - p).normalized() * cut)
				out.append(p + (b - p).normalized() * cut)
			else:
				out.append(p)
		out.append(src[-1])
		road["pts"] = out


# ── проверка скелета ─────────────────────────────────────────────────────────

## Пусто — скелет годен; иначе причина. Проверки — те, что дорога обещает по построению
## (У-6 ворота, У-7 чтение пути, У-8 Котёл, У-11 извилистость) плюс тест карт (≥ 2 поворотов,
## путь ≥ 1,4 прямой, дорога доходит до Котла).
static func check(sk: Dictionary, spiral: bool) -> String:
	var c: Vector2 = sk["cauldron"]
	if c.x < CAULDRON_EDGE or c.y < CAULDRON_EDGE or c.x > PgGeom.world.x - CAULDRON_EDGE \
			or c.y > PgGeom.world.y - CAULDRON_EDGE or PgGeom.in_hud(c, 60.0):
		return "котёл у края или под HUD"
	var roads: Array = sk["roads"]
	for road: Dictionary in roads:
		var why := _check_road(road["pts"], c, spiral)
		if not why.is_empty():
			return String(road["id"]) + ": " + why
	for i in roads.size():
		for j in range(i + 1, roads.size()):
			if not _apart(roads[i]["pts"], roads[j]["pts"]):
				return "дороги %s и %s пересекаются или слишком близко" % [
					roads[i]["id"], roads[j]["id"]]
	return ""


static func _check_road(p: PackedVector2Array, c: Vector2, spiral: bool) -> String:
	if p.size() < 3 or p[-1] != c:
		return "не доходит до котла"
	var world := Rect2(Vector2.ZERO, PgGeom.world)
	if world.has_point(p[0]):
		return "старт в кадре"
	if not PgGeom.gate_ok(p):
		return "ворота под HUD или у угла"
	if p[-1].distance_to(p[-2]) < LAST_MIN:
		return "последний отрезок короче 120"
	var total := PgGeom.length(p)
	var detour := total / p[0].distance_to(c)
	if detour < DETOUR_MIN or detour > (DETOUR_MAX_SPIRAL if spiral else DETOUR_MAX):
		return "извилистость %.2f" % detour
	var turns := 0
	for i in range(1, p.size() - 1):
		if PgGeom.turn_at(p, i) > 0.2:
			turns += 1
	if turns < 2:
		return "меньше двух поворотов"
	for i in range(1, p.size() - 2):
		if PgGeom.turn_at(p, i) >= TURN_BIG and PgGeom.turn_at(p, i + 1) >= TURN_BIG \
				and p[i].distance_to(p[i + 1]) < TURN_GAP:
			return "повороты ближе 80"
	for i in range(1, p.size() - 1):
		var q := p[i]
		if q.x < EDGE_KEEP or q.y < EDGE_KEEP or q.x > PgGeom.world.x - EDGE_KEEP \
				or q.y > PgGeom.world.y - EDGE_KEEP:
			return "колено у края"
	for i in range(0, p.size() - 2):
		var d := c.distance_to(Geometry2D.get_closest_point_to_segment(c, p[i], p[i + 1]))
		if d < CAULDRON_CLEAR and i < p.size() - 2:
			return "дорога проходит у котла"
	for i in range(p.size() - 1):
		for j in range(i + 2, p.size() - 1):
			if j == i + 2 and p[i + 1].distance_to(p[i + 2]) < 100.0:
				continue
			if PgGeom.seg_dist(p[i], p[i + 1], p[j], p[j + 1]) < ROAD_GAP:
				return "колена слишком близко"
	return ""


## Две дороги: общие начало и конец допустимы (развилка, слияние), остальное — не ближе ROAD_GAP.
static func _apart(a: PackedVector2Array, b: PackedVector2Array) -> bool:
	var pre := 0
	while pre < mini(a.size(), b.size()) and a[pre] == b[pre]:
		pre += 1
	var suf := 0
	while suf < mini(a.size(), b.size()) and a[a.size() - 1 - suf] == b[b.size() - 1 - suf]:
		suf += 1
	var nodes: Array[Vector2] = []
	if pre > 0:
		nodes.append(a[pre - 1])
	if suf > 0:
		nodes.append(a[a.size() - suf])
	for i in range(maxi(pre - 1, 0), a.size() - maxi(suf, 1)):
		for j in range(maxi(pre - 1, 0), b.size() - maxi(suf, 1)):
			var d := PgGeom.seg_dist(a[i], a[i + 1], b[j], b[j + 1])
			if d >= ROAD_GAP:
				continue
			# у узла развилки/слияния дороги сходятся — это и есть узел
			var near_node := false
			for n in nodes:
				near_node = near_node or (_seg_touches(a[i], a[i + 1], n)
					and _seg_touches(b[j], b[j + 1], n))
			if not near_node:
				return false
	return true


static func _seg_touches(a: Vector2, b: Vector2, n: Vector2) -> bool:
	return n.distance_to(Geometry2D.get_closest_point_to_segment(n, a, b)) < 1.0
