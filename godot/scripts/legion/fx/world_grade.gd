class_name LegionWorldGrade
extends CanvasLayer
## Единый мягкий тон мира. Слой 1 оставляет HUD (5+) и модалки чистыми.

const SHADER := preload("res://shaders/world_grade.gdshader")
const TONES := {
	"ash": Color(0.985, 0.97, 1.0), "grave": Color(0.955, 0.99, 1.0),
	"swamp": Color(0.94, 1.0, 0.98), "office": Color(1.0, 0.965, 0.935),
	"site": Color(1.0, 0.97, 0.94),
}

var world: LegionWorld
var rect: ColorRect


func setup(w: LegionWorld) -> void:
	world = w
	name = "WorldGrade"
	layer = 1
	process_mode = Node.PROCESS_MODE_ALWAYS
	rect = ColorRect.new()
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UiStyle.fill_rect(rect)
	var mat := ShaderMaterial.new()
	mat.shader = SHADER
	rect.material = mat
	add_child(rect)
	world.match_started.connect(_map_changed)
	_process(0.0)


func _map_changed(_id: String) -> void:
	var biome := String(world.map.get("biome", ""))
	if biome.is_empty():
		biome = "swamp" if world.map_id == "swamp" else "office" if world.map_id in [
			"archive", "office"] else "grave"
	var mat := rect.material as ShaderMaterial
	mat.set_shader_parameter("biome_tone", TONES.get(biome, TONES["grave"]))
	# Кампанийный фон уже затемнён по краям: не накладываем сильную виньетку второй раз.
	mat.set_shader_parameter("vignette", 0.12 if world.map.has("bg") else 0.18)


func _process(_dt: float) -> void:
	# CanvasLayer могут скрыть модальные экраны. Не перезаписываем их hide()/show().
	rect.visible = is_instance_valid(world) and world.is_visible_in_tree() \
		and world.phase != LegionWorld.Phase.MENU and Settings.is_world_grade_enabled() \
		and not Settings.is_economy_graphics()
