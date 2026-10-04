class_name PgArtRoad
extends RefCounted
## Дорога сборки процедурной карты «как нарисовано» (линия art3, 27.09.2026; BOOK §8.2 п.2,
## §8.3, §9 п.1, п.5). Было: плоская бежевая полоса с пунктирным краем. Стало: лента-меш
## вдоль оси дороги с настоящей нарисованной фактурой (вырезка прямых участков фонов кампании,
## tools/procgen_road_tiles.py → assets/legion/procgen/road/road_<биом>.png), UV вдоль пути,
## скруглённые повороты, неровный край шумом (pg_road.gdshader), мягкое затемнение земли у края.
##
## Почему меш-узлы (MeshInstance2D), а не draw_* в _draw(): текстурные immediate-draw внутри
## вложенного SubViewport PgArt давали белый кадр (докстринг PgArt._run) — узловой путь
## устойчив. Почему своя лента, а не Line2D: нужна непрерывная координата длины в UV (фактура
## не рвётся на поворотах) и альфа концов цветом вершин.
##
## Всё в мировых px (1280×720): PgArt масштабирует родителя ×1,5.

const ROAD_JSON := "res://assets/legion/procgen/road/road.json"
const ROAD_SHADER := "res://scripts/legion/procgen/pg_road.gdshader"
const TEX_SCALE := 1.5 ## px текстуры на px мира — тайлы вырезаны из фонов 1920×1080
## Биом без своей вырезки → ближайший по фактуре (зима — кладбищенская кайма, котельная —
## стройка, ад — пустырь); кампанийная карта в `--dev pgart=1` приходит с темой, не биомом.
const BIOME_FALLBACK := {"winter": "grave", "boiler": "site", "hell": "ash"}
const DEFAULT_BIOME := "grave"

## Скругление поворота: радиус больше полуширины ленты (≈27), иначе внутренний край
## выворачивается; на коротких коленах срезается до доли отрезка.
const CORNER_R := 40.0
const CORNER_MAX_FRAC := 0.45
const CORNER_STEPS := 10
## Шаг вершин ленты вдоль оси (мира px): держит альфу концов и изгиб каймы на своих местах.
const MAX_STEP := 8.0
## Конец у Котла тает в землю на этой длине (у ворот дорога уходит за край кадра).
const END_FADE := 30.0
const END_EXTEND := 8.0
## Кайма ответвления начинается на этой доле ширины от оси общей дороги (≈ её край).
const JOIN_CUT := 0.22
## Доля ширины, на которой кайма и полотно ответвления проявляются из общей дороги.
const JOIN_FADE := 0.12
## Продление ответвления сквозь колено другой дороги (доля ширины).
const THROUGH := 1.0
## Мягкое затемнение земли у края (§8.3): полоса снаружи ленты, прозрачная к внешнему краю.
const SHADE_W := 14.0
const SHADE_ALPHA := 0.26
## Тень начинается под полотном: сквозь выщербины «съеденного» края (pg_road.gdshader) видна
## притенённая земля, а не голая подложка (road-1003).
const SHADE_INNER := 0.7
const SHADE_OFFSET := Vector2(1.5, 2.5) ## свет сверху слева — тень гуще справа-снизу
const SHADE_COLOR := Color(0.05, 0.04, 0.06)
## Светлота полотна относительно ЛОКАЛЬНОЙ земли подложки (road-1003, слово Игоря 03.10: «дорога
## прямо выделяется»). Было: цель ×2,0 к средней земле всего кадра, пол L 0,62 — на тёмных
## grave/office/swamp дорога выходила ×1,9–2,6 и светилась кремовой лентой. Стало: нижний край
## коридора BOOK §8.2 п.2 (×1,4–2,5; фоны кампании §8.1 — ×1,41–2,46), цель ×1,6 к земле под
## самой дорогой (шейдер, кольцо выборок подложки), пол L 0,48 — дорога по-прежнему светлее земли
## заметно (читается путь врага), но в краске своей земли.
const TARGET_RATIO := 1.6
## Светлые биомы (пустырь, стройка) не жаловались, и там дорога и так у нижнего края коридора
## (фоны: Пустырь ×1,41, Прораб ×1,48): цель выше, чтобы кадр не потерял читаемость пути.
## Болото — главная жалоба 03.10 (кремовая лента поверх серо-оливковой земли): цель ниже.
const BIOME_RATIO := {"ash": 1.8, "hell": 1.8, "site": 1.7, "boiler": 1.7, "swamp": 1.42}
const RATIO_MIN := 1.4
const RATIO_MAX := 2.1
const ROAD_L_MIN := 0.48
## Потолок светлоты полотна ДО обработки: виньетка, тон и Кувахара (pg_post) снимают ≈ 8 %, в
## кадре выходит ≈ 0,83 — потолок замера фонов §8.1 (Болото 0,84); выше — лента выгорает.
const ROAD_L_MAX := 0.9
const BRIGHT_MIN := 0.55
const BRIGHT_MAX := 1.18
## Доля оттенка локальной земли в полотне (0 — чистый крем вырезки, 1 — краска земли).
const CAST_K := 0.45

