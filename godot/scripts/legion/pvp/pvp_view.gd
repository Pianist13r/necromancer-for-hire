class_name PvpView
extends RefCounted
##
## Вид «Схватки» (P5c, docs/dev/PVP_PLAN_0929.md): то, что зависит от масштаба поля. Камера PvP
## ×0,8 (LegionWorld.view_xf): всё, что нарисовано в мире, ужимается вместе с ним, а человеку
## нужен прежний размер на экране. Одиночка — масштаб 1: каждая функция здесь ей тождество.
##
## Числа правил PvP — в PvpRules; здесь только вид (цвета — таблица смыслов CfgFx.MEANING_COLOR).
##

## Маркер стороны под бойцом крупнее одиночного значения (7) на столько: на ×0,8 в драке овал и
## ромб были в 5–6 px и сливались с ботинками (кадр P5c до правки).
const MARKER_BOOST := 1.45


## Размер шрифта подписи в мире так, чтобы на экране он был прежним (B-303): size / масштаб вида.
## world == null или одиночка (масштаб 1) — size без изменений.
static func fs(world: LegionWorld, size: int) -> int:
	if world == null or not world.pvp:
		return size
	return roundi(float(size) / world.view_scale())


## Маркер стороны с поправкой на вид: радиус и толщина линий растут на 1/масштаб, чтобы на экране
## их размер не зависел от камеры, плюс MARKER_BOOST — в PvP маркер и есть «чей боец».
static func draw_marker(ci: CanvasItem, world: LegionWorld, at: Vector2, side: int,
		radius: float, boost := MARKER_BOOST) -> void:
	var k := boost / world.view_scale()
	var pts := PvpRules.marker_points(at, side, marker_radius(world, radius, boost))
	ci.draw_polyline(pts, Color(0.045, 0.035, 0.065, 0.95), 4.0 * k, true)
	ci.draw_polyline(pts, PvpRules.marker_color(side), 1.7 * k, true)


## Радиус маркера в мире: на экране он radius × boost, какой бы ни была камера.
static func marker_radius(world: LegionWorld, radius: float, boost := MARKER_BOOST) -> float:
	return radius * boost / world.view_scale()


## «мин:сек» — часы матча на плашке.
static func clock(seconds: float) -> String:
	var s := maxi(0, int(seconds))
	return "%d:%02d" % [int(s / 60.0), s % 60]
