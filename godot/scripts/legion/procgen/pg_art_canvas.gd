class_name PgArtCanvas
extends Node2D
## Слои сборки картинки процедурной карты, которые рисуются кодом (BOOK.md §8.3, §9, B-107;
## линия art3 — вода с кромкой, контактные тени, «клей» у подножий). Рисует в мировых
## координатах 1280×720 — PgArt растягивает узел трансформом ×1,5 внутри SubViewport 1920×1080
## (мир ×1,5, как у фонов кампании), поэтому все константы здесь — в мировых px.
##
## Сборка — стопка узлов (PgArt.compose), порядок как в BOOK §8.3:
##   подложка (Sprite2D) → UNDER: пятна почвы → дорога (PgArtRoad, меш-ленты) →
##   MID: вода/топь с кромкой и бликами, тени предметов, заглушки без картинки →
##   предметы, стены, мосты, камыш (PgArtSprites, спрайты с y-сортировкой) →
##   TOP: «клей» у подножий, пятна тёплого света, общий свет (без фото-подложки).
## Палитру, виньетку, кувахару и туман кладёт post-шейдер pg_post.gdshader (PgArt._run).
##
## Текстуры здесь не рисуются вовсе: draw_texture_rect(любая текстура) внутри вложенного
## SubViewport рендерил пустой БЕЛЫЙ кадр (замеры линии terrain); всё текстурное — узлами.

enum Layer { UNDER, MID, TOP }

## Кадр одиночной карты; рисуется весь мир карты (_world — поле «Схватки» 1600×900, P5b).
const WORLD := Vector2(1280, 720)
const GROUND_DIR := "res://assets/legion/procgen/ground/"
## Готовые подложки на биом (D-0927-72 + добор 27.09): выбор по (сид, k) детерминирован, чтобы
## одна и та же карта всегда открывала одну и ту же подложку.
const GROUND_CATALOG := {
	"grave": ["grave_01", "grave_02"], "office": ["office_01", "office_02"],
	"swamp": ["swamp_01", "swamp_02"], "ash": ["ash_01", "ash_02"], "site": ["site_01", "site_02"],
	"boiler": ["boiler_01"], "hell": ["hell_01"], "winter": ["winter_01"],
}

## Земля-заглушка, когда подложки для биома совсем нет (страховка): средний тон, L 0,28–0,58.
const BIOME_LAND := {
	"grave": Color("4c3f57"), "office": Color("5a4638"), "swamp": Color("515b3f"),
	"ash": Color("9c6d63"), "site": Color("7c5642"),
}
const SOFT_STEPS := 6
const HAIR := 1.0

## Вода по биому: глубокая бирюза реки кладбища (как «Мост») и зелёная болотная (как «Болото»);
## топь (проходимая, ×0,5) — тёмная бурая бирюза, полупрозрачная: сквозь неё читается земля и
## полотно дороги, если топь легла на дорогу (изюминка «топь на дороге»). Первый вариант —
## светлая оливковая — на кадре читался травяной поляной, а не трясиной.
const WATER_COL := {"swamp": Color("1f7a66"), "default": Color("1d5f73")}
const MARSH_COL := {"swamp": Color("1a7a60"), "grave": Color("24463a"), "ash": Color("3a3044"),
	"site": Color("4a3826"), "office": Color("4a2f1f")} ## пепельная жижа, глина, пролитый кофе
const MARSH_ALPHA := 0.74
const SWAMP_POOL_ALPHA := 0.88
const BANK_INK := Color(0.06, 0.05, 0.05, 0.6) ## тёмный контур берега, как на фонах
const BANK_W := 2.2
const WET_SOIL := Color(0.08, 0.07, 0.04, 0.22) ## мокрая земля у кромки
const WET_SOIL_GROW := 7.0
const DEPTH_STEPS := [6.0, 13.0, 22.0] ## вглубь от берега — темнее (вода глубже к середине)
const DEPTH_DARKEN := 0.09
const SHORE_LIGHT_A := 0.32 ## светлая полоска у берега — отражение неба
const GLINT_AREA := 2600.0 ## мира² на один блик
const GLINT_MAX := 28
const GLINT_COL := Color(0.9, 1.0, 0.98, 0.42)
const DUCKWEED_STEP := 26.0 ## ряска — кучками вдоль берега топи и болотной воды
const DUCKWEED_COL := Color("93b04c")
const MUD_COL := Color(0.16, 0.13, 0.08, 0.35)

