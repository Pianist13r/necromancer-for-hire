class_name PgArtMask
extends Node2D
## Карта зон собранной картинки для обработки PgArt (линия art3, D-0927-210): рендерится в свой
## SubViewport вдвое меньше кадра и читается пост-шейдером (перенос цвета по зонам, затемнение
## у подножий, защита оград и каймы от Кувахары) и PgArt (статистика цвета сборки по зонам).
##
## Каналы:
##   R — дорога: 1,0 сердцевина полотна, 0,75 полоса каймы; 0,5 — вода и топь; 0 — земля;
##   G — силуэты предметов (спрайты стен, препятствий, декора, мостов; без россыпи — она земля);
##   B — основания: следы препятствий, стены, основания декора — от них темнеет земля.
## Координаты — мировые; корень масштабирован под размер вьюпорта (PgArt).

const SILHOUETTE := "res://scripts/legion/procgen/pg_mask_silhouette.gdshader"
const KERB_FRAC := 1.0 ## полная ширина видимой ленты — зона каймы
const CORE_FRAC := 0.6 ## сердцевина полотна (как у образца: ≤ 0,75 полуширины… с запасом на кайму)
const C_ROAD := Color(1.0, 0.0, 0.0)
const C_KERB := Color(0.75, 0.0, 0.0)
const C_WATER := Color(0.5, 0.0, 0.0)

var _map: Dictionary = {}
var _road_w := 55.0


## Собирает под собой слои маски. road_w — видимая ширина ленты дороги (мира).
func setup(map: Dictionary, road_w: float) -> void:
	_map = map
	_road_w = road_w
	name = "PgArtMask"
	var feet := _Feet.new()
	feet.map = map
	var add := CanvasItemMaterial.new()
	add.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	feet.material = add
	add_child(feet)
	var sil := Node2D.new()
	sil.name = "Silhouettes"
	var mat := ShaderMaterial.new()
	mat.shader = load(SILHOUETTE) as Shader
	sil.material = mat
	add_child(sil)
	PgArtSprites.build(sil, map)
	_inherit(sil)
	queue_redraw()


## Силуэтный материал родителя — всем потомкам (use_parent_material действует на один уровень).
func _inherit(node: Node) -> void:
	for c in node.get_children():
		if c is CanvasItem:
			(c as CanvasItem).use_parent_material = true
		_inherit(c)


func _draw() -> void:
	# весь мир карты (поле «Схватки» 1600×900 — P5b) с запасом за край
	draw_rect(Rect2(Vector2(-64, -64), LegionTerrain.map_size(_map) + Vector2(128, 128)),
		Color.BLACK)
	for raw: Array in _map.get("water", []):
		var poly := PgArtRoad._points(raw)
		if poly.size() >= 3:
			draw_colored_polygon(poly, C_WATER)
	# Непрерывная мокрая земля соответствует механической зоне замедления целиком.
	for raw: Array in _map.get("swamp", []):
		var poly := PgArtRoad._points(raw)
		if poly.size() >= 3:
			draw_colored_polygon(poly, C_WATER)
	for pass_def: Array in [[KERB_FRAC, C_KERB], [CORE_FRAC, C_ROAD]]:
		var w := _road_w * float(pass_def[0])
		for road: Dictionary in _map.get("roads", []):
			var line := PgArtRoad.rounded(PgArtRoad._points(road.get("path", [])))
			if line.size() < 2:
				continue
			draw_polyline(line, pass_def[1], w, true)
			for p in line:
				draw_circle(p, w * 0.5, pass_def[1])


## Основания (канал B) — аддитивно поверх.
class _Feet:
	extends Node2D
	var map: Dictionary = {}

	func _draw() -> void:
		var c := Color(0, 0, 1)
		for raw: Array in map.get("rocks", []):
			var poly := PgArtRoad._points(raw)
			if poly.size() >= 3:
				draw_colored_polygon(poly, c)
		for w: Dictionary in map.get("walls", []):
			var path := PgArtRoad._points(w.get("path", []))
			if path.size() >= 2:
				draw_polyline(path, c, float(w.get("w", 24.0)))
		for prop: Dictionary in map.get("props", []):
			var item := PgCatalog.by_id(String(prop.get("item", "")))
			if String(item.get("role", "")) != "decor":
				continue
			var base: Array = item.get("base", [])
			if base.size() < 3 or not (item.get("tags", []) as Array).has("tree"):
				continue
			var pos := Vector2(float(prop.pos[0]), float(prop.pos[1]))
			var flip := bool(prop.get("flip", false))
			var poly := PackedVector2Array()
			for raw: Array in base:
				poly.append(pos + Vector2(-float(raw[0]) if flip else float(raw[0]), float(raw[1])))
			if Geometry2D.triangulate_polygon(poly).size() > 0:
				draw_colored_polygon(poly, c)
