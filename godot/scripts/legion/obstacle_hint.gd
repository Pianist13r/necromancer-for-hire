class_name ObstacleHint
extends Node2D
##
## Подсветка препятствий (v19 «стены по рисунку», медленная сессия d26f8623, 26.09.2026).
## Игорь: «чтобы точно я понимал, какие препятствия препятствия, а какие нет». Фон карты
## нарисован целиком, а скалы поверх нарисованного фона не рисуются (TerrainView) — отличить
## препятствие от картинки было нечем. Всё, что держит бойцов и режет штрих руны (скалы, стены,
## ограды, склепы, кучи хлама), обводится красным с косой штриховкой: пока игрок чертит договор
## или тянет рогатку и первые секунды боя. В остальное время слой прозрачен и рисунку не мешает.
## Рисуется один раз при старте карты; видимость — только альфа (modulate).
##

## На собранной карте предметы уже видны; полная подсветка остаётся при рисовании.
const GENERATED_FLASH_ALPHA := 0.24

var world: LegionWorld = null
var _polys: Array[PackedVector2Array] = []
## Штриховка — пары точек отрезков для draw_multiline, обрезанные по контурам.
var _hatch := PackedVector2Array()
var _flash := 0.0
var _flashed := false


func setup(w: LegionWorld) -> void:
	world = w
	z_index = LegionCfg.HINT_Z
	modulate.a = 0.0
	_polys = w.terrain.rocks.duplicate()
	_hatch = _build_hatch(_polys)
	_flash = 0.0
	_flashed = false
	queue_redraw()


func poly_count() -> int:
	return _polys.size()


func _process(delta: float) -> void:
	tick(delta)


## Шаг видимости. Отдельно от _process — тест ведёт его своим шагом.
func tick(dt: float) -> void:
	if world == null or world.my_field() == null:
		return
	var running := world.phase == LegionWorld.Phase.BATTLE and not world.paused \
		and not world.hold and not world.is_ground_loading()
	# вспышка — один раз, когда бой впервые пошёл: под брифингом и на удержании не сгорает
	if not _flashed and running:
		_flashed = true
		_flash = LegionCfg.HINT_FLASH_TIME
	if running:
		_flash = maxf(0.0, _flash - dt)
	var target := 0.0
	if world.my_field().is_gesturing():
		target = 1.0
	elif _flash > 0.0 or (not _flashed and world.phase == LegionWorld.Phase.BATTLE):
		target = LegionCfg.HINT_FLASH_ALPHA
		if world.map.has("procgen"):
			var remaining := _flash / LegionCfg.HINT_FLASH_TIME if _flashed else 1.0
			target = GENERATED_FLASH_ALPHA * remaining * remaining
	var rate := LegionCfg.HINT_FADE_IN if target > modulate.a else LegionCfg.HINT_FADE_OUT
	modulate.a = move_toward(modulate.a, target, rate * dt)


func _draw() -> void:
	for poly in _polys:
		draw_colored_polygon(poly, LegionCfg.HINT_FILL)
	if not _hatch.is_empty():
		draw_multiline(_hatch, LegionCfg.HINT_HATCH, LegionCfg.HINT_HATCH_W)
	for poly in _polys:
		var closed := poly.duplicate()
		closed.append(poly[0])
		draw_polyline(closed, LegionCfg.HINT_EDGE, LegionCfg.HINT_EDGE_W, true)


## Косые линии через рамку каждого контура с шагом HINT_HATCH_STEP, обрезанные по контуру.
static func _build_hatch(polys: Array[PackedVector2Array]) -> PackedVector2Array:
	var out := PackedVector2Array()
	var step := LegionCfg.HINT_HATCH_STEP
	for poly in polys:
		var box := Rect2(poly[0], Vector2.ZERO)
		for p in poly:
			box = box.expand(p)
		# линии x - y = c (под 45°): c от левого нижнего до правого верхнего угла рамки
		var c0 := floorf((box.position.x - box.end.y) / step) * step
		var c1 := box.end.x - box.position.y
		var c := c0
		while c <= c1:
			var a := Vector2(box.position.y + c, box.position.y)
			var b := Vector2(box.end.y + c, box.end.y)
			for piece in Geometry2D.intersect_polyline_with_polygon(PackedVector2Array([a, b]), poly):
				if piece.size() >= 2:
					out.append(piece[0])
					out.append(piece[piece.size() - 1])
			c += step
	return out
