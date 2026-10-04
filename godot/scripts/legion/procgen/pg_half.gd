class_name PgHalf
extends RefCounted
##
## Скелеты ПОЛОВИНЫ поля PvP (BOOK §12.2–12.3, docs/pvp/DESIGN.md §3). Половина строится в своей
## рамке PgGeom.world (стартово 800×900 мира): Котёл у дальнего (западного) края, стык — весь
## восточный край x = W, дороги идут от проёмов стыка к Котлу, дорога слабых волн PvE — от ворот
## на верхнем крае и вливается в одну из дорог стыка. Вторая половина — зеркало этой (PgPvp),
## поэтому всё, что лежит на самом стыке (стена стыка, река «переправы», мосты), строится
## симметричным относительно x = W и попадает в поле один раз.
##
## Числа архетипов — доли рамки (W, H), а не пиксели: половина другого размера (например
## 853×960 при масштабе 0,75) строится теми же правилами; негодное сочетание отсеивает
## PgArch.check, как у одиночных скелетов.
##
## Скелет — формат PgArch плюс nodes: "spans" (проёмы стыка [[a, b], …], y), "neutral" (Rect2
## нейтральной полосы у стыка), "pve_gate" (x ворот PvE), "seam" ("wall" или "river").
##

## Архетипы, которые влезают в половину (BOOK §12.3), и их веса (переправа — лучший кандидат).
## «Болото со склепами» (условно годен) не сделан: склепы у стыка спорят с нейтральной полосой.
## «Внутренний двор» (условно годен) не сделан: в 800 px ширины двор выходил подковой-змейкой
## без участков внутри (лист 27.09) — это не двор. Турникет — реже: двор за оградой тесноват
## (3 участка).
const ARCHETYPES: Array[String] = ["crossing", "fork", "snake", "boulevard", "turnstile",
	"pincers"]
const WEIGHTS := {"crossing": 1.6, "fork": 1.0, "snake": 1.0, "boulevard": 1.0,
	"turnstile": 0.5, "pincers": 1.0}
const TRIES := 40
## Старт дороги за краем рамки (как OFF_E/OFF_N одиночных скелетов).
const OFF := 80.0
## Проём стыка: 96–160 px, кратно 16 (BOOK §12.2).
const SPAN_W := Vector2i(96, 160)
## Между проёмами — не меньше куска стены.
const SPAN_GAP := 16
## Нейтральная полоса у стыка: 64–96 px, без участков, препятствий и ловушек.
const NEUTRAL := Vector2i(64, 96)
## Попыток вписать дорогу PvE в готовые дороги стыка.
const PVE_TRIES := 48
## Дорога PvE не ближе к стене скелета (полпролёта У-2 плюс толщина ограды).
const PVE_WALL_KEEP := 110.0
## Клещи: длинная дорога во столько раз длиннее короткой (LAYOUT.md: ≈ 1,15–1,3; здесь шире,
## половина теснее полной карты).
const PINCER_RATIO := Vector2(1.12, 1.6)
## Стена стыка по биому (вид звена каталога) — та же, что у кварталов этого биома.
const SEAM_WALL := {"grave": "stone", "ash": "stone", "swamp": "stone", "office": "shelf",
	"site": "fence"}
const SEAM_WALL_W := {"stone": 24.0, "shelf": 54.0, "fence": 20.0}


static func build(arch: String, rng: RandomNumberGenerator, card: Dictionary) -> Dictionary:
	for t in TRIES:
		var sk := _build_one(arch, rng)
		if sk.is_empty():
			continue
		if not _attach_pve(sk, rng):
			continue
		PgArch._chamfer(sk, rng)
		if not check(sk).is_empty():
			continue
		_finish(sk, rng, String(card.get("biome", "grave")), arch == "crossing")
		return sk
	return {}


