extends SceneTree
## Настоящие боец, постройка, разряд и поднятый враг; каждая особая поправка против базы.

const LAB := Vector2(760, 120)
var w: LegionWorld
var runtime: AmendmentRuntime
var checks := 0
var fails := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		fails += 1
		print("FAIL: ", message)


func _fresh(ids: Array[StringName] = []) -> void:
	Campaign.set_save_path("user://amendment_runtime_test.cfg")
	Campaign.use_campaign_scope()
	Campaign.reset()
	Campaign.unlock_all()
	for id in ids:
		Campaign.add_upgrade(id)
	w.dev = {"no_waves": "1", "spawn_units": "4"}
	w.mods = Campaign.active_mods()
	w.in_campaign = true
	w.start_map("_gray")
	w.dev_invuln = false
	w.set_process(false)
	w.set_physics_process(false)
	# A1: helper поправок теперь подключён к миру — узел amendment_runtime создаёт _build(),
	# подписки ставит start_map(). Тест гоняет тот же узел мира; отдельный не плодим, иначе
	# сигналы боя (unit_died/foe_killed/…) подписались бы дважды и засчитывали замены/ману вдвое.
	runtime = w.amendment_runtime


func _foe(at: Vector2, hp := 500.0) -> Foe:
	var f := w.spawn_foe_on_path("zombie", PackedVector2Array([at]), at)
	f.speed = 0.0
	f.hp = hp
	w.grid.rebuild()
	return f


func _run() -> void:
	w = LegionWorld.new()
	root.add_child(w)
	await process_frame
	_test_queue()
	_test_echo()
	_test_ghost()
	_test_march()
	_test_artifact_synergy()
	_test_dividend()
	_test_dividend_summoned()
	_test_megaphone()
	_test_hot_line()
	_test_boundaries()
	w.queue_free()
	await process_frame
	print("AMENDMENT RUNTIME: %d/%d OK" % [checks-fails, checks])
	quit(1 if fails else 0)


func _test_queue() -> void:
	_fresh()
	var base := w.staff.cauldron.alive_count()
	w.units[0]._die()
	_check(w.staff.cauldron.alive_count() == base - 1, "base death waits for timed replacement")
	_fresh([&"living_queue"])
	base = w.staff.cauldron.alive_count()
	w.units[0]._die()
	_check(w.staff.cauldron.alive_count() == base, "queue replaces first casualty immediately")
	_check(int(w.stats.get("amendment_replacements", 0)) == 1, "one genuine replacement counted")
	for unit in w.units:
		if unit.alive:
			unit._die()
			break
	_check(int(w.stats.get("amendment_replacements", 0)) == 1, "queue cooldown prevents death farming")
	_check(w.items.total() == 0, "doctrine is not counterfeit artifact inventory")


func _test_echo() -> void:
	_fresh()
	var f := _foe(LAB)
	w.hero.cast(LegionHero.SLOT_Q, LAB)
	var base := f.hp
	runtime.tick(0.7)
	_check(f.hp == base, "base Q has no delayed strike")
	_fresh([&"carbon_copy"])
	f = _foe(LAB)
	_check(w.hero.cast(LegionHero.SLOT_Q, LAB), "echo Q casts")
	var after := f.hp
	var damage := float(w.hero.last_cast["hits"][0]["dmg"])
	runtime.tick(0.59)
	_check(f.hp == after, "echo waits stated delay")
	runtime.tick(0.02)
	_check(is_equal_approx(after - f.hp, damage * 0.5), "echo applies stated second damage")
	_check(int(w.stats.get("amendment_echoes", 0)) == 1, "echo accounted once")
	_check(is_equal_approx(float(w.stats.get("amendment_damage", 0)), damage * 0.5),
		"reports actual extra damage")
	w.hero.reset_cd(LegionHero.SLOT_Q)
	w.contracts.mana = w.contracts.mana_max
	w.hero.cast(LegionHero.SLOT_Q, LAB)
	f.take_damage(10000.0, LAB)
	runtime.tick(0.7)
	_check(int(w.stats.get("amendment_echoes", 0)) == 1,
		"dead echo target cannot earn fictional damage")


