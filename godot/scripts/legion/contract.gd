# gdlint: disable=max-public-methods
class_name Contract
extends RefCounted
##
## Руна-договор: ломаная, её участки со своими сроками и места строя вдоль неё.
##
## Участки тают НЕЗАВИСИМО — в этом вся механика: таяние задаёт расписание выпуска отрядов.
## Растаявший или отпущенный участок мёртв насовсем (seg_dead), подрисовка его не воскрешает:
## подрисовка продлевает договор, а не заключает новый.
##
## Место строя — словарь {pos, normal, seg, row, offset, along, unit, dead}: словари передаются
## по ссылке, поэтому боец держит своё место прямо (unit.post) без индексов, которые плывут.
##
## v15 (DESIGN_V15 §4): у договора ОДНА стрелка натиска `dir` (единичный вектор) вместо нормали
## на каждом участке — изогнутая линия выпускает весь отряд в одну сторону, как нарисовал игрок.
## `normal` места и normal_at() — это тот же `dir` (оставлены, чтобы читатели не менялись).
## Исключение — кольцо «Оцепление» (ring): стрелка своя у участка и места, к центру; читать её
## только через seg_dir(s) / post["normal"], не через `dir`.
## Вид договора `kind` задаёт, кого он набирает, шаг мест и цену линии (LegionCfg.UNIT_KINDS).
##

## Доля SEG_LEN, которой хвост линии не хватает до нового участка (шум float, а не длина).
const SEG_EPS := 0.001

var points := PackedVector2Array()
var cum := PackedFloat32Array()        ## длина от начала до points[i]
var length := 0.0
var seg_age := PackedFloat32Array()
var seg_dead := PackedByteArray()
## Пакет melt: выплата требует хотя бы одного продления, иначе выгодно отпускать всё.
var seg_renewed := PackedByteArray()
## v18 «Давка»: прогиб участка (px, к Котлу от давящей толпы) и его направление. Ведёт мир
## (LegionWorld._tick_press); PRESS_BREAK — прорыв.
var seg_bend := PackedFloat32Array()
var seg_bend_dir := PackedVector2Array()
## Скан давки этого кадра (LegionGrid.press_scan): масса врагов у участка и Σ позиция × масса.
var press_mass := PackedFloat32Array()
var press_sum := PackedVector2Array()
var ttl := LegionCfg.SEG_TTL
var side := 1                          ## +1 — стрелка вправо от направления рисования
## Чей договор (сторона боя, PvpSide.index; одиночка — 0). Не `side`: то имя занято стрелкой.
var owner_side := 0
## Вид договора: набирает только бойцов этого вида (LegionCfg.UNIT_KINDS).
var kind: StringName = LegionCfg.KIND_LABORER
## Перк «Мелкий шрифт» (−10 % мана, camp_stat mana_cost_mult) — множитель этого договора,
## снятый с ContractField при рождении; 1.0 по умолчанию (без перка/вне кампании).
var mana_cost_mult := 1.0
## Стрелка натиска всего договора, единичный вектор. Менять — только через set_dir().
var dir := Vector2.RIGHT
var posts: Array[Dictionary] = []
## «Оцепление» (ContractShape): договор-кольцо. У кольца стрелка своя у каждого участка — к центру
## (ring_out — наружу, «круговая оборона»); `dir` у кольца не читается: всё берут через seg_dir().
var ring := false
var center := Vector2.ZERO
var ring_out := false
## Восьмёрка «Двойная смена» / треугольник «Обряд» / квадрат «Каре» (ContractShape.EIGHT /
## TRIANGLE / SQUARE; &"" — нет). Стрелка — своя у участка и места, как у кольца (seg_dir /
## post["normal"]): восьмёрка — к центру ЧУЖОЙ петли, треугольник — к центру (обряд бьёт там),
## квадрат — от центра наружу (каре держит оборону). Кольцо остаётся флагом `ring` (история).
var figure: StringName = &""
## Восьмёрка: центры петель A и B; петля A — места с along в [lobe_span.x, lobe_span.y].
var lobes := PackedVector2Array()
var lobe_span := Vector2.ZERO
## Треугольник, квадрат, пятиугольник и «D»: вершины по порядку штриха (у «Комиссии» — четыре
## выбранных из пяти, у «Неустойки» — два угла между прямой и дугой).
var tips := PackedVector2Array()
## Бойцы стоят ТОЛЬКО на углах, по одному на угол (ContractShape.CORNER_FIGURES). Пустые рёбра
## не стена: мест на них нет, давка их прогибает и рвёт, как обычную линию (D-1002 §1).
var corners_only := false
## Углы, вставшие в воду/скалу: фигура с таким углом НЕ заключается (D-1002 §2 — нельзя молча
## потерять угол и считать два оставшихся полным треугольником). Пусто — все углы на месте.
var blocked_tips := PackedVector2Array()
## Мини-размер (ContractShape.SIZE_MINI): та же фигура с ослабленными числами и меньшим числом
## мест (круг и восьмёрка — 4 места). Ставит build_figure по D штриха.
var size_mini := false
## Заряд подготовки, с боя: растёт, пока занято не меньше FigureCfg.CHARGE_FILL[figure] мест,
## и обнуляется, как только строй просел. Ульта/специальный выпуск — только при заряде
## (FigureCfg.CHARGE_TIME).
var charge_t := 0.0
## Пассив фигуры уже выдан («Комиссия» — щиты участникам): после загрузки снимка щит не
## выдаётся второй раз, а новый приход его не получает.
var ult_armed := false
var id := 0
var release_causes: Dictionary = {}