static func _build_one(arch: String, rng: RandomNumberGenerator) -> Dictionary:
	match arch:
		"crossing":
			return _crossing(rng)
		"fork":
			return _fork(rng)
		"snake":
			return _snake(rng)
		"boulevard":
			return _boulevard(rng)
		"turnstile":
			return _turnstile(rng)
		"pincers":
			return _pincers(rng)
	return {}


# ── доли рамки ───────────────────────────────────────────────────────────────

## Случайное на сетке 16 в [lo·dim, hi·dim] (края внутрь сетки).
static func _rf(rng: RandomNumberGenerator, lo: float, hi: float, dim: float) -> int:
	var a := ceili(dim * lo / 16.0) * 16
	var b := floori(dim * hi / 16.0) * 16
	return PgRng.grid(rng, a, maxi(a, b))


static func _w() -> float:
	return PgGeom.world.x


static func _h() -> float:
	return PgGeom.world.y


## Старт дороги стыка за восточным краем рамки на строке y.
static func _e(y: int) -> Vector2:
	return Vector2(_w() + OFF, y)


## Котёл: обычный — у запада; «обхват» — правее, чтобы дороги успели зайти за него.
static func _cauldron(rng: RandomNumberGenerator, wrap: bool) -> Vector2:
	var x := _rf(rng, 0.34, 0.40, _w()) if wrap else _rf(rng, 0.22, 0.28, _w())
	return Vector2(x, _rf(rng, 0.46, 0.54, _h()))


## Строки дорог у верхнего и нижнего края: ниже панели HUD сверху (при 0,8 — y 62 и угол
## x < 400, y < 162) и выше панелей снизу (y > 787).
static func _top(rng: RandomNumberGenerator) -> int:
	return _rf(rng, 0.22, 0.27, _h())


static func _bottom(rng: RandomNumberGenerator) -> int:
	return _rf(rng, 0.75, 0.80, _h())


## Колонна «за Котлом» у западного края (EDGE_KEEP 96 от края).
static func _behind(rng: RandomNumberGenerator) -> int:
	return _rf(rng, 0.14, 0.16, _w())


static func _sk(c: Vector2, roads: Array, centers: Array) -> Dictionary:
	var sk := PgArch._sk(c, roads)
	sk["nodes"]["centers"] = centers
	return sk


# ── архетипы половины ────────────────────────────────────────────────────────

## Развилка: один проём посередине, две ветви обходят половину по верхнему и нижнему краю и
## сходятся за Котлом (резерв — между ветвями).
static func _fork(rng: RandomNumberGenerator) -> Dictionary:
	var c := _cauldron(rng, true)
	var cy := int(c.y)
	var g := PgRng.grid(rng, cy - 16, cy + 16)
	var xs := _rf(rng, 0.66, 0.80, _w())
	var x_w := _behind(rng)
	var roads: Array = []
	for north: bool in [true, false]:
		var edge := _top(rng) if north else _bottom(rng)
		roads.append([_e(g), Vector2(xs, g), Vector2(xs, edge), Vector2(x_w, edge),
			Vector2(x_w, cy), c])
	var sk := _sk(c, roads, [g])
	sk["nodes"]["split"] = Vector2(xs, g)
	sk["nodes"]["merge"] = Vector2(x_w, cy)
	return sk


## Переправа: два проёма — мосты через реку, текущую по стыку (изюминка поля — одна и
## симметричная: общая река и мосты на ней). Дороги обходят Котёл и сходятся за ним; у каждой
## может быть ступенька к краю.
static func _crossing(rng: RandomNumberGenerator) -> Dictionary:
	var c := _cauldron(rng, true)
	var cy := int(c.y)
	var x_w := _behind(rng)
	var g1 := _rf(rng, 0.30, 0.37, _h())
	var g2 := _rf(rng, 0.63, 0.70, _h())
	var roads: Array = []
	for north: bool in [true, false]:
		var g := g1 if north else g2
		var pts: Array = [_e(g)]
		if rng.randf() < 0.6:
			var xa := _rf(rng, 0.62, 0.76, _w())
			var edge := _top(rng) if north else _bottom(rng)
			pts.append_array([Vector2(xa, g), Vector2(xa, edge), Vector2(x_w, edge)])
		else:
			pts.append(Vector2(x_w, g))
		pts.append_array([Vector2(x_w, cy), c])
		roads.append(pts)
	var sk := _sk(c, roads, [g1, g2])
	sk["nodes"]["merge"] = Vector2(x_w, cy)
	return sk


