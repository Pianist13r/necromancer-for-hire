class_name PgArtSprites
extends RefCounted
## Предметы сборки процедурной карты спрайтами библиотеки (линия art3, 27.09.2026; BOOK §8.3,
## §6.6): препятствия и декор каталога, стены/ограды/стеллажи звеньями по ломаной, мосты, «клей»
## по правилам соседства — камыш по кромке воды и топи, кувшинки на воде, бумаги у стеллажей.
##
## Было: стены рисовались кодом узкими полосами, препятствия — кодовыми многогранниками поверх
## следа коллизии, мосты — коричневым прямоугольником, вода без кромки. В каталоге есть
## нарисованные звенья (tex — вдоль, tex_v — поперёк, seg_h/seg_v — длина звена, w — толщина)
## и спрайты предметов с якорем; картинка и коллизия совпадают по построению, потому что
## раскладка ставит «след» тех же предметов в rocks/walls (STAGE2 §3).
##
## Всё — узлы (Sprite2D) в контейнере с y-сортировкой: нижний по экрану предмет перекрывает
## верхний, как на рисованном фоне в ракурсе 3/4. Узлы, а не draw_texture_rect: текстурные
## immediate-draw во вложенном SubViewport PgArt давали белый кадр (докстринг PgArt._run).
## Координаты — мировые px; PgArt масштабирует родителя ×1,5.

const TEX_SCALE := 1.5 ## px текстуры библиотеки на px мира (вырезки из листов 1920×1080)

## Мост — чуть шире полигона переправы (перила заходят на берег) и с передней гранью снизу.
const BRIDGE_PAD := 8.0
## Передняя грань звена стены свешивается за след не дальше этого (мира px).
const WALL_FRONT_MAX := 8.0
## Вид декора кампании → тег предмета библиотеки (decor_item).
const DECOR_TAG := {"grave": "tomb", "tree": "tree", "candle": "candle"}
const BRIDGE_FRONT := 10.0
## Только предметы с явными семантическими тегами идут в y-сортируемый боевой слой.
const DEPTH_TAGS := ["tree", "tomb", "pillar", "column"]
## В текущем каталоге у каменных колонн и крупных скал общий tag `stone`, поэтому берём
## только перечисленные силуэты по id; мелкий камень и низкие плиты остаются в земле.
const DEPTH_ITEM_IDS := ["grave_column_01", "grave_boulder_01", "ash_rock_l_01",
	"ash_cliff_xl_01", "swamp_rock_01", "hell_rock_01", "winter_rock_01"]

## Камыш по кромке воды/топи: шаг вдоль берега и доля пропусков (хэш, не RNG мира).
const REED_STEP := 44.0
const REED_SKIP := 0.45
const REED_ROAD_CLEAR := 12.0 ## от края полотна
## Кувшинки: сетка по воде, не ближе EDGE к берегу, не больше LILY_MAX на карту.
const LILY_STEP := 36.0
const LILY_EDGE := 18.0
const LILY_CHANCE := 0.16
const LILY_MAX := 8
const LILY_ROAD_CLEAR := 6.0
## Бумаги у стеллажей (§6.6: «у стеллажей и столов веером»): по одной на столько мира стены.
const PAPER_STEP := 150.0
const PAPER_SIDE := 16.0
const PAPER_CHANCE := 0.7
## Никакого клея на полотне, у участков и у Котла — там игра (BOOK §8.5 п.4).
const PLOT_CLEAR := 34.0
const CAULDRON_CLEAR := 70.0
const HASH_A := 12.9898
const HASH_B := 78.233
const HASH_SCALE := 43758.5453


