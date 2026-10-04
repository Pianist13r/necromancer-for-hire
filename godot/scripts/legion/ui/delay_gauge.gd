class_name DelayGauge
extends Control
##
## v17 CTL (DESIGN_V17 §2.3): шкала «Отсрочка» у курсора. Пока идёт натяжка рогатки, кольцо
## вокруг курсора показывает остаток шкалы (тратится DELAY_DRAIN/с реального времени, копится
## DELAY_REGEN/с вне натяжки); пустая — натяжка без замедления, кольцо красное. После срыва
## кольцо ещё FADE_TIME гаснет на месте.
##
## Висит на CanvasLayer боевого HUD (мир добавляет, legion_hud.gd не трогаем); мышь не ловит.
##

const R := 20.0
## Кольцо — за курсором по линии оттяжки (дальше от участка), не на тетиве и не на стрелке.
const AWAY := 38.0
const FADE_TIME := 0.8
const SLOW_COLOR := Color(0.55, 0.75, 1.0)

var world: LegionWorld = null
var _alpha := 0.0
var _at := Vector2.ZERO


func setup(w: LegionWorld) -> void:
	world = w
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	size = Vector2.ZERO


func _process(delta: float) -> void:
	var field := world.my_field()
	if field != null and field.is_slinging():
		_alpha = 1.0
		var aim := field.sling_aim()
		var back: Vector2 = -(aim["dir"] as Vector2) if not aim.is_empty() else Vector2.DOWN
		_at = field.sling_pointer() + back * AWAY
	elif _alpha > 0.0:
		_alpha = maxf(0.0, _alpha - delta / FADE_TIME)
	queue_redraw()


## Шкала видна сейчас (натяжка или гаснет после неё). Для тестов и кадров.
func shown() -> bool:
	return _alpha > 0.0


func _draw() -> void:
	if _alpha <= 0.0:
		return
	var a := _alpha
	var frac := world.my_field().delay / LegionCfg.DELAY_MAX
	var empty := frac <= 0.0
	var col := UiStyle.BAD if empty else SLOW_COLOR
	draw_circle(_at, R + 5.0, Color(UiStyle.PANEL_BG, 0.75 * a))
	draw_arc(_at, R, 0.0, TAU, 40, Color(1, 1, 1, 0.15 * a), 5.0, true)
	if frac > 0.0:
		draw_arc(_at, R, -PI * 0.5, -PI * 0.5 + TAU * frac, 40, Color(col, a), 5.0, true)
	# песочные часы в центре: «время растянуто»
	var h := 7.0
	# два треугольника: один «бантик» самопересекается и не триангулируется
	var sand := Color(col, 0.9 * a)
	draw_colored_polygon(PackedVector2Array([_at + Vector2(-5, -h), _at + Vector2(5, -h), _at]), sand)
	draw_colored_polygon(PackedVector2Array([_at + Vector2(5, h), _at + Vector2(-5, h), _at]), sand)
	var font: Font = UiStyle.FONT_TEXT
	var label := "Отсрочка" if not empty else "Отсрочка пуста"
	var w := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 15).x
	var pos := _at + Vector2(-w * 0.5, R + 20.0)   # под кольцом: над ним подпись силы
	draw_string_outline(font, pos, label, HORIZONTAL_ALIGNMENT_LEFT, -1, 15, 4,
		Color(0, 0, 0, 0.8 * a))
	draw_string(font, pos, label, HORIZONTAL_ALIGNMENT_LEFT, -1, 15, Color(col, a))
