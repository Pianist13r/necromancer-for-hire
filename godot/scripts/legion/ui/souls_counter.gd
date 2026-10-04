class_name SoulsCounter
extends Control
##
## Всплывающие «+N» душ у места убийства (пакет staff, DESIGN_V15 §5). Сам счётчик душ с v17
## живёт в верхней плашке (LegionTopPlate, DESIGN_V17 §1 п.2). «+N» — пул фиксированного
## размера, рисуется одним узлом: волна в сотню убийств не плодит сотню Label и твинов.
## Координаты HUD совпадают с мировыми (камеры нет, 1280×720). Обновляется по сигналам мира.
##

const POP_FONT := 15

var world: LegionWorld = null

var _pops: Node2D = null
var _pop_pos := PackedVector2Array()
var _pop_t := PackedFloat32Array()
var _pop_n := PackedInt32Array()
var _next := 0
var _live := 0


func setup(w: LegionWorld) -> SoulsCounter:
	world = w
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_pops = Node2D.new()
	_pops.draw.connect(_draw_pops)
	add_child(_pops)
	_pop_pos.resize(LegionCfg.SOUL_POP_MAX)
	_pop_t.resize(LegionCfg.SOUL_POP_MAX)
	_pop_n.resize(LegionCfg.SOUL_POP_MAX)
	world.foe_killed.connect(_on_kill)
	return self


func _on_kill(f: Foe, pos: Vector2) -> void:
	if f.has_meta(&"summoned"):
		return
	var n := roundi(LegionChallenge.foe_souls(f))
	if n <= 0:
		return
	# пул по кругу: при переполнении перезаписываем самую старую надпись
	if _pop_t[_next] <= 0.0:
		_live += 1
	_pop_pos[_next] = pos
	_pop_t[_next] = LegionCfg.SOUL_POP_TIME
	_pop_n[_next] = n
	_next = (_next + 1) % LegionCfg.SOUL_POP_MAX


func _process(dt: float) -> void:
	if _live <= 0:
		return
	for i in _pop_t.size():
		if _pop_t[i] > 0.0:
			_pop_t[i] -= dt
			if _pop_t[i] <= 0.0:
				_live -= 1
	_pops.queue_redraw()


func _draw_pops() -> void:
	for i in _pop_t.size():
		var t := _pop_t[i]
		if t <= 0.0:
			continue
		var k := 1.0 - t / LegionCfg.SOUL_POP_TIME
		var at := _pop_pos[i] + Vector2(-8.0, -30.0 - LegionCfg.SOUL_POP_RISE * k)
		var col := Color(UiStyle.SOUL.lightened(0.45), 1.0 - k * k)
		_pops.draw_string_outline(UiStyle.FONT_TEXT, at, "+%d" % _pop_n[i], HORIZONTAL_ALIGNMENT_LEFT,
			-1, POP_FONT, 3, Color(0, 0, 0, col.a * 0.8))
		_pops.draw_string(UiStyle.FONT_TEXT, at, "+%d" % _pop_n[i], HORIZONTAL_ALIGNMENT_LEFT,
			-1, POP_FONT, col)