## Строит под parent два слоя: мосты (под всем) и предметы с y-сортировкой. Возвращает
## счётчики для теста и отчёта: wall_links, wall_tex (пути текстур звеньев), props, bridges,
## reeds, lilies, papers.
static func build(parent: Node2D, map: Dictionary, depth_split := false) -> Dictionary:
	var stats := {"wall_links": 0, "wall_tex": [], "props": 0, "bridges": 0, "reeds": 0,
		"lilies": 0, "papers": 0, "depth_entries": []}
	var biome := String(map.get("biome", map.get("theme", "grave")))
	var bridges := Node2D.new()
	bridges.name = "Bridges"
	parent.add_child(bridges)
	var things := Node2D.new()
	things.name = "Things"
	things.y_sort_enabled = true
	parent.add_child(things)
	_bridges(bridges, map, stats)
	for entry: Dictionary in map.get("walls", []):
		_wall(things, entry, biome, stats)
	var avoid := Avoid.new(map)
	for prop: Dictionary in map.get("props", []):
		var item := PgCatalog.by_id(String(prop.get("item", "")))
		if String(item.get("role", "")) == "bridge":
			continue
		if depth_split and is_depth_item(item):
			(stats["depth_entries"] as Array).append({"item": item,
				"pos": Vector2(float(prop.pos[0]), float(prop.pos[1])),
				"flip": bool(prop.get("flip", false))})
			continue
		var tex := _tex(item, "tex")
		if tex == null:
			continue
		var pos := Vector2(float(prop.pos[0]), float(prop.pos[1]))
		# кувшинка раскладки под мостом легла бы на настил (кадр gen:12:11) — вода там не видна
		if (item.get("tags", []) as Array).has("water_only") and avoid.on_bridge(pos):
			continue
		things.add_child(item_sprite(item, tex, pos, bool(prop.get("flip", false))))
		stats["props"] = int(stats["props"]) + 1
	if (map.get("props", []) as Array).is_empty():
		for raw: Array in map.get("rocks", []):
			var poly := PgArtRoad._points(raw)
			if poly.size() < 3:
				continue
			var fit := fit_rock(poly, biome)
			if fit.is_empty():
				continue
			var it: Dictionary = fit["item"].duplicate()
			it["w"] = fit["w"]
			if depth_split and is_depth_item(it):
				(stats["depth_entries"] as Array).append({"item": it, "pos": fit["pos"],
					"flip": false})
				continue
			things.add_child(item_sprite(it, _tex(it, "tex"), fit["pos"], false))
			stats["props"] = int(stats["props"]) + 1
		for d: Dictionary in map.get("decor", []):
			var pos := Vector2(float(d.pos[0]), float(d.pos[1]))
			var item := decor_item(String(d.get("kind", "")), biome, pos)
			if depth_split and is_depth_item(item):
				(stats["depth_entries"] as Array).append({"item": item, "pos": pos,
					"flip": decor_flip(pos)})
				continue
			var tex := _tex(item, "tex")
			if tex != null:
				things.add_child(item_sprite(item, tex, pos, decor_flip(pos)))
				stats["props"] = int(stats["props"]) + 1
	_shore(things, map, biome, avoid, stats)
	_papers(things, map, biome, avoid, stats)
	return stats


static func is_depth_item(item: Dictionary) -> bool:
	if DEPTH_ITEM_IDS.has(String(item.get("id", ""))):
		return true
	var role := String(item.get("role", ""))
	if role != "decor" and role != "obstacle" and role != "light":
		return false
	for tag: String in DEPTH_TAGS:
		if (item.get("tags", []) as Array).has(tag):
			return true
	return false


## Декор кампании в `--dev pgart=1` (у карты нет props — только decor {kind, pos}): ближайший
## предмет библиотеки по тегу, выбор — хэш позиции. Без соответствия — {} (PgArtCanvas рисует
## такой декор кодом, как раньше).
static func decor_item(kind: String, biome: String, pos: Vector2) -> Dictionary:
	var tag := String(DECOR_TAG.get(kind, ""))
	if tag.is_empty():
		return {}
	var pool: Array = []
	for role: String in ["decor", "light"]:
		pool.append_array(PgCatalog.find(biome, role, "", tag))
	if pool.is_empty():
		return {}
	return pool[int(_hash(pos.x * 0.73 + pos.y * 1.37) * pool.size()) % pool.size()]


static func decor_flip(pos: Vector2) -> bool:
	return _hash(pos.x * 1.91 - pos.y) < 0.5


## Спрайт предмета каталога: ширина w мира, якорь anchor — в pos (узел стоит в pos, поэтому
## y-сортировка идёт по основанию предмета, а не по верху картинки).
static func item_sprite(item: Dictionary, tex: Texture2D, pos: Vector2, flip: bool) -> Sprite2D:
	var size := tex.get_size()
	var w := float(item.get("w", size.x / TEX_SCALE))
	var s := w / maxf(size.x, 1.0)
	var anchor: Array = item.get("anchor", [0.5, 0.5])
	var ax := float(anchor[0])
	if flip:
		ax = 1.0 - ax
	var sp := Sprite2D.new()
	sp.texture = tex
	sp.centered = false
	sp.flip_h = flip
	sp.offset = -Vector2(size.x * ax, size.y * float(anchor[1]))
	sp.scale = Vector2(s, s)
	sp.position = pos
	return sp