const WOOD := Color("84705f")
const BONE := Color("aaa69b")
const WARM := Color("ffc17c")

## Звенья стен без картинки в каталоге (страховка) — прежняя кодовая полоса.
const WALL_COLORS := {
	"stone": Color("454a63"), "fence": Color("5c4a3a"), "shelf": Color("6b4a34"),
	"cabinet": Color("53617a"),
}

## Силуэт препятствия-заглушки без спрайта (BOOK §8.2 п.1, п.4): свет сверху слева.
const ROCK_FACE_DARK := Color("242640")
const ROCK_FACE_LIGHT := Color("7d86ad")
const ROCK_CAP := Color("969fc4")
const ROCK_RIM_WARM := Color("f0d9a8")
const ROCK_OUTLINE := Color("14152280")
const ROCK_OUTLINE_W := 2.2
const ROCK_LIGHT_DIR := Vector2(-0.6, -0.8)
const ROCK_CAP_INSET := 0.62

## Тень: вправо-вниз, 10–12 px картинки (§8.2 п.5) — в мировых px ÷1,5; мягкая — три
## слоя с растущим отступом и падающей альфой (сумма ≈ 40 %, как в замере фонов).
const SHADOW_DIR := Vector2(6.0, 7.5)
const SHADOW_COLOR := Color(0.02, 0.02, 0.05)
const SHADOW_SOFT := [[0.0, 0.17], [3.0, 0.11], [6.5, 0.07]]
## Контактная тень — тёмное пятно прямо у основания (предмет «стоит», а не висит).
const CONTACT_ALPHA := 0.22
const CONTACT_FLAT := 0.32 ## эллипс: высота = ширина × это

## Фактура почвы — лёгкая присыпка, не перекраска (на фото-подложке втрое слабее).
const GRAIN_COUNT := 900
const GRAIN_RADIUS := 1.2
const GRAIN_ALPHA := 0.03
const SOIL_PATCHES := 40
const SOIL_RADIUS := 46.0
const SOIL_ALPHA := 0.012
const TEXTURE_DUST_MULT := 0.35
const HASH_SCALE := 43758.5453
const HASH_PHASE := 12.9898

## Клей у подножия (§8.3, §6.6): камешки и пучки травы по нижней половине основания.
const GLUE_MIN := 3
const GLUE_MAX := 6
const GLUE_REACH := 1.08 ## насколько за контур основания
const PEBBLE_R := Vector2(1.6, 3.2)
const TUFT_LEN := Vector2(4.0, 7.0)
const GLUE_STONE := {"ash": Color("8a7fa0"), "grave": Color("8d8f86"), "swamp": Color("7d8a70"),
	"site": Color("9a8068"), "office": Color("7a6f66")}
const GLUE_GRASS := {"grave": Color("5f7a3a"), "swamp": Color("4f7a44"), "ash": Color("8a6a4a"),
	"site": Color("7a6038")}
const GLUE_INK := Color(0.08, 0.07, 0.08, 0.7)

## Пятна света — ТОЛЬКО у источников (свечи, ambient.glows), мягкий радиальный спад, слабо.
const GLOW_COLOR := Color("ffb060")
const GLOW_RADIUS := 26.0
const GLOW_RING_ALPHA := 0.028
const WASH_WARM := Color(1.0, 0.86, 0.62)
const WASH_COOL := Color(0.05, 0.05, 0.12)
const WASH_RING_ALPHA := 0.018

const PROP_FALLBACK_W := 40.0

## Замер для PgArt._report: last_land_luma — светлота ГОЛОЙ земли (фото или заливка);
## used_ground_texture — легла ли настоящая подложка (иначе заливка и общий свет — здесь).
var last_land_luma := 0.0
var used_ground_texture := false
var layer := Layer.MID

var _map: Dictionary = {}
var _world := WORLD
## Ширина зеркального поля PvP (LegionTerrain.mirror_width; 0 — одиночка).
var _mirror_w := 0.0
var _biome := "ash"
var _covered := PackedInt32Array()
var _avoid: PgArtSprites.Avoid = null