## Кусок ломаной каждого участка — для отрисовки (строится раз, в кадре не аллоцируется).
var seg_polys: Array[PackedVector2Array] = []
## v18: рамка каждого участка, раздутая на полосу давки, — дешёвый отсев врагов в press_scan.
var seg_press_box: Array[Rect2] = []

var _seg_centers := PackedVector2Array()


## Собрать геометрию. walkable — Callable(Vector2) -> bool: место в воде/скале не создаётся
## (туда никто не дойдёт, и пустое место вечно звало бы подкрепление). Стрелка по умолчанию —
## перпендикуляр к ХОРДЕ линии на стороне new_side; ряды мест ставятся по локальной нормали.
func build(
	pts: PackedVector2Array, new_side: int, walkable: Callable = Callable(),
	new_kind: StringName = LegionCfg.KIND_LABORER
) -> Contract:
	points = pts
	side = 1 if new_side >= 0 else -1
	kind = new_kind if LegionCfg.UNIT_KINDS.has(new_kind) else LegionCfg.KIND_LABORER
	var step := post_step()
	cum.resize(points.size())
	length = 0.0
	for i in points.size():
		if i > 0:
			length += points[i].distance_to(points[i - 1])
		cum[i] = length
	# допуск SEG_EPS: линия длиной ровно k·SEG_LEN (штрих бота — шагами 8 px, 256 = 4·64) из-за
	# округления float получала то k, то k+1 участков — последний нулевой длины (B-365: у
	# зеркальных линий половин — по-разному)
	var n_seg := maxi(1, ceili(length / LegionCfg.SEG_LEN - SEG_EPS))
	seg_age.resize(n_seg)
	seg_age.fill(0.0)
	seg_dead.resize(n_seg)
	seg_dead.fill(0)
	seg_renewed.resize(n_seg)
	seg_renewed.fill(0)
	seg_bend.resize(n_seg)
	seg_bend.fill(0.0)
	seg_bend_dir.resize(n_seg)
	seg_bend_dir.fill(Vector2.ZERO)
	_seg_centers.resize(n_seg)
	dir = side_normal(chord_dir(points), side)
	seg_polys.clear()
	seg_press_box.clear()
	for s in n_seg:
		var d0 := s * LegionCfg.SEG_LEN
		var d1 := minf(length, d0 + LegionCfg.SEG_LEN)
		_seg_centers[s] = point_at((d0 + d1) * 0.5)
		seg_polys.append(_sub_polyline(d0, d1))
		var sp := seg_polys[s]
		var box := Rect2(sp[0], Vector2.ZERO)
		for q in sp:
			box = box.expand(q)
		seg_press_box.append(box.grow(LegionCfg.PRESS_BAND))
	posts.clear()
	if size_mini:
		_mini_posts(walkable)
		return self
	var n_slots := int(length / step)
	for k in n_slots:
		var d := (k + 0.5) * step
		var at := point_at(d)
		var tan := _tangent_at(d)
		var local_n := side_normal(tan, side)
		var seg := segment_at(d)
		# у кольца и фигур стрелка места своя (от точки линии); у прочих — одна `dir`
		var front := _front(at, d)
		for row in 2:
			# ряд 0 — передний (по стрелке): он принимает удар и прикрывает второй
			var off := LegionCfg.ROW_OFFSET if row == 0 else -LegionCfg.ROW_OFFSET
			if local_n.dot(front) < 0.0:
				off = -off       # на изгибе локальная нормаль смотрит против стрелки
			var pos := at + local_n * off
			if walkable.is_valid() and not bool(walkable.call(pos)):
				continue
			posts.append({
				"pos": pos, "normal": front, "seg": seg, "row": row,
				"offset": pos - at, "along": d,
				"unit": null, "dead": false,
			})
	return self


