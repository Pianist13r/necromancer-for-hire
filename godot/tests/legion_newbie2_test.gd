extends SceneTree
##
## Регресс второй волны находок кампании новичка по переписке (сессия 180f1168, 27.09.2026,
## дневник C:\AI\necro\batches\corr\camp-s1\DIARY.md; линия newbie2 сессии e5d60159):
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_newbie2_test.gd -- --mute
##
## Каждая проверка падала на коде до правки (номер находки — в заголовке раздела).
## Итог «LEGION NEWBIE2: N/M OK»; код выхода 1, если что-то упало.
##

const SAVE := "user://legion_newbie2_test.cfg"
const FPS := 60.0
const MAPS := ["wasteland", "gatehouse", "fork", "bridge", "maze", "swamp", "archive", "boss"]
## B-123, линии замера: поперёк дороги и фланги вдоль неё в стольких px от оси; длина; шаг.
const ARROW_FLANK := 55.0
const ARROW_LEN := 100.0
const ARROW_STEP := 30.0
## Враг «впереди», если средняя точка дорог выше по течению в этом радиусе от середины линии
## лежит по стрелке — независимо от правила самой стрелки (там — одна точка на 60 px пути).
const ARROW_R := 150.0
## B-092: шаг по дороге; «узко» — уже 76 px (B-099); рука заходит в стену на столько px;
## дальше CORRIDOR_SCAN от оси стены нет — это не коридор.
const CORRIDOR_STEP := 20.0
const CORRIDOR_NARROW := 76.0
const CORRIDOR_OVER := 8.0
const CORRIDOR_SCAN := 70.0
## B-083: рождений на площадку; «у дороги» — ближе стольких px к оси (досягаемость толпы).
const SPAWN_SAMPLES := 200
const SPAWN_NEAR := 50.0
## B-083 (verifier): рождение «с обходом» — путь от двери по сетке длиннее прямой × 1,3 + 32 px.
## Запас — две клетки: A* идёт через центры клеток 16 px, и до точки в 25 px от двери по прямой
## путь без всякого обхода выходит ~51 px (wasteland p1). Настоящий обход — сотни px.
const REACH_SAMPLES := 2000
const REACH_K := 1.3
const REACH_PAD := 32.0

var w: LegionWorld
var _fails := 0
var _checks := 0
var _rng := RandomNumberGenerator.new()


func _initialize() -> void:
	_run.call_deferred()


func _check(cond: bool, what: String) -> void:
	_checks += 1
	if cond:
		print("  ok   ", what)
	else:
		_fails += 1
		print("  FAIL ", what)


func _step(sec: float) -> void:
	for i in int(sec * FPS):
		w._step(1.0 / FPS)