static var _meta_cache: Dictionary = {}


## Строит под parent затемнение земли у края и полотно всех дорог карты. Возвращает число
## лент полотна (для теста и отчёта). land_luma — средняя светлота земли подложки; ground_tex —
## сама подложка (Sprite2D «Ground» PgArt.compose): по ней шейдер берёт светлоту и оттенок земли
## под дорогой. Без подложки (запасная заливка) — прежняя подгонка по средней светлоте.
static func build(parent: Node2D, map: Dictionary, land_luma: float,
		ground_tex: Texture2D = null) -> int:
	var meta := road_meta(map)
	if meta.is_empty():
		return 0
	var tex := load(String(meta["tex"])) as Texture2D
	if tex == null:
		return 0
	var width := float(meta["height_px"]) / TEX_SCALE
	var ground := ground_params(map, ground_tex)
	var ratio := target_ratio(map)
	meta = meta.duplicate()
	meta["ratio"] = ratio
	var paths := unique_paths(map)
	var shade := Node2D.new()
	shade.name = "RoadShade"
	shade.position = SHADE_OFFSET
	parent.add_child(shade)
	var body := Node2D.new()
	body.name = "RoadBody"
	parent.add_child(body)
	var core := Node2D.new()
	core.name = "RoadCore"
	parent.add_child(core)
	var bright := brightness(float(meta.get("luma", 0.75)), land_luma, ratio)
	var n := 0
	var mw := LegionTerrain.mirror_width(map)
	var built: Array[PackedVector2Array] = []
	var phases: Array[float] = []
	for entry: Dictionary in paths:
		var line := rounded(entry["path"])
		if line.size() < 2:
			continue
		var fade_end: bool = entry["fade_end"]
		if fade_end:
			line = _extend_end(line, END_EXTEND)
		# Устье, где ответвление продолжает прямо отрезок другой дороги (та поворачивает в этой
		# точке — «Т» на колене, кадр gen:10:3): ответвление продлевается сквозь точку на ширину.
		# Тогда его кайма идёт сплошной линией мимо устья, как на рисованных фонах, а не
		# обрывается размывом (B-171).
		if entry["through_start"]:
			line = _reversed(_extend_end(_reversed(line), width * THROUGH))
		if entry["through_end"]:
			line = _extend_end(line, width * THROUGH)
		# альфа концов — цветом вершин: на длинном прямом отрезке без промежуточных вершин
		# проявление растянулось бы на весь отрезок (кадр gen:10:3 — полупрозрачная ветка)
		line = densify(line, MAX_STEP)
		# «Т» посреди прямой другой дороги: кайма ответвления начинается у края общей дороги, а
		# не на её оси (иначе торчит поперёк полотна «ножкой», кадр gen:12:5); полотно (core)
		# идёт до оси — оно стирает кайму общей дороги в устье.
		var js: bool = entry["joined_start"] and not entry["through_start"]
		var je: bool = entry["joined_end"] and not entry["through_end"]
		var cut := width * JOIN_CUT
		var edge_line := _trim(line, cut if js else 0.0, cut if je else 0.0)
		var ramp := width * JOIN_FADE
		var body_fade := Vector2(END_FADE if entry["through_start"] else (ramp if js else 0.0),
			END_FADE if fade_end or entry["through_end"] else (ramp if je else 0.0))
		var ph := float(n) * 3.7
		# поле PvP (P5b): дорога стороны 1 — зеркало дороги стороны 0; тот же рисунок шума и
		# фактура отражённой, иначе на стыке, где обе начинаются, фактура рвётся швом
		var twin := _mirror_twin(entry["path"], built, mw)
		if twin >= 0:
			ph = phases[twin]
		if edge_line.size() >= 2:
			var u0 := cut if js else 0.0
			shade.add_child(_shade_mesh(edge_line, width * 0.5, body_fade))
			body.add_child(_road_mesh(edge_line, width, meta, tex, bright, false, body_fade, u0, ph,
				twin >= 0, ground))
		core.add_child(_road_mesh(line, width, meta, tex, bright, true, body_fade, 0.0, ph,
			twin >= 0, ground))
		built.append(entry["path"])
		phases.append(ph)
		n += 1
	return n


