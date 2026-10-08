class_name CharShadows
extends Node2D
##
## Тени под персонажами (v19, 26.09.2026). Без тени фигура висит над нарисованной землёй —
## а при разглядывании именно это и выдаёт «картонку». Слой лежит под рунами и под всеми
## персонажами (мир ставит его перед Contracts) и рисует все тени одной текстурой за один
## проход: на телефоне это один вызов отрисовки, а не по узлу на бойца.
##
## Источник — CharView.registry (вид сам встаёт в список при входе в дерево). Размер и
## прозрачность — CfgAnim MOTION shadow_*; тень лежит на земле: поворот и оседание смерти её
## не двигают, таяние трупа и прозрачность призрака — гасят.
##

const TEX_SIZE := 64

static var _tex: Texture2D = null
## Собранная карта (PgArt): тень берёт цвет земли под ногами вместо чёрного (D-CX-08); null —
## чёрная тень, как была (кампания, нарисованные фоны).
var harmony: PgArtHarmony = null


func _ready() -> void:
	if _tex == null:
		_tex = _make_texture()


## Мягкое пятно: радиальный градиент, плотный центр и растушёванный край. Текстура белая, цвет
## тени задаёт modulate в _draw (чёрный по умолчанию; чёрная текстура не тонируется).
static func _make_texture() -> Texture2D:
	var g := Gradient.new()
	g.set_offset(0, 0.0)
	g.set_color(0, Color(1, 1, 1, 1))
	g.set_offset(1, 1.0)
	g.set_color(1, Color(1, 1, 1, 0))
	g.add_point(0.55, Color(1, 1, 1, 0.72))
	var t := GradientTexture2D.new()
	t.gradient = g
	t.width = TEX_SIZE
	t.height = TEX_SIZE
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(1.0, 0.5)
	return t


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	var inv := get_global_transform().affine_inverse()
	# дёшево: поля вида вместо словарей; видимость — сам вид и сущность (вся вложенность
	# is_visible_in_tree() на сотнях фигур за кадр заметна)
	for v in CharView.registry:
		if not v.visible:
			continue
		var parent := v.get_parent() as Node2D
		if parent == null or not parent.visible:
			continue
		var a := v.shadow_alpha() * v.shadow_a * parent.modulate.a
		if a <= 0.01:
			continue
		var size := Vector2(v.shadow_w_px, v.shadow_h_px * 0.85)
		var c: Vector2 = inv * (parent.global_position + Vector2(0.0, v.ground_px()))
		var col := Color(0.075, 0.065, 0.10, minf(a * 1.22, 0.72))
		if harmony != null and harmony.ready():
			var tint := harmony.shadow_tint(parent.position)
			col = Color(tint.r, tint.g, tint.b, a)
		draw_texture_rect(_tex, Rect2(c - size * 0.5, size), false, col)