func _run() -> void:
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	root.size = Vector2i(1280, 720)
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	w = scene.instantiate() as LegionWorld
	w.embedded = true
	root.add_child(w)
	await process_frame
	await _test_perfect_lesson()
	_test_stroke_arrow()
	_test_corridors()
	_test_spawn_fan()
	_test_spawn_reach()
	_test_charge_miss()
	_test_plot_menu_staff()
	_test_upgrade_offers()
	await _test_settlement_word()
	_test_item_overflow()
	_test_false_eight()
	_test_gold_taken()
	await _test_lesson_advice()
	_test_lull_hint()
	_test_door_hint()
	# дальше — экраны кампании через LegionMain (свой мир), тестовый мир больше не нужен
	w.queue_free()
	await process_frame
	await _test_screens_cover()
	Campaign.reset()
	print("LEGION NEWBIE2: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


# ── B-090: «Пустырь», урок 4 «Точно!» ────────────────────────────────────────

## Новичок: линия по дорожке, подновление, урок натиска — рогаткой по участку на дороге к
## идущим зомби (как в дневнике: отряд встал на повороте). Дальше урок «Точно!» должен
## проходиться сам собой: зомби доходят до строя (участок золотеет), линия не тает, урок не
## откатывается к «проведи договор».
func _test_perfect_lesson() -> void:
	print("— B-090: урок «Точно!» на «Пустыре»")
	Campaign.reset()
	w.in_campaign = true
	w.dev = {}
	w.args.erase("bot")
	w.start_map("wasteland")
	w.start_lessons(false)
	var tut := w.tutorial
	await process_frame
	var pts := tut.ghost_points()
	var c := w.contracts.add_contract(pts, w.contracts.default_side(pts), true)
	_step(4.0)
	w.contracts.refresh(c, PackedInt32Array([0, 1]))
	_step(1.0)
	_check(tut.step_id() == &"release", "дошли до урока натиска (сейчас %s)" % tut.step_id())
	# участок на дороге (x = 320) — к повороту, куда идут зомби
	var road_seg := 1 if c.seg_center(1).x > c.seg_center(0).x else 0
	var to_turn := (Vector2(400, 180) - c.seg_center(road_seg)).normalized()
	w.contracts.release_aimed(c, road_seg, to_turn, 1.0, false)
	_step(0.2)
	_check(tut.step_id() == &"perfect", "урок «Точно!» начался (сейчас %s)" % tut.step_id())
	var gold := false
	var rolled_back := false
	var far_free := 0
	for k in int(20.0 * FPS):
		w._step(1.0 / FPS)
		if w.tutorial == null or tut.step_id() != &"perfect":
			rolled_back = true
			break
		for cc in w.contracts.contracts:
			for s in cc.seg_count():
				if cc.seg_alive(s) and w.contracts.seg_gold(cc, s):
					gold = true
		if k == int(8.0 * FPS):
			for u in w.units:
				if u.alive and u.state == Legionnaire.State.FREE \
						and u.position.distance_to(Vector2(380, 210)) < 60.0:
					far_free += 1
	_check(not rolled_back, "за 20 с урок не откатился к «проведи договор» (таяние линии)")
	_check(gold, "учебные зомби дошли до строя: участок золотой — «Точно!» можно взять")
	_check(far_free == 0, "на повороте не стоят свободные, перехватывающие зомби (%d)" % far_free)
	w.in_campaign = false


# ── B-123: стрелка штриха по умолчанию ───────────────────────────────────────

## Доля линий, чья стрелка смотрит на подходящего врага: по всем 8 картам, «от Котла» (было)
## против стрелки договора, начерченного штрихом игрока (стало). Числа — в отчёт линии;
## проверка — не хуже ни на одной карте и заметно лучше на «Пустыре».
func _test_stroke_arrow() -> void:
	print("— B-123: стрелка штриха смотрит на подход врага")
	w.in_campaign = false
	for id: String in MAPS:
		w.dev = {"no_waves": "1", "spawn_units": "0"}
		w.start_map(id)
		var n := 0
		var old_ok := 0
		var new_ok := 0
		for r: Dictionary in w.map.get("roads", []):
			var path := w.road_path(String(r["id"]))
			var total := 0.0
			for i in range(1, path.size()):
				total += path[i - 1].distance_to(path[i])
			var s := 0.0
			while s < total:
				var p := _pp(path, s)
				var t := (_pp(path, s + 4.0) - _pp(path, s - 4.0)).normalized()
				s += ARROW_STEP
				if not Rect2(Vector2.ZERO, LegionCfg.WORLD_SIZE).has_point(p) \
						or p.distance_to(w.cauldron_pos) < 100.0 or t == Vector2.ZERO:
					continue
				var nrm := t.orthogonal()
				var lines: Array[PackedVector2Array] = [
					PackedVector2Array([p - nrm * ARROW_LEN * 0.5, p + nrm * ARROW_LEN * 0.5])]
				for off: float in [ARROW_FLANK, -ARROW_FLANK]:
					var m := p + nrm * off
					lines.append(PackedVector2Array([m - t * ARROW_LEN * 0.5, m + t * ARROW_LEN * 0.5]))
				for ln in lines:
					if not (w.terrain.walkable(ln[0]) and w.terrain.walkable(ln[1])
							and w.terrain.walkable(ln[0].lerp(ln[1], 0.5))):
						continue
					var verdict := _faces_foe(ln)
					if verdict == 0:
						continue
					var drawn := _drawn_dir(ln)
					if drawn == Vector2.ZERO:
						continue   # штрих не лёг (упёрся в стену) — стрелки нет ни прежде, ни теперь
					n += 1
					var ahead := _upstream_dir(ln[0].lerp(ln[1], 0.5))
					if w.contracts.default_dir(ln).dot(ahead) > 0.0:
						old_ok += 1
					if drawn.dot(ahead) > 0.0:
						new_ok += 1
		var old_f := float(old_ok) / maxf(1.0, float(n))
		var new_f := float(new_ok) / maxf(1.0, float(n))
		print("    %-9s линий %3d: смотрит на подход — было %3.0f %%, стало %3.0f %%"
			% [id, n, old_f * 100.0, new_f * 100.0])
		_check(n > 0 and new_f >= old_f, "%s: стрелка не хуже прежней (%.0f → %.0f %%)"
			% [id, old_f * 100.0, new_f * 100.0])
		if id == "wasteland":
			_check(new_f >= 0.9 and new_f > old_f + 0.2,
				"«Пустырь»: стрелка смотрит на подход у ≥ 90 %% линий (%.0f %%)" % (new_f * 100.0))
	w.dev = {}


## Средняя сторона, где лежат точки дорог выше по течению (враг ещё не прошёл линию) в ARROW_R
## от середины: единичный вектор от середины к их центру; ZERO — таких точек нет.
func _upstream_dir(mid: Vector2) -> Vector2:
	var sum := Vector2.ZERO
	var k := 0
	for r: Dictionary in w.map.get("roads", []):
		var path := w.road_path(String(r["id"]))
		# ближайшая точка этой дороги — дальше неё враг уже прошёл
		var best := INF
		var best_s := 0.0
		var run := 0.0
		for i in range(1, path.size()):
			var q := Geometry2D.get_closest_point_to_segment(mid, path[i - 1], path[i])
			if mid.distance_to(q) < best:
				best = mid.distance_to(q)
				best_s = run + path[i - 1].distance_to(q)
			run += path[i - 1].distance_to(path[i])
		if best > ARROW_R:
			continue
		var s := best_s - 6.0
		while s > 0.0:
			var p := _pp(path, s)
			if p.distance_to(mid) > ARROW_R:
				break
			sum += p - mid
			k += 1
			s -= 6.0
	return sum.normalized() if k > 0 else Vector2.ZERO


func _faces_foe(ln: PackedVector2Array) -> int:
	return 1 if _upstream_dir(ln[0].lerp(ln[1], 0.5)) != Vector2.ZERO else 0


## Стрелка договора, начерченного штрихом (путь мыши игрока: begin → extend → finish).
func _drawn_dir(ln: PackedVector2Array) -> Vector2:
	var f := w.contracts
	f.mana = f.mana_max
	f.begin(ln[0])
	for k in range(1, 11):
		f.extend(ln[0].lerp(ln[1], float(k) / 10.0))
	f.finish()
	if f.contracts.is_empty():
		return Vector2.ZERO
	var c: Contract = f.contracts[f.contracts.size() - 1]
	var d := c.dir
	f.dismiss(c)
	return d


## Точка ломаной на расстоянии dist пути от начала (своя копия: тест должен собираться и на
## коде до правки, где у ContractField такого помощника нет).
static func _pp(path: PackedVector2Array, dist: float) -> Vector2:
	if dist <= 0.0:
		return path[0]
	for i in range(1, path.size()):
		var seg := path[i - 1].distance_to(path[i])
		if dist <= seg and seg > 0.0:
			return path[i - 1].lerp(path[i], dist / seg)
		dist -= seg
	return path[path.size() - 1]


# ── B-092/B-099: линия поперёк узкого коридора ───────────────────────────────

## Штрих поперёк дороги там, где проход уже 76 px (B-099): рука начинает и кончает чуть в стене
## (CORRIDOR_OVER px за кромкой — у ограды след толще рисунка забора), как в дневнике
## (ходы 248–251). Доля штрихов, из которых родилась линия, — на «Двух отделах» и «Лабиринте».
func _test_corridors() -> void:
	print("— B-092: линия поперёк узкого коридора")
	w.in_campaign = false
	for id: String in ["fork", "maze"]:
		w.dev = {"no_waves": "1", "spawn_units": "0"}
		w.start_map(id)
		var tried := 0
		var made := 0
		var widths: Array[float] = []
		for r: Dictionary in w.map.get("roads", []):
			var path := w.road_path(String(r["id"]))
			var total := 0.0
			for i in range(1, path.size()):
				total += path[i - 1].distance_to(path[i])
			var s := 0.0
			while s < total:
				var p := _pp(path, s)
				var t := (_pp(path, s + 4.0) - _pp(path, s - 4.0)).normalized()
				s += CORRIDOR_STEP
				if not Rect2(Vector2(20, 20), LegionCfg.WORLD_SIZE - Vector2(40, 40)).has_point(p) \
						or p.distance_to(w.cauldron_pos) < 100.0 or t == Vector2.ZERO \
						or w.terrain.is_rock(p):
					continue
				var nrm := t.orthogonal()
				var lo := _open_run(p, -nrm)
				var hi := _open_run(p, nrm)
				if lo + hi >= CORRIDOR_NARROW or lo >= CORRIDOR_SCAN or hi >= CORRIDOR_SCAN:
					continue
				tried += 1
				widths.append(lo + hi)
				var a := p - nrm * (lo + CORRIDOR_OVER)
				var b := p + nrm * (hi + CORRIDOR_OVER)
				if _drawn_dir(PackedVector2Array([a, b])) != Vector2.ZERO:
					made += 1
		widths.sort()
		var share := float(made) / maxf(1.0, float(tried))
		print("    %-5s узких мест %d (ширина %.0f…%.0f px): линия родилась у %d (%.0f %%)"
			% [id, tried, widths[0] if tried > 0 else 0.0, widths[-1] if tried > 0 else 0.0,
			made, share * 100.0])
		_check(tried > 0 and share >= 0.95,
			"%s: штрих поперёк узкого коридора рождает линию (%.0f %%)" % [id, share * 100.0])
	# широкое место: короткий штрих посреди дороги (не от стены до стены) — по-прежнему не линия
	w.start_map("wasteland")
	_check(_drawn_dir(PackedVector2Array([Vector2(290, 330), Vector2(335, 330)])) == Vector2.ZERO,
		"короткий штрих не от стены до стены (45 px) — по-прежнему не линия")
	w.dev = {}


## Сколько px от p в сторону dir до скалы (не дальше CORRIDOR_SCAN).
func _open_run(p: Vector2, dir: Vector2) -> float:
	var d := 0.0
	while d < CORRIDOR_SCAN and not w.terrain.is_rock(p + dir * (d + 1.0)):
		d += 1.0
	return d


# ── B-083: рождение у двери — от дороги ─────────────────────────────────────

## Все площадки всех 8 карт: 200 рождений на каждой; доля в досягаемости проходящей толпы
## (ближе SPAWN_NEAR к оси дороги). «Проходная» p2 (будка у турникета) — почти все вне её.
func _test_spawn_fan() -> void:
	print("— B-083: рождение у двери — от дороги")
	w.in_campaign = false
	var total := 0
	var near := 0
	for id: String in MAPS:
		w.dev = {"no_waves": "1", "spawn_units": "0"}
		w.start_map(id)
		var m_total := 0
		var m_near := 0
		for plot: Dictionary in w.staff.plots:
			w.souls = 1000
			var b := w.staff.build(plot, LegionCfg.KIND_LABORER)
			if b == null:
				continue
			var p_near := 0
			for i in SPAWN_SAMPLES:
				if w.road_dist(b._spawn_point()) < SPAWN_NEAR:
					p_near += 1
			m_total += SPAWN_SAMPLES
			m_near += p_near
			if id == "gatehouse" and String(plot["id"]) == "p2":
				_check(p_near <= SPAWN_SAMPLES / 20,
					"«Проходная» p2: у проходящей толпы %d из %d рождений" % [p_near, SPAWN_SAMPLES])
		print("    %-9s у дороги (< %.0f px) %4.1f %% рождений" % [id, SPAWN_NEAR,
			100.0 * float(m_near) / maxf(1.0, float(m_total))])
		total += m_total
		near += m_near
	var share := float(near) / maxf(1.0, float(total))
	# до правки — 42 % (замер линии newbie2): веер ронял новичков в досягаемость толпы
	_check(share <= 0.3,
		"по всем картам у дороги рождается не больше 30 %% (%.1f %%)" % (share * 100.0))
	w.dev = {}


# ── B-077: натиск-промах ────────────────────────────────────────────────────

## Бег натиска подрядчика вправо от (300, 360) до конца; мир не тикает — только боец и сетка.
func _run_charge(foes: Array[Vector2]) -> Legionnaire:
	w.dev = {"no_waves": "1", "spawn_units": "0"}
	w.start_map("_plots")
	w.set_process(false)
	for at in foes:
		w.spawn_foe_on_path("zombie", PackedVector2Array([at, at + Vector2(0, 1)]), at)
	var u := w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(300, 360))
	u.start_charge(Vector2.RIGHT)
	for i in int(4.0 * FPS):
		w.now += 1.0 / FPS
		w.grid.rebuild()
		u.tick(1.0 / FPS)
		if u.state != Legionnaire.State.CHARGE:
			break
	w.set_process(true)
	return u