func setup(map: Dictionary, ground_used: bool, ground_luma: float, which: Layer) -> void:
	_map = map
	_world = LegionTerrain.map_size(map)
	_mirror_w = LegionTerrain.mirror_width(map)
	layer = which
	name = "Canvas" + String(Layer.keys()[which])
	_biome = String(map.get("biome", map.get("theme", "ash")))
	used_ground_texture = ground_used
	last_land_luma = ground_luma if ground_used else _land_color().get_luminance()
	if which != Layer.UNDER:
		_covered = PgArtSprites.covered_rocks(map)
	if which == Layer.TOP:
		_avoid = PgArtSprites.Avoid.new(map)


## Детерминированный выбор готовой подложки по (сид, k) карты. Статик — PgArt зовёт его ДО
## рендера, чтобы решить параметры post-шейдера (фото или заливка) синхронно.
static func resolve_ground_path(map: Dictionary) -> String:
	var explicit := String(map.get("ground", ""))
	if not explicit.is_empty() and ResourceLoader.exists(explicit, "Texture2D"):
		return explicit
	if explicit.ends_with(".jpg"):
		var sibling := explicit.trim_suffix(".jpg") + ".png"
		if ResourceLoader.exists(sibling, "Texture2D"):
			return sibling
	var biome := String(map.get("biome", map.get("theme", "ash")))
	var options: Array = GROUND_CATALOG.get(biome, [])
	if options.is_empty():
		return ""
	var procgen: Dictionary = map.get("procgen", {})
	var key: String
	if procgen.has("seed"):
		key = "%s:%s" % [str(procgen.get("seed", 0)), str(procgen.get("k", 0))]
	else:
		key = String(map.get("id", biome))
	var idx := absi(hash(key)) % options.size()
	var stem := GROUND_DIR + String(options[idx])
	return stem + ".png" if ResourceLoader.exists(stem + ".png", "Texture2D") else stem + ".jpg"


func _draw() -> void:
	if _map.is_empty():
		return
	match layer:
		Layer.UNDER:
			_ground()
		Layer.MID:
			_draw_mid()
		Layer.TOP:
			_draw_top()


func _draw_mid() -> void:
	# вне «Болота» топь рисует PgArtMarsh (спрайты и подложка), здесь — только бирюзовая заводь
	if _biome == "swamp":
		for raw: Array in _map.get("swamp", []):
			_marsh(_points(raw))
	for raw: Array in _map.get("water", []):
		_water(_points(raw))
	if not _has_bridge_sprite():
		for b: Array in _map.get("bridges", []):
			_bridge(_points(b))
	# тени сперва (§8.3: «тени предметов» перед самими предметами)
	var rocks: Array = _map.get("rocks", [])
	for i in rocks.size():
		if not _covered.has(i):
			_soft_shadow(_points(rocks[i]))
	for entry: Dictionary in _map.get("walls", []):
		_wall_shadow(entry)
	for prop: Dictionary in _map.get("props", []):
		_prop_shadow(prop)
	for i in rocks.size():
		if not _covered.has(i):
			_rock(_points(rocks[i]))
	for entry: Dictionary in _map.get("walls", []):
		if _wall_tex_missing(entry):
			_wall(entry)
	for prop: Dictionary in _map.get("props", []):
		_prop_fallback(prop)
	# код-декор кампании (--dev pgart=1 на кампанийной карте): у процедурной карты тот же
	# декор уже стоит спрайтами в props — не задваиваем
	if (_map.get("props", []) as Array).is_empty():
		for item: Dictionary in _map.get("decor", []):
			var p := Vector2(item.pos[0], item.pos[1])
			var kind := String(item.get("kind", "grave"))
			var lib := PgArtSprites.decor_item(kind, _biome, p)
			if not lib.is_empty():
				# декор стал спрайтом библиотеки (PgArtSprites) — здесь только его тень
				_prop_shadow({"item": lib["id"], "pos": item.pos,
					"flip": PgArtSprites.decor_flip(p)})
				continue
			_contact(p, 10.0)
			_decor(p, kind)


func _draw_top() -> void:
	var rocks: Array = _map.get("rocks", [])
	for i in rocks.size():
		_glue(_points(rocks[i]), i)
	for prop: Dictionary in _map.get("props", []):
		var item := PgCatalog.by_id(String(prop.get("item", "")))
		if String(item.get("role", "")) != "decor" or not (item.get("tags", []) as Array).has("tree"):
			continue
		var base := _item_poly(item, prop, "base")
		if base.size() >= 3:
			_glue(base, int(float(prop.pos[0]) * 7.0 + float(prop.pos[1])))
	_light_glows()
	_light_wash()


