class_name PgArt
extends RefCounted
## Сборка картинки процедурной карты в текстуру 1920×1080 (мир ×1,5 — как у фонов кампании) и
## её «склеивание» (BOOK.md §9, D-0927-71: нейросеть у игрока — отказ, только алгоритмы).
##
## Рендер идёт через два SubViewport — это GPU-путь, недоступный в headless/dummy-рендере
## тестов и гейта; там ждать нечего и незачем рисковать зависанием на await кадра, поэтому
## build() в headless сразу возвращает null: PgArtCanvas.
##
## Тайминг: SubViewport отдаёт кадр не раньше следующего process_frame, значит build() не может
## быть синхронным. STAGE2.md допускает оба варианта интерфейса — здесь сигнал вместо прямого
## возврата текстуры:
##   var req := PgArt.build(map, host)
##   if req == null:
##       pass # headless — вызывающий сам рисует запасной фон
##   else:
##       req.ready.connect(_on_pgart_ready)   # texture может быть null при неудаче рендера
signal ready(texture: Texture2D)

const POST_SHADER := "res://scripts/legion/procgen/pg_post.gdshader"
const SEAM_SHADER := preload("res://scripts/legion/procgen/pg_ground_seam.gdshader")
const SEAM_FEATHER := 128.0
## Мир ×1,5 — то же соотношение, что у нарисованных фонов кампании (BOOK §8.1: «1920×1080,
## мир ×1,5»); раскладка (roads/rocks/...) остаётся в мировых 1280×720 без пересчёта.
const TEX_SCALE := 1.5
## Кадр одиночной карты; у поля «Схватки» картинка — весь мир карты ×1,5 (tex_size, P5b).
const TEX_SIZE := Vector2(1280.0, 720.0) * TEX_SCALE

## Тон, туман и виньетка биома для pg_post.gdshader — приближение к замерам BOOK §8.1 (полный
## gradient map — см. ограничение в отчёте линии terrain). Когда земля — настоящая подложка
## (фото уже несёт свой свет и виньетку, разбор координатора 27.09), оба эффекта смягчены
## VIGNETTE_TEX_SOFTEN/TINT_TEX_MULT, чтобы не удваивать то, что уже есть на подложке.
const BIOME_POST := {
	"grave": {"tint": Color(0.86, 0.84, 1.0), "vignette": 0.60, "fog": 0.0},
	"office": {"tint": Color(1.0, 0.9, 0.78), "vignette": 0.55, "fog": 0.0},
	"swamp": {"tint": Color(0.82, 0.94, 0.86), "vignette": 0.72, "fog": 0.18},
	"ash": {"tint": Color(1.0, 0.88, 0.8), "vignette": 0.68, "fog": 0.06},
	"site": {"tint": Color(0.98, 0.9, 0.8), "vignette": 0.55, "fog": 0.0},
}
## Туман болота 0,28 → 0,18 (линия art3): на паре с фоном «Болото» сборка выходила
## выцветшей молочной — у рисованного фона туман только по краям, середина насыщенная.
const DEFAULT_POST := {"tint": Color(1, 1, 1), "vignette": 0.57, "fog": 0.0}
const TINT_STRENGTH := 0.12
const TINT_TEX_MULT := 0.4 ## слабее тонировать поверх настоящей подложки
const VIGNETTE_TEX_SOFTEN := 0.4 ## доля исходной виньетки, когда земля уже фото (0..1)
## Значения по умолчанию из pg_post.gdshader (foot_r1/foot_r2/foot_bias) — доли ширины кадра.
const FOOT_R1 := 0.0055
const FOOT_R2 := 0.0115
const FOOT_BIAS := Vector2(-0.0015, -0.0025)

const MASK_SIZE := Vector2i(960, 540)
## Доля карты зон от мира (MASK_SIZE одиночки = 1280×720 × это).
const MASK_SCALE := 0.75
## Кадры ожидания: сборка+маска (вход в дерево, рендер, запас) и проход обработки.
const WAIT_BUILD := 4
const WAIT_POST := 3
var depth_entries: Array[Dictionary] = []


## Размер картинки земли карты: мир карты ×TEX_SCALE (одиночка — TEX_SIZE, поле PvP 2400×1350).
static func tex_size(map: Dictionary) -> Vector2:
	return LegionTerrain.map_size(map) * TEX_SCALE