func _test_charge_miss() -> void:
	print("— B-077: натиск-промах не улетает на всю дальность")
	w.in_campaign = false
	# половина дальности (LegionCfg.CHARGE_MISS_FRAC = 0,5) — числом: тест собирается и на старом коде
	var half := 300.0 + LegionCfg.CHARGE_DIST * 0.5
	var empty := _run_charge([])
	_check(empty.state == Legionnaire.State.FREE and empty.position.x <= half + 12.0,
		"пусто впереди — стоп на половине дальности: x = %.0f (было бы 470)" % empty.position.x)
	# колонна идёт в 80 px сбоку — промах мимо колонны
	var side := _run_charge([Vector2(420, 280), Vector2(450, 280), Vector2(480, 280)])
	_check(side.position.x <= half + 12.0,
		"колонна сбоку (в 80 px) — промах, стоп на половине: x = %.0f" % side.position.x)
	# враг впереди на пути, дальше порога выцеливания пехоты (50 px) — бежит и бьёт, как прежде
	var ahead := _run_charge([Vector2(445, 362)])
	_check(ahead.position.x >= 400.0,
		"враг впереди на линии бега — натиск добегает до него: x = %.0f" % ahead.position.x)
	w.dev = {}


# ── B-093: слои боя не рисуются поверх экранов после боя ─────────────────────

