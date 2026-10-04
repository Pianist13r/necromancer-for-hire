class_name ContractShape
extends RefCounted
##
## Фигуры договора (идея Игоря 26.09: «рисуешь форму — получаешь бонус», как жесты фехтования в
## «Робин Гуд: Легенда Шервуда»). Первая фигура — замкнутый круг, «Оцепление».
##
## Урок Robin Hood: жест, который легко нарисовать случайно, хуже отсутствия жеста. Поэтому кольцо
## признаётся только по ЧЕТЫРЁМ признакам сразу — конец у начала, длина, «круглость» и полный
## оборот. Прямая, L, S-дуга вдоль дороги, U-разворот, зигзаг, петля на конце линии, короткая
## дуга — не кольцо (корпус штрихов — tests/legion_ring_test.gd). Ложное срабатывание хуже пропуска.
## Ещё фигуры: восьмёрка (26.09), треугольник и квадрат (D-1002-03, вместо звезды 26.09).
##
## Здесь только геометрия (статические функции без состояния): распознавание, центр, «внутри».
## Числа — локальные const: legion_cfg.gd упёрся в потолок gdlint (так делали соседи).
##

## Конец штриха ближе max(RING_GAP_MIN, RING_GAP_FRAC · длина) к началу — фигура замкнута.
## 28 px — зазор, который оставляет рука, «недотянувшая» круг; 12 % — у большого круга рука
## промахивается сильнее.
const RING_GAP_MIN := 28.0
const RING_GAP_FRAC := 0.12
## Кольцо не короче 220 px (радиус ~35): меньше — места строя ложатся кучкой, а «круг» из
## 60 px рисуется случайно при каждом росчерке.
const RING_MIN_LEN := 220.0
## Круглость 4πS/P²: круг 1.0, овал 2:1 ≈ 0.84, 3:1 ≈ 0.66, узкий U-разворот ≈ 0.3.
const RING_ROUND_MIN := 0.5
## Суммарный поворот касательной ≈ ±2π (±30 %): восьмёрка даёт ≈ 0, полтора витка спирали ≈ 3π.
const RING_TURN_TOL := 0.3
## Отрезки короче этого в подсчёте поворота не участвуют: дрожь мыши по 1–2 px даёт углы в
## десятки градусов, которые не значат ничего.
const TURN_MIN_SEG := 4.0
const RING_MIN_POINTS := 8
## Натиск кольца к центру кончается за центром не дальше этого (LegionWorld._ring_cap).
const RING_OVERRUN := 20.0

## Виды фигур (Contract.figure; кольцо исторически — отдельный флаг Contract.ring).
const RING := &"ring"
const EIGHT := &"eight"
const TRIANGLE := &"triangle"
const SQUARE := &"square"

## Восьмёрка, треугольник и квадрат тоже замкнуты: конец у начала (как у кольца, чуть щедрее —
## у фигуры длиннее штрих и рука дальше уходит от начала).
const FIG_GAP_MIN := 34.0
const FIG_GAP_FRAC := 0.12
## Штрих пересэмплируется на ~RESAMPLE_N равных шагов (не мельче RESAMPLE_MIN_STEP px): дрожь
## мыши по 1–2 px пропадает, а перебор пар отрезков остаётся дешёвым (~100² / 2 на штрих).
const RESAMPLE_N := 96
const RESAMPLE_MIN_STEP := 5.0