## Змейка: один проём, одна или две петли во весь рост половины.
static func _snake(rng: RandomNumberGenerator) -> Dictionary:
	var c := _cauldron(rng, false)
	var cy := int(c.y)
	var down := rng.randf() < 0.5
	var xm := int(c.x) + PgArch._r(rng, Vector2i(144, 208))
	var pts: Array
	var g: int
	if rng.randf() < 0.5:
		# одна петля: вход у края, колено через всю высоту, заход к Котлу
		g = _rf(rng, 0.27, 0.34, _h()) if down else _rf(rng, 0.66, 0.73, _h())
		var x0 := _rf(rng, 0.62, 0.76, _w())
		var y1 := _bottom(rng) if down else _top(rng)
		pts = [_e(g), Vector2(x0, g), Vector2(x0, y1), Vector2(xm, y1), Vector2(xm, cy), c]
	else:
		# две петли: вход посередине, вверх (вниз), через всю высоту, к Котлу
		g = PgRng.grid(rng, cy - 32, cy + 32)
		var x0 := _rf(rng, 0.76, 0.84, _w())
		var x1 := x0 - PgArch._r(rng, Vector2i(144, 208))
		xm = mini(xm, x1 - 128)
		var y1 := _top(rng) if down else _bottom(rng)
		var y2 := _bottom(rng) if down else _top(rng)
		pts = [_e(g), Vector2(x0, g), Vector2(x0, y1), Vector2(x1, y1), Vector2(x1, y2),
			Vector2(xm, y2), Vector2(xm, cy), c]
	return _sk(c, [pts], [g])


## Бульвар: два соседних проёма, дороги идут параллельно в 112–144 px через полполовины,
## расходятся к верхнему и нижнему краю и сходятся за Котлом.
static func _boulevard(rng: RandomNumberGenerator) -> Dictionary:
	var c := _cauldron(rng, true)
	var cy := int(c.y)
	var yb1 := cy - PgArch._r(rng, Vector2i(48, 80))
	var yb2 := yb1 + PgArch._r(rng, Vector2i(112, 144))
	var xa := _rf(rng, 0.50, 0.60, _w())
	var x_w := _behind(rng)
	var roads: Array = []
	for north: bool in [true, false]:
		var y := yb1 if north else yb2
		var edge := _top(rng) if north else _bottom(rng)
		roads.append([_e(y), Vector2(xa, y), Vector2(xa, edge), Vector2(x_w, edge),
			Vector2(x_w, cy), c])
	var sk := _sk(c, roads, [yb1, yb2])
	sk["nodes"]["merge"] = Vector2(x_w, cy)
	sk["nodes"]["boulevard"] = Rect2(xa, yb1, _w() - xa, yb2 - yb1)
	return sk