## Видимые слои (CanvasLayer) мира: HUD, панель навыков, меню площадки, плашка урока.
static func _layers_on(world: LegionWorld) -> PackedStringArray:
	var out := PackedStringArray()
	for layer: Node in world.find_children("*", "CanvasLayer", true, false):
		if (layer as CanvasLayer).visible:
			out.append(String(layer.name))
	return out


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _test_screens_cover() -> void:
	print("— B-093: панель волн и полоска видов не висят поверх экранов после боя")
	Campaign.reset()
	Campaign.set_intro_cutscene_seen()
	var main := (load("res://scenes/legion.tscn") as PackedScene).instantiate() as LegionMain
	root.add_child(main)
	await _frames(2)
	main.start_battle("wasteland")
	await _frames(2)
	_check(main.world.hud.visible, "в бою HUD виден")
	main.world.force_end(true)
	await _frames(3)
	_check(main.screen is LegionResult, "бой → итог")
	var on := _layers_on(main.world)
	_check(on.is_empty(), "на экране итога слои боя спрятаны (видны: %s)" % ", ".join(on))
	(main.screen as LegionResult).next.emit()
	await _frames(3)
	on = _layers_on(main.world)
	_check(on.is_empty(), "на выборе поправки (%s) слои боя спрятаны (видны: %s)"
		% [main.screen.get_class(), ", ".join(on)])
	main.show_hero(func() -> void: pass)
	await _frames(3)
	on = _layers_on(main.world)
	_check(main.screen is HeroScreen and on.is_empty(),
		"на экране героя слои боя спрятаны (видны: %s)" % ", ".join(on))
	main.start_battle("wasteland")
	await _frames(3)
	on = _layers_on(main.world)
	_check(main.world.hud.visible and on.size() >= 2,
		"новый бой — HUD и панель навыков снова видны (%s)" % ", ".join(on))
	main.queue_free()
	await process_frame