static func _tex(item: Dictionary, key: String) -> Texture2D:
	var path := String(item.get(key, ""))
	if path.is_empty() or not ResourceLoader.exists(path, "Texture2D"):
		return null
	return load(path) as Texture2D


## Препятствия, которые уже нарисованы спрайтом (их «след» — в rocks): PgArtCanvas не рисует
## для них кодовый многогранник-заглушку. Индексы rocks.
static func covered_rocks(map: Dictionary) -> PackedInt32Array:
	var no_props := (map.get("props", []) as Array).is_empty()
	var biome := String(map.get("biome", map.get("theme", "grave")))
	var anchors := PackedVector2Array()
	for prop: Dictionary in map.get("props", []):
		var item := PgCatalog.by_id(String(prop.get("item", "")))
		if String(item.get("role", "")) == "obstacle" and _tex(item, "tex") != null:
			anchors.append(Vector2(float(prop.pos[0]), float(prop.pos[1])))
	var out := PackedInt32Array()
	var rocks: Array = map.get("rocks", [])
	for i in rocks.size():
		var poly := PackedVector2Array()
		for p: Array in rocks[i]:
			poly.append(Vector2(float(p[0]), float(p[1])))
		if poly.size() < 3:
			continue
		if no_props and not fit_rock(poly, biome).is_empty():
			out.append(i)
			continue
		for a in anchors:
			if Geometry2D.is_point_in_polygon(a, poly):
				out.append(i)
				break
	return out


## Препятствие кампании в `--dev pgart=1` (у карты нет props — только след в rocks): предмет
## библиотеки своего биома, чей след ближе всего по пропорциям, растянутый по ширине следа.
## Совпадение с коллизией — приблизительное (след предмета не равен многоугольнику карты); когда
## кампания пойдёт через раскладку, препятствия придут предметами и подгонка не понадобится.
## {item, pos, w} или {}.
static func fit_rock(poly: PackedVector2Array, biome: String) -> Dictionary:
	var box := Rect2(poly[0], Vector2.ZERO)
	for p in poly:
		box = box.expand(p)
	if box.size.x < 8.0 or box.size.y < 8.0:
		return {}
	var want := log(box.size.x / box.size.y)
	var best := {}
	var best_d := INF
	for it: Dictionary in PgCatalog.find(biome, "obstacle"):
		var foot: Array = it.get("foot", [])
		if foot.size() < 3 or _tex(it, "tex") == null:
			continue
		var fb := Rect2(Vector2(float(foot[0][0]), float(foot[0][1])), Vector2.ZERO)
		for raw: Array in foot:
			fb = fb.expand(Vector2(float(raw[0]), float(raw[1])))
		if fb.size.x < 1.0 or fb.size.y < 1.0:
			continue
		var d := absf(log(fb.size.x / fb.size.y) - want)
		if d < best_d:
			best_d = d
			var k := box.size.x / fb.size.x
			best = {"item": it, "w": float(it.get("w", 60.0)) * k,
				"pos": box.get_center() - fb.get_center() * k}
	return best


# ── Стены звеньями ──────────────────────────────────────────────────────────

