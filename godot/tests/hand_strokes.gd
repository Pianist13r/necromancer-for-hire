extends RefCounted
##
## Генератор рукописных штрихов фигур (B-490): общий для tests/legion_figures_hand_test.gd и
## разовых замеров. Одна модель «руки» на все фигуры: идеальный контур → неровность формы
## (своя у каждой фигуры) → скругление вершин скользящим средним до 14 px → начало где угодно
## на контуре → недотяг конца 10–25 px → точки через равные доли времени (у углов рука в 3 раза
## медленнее), 40–120 точек на штрих, дрожь до 1,5 px. Размер — большая сторона bbox 120–220 px,
## длина штриха не больше 690 px (предел фигуры FigureCfg.FIG_LEN_MAX 720).
##

const CENTER := Vector2(640.0, 360.0)
const LEN_CAP := 690.0

var rng := RandomNumberGenerator.new()
## Углы последнего штриха (вершины многоугольника, концы прямой «D»; у круга и восьмёрки пусто) —
## для разбора промахов.
var last_corners := PackedVector2Array()


## Штрих фигуры по имени вида ContractShape (ring/eight/triangle/square/pentagon/d_shape) или
## «oval» — вытянутый овал (кольцо).
# gdlint: disable=max-returns
func stroke(kind: StringName) -> PackedVector2Array:
	match kind:
		&"triangle":
			return poly(3, 48.0, 72.0)
		&"square":
			return poly(4, 80.0, 100.0)
		&"pentagon":
			return poly(5, 100.0, 120.0)
		&"d_shape":
			return d_shape()
		&"eight":
			return eight()
		&"oval":
			return ring(0.45, 0.7)
	return ring()


## Многоугольник: sides вершин, внутренние углы lo…hi°, рёбра ±20 % от среднего, прогиб рёбер
## до 4 % длины.
func poly(sides: int, lo: float, hi: float) -> PackedVector2Array:
	var verts := PackedVector2Array()
	while true:
		var r := rng.randf_range(120.0, 220.0) / 1.9
		var rot := rng.randf() * TAU
		var dir := 1.0 if rng.randf() < 0.5 else -1.0
		verts.clear()
		for i in sides:
			var a := rot + dir * (TAU * i / sides + rng.randf_range(-0.16, 0.16))
			verts.append(CENTER + Vector2.from_angle(a) * r * rng.randf_range(0.85, 1.15))
		if _poly_ok(verts, lo, hi):
			break
	var bow := rng.randf_range(0.0, 0.04)
	var fine := PackedVector2Array()
	for e in sides:
		fine.append_array(_edge(verts[e], verts[(e + 1) % sides], bow))
	return _hand(fine, verts)


## «D»: прямое ребро (прогиб до 3 %) любой ориентации и дуга от его конца к началу —
## полуэллипс с выпуклостью 0,75…1,15 полуребра и волной радиуса до 6 %.
func d_shape() -> PackedVector2Array:
	var side := rng.randf_range(120.0, 220.0)
	var u := Vector2.from_angle(rng.randf() * TAU)
	var nrm := u.orthogonal() * (1.0 if rng.randf() < 0.5 else -1.0)
	var a := CENTER - u * side * 0.5
	var b := CENTER + u * side * 0.5
	var fine := _edge(a, b, rng.randf_range(0.0, 0.03))
	var bulge := rng.randf_range(0.75, 1.15)
	var wob := rng.randf_range(0.0, 0.06)
	var ph := rng.randf() * TAU
	var n := ceili(PI * side * 0.5 * bulge)
	for k in n:
		var t := PI * float(k) / n
		var w := 1.0 + wob * sin(3.0 * t + ph)
		fine.append(CENTER + u * cos(t) * side * 0.5 * w + nrm * sin(t) * side * 0.5 * bulge * w)
	return _hand(fine, PackedVector2Array([a, b]))


## Круг/овал: полуоси 1 : 0,7…1, волна радиуса до 8 %.
## «oval» — вытянутый 0,45…0,7: соблазн для «D» (плоский бок похож на прямую сторону).
func ring(lo := 0.7, hi := 1.0) -> PackedVector2Array:
	var rx := rng.randf_range(120.0, 220.0) * 0.5
	var ry := rx * rng.randf_range(lo, hi)
	var rot := rng.randf() * TAU
	var wob := rng.randf_range(0.0, 0.08)
	var ph := rng.randf() * TAU
	var fine := PackedVector2Array()
	var n := ceili(TAU * rx)
	for k in n:
		var t := TAU * float(k) / n
		var w := 1.0 + wob * sin(3.0 * t + ph)
		fine.append(CENTER + Vector2(cos(t) * rx * w, sin(t) * ry * w).rotated(rot))
	return _hand(fine, PackedVector2Array())