# ── B-094: меню пустой площадки — штат с бонусами ─────────────────────────────

func _test_plot_menu_staff() -> void:
	print("— B-094: меню пустой площадки пишет штат, который получит постройка")
	Campaign.reset()
	# Пул поправок переехал в AmendmentDb: «Партнёр» (outstaff_partner) мигрирует в «Живую
	# очередь» (LEGACY_MAP), а она штат УМЕНЬШАЕТ (−20 %) — прибавляющих карт в новом пуле
	# нет. Контракт меню тот же: пишет фактический штат с поправками, постройка ему равна.
	Campaign.add_upgrade(&"living_queue")
	w.in_campaign = true
	w.mods = Campaign.active_mods()
	w.dev = {"no_waves": "1", "spawn_units": "0"}
	w.start_map("wasteland")
	var plot: Dictionary = w.staff.plots[0]
	w.plot_menu.open(plot, plot["pos"])
	var shown := -1
	for b in w.plot_menu.buttons():
		if b.text.begins_with("Бытовка · штат "):
			shown = int(b.text.trim_prefix("Бытовка · штат ").get_slice(" ", 0))
	w.plot_menu.close()
	w.souls = 1000
	var built := w.staff.build(plot, LegionCfg.KIND_LABORER)
	var got := built.cap if built != null else -1
	var base := LegionStaff.paced(int(LegionCfg.BUILDINGS[LegionCfg.KIND_LABORER]["cap"][0]))
	_check(got < base, "поправка «Живая очередь» меняет штат (%d < %d)" % [got, base])
	_check(shown == got, "меню обещало штат %d — построенная получила %d" % [shown, got])
	w.in_campaign = false
	w.mods = {}
	Campaign.reset()
	w.dev = {}


# ── B-096: поправки — только про открытое ────────────────────────────────────

## После «Пустыря» (открыта «Проходная»: Ку, вахтёр, стрелка, «Сбор») 300 розыгрышей поправок не
## дают карт про закрытые Дубль-вэ и Е («Агентство однодневок», «Ненормированный день» — пул
## теперь AmendmentDb); про открытое Ку карты есть. После «Проходной» (открыты «Два отдела»:
## W и Е) обе снова в пуле. offer() запоминает розыгрыш липким драфтом (draft_options), поэтому
## драфт сбрасывается каждую итерацию — иначе все 300 розыгрышей вернули бы первый.
func _test_upgrade_offers() -> void:
	print("— B-096: поправки не предлагаются до открытия навыка")
	Campaign.reset()
	Campaign.record_result("wasteland", true, 1.0)
	var early := {}
	var rng := RandomNumberGenerator.new()
	for s in 300:
		rng.seed = s
		Campaign.clear_pending_reward()
		for id in Campaign.offer_upgrades(rng):
			early[String(id)] = true
	var wrong: Array[String] = []
	for id: String in ["temp_agency", "overtime_cycle"]:
		if early.has(id):
			wrong.append(id)
	_check(wrong.is_empty(), "после «Пустыря» нет поправок про закрытое (%s)" % ", ".join(wrong))
	_check(early.has("high_voltage") and early.has("carbon_copy"),
		"про открытое Ку (с «Проходной») поправки есть")
	Campaign.record_result("gatehouse", true, 1.0)
	var later := {}
	for s in 300:
		rng.seed = s
		Campaign.clear_pending_reward()
		for id in Campaign.offer_upgrades(rng):
			later[String(id)] = true
	_check(later.has("temp_agency") and later.has("overtime_cycle"),
		"открыты «Два отдела» (Дубль-вэ, Е) — поправки про них в пуле")
	Campaign.reset()


# ── B-097: слово «расчёт» объяснено ──────────────────────────────────────────