## Мини-фигура: у кольца и восьмёрки мест всего четыре — прежний многоместный строй на таком
## размере не читается (D-1002 §3). Кольцо: четыре точки через четверть длины. Восьмёрка: по два
## места на каждой петле (0,3 и 0,7 её длины) — вне перетяжки, чтобы бойцы не вставали в узел.
func _mini_posts(walkable: Callable) -> void:
	var along := PackedFloat32Array()
	if figure == ContractShape.EIGHT and lobe_span.y > lobe_span.x and length > 0.0:
		var b0 := lobe_span.y
		var b1 := length + lobe_span.x
		along.append(lerpf(lobe_span.x, lobe_span.y, 0.3))
		along.append(lerpf(lobe_span.x, lobe_span.y, 0.7))
		along.append(fposmod(lerpf(b0, b1, 0.3), length))
		along.append(fposmod(lerpf(b0, b1, 0.7), length))
	else:
		for k in 4:
			along.append(length * (float(k) + 0.5) / 4.0)
	for d in along:
		var at := point_at(d)
		if walkable.is_valid() and not bool(walkable.call(at)):
			continue
		var front := _front(at, d)
		posts.append({
			"pos": at, "normal": front, "seg": segment_at(d), "row": 0,
			"offset": Vector2.ZERO, "along": d, "unit": null, "dead": false,
		})


## «Оцепление»: собрать договор-кольцо по штриху, признанному ContractShape.is_ring(). Зазор
## недотянутого круга закрывается, центр — центр масс фигуры, передний ряд — внутри.
func build_ring(
	pts: PackedVector2Array, walkable: Callable = Callable(),
	new_kind: StringName = LegionCfg.KIND_LABORER
) -> Contract:
	var loop := ContractShape.closed(pts)
	ring = true
	ring_out = false
	# мини-кольцу четыре места (D-1002 §3): размер — по исходному штриху, как у фигур
	size_mini = ContractShape.size_class(pts) == ContractShape.SIZE_MINI
	center = ContractShape.centroid(loop)
	return build(loop, 1, walkable, new_kind)