## Восьмёрка (лемниската Жероно): петли разного размера (до 1 : 1,3), высота петли 0,8…1,3 от
## ширины, волна до 6 %.
func eight() -> PackedVector2Array:
	var size := rng.randf_range(120.0, 220.0)
	var a := size * 0.5
	var b := a * rng.randf_range(0.8, 1.3)
	var asym := rng.randf_range(0.77, 1.3)
	var rot := rng.randf() * TAU
	var wob := rng.randf_range(0.0, 0.06)
	var ph := rng.randf() * TAU
	var fine := PackedVector2Array()
	var n := 900
	for k in n:
		var t := TAU * float(k) / n
		var s := asym if sin(t) > 0.0 else 1.0
		var w := 1.0 + wob * sin(5.0 * t + ph)
		fine.append(CENTER + Vector2(a * sin(t) * s * w, b * sin(t) * cos(t) * s * w).rotated(rot))
	return _hand(fine, PackedVector2Array())


## Ребро a→b с прогибом bow (доля длины) в случайную сторону, шаг 1 px, без точки b.
func _edge(a: Vector2, b: Vector2, bow: float) -> PackedVector2Array:
	var ln := a.distance_to(b)
	var sag := (b - a).orthogonal().normalized() * ln * bow * (1.0 if rng.randf() < 0.5 else -1.0)
	var out := PackedVector2Array()
	var m := ceili(ln)
	for k in m:
		var t := float(k) / m
		out.append(a.lerp(b, t) + sag * 4.0 * t * (1.0 - t))
	return out


## Рука по замкнутому тонкому контуру fine (шаг ~1 px): скругление, начало, недотяг, время.
func _hand(fine: PackedVector2Array, corners: PackedVector2Array) -> PackedVector2Array:
	var nf := fine.size()
	var total := 0.0
	for k in nf:
		total += fine[k].distance_to(fine[(k + 1) % nf])
	# длинный контур ужимается к центру: штрих длиннее предела фигуры игра бы не приняла
	if total > LEN_CAP:
		var sc := LEN_CAP / total
		for k in nf:
			fine[k] = CENTER + (fine[k] - CENTER) * sc
		for k in corners.size():
			corners[k] = CENTER + (corners[k] - CENTER) * sc
		total = LEN_CAP
	last_corners = corners
	var win := int(rng.randf_range(0.0, 14.0))
	var smooth := PackedVector2Array()
	for k in nf:
		var s := Vector2.ZERO
		for q in range(-win, win + 1):
			s += fine[posmod(k + q, nf)]
		smooth.append(s / (2 * win + 1))
	var start := rng.randi_range(0, nf - 1)
	var gap := rng.randf_range(10.0, 25.0)
	var path := PackedVector2Array()
	var acc := 0.0
	for k in nf:
		var p := smooth[(start + k) % nf]
		if not path.is_empty():
			acc += p.distance_to(path[path.size() - 1])
		if acc > total - gap:
			break
		path.append(p)
	var tau := PackedFloat32Array([0.0])
	for k in range(1, path.size()):
		var near := INF
		for v in corners:
			near = minf(near, path[k].distance_to(v))
		var speed := 0.35 + 0.65 * clampf(near / 30.0, 0.0, 1.0)
		tau.append(tau[k - 1] + path[k].distance_to(path[k - 1]) / speed)
	var cnt := rng.randi_range(40, 120)
	var j := rng.randf_range(0.5, 1.5)
	var out := PackedVector2Array()
	var idx := 0
	for i in cnt + 1:
		var tt := tau[tau.size() - 1] * i / cnt
		while idx < tau.size() - 1 and tau[idx + 1] < tt:
			idx += 1
		out.append(path[idx] + Vector2(rng.randf_range(-j, j), rng.randf_range(-j, j)))
	return out


static func _poly_ok(v: PackedVector2Array, lo: float, hi: float) -> bool:
	var n := v.size()
	var e_mean := 0.0
	for e in n:
		e_mean += v[e].distance_to(v[(e + 1) % n]) / n
	var sgn := 0.0
	for e in n:
		var ln := v[e].distance_to(v[(e + 1) % n])
		if ln < e_mean * 0.8 or ln > e_mean * 1.2:
			return false
		var t := (v[e] - v[(e + n - 1) % n]).angle_to(v[(e + 1) % n] - v[e])
		if sgn == 0.0:
			sgn = signf(t)
		elif signf(t) != sgn:
			return false
		var inner := 180.0 - rad_to_deg(absf(t))
		if inner < lo or inner > hi:
			return false
	return true