## Расчёт объяснён там, где игрок теперь с ним встречается: поправка «Бумажная броня» умножает
## расчёт за срок, «Как играть» даёт отдельную строку о прибавке здоровья. Новая «Контора»
## продаёт пакеты на следующий объект и расчёта не касается; перки героя заменены поправками.
func _test_settlement_word() -> void:
	print("— B-097: «расчёт» объяснён там, где встречается")
	var card := String(AmendmentDb.card(&"paper_shield").get("text", ""))
	_check(card.contains("расчёт"), "поправка «Бумажная броня»: расчёт за срок — «%s»" % card)
	var howto := HowtoLegion.new()
	root.add_child(howto)
	await process_frame
	var line := ""
	for l: Node in howto.find_children("*", "Label", true, false):
		if (l as Label).text.begins_with("Расчёт:"):
			line = (l as Label).text
	for l: Node in howto.find_children("*", "RichTextLabel", true, false):
		if (l as RichTextLabel).text.begins_with("Расчёт:"):
			line = (l as RichTextLabel).text
	_check(not line.is_empty(), "«Как играть»: строка «Расчёт: …»")
	_check(line.contains("здоров"), "«Как играть»: что такое расчёт — «%s»" % line)
	_check(line.contains("Бумажная броня") and not line.contains("перком"),
		"«Как играть»: расчёт усиливает поправка, а не убранная покупка — «%s»" % line)
	howto.queue_free()


# ── B-072: полоска предметов — «+N» вместо молча скрытых ─────────────────────

func _test_item_overflow() -> void:
	print("— B-072: больше 24 значков — последний слот «+N»")
	w.dev = {"no_waves": "1", "spawn_units": "0"}
	w.start_map("wasteland")
	var bar := w.hud.get_node("ItemBar") as LegionItemBar
	for id in LegionItemDb.ids():
		w.items.grant(id)
	var cap := CfgItems.BAR_PER_ROW * CfgItems.BAR_MAX_ROWS
	# v2 сократил каталог до 13 артефактов: выдача всего каталога больше не создаёт переполнение.
	# Проверяем защиту полоски отдельной UI-фикстурой с валидными id, независимо от баланса.
	var ids := LegionItemDb.ids()
	while bar.shown.size() + bar.shown_synergies.size() <= cap + 2:
		bar.shown.append(ids[bar.shown.size() % ids.size()])
	var total := bar.shown.size() + bar.shown_synergies.size()
	var last := String(bar.slot_info(cap - 1)["title"])
	var more := int(bar.call("overflow")) if bar.has_method("overflow") else 0
	_check(total > cap, "значков больше, чем слотов (%d > %d)" % [total, cap])
	_check(last.begins_with("Ещё") and (cap - 1) + more == total,
		"последний слот — «%s»: видно %d + в «Ещё» %d = все %d" % [last, cap - 1, more, total])
	w.dev = {}


# ── B-073: ложная восьмёрка ─────────────────────────────────────────────────

func _jit(p: Vector2, j: float) -> Vector2:
	return p + Vector2(_rng.randf_range(-j, j), _rng.randf_range(-j, j))


## «S-дуга и прямой возврат к началу» (как в legion_runes_test): полукруг вверх, полукруг вниз,
## прямая назад; точки через ~6 px с дрожью jit.
func _s_return(jit: float) -> PackedVector2Array:
	var o := Vector2(500, 380)
	var r := _rng.randf_range(40.0, 60.0)
	var rot := _rng.randf_range(0.0, TAU)
	var pts := PackedVector2Array()
	for i in 27:
		var a := PI - PI * i / 26.0
		pts.append(Vector2(-r, 0) + Vector2(cos(a), -sin(a)) * r)
	for i in range(1, 27):
		var a := PI - PI * i / 26.0
		pts.append(Vector2(r, 0) + Vector2(cos(a), sin(a)) * r)
	var end := pts[pts.size() - 1]
	var n := ceili(end.distance_to(pts[0]) / 6.0)
	for k in range(1, n + 1):
		pts.append(end.lerp(pts[0], float(k) / n))
	var out := PackedVector2Array()
	for p in pts:
		out.append(_jit(o + p.rotated(rot), jit))
	return out


## Восьмёрка рукой: петли сверху и снизу (как в скилле corr-play), размер и наклон случайные.
func _hand_eight(jit: float) -> PackedVector2Array:
	var o := Vector2(640, 380)
	var sx := _rng.randf_range(50.0, 75.0)
	var sy := _rng.randf_range(75.0, 105.0)
	var rot := _rng.randf_range(-0.5, 0.5)
	var out := PackedVector2Array()
	var t := 0.0
	while t <= TAU + 0.001:
		out.append(_jit(o + Vector2(sx * sin(t) * cos(t), sy * sin(t)).rotated(rot), jit))
		t += 0.1
	return out


func _test_false_eight() -> void:
	print("— B-073: «S-дуга + прямой возврат» с дрожью — не восьмёрка")
	_rng.seed = 77
	for jit: float in [1.5, 2.0]:
		var hits := 0
		for i in 50:
			hits += 1 if ContractShape.classify(_s_return(jit)) == ContractShape.EIGHT else 0
		_check(hits <= 2, "дрожь %.1f px: каракуля признана восьмёркой %d из 50" % [jit, hits])
	var ok := 0
	var t0 := Time.get_ticks_usec()
	for i in 60:
		ok += 1 if ContractShape.classify(_hand_eight(2.0)) == ContractShape.EIGHT else 0
	var ms := float(Time.get_ticks_usec() - t0) / 1000.0 / 60.0
	_check(ok >= 57, "настоящие восьмёрки рукой (дрожь 2 px) признаются: %d из 60 (%.2f мс)"
		% [ok, ms])


