extends SceneTree
## Приёмка v17 LAW (docs/legion/DESIGN_V17.md §3): Юрист рвёт участок договора, телеграф печати.
## Настоящий мир, изолированное сохранение; время ведём сами — тикаем только проверяемого врага,
## чтобы бойцы не убили Юриста раньше, чем проверка дойдёт до конца зачитки.

const SAVE := "user://legion_lawyer_test.cfg"
const DT := 1.0 / 60.0
var w: LegionWorld
var checks := 0
var fails := 0
var released := 0
var torn: Array = []


func _initialize() -> void:
	_run.call_deferred()


func check(ok: bool, text: String) -> void:
	checks += 1
	if not ok:
		fails += 1
	print("  %s %s" % ["ok" if ok else "FAIL", text])


func fresh() -> void:
	w.dev["spawn_units"] = "0"
	w.dev["no_waves"] = "1"
	w.start_map("wasteland")
	w.set_process(false)
	w.terrain = LegionTerrain.new().setup({})
	w.grid.rebuild()
	w.dev_invuln = false
	w.contracts.active = true
	released = 0
	torn.clear()


## Вертикальная линия 128 px — два участка: seg0 сверху, seg1 снизу.
func line_at(at: Vector2, length := 128.0) -> Contract:
	return w.contracts.add_contract(PackedVector2Array([at, at + Vector2(0, length)]), 1, false)


func man(c: Contract, seg: int) -> Array[Legionnaire]:
	var units: Array[Legionnaire] = []
	for p in c.posts:
		if int(p["seg"]) != seg:
			continue
		var u := w.spawn_unit(c.kind, p["pos"])
		u.assign(c, p)
		u._arrive()
		units.append(u)
	return units


func lawyer(at: Vector2) -> Foe:
	return w.spawn_foe_on_path("lawyer", PackedVector2Array([at, w.cauldron_pos]), at)


## Тикаем одного врага; до условия или до limit секунд. Возвращает прошедшее время.
func run_until(f: Foe, cond: Callable, limit: float) -> float:
	var t := 0.0
	while t < limit and not bool(cond.call()):
		w.grid.rebuild()
		f.tick(DT)
		t += DT
	return t


func _run() -> void:
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	w = (load("res://scenes/legion_world.tscn") as PackedScene).instantiate() as LegionWorld
	w.embedded = true
	root.add_child(w)
	root.size = Vector2i(1280, 720)
	await process_frame
	w.segment_released.connect(func(_c: Contract, _s: int, _n: int) -> void: released += 1)
	w.segment_torn.connect(func(c: Contract, s: int, n: int) -> void: torn.append([c, s, n]))
	test_config()
	test_pick_and_tear()
	await test_draw()
	test_interrupt()
	test_range_and_cauldron()
	test_stamp_telegraph()
	print("LEGION LAWYER: %d/%d OK" % [checks - fails, checks])
	quit(1 if fails else 0)


func test_config() -> void:
	var d: Dictionary = LegionCfg.FOES["lawyer"]
	check(d["hp"] == 45.0 and d["speed"] == 42.0 and d["dmg"] == 5.0 and d["cd"] == 1.2,
		"Юрист: HP 45, скорость 42, урон 5 / 1.2 с")
	check(int(LegionCfg.SOULS_PER_FOE["lawyer"]) == 6, "Юрист даёт 6 душ")
	check(LegionWorld.foe_caption("lawyer").contains("Юрист"), "превью волны называет его «Юрист»")
	check(Briefing.FOE_NAMES.get("lawyer", "") == "Юрист", "брифинг называет его «Юрист»")
	for id in ["wasteland", "fork"]:
		check(not JSON.stringify(LegionWorld.load_map(id)["waves"]).contains("lawyer"),
			"%s — без Юриста" % id)
	for id in ["bridge", "maze", "swamp", "boss"]:
		var waves: Array = LegionWorld.load_map(id)["waves"]
		var first := -1
		var most := 0
		for i in waves.size():
			var n := 0
			for g: Dictionary in waves[i]["groups"]:
				if g["type"] == "lawyer":
					n += int(g["count"])
			if n > 0 and first < 0:
				first = i
			most = maxi(most, n)
		check(first >= int(waves.size() / 2.0) - 1 and first > 0 and most <= 2,
			"%s: Юрист с середины, не больше 2 за волну (с волны %d)" % [id, first + 1])