## Восьмёрка: ровно одна «перетяжка» — место, где штрих проходит сам через себя (или
## вплотную, EIGHT_CROSS_TOL px), и она делит фигуру на две петли, каждая не короче
## EIGHT_LOBE_MIN длины. Петли — «круглые» (круглость как у кольца, мягче: петля восьмёрки
## — капля) и закручены В РАЗНЫЕ стороны: это и отличает восьмёрку от двойного витка или
## петли внутри петли (там обе закручены одинаково). Итоговый поворот ≈ 0 (кольцо ≈ 2π).
const EIGHT_MIN_LEN := 300.0
const EIGHT_MIN_POINTS := 16
const EIGHT_LOBE_MIN := 0.25
const EIGHT_CROSS_TOL := 12.0
const EIGHT_ROUND_MIN := 0.4
## Меньшая петля — не меньше этой доли площади большей: «капля с хвостиком» — не восьмёрка.
const EIGHT_AREA_RATIO := 0.3
const EIGHT_NET_TURN := 0.35
## Петля — дуга, а не «D»: самый длинный почти прямой кусок не длиннее этой доли её периметра.
## Так отсекается «S-дуга и прямой возврат к началу» — каракуля, которая по топологии восьмёрка,
## но на глаз ею не выглядит (у восьмёрок рукой ≤ 0.34). «Почти прямой» (B-073) — все точки
## куска (сглаженного [1 2 1]) близко к его хорде — не дальше EIGHT_STRAIGHT_DEV_K её длины и не
## меньше EIGHT_STRAIGHT_DEV_MIN px. Раньше мерили поворот соседних шагов (< 0.25 рад от первого),
## и дрожь руки 1,5–2 px на шаге 5 px рвала прямой возврат на куски — каракуля признавалась
## восьмёркой 42–46 раз из 50. Дуга прогибается от хорды на L/(8R) её длины — у петли заметно.
const EIGHT_STRAIGHT_MAX := 0.36
const EIGHT_STRAIGHT_DEV_K := 0.04
const EIGHT_STRAIGHT_DEV_MIN := 2.0
## В перетяжке штрих ПЕРЕСЕКАЕТ сам себя под углом не меньше этого (рад, ~25°): касание по
## касательной — это две петли рядом, а не восьмёрка.
const EIGHT_CROSS_MIN := 0.44

## Треугольник «Обряд» и квадрат «Каре» (D-1002-03: звезду рукой почти не нарисовать — её место
## занял треугольник, квадрат — новая фигура). Мышь даёт точку на событие движения, а Godot
## копит движение до кадра: быстрая рука кладёт точки через 15–30 px, на фигуру бывает 8–12
## точек. Поэтому вершины ищутся не окном в отсчётах, а по упрощённой ломаной (verifier 02.10:
## окно в 3 отсчёта срезало угол квадрата до 60–85°, быстрый квадрат становился линией и кольцом):
##  · замкнут (как восьмёрка: FIG_GAP_*), перелёт конца за начало срезается (trim_overshoot);
##  · длина не меньше POLY_MIN_LEN;
##  · штрих упрощается Рамером–Дугласом–Пейкером с допуском POLY_RDP_K · длина (≥ POLY_RDP_MIN
##    px): у круга остаётся ≥ 6 отрезков, у многоугольника — его рёбра и срезы углов;
##  · отрезки короче POLY_MERGE_K · длина — срез угла: соседние изломы сливаются в одну вершину,
##    её поворот — сумма, сама вершина — пересечение прямых соседних рёбер;
##  · вершина — излом от CORNER_MIN (~50°); изломы мягче POLY_BEND_MAX (~30°) — изгиб ребра;
##    между ними — не фигура (неясно, угол это или дуга);
##  · ровно 3 / 4 вершины, все в одну сторону, сумма всех изломов ≈ 2π (±POLY_TURN_TOL);
##  · каждая точка штриха ближе max(POLY_STRAIGHT_MIN px, POLY_STRAIGHT_K · ребро) к контуру по
##    вершинам — рёбра прямые: круг, овал, «D» и сильно скруглённый квадрат не проходят;
##  · каждая вершина ≥ TIP_MIN (~65°: у ложного «квадрата» из 8–12 точек круга один угол
##    бывает 50–65°), у квадрата ещё и ≤ SQUARE_TIP_MAX (~125°): ромб и «кривой квадрат» —
##    квадрат;
##  · рёбра похожей длины: короткое ≥ POLY_EDGE_RATIO длинного (вытянутый клин — пропуск).
## Кольцо не признаёт штрих, который проходит эти проверки без двух последних (is_ring): квадрат
## больше не «Оцепление» (B-069), а круг с рывками мыши остаётся кольцом. Корпус —
## tests/legion_figures_test.gd (и быстрые штрихи — там же).
const POLY_MIN_LEN := 240.0
const POLY_MIN_POINTS := 6
const POLY_RDP_K := 0.025
const POLY_RDP_MIN := 4.0
const POLY_MERGE_K := 0.11
const POLY_MERGE_REL := 0.5
const CORNER_MIN := 0.87
const POLY_BEND_MAX := 0.52
const TIP_MIN := 1.13
const SQUARE_TIP_MAX := 2.18
const POLY_TURN_TOL := 0.2
const POLY_STRAIGHT_K := 0.06
const POLY_STRAIGHT_MIN := 4.5
const POLY_EDGE_RATIO := 0.35