# ── Земля ────────────────────────────────────────────────────────────────────

func _ground() -> void:
	if not used_ground_texture:
		draw_rect(Rect2(Vector2.ZERO, _world), _land_color())
	_soil_patches()


func _land_color() -> Color:
	return BIOME_LAND.get(_biome, BIOME_LAND["ash"])


func _soil_patches() -> void:
	var mult := TEXTURE_DUST_MULT if used_ground_texture else 1.0
	var tint := _land_color().lightened(0.12)
	# поле PvP: узор на половине стороны 0 и его зеркало (стороны одинаковы, шва нет)
	var area := _world
	var n_soil := SOIL_PATCHES
	var n_grain := GRAIN_COUNT
	if _mirror_w > 0.0:
		area = Vector2(_mirror_w * 0.5, _world.y)
		var k := area.x * area.y / (WORLD.x * WORLD.y)
		n_soil = roundi(SOIL_PATCHES * k)
		n_grain = roundi(GRAIN_COUNT * k)
	for i in n_soil:
		var p := Vector2(_hash(i) * area.x, _hash(i + SOIL_PATCHES) * area.y)
		for q in _mirrored(p):
			for step in SOFT_STEPS:
				draw_circle(q, SOIL_RADIUS * (1.0 + float(step) / SOFT_STEPS),
					Color(tint, SOIL_ALPHA * mult))
	for i in n_grain:
		var p := Vector2(_hash(i * 137.37) * area.x, _hash(i * 79.73) * area.y)
		for q in _mirrored(p):
			draw_circle(q, GRAIN_RADIUS, Color(tint, GRAIN_ALPHA * mult))


## Точка узора и её зеркало на поле PvP (одиночка — только сама точка).
func _mirrored(p: Vector2) -> PackedVector2Array:
	if _mirror_w > 0.0:
		return PackedVector2Array([p, Vector2(_mirror_w - p.x, p.y)])
	return PackedVector2Array([p])


func _hash(value: float) -> float:
	return fposmod(sin(value * HASH_PHASE) * HASH_SCALE, 1.0)


func _points(raw: Array) -> PackedVector2Array:
	var result := PackedVector2Array()
	for p: Array in raw:
		result.append(Vector2(p[0], p[1]))
	return result


# ── Вода и топь ──────────────────────────────────────────────────────────────

## Вода «как нарисовано» (фоны «Мост», «Болото»): мокрая земля у кромки, тёмный контур берега,
## глубина — темнее к середине, светлая полоска отражения у берега, блики, на болоте — ряска.
## Живые блики поверх рисует LegionFx по ambient.water (фоновая жизнь карты).
func _water(poly: PackedVector2Array) -> void:
	if poly.size() < 3:
		return
	var col: Color = WATER_COL.get(_biome, WATER_COL["default"])
	for grown in Geometry2D.offset_polygon(poly, WET_SOIL_GROW):
		draw_colored_polygon(grown, WET_SOIL)
	draw_colored_polygon(poly, col)
	for i in DEPTH_STEPS.size():
		for inner in Geometry2D.offset_polygon(poly, -float(DEPTH_STEPS[i])):
			draw_colored_polygon(inner, col.darkened(DEPTH_DARKEN * (i + 1)))
	for rim in Geometry2D.offset_polygon(poly, -2.5):
		_ring(rim, Color(col.lightened(0.45), SHORE_LIGHT_A), 1.6)
	_ring(poly, BANK_INK, BANK_W)
	_glints(poly)
	if _biome == "swamp":
		_duckweed(poly)


