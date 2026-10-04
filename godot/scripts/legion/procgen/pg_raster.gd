class_name PgRaster
extends RefCounted
##
## Растр препятствий карты 1 px = 1 px мира — для замеров удобства фильтра годности (BOOK §7, §10).
##
## Почему свой растр, а не сетка LegionTerrain: числа книги («Два отдела» 13,1 % дороги уже 76 px,
## p10 = 62) сняты скриптом `C:\AI\necro\assets\procgen\tools\comfort_measure.py` по пиксельной
## маске «как нарисовано в данных»: скалы + стены полосой ширины w + вода − мосты, без подрезки
## дорог ROAD_CLEAR. Клетка 16 px дала бы пролёты с шагом 16 и разошлась бы с книгой; пороги У-1
## (90 px) и У-2 (200 px) откалиброваны именно по этой методике. Повторяем её здесь.
##
## Скорость: заливка — строками через Image.fill_rect (C++), луч идёт по пикселям только в блоках
## 16×16, где есть препятствие; пустой блок пролетает одним прыжком (результат тот же, что шаг
## в 1 px: все пропущенные пиксели свободны).
##

const W := 1280
const H := 720
const BLOCK := 16
const BW := W / BLOCK
const BH := H / BLOCK
## Дальность луча в одну сторону — как maxd = 260 в comfort_measure.py (шаги 1…259).
const RAY_MAX := 260

var mask := PackedByteArray()
## 1 — в блоке 16×16 был залит хоть один пиксель (мост потом мог его очистить — это лишь
## заставит луч пройти блок попиксельно, ответ не меняется).
var _dirty := PackedByteArray()
var _img: Image


static func build(map: Dictionary) -> PgRaster:
	var r := PgRaster.new()
	r._img = Image.create_empty(W, H, false, Image.FORMAT_L8)
	r._img.fill(Color.BLACK)
	r._dirty.resize(BW * BH)
	r._dirty.fill(0)
	for poly: Array in map.get("rocks", []):
		r._fill(LegionMapChecks.polyline(poly), true)
	for wl: Dictionary in map.get("walls", []):
		r._wall(LegionMapChecks.polyline(wl.get("path", [])), float(wl.get("w", LegionCfg.WALL_MIN_W)))
	for poly: Array in map.get("water", []):
		r._fill(LegionMapChecks.polyline(poly), true)
	for poly: Array in map.get("bridges", []):
		r._fill(LegionMapChecks.polyline(poly), false)
	r.mask = r._img.get_data()
	return r


func solid(x: int, y: int) -> bool:
	return mask[y * W + x] != 0


## Точка мира на препятствии (за кадром — нет).
func solid_at(p: Vector2) -> bool:
	var x := roundi(p.x)
	var y := roundi(p.y)
	return x >= 0 and y >= 0 and x < W and y < H and mask[y * W + x] != 0


## Доля свободных пикселей кадра.
func free_share() -> float:
	return float(mask.count(0)) / float(W * H)


## Сколько шагов по 1 px из p в сторону единичного n свободно (до препятствия или края кадра),
## не больше RAY_MAX − 1. Как span() в comfort_measure.py для одной стороны.
func ray(p: Vector2, n: Vector2) -> int:
	var t := 1
	while t < RAY_MAX:
		var fx := p.x + n.x * t
		var fy := p.y + n.y * t
		var x := roundi(fx)
		var y := roundi(fy)
		if x < 0 or y < 0 or x >= W or y >= H:
			return t - 1
		var bx := x / BLOCK
		var by := y / BLOCK
		if _dirty[by * BW + bx] == 0:
			# пустой блок: прыжок к первому t, чей пиксель может лежать за блоком
			var jump := RAY_MAX
			if n.x > 0.0:
				jump = mini(jump, floori(((bx + 1) * BLOCK - 0.5 - p.x) / n.x))
			elif n.x < 0.0:
				jump = mini(jump, floori((bx * BLOCK - 0.5 - p.x) / n.x))
			if n.y > 0.0:
				jump = mini(jump, floori(((by + 1) * BLOCK - 0.5 - p.y) / n.y))
			elif n.y < 0.0:
				jump = mini(jump, floori((by * BLOCK - 0.5 - p.y) / n.y))
			t = maxi(t + 1, jump)
			continue
		if mask[y * W + x] != 0:
			return t - 1
		t += 1
	return RAY_MAX - 1


## Стена — как ImageDraw.line(width=w) у PIL: прямоугольник на каждое звено, торцы без скруглений.
func _wall(path: PackedVector2Array, w: float) -> void:
	var half := float(int(w)) * 0.5
	for i in range(1, path.size()):
		var d := path[i] - path[i - 1]
		if d.length() < 0.001:
			continue
		var o := d.normalized().orthogonal() * half
		_fill(PackedVector2Array([path[i - 1] + o, path[i] + o, path[i] - o, path[i - 1] - o]), true)


## Заливка многоугольника строками. Пиксель (x, y) — квадрат вокруг точки (x, y); закрашивается,
## если его задевает многоугольник: строка пикселей y — объединение пересечений на полустроках
## y − 0,5 и y + 0,5, края округляются наружу. Так ведёт себя PIL: он обводит контур тем же цветом,
## и пиксель, через который идёт ребро, закрашен. Без этого луч вдоль самой кромки воды «Моста»
## проскальзывал по полупикселю (пролёт 288 вместо 96). Полустрока считается один раз и красит
## обе соседние строки — вдвое дешевле, чем две полустроки на каждую строку (verifier 27.09:
## 150 скал — 24 мс на растр).
func _fill(poly: PackedVector2Array, value: bool) -> void:
	var n := poly.size()
	if n < 3:
		return
	var lo := poly[0]
	var hi := poly[0]
	for p in poly:
		lo = lo.min(p)
		hi = hi.max(p)
	var color := Color.WHITE if value else Color.BLACK
	var xs := PackedFloat32Array()
	# полустрока h + 0,5 касается строк h и h + 1
	for h in range(maxi(-1, floori(lo.y - 0.5)), mini(H - 1, ceili(hi.y - 0.5)) + 1):
		var fy := h + 0.5
		xs.clear()
		var a := poly[n - 1]
		for i in n:
			var b := poly[i]
			if (a.y <= fy) != (b.y <= fy):
				xs.append(a.x + (fy - a.y) * (b.x - a.x) / (b.y - a.y))
			a = b
		if xs.size() > 2:
			xs.sort()
		elif xs.size() == 2 and xs[0] > xs[1]:
			xs.reverse()
		var k := 0
		while k + 1 < xs.size():
			_span(h, xs[k] - 0.5, xs[k + 1] + 0.5, color, value)
			k += 2


## Отрезок [xa, xb] на строках y и y + 1 (обрезано по кадру).
func _span(y: int, xa: float, xb: float, color: Color, value: bool) -> void:
	var x0 := maxi(0, ceili(xa - 0.001))
	var x1 := mini(W - 1, floori(xb + 0.001))
	var y0 := maxi(0, y)
	var y1 := mini(H - 1, y + 1)
	if x1 < x0 or y1 < y0:
		return
	_img.fill_rect(Rect2i(x0, y0, x1 - x0 + 1, y1 - y0 + 1), color)
	if value:
		for yy in range(y0 / BLOCK, y1 / BLOCK + 1):
			var row := yy * BW
			for bx in range(x0 / BLOCK, x1 / BLOCK + 1):
				_dirty[row + bx] = 1
