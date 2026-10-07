extends SceneTree
##
## v20 «навыки обязательны» (сессия 9ef4ccac, 26.09.2026; Игорь: «обязательно надо было
## использовать скиллы», «механику с юристами я не понял»):
##   1) Ку оглушает каждую цель цепи — оглушённый стоит и не давит строй; по призраку — вдвое;
##   2) оглушение срывает зачитку Юриста (читает заново) и печать нотариуса в замахе;
##   3) Юрист идёт к самому людному участку, а не к ближайшему пустому;
##   4) строй Юриста не бьёт (но соседа-зомби бьёт как раньше);
##   5) расторгнутые Юристом бойцы «в отказе» — оглушены;
##   6) натиск по оглушённому — сильнее.
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_action_test.gd -- --mute
##
## Итог «LEGION ACTION: N/M OK»; код выхода 1, если что-то упало. Мир настоящий, сохранение
## временное; время ведём сами (тикаем только тех, кого проверяем), рельеф — плоский.
##

const SAVE := "user://legion_action_test.cfg"
const DT := 1.0 / 60.0

var w: LegionWorld
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
	w = (load("res://scenes/legion_world.tscn") as PackedScene).instantiate() as LegionWorld
	w.embedded = true
	root.add_child(w)
	root.size = Vector2i(1280, 720)
	await process_frame
	_test_q_stuns()
	_test_q_ghost()
	_test_stun_breaks_reading()
	_test_stun_breaks_stamp()
	_test_lawyer_picks_crowd()
	_test_posted_spare_lawyer()
	_test_tear_stuns()
	_test_press_ignores_stunned()
	_test_charge_on_stunned()
	_test_w_brigade()
	_test_corpse_dupes()
	_test_e_braces_line()
	_test_ring_gap_paid()
	Campaign.reset()
	print("LEGION ACTION: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


func _fresh() -> void:
	w.dev["spawn_units"] = "0"
	w.dev["no_waves"] = "1"
	w.start_map("wasteland")
	w.set_process(false)
	w.terrain = LegionTerrain.new().setup({})
	w.grid.rebuild()
	w.dev_invuln = false
	w.contracts.active = true
	w.hero.reset()


## Враг на пути к Котлу, стоит в точке at (путь — к Котлу).
func _foe(type: String, at: Vector2) -> Foe:
	return w.spawn_foe_on_path(type, PackedVector2Array([at, w.cauldron_pos]), at)


## Вертикальная линия 128 px — два участка: seg0 сверху, seg1 снизу.
func _line(at: Vector2, length := 128.0) -> Contract:
	return w.contracts.add_contract(PackedVector2Array([at, at + Vector2(0, length)]), 1, false)


func _man(c: Contract, seg: int) -> Array[Legionnaire]:
	var units: Array[Legionnaire] = []
	for p in c.posts:
		if int(p["seg"]) != seg:
			continue
		var u := w.spawn_unit(c.kind, p["pos"])
		u.assign(c, p)
		u._arrive()
		units.append(u)
	return units


func _tick_foe(f: Foe, seconds: float) -> void:
	var t := 0.0
	while t < seconds:
		w.grid.rebuild()
		f.tick(DT)
		t += DT


func _q_dmg(i: int) -> float:
	return float(LegionCfg.Q_CHAIN_DMG[i])


func _test_q_stuns() -> void:
	print("— Ку оглушает цепь")
	_fresh()
	var a := _foe("zombie", Vector2(700, 300))
	var b := _foe("zombie", Vector2(730, 310))
	w.grid.rebuild()
	_check(w.hero.cast(LegionHero.SLOT_Q, a.position), "Ку состоялся")
	_check(a.is_stunned() and b.is_stunned(), "обе цели оглушены")
	_check(absf(a.stun_t - LegionCfg.Q_STUN) < 0.001, "оглушение %.2f с" % a.stun_t)
	var p0 := a.position
	_tick_foe(a, LegionCfg.Q_STUN * 0.8)
	_check(a.position.distance_to(p0) < 0.01, "оглушённый стоит")
	_tick_foe(a, LegionCfg.Q_STUN)
	_check(not a.is_stunned() and a.position.distance_to(p0) > 5.0,
		"очнулся и пошёл (%.1f px)" % a.position.distance_to(p0))
	var boss := _foe("boss", Vector2(400, 500))
	boss.stun(LegionCfg.Q_STUN)
	_check(absf(boss.stun_t - LegionCfg.Q_STUN * LegionCfg.Q_STUN_BOSS_MULT) < 0.001,
		"босс оглушён на долю (%.2f с)" % boss.stun_t)


func _test_q_ghost() -> void:
	print("— Ку по призраку вдвое")
	_fresh()
	var g := _foe("ghost", Vector2(700, 300))
	var z := _foe("zombie", Vector2(1100, 600))    # вне цепи: цепь ищет соседей по всей карте
	g.hp = 500.0                                   # толстый, чтобы урон считался без отсечки смертью
	w.grid.rebuild()
	w.hero.cast(LegionHero.SLOT_Q, g.position)
	var want := _q_dmg(0) * LegionCfg.Q_GHOST_MULT
	_check(absf((500.0 - g.hp) - want) < 0.01,
		"урон призраку %.1f (нужно %.1f)" % [500.0 - g.hp, want])
	_check(absf((z.max_hp - z.hp) - _q_dmg(1)) < 0.01, "зомби вторым в цепи — обычный урон %.1f"
		% (z.max_hp - z.hp))


func _test_stun_breaks_reading() -> void:
	print("— Ку срывает зачитку Юриста")
	_fresh()
	var c := _line(Vector2(600, 200))
	var f := _foe("lawyer", Vector2(560, 330))
	var t := 0.0
	while f.law_read_t < 0.0 and t < 6.0:
		_tick_foe(f, DT)
		t += DT
	_check(f.law_read_t >= 0.0, "Юрист дошёл и читает")
	_tick_foe(f, LegionCfg.LAWYER_READ_TIME * 0.6)
	var interrupts := int(w.stats.get("lawyer_interrupts", 0))
	f.stun(LegionCfg.Q_STUN)
	_check(f.law_read_t < 0.0 and f.alive, "зачитка сорвана, Юрист жив")
	_check(int(w.stats.get("lawyer_interrupts", 0)) == interrupts + 1, "счёт прерванных зачиток")
	# дочитать прежний остаток уже нельзя: после оглушения — заново, целиком
	_tick_foe(f, LegionCfg.Q_STUN + LegionCfg.LAWYER_READ_TIME * 0.6)
	_check(c.seg_alive(f.law_seg if f.law_seg >= 0 else 1), "через прежний остаток участок ещё цел")
	_tick_foe(f, LegionCfg.LAWYER_READ_TIME)
	_check(int(w.stats.get("segments_torn", 0)) == 1, "дочитал заново — расторг")


func _test_stun_breaks_stamp() -> void:
	print("— Ку сбивает печать в замахе")
	_fresh()
	var at := Vector2(700, 300)
	var s := w.spawn_foe_on_path("signer", PackedVector2Array([at]), at)
	var victim := w.spawn_unit(LegionCfg.KIND_LABORER, at + Vector2.LEFT * 150)
	s.stamp_pos = victim.position
	s.stamp_t = LegionCfg.SIGNER_WARN
	s.stun(LegionCfg.Q_STUN)
	var hits := int(w.stats["stamp_hits"])
	# окно — оглушение плюс весь замах: без отмены замах дотикал бы после оглушения и печать упала
	# бы внутри окна (verifier 26.09: окно SIGNER_WARN + 0,1 мутацию «без отмены» не ловило);
	# новая печать внутри окна не начнётся — откат печати (stamp_cd) дольше
	_tick_foe(s, LegionCfg.Q_STUN + LegionCfg.SIGNER_WARN + 0.3)
	_check(int(w.stats["stamp_hits"]) == hits and victim.hp == float(victim.spec["hp"]),
		"печать не упала")
	_check(int(w.stats.get("stamps_broken", 0)) == 1, "счёт сбитых печатей")


func _test_lawyer_picks_crowd() -> void:
	print("— Юрист идёт к людному участку")
	_fresh()
	var near := _line(Vector2(600, 200))          # пустая, ближе
	var crowd := _line(Vector2(860, 200))         # людная, дальше
	_man(crowd, 1)
	var f := _foe("lawyer", Vector2(560, 300))
	w.grid.rebuild()
	f.tick(DT)
	_check(f.law_c == crowd and f.law_seg == 1,
		"выбран людный участок (%s)" % ("людный" if f.law_c == crowd else "пустой ближний"))
	_check(near.seg_alive(0), "пустой ближний не тронут")


func _test_posted_spare_lawyer() -> void:
	print("— строй Юриста не бьёт, соседа — бьёт")
	_fresh()
	var c := _line(Vector2(600, 200))
	var squad := _man(c, 1)
	var f := _foe("lawyer", c.seg_center(1) + Vector2(4, 0))
	f.speed = 0.0
	var z := _foe("zombie", c.seg_center(1) + Vector2(10, 18))
	z.speed = 0.0
	var hp_l := f.hp
	var hp_z := z.hp
	for i in roundi(2.0 / DT):
		w.grid.rebuild()
		for u in squad:
			u.tick(DT)
	_check(f.hp == hp_l, "Юрист цел (%.0f/%.0f)" % [f.hp, hp_l])
	_check(z.hp < hp_z, "зомби рядом бьют (%.0f/%.0f)" % [z.hp, hp_z])


func _test_tear_stuns() -> void:
	print("— расторгнутые «в отказе»")
	_fresh()
	var c := _line(Vector2(600, 200))
	var squad := _man(c, 1)
	w.tear_segment(c, 1)
	var all_stunned := not squad.is_empty()
	for u in squad:
		all_stunned = all_stunned and u.is_stunned()
	_check(all_stunned, "все %d оглушены" % squad.size())


func _test_press_ignores_stunned() -> void:
	print("— оглушённый не давит строй")
	_fresh()
	var c := _line(Vector2(600, 200))
	_man(c, 1)
	# зомби у участка seg1, идёт на него (с востока на запад — к линии)
	var z := w.spawn_foe_on_path("zombie", PackedVector2Array([Vector2(630, 296), Vector2(300, 296)]),
		Vector2(630, 296))
	z._dir = Vector2.LEFT
	w.grid.rebuild()
	w.grid.press_scan(c, LegionCfg.PRESS_BAND)
	var before := c.press_mass[1]
	z.stun(LegionCfg.Q_STUN)
	w.grid.press_scan(c, LegionCfg.PRESS_BAND)
	_check(before > 0.0 and c.press_mass[1] == 0.0,
		"масса давки %.2f → %.2f" % [before, c.press_mass[1]])


func _test_charge_on_stunned() -> void:
	print("— натиск по оглушённому сильнее")
	var dmg: Array[float] = []
	for stunned in [false, true]:
		_fresh()
		var z := _foe("zombie", Vector2(700, 300))
		z.speed = 0.0
		if stunned:
			z.stun(60.0)
		var u := w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(640, 300))
		u.start_charge(Vector2.RIGHT)
		var hp0 := z.hp
		for i in roundi(2.0 / DT):
			w.grid.rebuild()
			u.tick(DT)
			if z.hp < hp0:
				break
		dmg.append(hp0 - z.hp)
	_check(dmg[0] > 0.0 and absf(dmg[1] - dmg[0] * LegionCfg.STUNNED_CHARGE_MULT) < 0.01,
		"удар с разбега %.1f → %.1f (×%.1f)" % [dmg[0], dmg[1], LegionCfg.STUNNED_CHARGE_MULT])