## Двор с турникетом: вход по «улице» у стыка, ограда во всю высоту с проходом 112 px, за ней
## двор, две петли вокруг него и слияние у Котла.
static func _turnstile(rng: RandomNumberGenerator) -> Dictionary:
	var c := Vector2(_rf(rng, 0.20, 0.24, _w()), _rf(rng, 0.46, 0.54, _h()))
	var cy := int(c.y)
	var yt := PgRng.grid(rng, cy - 32, cy + 32)
	# вход снизу: колено улицы (xe, yt) — место, куда сверху вливается дорога PvE (по эту
	# сторону ограды, ≥ PVE_WALL_KEEP от неё); вход сверху лёг бы на неё внахлёст
	var g := _rf(rng, 0.70, 0.76, _h())
	var xe := _rf(rng, 0.80, 0.84, _w())
	var xf := xe - PgArch._r(rng, Vector2i(112, 128))
	var xs := xf - PgArch._r(rng, Vector2i(96, 112))
	var xm := int(c.x) + PgArch._r(rng, Vector2i(144, 160))
	if xs - xm < 112:
		return {}
	var yn := _top(rng)
	var ys := _bottom(rng)
	var head: Array = [_e(g), Vector2(xe, g), Vector2(xe, yt), Vector2(xs, yt)]
	var north := head + [Vector2(xs, yn), Vector2(xm, yn), Vector2(xm, cy), c]
	var south := head + [Vector2(xs, ys), Vector2(xm, ys), Vector2(xm, cy), c]
	var sk := _sk(c, [north, south], [g])
	var half := 56
	sk["walls"] = [{"path": [Vector2(xf, -4), Vector2(xf, yt - half)], "w": 18.0,
		"kind": "fence", "role": "turnstile"},
		{"path": [Vector2(xf, yt + half), Vector2(xf, _h() + 4.0)], "w": 18.0, "kind": "fence",
		"role": "turnstile"}]
	sk["nodes"]["yard"] = Rect2(xm, yn, xs - xm, ys - yn)
	sk["nodes"]["turnstile"] = Vector2(xf, yt)
	sk["nodes"]["split"] = Vector2(xs, yt)
	sk["nodes"]["merge"] = Vector2(xm, cy)
	return sk


## Клещи с опозданием: два проёма; длинная дорога обходит Котёл по краю и заходит сзади,
## короткая ступенькой по другой половине заходит спереди — приходят в разное время.
static func _pincers(rng: RandomNumberGenerator) -> Dictionary:
	var c := _cauldron(rng, true)
	var cy := int(c.y)
	var up := rng.randf() < 0.5
	var x_w := _behind(rng)
	var gl := _rf(rng, 0.30, 0.37, _h()) if up else _rf(rng, 0.63, 0.70, _h())
	var gs := _rf(rng, 0.63, 0.70, _h()) if up else _rf(rng, 0.30, 0.37, _h())
	var xa := _rf(rng, 0.62, 0.74, _w())
	var edge := _top(rng) if up else _bottom(rng)
	var long: Array = [_e(gl), Vector2(xa, gl), Vector2(xa, edge), Vector2(x_w, edge),
		Vector2(x_w, cy), c]
	var x0 := _rf(rng, 0.76, 0.84, _w())
	var yo := _bottom(rng) if up else _top(rng)
	var xe := int(c.x) + PgArch._r(rng, Vector2i(144, 176))
	var short: Array = [_e(gs), Vector2(x0, gs), Vector2(x0, yo), Vector2(xe, yo),
		Vector2(xe, cy), c]
	var ratio := PgGeom.length(PackedVector2Array(long)) / PgGeom.length(PackedVector2Array(short))
	if ratio < PINCER_RATIO.x or ratio > PINCER_RATIO.y:
		return {}
	var sk := _sk(c, [long, short] if up else [short, long], [gl, gs] if up else [gs, gl])
	sk["nodes"]["long"] = 0 if up else 1
	sk["nodes"]["short"] = 1 if up else 0
	return sk


# ── дорога слабых волн PvE ───────────────────────────────────────────────────

