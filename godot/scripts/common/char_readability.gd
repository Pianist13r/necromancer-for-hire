class_name CharReadability
extends RefCounted
## Два общих материала: без копии шейдера/узла на каждого из 300 врагов.

const SHADER := preload("res://shaders/character_rim.gdshader")
static var _materials: Dictionary = {}


static func for_character(id: String) -> ShaderMaterial:
	var friendly := id in ["skeleton", "guard", "clerk", "necromancer"]
	if not _materials.has(friendly):
		var mat := ShaderMaterial.new()
		mat.shader = SHADER
		mat.set_shader_parameter("rim_color", Color(0.20, 0.25, 0.24, 0.55) if friendly
			else Color(0.07, 0.04, 0.10, 0.82))
		mat.set_shader_parameter("width", 1.2 if friendly else 2.0)
		_materials[friendly] = mat
	return _materials[friendly]