func _test_w_brigade() -> void:
	print("— Дубль-вэ поднимает бригаду")
	_fresh()
	var at := Vector2(700, 300)
	var dead: Array[Foe] = []
	for off: Vector2 in [Vector2(10, 0), Vector2(-20, 15), Vector2(0, -30), Vector2(30, 30),
			Vector2(250, 0)]:
		var z := _foe("zombie", at + off)
		z.take_damage(1000.0, z.position + Vector2.RIGHT)
		dead.append(z)
	_check(w.hero.cast(LegionHero.SLOT_W, at), "Дубль-вэ состоялся")
	_check(w.hero.vassal_count() == LegionCfg.W_RAISE_MAX,
		"поднято %d (нужно %d)" % [w.hero.vassal_count(), LegionCfg.W_RAISE_MAX])
	_check(is_instance_valid(dead[4]) and dead[4].is_fresh_corpse(), "дальний труп не тронут")
	_check(is_instance_valid(dead[3]) and dead[3].is_fresh_corpse(),
		"четвёртый ближний — сверх бригады — остался")


## Труп бывает и в world.foes, и в world._corpses — поднимается один раз (verifier 26.09: не было
## проверки).
func _test_corpse_dupes() -> void:
	print("— Дубль-вэ: труп в двух списках — один внештатник")
	_fresh()
	var z := _foe("zombie", Vector2(700, 300))
	z.take_damage(1000.0, z.position + Vector2.RIGHT)
	if not w._corpses.has(z):
		w._corpses.append(z)
	_check(w.foes.has(z) and w._corpses.has(z), "труп в обоих списках")
	_check(w.hero.fresh_corpses(z.position, LegionCfg.W_RAISE_RADIUS, 5).size() == 1,
		"fresh_corpses видит его один раз")
	w.hero.cast(LegionHero.SLOT_W, z.position)
	_check(w.hero.vassal_count() == 1, "поднят один внештатник (%d)" % w.hero.vassal_count())