## Видимая полуширина ленты (мира px): край в шейдере съеден шумом в среднем на ≈ 7 %
## полуширины (edge_amp 0,14 × среднее шума 0,5). 0 — у биома нет вырезки.
static func visible_half(map: Dictionary) -> float:
	var meta := road_meta(map)
	if meta.is_empty():
		return 0.0
	return float(meta["height_px"]) / TEX_SCALE * 0.5 * 0.93


## Отображение мира в UV подложки — то же, что у спрайтов «Ground» в PgArt.compose: одиночка —
## подложка растянута на кадр; поле PvP — вырезка подложки во всю высоту на половину стороны 0
## и её зеркало на стороне 1 (PgArt._mirrored_ground). {} — подложки нет.
static func ground_params(map: Dictionary, ground_tex: Texture2D) -> Dictionary:
	if ground_tex == null:
		return {}
	var src := Vector2(ground_tex.get_size())
	if src.x < 1.0 or src.y < 1.0:
		return {}
	var mw := LegionTerrain.mirror_width(map)
	if mw > 0.0:
		var half := Vector2(LegionTerrain.map_size(map).x * 0.5, LegionTerrain.map_size(map).y)
		var crop := Vector2(minf(src.x, src.y * half.x / half.y), 0.0)
		crop.y = crop.x * half.y / half.x
		var k := crop.x / half.x
		return {"tex": ground_tex, "scale": Vector2(k, k) / src,
			"off": Vector2(0.0, (src.y - crop.y) * 0.5) / src, "mirror": mw}
	var view := PgArt.TEX_SIZE / PgArt.TEX_SCALE
	return {"tex": ground_tex, "scale": Vector2.ONE / view, "off": Vector2.ZERO, "mirror": 0.0}


## Индекс уже построенной дороги, зеркалом которой (x' = mirror_w − x) является path; −1 — нет
## (одиночка: mirror_w = 0 — всегда −1).
static func _mirror_twin(path: PackedVector2Array, built: Array[PackedVector2Array],
		mirror_w: float) -> int:
	if mirror_w <= 0.0:
		return -1
	for i in built.size():
		var other := built[i]
		if other.size() != path.size():
			continue
		var same := true
		for k in path.size():
			if absf(other[k].x - (mirror_w - path[k].x)) > 0.5 \
					or absf(other[k].y - path[k].y) > 0.5:
				same = false
				break
		if same:
			return i
	return -1


## Вырезка дороги для биома карты: {tex, height_px, period_px, luma} из road.json.
static func road_meta(map: Dictionary) -> Dictionary:
	if _meta_cache.is_empty():
		if not FileAccess.file_exists(ROAD_JSON):
			return {}
		var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(ROAD_JSON))
		if not data is Dictionary:
			return {}
		_meta_cache = data
	var biome := String(map.get("biome", map.get("theme", DEFAULT_BIOME)))
	biome = String(BIOME_FALLBACK.get(biome, biome))
	if not _meta_cache.has(biome):
		biome = DEFAULT_BIOME
	return _meta_cache.get(biome, {})


## Цель светлоты дороги к земле для биома карты (BIOME_RATIO, иначе TARGET_RATIO).
static func target_ratio(map: Dictionary) -> float:
	var biome := String(map.get("biome", map.get("theme", DEFAULT_BIOME)))
	return float(BIOME_RATIO.get(biome, TARGET_RATIO))