## Размер карты зон (одиночка — MASK_SIZE).
static func mask_size(map: Dictionary) -> Vector2i:
	var world := LegionTerrain.map_size(map)
	if world == LegionCfg.WORLD_SIZE:
		return MASK_SIZE
	return Vector2i((world * MASK_SCALE).round())


static func build(map: Dictionary, host: Node, depth_split := false) -> PgArt:
	if DisplayServer.get_name() == "headless":
		return null
	var req := PgArt.new()
	req._run(map, host, depth_split)
	return req


func _run(map: Dictionary, host: Node, depth_split: bool) -> void:
	var t0 := Time.get_ticks_msec()
	var tree := host.get_tree()
	if tree == null:
		ready.emit(null)
		return
	# Подложку резолвим и грузим ЗДЕСЬ, не в PgArtCanvas: draw_texture_rect(любая текстура)
	# внутри вложенного SubViewport рендерился ПУСТЫМ БЕЛЫМ кадром (проверено замерами и кадрами
	# — solid-color draw_rect/draw_circle рисуются нормально, ломались именно текстурные
	# immediate-draw; узел Sprite2D — обычный путь отрисовки, устойчив). Земля — Sprite2D-сосед
	# PgArtCanvas, а не часть его _draw().
	var ground_path := PgArtCanvas.resolve_ground_path(map)
	var ground_tex: Texture2D = null
	var ground_luma := 0.0
	if not ground_path.is_empty() and ResourceLoader.exists(ground_path, "Texture2D"):
		var loaded := load(ground_path) as Texture2D
		if loaded != null:
			var raw_img := loaded.get_image()
			if raw_img != null and not raw_img.is_empty():
				ground_tex = loaded
				ground_luma = _sample_grid_luma(raw_img)
	var used_tex := ground_tex != null

	# Первый SubViewport — сборка (подложка + слои кода + дорога + спрайты), без обработки.
	var tex_px := tex_size(map)
	var vp_a := _viewport(host, Vector2i(tex_px))
	var art := Node2D.new()
	vp_a.add_child(art)
	var stats := compose(art, map, ground_tex, ground_luma, depth_split)
	depth_entries.assign(stats.get("depth_entries", []))
	# Карта зон (PgArtMask) — вдвое меньше кадра: её читают шейдер обработки и статистика.
	var mask_px := mask_size(map)
	var vp_m := _viewport(host, mask_px)
	var mask := PgArtMask.new()
	mask.scale = Vector2.ONE * (float(mask_px.x) / LegionTerrain.map_size(map).x)
	vp_m.add_child(mask)
	var meta := PgArtRoad.road_meta(map)
	mask.setup(map, float(meta.get("height_px", 69.0)) / TEX_SCALE)
	# Второй SubViewport — обработка: TextureRect с картинкой первого как ОБЫЧНОЙ текстурой
	# (TEXTURE/UV, не hint_screen_texture — во вложенном SubViewport тот давал выбеленный кадр).
	var vp_b := _viewport(host, Vector2i(tex_px))
	var post := TextureRect.new()
	post.texture = vp_a.get_texture()
	post.size = tex_px
	var mat := ShaderMaterial.new()
	mat.shader = load(POST_SHADER) as Shader
	_apply_post(mat, map, ground_tex != null)
	mat.set_shader_parameter("mask_tex", vp_m.get_texture())
	post.material = mat
	vp_b.add_child(post)
	# Сборка и маска: кадр на вход в дерево + кадр рендера (+ запас). Потом — статистика цвета
	# сборки по зонам и параметры переноса, и ещё кадры на проход обработки.
	for _i in WAIT_BUILD:
		await tree.process_frame
	if not is_instance_valid(host) or not is_instance_valid(vp_a) \
			or not is_instance_valid(vp_b) or not is_instance_valid(vp_m):
		ready.emit(null)
		return
	var raw := vp_a.get_texture().get_image()
	var mask_img := vp_m.get_texture().get_image()
	var biome := String(map.get("biome", map.get("theme", "grave")))
	var strength := Vector3.ZERO
	if raw != null and mask_img != null and not raw.is_empty() and not mask_img.is_empty():
		strength = PgArtGrade.apply(mat, PgArtGrade.zone_stats(raw, mask_img),
			PgArtGrade.biome_ref(biome))
	for _i in WAIT_POST:
		await tree.process_frame
	if not is_instance_valid(host) or not is_instance_valid(vp_b):
		ready.emit(null)
		return
	var img := vp_b.get_texture().get_image()
	vp_a.queue_free()
	vp_b.queue_free()
	vp_m.queue_free()
	if img == null or img.is_empty():
		ready.emit(null)
		return
	img = img.duplicate()
	if img.is_compressed():
		img.decompress()
	var tex := ImageTexture.create_from_image(img)
	stats["strength"] = strength
	_report(map, ground_tex, raw, img, mask_img, Time.get_ticks_msec() - t0, stats)
	ready.emit(tex)