func _test_ghost() -> void:
	_fresh()
	var line := PackedVector2Array([LAB - Vector2(60, 0), LAB + Vector2(60, 0)])
	var c := w.contracts._create(line, 1, LegionCfg.KIND_LABORER, true)
	w.release_segment(c, 0, &"melt")
	_check(runtime._ghosts.is_empty(), "base expired line leaves no extra hazard")
	_fresh([&"ghost_clause"])
	c = w.contracts._create(line, 1, LegionCfg.KIND_LABORER, true)
	var f := _foe(LAB)
	w.release_segment(c, 0, &"melt")
	_check(runtime._ghosts.size() == 1, "natural expiry leaves genuine ghost")
	var hp := f.hp
	runtime.tick(0.1)
	_check(f.hp < hp and f.seal_slow_t > 0.0, "ghost damages and slows intersecting foe")
	c = w.contracts._create(line + PackedVector2Array(), 1, LegionCfg.KIND_LABORER, true)
	w.release_segment(c, 0, &"manual")
	_check(runtime._ghosts.size() == 1, "manual launch cannot farm expiry reward")
	runtime.tick(3.1)
	_check(runtime._ghosts.is_empty(), "ghost respects lifetime")


func _raise_one() -> Node2D:
	var corpse := _foe(LAB, 20.0)
	corpse.take_damage(10000.0, LAB)
	w.hero.cast(LegionHero.SLOT_W, LAB)
	return w.hero._vassals[0]


func _test_march() -> void:
	_fresh()
	var v := _raise_one()
	_foe(LAB + Vector2(180, 0))
	var before: Vector2 = v.position
	runtime.tick(1.0)
	_check(v.position == before, "base outside hire remains stationary")
	_fresh([&"temp_agency"])
	v = _raise_one()
	_foe(LAB + Vector2(180, 0))
	before = v.position
	for _i in 10:
		runtime.tick(0.1)
	_check(v.position.distance_to(before) > 10.0, "agency hire marches toward enemy")
	_check(w.terrain.walkable(v.position), "hire follows walkable terrain")
	_check(is_equal_approx(float(w.stats.get("amendment_vassal_steps", 0)),
		v.position.distance_to(before)), "reports actual straight route distance")
	_check(runtime._vassals.size() == 1, "one summon tracked once")


func _test_artifact_synergy() -> void:
	_fresh([&"temp_agency"])
	w.items.grant(&"temp_contract")
	var v := _raise_one()
	var target := _foe(LAB + Vector2(15, 0))
	var before := target.hp
	v.life = 0.01
	runtime.tick(0.02)
	w.hero.tick(0.02)
	w.items.tick(0.2)
	_check(is_equal_approx(before - target.hp, 34.0),
		"agency plus artifact expires into one artifact blast")
	_check(w.items.count(&"temp_contract") == 1, "agency does not create extra artifact copy")


## E-1005 (ошибка 2): «Рупор завхоза» глушит только за НАСТОЯЩИЙ «Сбор» (n > 0). Сигнал rally_used
## при n == 0 остаётся — его слушает обучение (подсказка «некого звать», legion_tutorial), — а
## артефакт молчит: иначе R оглушал всех в 95 px бесплатно, без отката и без маны.
func _test_megaphone() -> void:
	_fresh()
	for u in w.units:
		if u.alive:
			u._die()                 # свободных нет — «Сбор» честно позовёт 0
	w.items.grant(&"megaphone")
	var f := _foe(LAB)
	var seen: Array = []
	var probe := func(_at: Vector2, n: int) -> void: seen.append(n)
	w.rally_used.connect(probe)
	var n := w.rally(LAB)
	_check(n == 0, "«Сбор» без свободных позвал 0 (n=%d)" % n)
	_check(seen.has(0), "сигнал rally_used с n=0 дошёл до слушателей (обучение/вид не сломаны)")
	_check(f.stun_t <= 0.0, "бесплатного оглушения нет: враг не оглушён (было 1,4 с)")
	_check(w.items.activation_count(&"megaphone") == 0, "ложный сбор артефакту не засчитан")
	w.rally_used.disconnect(probe)
	w.items.on(&"rally_used", [LAB, 1])   # настоящий сбор — эффект на месте
	_check(f.stun_t > 0.0, "за настоящий сбор «Рупор» глушит: %.2f с" % f.stun_t)
	_check(w.items.activation_count(&"megaphone") == 1, "оглушение засчитано артефакту")


