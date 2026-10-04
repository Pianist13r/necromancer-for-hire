class_name PvpSideLook
extends RefCounted
##
## Вид стороны на бойце «Схватки» (B-346, D-0930-50): шейдер перекрашивает насыщенную одежду
## (оранжевая каска и жилет, синяя форма) в цвет стороны — оттенок совпадает с маркером под
## ногами (CfgFx.MEANING_COLOR side_0 / side_1). Профессии остаются различимы формой (D-CX-13);
## цвет стороны живёт в материале, а не в modulate, поэтому Е, «Аврал» и предметы (они красят
## modulate / self_modulate) принадлежность не стирают. Одиночка сюда не заходит: материала у
## бойца нет, вид прежний.
##

const SHADER := preload("res://scripts/legion/pvp/pvp_side_look.gdshader")
## Оттенок (HSV, 0..1), в который уходит одежда: бирюза стороны 0, розовый стороны 1.
const HUE := [0.44, 0.87]

static var _mats: Dictionary = {}


## Материал стороны: один на сторону, общий у всех бойцов (не ломает пакетную отрисовку).
static func material(side: int) -> ShaderMaterial:
	var i := side % 2
	if not _mats.has(i):
		var m := ShaderMaterial.new()
		m.shader = SHADER
		m.set_shader_parameter("side_hue", float(HUE[i]))
		_mats[i] = m
	return _mats[i]


static func apply(view: CharView, side: int) -> void:
	if view != null:
		view.set_look_material(material(side))