## Кольцо ли штрих (см. заголовок). pts — ломаная как нарисована, без замыкания.
static func is_ring(pts: PackedVector2Array) -> bool:
	if pts.size() < RING_MIN_POINTS:
		return false
	var length := poly_len(pts)
	if length < RING_MIN_LEN:
		return false
	var gap := pts[0].distance_to(pts[pts.size() - 1])
	if gap > maxf(RING_GAP_MIN, RING_GAP_FRAC * length):
		return false
	var perim := length + gap
	var area := absf(signed_area(pts))
	if 4.0 * PI * area / (perim * perim) < RING_ROUND_MIN:
		return false
	var turn := absf(total_turn(pts))
	if absf(turn - TAU) > TAU * RING_TURN_TOL:
		return false
	# многоугольник с 3–4 прямыми рёбрами — треугольник или квадрат (или их недобор по углам и
	# пропорциям), а не круг (D-1002-03); круг с рывками сюда не попадает — у него рёбра не прямые
	return polygon_fit(pts).is_empty()


## Замкнуть ломаную: дотянуть конец до начала (зазор недотянутого круга закрывается бесплатно —
## это часть фигуры, а не новая длина штриха).
static func closed(pts: PackedVector2Array) -> PackedVector2Array:
	var out := pts.duplicate()
	if out.size() >= 2 and out[0].distance_to(out[out.size() - 1]) > 0.5:
		out.append(out[0])
	return out


## Центр масс многоугольника (для кольца неровной руки — честнее среднего точек: штрих
## гуще там, где мышь шла медленнее).
static func centroid(pts: PackedVector2Array) -> Vector2:
	var a := 0.0
	var c := Vector2.ZERO
	var n := pts.size()
	for i in n:
		var p := pts[i]
		var q := pts[(i + 1) % n]
		var cross := p.cross(q)
		a += cross
		c += (p + q) * cross
	if absf(a) < 1e-3:
		var s := Vector2.ZERO
		for p in pts:
			s += p
		return s / float(maxi(1, n))
	return c / (3.0 * a)


## Площадь со знаком (формула шнурков), многоугольник замыкается сам.
static func signed_area(pts: PackedVector2Array) -> float:
	var a := 0.0
	var n := pts.size()
	for i in n:
		a += pts[i].cross(pts[(i + 1) % n])
	return a * 0.5


## Суммарный поворот направления штриха, рад (со знаком): у круга ±2π.
static func total_turn(pts: PackedVector2Array) -> float:
	var turn := 0.0
	var prev := Vector2.ZERO
	var anchor := pts[0]
	for i in range(1, pts.size()):
		var d := pts[i] - anchor
		if d.length() < TURN_MIN_SEG:
			continue
		anchor = pts[i]
		if prev != Vector2.ZERO:
			turn += prev.angle_to(d)
		prev = d
	return turn


