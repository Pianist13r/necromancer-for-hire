extends SceneTree
## Постройки и бойцы собранных карт встают в землю (slow/gen-harmony, 03.10.2026, D-1003-08):
## 1) тонировка PgArtHarmony.tone не поднимает светлоту (макс. компонента ≤ 1) и тонирует умеренно;
## 2) контактные точки — склепы и Котлы (участки не запекаем: в «Схватке» выдали бы пустые
##    участки противника), compose() кладёт узел Contact с тем же числом теней;
## 3) B-399: тела топи непрерывны (gen:5:9), мокрый слой покрывает все замедляющие клетки;
##    край детерминирован, словарь карты не меняется; кольцо-шина опилок не в группе конусов;
##    мебель конторы в группах темнее;
## 4) тень бойцов: без карты PgArt — чёрная, как была.
## Headless: compose() собирает дерево узлов без рендера.
var checks := 0
var fails := 0


func _initialize() -> void:
	_run.call_deferred()


func check(ok: bool, why: String) -> void:
	checks += 1
	if not ok:
		fails += 1
	print("  %s %s" % ["ok" if ok else "FAIL", why])


func _run() -> void:
	_test_tone()
	_test_contact()
	_test_marsh()
	_test_fill_kinds()
	_test_shadow_default()
	await _test_shadow_reset()
	print("LEGION PROCGEN HARMONY: %d/%d OK" % [checks - fails, checks])
	quit(1 if fails else 0)


func _probe(color: Color) -> PgArtHarmony:
	var img := Image.create(64, 36, false, Image.FORMAT_RGB8)
	img.fill(color)
	var h := PgArtHarmony.new()
	h.setup(ImageTexture.create_from_image(img), {"biome": "office", "id": "t"})
	return h


func _test_tone() -> void:
	for biome: String in PgArtHarmony.BIOME_TONE:
		var img := Image.create(64, 36, false, Image.FORMAT_RGB8)
		img.fill(Color(0.45, 0.4, 0.5))
		var h := PgArtHarmony.new()
		check(h.setup(ImageTexture.create_from_image(img), {"biome": biome}), biome + ": проба")
		var t := h.tone(Vector2(640, 360))
		check(maxf(t.r, maxf(t.g, t.b)) <= 1.0001, biome + ": компонента тона не больше 1")
		check(t.get_luminance() > 0.82, "%s: светлота не просела (%.3f)" % [biome, t.get_luminance()])
		check(t != Color.WHITE, biome + ": тон не белый")
	var warm := _probe(Color(0.5, 0.4, 0.3)).tone(Vector2(100, 100))
	check(warm.r > warm.b, "контора: тон тёплый (янтарь)")
	var sh := _probe(Color(0.5, 0.4, 0.3)).shadow_tint(Vector2(100, 100))
	check(sh.get_luminance() < 0.15 and sh.r > sh.b, "тень бойца тёмная и цвета земли (не серая)")


func _test_contact() -> void:
	for id: String in ["gen:12:5", "gen:5:9", "pvp:duel"]:
		var map := LegionWorld.load_map(id)
		var pts := PgArtHarmony.contact_points(map)
		var crypts := (map.get("crypts", []) as Array).size()
		var cauldrons := PgArtScatter.cauldrons(map).size()
		check(pts.size() == crypts + cauldrons,
			"%s: пустые участки не оставляют пятен на земле" % id)
		var root := Node2D.new()
		var stats := PgArt.compose(root, map, null, 0.0)
		var contact := root.get_node_or_null("Contact")
		check(contact != null and contact.get_child_count() == pts.size(),
			"%s: узел Contact, теней %d" % [id, pts.size()])
		check(int(stats.get("contact", -1)) == pts.size(), id + ": счётчик в stats")
		root.free()
	var disabled := LegionWorld.load_map("gen:12:5")
	disabled["contact"] = []
	var holder := Node2D.new()
	check(PgArtHarmony.build_contact(holder, disabled, null) == 0
		and holder.get_child_count() == 0, "явно пустой contact не возвращает тень Котла")
	holder.free()