## Замыкание кольца «Оцепление» платится, как штрих (verifier 26.09: зазор был бесплатным).
func _test_ring_gap_paid() -> void:
	print("— кольцо: зазор замыкания стоит маны")
	_fresh()
	var cf := w.contracts
	cf.mana = cf.mana_max
	var c0 := Vector2(640, 360)
	var r := 60.0
	var n := 40
	# круг почти целиком — 330°, зазор ≈ 34 px (меньше порога 12 % длины)
	cf.begin(c0 + Vector2(r, 0))
	for i in range(1, n + 1):
		var a := TAU * (330.0 / 360.0) * float(i) / float(n)
		cf.extend(c0 + Vector2(cos(a), sin(a)) * r)
	var stroke_len := cf._draft_len
	var gap := cf._draft[0].distance_to(cf._draft[cf._draft.size() - 1])
	var before := cf.mana
	cf.finish()
	var ring: Contract = null
	for c in cf.contracts:
		if c.ring:
			ring = c
	_check(ring != null, "кольцо создано")
	var price := Contract.base_price(cf.current_kind) * cf.mana_cost_mult
	_check(absf((before - cf.mana) - gap * price) < 0.01,
		"за зазор %.1f px списано %.2f маны (штрих %.0f px оплачен по ходу)"
			% [gap, before - cf.mana, stroke_len])


func _test_e_braces_line() -> void:
	print("— Е: строй держит напор вдвое")
	var bends: Array[float] = []
	for with_e in [false, true]:
		_fresh()
		var c := _line(Vector2(600, 200))
		var squad := _man(c, 1)
		var hold := 0.0
		for u in squad:
			hold += float(LegionCfg.PRESS_HOLD.get(u.kind, 1.0))
		# толпа тяжелее строя, но легче удвоенного: n зомби по массе 1, идут на участок с востока
		var n := int(hold * 1.5)
		for i in n:
			var z := w.spawn_foe_on_path("zombie",
				PackedVector2Array([Vector2(622, 270 + i * 5), Vector2(300, 270 + i * 5)]),
				Vector2(622, 270 + i * 5))
			z._dir = Vector2.LEFT
		if with_e:
			w.hero.cast(LegionHero.SLOT_E, c.seg_center(1))
		w.grid.rebuild()
		for k in 30:
			w.grid.press_scan(c, LegionCfg.PRESS_BAND)
			w._press_segment(c, 1, DT)
		bends.append(c.seg_bend[1])
	_check(bends[0] > 0.0 and bends[1] == 0.0,
		"прогиб без Е %.2f, с Е %.2f" % [bends[0], bends[1]])