static func poly_len(pts: PackedVector2Array) -> float:
	var s := 0.0
	for i in range(1, pts.size()):
		s += pts[i].distance_to(pts[i - 1])
	return s


## Точка внутри кольца (Пробел над кольцом: внутри — стрелки к центру, снаружи — наружу).
static func inside(p: Vector2, pts: PackedVector2Array) -> bool:
	return Geometry2D.is_point_in_polygon(p, pts)


# ── Восьмёрка (просьба Игоря 26.09), треугольник и квадрат (D-1002-03) ──────────

## Что за фигура штрих: EIGHT / TRIANGLE / SQUARE / RING или &"" (обычная линия). Восьмёрка
## (итоговый поворот ≈ 0) с прочими не пересекается; многоугольник проверяется раньше кольца,
## а кольцо и само не признаёт фигуру с 3–4 вершинами.
static func classify(pts: PackedVector2Array) -> StringName:
	if is_eight(pts):
		return EIGHT
	var poly := polygon_kind(pts)
	if poly != &"":
		return poly
	if is_ring(pts):
		return RING
	return &""


## Замкнут ли штрих фигуры и какой у него зазор; -1 — не замкнут.
static func _fig_gap(pts: PackedVector2Array, length: float) -> float:
	var gap := pts[0].distance_to(pts[pts.size() - 1])
	return gap if gap <= maxf(FIG_GAP_MIN, FIG_GAP_FRAC * length) else -1.0


## Замкнутый штрих равными шагами (без повторной первой точки в конце: ломаная циклическая).
static func resample_closed(pts: PackedVector2Array) -> PackedVector2Array:
	var loop := closed(pts)
	var total := poly_len(loop)
	var out := PackedVector2Array()
	if total <= 0.0:
		return out
	var n := maxi(3, int(total / maxf(RESAMPLE_MIN_STEP, total / RESAMPLE_N)))
	var st := total / n
	var i := 1
	var acc := 0.0
	for k in n:
		var d := k * st
		while i < loop.size() - 1 and acc + loop[i - 1].distance_to(loop[i]) < d:
			acc += loop[i - 1].distance_to(loop[i])
			i += 1
		var seg := loop[i - 1].distance_to(loop[i])
		var t := 0.0 if seg <= 0.0 else clampf((d - acc) / seg, 0.0, 1.0)
		out.append(loop[i - 1].lerp(loop[i], t))
	return out


## Суммарный поворот циклической ломаной, рад, со знаком (у ровного круга ±2π).
static func cyclic_turn(rs: PackedVector2Array) -> float:
	var n := rs.size()
	var t := 0.0
	for i in n:
		var a := rs[(i + 1) % n] - rs[i]
		var b := rs[(i + 2) % n] - rs[(i + 1) % n]
		if a != Vector2.ZERO and b != Vector2.ZERO:
			t += a.angle_to(b)
	return t


## Круглость многоугольника 4πS/P² (замыкается сам): круг 1, капля ~0.7, щель ~0.
static func roundness(poly: PackedVector2Array) -> float:
	var perim := poly_len(poly) + poly[0].distance_to(poly[poly.size() - 1])
	if perim <= 0.0:
		return 0.0
	return 4.0 * PI * absf(signed_area(poly)) / (perim * perim)


static func is_eight(pts: PackedVector2Array) -> bool:
	if pts.size() < EIGHT_MIN_POINTS:
		return false
	var length := poly_len(pts)
	if length < EIGHT_MIN_LEN or _fig_gap(pts, length) < 0.0:
		return false
	var rs := resample_closed(pts)
	if absf(cyclic_turn(rs)) > TAU * EIGHT_NET_TURN:
		return false
	return not eight_lobes(rs).is_empty()


