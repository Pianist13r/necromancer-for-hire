extends Node
## Менеджер вертикального декора. Его Sprite2D — прямые дети entities, рядом с юнитами:
## y-sort сравнивает общие опорные точки, а тени остаются единственным разом в запечённом ground.

const PG_SPRITES := "res://scripts/legion/procgen/pg_art_sprites.gd"
const CELL_SIZE := 96.0
const OCCLUSION_INTERVAL := 0.1
const HIDDEN_ALPHA := 0.58
const FADE_SPEED := 5.0

var _world: LegionWorld = null
var _sprites: Array[Sprite2D] = []
var _targets: Dictionary = {}
var _refresh_left := 0.0


func setup(world: LegionWorld, map: Dictionary, entries: Array[Dictionary],
		render_parent: Node2D) -> void:
	_world = world
	if not is_instance_valid(render_parent):
		return
	var sprite_script := load(PG_SPRITES) as GDScript
	if sprite_script == null:
		return
	for entry: Dictionary in entries:
		var item: Dictionary = entry["item"]
		var tex: Texture2D = sprite_script.call("_tex", item, "tex")
		if tex == null:
			continue
		var sprite: Sprite2D = sprite_script.call("item_sprite", item, tex,
			entry["pos"], bool(entry["flip"]))
		sprite.set_meta("pgart_depth_id", String(item.get("id", "")))
		sprite.modulate = _biome_tint(String(map.get("biome", map.get("theme", "grave"))))
		render_parent.add_child(sprite)
		_sprites.append(sprite)
		_targets[sprite.get_instance_id()] = 1.0
	set_process(not _sprites.is_empty())


func clear() -> void:
	set_process(false)
	for sprite: Sprite2D in _sprites:
		if is_instance_valid(sprite):
			sprite.hide()
			sprite.queue_free()
	_sprites.clear()
	_targets.clear()


func _process(delta: float) -> void:
	_refresh_left -= delta
	if _refresh_left <= 0.0:
		_refresh_occlusion()
		_refresh_left = OCCLUSION_INTERVAL
	for sprite: Sprite2D in _sprites:
		if not is_instance_valid(sprite):
			continue
		var target := float(_targets.get(sprite.get_instance_id(), 1.0))
		var color := sprite.modulate
		color.a = move_toward(color.a, target, FADE_SPEED * delta)
		sprite.modulate = color


func _refresh_occlusion() -> void:
	if not is_instance_valid(_world):
		return
	var cells: Dictionary = {}
	for unit: Legionnaire in _world.units:
		if is_instance_valid(unit) and unit.alive:
			_add_actor(cells, unit.global_position.y, _actor_rect(unit.view))
	for foe: Foe in _world.foes:
		if is_instance_valid(foe) and foe.alive:
			_add_actor(cells, foe.global_position.y, _actor_rect(foe.view))
	for sprite: Sprite2D in _sprites:
		if not is_instance_valid(sprite):
			continue
		var rect := _sprite_world_rect(sprite)
		var behind := false
		for x in range(floori(rect.position.x / CELL_SIZE), floori(rect.end.x / CELL_SIZE) + 1):
			for y in range(floori(rect.position.y / CELL_SIZE), floori(rect.end.y / CELL_SIZE) + 1):
				for actor: Dictionary in cells.get(Vector2i(x, y), []):
					if should_fade(sprite.global_position.y, actor.rect, rect, actor.anchor_y):
						behind = true
						break
				if behind:
					break
			if behind:
				break
		_targets[sprite.get_instance_id()] = HIDDEN_ALPHA if behind else 1.0


func _actor_rect(view: CharView) -> Rect2:
	if is_instance_valid(view):
		return view.occlusion_world_rect()
	return Rect2()


func _add_actor(cells: Dictionary, anchor_y: float, rect: Rect2) -> void:
	var left := floori(rect.position.x / CELL_SIZE)
	var right := floori(rect.end.x / CELL_SIZE)
	var top := floori(rect.position.y / CELL_SIZE)
	var bottom := floori(rect.end.y / CELL_SIZE)
	for x in range(left, right + 1):
		for y in range(top, bottom + 1):
			var key := Vector2i(x, y)
			var actors: Array = cells.get(key, [])
			actors.append({"anchor_y": anchor_y, "rect": rect})
			cells[key] = actors


func _sprite_world_rect(sprite: Sprite2D) -> Rect2:
	var local := sprite.get_rect()
	var points := [sprite.to_global(local.position),
		sprite.to_global(Vector2(local.end.x, local.position.y)),
		sprite.to_global(local.end), sprite.to_global(Vector2(local.position.x, local.end.y))]
	var bounds := Rect2(points[0], Vector2.ZERO)
	for point: Vector2 in points:
		bounds = bounds.expand(point)
	return bounds


## Кадрировать следует только объект, нарисованный перед бойцом и геометрически перекрывший его.
static func should_fade(anchor_y: float, actor_rect: Rect2, sprite_rect: Rect2,
		actor_anchor_y: float) -> bool:
	return actor_anchor_y < anchor_y and actor_rect.intersects(sprite_rect)


func _biome_tint(biome: String) -> Color:
	var tints := {
		"grave": Color(0.86, 0.84, 1.0), "office": Color(1.0, 0.9, 0.78),
		"swamp": Color(0.82, 0.94, 0.86), "ash": Color(1.0, 0.88, 0.8),
		"site": Color(0.98, 0.9, 0.8), "winter": Color(0.9, 0.94, 1.0),
	}
	# Тон слабый: запечённая земля уже проходит зоновую обработку PgArt; этого хватает,
	# чтобы runtime-декор не выглядел вставленным из другого набора.
	return Color.WHITE.lerp(tints.get(biome, Color.WHITE), 0.048)