## Восьмёрка, треугольник или квадрат: собрать договор-фигуру по штриху, признанному
## ContractShape.classify(). Зазор закрывается, как у кольца; разбор фигуры — по той же замкнутой
## ломаной, поэтому доли длины перетяжки восьмёрки ложатся прямо на along мест. У треугольника и
## квадрата перелёт конца за начало срезается, как при распознавании.
func build_figure(
	pts: PackedVector2Array, fig: StringName, walkable: Callable = Callable(),
	new_kind: StringName = LegionCfg.KIND_LABORER
) -> Contract:
	var corners := _figure_corners(fig)
	var stroke := ContractShape.trim_overshoot(pts) if corners > 0 else pts
	var loop := ContractShape.closed(stroke)
	var rs := ContractShape.resample_closed(stroke)
	var total := ContractShape.poly_len(loop)
	# размер — по ИСХОДНОМУ штриху (как classify): обрезка перелёта его не меняет заметно.
	# Восьмёрке мало общей нижней границы мини: четыре места по два на петлю слиплись бы, ей
	# нужно D ≥ EIGHT_MINI_MIN_D — ниже этого она остаётся прежней многоместной (D-1002 §3).
	size_mini = ContractShape.size_class(pts) == ContractShape.SIZE_MINI
	if fig == ContractShape.EIGHT and ContractShape.fig_span(pts) < ContractShape.EIGHT_MINI_MIN_D:
		size_mini = false
	figure = fig
	if fig == ContractShape.EIGHT:
		var split := ContractShape.eight_lobes(rs)
		if split.is_empty():
			figure = &""   # не разобралась (не должно: классификатор видел то же) — линия
		else:
			lobes = split["centers"]
			lobe_span = Vector2(float(split["a"]), float(split["b"])) * total
			center = lobes[0].lerp(lobes[1], 0.5)
	elif fig == ContractShape.PENTAGON:
		var all := ContractShape.polygon_tips(stroke, 5, size_mini)
		if all.size() != 5:
			figure = &""
		else:
			tips = ContractShape.selected_tips(all, FigureCfg.PENTA_SEATS)
			center = Vector2.ZERO
			for t in all:
				center += t
			center /= float(all.size())
	elif fig == ContractShape.D_SHAPE:
		tips = ContractShape.d_corners(stroke, size_mini)
		if tips.size() != FigureCfg.D_SEATS:
			figure = &""
		else:
			center = tips[0].lerp(tips[1], 0.5)
	elif corners > 0:
		tips = ContractShape.polygon_tips(stroke, corners, size_mini)
		if tips.size() != corners:
			figure = &""
		else:
			center = Vector2.ZERO
			for t in tips:
				center += t
			center /= float(corners)
			if fig == ContractShape.SQUARE:
				ttl = LegionCfg.SEG_TTL * FigureCfg.SQUARE_TTL_MULT
	else:
		figure = &""
	build(loop, 1, walkable, new_kind)
	if figure != &"" and _corner_fig():
		corner_posts(walkable)
	return self


## Сколько углов у фигуры по её виду (0 — не угловая: восьмёрка и кольцо).
static func _figure_corners(fig: StringName) -> int:
	match fig:
		ContractShape.TRIANGLE:
			return 3
		ContractShape.SQUARE:
			return 4
		ContractShape.PENTAGON:
			return 5
		ContractShape.D_SHAPE:
			return FigureCfg.D_SEATS
	return 0


## Фигура с местами ТОЛЬКО на углах.
func _corner_fig() -> bool:
	return ContractShape.CORNER_FIGURES.has(figure)


## Строй угловой фигуры: по одному месту на вершину, без рёбер и второго ряда. Место угла несёт
## прежний формат словаря (pos, normal, seg, row, offset, along), поэтому раздача, давка и
## выпуск читают его как любое другое: pos — сама вершина, seg и along — куда она проецируется
## на штрих (у вершины проекция — она сама, offset ≈ 0). Вершина в воде или скале место не даёт:
## туда никто не дойдёт.
func corner_posts(walkable: Callable = Callable()) -> void:
	posts.clear()
	blocked_tips.clear()
	corners_only = true
	for t in tips:
		if walkable.is_valid() and not bool(walkable.call(t)):
			blocked_tips.append(t)
			continue
		var pr := project(t)
		var along := pr.y
		posts.append({
			"pos": t, "normal": _front(t, along), "seg": segment_at(along), "row": 0,
			"offset": t - point_at(along), "along": along, "unit": null, "dead": false,
		})


func shaped() -> bool:
	return ring or figure != &""


## Петля восьмёрки, в которой лежит точка линии с длиной along: 0 — A, 1 — B.
func lobe_at(along: float) -> int:
	return 0 if along >= lobe_span.x and along <= lobe_span.y else 1


## Стрелка места/участка в точке линии at (along — её длина от начала).
func _front(at: Vector2, along: float) -> Vector2:
	if ring:
		return _ring_front(at)
	if figure == ContractShape.EIGHT:
		var to := lobes[1 - lobe_at(along)] - at
		return to.normalized() if to != Vector2.ZERO else Vector2.DOWN
	if figure == ContractShape.TRIANGLE:
		# к центру: обряд бьёт там
		var v := center - at
		return v.normalized() if v != Vector2.ZERO else Vector2.DOWN
	if figure == ContractShape.SQUARE or figure == ContractShape.PENTAGON \
			or figure == ContractShape.D_SHAPE:
		# от центра наружу: каре держит оборону, комиссия и неустойка выходят от контура
		var w := at - center
		return w.normalized() if w != Vector2.ZERO else Vector2.DOWN
	return dir