## Разбор восьмёрки по пересэмплированной циклической ломаной rs: {a, b — доли длины, где
## штрих проходит перетяжку (петля A — между ними), centers — центры петель A и B}; {} — не
## восьмёрка. Перетяжка — пара отрезков через ≥ EIGHT_LOBE_MIN длины в обе стороны, которые
## пересекаются (лучше) или сходятся ближе EIGHT_CROSS_TOL; из таких — самая «ровная» делёжка.
static func eight_lobes(rs: PackedVector2Array) -> Dictionary:
	var n := rs.size()
	var min_sep := ceili(n * EIGHT_LOBE_MIN)
	var best_i := -1
	var best_j := -1
	var best_score := -INF
	for i in n:
		var a0 := rs[i]
		var a1 := rs[(i + 1) % n]
		for j in range(i + min_sep, mini(n, n - min_sep + i + 1)):
			var b0 := rs[j]
			var b1 := rs[(j + 1) % n]
			# дёшево отсечь далёкие пары (шаг ломаной ≤ 7,5 px, отрезки короче этого запаса)
			if a0.distance_squared_to(b0) > EIGHT_CROSS_TOL * EIGHT_CROSS_TOL * 9.0:
				continue
			var score := float(mini(j - i, n - (j - i))) / n
			if Geometry2D.segment_intersects_segment(a0, a1, b0, b1) != null:
				score += 1.0
			else:
				var d := minf(
					minf(a0.distance_to(Geometry2D.get_closest_point_to_segment(a0, b0, b1)),
						a1.distance_to(Geometry2D.get_closest_point_to_segment(a1, b0, b1))),
					minf(b0.distance_to(Geometry2D.get_closest_point_to_segment(b0, a0, a1)),
						b1.distance_to(Geometry2D.get_closest_point_to_segment(b1, a0, a1))))
				if d > EIGHT_CROSS_TOL:
					continue
				score += 0.5 - 0.5 * d / EIGHT_CROSS_TOL
			if score > best_score:
				best_score = score
				best_i = i
				best_j = j
	if best_i < 0:
		return {}
	var lobe_a := rs.slice(best_i + 1, best_j + 1)
	var lobe_b := rs.slice(best_j + 1)
	lobe_b.append_array(rs.slice(0, best_i + 1))
	if lobe_a.size() < 3 or lobe_b.size() < 3:
		return {}
	var area_a := signed_area(lobe_a)
	var area_b := signed_area(lobe_b)
	if area_a * area_b >= 0.0:
		return {}   # обе петли закручены в одну сторону — двойной виток, а не восьмёрка
	if minf(absf(area_a), absf(area_b)) < EIGHT_AREA_RATIO * maxf(absf(area_a), absf(area_b)):
		return {}
	if roundness(lobe_a) < EIGHT_ROUND_MIN or roundness(lobe_b) < EIGHT_ROUND_MIN:
		return {}
	if straight_share(lobe_a) > EIGHT_STRAIGHT_MAX or straight_share(lobe_b) > EIGHT_STRAIGHT_MAX:
		return {}
	# угол перетяжки — по хордам через 2 шага: одиночный шаг ломаной дрожит
	var da := rs[(best_i + 2) % n] - rs[(best_i - 1 + n) % n]
	var db := rs[(best_j + 2) % n] - rs[(best_j - 1 + n) % n]
	if da == Vector2.ZERO or db == Vector2.ZERO \
			or absf(da.normalized().dot(db.normalized())) > cos(EIGHT_CROSS_MIN):
		return {}
	return {
		"a": (best_i + 0.5) / n, "b": (best_j + 0.5) / n,
		"centers": PackedVector2Array([centroid(lobe_a), centroid(lobe_b)]),
	}