## Звенья каталога вдоль ломаной стены (все отрезки у раскладки — по осям экрана, проверено
## дампом 144 карт). Число звеньев на отрезке — ближайшее к длине/seg, звено слегка
## растягивается или сжимается, чтобы концы легли ровно в углы; отрезок продлён на полтолщины
## за каждый конец — угол «закрыт» перекрытием горизонтального и вертикального звена, а
## y-сортировка кладёт переднее поверх заднего. Нарисованные звенья сами несут столбы/торцы
## на концах, поэтому стык двух звеньев читается как столб ограды или шов кладки.
static func _wall(parent: Node2D, entry: Dictionary, biome: String, stats: Dictionary) -> void:
	var path := PgArtRoad._points(entry.get("path", []))
	if path.size() < 2:
		return
	var item := PgCatalog.by_id(String(entry.get("item", "")))
	if item.is_empty() or String(item.get("role", "")) != "wall":
		item = PgCatalog.wall(String(entry.get("kind", "stone")), biome)
	var tex_h := _tex(item, "tex")
	if tex_h == null:
		return
	var tex_v := _tex(item, "tex_v")
	var w := float(entry.get("w", item.get("w", 24.0)))
	var k := w / maxf(float(item.get("w", w)), 1.0)
	var hs := tex_h.get_size()
	var seg_h := float(item.get("seg_h", hs.x / TEX_SCALE))
	# передняя грань: картинка звена выше толщины стены — видна стенка под «крышкой» (ракурс 3/4).
	# Свешиваться за след коллизии ей можно лишь на WALL_FRONT_MAX: у стеллажа грань в полстены,
	# и без предела шкаф «наезжал» на дорогу и участки под ним (кадр archive, --dev pgart=1)
	var front := clampf(hs.y / TEX_SCALE * k - w, 0.0, WALL_FRONT_MAX)
	var h_scale := (w + front) / hs.y
	for i in path.size() - 1:
		var a := path[i]
		var b := path[i + 1]
		if is_equal_approx(a.y, b.y):
			var x0 := minf(a.x, b.x) - w * 0.5
			var x1 := maxf(a.x, b.x) + w * 0.5
			var n := maxi(1, roundi((x1 - x0) / seg_h))
			var link := (x1 - x0) / n
			for j in n:
				var sp := Sprite2D.new()
				sp.texture = tex_h
				sp.centered = false
				sp.offset = Vector2(0.0, -hs.y)
				sp.scale = Vector2(link / hs.x, h_scale)
				sp.position = Vector2(x0 + j * link, a.y + w * 0.5 + front)
				parent.add_child(sp)
				_count_link(stats, tex_h)
		else:
			var y0 := minf(a.y, b.y) - w * 0.5
			var y1 := maxf(a.y, b.y) + w * 0.5 + front
			if tex_v != null:
				var vs := tex_v.get_size()
				var seg_v := float(item.get("seg_v", vs.y / TEX_SCALE))
				var n := maxi(1, roundi((y1 - y0) / seg_v))
				var link := (y1 - y0) / n
				var vw := vs.x / TEX_SCALE * k
				for j in n:
					var sp := Sprite2D.new()
					sp.texture = tex_v
					sp.centered = false
					sp.offset = Vector2(0.0, -vs.y)
					sp.scale = Vector2(k / TEX_SCALE, link / vs.y)
					sp.position = Vector2(a.x - vw * 0.5, y0 + (j + 1) * link)
					parent.add_child(sp)
					_count_link(stats, tex_v)
			else:
				# у звена нет поперечного вида (дощатый забор стройки) — продольное, повёрнутое
				var n := maxi(1, roundi((y1 - y0) / seg_h))
				var link := (y1 - y0) / n
				for j in n:
					var sp := Sprite2D.new()
					sp.texture = tex_h
					sp.rotation = PI * 0.5
					sp.scale = Vector2(link / hs.x, k / TEX_SCALE)
					sp.position = Vector2(a.x, y0 + (j + 0.5) * link)
					parent.add_child(sp)
					_count_link(stats, tex_h)


static func _count_link(stats: Dictionary, tex: Texture2D) -> void:
	stats["wall_links"] = int(stats["wall_links"]) + 1
	var used: Array = stats["wall_tex"]
	if not used.has(tex.resource_path):
		used.append(tex.resource_path)


# ── Мосты ───────────────────────────────────────────────────────────────────