func _viewport(host: Node, size: Vector2i) -> SubViewport:
	var vp := SubViewport.new()
	vp.size = size
	vp.transparent_bg = false
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	host.add_child(vp)
	return vp


## Стопка слоёв сборки под root (мировые px, root масштабирован ×TEX_SCALE) в порядке BOOK §8.3:
## подложка → почва (код) → дорога (меш-ленты) → вода/топь, тени (код) → предметы, стены,
## мосты, камыш (спрайты) → клей и свет (код). Отдельно от _run, чтобы тест мог собрать дерево
## узлов в headless (без рендера) и проверить, что стены взяли звенья каталога, а дорога —
## текстуру. Возвращает счётчики: roads, wall_links, wall_tex, props, bridges, reeds, lilies,
## papers и canvas (слой MID — у него замер светлоты земли).
static func compose(root: Node2D, map: Dictionary, ground_tex: Texture2D,
		ground_luma: float, depth_split := false) -> Dictionary:
	root.name = "PgArtStack"
	root.scale = Vector2.ONE * TEX_SCALE
	var used_tex := ground_tex != null
	if used_tex and LegionTerrain.mirror_width(map) > 0.0:
		_mirrored_ground(root, ground_tex, LegionTerrain.map_size(map))
	elif used_tex:
		var sprite := Sprite2D.new()
		sprite.name = "Ground"
		sprite.texture = ground_tex
		sprite.centered = false
		var src := ground_tex.get_size()
		sprite.scale = Vector2(TEX_SIZE.x / TEX_SCALE / maxf(src.x, 1.0),
			TEX_SIZE.y / TEX_SCALE / maxf(src.y, 1.0))
		root.add_child(sprite)
	var under := PgArtCanvas.new()
	under.setup(map, used_tex, ground_luma, PgArtCanvas.Layer.UNDER)
	root.add_child(under)
	var road := Node2D.new()
	road.name = "Roads"
	root.add_child(road)
	var mid := PgArtCanvas.new()
	mid.setup(map, used_tex, ground_luma, PgArtCanvas.Layer.MID)
	var roads := PgArtRoad.build(road, map, mid.last_land_luma, ground_tex)
	# трава и камешки на кромке дороги — над полотном, под водой и тенями (road-1003)
	var road_edge := Node2D.new()
	road_edge.name = "RoadEdge"
	root.add_child(road_edge)
	var edge_n := PgArtScatter.build_edge(road_edge, map, PgArtRoad.visible_half(map))
	# топь вне «Болота» — картинкой, а не плоской заливкой (gen-art-polish); под тенями и водой
	var marsh := Node2D.new()
	marsh.name = "Marsh"
	root.add_child(marsh)
	var marsh_n := PgArtMarsh.build(marsh, map, ground_tex)
	root.add_child(mid)
	var still_life := PgArtLife.new()
	still_life.name = "StillLife"
	still_life.setup(map, false)
	root.add_child(still_life)
	# россыпь и площадка под Котлом — плоские, под предметами (D-0927-210)
	var scatter := Node2D.new()
	scatter.name = "Scatter"
	root.add_child(scatter)
	var sc := PgArtScatter.build(scatter, map)
	# контактная тень земли под участками, склепами и Котлами (harmony-1003): над россыпью и
	# площадкой Котла, под предметами; без неё постройки стоят на карте «наклейками»
	var contact := Node2D.new()
	contact.name = "Contact"
	root.add_child(contact)
	var contact_n := PgArtHarmony.build_contact(contact, map, ground_tex)
	# крупные группы в пустотах — над россыпью, под предметами; строятся после всех спрайтов
	var fill := Node2D.new()
	fill.name = "Fill"
	root.add_child(fill)
	var things := Node2D.new()
	things.name = "Sprites"
	root.add_child(things)
	var stats := PgArtSprites.build(things, map, depth_split)
	stats.merge(sc)
	var split_pts := PackedVector2Array()
	for e: Dictionary in stats.get("depth_entries", []):
		split_pts.append(e["pos"] as Vector2)
	stats["fill"] = PgArtFill.build(fill, map, [road_edge, scatter, things, still_life, marsh],
		split_pts)
	var top := PgArtCanvas.new()
	top.setup(map, used_tex, ground_luma, PgArtCanvas.Layer.TOP)
	root.add_child(top)
	for c: PgArtCanvas in [under, mid, top]:
		c.queue_redraw()
	stats["roads"] = roads
	stats["contact"] = contact_n
	stats["road_edge"] = edge_n
	stats["marsh"] = marsh_n
	stats["canvas"] = mid
	return stats