## Топь (проходимая, ×0,5): мутная полупрозрачная заливка, грязь пятнами, ряска у кромки.
func _marsh(poly: PackedVector2Array) -> void:
	if poly.size() < 3:
		return
	for grown in Geometry2D.offset_polygon(poly, WET_SOIL_GROW * 0.7):
		draw_colored_polygon(grown, WET_SOIL)
	var col: Color = MARSH_COL.get(_biome, MARSH_COL["swamp"])
	if _biome == "swamp":
		# болото биома «Болото» — светящаяся бирюзовая заводь, как на фоне кампании, а не бурая
		# жижа: светлее к середине, плотнее (мутная полупрозрачность читалась тенью на траве)
		draw_colored_polygon(poly, Color(col, SWAMP_POOL_ALPHA))
		for inner in Geometry2D.offset_polygon(poly, -10.0):
			draw_colored_polygon(inner, Color(col.lightened(0.14), 0.4))
		for inner in Geometry2D.offset_polygon(poly, -22.0):
			draw_colored_polygon(inner, Color(col.lightened(0.24), 0.3))
		for rim in Geometry2D.offset_polygon(poly, -2.5):
			_ring(rim, Color(col.lightened(0.45), SHORE_LIGHT_A), 1.6)
	else:
		draw_colored_polygon(poly, Color(col, MARSH_ALPHA))
		for inner in Geometry2D.offset_polygon(poly, -8.0):
			draw_colored_polygon(inner, Color(col.darkened(0.12), MARSH_ALPHA * 0.5))
	var box := _box(poly)
	var n := int(box.get_area() / 1800.0)
	for k in n:
		var p := box.position + Vector2(_hash(k * 3.7 + box.position.x),
			_hash(k * 5.1 + box.position.y)) * box.size
		if Geometry2D.is_point_in_polygon(p, poly) and _edge_dist(p, poly) > 6.0:
			_blob(p, 3.0 + _hash(k + 0.5) * 5.0, MUD_COL)
	_ring(poly, Color(BANK_INK, BANK_INK.a * 0.6), 1.6)
	# ряска — только живому болоту; на пепле, глине и кофе её не бывает
	if _biome == "swamp" or _biome == "grave":
		_duckweed(poly)
	_glints(poly, 0.5)


func _glints(poly: PackedVector2Array, mult := 1.0) -> void:
	var box := _box(poly)
	var n := mini(GLINT_MAX, int(box.get_area() / GLINT_AREA * mult))
	for k in n:
		var p := box.position + Vector2(_hash(k * 7.3 + box.position.y * 0.1),
			_hash(k * 2.9 + box.position.x * 0.1)) * box.size
		if not Geometry2D.is_point_in_polygon(p, poly) or _edge_dist(p, poly) < 6.0:
			continue
		var ln := 3.0 + _hash(k * 1.3) * 5.0
		draw_line(p, p + Vector2(ln, -ln * 0.18), GLINT_COL, 1.2, true)
		if _hash(k * 4.1) < 0.4:
			draw_line(p + Vector2(ln * 0.3, 2.5), p + Vector2(ln * 0.9, 2.2),
				Color(GLINT_COL, GLINT_COL.a * 0.6), 1.0, true)


func _duckweed(poly: PackedVector2Array) -> void:
	var ring := poly.duplicate()
	ring.append(poly[0])
	var salt := poly[0].x * 0.13 + poly[0].y * 0.07
	for i in ring.size() - 1:
		var a := ring[i]
		var b := ring[i + 1]
		var ln := a.distance_to(b)
		var d := 0.0
		while d < ln:
			var p := a.lerp(b, d / ln)
			d += DUCKWEED_STEP
			if _hash(p.x * 0.7 + p.y + salt) < 0.35:
				continue
			var inward := _inward(p, poly)
			var c := p + inward * (4.0 + _hash(p.y) * 9.0)
			for k in 4 + int(_hash(p.x) * 5.0):
				var q := c + Vector2(_hash(k * 3.3 + p.x) - 0.5, _hash(k * 1.9 + p.y) - 0.5) * 10.0
				if Geometry2D.is_point_in_polygon(q, poly):
					draw_circle(q, 1.1 + _hash(k + p.x) * 1.2,
						Color(DUCKWEED_COL, 0.75), true, -1.0, true)


func _inward(p: Vector2, poly: PackedVector2Array) -> Vector2:
	var c := Vector2.ZERO
	for v in poly:
		c += v
	c /= poly.size()
	return (c - p).normalized()


func _box(poly: PackedVector2Array) -> Rect2:
	var box := Rect2(poly[0], Vector2.ZERO)
	for p in poly:
		box = box.expand(p)
	return box


func _edge_dist(p: Vector2, poly: PackedVector2Array) -> float:
	return PgArtSprites._edge_dist(p, poly)


func _ring(poly: PackedVector2Array, color: Color, width: float) -> void:
	var rim := poly.duplicate()
	rim.append(poly[0])
	draw_polyline(rim, color, width, true)


func _blob(p: Vector2, r: float, color: Color) -> void:
	var pts := PackedVector2Array()
	for k in 8:
		var ang := TAU * k / 8.0
		pts.append(p + Vector2(cos(ang), sin(ang) * 0.6) * r * (0.8 + _hash(p.x + k) * 0.4))
	draw_colored_polygon(pts, color)