## Сколько мест нужно для ЗАРЯДА фигуры (FigureCfg.CHARGE_FILL): 0 — фигура без заряда (кольцо,
## восьмёрка). У «Комиссии» и «Каре» — три места из четырёх, у Обряда два из трёх, у Неустойки
## оба.
func charge_need() -> int:
	var frac := float(FigureCfg.CHARGE_FILL.get(figure, 0.0))
	return 0 if frac <= 0.0 else ceili(posts.size() * frac - 0.0001)


## Сколько мест занято СТОЯЩИМИ бойцами (POSTED): MARCH — бронь места, но ещё не участник
## фигуры (D-1002 §1), заряд по нему не идёт.
func posted_posts() -> int:
	var n := 0
	for p in posts:
		var u: Legionnaire = p["unit"]
		if not p["dead"] and u != null and u.state == Legionnaire.State.POSTED:
			n += 1
	return n


## Занято ли мест не меньше, чем нужно заряду (по ним и копится charge_t).
func charge_filled() -> bool:
	var need := charge_need()
	return need > 0 and posted_posts() >= need


## Заряд набран — ульта/специальный выпуск сработает. Строй обязан держать нужную долю углов
## ПРЯМО СЕЙЧАС, а не только на прошлом тике поля (J4): поле обнуляет charge_t на своём тике, а
## участник, убитый после него, оставлял заряд «готовым» до конца шага — ручной выпуск и пассив
## «Комиссии» получали ульту при уже сорванной подготовке.
func charge_ready() -> bool:
	return charge_need() > 0 and charge_filled() and charge_t >= FigureCfg.CHARGE_TIME


## Доля мест фигуры, где боец стоит в строю (POSTED): порог «Сверхурочных» и «Обряда».
func fill() -> float:
	if posts.is_empty():
		return 0.0
	var n := 0
	for p in posts:
		if not p["dead"] and p["unit"] != null \
				and (p["unit"] as Legionnaire).state == Legionnaire.State.POSTED:
			n += 1
	return float(n) / posts.size()


## Стрелка кольца в точке линии: к центру, при ring_out — наружу.
func _ring_front(at: Vector2) -> Vector2:
	var v := (center - at).normalized()
	if v == Vector2.ZERO:
		v = Vector2.DOWN
	return -v if ring_out else v


## Стрелка натиска участка: у кольца — своя (к центру/наружу), у линии — общая `dir`.
## Все, кто выпускает участок или рисует его стрелку, берут её отсюда.
func seg_dir(seg: int) -> Vector2:
	if ring:
		return _ring_front(_seg_centers[seg])
	if figure != &"":
		return _front(_seg_centers[seg], minf(length, (seg + 0.5) * LegionCfg.SEG_LEN))
	return dir


## Пробел над кольцом: курсор снаружи — стрелки наружу, внутри — к центру. Места сразу смотрят
## по новой стрелке, метка переднего ряда следует ей (как set_dir у линии).
func set_ring_out(out: bool) -> void:
	if not ring:
		return
	ring_out = out
	for p in posts:
		var at: Vector2 = (p["pos"] as Vector2) - (p["offset"] as Vector2)
		var n := _ring_front(at)
		p["normal"] = n
		p["row"] = 0 if (p["offset"] as Vector2).dot(n) >= 0.0 else 1


## Нормаль стороны выпуска. side = +1 — «правая» в системе карт MAPS (bot_lines.release):
## отрезок сверху вниз (a→b на юг) с release = +1 смотрит на ВОСТОК. Так размечены все карты
## пакета MAPS (рубежи западнее врага с release 1), поэтому ядро подстроено под данные.
static func side_normal(along: Vector2, s: int) -> Vector2:
	return Vector2(along.y, -along.x) * float(s)


