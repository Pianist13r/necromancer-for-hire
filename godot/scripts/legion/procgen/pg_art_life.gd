class_name PgArtLife
extends Node2D
## Small composed still-lifes on unused ground, with a separate quiet animation layer.
## Never edits map data or consumes the simulation RNG.
## Поле «Схватки» (P5b, B-CX-B-06): группы выбираются на половине стороны 0 и отражаются
## (x' = W − x) — стороны одинаковы; место годно, только если свободно и его зеркало (зоны Котлов
## обеих сторон исключены). positions() тогда чередует [группа, её зеркало, …].
const COUNT := 3
const CLEAR := 68.0
const GAP := 240.0
const SETS := {
	"grave": ["grave_dec_slab", "grave_dec_wreath", "grave_dec_grass", "grave_dec_mushrooms"],
	"swamp": ["swamp_dec_log", "swamp_dec_moss", "swamp_dec_grass", "swamp_dec_mushrooms"],
	"ash": ["ash_dec_crystalslab", "ash_dec_burn", "ash_dec_chain", "ash_dec_embercrack"],
	"site": ["site_dec_tray", "site_dec_bricks", "site_dec_sawdust", "site_dec_nails"],
	"office": ["under_dec_rug", "under_dec_contracts", "under_dec_contracts"],
}
const TINT := {"grave": Color("849d65"), "swamp": Color("77b49c"),
	"ash": Color("ee9868"), "site": Color("c1ab8c"), "office": Color("d4c1a0")}
var centers := PackedVector2Array()
var biome := "grave"
var animated := false
## Ширина зеркального поля PvP (LegionTerrain.mirror_width; 0 — одиночка).
var mirror_w := 0.0
var _time := 0.0
var _redraw_acc := 0.0


static func positions(map: Dictionary) -> PackedVector2Array:
	var result := PackedVector2Array()
	if not SETS.has(String(map.get("biome", map.get("theme", "grave")))):
		return result
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(String(map.get("id", "")) + "|still-life")
	var free := PgArtScatter.Free.new(map, PgArtScatter._cauldron(map))
	var mw := LegionTerrain.mirror_width(map)
	var area := PgArtScatter.area_size(map)
	var want := COUNT * (2 if mw > 0.0 else 1)
	for attempt in 240:
		# одиночка: x 90…1190, y 140…620 — как в кадре 1280×720 до P5b
		var p := Vector2(rng.randf_range(90, area.x - 90), rng.randf_range(140, area.y - 100))
		if not free.ok(p, CLEAR):
			continue
		var twin := PgArtScatter.mirror(p, mw)
		if mw > 0.0 and (twin.distance_to(p) < GAP or not free.ok(twin, CLEAR)):
			continue
		var near := false
		for old in result:
			if old.distance_to(p) < GAP:
				near = true
		if near:
			continue
		result.append(p)
		if mw > 0.0:
			result.append(twin)
		if result.size() == want:
			break
	return result


func setup(map: Dictionary, animate: bool) -> void:
	centers = positions(map)
	mirror_w = LegionTerrain.mirror_width(map)
	biome = String(map.get("biome", map.get("theme", "grave")))
	animated = animate
	set_process(animate and not centers.is_empty())
	if not animate:
		_build_objects()
	queue_redraw()


func _build_objects() -> void:
	var ids: Array = SETS.get(biome, [])
	for ci in centers.size():
		var k := _source(ci)
		var m := _side_sign(ci)
		for i in ids.size():
			var item := PgCatalog.by_id(String(ids[i])).duplicate()
			var tex := PgArtSprites._tex(item, "tex")
			if tex == null:
				continue
			var offset := Vector2.ZERO if i == 0 else Vector2.from_angle(
				float(i) * 2.1 + float(k) * 0.8) * 28.0
			offset.x *= m
			item["w"] = float(item.get("w", 48)) * (1.05 if i == 0 else 0.78)
			var flip := (k % 2 == 0) != (m < 0.0)
			var sprite := PgArtSprites.item_sprite(item, tex, centers[ci] + offset, flip)
			sprite.rotation = sin(float(i + k)) * 0.12 * m
			add_child(sprite)


## Группа, зеркалом которой является ci (поле PvP: нечётные — зеркала чётных; одиночка — сама).
func _source(ci: int) -> int:
	return ci - 1 if mirror_w > 0.0 and ci % 2 == 1 else ci


## Знак по x: у зеркальной группы смещения, повороты и движение отражены.
func _side_sign(ci: int) -> float:
	return -1.0 if mirror_w > 0.0 and ci % 2 == 1 else 1.0


func _process(dt: float) -> void:
	_time += dt
	_redraw_acc += dt
	if _redraw_acc >= 1.0 / 30.0:
		_redraw_acc = 0.0
		queue_redraw()


func _draw() -> void:
	var tint: Color = TINT.get(biome, Color.WHITE)
	for ci in centers.size():
		var center := centers[ci]
		var k := _source(ci)
		var m := _side_sign(ci)
		if not animated:
			# Feathered soil patch grounds each group; no opaque disc or new collision.
			for ring in range(5, 0, -1):
				draw_set_transform(center, 0.15 * k * m, Vector2(1.0, 0.62))
				draw_circle(Vector2.ZERO, 24.0 + ring * 7.0, Color(tint * 0.48, 0.025))
			draw_set_transform(Vector2.ZERO)
			continue
		# Three tiny, slow local motes. Never cross a road or enter a combat plot.
		for i in 3:
			var phase := float(k * 3 + i) * 2.37
			var motion := Vector2(sin(_time * 0.37 + phase) * 18.0 * m,
				cos(_time * 0.29 + phase * 1.7) * 9.0 - 10.0)
			var alpha := 0.08 + 0.10 * pow(0.5 + 0.5 * sin(_time * 0.8 + phase), 2.0)
			if biome in ["grave", "swamp", "ash"]:
				draw_circle(center + motion, 3.8, Color(tint, alpha * 0.28))
				draw_circle(center + motion, 1.15, Color(tint, alpha))
			else:
				draw_line(center + motion, center + motion + Vector2(2.0, 1.0),
					Color(tint, alpha * 0.6), 1.0, true)