func test_pick_and_tear() -> void:
	fresh()
	var near := line_at(Vector2(600, 200))          # seg1 — центр (600, 296)
	var far := line_at(Vector2(900, 200))
	var squad := man(near, 1)
	var f := lawyer(Vector2(540, 330))
	w.grid.rebuild()
	f.tick(DT)
	check(f.law_c == near and f.law_seg == 1, "выбрал ближайший живой участок")
	check(f.law_pos.is_equal_approx(near.seg_center(1)), "точка цели — середина участка")
	var t := run_until(f, func() -> bool: return f.law_read_t >= 0.0, 5.0)
	check(f.law_read_t >= 0.0 and f.position.distance_to(f.law_pos) <= LegionCfg.LAWYER_REACH,
		"дошёл до участка и зачитывает (%.2f с пути)" % t)
	var charges := int(w.stats["charges"])
	var read := run_until(f, func() -> bool: return not near.seg_alive(1), 3.0)
	check(absf(read - LegionCfg.LAWYER_READ_TIME) <= DT * 2.0,
		"зачитка %.2f с ≈ %.1f с" % [read, LegionCfg.LAWYER_READ_TIME])
	check(not near.seg_alive(1) and near.release_causes.get(1) == &"torn", "участок расторгнут (torn)")
	check(near.seg_alive(0) and far.seg_alive(0), "соседний участок и дальний договор целы")
	var all_free := not squad.is_empty()
	for u in squad:
		all_free = all_free and u.alive and u.state == Legionnaire.State.FREE and u.contract == null
	check(all_free, "бойцы участка (%d) свободны" % squad.size())
	check(int(w.stats["charges"]) == charges and released == 0,
		"натиска нет, segment_released не было")
	check(torn.size() == 1 and torn[0][2] == squad.size(), "segment_torn с числом освобождённых")
	for p in near.posts:
		if int(p["seg"]) == 1:
			check(bool(p["dead"]) and p["unit"] == null, "места участка погасли")
			break
	check(int(w.stats.get("segments_torn", 0)) == 1, "счёт segments_torn")
	w.grid.rebuild()
	f.tick(DT)
	check(f.law_c == near and f.law_seg == 0, "потом — следующая цель (соседний участок)")


## Телеграф рисуется без ошибок во всех фазах (пунктир, печать, кольцо, разрыв, печать нотариуса).
func test_draw() -> void:
	fresh()
	var c := line_at(Vector2(600, 200))
	var f := lawyer(Vector2(560, 330))
	run_until(f, func() -> bool: return f.law_c != null, 1.0)
	w._fx.queue_redraw()
	await process_frame
	run_until(f, func() -> bool: return f.law_read_t >= 0.0, 5.0)
	w._fx.queue_redraw()
	await process_frame
	w.tear_segment(c, 0)
	w._fx.queue_redraw()
	await process_frame
	check(w._tears.size() == 1, "вспышка разрыва в очереди отрисовки")
	w._tick_impacts(LegionCfg.LAWYER_TEAR_FX + 0.01)
	check(w._tears.is_empty(), "вспышка разрыва гаснет")


func test_interrupt() -> void:
	fresh()
	var c := line_at(Vector2(600, 200))
	var f := lawyer(Vector2(560, 330))
	run_until(f, func() -> bool: return f.law_read_t >= 0.0, 5.0)
	# за 60 % срока зачитки (v20: срок 2,2 с вместо 1,8 — прежняя 1 с была уже меньше половины)
	run_until(f, func() -> bool: return false, LegionCfg.LAWYER_READ_TIME * 0.6)
	check(f.law_read_progress() > 0.5, "зачитка идёт (%.2f)" % f.law_read_progress())
	f.take_damage(1000.0, f.position + Vector2.RIGHT)
	for i in 180:
		f.tick(DT)
	check(c.seg_alive(1) and torn.is_empty(), "убит во время чтения — участок цел")
	check(int(w.stats.get("lawyer_interrupts", 0)) == 1, "счёт прерванных зачиток")


func test_range_and_cauldron() -> void:
	fresh()
	var out := line_at(Vector2(1000, 200))
	var f := lawyer(Vector2(600, 400))
	check(f.position.distance_to(out.seg_center(0)) > LegionCfg.LAWYER_SEEK_R, "договор дальше 360 px")
	var d0 := f.position.distance_to(w.cauldron_pos)
	run_until(f, func() -> bool: return false, 2.0)
	check(f.law_c == null, "дальше 360 px участок не выбран")
	check(f.position.distance_to(w.cauldron_pos) < d0 - 60.0, "без договоров рядом идёт к Котлу")
	w.contracts.dismiss(out)
	var hp := w.cauldron_hp
	run_until(f, func() -> bool: return not f.alive, 30.0)
	check(not f.alive and is_equal_approx(hp - w.cauldron_hp, 8.0), "дошёл до Котла: урон 8")


func test_stamp_telegraph() -> void:
	fresh()
	var at := Vector2(700, 300)
	var s := w.spawn_foe_on_path("signer", PackedVector2Array([at]), at)
	s.stamp_pos = at + Vector2.LEFT * 150
	s.stamp_t = LegionCfg.SIGNER_WARN
	var t := 0.0
	var shown := -1.0
	var last_k := -1.0
	var grows := true
	var hits := int(w.stats["stamp_hits"])
	var victim := w.spawn_unit(LegionCfg.KIND_LABORER, s.stamp_pos)
	while s.stamp_t >= 0.0 and t < 3.0:
		var k := s.stamp_telegraph()
		if k >= 0.0 and shown < 0.0:
			shown = t
		if k >= 0.0:
			grows = grows and k >= last_k
			last_k = k
		w.grid.rebuild()
		s._tick_stamp(DT)
		t += DT
	var lead := t - shown
	check(shown >= 0.0 and absf(lead - LegionCfg.STAMP_TELEGRAPH) <= DT * 1.5,
		"круг печати появляется за %.2f с до удара (нужно 0.6)" % lead)
	check(grows and last_k > 0.95, "круг растёт до stamp_r к моменту удара")
	check(s.stamp_telegraph() < 0.0, "после удара круга нет")
	check(int(w.stats["stamp_hits"]) > hits and victim.hp < float(victim.spec["hp"]),
		"удар печати пришёлся в точку круга")