## Доля периметра замкнутой ломаной в самом длинном почти прямом куске (см. EIGHT_STRAIGHT_MAX):
## от каждой вершины кусок растёт, пока все его точки не дальше EIGHT_STRAIGHT_DEV от хорды.
static func straight_share(raw: PackedVector2Array) -> float:
	var n := raw.size()
	# сглаживание [1 2 1]/4 по кругу: дрожь руки гасится вдвое, дуга петли почти не меняется
	var poly := PackedVector2Array()
	poly.resize(n)
	for k in n:
		poly[k] = (raw[(k - 1 + n) % n] + raw[k] * 2.0 + raw[(k + 1) % n]) * 0.25
	var total := 0.0
	for k in n:
		total += poly[k].distance_to(poly[(k + 1) % n])
	if total <= 0.0:
		return 0.0
	var best := 0.0
	for st in n:
		var a := poly[st]
		var run := 0.0
		for k in range(1, n):
			var b := poly[(st + k) % n]
			if not _near_chord(poly, st, k, a, b):
				break
			run += poly[(st + k - 1) % n].distance_to(b)
		best = maxf(best, run)
	return best / total


## Точки poly[st+1 … st+k-1] (по кругу) близко к хорде a→b: не дальше доли EIGHT_STRAIGHT_DEV_K
## её длины (прогиб дуги относительно хорды — признак кривизны, не зависящий от размера петли) и
## не меньше EIGHT_STRAIGHT_DEV_MIN px (остаток дрожи после сглаживания).
static func _near_chord(poly: PackedVector2Array, st: int, k: int, a: Vector2, b: Vector2) -> bool:
	var n := poly.size()
	var tol := maxf(EIGHT_STRAIGHT_DEV_MIN, EIGHT_STRAIGHT_DEV_K * a.distance_to(b))
	for m in range(1, k):
		var p := poly[(st + m) % n]
		if p.distance_to(Geometry2D.get_closest_point_to_segment(p, a, b)) > tol:
			return false
	return true


# ── Треугольник и квадрат (D-1002-03) ────────────────────────────────────────

## TRIANGLE / SQUARE или &"" (см. заголовок POLY_*).
static func polygon_kind(pts: PackedVector2Array) -> StringName:
	var fit := polygon_fit(pts)
	if fit.is_empty():
		return &""
	var tips: PackedVector2Array = fit["tips"]
	if _kind_ok(fit, tips.size()):
		return TRIANGLE if tips.size() == 3 else SQUARE
	return &""


## Вершины треугольника (count 3) или квадрата (count 4) по порядку штриха; пусто — не он.
## pts — штрих как нарисован (не пересэмплированный: у редких точек хорда срезает угол).
static func polygon_tips(pts: PackedVector2Array, count: int) -> PackedVector2Array:
	var fit := polygon_fit(pts)
	if fit.is_empty() or (fit["tips"] as PackedVector2Array).size() != count \
			or not _kind_ok(fit, count):
		return PackedVector2Array()
	return fit["tips"]


## Углы и пропорции под вид: каждая вершина ≥ TIP_MIN (~65°), у квадрата ещё и
## ≤ SQUARE_TIP_MAX; короткое ребро ≥ POLY_EDGE_RATIO длинного.
static func _kind_ok(fit: Dictionary, count: int) -> bool:
	var tips: PackedVector2Array = fit["tips"]
	var turns: PackedFloat32Array = fit["turns"]
	for t in turns:
		if absf(t) < TIP_MIN or (count == 4 and absf(t) > SQUARE_TIP_MAX):
			return false
	var e_min := INF
	var e_max := 0.0
	for e in count:
		var d := tips[e].distance_to(tips[(e + 1) % count])
		e_min = minf(e_min, d)
		e_max = maxf(e_max, d)
	return e_min >= POLY_EDGE_RATIO * e_max