## Направление хорды «первая → последняя точка»; у замкнутого штриха — первый ненулевой отрезок.
static func chord_dir(pts: PackedVector2Array) -> Vector2:
	if pts.size() >= 2:
		var d := (pts[pts.size() - 1] - pts[0]).normalized()
		if d != Vector2.ZERO:
			return d
		for i in range(1, pts.size()):
			d = (pts[i] - pts[i - 1]).normalized()
			if d != Vector2.ZERO:
				return d
	return Vector2.DOWN


## Новая стрелка натиска (Пробел). Места сразу смотрят по ней:
## стоящие в строю разворачиваются, броня спереди считается от новой стрелки.
func set_dir(v: Vector2) -> void:
	if shaped():
		return   # у фигур одной стрелки нет (у кольца наружу/внутрь — set_ring_out())
	var n := v.normalized()
	if n == Vector2.ZERO:
		return
	dir = n
	for p in posts:
		p["normal"] = dir
		# Метка ряда следует стрелке; сами места не двигаем, чтобы не пересекать строй.
		p["row"] = 0 if (p["offset"] as Vector2).dot(dir) >= 0.0 else 1


## Мёртвая часть линии больше не зовёт бойцов и не даёт соцпакет.
func live_distance(at: Vector2) -> float:
	var best := INF
	for s in seg_count():
		if not seg_alive(s):
			continue
		var poly := seg_polys[s]
		for i in range(1, poly.size()):
			var q := Geometry2D.get_closest_point_to_segment(at, poly[i - 1], poly[i])
			best = minf(best, at.distance_to(q))
	return best


func flip_dir() -> void:
	if ring:
		set_ring_out(not ring_out)
		return
	set_dir(-dir)


## Шаг мест этого вида, px.
func post_step() -> float:
	return float(LegionCfg.UNIT_KINDS[kind]["post_step"])


## polish1 (ревью 25.09.2026): раньше цену считали ТРИ разных места (эта функция,
## `ContractField._kind_price()` — своя копия того же поиска по таблице, и черновик штриха) —
## перк «Мелкий шрифт» (mana_cost_mult) применялся только там, где кто-то не забыл, и бой его
## не применял нигде. Теперь `base_price()` — единственное место, где читается таблица видов,
## `ContractField` больше не дублирует поиск (её `_kind_price()` зовёт эту же функцию), а перк —
## множитель `mana_cost_mult`, который `ContractField.setup()` берёт из `world.camp_stat()` один
## раз на карту и передаёт КАЖДОМУ договору при его создании (`_create()`).
static func base_price(k: StringName) -> float:
	var kk := k if LegionCfg.UNIT_KINDS.has(k) else LegionCfg.KIND_LABORER
	return float(LegionCfg.UNIT_KINDS[kk]["mana_per_px"])


## Цена продления/линии этого вида за пиксель, с учётом перка. ЕДИНСТВЕННОЕ место, где
## считается цена уже существующего договора — ContractField зовёт её же, не копирует.
func mana_per_px() -> float:
	return base_price(kind) * mana_cost_mult


func seg_count() -> int:
	return seg_age.size()


func segment_at(dist: float) -> int:
	return clampi(int(dist / LegionCfg.SEG_LEN), 0, seg_age.size() - 1)


## Стрелка участка: у линии — v15, одна на весь договор; у кольца — своя (seg_dir).
func normal_at(seg: int) -> Vector2:
	return seg_dir(seg)


func seg_center(seg: int) -> Vector2:
	return _seg_centers[seg]


func seg_alive(seg: int) -> bool:
	return seg_dead[seg] == 0


func seg_left(seg: int) -> float:
	return 0.0 if seg_dead[seg] != 0 else maxf(0.0, ttl - seg_age[seg])


func alive() -> bool:
	for s in seg_dead.size():
		if seg_dead[s] == 0:
			return true
	return false


## Обнулить возраст живых участков из списка. Возвращает, сколько реально продлено.
func refresh_segments(idx: PackedInt32Array) -> int:
	var n := 0
	for s in idx:
		if s >= 0 and s < seg_age.size() and seg_dead[s] == 0:
			seg_age[s] = 0.0
			seg_renewed[s] = 1
			n += 1
	return n


func free_posts() -> int:
	var n := 0
	for p in posts:
		if not p["dead"] and p["unit"] == null:
			n += 1
	return n