## Подложка поля «Схватки» (P5b): кадр подложки 16:9 растянуть на поле нельзя — у половины
## другие пропорции. Половина стороны 0 — вырезка подложки от левого края во всю высоту (без
## искажения), половина стороны 1 — та же вырезка зеркально. На стыке встречаются одинаковые
## столбцы — шва нет; края поля — края подложки с её виньеткой, середина — её светлая часть.
static func _mirrored_ground(root: Node2D, tex: Texture2D, world: Vector2) -> void:
	var half := Vector2(world.x * 0.5, world.y)
	var src := tex.get_size()
	var crop := Vector2(minf(src.x, src.y * half.x / half.y), 0.0)
	crop.y = crop.x * half.y / half.x
	var region := Rect2(Vector2(0.0, (src.y - crop.y) * 0.5), crop)
	for side in 2:
		var sprite := Sprite2D.new()
		sprite.name = "Ground" if side == 0 else "GroundMirror"
		sprite.texture = tex
		sprite.centered = false
		sprite.region_enabled = true
		sprite.region_rect = region
		sprite.flip_h = side == 1
		sprite.scale = Vector2.ONE * (half.x / maxf(crop.x, 1.0))
		sprite.position = Vector2(half.x * side, 0.0)
		root.add_child(sprite)
	# На оси одинаковые мазки сходились «пятном Роршаха». Узкая растушёванная
	# полоса продолжает исходный рисунок через стык, под всеми игровыми объектами.
	var band := Polygon2D.new()
	band.name = "GroundSeam"
	band.polygon = PackedVector2Array([Vector2(half.x - SEAM_FEATHER, 0),
		Vector2(half.x + SEAM_FEATHER, 0), Vector2(half.x + SEAM_FEATHER, world.y),
		Vector2(half.x - SEAM_FEATHER, world.y)])
	var mat := ShaderMaterial.new()
	mat.shader = SEAM_SHADER
	mat.set_shader_parameter("ground_tex", tex)
	mat.set_shader_parameter("uv_scale", Vector2.ONE * (crop.x / half.x) / src)
	mat.set_shader_parameter("uv_offset", region.position / src)
	mat.set_shader_parameter("middle", half.x)
	mat.set_shader_parameter("feather", SEAM_FEATHER)
	band.material = mat
	root.add_child(band)