## Многоугольник по штриху: {tips — 3 или 4 вершины по порядку штриха, turns — их повороты}
## или {} (см. заголовок POLY_*: замкнут, выпуклый, рёбра прямые). Углы и пропорции под вид —
## _kind_ok.
static func polygon_fit(pts: PackedVector2Array) -> Dictionary:
	if pts.size() < POLY_MIN_POINTS:
		return {}
	var stroke := trim_overshoot(pts)
	var length := poly_len(stroke)
	if length < POLY_MIN_LEN or _fig_gap(stroke, length) < 0.0:
		return {}
	var loop := closed(stroke)
	var total := poly_len(loop)
	var keep := _rdp_closed(loop, maxf(POLY_RDP_MIN, POLY_RDP_K * total))
	var m := keep.size()
	if m < 3:
		return {}
	var v := PackedVector2Array()
	for idx in keep:
		v.append(loop[idx])
	# изломы упрощённой ломаной (по кругу) и длины её отрезков
	var turn := PackedFloat32Array()
	var seg := PackedFloat32Array()
	turn.resize(m)
	seg.resize(m)
	for q in m:
		var a := v[(q - 1 + m) % m]
		var b := v[q]
		var c := v[(q + 1) % m]
		seg[q] = b.distance_to(c)   # отрезок q → q+1
		turn[q] = (b - a).angle_to(c - b) if b != a and c != b else 0.0
	# отрезок — срез угла, если он короче POLY_MERGE_K длины И заметно короче самого длинного
	# (POLY_MERGE_REL): у круга из 8–12 точек все отрезки похожи — их не слить в «углы квадрата»
	var long_min := POLY_MERGE_K * total
	var seg_max := 0.0
	for x in seg:
		seg_max = maxf(seg_max, x)
	long_min = minf(long_min, POLY_MERGE_REL * seg_max)
	# начать с вершины, перед которой длинный отрезок: кластеры не рвутся на стыке
	var s0 := -1
	for q in m:
		if seg[(q - 1 + m) % m] >= long_min:
			s0 = q
			break
	if s0 < 0:
		return {}
	# кластеры: изломы, соединённые короткими отрезками (срез угла редкими точками)
	var clusters: Array = []   # [[первый, последний, сумма поворота]]
	var q := s0
	var start := s0
	var acc := 0.0
	for step in m:
		acc += turn[q]
		if seg[q] >= long_min:
			clusters.append([start, q, wrapf(acc, -PI, PI)])   # угол — один поворот, не петля
			start = (q + 1) % m
			acc = 0.0
		q = (q + 1) % m
	# вершины — кластеры с изломом от CORNER_MIN, все в одну сторону; сумма всех изломов ≈ 2π
	var corners: Array = []   # [первый, последний] — индексы точек loop
	var sum := 0.0
	var sgn := 0.0
	for cl: Array in clusters:
		var t := float(cl[2])
		sum += t
		if absf(t) < POLY_BEND_MAX:
			continue   # изгиб ребра
		if absf(t) < CORNER_MIN:
			return {}  # ни угол, ни прямая — не фигура
		if sgn == 0.0:
			sgn = signf(t)
		elif signf(t) != sgn:
			return {}
		corners.append([keep[int(cl[0])], keep[int(cl[1])]])
	var n := corners.size()
	if n < 3 or n > 4 or absf(absf(sum) - TAU) > TAU * POLY_TURN_TOL:
		return {}
	# ребро — прямая по точкам штриха от вершины до вершины (срез угла редкими точками не в счёт);
	# вершина — пересечение соседних рёбер: у редких точек ближняя к углу точка лежит на ребре
	var lines: Array = []   # [точка, направление]
	var pn := loop.size() - 1
	for e in n:
		var a := int(corners[e][1])
		var b := int(corners[(e + 1) % n][0])
		var span := PackedVector2Array()
		var k := a
		while true:
			span.append(loop[k])
			if k == b:
				break
			k = (k + 1) % pn
		var line := _fit_line(span)
		if line.is_empty():
			return {}
		lines.append(line)
	var tips := PackedVector2Array()
	var turns := PackedFloat32Array()
	for e in n:
		var l_in: Array = lines[(e - 1 + n) % n]
		var l_out: Array = lines[e]
		var at: Variant = Geometry2D.line_intersects_line(l_in[0], l_in[1], l_out[0], l_out[1])
		if at == null:
			return {}
		tips.append(at)
		turns.append((l_in[1] as Vector2).angle_to(l_out[1]))
	# рёбра прямые: каждая точка штриха близко к контуру по вершинам
	var e_mean := 0.0
	for e in n:
		e_mean += tips[e].distance_to(tips[(e + 1) % n]) / n
	if e_mean <= 0.0 or e_mean > total:
		return {}
	var tol := maxf(POLY_STRAIGHT_MIN, POLY_STRAIGHT_K * e_mean)
	for p in stroke:
		var best := INF
		for e in n:
			var cp := Geometry2D.get_closest_point_to_segment(p, tips[e], tips[(e + 1) % n])
			best = minf(best, p.distance_to(cp))
		if best > tol:
			return {}
	return {"tips": tips, "turns": turns}


