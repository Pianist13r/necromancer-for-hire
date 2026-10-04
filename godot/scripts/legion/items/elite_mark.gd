class_name LegionEliteMark
extends Node2D
##
## Знак элитного (враг волны или нанятый «Кадровым агентством» скелет): золотой ореол под
## ногами и корона над головой — читается с первого взгляда в толпе. Чистый вид: ставится
## первым ребёнком фигуры (ореол под спрайтом), пульс — от часов мира, без ГСЧ. В экономной
## графике — тот же знак без пульса (кадр не перерисовывается каждый тик).
##

var world: LegionWorld = null
var body_h := 44.0
var color := CfgItems.ELITE_COLOR
## Носитель артефакта: над короной светится «портфель» с лучами — видно, кого дожимать.
var carrier := false
var _economy := false
var _was_alive := true


func setup(w: LegionWorld, body: float, tint: Color) -> LegionEliteMark:
	world = w
	body_h = body
	color = tint
	_economy = Settings.is_economy_graphics()
	queue_redraw()
	return self


func _process(_delta: float) -> void:
	# экономная графика: перерисовка только когда владелец умер (корона не остаётся на трупе)
	if not _economy or _owner_alive() != _was_alive:
		_was_alive = _owner_alive()
		queue_redraw()


func _owner_alive() -> bool:
	var p := get_parent()
	if p is Foe:
		return (p as Foe).alive
	if p is Legionnaire:
		return (p as Legionnaire).alive
	return true


func _draw() -> void:
	if not _owner_alive():
		return
	var k := 0.5
	if not _economy and world != null:
		k = 0.5 + 0.5 * sin(world.now * CfgItems.ELITE_HALO_PULSE)
	var halo := CfgItems.ELITE_HALO * (body_h / 44.0)
	draw_set_transform(Vector2(0.0, -1.0), 0.0, Vector2(1.0, halo.y / halo.x))
	draw_circle(Vector2.ZERO, halo.x * (1.25 + 0.15 * k), Color(color, 0.12 + 0.1 * k))
	draw_circle(Vector2.ZERO, halo.x, Color(color, 0.3 + 0.15 * k))
	draw_arc(Vector2.ZERO, halo.x, 0.0, TAU, 32, Color(color, 0.95), 3.0, true)
	draw_set_transform(Vector2.ZERO)
	# корона: три зубца, тёмный контур — видна на светлой земле и на плитах
	var top := Vector2(0.0, -body_h - CfgItems.ELITE_CROWN_LIFT - 2.0 * k)
	var w := CfgItems.ELITE_CROWN_W
	var crown := PackedVector2Array([
		top + Vector2(-w, 0.0), top + Vector2(-w * 1.1, -10.0), top + Vector2(-w * 0.45, -4.5),
		top + Vector2(0.0, -14.0), top + Vector2(w * 0.45, -4.5), top + Vector2(w * 1.1, -10.0),
		top + Vector2(w, 0.0),
	])
	var ink := PackedVector2Array(crown)
	ink.append(crown[0])
	draw_colored_polygon(crown, color)
	draw_polyline(ink, Color(0.12, 0.07, 0.02, 0.95), 2.0, true)
	draw_circle(top + Vector2(0.0, -4.0), 2.4, Color(1.0, 0.3, 0.25))
	if carrier:
		_draw_carrier(top + Vector2(0.0, -CfgItems.CARRIER_GLYPH * 2.4 - 3.0 * k))


## «Портфель» носителя: голубое сияние, лучи и сам портфель с застёжкой (тёмный контур —
## читается на любой земле). Цвет отличен от золота короны: это не «ещё один элитный».
func _draw_carrier(at: Vector2) -> void:
	var g := CfgItems.CARRIER_GLYPH
	var c := CfgItems.CARRIER_COLOR
	var spin := 0.0 if _economy or world == null else world.now * 1.6
	draw_circle(at, g * 1.9, Color(c, 0.22))
	for i in 8:
		var d := Vector2.from_angle(TAU * float(i) / 8.0 + spin)
		draw_line(at + d * g * 1.25, at + d * g * 2.1, Color(c, 0.8), 2.0, true)
	var body := Rect2(at - Vector2(g, g * 0.62), Vector2(g * 2.0, g * 1.3))
	draw_rect(body.grow(1.5), Color(0.1, 0.06, 0.03, 0.95))
	draw_rect(body, Color(0.62, 0.38, 0.2))
	draw_rect(Rect2(at + Vector2(-g * 0.4, -g * 0.95), Vector2(g * 0.8, g * 0.4)), Color(0.1, 0.06,
		0.03, 0.95), false, 2.0)
	draw_rect(Rect2(at - Vector2(2.0, 2.0), Vector2(4.0, 4.0)), c)