## Мост — спрайт swamp_bridge (tex — дорога вдоль x, tex_v — вдоль y) по прямоугольнику
## полигона переправы; предмет и ориентацию берём у предмета-моста раскладки (props[].vertical),
## без него — по вытянутости полигона.
static func _bridges(parent: Node2D, map: Dictionary, stats: Dictionary) -> void:
	var props: Array = map.get("props", [])
	for raw: Array in map.get("bridges", []):
		var poly := PgArtRoad._points(raw)
		if poly.size() < 3:
			continue
		var box := Rect2(poly[0], Vector2.ZERO)
		for p in poly:
			box = box.expand(p)
		var item := {}
		var vertical := box.size.y > box.size.x
		for prop: Dictionary in props:
			var it := PgCatalog.by_id(String(prop.get("item", "")))
			if String(it.get("role", "")) != "bridge":
				continue
			if box.grow(BRIDGE_PAD).has_point(Vector2(float(prop.pos[0]), float(prop.pos[1]))):
				item = it
				vertical = bool(prop.get("vertical", vertical))
				break
		if item.is_empty():
			for it: Dictionary in PgCatalog.items():
				if String(it.get("role", "")) == "bridge":
					item = it
					break
		var tex := _tex(item, "tex_v" if vertical else "tex")
		if tex == null:
			tex = _tex(item, "tex")
		if tex == null:
			continue
		var r := box.grow(BRIDGE_PAD)
		r.size.y += BRIDGE_FRONT
		var sp := Sprite2D.new()
		sp.texture = tex
		sp.centered = false
		sp.position = r.position
		sp.scale = r.size / tex.get_size()
		parent.add_child(sp)
		stats["bridges"] = int(stats["bridges"]) + 1


# ── Клей по соседству (§6.6) ────────────────────────────────────────────────

## Камыш — только на кромке воды и топи; кувшинки — только на воде. Предметы своего биома
## (каталог: теги reed/shore, water_only); чужого не берём — лучше без камыша, чем пальма.
static func _shore(parent: Node2D, map: Dictionary, biome: String, avoid: Avoid,
		stats: Dictionary) -> void:
	var reeds := PgCatalog.find(biome, "decor", "", "reed")
	var lilies: Array = []
	for it: Dictionary in PgCatalog.find(biome, "decor", "", "water_only"):
		if String(it.get("id", "")).contains("lily"):
			lilies.append(it)
	var polys: Array[PackedVector2Array] = []
	for raw: Array in map.get("water", []) + map.get("swamp", []):
		polys.append(PgArtRoad._points(raw))
	var salt := 0
	if not reeds.is_empty():
		for poly in polys:
			salt += 1
			if poly.size() < 3:
				continue
			var ring := poly.duplicate()
			ring.append(poly[0])
			var carry := 0.0
			for i in ring.size() - 1:
				var a := ring[i]
				var b := ring[i + 1]
				var ln := a.distance_to(b)
				var d := carry
				while d < ln:
					var p := a.lerp(b, d / ln)
					d += REED_STEP
					if _hash(p.x * 0.37 + p.y * 1.13 + salt) < REED_SKIP:
						continue
					if not avoid.clear(p, REED_ROAD_CLEAR):
						continue
					var item: Dictionary = reeds[int(_hash(p.y + p.x * 0.5) * reeds.size())
						% reeds.size()]
					var tex := _tex(item, "tex")
					if tex == null:
						continue
					parent.add_child(item_sprite(item, tex, p, _hash(p.x - p.y) < 0.5))
					stats["reeds"] = int(stats["reeds"]) + 1
				carry = d - ln
	if lilies.is_empty():
		return
	var placed := 0
	# кувшинки — на воде; в биоме «Болото» и на заводях топи (они там нарисованы как вода),
	# но не на полотне дороги
	var pools: Array = map.get("water", []).duplicate()
	if biome == "swamp":
		pools.append_array(map.get("swamp", []))
	for raw: Array in pools:
		var poly := PgArtRoad._points(raw)
		if poly.size() < 3:
			continue
		var box := Rect2(poly[0], Vector2.ZERO)
		for p in poly:
			box = box.expand(p)
		var y := box.position.y + LILY_STEP * 0.5
		while y < box.end.y and placed < LILY_MAX:
			var x := box.position.x + LILY_STEP * 0.5
			while x < box.end.x and placed < LILY_MAX:
				var p := Vector2(x, y)
				x += LILY_STEP
				if _hash(p.x * 1.7 + p.y * 0.3) > LILY_CHANCE:
					continue
				if not Geometry2D.is_point_in_polygon(p, poly) or _edge_dist(p, poly) < LILY_EDGE:
					continue
				if not avoid.clear(p, LILY_ROAD_CLEAR):
					continue
				var item: Dictionary = lilies[0]
				var tex := _tex(item, "tex")
				if tex == null:
					return
				parent.add_child(item_sprite(item, tex, p, _hash(p.y) < 0.5))
				placed += 1
			y += LILY_STEP
	stats["lilies"] = placed


