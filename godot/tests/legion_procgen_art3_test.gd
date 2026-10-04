extends SceneTree
##
## Регресс линии art3 (сессия e5d60159, 27.09.2026): сборка картинки процедурной карты «как
## нарисовано» и эффекты логики уровня.
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_procgen_art3_test.gd -- --mute
##
## 1) PgArt.compose собирает дерево узлов без рендера (headless не падает);
## 2) стены — спрайтами звеньев каталога (tex вдоль, tex_v поперёк), по звену на отрезок и больше;
## 3) дорога — меш-лента с текстурой вырезки road_<биом>.png, UV вдоль пути (фактура повторяется
##    по длине), светлота полотна подогнана к земле в коридоре ×1,4–2,5;
## 4) препятствия с картинкой — спрайтами, их кодовый многогранник-заглушка не рисуется;
## 5) мосты — спрайт swamp_bridge, камыш — на кромке воды;
## 6) у карты с ambient.quirk_fx создаются эффекты логики уровня: трещина ярчает к открытию,
##    спящий мимик «похрапывает» (Zz), в экономной графике слоя эффектов нет вовсе;
## 7) кампанийная карта рисуется как раньше — своим нарисованным фоном.
##
## Итог «LEGION PROCGEN ART3: N/M OK»; код выхода 1, если что-то упало. Сохранение — временное.
##
## На старом коде (до линии art3) падает: нет PgArt.compose и LegionQuirkFx — проверки 1–6
## дают FAIL (скрипты грузятся через load(), а не по имени класса, чтобы тест не падал разбором).

const SAVE := "user://legion_procgen_art3_test.cfg"
const PG_ART := "res://scripts/legion/procgen/pg_art.gd"
const QUIRK_FX := "res://scripts/legion/fx/legion_quirk_fx.gd"
const PG_SPRITES := "res://scripts/legion/procgen/pg_art_sprites.gd"
const PG_ROAD := "res://scripts/legion/procgen/pg_art_road.gd"

var _fails := 0
var _checks := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(cond: bool, what: String) -> void:
	_checks += 1
	if cond:
		print("  ok   ", what)
	else:
		_fails += 1
		print("  FAIL ", what)


