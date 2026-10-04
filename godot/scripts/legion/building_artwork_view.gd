extends Node2D
## Изолированный слой рисунка здания. Подпись штата и командный акцент остаются у LegionBuilding.

const PAINTERLY_TEXTURE := "res://assets/legion/buildings/laborer_1_painterly.png"
const SHADOW_ALPHA := 0.85
const SHADOW_W := 1.32
const SHADOW_H := 0.95
const STYLE_SHADER := preload("res://shaders/actor_grounding/building_artwork.gdshader")

var _texture: Texture2D
var _display_width := 90.0
var _anchor_y := 0.72
var _tint := Color.WHITE
## Ширина контактной тени в долях ширины рисунка (0,78 — как было; на собранных картах шире).
var _shadow_k := 0.78
var _sprite: Sprite2D
var _shadow: Sprite2D


func configure(texture: Texture2D, display_width: float, anchor_y: float) -> void:
	_texture = texture
	_display_width = display_width
	_anchor_y = anchor_y
	_create_shadow()
	_create_sprite()
	_layout()


func set_variant(variant: StringName) -> void:
	if not is_instance_valid(_sprite):
		return
	_sprite.material = null
	_sprite.texture = _texture
	_sprite.modulate = _tint
	match variant:
		&"shader":
			var material := ShaderMaterial.new()
			material.shader = STYLE_SHADER
			_sprite.material = material
		&"painterly":
			var painterly := load(PAINTERLY_TEXTURE) as Texture2D
			if painterly == null:
				push_error("Painterly building asset is not imported: %s" % PAINTERLY_TEXTURE)
				return
			_sprite.texture = painterly
		&"original":
			pass
		_:
			push_warning("Unknown building artwork variant: %s" % variant)
	_layout()


## Контактная тень собранной карты (D-CX-08): шире и плотнее, цветом земли рядом, а не чёрная.
## Белая текстура-градиент красится modulate; базовая (почти чёрная) тонироваться не может.
func set_ground_shadow(color: Color) -> void:
	if not is_instance_valid(_shadow):
		return
	var tex := _shadow.texture as GradientTexture2D
	if tex != null:
		var g := Gradient.new()
		g.set_color(0, Color(1, 1, 1, 1))
		g.set_color(1, Color(1, 1, 1, 0))
		g.add_point(0.5, Color(1, 1, 1, 0.8))
		tex.gradient = g
	_shadow.modulate = Color(color.r, color.g, color.b, SHADOW_ALPHA)
	_shadow.scale.y = SHADOW_H
	_shadow_k = SHADOW_W
	_shadow.position = Vector2(3, 0)
	_layout()


## Тонировка рисунка под землю карты (D-CX-08); белый — как нарисован. Только Sprite2D здания.
func set_tint(color: Color) -> void:
	_tint = color
	if is_instance_valid(_sprite):
		_sprite.modulate = color


func set_display_width(width: float) -> void:
	_display_width = maxf(1.0, width)
	_layout()


func _create_shadow() -> void:
	if not is_instance_valid(_shadow):
		_shadow = Sprite2D.new()
		_shadow.name = "ContactShadow"
		_shadow.centered = true
		add_child(_shadow)
	var gradient := Gradient.new()
	gradient.set_color(0, Color(0.035, 0.025, 0.02, 0.20))
	gradient.set_color(1, Color(0.035, 0.025, 0.02, 0.0))
	var texture := GradientTexture2D.new()
	texture.gradient = gradient
	texture.width = 64
	texture.height = 32
	texture.fill = GradientTexture2D.FILL_RADIAL
	texture.fill_from = Vector2(0.5, 0.5)
	texture.fill_to = Vector2(1.0, 0.5)
	_shadow.texture = texture
	_shadow.scale = Vector2(_display_width * 0.78 / texture.get_width(), 0.34)
	_shadow.position = Vector2(0, -2)


func _create_sprite() -> void:
	if not is_instance_valid(_sprite):
		_sprite = Sprite2D.new()
		_sprite.name = "Artwork"
		_sprite.centered = false
		add_child(_sprite)
	_sprite.texture = _texture


func _layout() -> void:
	if not is_instance_valid(_sprite) or _sprite.texture == null:
		return
	var scale_factor := _display_width / float(_sprite.texture.get_width())
	_sprite.scale = Vector2(scale_factor, scale_factor)
	_sprite.position = Vector2(
		-_display_width * 0.5, -_sprite.texture.get_height() * scale_factor * _anchor_y
	)
	if is_instance_valid(_shadow):
		_shadow.scale.x = _display_width * _shadow_k / float(_shadow.texture.get_width())