func _has_bridge_sprite() -> bool:
	for it: Dictionary in PgCatalog.items():
		if String(it.get("role", "")) == "bridge" and not String(it.get("tex", "")).is_empty():
			return true
	return false


func _bridge(poly: PackedVector2Array) -> void:
	if poly.size() < 3:
		return
	draw_colored_polygon(poly, WOOD.darkened(0.35))
	_ring(poly, BONE, 1.0)


# ── Тени ─────────────────────────────────────────────────────────────────────

## Тень формы: сдвиг вправо-вниз, три слоя с растущим отступом — мягкий край (§9 п.1).
func _soft_shadow(poly: PackedVector2Array, mult := 1.0) -> void:
	if poly.size() < 3:
		return
	var shifted := PackedVector2Array()
	for p in poly:
		shifted.append(p + SHADOW_DIR)
	for pass_def: Array in SHADOW_SOFT:
		var grow := float(pass_def[0])
		var a := float(pass_def[1]) * mult
		var shapes: Array = [shifted] if grow <= 0.0 else Geometry2D.offset_polygon(shifted, grow)
		for s: PackedVector2Array in shapes:
			draw_colored_polygon(s, Color(SHADOW_COLOR, a))


func _contact(p: Vector2, half_w: float) -> void:
	var pts := PackedVector2Array()
	for k in 12:
		var ang := TAU * k / 12.0
		pts.append(p + Vector2(cos(ang) * half_w, sin(ang) * half_w * CONTACT_FLAT))
	draw_colored_polygon(pts, Color(SHADOW_COLOR, CONTACT_ALPHA))


## Тень спрайта предмета: по «следу» (препятствие) или «основанию» (декор) из каталога.
func _prop_shadow(prop: Dictionary) -> void:
	var item := PgCatalog.by_id(String(prop.get("item", "")))
	var role := String(item.get("role", ""))
	if role == "bridge" or String(item.get("tex", "")).is_empty():
		return
	var poly := _item_poly(item, prop, "foot")
	if poly.size() < 3:
		poly = _item_poly(item, prop, "base")
	var p := Vector2(float(prop.pos[0]), float(prop.pos[1]))
	if poly.size() >= 3:
		_soft_shadow(poly, 0.8 if role == "obstacle" else 0.55)
		var box := _box(poly)
		_contact(Vector2(box.get_center().x, box.end.y - box.size.y * 0.25), box.size.x * 0.46)
	else:
		_contact(p, float(item.get("w", 30.0)) * 0.4)


func _item_poly(item: Dictionary, prop: Dictionary, key: String) -> PackedVector2Array:
	var pos := Vector2(float(prop.pos[0]), float(prop.pos[1]))
	var flip := bool(prop.get("flip", false))
	if key == "foot":
		return PgCatalog.foot_at(item, pos, flip)
	var out := PackedVector2Array()
	for raw: Array in item.get(key, []):
		var v := Vector2(float(raw[0]), float(raw[1]))
		if flip:
			v.x = -v.x
		out.append(pos + v)
	return out


func _wall_shadow(entry: Dictionary) -> void:
	var path := _points(entry.get("path", []))
	if path.size() < 2:
		return
	var w: float = float(entry.get("w", 24.0))
	var shifted := PackedVector2Array()
	for p in path:
		shifted.append(p + SHADOW_DIR)
	for pass_def: Array in SHADOW_SOFT:
		draw_polyline(shifted, Color(SHADOW_COLOR, float(pass_def[1])),
			w + float(pass_def[0]) * 2.0, true)


func _wall_tex_missing(entry: Dictionary) -> bool:
	var item := PgCatalog.by_id(String(entry.get("item", "")))
	if item.is_empty() or String(item.get("role", "")) != "wall":
		item = PgCatalog.wall(String(entry.get("kind", "stone")), _biome)
	var tex := String(item.get("tex", ""))
	return tex.is_empty() or not ResourceLoader.exists(tex, "Texture2D")