## Множитель светлоты полотна: цель ×ratio к земле, в коридоре [RATIO_MIN, RATIO_MAX]
## и абсолютном [ROAD_L_MIN, ROAD_L_MAX] (на тёмной подложке второй коридор уступает первому,
## иначе дорога «засветилась» бы). Та же формула — в pg_road.gdshader от локальной земли; здесь —
## запасной путь без подложки (средняя светлота земли) и замер для теста.
static func brightness(tex_luma: float, land_luma: float, ratio := TARGET_RATIO) -> float:
	var target := clampf(land_luma * ratio, ROAD_L_MIN, ROAD_L_MAX)
	target = clampf(target, land_luma * RATIO_MIN, land_luma * RATIO_MAX)
	return clampf(target / maxf(tex_luma, 0.01), BRIGHT_MIN, BRIGHT_MAX)


## Оси дорог без общих кусков: вторая дорога, идущая от тех же ворот или к тому же Котлу, что
## и первая, рисуется только от развилки/до слияния — иначе на общем участке две ленты с
## разной фазой фактуры просвечивали бы друг сквозь друга каймой.
## [{path, fade_end, joined_start, joined_end}] — fade_end: конец в поле (у Котла), а не общий;
## joined_*: конец лежит на другой дороге (развилка/слияние).
static func unique_paths(map: Dictionary) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var seen: Array[PackedVector2Array] = []
	for road: Dictionary in map.get("roads", []):
		var path := _points(road.get("path", []))
		if path.size() < 2:
			continue
		var head := 0
		var tail := 0
		for other in seen:
			head = maxi(head, _shared_prefix(path, other))
			tail = maxi(tail, _shared_suffix(path, other))
		seen.append(path)
		var a := maxi(head - 1, 0)
		var b := path.size() - maxi(tail - 1, 0)
		if b - a < 2:
			continue
		var cut := path.slice(a, b)
		var n := cut.size()
		out.append({"path": cut, "fade_end": tail < 2, "joined_start": head >= 2,
			"joined_end": tail >= 2,
			"through_start": head >= 2 and _continues(cut[0], cut[0] - cut[1], seen),
			"through_end": tail >= 2 and _continues(cut[n - 1], cut[n - 1] - cut[n - 2], seen)})
	return out


## В точке p у другой уже нарисованной дороги есть отрезок, идущий из p в направлении dir:
## ответвление, продлённое прямо, ляжет на него (устье на колене другой дороги).
static func _continues(p: Vector2, dir: Vector2, roads: Array[PackedVector2Array]) -> bool:
	var want := dir.normalized()
	for path in roads:
		for i in path.size():
			if not path[i].is_equal_approx(p):
				continue
			for j: int in [i - 1, i + 1]:
				if j >= 0 and j < path.size() and (path[j] - p).normalized().dot(want) > 0.98:
					return true
	return false


static func _shared_prefix(a: PackedVector2Array, b: PackedVector2Array) -> int:
	var k := 0
	while k < a.size() and k < b.size() and a[k].is_equal_approx(b[k]):
		k += 1
	return k


static func _shared_suffix(a: PackedVector2Array, b: PackedVector2Array) -> int:
	var k := 0
	while k < a.size() and k < b.size() \
			and a[a.size() - 1 - k].is_equal_approx(b[b.size() - 1 - k]):
		k += 1
	return k