## Ворота PvE — на верхнем свободном отрезке края половины (DESIGN §2.6); дорога спускается
## отвесно и вливается в одну из дорог стыка (общий хвост до Котла — одна дорога в голове
## игрока, а не третья). Пробуем точки вливания на горизонталях дорог стыка, пока скелет не
## пройдёт PgArch.check.
static func _attach_pve(sk: Dictionary, rng: RandomNumberGenerator) -> bool:
	var span: Vector2 = PgGeom.spans["north"]
	var lo := ceili((span.x + PgGeom.GATE_HALF) / 16.0) * 16
	var hi := floori((span.y - PgGeom.GATE_HALF) / 16.0) * 16
	var roads: Array = sk["roads"]
	var cands: Array = []
	for ri in roads.size():
		var p: PackedVector2Array = roads[ri]["pts"]
		for i in range(0, p.size() - 2):
			var a := p[i]
			var b := p[i + 1]
			if a.y != b.y:
				continue
			var x0 := maxi(lo, ceili(minf(a.x, b.x) / 16.0) * 16)
			var x1 := mini(hi, floori(maxf(a.x, b.x) / 16.0) * 16)
			var x := x0
			while x <= x1:
				cands.append([ri, i, Vector2(x, a.y)])
				x += 16
	cands = PgRng.shuffled(rng, cands)
	for n in mini(cands.size(), PVE_TRIES):
		var cand: Array = cands[n]
		var ri: int = cand[0]
		var i: int = cand[1]
		var j: Vector2 = cand[2]
		if _near_wall(sk, Vector2(j.x, 0.0), j):
			continue
		var p: PackedVector2Array = roads[ri]["pts"]
		var joined := PackedVector2Array()
		for k in i + 1:
			joined.append(p[k])
		if j != p[i]:
			joined.append(j)
		var at := joined.size() - 1
		for k in range(i + 1, p.size()):
			if p[k] != j:
				joined.append(p[k])
		var pve := PackedVector2Array([Vector2(j.x, -OFF)])
		for k in range(at, joined.size()):
			pve.append(joined[k])
		var trial := sk.duplicate(true)
		trial["roads"][ri]["pts"] = joined
		trial["roads"].append({"id": "r%d" % roads.size(), "pts": pve})
		trial["nodes"]["pve_join"] = j
		trial["nodes"]["pve_road"] = roads.size()
		if check(trial).is_empty():
			sk["roads"] = trial["roads"]
			sk["nodes"] = trial["nodes"]
			sk["nodes"]["pve_gate"] = int(j.x)
			return true
	return false


## Проверка скелета половины: дороги стыка — как одиночные (PgArch.check); дорога PvE — своя
## проверка дороги (ворота, извилистость, повороты, Котёл) и отвес до точки вливания не ближе
## ROAD_GAP к чужим дорогам. Общую проверку пар дорог на дорогу PvE не пускаем: она вливается в
## середину дороги, которая у двора с турникетом общая для двух ветвей (ни начало, ни конец), —
## пара «PvE — вторая ветвь» там совпадает по отрезку, и это не пересечение, а общий ствол.
static func check(sk: Dictionary) -> String:
	var roads: Array = sk["roads"]
	var pve_i := int(sk["nodes"].get("pve_road", -1))
	var rest := sk.duplicate()
	rest["roads"] = []
	for i in roads.size():
		if i != pve_i:
			rest["roads"].append(roads[i])
	var why := PgArch.check(rest, false)
	if not why.is_empty() or pve_i < 0:
		return why
	var p: PackedVector2Array = roads[pve_i]["pts"]
	why = PgArch._check_road(p, sk["cauldron"], false)
	if not why.is_empty():
		return "дорога PvE: " + why
	var j: Vector2 = sk["nodes"]["pve_join"]
	var k := p.find(j)
	for i in k:
		for other: Dictionary in rest["roads"]:
			var q: PackedVector2Array = other["pts"]
			for m in range(1, q.size()):
				if PgArch._seg_touches(p[i], p[i + 1], j) and PgArch._seg_touches(q[m - 1], q[m], j):
					continue
				if PgGeom.seg_dist(p[i], p[i + 1], q[m - 1], q[m]) < PgArch.ROAD_GAP:
					return "дорога PvE у чужой дороги"
	return ""