func _run() -> void:
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	_test_compose_walls_road_props()
	_test_compose_bridge_shore()
	_test_brightness_corridor()
	await _test_quirk_fx()
	await _test_economy_no_fx()
	_test_campaign_untouched()
	Campaign.reset()
	print("LEGION PROCGEN ART3: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


func _compose(map: Dictionary) -> Dictionary:
	var script := load(PG_ART) as GDScript
	var has := false
	if script != null:
		for m: Dictionary in script.get_script_method_list():
			if String(m["name"]) == "compose":
				has = true
	_check(has, "PgArt.compose есть (сборка стопкой узлов, тестируемо без рендера)")
	if not has:
		return {}
	var root := Node2D.new()
	var stats: Dictionary = script.call("compose", root, map, null, 0.4)
	stats["root"] = root
	return stats


func _sprites_with(node: Node, needle: String) -> int:
	var n := 0
	for c in node.get_children():
		# слой Fill — декоративные группы gen-art-polish, не предметы карты: тест считает только запечённое словарём
		if c.name == &"Fill":
			continue
		if c is Sprite2D and (c as Sprite2D).texture != null \
				and (c as Sprite2D).texture.resource_path.contains(needle):
			n += 1
		n += _sprites_with(c, needle)
	return n


func _meshes(node: Node) -> Array[MeshInstance2D]:
	var out: Array[MeshInstance2D] = []
	for c in node.get_children():
		if c is MeshInstance2D:
			out.append(c as MeshInstance2D)
		out.append_array(_meshes(c))
	return out


func _grave_map() -> Dictionary:
	return {
		"id": "gen:0:0", "biome": "grave", "bg": "", "cauldron": [200, 360],
		"procgen": {"version": 1, "seed": 0, "k": 0},
		"roads": [{"id": "east", "path": [[1360, 360], [800, 360], [800, 200], [200, 200],
			[200, 360]]}],
		"walls": [{"path": [[400, 500], [700, 500], [700, 650]], "w": 18, "kind": "fence",
			"item": "grave_fence"}],
		"rocks": [[[930, 470], [1030, 470], [1030, 530], [930, 530]]],
		"props": [{"item": "grave_sarc_01", "pos": [980, 500], "flip": false},
			{"item": "grave_tomb_01", "pos": [500, 580], "flip": true}],
		"water": [], "swamp": [], "bridges": [], "decor": [], "plots": [],
		"ambient": {"glows": []},
	}


func _test_compose_walls_road_props() -> void:
	var map := _grave_map()
	var st := _compose(map)
	if st.is_empty():
		for i in 6:
			_check(false, "сборка недоступна — проверки стен/дороги/предметов пропущены")
		return
	var root: Node2D = st["root"]
	var wall_tex: Array = st.get("wall_tex", [])
	_check(int(st.get("wall_links", 0)) >= 3,
		"стена из двух отрезков — ≥ 3 звеньев-спрайтов (было %d)" % int(st.get("wall_links", 0)))
	_check(wall_tex.has("res://assets/legion/procgen/items/grave_fence_h.png")
		and wall_tex.has("res://assets/legion/procgen/items/grave_fence_v.png"),
		"стена берёт текстуры каталога: звено вдоль (tex) и поперёк (tex_v) — %s" % str(wall_tex))
	_check(_sprites_with(root, "grave_fence") == int(st.get("wall_links", -1)),
		"каждое звено — Sprite2D с картинкой ограды")
	var roads := _meshes(root.get_node("Roads"))
	var textured := roads.filter(func(m: MeshInstance2D) -> bool:
		return m.texture != null and m.texture.resource_path.ends_with("road/road_grave.png"))
	_check(int(st.get("roads", 0)) == 1 and textured.size() >= 2,
		"дорога — меш-лента (кайма + полотно) с текстурой вырезки road_grave.png")
	var max_u := 0.0
	if not textured.is_empty():
		var arr := (textured[0].mesh as ArrayMesh).surface_get_arrays(0)
		for uv: Vector2 in arr[Mesh.ARRAY_TEX_UV] as PackedVector2Array:
			max_u = maxf(max_u, uv.x)
	_check(max_u > 3.0, "UV вдоль пути: фактура повторяется по длине (u до %.1f периодов)" % max_u)
	_check(_sprites_with(root, "grave_sarc_01") == 1 and _sprites_with(root, "grave_tomb_01") == 1,
		"препятствие и декор с картинкой — спрайты каталога")
	var covered: PackedInt32Array = (load(PG_SPRITES) as GDScript).call("covered_rocks", map)
	_check(covered.has(0), "след препятствия со спрайтом не рисуется кодовым многогранником")
	root.free()


func _test_compose_bridge_shore() -> void:
	var map := _grave_map()
	map["biome"] = "swamp"
	map["walls"] = []
	map["water"] = [[[600, -40], [700, -40], [700, 760], [600, 760]]]
	map["bridges"] = [[[570, 152], [730, 152], [730, 248], [570, 248]]]
	map["props"] = [{"item": "swamp_bridge", "pos": [650, 200], "flip": false, "vertical": false}]
	var st := _compose(map)
	if st.is_empty():
		_check(false, "сборка недоступна — мост и камыш не проверены")
		return
	var root: Node2D = st["root"]
	_check(int(st.get("bridges", 0)) == 1 and _sprites_with(root, "swamp_bridge_h") == 1,
		"мост — спрайт swamp_bridge (дорога вдоль x — вид tex)")
	_check(int(st.get("reeds", 0)) >= 4, "камыш на кромке воды (%d шт.)" % int(st.get("reeds", 0)))
	var on_road := 0
	for c in root.get_node("Sprites/Things").get_children():
		var sp := c as Sprite2D
		if sp != null and sp.texture.resource_path.contains("reeds"):
			if absf(sp.position.y - 200.0) < LegionCfg.MAP_ROAD_WIDTH * 0.5 + 8.0 \
					and sp.position.x > 560.0 and sp.position.x < 740.0:
				on_road += 1
	_check(on_road == 0, "камыш не лёг на полотно дороги и мост")
	root.free()


func _test_brightness_corridor() -> void:
	# светлота полотна после подгонки: ×1,4–2,5 к земле и на тёмной, и на светлой подложке
	for land: float in [0.26, 0.4, 0.55]:
		var b := 0.0
		if _has_road_class():
			b = (load(PG_ROAD) as GDScript).call("brightness", 0.8, land)
		var ratio := 0.8 * b / land
		_check(ratio >= 1.4 and ratio <= 2.5,
			"полотно на земле L %.2f — ×%.2f к земле (коридор 1,4–2,5)" % [land, ratio])


func _has_road_class() -> bool:
	return ResourceLoader.exists(PG_ROAD)


func _world() -> LegionWorld:
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	var w := scene.instantiate() as LegionWorld
	root.add_child(w)
	return w


func _test_quirk_fx() -> void:
	var script := load(QUIRK_FX) as GDScript
	_check(script != null, "слой эффектов логики уровня LegionQuirkFx есть")
	if script == null:
		for i in 5:
			_check(false, "эффекты логики уровня недоступны")
		return
	var w := _world()
	await process_frame
	w.set_process(false)
	w.dev["spawn_units"] = "0"
	# карта со спящим мимиком, топью на дороге и склепом (gen:12:5 — дамп 27.09)
	w.start_map("gen:12:5")
	var fx := LegionFx.new()
	w.add_child(fx)
	fx.setup(w)
	fx._on_match_started(w.map_id)
	var q: Node = fx.get("quirk")
	var kinds: PackedStringArray = q.call("kinds") if q != null else PackedStringArray()
	var want := (w.map.get("ambient", {}) as Dictionary).get("quirk_fx", []) as Array
	_check(q != null and int(q.call("count")) == want.size() and want.size() >= 2,
		"у карты с quirk_fx создаются эффекты: %s" % ",".join(kinds))
	var zz := 0
	var bubbles := 0
	for i in 60:
		fx.tick(0.1)
		for p: Dictionary in q.get("_parts"):
			if p["kind"] == &"zz":
				zz += 1
			elif p["kind"] == &"bubble":
				bubbles += 1
	_check(zz > 0, "спящий мимик «похрапывает»: Zz над ним")
	_check(bubbles > 0, "топь на дороге пускает пузыри")
	# трещина: gen:16:9 — breach×2 + golden_pit. Интеграция 27.09: filter v4 + layout + каталог
	# библиотеки сдвинули генерацию, gen:12:9 из дампа ветки art3 теперь даёт throat_lights.
	w.start_map("gen:16:9")
	fx._on_match_started(w.map_id)
	var crack := {}
	for it: Dictionary in q.get("_items"):
		if it["kind"] == "breach":
			crack = it
	if crack.is_empty():
		_check(false, "у gen:12:9 есть эффект трещины")
	else:
		var k0: float = q.call("breach_k", crack)
		w.breach_warned.emit(String(crack["id"]), 5.0, [])
		var k1: float = q.call("breach_k", crack)
		_check(k0 < k1 and is_equal_approx(k1, 1.0),
			"трещина светится сильнее к открытию: %.2f → %.2f при предупреждении" % [k0, k1])
	fx.free()
	w.queue_free()
	await process_frame


func _test_economy_no_fx() -> void:
	var w := _world()
	await process_frame
	w.set_process(false)
	w.start_map("gen:12:9")
	Settings.economy_override = "on"
	w._sync_gfx_layers()
	_check(w.gfx_fx() == null, "экономная графика: слоя эффектов (и эффектов логики уровня) нет")
	Settings.economy_override = "off"
	w._sync_gfx_layers()
	var fx := w.gfx_fx()
	_check(fx != null and fx.get("quirk") != null, "полная графика: слой эффектов с эффектами карты")
	Settings.economy_override = ""
	w.queue_free()
	await process_frame


func _test_campaign_untouched() -> void:
	var map := LegionWorld.load_map("fork")
	var tv := TerrainView.new()
	tv.setup(map)
	_check(tv.background_texture() != null
		and tv.background_texture().resource_path.ends_with("fork_bg.jpg"),
		"кампанийная карта рисуется своим фоном, не сборкой PgArt")
	tv.free()