func _apply_post(mat: ShaderMaterial, map: Dictionary, used_tex: bool) -> void:
	var biome := String(map.get("biome", map.get("theme", "ash")))
	var p: Dictionary = BIOME_POST.get(biome, DEFAULT_POST)
	var vignette: float = p.vignette
	var tint_strength := TINT_STRENGTH
	if used_tex:
		# подложка уже несёт свой свет и виньетку (координатор 27.09) — не удваивать
		vignette = lerpf(1.0, vignette, VIGNETTE_TEX_SOFTEN)
		tint_strength *= TINT_TEX_MULT
	mat.set_shader_parameter("biome_tint", Vector3(p.tint.r, p.tint.g, p.tint.b))
	mat.set_shader_parameter("vignette_edge", vignette)
	mat.set_shader_parameter("tint_strength", tint_strength)
	mat.set_shader_parameter("fog_strength", p.fog)
	mat.set_shader_parameter("fog_color", Vector3(0.75, 0.78, 0.85))
	mat.set_shader_parameter("preserve_ground_light", 1.0 if used_tex else 0.0)
	# радиусы затемнения у подножий — доли ширины кадра: на поле шире кадра одиночки их
	# уменьшаем, чтобы в пикселях мира тень осталась прежней (одиночка — значения шейдера)
	var k := LegionCfg.WORLD_SIZE.x / LegionTerrain.map_size(map).x
	if not is_equal_approx(k, 1.0):
		mat.set_shader_parameter("foot_r1", FOOT_R1 * k)
		mat.set_shader_parameter("foot_r2", FOOT_R2 * k)
		mat.set_shader_parameter("foot_bias", FOOT_BIAS * k)


## Числа для приёмки (правило координатора 27.09): земля не должна уйти от исходной подложки
## больше чем на ±10 %, дорога должна остаться самым светлым — печатаются в консоль при
## каждой сборке карты, чтобы регрессия была видна в любом прогоне (--bench, --shot, бой).
## Земля меряется по зоне «земля» карты зон (без дороги, предметов, воды), подложка — по той же
## зоне (раньше — решёткой по всему кадру: заводи и дорога попадали в «землю», B-172).
func _report(map: Dictionary, ground_tex: Texture2D, raw: Image, img: Image, mask: Image,
		elapsed_ms: int, stats: Dictionary) -> void:
	var land_before := -1.0
	# поле PvP: подложка лежит вырезкой и зеркалом (_mirrored_ground) — кадр подложки с картой
	# зон поля не совпадает, земля «до» меряется по сборке (raw)
	if ground_tex != null and mask != null and LegionTerrain.mirror_width(map) <= 0.0:
		land_before = PgArtGrade.zone_luma(ground_tex.get_image(), mask, 0)
	elif raw != null and mask != null:
		land_before = PgArtGrade.zone_luma(raw, mask, 0)
	var land_after := PgArtGrade.zone_luma(img, mask, 0) if mask != null else _sample_grid_luma(img)
	var road_after := PgArtGrade.zone_luma(img, mask, 1) if mask != null else -1.0
	var delta_pct := 0.0
	if land_before > 0.001:
		delta_pct = (land_after - land_before) / land_before * 100.0
	var road_txt := "нет дороги на карте"
	if road_after >= 0.0:
		road_txt = "дорога %.3f (×%.2f от земли)" % [road_after, road_after / maxf(land_after, 0.001)]
	var st: Vector3 = stats.get("strength", Vector3.ZERO)
	print(("PgArt: сборка %s — %d мс · земля подложка %.3f / после %.3f (Δ %+.1f%%) · %s · "
		+ "перенос %.1f/%.1f/%.1f · лент %d, звеньев %d, предметов %d, мостов %d, камыш %d, "
		+ "кувшинки %d, бумаги %d, россыпь %d, кромка %d, площадка %d") %
		[String(map.get("id", "?")), elapsed_ms, land_before, land_after, delta_pct, road_txt,
		st.x, st.y, st.z,
		int(stats.get("roads", 0)), int(stats.get("wall_links", 0)), int(stats.get("props", 0)),
		int(stats.get("bridges", 0)), int(stats.get("reeds", 0)), int(stats.get("lilies", 0)),
		int(stats.get("papers", 0)), int(stats.get("scatter", 0)),
		int(stats.get("road_edge", 0)), int(stats.get("cauldron_base", 0))])


## Грубая решётка по всей картинке — средняя светлота земли ПОСЛЕ всех слоёв и пост-шейдера.
static func _sample_grid_luma(img: Image) -> float:
	var w := img.get_width()
	var h := img.get_height()
	if w <= 0 or h <= 0:
		return 0.0
	var sum := 0.0
	var n := 0
	var step_x := maxi(1, w / 40)
	var step_y := maxi(1, h / 24)
	var y := 0
	while y < h:
		var x := 0
		while x < w:
			sum += img.get_pixel(x, y).get_luminance()
			n += 1
			x += step_x
		y += step_y
	return sum / maxf(float(n), 1.0)