## Прямая по точкам (главная ось разброса): [точка на прямой, направление от первой точки к
## последней]; [] — точки слились.
static func _fit_line(span: PackedVector2Array) -> Array:
	var mean := Vector2.ZERO
	for q in span:
		mean += q
	mean /= float(span.size())
	var sxx := 0.0
	var syy := 0.0
	var sxy := 0.0
	for q in span:
		var d := q - mean
		sxx += d.x * d.x
		syy += d.y * d.y
		sxy += d.x * d.y
	if sxx + syy < 1.0:
		return []
	var dir := Vector2.from_angle(0.5 * atan2(2.0 * sxy, sxx - syy))
	if dir.dot(span[span.size() - 1] - span[0]) < 0.0:
		dir = -dir
	return [mean, dir]


## Рамер–Дуглас–Пейкер замкнутой ломаной loop (последняя точка = первой): индексы оставленных
## точек по порядку, без повтора последней. Разрез — в начале и самой далёкой от него точке.
static func _rdp_closed(loop: PackedVector2Array, eps: float) -> PackedInt32Array:
	var n := loop.size() - 1
	var far := 0
	var far_d := -1.0
	for i in n:
		var d := loop[0].distance_squared_to(loop[i])
		if d > far_d:
			far_d = d
			far = i
	var keep := PackedByteArray()
	keep.resize(n + 1)
	keep[0] = 1
	keep[far] = 1
	keep[n] = 1
	var stack: Array[Vector2i] = [Vector2i(0, far), Vector2i(far, n)]
	while not stack.is_empty():
		var span: Vector2i = stack.pop_back()
		var a := loop[span.x]
		var b := loop[span.y]
		var worst := -1
		var worst_d := eps
		for i in range(span.x + 1, span.y):
			var d := loop[i].distance_to(Geometry2D.get_closest_point_to_segment(loop[i], a, b))
			if d > worst_d:
				worst_d = d
				worst = i
		if worst >= 0:
			keep[worst] = 1
			stack.append(Vector2i(span.x, worst))
			stack.append(Vector2i(worst, span.y))
	var out := PackedInt32Array()
	for i in n:
		if keep[i] != 0:
			out.append(i)
	return out


## Рука часто перелетает конец за начало: штрих срезается в точке хвоста, ближайшей к началу
## (хвост не длиннее зазора замыкания FIG_GAP_*). Недотянутый штрих не меняется.
static func trim_overshoot(pts: PackedVector2Array) -> PackedVector2Array:
	var n := pts.size()
	if n < 3:
		return pts
	var limit := maxf(FIG_GAP_MIN, FIG_GAP_FRAC * poly_len(pts))
	var best := n - 1
	var best_d := pts[0].distance_to(pts[n - 1])
	var run := 0.0
	for i in range(n - 2, 0, -1):
		run += pts[i].distance_to(pts[i + 1])
		if run > limit:
			break
		var d := pts[0].distance_to(pts[i])
		if d < best_d:
			best_d = d
			best = i
	return pts if best == n - 1 else pts.slice(0, best + 1)