func _test_marsh() -> void:
	var map := LegionWorld.load_map("gen:5:9")
	var raw: Array = map.get("swamp", [])
	var before := raw.duplicate(true)
	var bodies := PgArtMarsh.polys_of(map)
	check(raw.size() >= 2 and bodies.size() == raw.size(),
		"gen:5:9: топь непрерывна, без сухих просветов (%d зон, %d тел)"
			% [raw.size(), bodies.size()])
	check(raw == before, "gen:5:9: словарь карты не менялся")
	var again := PgArtMarsh.polys_of(map)
	var same := again.size() == bodies.size()
	for i in mini(again.size(), bodies.size()):
		same = same and again[i] == bodies[i]
	check(same, "тела топи повторяемы")
	var tiny := 0
	for b in bodies:
		var box := Rect2(b[0], Vector2.ZERO)
		for p in b:
			box = box.expand(p)
		if minf(box.size.x, box.size.y) < 14.0:
			tiny += 1
	check(tiny == 0, "нет лужи тоньше 14 px (%d)" % tiny)
	# Бирюзовая топь «Болота» остаётся в прежнем PgArtCanvas.
	check(PgArtMarsh.covers("site") and not PgArtMarsh.covers("swamp"),
		"тела топи — только вне «Болота»")
	_test_visible_slowdown(map)


## Проверяем узлы реального слоя рендера в каждой замедляющей клетке, а не только словарь.
func _test_visible_slowdown(map: Dictionary) -> void:
	var holder := Node2D.new()
	PgArtMarsh.build(holder, map, null)
	var wet: Array[PackedVector2Array] = []
	for node in holder.get_children():
		if node is Polygon2D and node.has_meta("pgart_swamp_zone"):
			var polygon := node as Polygon2D
			if polygon.color.a >= 0.65:
				wet.append(polygon.polygon)
	var terrain := LegionTerrain.new().setup(map)
	var missing := 0
	var slowed := 0
	for y in terrain.rows:
		for x in terrain.cols:
			var p := Vector2((x + 0.5) * LegionCfg.CELL, (y + 0.5) * LegionCfg.CELL)
			if terrain.speed_mult(p) >= 1.0:
				continue
			slowed += 1
			var visible := false
			for poly in wet:
				visible = visible or Geometry2D.is_point_in_polygon(p, poly)
			if not visible:
				missing += 1
	check(slowed > 0 and missing == 0,
		"все %d замедляющих клеток имеют видимую мокрую землю (пустых %d)" % [slowed, missing])
	holder.free()


func _test_shadow_reset() -> void:
	Campaign.set_save_path("user://harmony_test.cfg")
	var world := (load("res://scenes/legion_world.tscn") as PackedScene).instantiate() as LegionWorld
	world.embedded = true
	world.hold = true
	root.add_child(world)
	await process_frame
	world.start_map("gen:5:9")
	world.harmony = _probe(Color(0.5, 0.4, 0.3))
	world.apply_harmony()
	check(world._shadows_node != null and world._shadows_node.harmony != null,
		"тень бойцов получила пробу generated-карты")
	world.start_map("wasteland")
	check(world.harmony == null and world._shadows_node.harmony == null,
		"нарисованная кампания очистила цвет теней прошлой карты")
	world.harmony = _probe(Color(0.5, 0.4, 0.3))
	world.apply_harmony()
	world.dev["gray"] = 1
	world.start_map("gen:5:9")
	check(world.harmony == null and world._shadows_node.harmony == null,
		"запасной серый рельеф очистил цвет теней прошлой карты")
	# У LegionItems/effects взаимные RefCounted-ссылки; тест освобождает свой мир полностью.
	world.items.effects.items = null
	world.queue_free()
	await process_frame


func _test_fill_kinds() -> void:
	var site: Array = PgArtFill.KINDS["site"]
	var rings := 0
	for k: Dictionary in site:
		if String(k["flat"]) == "site_dec_sawdust":
			rings += 1
	check(rings == 0, "группы стройки: кольцо-шина опилок убрано")
	var up_tones := 0
	for k: Dictionary in PgArtFill.KINDS["office"]:
		var c: Color = k.get("up_tone", Color.WHITE)
		if c.get_luminance() < 0.8:
			up_tones += 1
	check(up_tones == 3, "группы конторы: мебель темнее пола (%d из 3)" % up_tones)


func _test_shadow_default() -> void:
	var sh := CharShadows.new()
	check(sh.harmony == null, "тени бойцов: без карты PgArt гармонии нет (чёрная тень, как была)")
	var tex := CharShadows._make_texture() as GradientTexture2D
	check(tex.gradient.get_color(0).r > 0.99, "текстура тени белая (цвет задаёт modulate)")
	sh.free()