## E-1005 (ошибка 3): «Душевые дивиденды» платят только за обычных проверяющих — призванные (свита
## Прораба, метка summoned) маны не дают, как и у всех прочих потребителей убийств.
func _test_dividend_summoned() -> void:
	_fresh([&"soul_dividend"])
	w.contracts.mana -= 5.0
	var before := w.contracts.mana
	var escort := w.spawn_foe_on_path("zombie", PackedVector2Array([LAB]), LAB, true)
	escort.speed = 0.0
	escort.hp = 20.0
	w.grid.rebuild()
	escort.take_damage(1000.0, LAB)
	_check(w.contracts.mana == before, "за призванного (свиту) мана не начислена (было +1)")
	_check(float(w.stats.get("amendment_mana", 0)) == 0.0, "призванный не даёт и учтённой маны")
	var normal := _foe(LAB + Vector2(20, 0), 20.0)
	normal.take_damage(1000.0, LAB)
	_check(w.contracts.mana == before + 1.0, "обычный проверяющий платит 1 ману — эффект цел")


## E-1005 (ошибка 9): синергия «Горячая линия» (ghost_burn) жжёт и призрак ПОПРАВКИ «Договор с
## привидением», не только артефактную линию «Пролонгации» — иначе текст синергии врал для половины.
func _ghost_tick_damage(synergy: bool) -> float:
	_fresh([&"ghost_clause"])
	w.items.grant(&"burning_seal")
	if synergy:
		w.items.grant(&"prolongation")   # + «Сургуч» = «Горячая линия»: ghost_burn +2, жжёт втрое
	var line := PackedVector2Array([LAB - Vector2(60, 0), LAB + Vector2(60, 0)])
	var c := w.contracts._create(line, 1, LegionCfg.KIND_LABORER, true)
	var f := _foe(LAB, 100000.0)
	w.release_segment(c, 0, &"melt")
	w.items.hazards.clear()   # у «Пролонгации» своя линия — меряем только призрак поправки
	var hp := f.hp
	runtime.tick(0.1)         # первый тик призрака — ровно один такт урона
	return hp - f.hp


func _test_hot_line() -> void:
	var base := _ghost_tick_damage(false)
	var hot := _ghost_tick_damage(true)
	_check(is_equal_approx(base, 12.0 * 0.25), "призрак поправки бьёт 12 dps: %.2f" % base)
	_check(is_equal_approx(hot, base * 3.0),
		"«Горячая линия» жжёт призрак поправки втрое: %.2f против %.2f" % [hot, base])


func _test_dividend() -> void:
	_fresh([&"soul_dividend"])
	w.contracts.mana -= 3.0
	var before := w.contracts.mana
	_foe(LAB, 20.0).take_damage(1000.0, LAB)
	_check(w.contracts.mana == before + 1.0, "kill returns real mana")
	w.contracts.mana = w.contracts.mana_max
	_foe(LAB + Vector2(20, 0), 20.0).take_damage(1000.0, LAB)
	_check(float(w.stats.get("amendment_mana", 0)) == 1.0, "full mana cannot earn fictional refund")


func _test_boundaries() -> void:
	_fresh([&"carbon_copy", &"living_queue"])
	runtime.setup(w)
	var f := _foe(LAB)
	w.hero.cast(LegionHero.SLOT_Q, LAB)
	_check(runtime._echoes.size() == 1, "setup twice does not double-subscribe")
	runtime.reset()
	var hp := f.hp
	runtime.tick(1.0)
	_check(f.hp == hp and runtime._echoes.is_empty(), "reset removes delayed work")
	w.in_campaign = false
	runtime.setup(w)
	_check(runtime.rules.is_empty(), "standalone cannot read campaign doctrine")
	w.in_campaign = true
	w.pvp = true
	runtime.setup(w)
	_check(runtime.rules.is_empty(), "PvP cannot read campaign doctrine")