## Отвесная дорога PvE вдоль ограды скелета (турникет) легла бы на стену: такие точки мимо.
static func _near_wall(sk: Dictionary, a: Vector2, b: Vector2) -> bool:
	for wl: Dictionary in sk["walls"]:
		var path: Array = wl["path"]
		for i in range(1, path.size()):
			if PgGeom.seg_dist(a, b, path[i - 1], path[i]) < PVE_WALL_KEEP:
				return true
	return false


# ── стык ─────────────────────────────────────────────────────────────────────

## Проёмы, нейтральная полоса и граница стыка: стена по x = W с разрывами на проёмах или
## (переправа) река по стыку с мостами на проёмах. Всё симметрично относительно x = W.
static func _finish(sk: Dictionary, rng: RandomNumberGenerator, biome: String, river: bool) -> void:
	var w := _w()
	var span: Vector2 = PgGeom.spans["east"]
	var centers: Array = sk["nodes"]["centers"]
	var spans: Array = []
	for i in centers.size():
		var g := int(centers[i])
		var width := PgRng.grid(rng, SPAN_W.x, SPAN_W.y)
		# соседний проём и края свободного отрезка ограничивают ширину
		var room_lo := float(span.x) if i == 0 else float(int(centers[i - 1]) + g) * 0.5
		var room_hi := float(span.y) if i == centers.size() - 1 \
			else float(int(centers[i + 1]) + g) * 0.5
		while width > SPAN_W.x:
			var a0 := floori((g - width * 0.5) / 16.0) * 16
			if a0 >= room_lo + (SPAN_GAP * 0.5 if i > 0 else 0.0) \
					and a0 + width <= room_hi - (SPAN_GAP * 0.5 if i < centers.size() - 1 else 0.0):
				break
			width -= 16
		var a := floori((g - width * 0.5) / 16.0) * 16
		spans.append([a, a + width])
	sk["nodes"]["spans"] = spans
	var n := PgRng.grid(rng, NEUTRAL.x, NEUTRAL.y)
	sk["nodes"]["neutral"] = Rect2(w - n, 0.0, n, _h())
	if river:
		sk["nodes"]["seam"] = "river"
		var ys: Array[int] = []
		for s: Array in spans:
			ys.append((int(s[0]) + int(s[1])) / 2)
		sk["water"].append(_seam_river(rng, ys, spans))
		for s: Array in spans:
			sk["bridges"].append(PgGeom.rect_poly(Rect2(w - PgArch.BRIDGE_LEN * 0.5, s[0],
				PgArch.BRIDGE_LEN, int(s[1]) - int(s[0]))))
		return
	sk["nodes"]["seam"] = "wall"
	var kind := String(SEAM_WALL.get(biome, "stone"))
	var y := -4.0
	for s: Array in spans + [[_h() + 4.0, _h() + 4.0]]:
		if float(s[0]) - y >= 16.0:
			sk["walls"].append({"path": [Vector2(w, y), Vector2(w, float(s[0]))],
				"w": SEAM_WALL_W[kind], "kind": kind, "role": "seam"})
		y = float(s[1])


## Река по стыку, симметричная относительно x = W (берега отражают друг друга); у мостов —
## ровная, чтобы мост накрыл воду целиком.
static func _seam_river(rng: RandomNumberGenerator, ys: Array[int], spans: Array) \
		-> PackedVector2Array:
	var w := _w()
	var left: Array = []
	var right: Array = []
	var y := -40.0
	while y <= _h() + 40.0:
		var near := false
		for yb in ys:
			near = near or absf(y - yb) <= 80.0
		for s: Array in spans:
			near = near or (y >= float(s[0]) - 40.0 and y <= float(s[1]) + 40.0)
		var dx := 0.0 if near else float(rng.randi_range(-1, 1) * 16)
		left.append(Vector2(w - PgArch.RIVER_HALF - dx, y))
		right.append(Vector2(w + PgArch.RIVER_HALF + dx, y))
		y += 80.0
	right.reverse()
	return PackedVector2Array(left + right)