static func _points(raw: Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p: Array in raw:
		var v := Vector2(float(p[0]), float(p[1]))
		if out.is_empty() or not out[out.size() - 1].is_equal_approx(v):
			out.append(v)
	return out


## Ломаная со скруглёнными поворотами: колено заменено квадратичной кривой Безье от точки
## входа до точки выхода (касательные по отрезкам) — как на фонах кампании, где дорога
## заворачивает дугой, а не углом.
static func rounded(path: PackedVector2Array) -> PackedVector2Array:
	if path.size() < 3:
		return path
	var out := PackedVector2Array([path[0]])
	for i in range(1, path.size() - 1):
		var p := path[i]
		var into := p - path[i - 1]
		var outof := path[i + 1] - p
		if into.length() < 0.01 or outof.length() < 0.01:
			continue
		var cut := minf(CORNER_R, CORNER_MAX_FRAC * minf(into.length(), outof.length()))
		var a := p - into.normalized() * cut
		var b := p + outof.normalized() * cut
		for s in CORNER_STEPS + 1:
			var t := float(s) / CORNER_STEPS
			out.append(a.lerp(p, t).lerp(p.lerp(b, t), t))
	out.append(path[path.size() - 1])
	return out


## Ломаная без первых from_start и последних from_end единиц длины.
static func _trim(line: PackedVector2Array, from_start: float,
		from_end: float) -> PackedVector2Array:
	var out := line
	if from_start > 0.0:
		out = _cut_head(out, from_start)
	if from_end > 0.0:
		out = _cut_head(_reversed(out), from_end)
		out = _reversed(out)
	return out


static func _cut_head(line: PackedVector2Array, by: float) -> PackedVector2Array:
	var left := by
	for i in line.size() - 1:
		var ln := line[i].distance_to(line[i + 1])
		if left < ln:
			var out := PackedVector2Array([line[i].lerp(line[i + 1], left / ln)])
			out.append_array(line.slice(i + 1))
			return out
		left -= ln
	return PackedVector2Array()


static func _reversed(line: PackedVector2Array) -> PackedVector2Array:
	var out := line.duplicate()
	out.reverse()
	return out


static func densify(line: PackedVector2Array, step: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in line.size() - 1:
		var a := line[i]
		var b := line[i + 1]
		var n := maxi(1, ceili(a.distance_to(b) / step))
		for k in n:
			out.append(a.lerp(b, float(k) / n))
	out.append(line[line.size() - 1])
	return out


static func _extend_end(line: PackedVector2Array, by: float) -> PackedVector2Array:
	var n := line.size()
	var dir := (line[n - 1] - line[n - 2]).normalized()
	var out := line.duplicate()
	out.append(line[n - 1] + dir * by)
	return out


## Нормали вершин ленты: средняя соседних отрезков, со срезом «митры» (на скруглённом пути
## изломы малые, срез нужен только на коротких коленах).
static func _normals(line: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	var n := line.size()
	for i in n:
		var d_in := (line[i] - line[maxi(i - 1, 0)]).normalized()
		var d_out := (line[mini(i + 1, n - 1)] - line[i]).normalized()
		if i == 0:
			d_in = d_out
		if i == n - 1:
			d_out = d_in
		var tangent := (d_in + d_out).normalized()
		if tangent.is_zero_approx():
			tangent = d_out
		var normal := tangent.orthogonal()
		var cos_half := maxf(normal.dot(d_out.orthogonal()), 0.5)
		out.append(normal / cos_half)
	return out


static func _lengths(line: PackedVector2Array) -> PackedFloat32Array:
	var out := PackedFloat32Array([0.0])
	for i in range(1, line.size()):
		out.append(out[i - 1] + line[i].distance_to(line[i - 1]))
	return out


## fade — длина проявления (x — от начала, y — к концу; 0 — без); u0 — сдвиг фазы фактуры,
## чтобы подрезанная кайма ответвления совпала по фазе со своим полотном; flip_v — поперёк
## наоборот (зеркальная дорога поля PvP: отражение переворачивает нормаль пути).
static func _road_mesh(line: PackedVector2Array, width: float, meta: Dictionary, tex: Texture2D,
		bright: float, core_only: bool, fade: Vector2, u0: float, ph: float,
		flip_v := false, ground: Dictionary = {}) -> MeshInstance2D:
	var period := float(meta["period_px"]) / TEX_SCALE
	var normals := _normals(line)
	var dist := _lengths(line)
	var total := dist[dist.size() - 1]
	var verts := PackedVector2Array()
	var uvs := PackedVector2Array()
	var cols := PackedColorArray()
	var half := width * 0.5
	for i in line.size():
		var u := (dist[i] + u0) / period
		var a := _fade_alpha(dist[i], total, fade)
		verts.append(line[i] + normals[i] * half)
		verts.append(line[i] - normals[i] * half)
		uvs.append(Vector2(u, 1.0 if flip_v else 0.0))
		uvs.append(Vector2(u, 0.0 if flip_v else 1.0))
		cols.append(Color(1, 1, 1, a))
		cols.append(Color(1, 1, 1, a))
	var mi := MeshInstance2D.new()
	mi.name = "RoadCore" if core_only else "Road"
	mi.mesh = _strip_mesh(verts, uvs, cols)
	mi.texture = tex
	mi.texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED
	mi.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	var mat := ShaderMaterial.new()
	mat.shader = load(ROAD_SHADER) as Shader
	mat.set_shader_parameter("brightness", bright)
	mat.set_shader_parameter("period_world", period)
	mat.set_shader_parameter("core_only", 1.0 if core_only else 0.0)
	mat.set_shader_parameter("phase", ph)
	mat.set_shader_parameter("width_world", width)
	mat.set_shader_parameter("tex_luma", float(meta.get("luma", 0.75)))
	mat.set_shader_parameter("ratio", float(meta.get("ratio", TARGET_RATIO)))
	mat.set_shader_parameter("ratio_min", RATIO_MIN)
	mat.set_shader_parameter("ratio_max", RATIO_MAX)
	mat.set_shader_parameter("l_min", ROAD_L_MIN)
	mat.set_shader_parameter("l_max", ROAD_L_MAX)
	mat.set_shader_parameter("bright_min", BRIGHT_MIN)
	mat.set_shader_parameter("bright_max", BRIGHT_MAX)
	mat.set_shader_parameter("cast_k", CAST_K)
	if not ground.is_empty():
		mat.set_shader_parameter("ground_tex", ground["tex"])
		mat.set_shader_parameter("use_ground", 1.0)
		mat.set_shader_parameter("g_scale", ground["scale"])
		mat.set_shader_parameter("g_off", ground["off"])
		mat.set_shader_parameter("g_mirror", ground["mirror"])
	var tex_b := String(meta.get("tex_b", ""))
	if not tex_b.is_empty() and ResourceLoader.exists(tex_b, "Texture2D"):
		mat.set_shader_parameter("tex_b", load(tex_b) as Texture2D)
		mat.set_shader_parameter("use_b", 1.0)
		mat.set_shader_parameter("period_b_world", float(meta["period_b_px"]) / TEX_SCALE)
	mi.material = mat
	return mi


static func _fade_alpha(d: float, total: float, fade: Vector2) -> float:
	var a := 1.0
	if fade.x > 0.0:
		a = minf(a, clampf(d / fade.x, 0.0, 1.0))
	if fade.y > 0.0:
		a = minf(a, clampf((total - d) / fade.y, 0.0, 1.0))
	return a


static func _shade_mesh(line: PackedVector2Array, half: float, fade: Vector2) -> MeshInstance2D:
	var normals := _normals(line)
	var dist := _lengths(line)
	var total := dist[dist.size() - 1]
	var verts := PackedVector2Array()
	var uvs := PackedVector2Array()
	var cols := PackedColorArray()
	var inner := half * SHADE_INNER
	var outer := half + SHADE_W
	for i in line.size():
		verts.append(line[i] + normals[i] * outer)
		verts.append(line[i] + normals[i] * inner)
		verts.append(line[i] - normals[i] * inner)
		verts.append(line[i] - normals[i] * outer)
		for v in 4:
			uvs.append(Vector2.ZERO)
		var a := SHADE_ALPHA * _fade_alpha(dist[i], total, fade)
		cols.append(Color(SHADE_COLOR, 0.0))
		cols.append(Color(SHADE_COLOR, a))
		cols.append(Color(SHADE_COLOR, a))
		cols.append(Color(SHADE_COLOR, 0.0))
	var idx := PackedInt32Array()
	for i in line.size() - 1:
		for c in 3:
			var a := i * 4 + c
			var b := (i + 1) * 4 + c
			idx.append_array([a, b, a + 1, a + 1, b, b + 1])
	var mi := MeshInstance2D.new()
	mi.name = "Shade"
	mi.mesh = _mesh(verts, uvs, cols, idx)
	return mi


static func _strip_mesh(verts: PackedVector2Array, uvs: PackedVector2Array,
		cols: PackedColorArray) -> ArrayMesh:
	var idx := PackedInt32Array()
	for i in verts.size() / 2 - 1:
		var a := i * 2
		idx.append_array([a, a + 2, a + 1, a + 1, a + 2, a + 3])
	return _mesh(verts, uvs, cols, idx)


static func _mesh(verts: PackedVector2Array, uvs: PackedVector2Array, cols: PackedColorArray,
		idx: PackedInt32Array) -> ArrayMesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_COLOR] = cols
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