## Звено стены без картинки (страховка) — полоса кодом с тёмным контуром и светлой гранью.
func _wall(entry: Dictionary) -> void:
	var path := _points(entry.get("path", []))
	if path.size() < 2:
		return
	var w: float = float(entry.get("w", 24.0))
	var base: Color = WALL_COLORS.get(String(entry.get("kind", "stone")), WALL_COLORS["stone"])
	draw_polyline(path, base.darkened(0.5), w + ROCK_OUTLINE_W * 2.0, true)
	draw_polyline(path, base, w, true)
	var light_off := ROCK_LIGHT_DIR.normalized() * (w * 0.16)
	var hi := PackedVector2Array()
	for p in path:
		hi.append(p + light_off)
	draw_polyline(hi, base.lightened(0.24), w * 0.32, true)


# ── Препятствия-заглушки и декор ─────────────────────────────────────────────

## Силуэт препятствия без спрайта (след в rocks, картинки нет): грань по освещённости нормали,
## светлая крышка, тёплый блик, тёмный контур.
func _rock(poly: PackedVector2Array) -> void:
	if poly.size() < 3:
		return
	var center := Vector2.ZERO
	for p in poly:
		center += p
	center /= poly.size()
	var cap := PackedVector2Array()
	for p in poly:
		cap.append(center + (p - center) * ROCK_CAP_INSET)
	var light_dir := ROCK_LIGHT_DIR.normalized()
	var best_i := 0
	var best_score := -INF
	for i in poly.size():
		var next := (i + 1) % poly.size()
		var normal := (poly[next] - poly[i]).orthogonal().normalized()
		if normal.dot(poly[i] - center) < 0.0:
			normal = -normal
		var score := normal.dot(-light_dir)
		if score > best_score:
			best_score = score
			best_i = i
		var light := clampf(score * 0.5 + 0.5, 0.0, 1.0)
		var face := PackedVector2Array([poly[i], poly[next], cap[next], cap[i]])
		draw_colored_polygon(face, ROCK_FACE_DARK.lerp(ROCK_FACE_LIGHT, light))
	draw_colored_polygon(cap, ROCK_CAP)
	_ring(cap, ROCK_CAP.lightened(0.14), HAIR)
	var hi_next := (best_i + 1) % poly.size()
	draw_line(poly[best_i].lerp(cap[best_i], 0.5), poly[hi_next].lerp(cap[hi_next], 0.5),
		Color(ROCK_RIM_WARM, 0.55), 1.6, true)
	_ring(poly, ROCK_OUTLINE, ROCK_OUTLINE_W)


## «Клей» у подножия (§8.3, §6.6): камешки и пучки травы по нижней половине контура основания
## (передняя сторона в ракурсе 3/4), позиции — хэш от геометрии, RNG мира не тратится. Не на
## полотне дороги, не у участков и Котла.
func _glue(poly: PackedVector2Array, salt: int) -> void:
	if poly.size() < 3 or _avoid == null:
		return
	var box := _box(poly)
	var center := box.get_center()
	var n := GLUE_MIN + int(_hash(center.x + center.y + salt) * float(GLUE_MAX - GLUE_MIN + 1))
	var stone: Color = GLUE_STONE.get(_biome, GLUE_STONE["grave"])
	var grass: Color = GLUE_GRASS.get(_biome, Color(0, 0, 0, 0))
	for k in n:
		var t := _hash(center.x * 1.7 + center.y * 0.3 + k * 3.1 + salt)
		var idx := int(t * poly.size()) % poly.size()
		var e := poly[idx].lerp(poly[(idx + 1) % poly.size()], _hash(k + salt * 0.7))
		if e.y < center.y - box.size.y * 0.1:
			continue
		var p := center + (e - center) * GLUE_REACH
		if not _avoid.clear(p, 4.0):
			continue
		if grass.a > 0.0 and _hash(p.x * 0.9 + k) < 0.5:
			_tuft(p, grass, k)
		else:
			_pebble(p, stone, k)


func _pebble(p: Vector2, col: Color, k: int) -> void:
	var r := lerpf(PEBBLE_R.x, PEBBLE_R.y, _hash(p.x + p.y * 1.3 + k))
	var pts := PackedVector2Array()
	for i in 8:
		var ang := TAU * i / 8.0
		pts.append(p + Vector2(cos(ang) * r * 1.25, sin(ang) * r * 0.8))
	draw_colored_polygon(pts, col.darkened(0.1))
	_ring(pts, GLUE_INK, 0.9)
	draw_circle(p + Vector2(-r * 0.35, -r * 0.3), r * 0.35, Color(col.lightened(0.3), 0.8))