# ── B-086: золото не обещает удара, которого не будет ────────────────────────

## Участок с одним стоящим бойцом на краю, зомби в зоне «Точно!» у другого края: узкий конус
## пехоты (±CHARGE_SEEK) его не возьмёт — участок не золотой. Боец напротив зомби — золотой.
func _test_gold_taken() -> void:
	print("— B-086: золото — только если врага зоны кто-то возьмёт")
	w.dev = {"no_waves": "1", "spawn_units": "0"}
	w.start_map("_plots")
	w.set_process(false)
	var pts := PackedVector2Array([Vector2(560, 400), Vector2(624, 400)])
	var c := w.contracts.add_contract(pts, w.contracts.default_side(pts), false)
	c.ttl = 999.0
	var s := 0
	var center := c.seg_center(s)
	var side := c.dir.orthogonal()
	var half := w.contracts.seg_half_len(c, s)
	# место строя дальше всех от края +side
	var post: Dictionary = {}
	for p: Dictionary in c.posts:
		if int(p["seg"]) == s and (post.is_empty()
				or (p["pos"] as Vector2).dot(side) < (post["pos"] as Vector2).dot(side)):
			post = p
	var u := w.spawn_unit(LegionCfg.KIND_LABORER, post["pos"])
	u.contract = c
	u.post = post
	post["unit"] = u
	u.state = Legionnaire.State.POSTED
	var at := center + side * (half + 4.0) + c.dir * 50.0
	var z := w.spawn_foe_on_path("zombie", PackedVector2Array([at, at + side]), at)
	z.speed = 0.0
	w.grid.rebuild()
	var far_gold := w.contracts.seg_gold(c, s)
	# тот же зомби напротив бойца — золото есть
	z.position = Vector2(post["pos"]).dot(side) * side + center.dot(c.dir) * c.dir + c.dir * 50.0
	w.grid.rebuild()
	var near_gold := w.contracts.seg_gold(c, s)
	_check(not far_gold, "зомби у дальнего края зоны, боец у ближнего — не золото")
	_check(near_gold, "зомби напротив бойца — золото (%s)" % z.position)
	w.set_process(true)
	w.dev = {}


# ── B-081: урок посреди боя не глушит советы до конца боя ────────────────────

## «Проходная»: урок «пружина» стоит (участок держат прогнутым), игрок его не делает. Первые
## секунды урока советы молчат все; через 10 с совет «Ку» (не про пружину) снова показывается, а
## «сорви — ударит сильнее» и «Е» (спорят с уроком) — нет.
func _test_lesson_advice() -> void:
	print("— B-081: непройденный урок глушит только спорящие советы")
	Settings.hints_override = "on"   # советы включены, файл настроек не трогаем
	Campaign.reset()
	Campaign.unlock_all()
	w.in_campaign = true
	w.dev = {"difficulty": "intern", "no_waves": "1"}
	w.args.erase("bot")
	w.start_map("gatehouse")
	w.start_lessons(true)
	var tut := w.tutorial
	await process_frame
	tut._passed[&"aim"] = true
	tut._passed[&"erase"] = true
	tut._passed[&"rally"] = true
	tut._next()
	var bl: Dictionary = (w.map["bot_lines"] as Array)[2]
	var pts := PackedVector2Array([Vector2(float(bl["a"][0]), float(bl["a"][1])),
		Vector2(float(bl["b"][0]), float(bl["b"][1]))])
	var c := w.contracts.add_contract(pts, w.contracts.default_side(pts), false)
	c.ttl = 999.0
	var bend := func() -> void:
		if is_instance_valid(c) and c.seg_alive(0):
			c.seg_bend[0] = LegionCfg.PRESS_BREAK * 0.6
	for i in int(1.0 * FPS):
		bend.call()
		w._step(1.0 / FPS)
	_check(tut.step_id() == &"spring", "урок «пружина» на плашке (%s)" % tut.step_id())
	var intuit := w.intuit
	intuit.call("_offer", &"q", 0, Vector2(400, 300), "Ку — тест")
	var early := intuit.hints_shown(&"q")
	for i in int(10.0 * FPS):
		bend.call()
		w._step(1.0 / FPS)
	_check(tut.step_id() == &"spring", "через 10 с урок всё ещё стоит (игрок его не делает)")
	intuit.call("_offer", &"q", 0, Vector2(400, 300), "Ку — тест")
	intuit.call("_offer", &"spring", -1, Vector2(400, 300), "сорви — тест")
	intuit.call("_offer", &"e", 2, Vector2(400, 300), "Е — тест")
	_check(early == 0, "первые секунды урока — совет «Ку» молчит")
	_check(intuit.hints_shown(&"q") == 1, "через 10 с совет «Ку» снова показан (%d)"
		% intuit.hints_shown(&"q"))
	_check(intuit.hints_shown(&"spring") == 0 and intuit.hints_shown(&"e") == 0,
		"советы «сорви» и «Е» (спорят с уроком «пружина») молчат")
	Settings.hints_override = ""
	w.in_campaign = false
	w.dev = {}
	Campaign.reset()