## Сколько бойцов стоит в строю на участке (бот не отпускает пустой участок).
func seg_manned(seg: int) -> int:
	var n := 0
	for p in posts:
		if int(p["seg"]) == seg and not p["dead"] and p["unit"] != null \
				and (p["unit"] as Legionnaire).state == Legionnaire.State.POSTED:
			n += 1
	return n


func manned_posts() -> int:
	var n := 0
	for p in posts:
		if not p["dead"] and p["unit"] != null:
			n += 1
	return n


func point_at(dist: float) -> Vector2:
	if points.size() == 1:
		return points[0]
	var d := clampf(dist, 0.0, length)
	for i in range(1, points.size()):
		if d <= cum[i]:
			var seg := cum[i] - cum[i - 1]
			var t := 0.0 if seg <= 0.0 else (d - cum[i - 1]) / seg
			return points[i - 1].lerp(points[i], t)
	return points[points.size() - 1]


func _sub_polyline(d0: float, d1: float) -> PackedVector2Array:
	var out := PackedVector2Array([point_at(d0)])
	for i in points.size():
		if cum[i] > d0 and cum[i] < d1:
			out.append(points[i])
	out.append(point_at(d1))
	return out


func _tangent_at(dist: float) -> Vector2:
	# касательная по хорде ±шаг мест: у дрожащего штриха мыши локальные отрезки по 6 px
	# дали бы места, разбросанные зигзагом
	var a := point_at(dist - post_step())
	var b := point_at(dist + post_step())
	var t := (b - a).normalized()
	return t if t != Vector2.ZERO else Vector2.RIGHT


## Ближайшая точка ломаной к p: {dist (до линии), along (от начала линии)}.
func project(p: Vector2) -> Vector2:
	var best_d := INF
	var best_along := 0.0
	for i in range(1, points.size()):
		var a := points[i - 1]
		var b := points[i]
		var q := Geometry2D.get_closest_point_to_segment(p, a, b)
		var d := q.distance_to(p)
		if d < best_d:
			best_d = d
			best_along = cum[i - 1] + a.distance_to(q)
	return Vector2(best_d, best_along)


## v18: доля прогиба участка до прорыва, 0..1.
func bend_frac(seg: int) -> float:
	if seg < 0 or seg >= seg_bend.size():
		return 0.0
	return clampf(seg_bend[seg] / LegionCfg.PRESS_BREAK, 0.0, 1.0)


## v18: где стоит боец места p с учётом прогиба участка — середина гнётся сильнее краёв.
## У угловых фигур (крыша, каре, комиссия, неустойка) места НЕ ездят вдоль прогиба (D-1002 §2
## «Давка»): пустые рёбра давка прогибает и рвёт, как обычную линию, а углы остаются на месте.
func bent_pos(p: Dictionary) -> Vector2:
	if corners_only:
		return p["pos"]
	var s := int(p["seg"])
	var b := seg_bend[s]
	if b <= 0.0:
		return p["pos"]
	var t := clampf((float(p["along"]) - s * LegionCfg.SEG_LEN) / LegionCfg.SEG_LEN, 0.0, 1.0)
	var w := LegionCfg.PRESS_EDGE_SHARE + (1.0 - LegionCfg.PRESS_EDGE_SHARE) * sin(PI * t)
	return (p["pos"] as Vector2) + seg_bend_dir[s] * b * w


## v18: ломаная участка, прогнутая как его строй (для отрисовки; аллоцирует — только у
## прогнутых участков).
func bent_poly(seg: int) -> PackedVector2Array:
	var poly := seg_polys[seg]
	var b := seg_bend[seg]
	if b <= 0.0 or poly.size() < 2:
		return poly
	var total := 0.0
	for i in range(1, poly.size()):
		total += poly[i].distance_to(poly[i - 1])
	var out := PackedVector2Array()
	var run := 0.0
	for i in poly.size():
		if i > 0:
			run += poly[i].distance_to(poly[i - 1])
		var t := 0.0 if total <= 0.0 else run / total
		var w := LegionCfg.PRESS_EDGE_SHARE + (1.0 - LegionCfg.PRESS_EDGE_SHARE) * sin(PI * t)
		out.append(poly[i] + seg_bend_dir[seg] * b * w)
	return out
