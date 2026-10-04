extends SceneTree
##
## P5b «Схватки» (docs/dev/PVP_PLAN_0929.md, B-301, B-304, B-CX-B-06): земля и фон — на весь мир
## поля 1600×900, а не на кадр одиночки 1280×720; стороны зеркальны; вид считает край ВИДИМОГО
## мира. Одиночка — прежние размеры.
##  1) PgArt: картинка и карта зон — мир карты ×1,5 / ×0,75 (одиночка — TEX_SIZE / MASK_SIZE);
##  2) подложка поля — вырезка и её зеркало, вместе ровно весь мир; у одиночки один спрайт 1280×720;
##  3) россыпь и композиции поля: на всём поле, попарно зеркальны, не в зонах Котлов ОБЕИХ сторон,
##     площадка под каждым Котлом;
##  4) TerrainView «Дуэли» рисует мир 1600×900, узор почвы — на половине с зеркалом;
##  5) телеграф угрозы и ворота волны — у края видимого поля (нижняя дорога стороны 1 входит
##     у нижнего края экрана, а не посреди него), одиночка — как раньше.
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_pvp_ground_test.gd -- --mute
##
## Итог «LEGION PVP GROUND: N/M OK»; код выхода 1, если что-то упало.
##

const SAVE := "user://legion_pvp_ground_test.cfg"
const SINGLE_GEN := ["gen:7:3", "gen:23:3", "gen:12:5"]
const PVP_GEN := ["gen:7:3:pvp", "gen:23:3:pvp"]
const DUEL := "pvp:duel"
const EPS := 0.51

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


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _run() -> void:
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	_test_sizes()
	for id: String in SINGLE_GEN:
		_test_single_stack(id)
	for id: String in PVP_GEN:
		_test_pvp_stack(id)
		_test_life(id)
	await _test_world()
	Campaign.reset()
	print("LEGION PVP GROUND: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


# ── 1. размеры картинки ─────────────────────────────────────────────────────

func _test_sizes() -> void:
	for id: String in SINGLE_GEN:
		var m := LegionWorld.load_map(id)
		_check(PgArt.tex_size(m) == PgArt.TEX_SIZE and PgArt.mask_size(m) == PgArt.MASK_SIZE,
			"%s: картинка %s, зоны %s — как у одиночки" % [id, PgArt.tex_size(m),
				PgArt.mask_size(m)])
		_check(LegionTerrain.mirror_width(m) == 0.0, "%s: не зеркальное поле" % id)
	for id: String in PVP_GEN + [DUEL]:
		var m := LegionWorld.load_map(id)
		var world := LegionTerrain.map_size(m)
		_check(world.x > LegionCfg.WORLD_SIZE.x and world.y > LegionCfg.WORLD_SIZE.y,
			"%s: мир %s больше кадра одиночки" % [id, world])
		_check(PgArt.tex_size(m) == world * PgArt.TEX_SCALE,
			"%s: картинка %s = мир ×1,5" % [id, PgArt.tex_size(m)])
		_check(PgArt.mask_size(m) == Vector2i((world * PgArt.MASK_SCALE).round()),
			"%s: карта зон %s = мир ×0,75" % [id, PgArt.mask_size(m)])
		_check(LegionTerrain.mirror_width(m) == world.x, "%s: поле зеркальное" % id)


# ── 2–3. стопка сборки (узлы без рендера) ────────────────────────────────────

func _ground_tex(m: Dictionary) -> Texture2D:
	var gp := PgArtCanvas.resolve_ground_path(m)
	if gp.is_empty() or not ResourceLoader.exists(gp, "Texture2D"):
		return null
	return load(gp) as Texture2D


## Прямоугольник спрайта подложки в мире (region × scale от position).
func _sprite_rect(s: Sprite2D) -> Rect2:
	var sz := s.region_rect.size if s.region_enabled else s.texture.get_size()
	return Rect2(s.position, sz * s.scale)


func _test_single_stack(id: String) -> void:
	var m := LegionWorld.load_map(id)
	var tex := _ground_tex(m)
	_check(tex != null, "%s: подложка биома есть" % id)
	if tex == null:
		return
	var root := Node2D.new()
	PgArt.compose(root, m, tex, 0.4)
	var g := root.get_node_or_null("Ground") as Sprite2D
	_check(g != null and root.get_node_or_null("GroundMirror") == null,
		"%s: одна подложка, без зеркала" % id)
	if g != null:
		var r := _sprite_rect(g)
		_check(r.position.is_equal_approx(Vector2.ZERO) and r.size.is_equal_approx(
			LegionCfg.WORLD_SIZE) and not g.region_enabled,
			"%s: подложка — кадр 1280×720 целиком (%s)" % [id, r])
	var scatter := root.get_node("Scatter")
	var bases := 0
	var outside := 0
	for c in scatter.get_children():
		var sp := c as Sprite2D
		if String(sp.name).begins_with("CauldronBase"):
			bases += 1
		elif not Rect2(Vector2.ZERO, LegionCfg.WORLD_SIZE).has_point(sp.position):
			outside += 1
	_check(outside == 0, "%s: россыпь в кадре 1280×720 (вне: %d)" % [id, outside])
	_check(bases == 1, "%s: одна площадка под Котлом" % id)
	root.free()


func _test_pvp_stack(id: String) -> void:
	var m := LegionWorld.load_map(id)
	var world := LegionTerrain.map_size(m)
	var half := Vector2(world.x * 0.5, world.y)
	var tex := _ground_tex(m)
	_check(tex != null, "%s: подложка биома есть" % id)
	if tex == null:
		return
	var root := Node2D.new()
	PgArt.compose(root, m, tex, 0.4)
	var g0 := root.get_node_or_null("Ground") as Sprite2D
	var g1 := root.get_node_or_null("GroundMirror") as Sprite2D
	_check(g0 != null and g1 != null, "%s: подложка и её зеркало" % id)
	if g0 != null and g1 != null:
		var r0 := _sprite_rect(g0)
		var r1 := _sprite_rect(g1)
		_check(r0.position.is_equal_approx(Vector2.ZERO) and r0.size.is_equal_approx(half),
			"%s: подложка стороны 0 = половина %s (%s)" % [id, half, r0])
		_check(r1.position.is_equal_approx(Vector2(half.x, 0.0)) and r1.size.is_equal_approx(half),
			"%s: зеркало = половина стороны 1 (%s)" % [id, r1])
		_check(r0.merge(r1).is_equal_approx(Rect2(Vector2.ZERO, world)),
			"%s: подложка покрывает весь мир %s" % [id, world])
		_check(g1.flip_h and not g0.flip_h and g0.region_rect == g1.region_rect,
			"%s: вторая половина — та же вырезка отражённой" % id)
		var ar := g0.region_rect.size.x / g0.region_rect.size.y
		_check(absf(ar - half.x / half.y) < 0.01, "%s: вырезка без искажения пропорций" % id)
	_check_scatter(id, m, root.get_node("Scatter"), world)
	# дороги: у каждой ленты стороны 1 есть зеркальная пара стороны 0 — её фактура рисуется
	# отражённой, и на стыке, где обе начинаются, шва нет
	var built: Array[PackedVector2Array] = []
	var twins := 0
	var paths := PgArtRoad.unique_paths(m)
	for e: Dictionary in paths:
		if PgArtRoad._mirror_twin(e["path"], built, world.x) >= 0:
			twins += 1
		built.append(e["path"])
	_check(twins * 2 == paths.size() and twins > 0,
		"%s: ленты дорог парами-зеркалами (%d из %d)" % [id, twins, paths.size()])
	_check(PgArtRoad._mirror_twin(paths[0]["path"], built, 0.0) == -1,
		"%s: без зеркального поля пары не ищутся (одиночка)" % id)
	root.free()


func _check_scatter(id: String, m: Dictionary, scatter: Node, world: Vector2) -> void:
	var cauldrons := PgArtScatter.cauldrons(m)
	_check(cauldrons.size() == 2, "%s: Котлов двое %s" % [id, cauldrons])
	var bases := PackedVector2Array()
	var pts: Array[Sprite2D] = []
	for c in scatter.get_children():
		var sp := c as Sprite2D
		if String(sp.name).begins_with("CauldronBase"):
			bases.append(sp.position - Vector2(0, PgArtScatter.BASE_LIFT))
		else:
			pts.append(sp)
	var based := bases.size() == 2
	for cp in cauldrons:
		based = based and (bases[0].is_equal_approx(cp) or bases[1].is_equal_approx(cp))
	_check(based, "%s: площадка под каждым Котлом %s" % [id, bases])
	_check(pts.size() >= 2 and pts.size() % 2 == 0, "%s: россыпи %d — чётное число" % [id,
		pts.size()])
	var unpaired := 0
	var in_cauldron := 0
	var outside := 0
	var beyond := false
	for sp in pts:
		var p := sp.position
		var twin: Sprite2D = null
		for q in pts:
			if q.position.distance_to(Vector2(world.x - p.x, p.y)) < EPS:
				twin = q
		if twin == null or twin.flip_h == sp.flip_h and absf(p.x - world.x * 0.5) > EPS \
				or not is_equal_approx(twin.rotation, -sp.rotation):
			unpaired += 1
		for cp in cauldrons:
			if p.distance_to(cp) < PgArtScatter.CAULDRON_CLEAR:
				in_cauldron += 1
		if not Rect2(Vector2.ZERO, world).has_point(p):
			outside += 1
		beyond = beyond or p.x > LegionCfg.WORLD_SIZE.x or p.y > LegionCfg.WORLD_SIZE.y
	_check(unpaired == 0, "%s: каждая кучка россыпи зеркальна (без пары: %d)" % [id, unpaired])
	_check(in_cauldron == 0, "%s: россыпь не в зонах Котлов обеих сторон (%d)" % [id,
		in_cauldron])
	_check(outside == 0, "%s: россыпь в поле (вне: %d)" % [id, outside])
	_check(beyond, "%s: россыпь есть и за кадром 1280×720 (x > 1280 или y > 720)" % id)


func _test_life(id: String) -> void:
	var m := LegionWorld.load_map(id)
	var world := LegionTerrain.map_size(m)
	var pts := PgArtLife.positions(m)
	_check(pts == PgArtLife.positions(m), "%s: композиции детерминированы" % id)
	_check(not pts.is_empty() and pts.size() % 2 == 0,
		"%s: композиции парами (%d)" % [id, pts.size()])
	var free := PgArtScatter.Free.new(m, PgArtScatter._cauldron(m))
	var cauldrons := PgArtScatter.cauldrons(m)
	var bad := 0
	for i in range(0, pts.size() - 1, 2):
		if not pts[i + 1].is_equal_approx(Vector2(world.x - pts[i].x, pts[i].y)):
			bad += 1
	_check(bad == 0, "%s: вторая группа пары — зеркало первой" % id)
	var busy := 0
	for p in pts:
		if not free.ok(p, PgArtLife.CLEAR):
			busy += 1
		for cp in cauldrons:
			if p.distance_to(cp) < PgArtScatter.CAULDRON_CLEAR + PgArtLife.CLEAR:
				busy += 1
	_check(busy == 0, "%s: композиции на свободной земле, вне зон обоих Котлов" % id)


# ── 4–5. мир: TerrainView, телеграф угрозы, ворота ──────────────────────────

func _test_world() -> void:
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	var w := scene.instantiate() as LegionWorld
	root.add_child(w)
	await _frames(2)
	# одиночка: вид — кадр, вход дороги как раньше
	w.dev = {"no_waves": "1", "spawn_units": "0"}
	w.args.erase("bot")
	w.start_map("bridge")
	await _frames(2)
	_check(w.view_rect() == Rect2(Vector2.ZERO, LegionCfg.WORLD_SIZE), "одиночка: вид — кадр")
	var same := true
	for r: Dictionary in w.map.get("roads", []):
		var path := w.road_path(String(r.get("id", "")))
		if path.size() >= 2:
			var a := LegionThreatEdge.entry_point(path)
			same = same and a == w.world_to_screen(LegionThreatEdge.entry_point(path,
				w.view_rect()))
	_check(same, "одиночка: вход дорог для телеграфа прежний")
	var tv := w.ground_view()
	_check(tv != null and tv.get("_size") == LegionCfg.WORLD_SIZE, "одиночка: рельеф 1280×720")
	# «Дуэль»
	# волны нужны для ворот (gate_points); первая — через PvpRules.FIRST_WAVE, тест раньше
	w.dev = {"spawn_units": "0", "pvp_nobot": "1"}
	w.args.erase("pvp_bots")
	w.start_map(DUEL)
	await _frames(2)
	var world := w.world_size
	_check(w.view_rect().is_equal_approx(Rect2(Vector2.ZERO, world)),
		"«Дуэль»: видно всё поле %s" % w.view_rect())
	tv = w.ground_view()
	_check(tv != null and tv.get("_size") == world, "«Дуэль»: рельеф рисует мир %s" % world)
	if tv != null:
		var area: Rect2 = tv.call("_pattern_area")
		_check(area == Rect2(Vector2.ZERO, Vector2(world.x * 0.5, world.y)),
			"«Дуэль»: узор почвы — на половине %s и зеркалом" % area)
	var bot := w.road_path("s1_bot")
	_check(bot.size() >= 2, "«Дуэль»: есть нижняя дорога стороны 1")
	if bot.size() >= 2:
		var at := w.world_to_screen(LegionThreatEdge.entry_point(bot, w.view_rect()))
		_check(absf(at.y - LegionCfg.WORLD_SIZE.y) < 4.0 and at.x > LegionCfg.WORLD_SIZE.x * 0.7,
			"«Дуэль»: телеграф нижней дороги стороны 1 — у нижнего края экрана %s" % at)
		var old := LegionThreatEdge.entry_point(bot)
		_check(old.y < LegionCfg.WORLD_SIZE.y + 1.0 and at != old,
			"«Дуэль»: прежний расчёт по кадру 1280×720 дал бы другую точку %s" % old)
	# слой FX в безголовом прогоне может быть выключен настройкой графики — свой экземпляр
	var fx := w.gfx_fx()
	var own_fx := fx == null
	if own_fx:
		fx = LegionFx.new()
		w.add_child(fx)
		fx.setup(w)
	print("  ..   волн у «Дуэли»: %d" % (w.wave_runner.waves.size() if w.wave_runner else -1))
	if w.wave_runner != null and not w.wave_runner.waves.is_empty():
		var far := false
		var inside := true
		for i in mini(2, w.wave_runner.waves.size()):
			for p in fx.gate_points(i):
				far = far or p.x > LegionCfg.WORLD_SIZE.x or p.y > LegionCfg.WORLD_SIZE.y
				inside = inside and w.view_rect().has_point(p)
		_check(far and inside, "«Дуэль»: отсвет ворот и за кадром 1280×720, но в поле")
	else:
		_check(false, "«Дуэль»: волны для проверки ворот")
	if own_fx:
		fx.queue_free()
	w.queue_free()
	await _frames(2)