# ── B-078: затишье — подсказать F ─────────────────────────────────────────────

## «Два отдела» (fork) без бота: до первого контакта колонны идут змейкой ~50 с. Совет «F» должен
## появиться в затишье, а после вызова волны (F) — больше не появляться.
func _test_lull_hint() -> void:
	print("— B-078: затишье до первого контакта — совет «F»")
	Settings.hints_override = "on"
	w.in_campaign = false
	w.dev = {}
	w.args.erase("bot")
	w.start_map("fork")
	var intuit := w.intuit
	var first := -1.0
	for i in int(45.0 * FPS):
		w._step(1.0 / FPS)
		if i % 6 == 0:
			intuit.scan()
		if first < 0.0 and intuit.hints_shown(&"call") > 0:
			first = w.now
	_check(first > 0.0, "совет «F» в затишье показан (на %.0f с боя)" % first)
	var before := intuit.hints_shown(&"call")
	w.call_wave()
	for i in int(30.0 * FPS):
		w._step(1.0 / FPS)
		if i % 6 == 0:
			intuit.scan()
	_check(intuit.hints_shown(&"call") == before, "после вызова волны совет «F» больше не показан")
	Settings.hints_override = ""


# ── B-124: печати у двери — совет ────────────────────────────────────────────

## «Два отдела»: Бытовка на средней площадке, рядом нотариус, у двери за секунды легли трое —
## совет «сорви строй на нотариуса» у постройки. Без нотариуса рядом — совета нет.
func _test_door_hint() -> void:
	print("— B-124: печати выкашивают бойцов у двери — совет")
	Settings.hints_override = "on"
	w.dev = {"no_waves": "1", "spawn_units": "0"}
	w.start_map("fork")
	w.souls = 1000
	var b := w.staff.build(w.staff.plots[1], LegionCfg.KIND_LABORER)
	var intuit := w.intuit
	for i in 3:
		var u := w.spawn_unit(LegionCfg.KIND_LABORER, b.entry + Vector2(8.0 * i, 12.0))
		u.take_damage(u.hp + 1.0, u.position)
	intuit.scan()
	var without := intuit.hints_shown(&"door")
	var at := b.entry + Vector2(180.0, 0.0)
	w.spawn_foe_on_path("signer", PackedVector2Array([at, at + Vector2(1, 0)]), at)
	intuit.scan()
	_check(without == 0, "трое легли, нотариуса рядом нет — совета нет")
	_check(intuit.hints_shown(&"door") == 1, "нотариус в 180 px — совет у постройки показан (%d)"
		% intuit.hints_shown(&"door"))
	Settings.hints_override = ""
	w.dev = {}


# ── B-083 (verifier): рождение не за препятствием ─────────────────────────────

## Все площадки 8 карт, по REACH_SAMPLES рождений: ни одного, до которого от двери пешком
## заметно дальше, чем по прямой, и ни одного за краем карты («Проходная» p4: за скальной
## полосой у нижнего края — 45 px по прямой, ~1019 пешком, 6 % рождений).
func _test_spawn_reach() -> void:
	print("— B-083: рождение у двери не за препятствием")
	w.in_campaign = false
	var bad := 0
	var total := 0
	var example := ""
	var field := Rect2(Vector2.ZERO, LegionCfg.WORLD_SIZE)
	for id: String in MAPS:
		w.dev = {"no_waves": "1", "spawn_units": "0"}
		w.start_map(id)
		for plot: Dictionary in w.staff.plots:
			w.souls = 1000
			var b := w.staff.build(plot, LegionCfg.KIND_LABORER)
			if b == null:
				continue
			var seen := {}
			for i in REACH_SAMPLES:
				var p := b._spawn_point()
				total += 1
				var key := Vector2i(roundi(p.x / 4.0), roundi(p.y / 4.0))
				if seen.has(key):
					if not bool(seen[key]):
						bad += 1
					continue
				var ok := field.has_point(p)
				if ok:
					var path := w.contracts.recruit_path(b.entry, p)
					var walk := 0.0
					var prev := b.entry
					for q in path:
						walk += prev.distance_to(q)
						prev = q
					ok = not path.is_empty() and walk <= b.entry.distance_to(p) * REACH_K + REACH_PAD
				seen[key] = ok
				if not ok:
					bad += 1
					if example == "":
						example = "%s %s: %s" % [id, plot["id"], p]
	_check(bad == 0, "рождений с обходом или за краем: %d из %d %s" % [bad, total, example])
	w.dev = {}