func _tuft(p: Vector2, col: Color, k: int) -> void:
	var ln := lerpf(TUFT_LEN.x, TUFT_LEN.y, _hash(p.y + k * 1.7))
	for i in 4:
		var ang := -PI * 0.5 + (float(i) - 1.5) * 0.35 + (_hash(p.x + i) - 0.5) * 0.2
		var tip := p + Vector2(cos(ang), sin(ang)) * ln * (0.7 + 0.3 * _hash(i + p.y))
		draw_line(p, tip, col.darkened(0.25) if i % 2 == 0 else col, 1.3, true)


## Предмет каталога без картинки — простая форма по role (страховка на пустой tex).
func _prop_fallback(prop: Dictionary) -> void:
	var item := PgCatalog.by_id(String(prop.get("item", "")))
	var role := String(item.get("role", "decor"))
	if role == "obstacle" or role == "bridge":
		return
	var tex_path := String(item.get("tex", ""))
	if not tex_path.is_empty() and ResourceLoader.exists(tex_path, "Texture2D"):
		return
	var p := Vector2(float(prop.pos[0]), float(prop.pos[1]))
	if role == "light":
		draw_circle(p, GLOW_RADIUS * 0.3, Color(WARM, GLOW_RING_ALPHA * 4.0))
	else:
		_contact(p, PROP_FALLBACK_W * 0.3)
		draw_circle(p, PROP_FALLBACK_W * 0.22, ROCK_FACE_LIGHT.darkened(0.2))


## Ровно та же палитра декора кода, что у TerrainView._decor — единая манера карты.
func _decor(p: Vector2, kind: String) -> void:
	match kind:
		"tree":
			draw_line(p, p + Vector2(0, -34), ROCK_FACE_DARK, 3.0, true)
			draw_circle(p + Vector2(0, -40), 16.0, ROCK_FACE_DARK.lightened(0.1))
		"candle":
			draw_line(p, p + Vector2(0, -9), BONE, 2.0)
			draw_circle(p + Vector2(0, -9), 2.6, WARM)
		_:
			draw_rect(Rect2(p + Vector2(-8, -19), Vector2(16, 19)), ROCK_FACE_LIGHT)


# ── Свет (§9 п.3): пятна ТОЛЬКО у источников + общий свет (только без фото-подложки) ──────

func _light_glows() -> void:
	for item: Dictionary in _map.get("decor", []):
		# У процгена decor — запасное представление тех же props. Их свет уже
		# присутствует в ambient.glows; два прохода давали лишний ореол свечи.
		if not (_map.get("props", []) as Array).is_empty():
			break
		if String(item.get("kind", "")) != "candle":
			continue
		_glow_at(Vector2(item.pos[0], item.pos[1]), GLOW_RADIUS)
	for glow: Dictionary in (_map.get("ambient", {}) as Dictionary).get("glows", []):
		var pos: Array = glow.get("pos", [0, 0])
		_glow_at(Vector2(float(pos[0]), float(pos[1])), float(glow.get("r", GLOW_RADIUS)))


func _glow_at(p: Vector2, r: float) -> void:
	for step in range(SOFT_STEPS, 0, -1):
		draw_circle(p, r * float(step) / SOFT_STEPS, Color(GLOW_COLOR, GLOW_RING_ALPHA))


func _light_wash() -> void:
	if used_ground_texture:
		return
	var span := _world.length()
	var warm: Array[Vector2] = [Vector2(_world.x * 0.16, _world.y * 0.14)]
	var cool := Vector2(_world.x * 0.88, _world.y * 0.9)
	if _mirror_w > 0.0:
		# поле PvP: тёплый свет над обеими сторонами, холод — по середине низа (симметрично)
		span = Vector2(_mirror_w * 0.5, _world.y).length()
		warm = [Vector2(_world.x * 0.12, _world.y * 0.14), Vector2(_world.x * 0.88, _world.y * 0.14)]
		cool = Vector2(_world.x * 0.5, _world.y * 0.9)
	for step in range(SOFT_STEPS, 0, -1):
		var f := float(step) / SOFT_STEPS
		for warm_c in warm:
			draw_circle(warm_c, span * 0.55 * f, Color(WASH_WARM, WASH_RING_ALPHA * f))
		draw_circle(cool, span * 0.45 * f, Color(WASH_COOL, WASH_RING_ALPHA * 0.8 * f))