## Бумаги у стеллажей: вдоль звеньев kind=shelf, попеременно по сторонам, веером (flip).
static func _papers(parent: Node2D, map: Dictionary, biome: String, avoid: Avoid,
		stats: Dictionary) -> void:
	var papers := PgCatalog.find(biome, "decor", "", "paper")
	if papers.is_empty():
		return
	for entry: Dictionary in map.get("walls", []):
		if String(entry.get("kind", "")) != "shelf":
			continue
		var path := PgArtRoad._points(entry.get("path", []))
		var w := float(entry.get("w", 50.0))
		for i in path.size() - 1:
			var a := path[i]
			var b := path[i + 1]
			var ln := a.distance_to(b)
			var dir := (b - a) / maxf(ln, 0.01)
			var d := PAPER_STEP * 0.5
			var side := 1.0
			while d < ln:
				var p := a + dir * d + dir.orthogonal() * side * (w * 0.5 + PAPER_SIDE)
				d += PAPER_STEP
				side = -side
				if _hash(p.x + p.y * 2.3) > PAPER_CHANCE or not avoid.clear(p, 8.0):
					continue
				var item: Dictionary = papers[int(_hash(p.x) * papers.size()) % papers.size()]
				var tex := _tex(item, "tex")
				if tex == null:
					continue
				parent.add_child(item_sprite(item, tex, p, _hash(p.y * 3.1) < 0.5))
				stats["papers"] = int(stats["papers"]) + 1


static func _edge_dist(p: Vector2, poly: PackedVector2Array) -> float:
	var best := INF
	for i in poly.size():
		var q := Geometry2D.get_closest_point_to_segment(p, poly[i], poly[(i + 1) % poly.size()])
		best = minf(best, p.distance_to(q))
	return best


static func _hash(v: float) -> float:
	return fposmod(sin(v * HASH_A + HASH_B) * HASH_SCALE, 1.0)


## Где клею нельзя: полотно дорог, участки, Котёл, мосты (BOOK §8.5 п.4 — там игра).
class Avoid:
	var roads: Array[PackedVector2Array] = []
	var plots := PackedVector2Array()
	var cauldron := Vector2(-9999, -9999)
	var cauldron_all := PackedVector2Array()
	var bridges: Array[Rect2] = []

	func _init(map: Dictionary) -> void:
		for road: Dictionary in map.get("roads", []):
			roads.append(PgArtRoad._points(road.get("path", [])))
		for plot: Dictionary in map.get("plots", []):
			plots.append(Vector2(float(plot.pos[0]), float(plot.pos[1])))
		var c: Variant = map.get("cauldron", null)
		if c is Array and (c as Array).size() >= 2:
			cauldron = Vector2(float(c[0]), float(c[1]))
		elif c is Dictionary and (c as Dictionary).has("pos"):
			cauldron = Vector2(float(c["pos"][0]), float(c["pos"][1]))
		# поле «Схватки»: Котлы обеих сторон (одиночка — тот же один map.cauldron)
		cauldron_all = PgArtScatter.cauldrons(map)
		if cauldron.x > -9000.0 and not cauldron_all.has(cauldron):
			cauldron_all.append(cauldron)
		for raw: Array in map.get("bridges", []):
			var poly := PgArtRoad._points(raw)
			if poly.is_empty():
				continue
			var box := Rect2(poly[0], Vector2.ZERO)
			for p in poly:
				box = box.expand(p)
			bridges.append(box.grow(PgArtSprites.BRIDGE_PAD * 2.0))

	func on_bridge(p: Vector2) -> bool:
		for r in bridges:
			if r.has_point(p):
				return true
		return false

	## Точка свободна: дальше extra от края полотна (полуширина MAP_ROAD_WIDTH), от участков
	## и Котла, вне мостов.
	func clear(p: Vector2, extra: float) -> bool:
		var need := LegionCfg.MAP_ROAD_WIDTH * 0.5 + extra
		for path in roads:
			for i in path.size() - 1:
				var q := Geometry2D.get_closest_point_to_segment(p, path[i], path[i + 1])
				if p.distance_to(q) < need:
					return false
		for pl in plots:
			if p.distance_to(pl) < PgArtSprites.PLOT_CLEAR:
				return false
		for c in cauldron_all:
			if p.distance_to(c) < PgArtSprites.CAULDRON_CLEAR:
				return false
		for r in bridges:
			if r.has_point(p):
				return false
		return true
