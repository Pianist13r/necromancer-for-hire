extends SceneTree
##
## Регресс P2b (docs/dev/PVP_PLAN_0929.md): мана способностей — у каждой стороны своя.
## После слияния slow/pvp-core с economy-mana (D-0927-140) can_pay_ability/pay_ability брали ману
## из поля стороны 0: Ку и «Сбор» стороны 1 платились чужой маной (и не шли без неё).
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_pvp_mana_test.gd -- --mute
##
## 1) Ку стороны 1: при своей мане и пустой мане стороны 0 — каст идёт, списано у стороны 1;
##    при своей пустой мане и полной у стороны 0 — отказ, мана стороны 0 цела;
## 2) «Сбор» стороны 1 — то же;
## 3) запас маны бота — у каждой стороны с PvpBot свой, оплата читает запас своей стороны;
## 4) траты стороны 1 не попадают в счёт боя игрока (stats стороны 0);
## 5) логика постройки меряет край мира по размеру карты (1600×900), а не по кадру 1280×720:
##    точка рождения у Котла стороны 1 (x ≈ 1430) годна.
## Итог «LEGION PVP MANA: N/M OK»; выход 1 при провале.
##

const SAVE := "user://legion_pvp_mana_test.cfg"
const DT := 1.0 / 60.0
const DUEL := "pvp:duel"
## Точка стычки на половине стороны 1: цель Ку стороны 1 и место «Сбора» её бойцов.
const SPOT := Vector2(1150.0, 450.0)

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
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	w = scene.instantiate() as LegionWorld
	root.add_child(w)
	await process_frame
	await process_frame
	w.set_process(false)
	_test_q()
	_test_rally()
	_test_bot_reserve()
	_test_world_edge()
	Campaign.reset()
	print("LEGION PVP MANA: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


## Матч без волн, без ботов, без стартового штата (как _fresh в legion_pvp_core_test).
func _fresh(bots := false) -> void:
	w.dev = {"spawn_units": "0", "no_waves": "1"}
	if bots:
		w.args["pvp_bots"] = true
	else:
		w.dev["pvp_nobot"] = "1"
		w.args.erase("pvp_bots")
	w.args.erase("bot")
	w.dev_invuln = false
	w._base_seed = 7
	w.start_map(DUEL)


func _side(i: int) -> PvpSide:
	return w.sides[i]


func _mana(i: int) -> float:
	return _side(i).contracts.mana


func _set_mana(m0: float, m1: float) -> void:
	_side(0).contracts.mana = m0
	_side(1).contracts.mana = m1


func _unit(at: Vector2, side: int) -> Legionnaire:
	return w.spawn_unit(LegionCfg.KIND_LABORER, at, null, side)


func _test_q() -> void:
	print("— Ку стороны 1 платит своей маной")
	_fresh()
	_check(w.ability_mana(LegionHero.SLOT_Q) == 25.0 \
			and w.ability_mana(LegionHero.SLOT_W) == 30.0 \
			and w.ability_mana(LegionHero.SLOT_E) == 20.0,
		"PvP сохраняет цены Ку 25, Дубль-вэ 30, Е 20")
	var cost := w.ability_mana(LegionHero.SLOT_Q)
	_unit(SPOT, 0)   # чужой боец — цель Ку стороны 1
	_set_mana(0.0, 100.0)
	var r: Dictionary = w.command(1, PvpCmd.cast(LegionHero.SLOT_Q, SPOT))
	_check(bool(r.get("ok", false)), "Ку стороны 1 при своей мане и пустой у стороны 0: %s" % str(r))
	_check(is_equal_approx(_mana(1), 100.0 - cost),
		"списано у стороны 1: %.1f (ждали %.1f)" % [_mana(1), 100.0 - cost])
	_check(is_equal_approx(_mana(0), 0.0), "мана стороны 0 не тронута: %.1f" % _mana(0))
	_check(is_zero_approx(float(w.stats["mana_abilities"])),
		"трата стороны 1 не в счёте боя стороны 0: %s" % str(w.stats["mana_abilities"]))
	_fresh()
	_unit(SPOT, 0)
	_set_mana(100.0, 0.0)
	r = w.command(1, PvpCmd.cast(LegionHero.SLOT_Q, SPOT))
	_check(not bool(r.get("ok", true)), "Ку стороны 1 без своей маны — отказ: %s" % str(r))
	_check(is_equal_approx(_mana(0), 100.0), "мана стороны 0 цела: %.1f" % _mana(0))
	_check(is_equal_approx(_mana(1), 0.0), "мана стороны 1 не ушла в минус: %.1f" % _mana(1))


func _test_rally() -> void:
	print("— «Сбор» стороны 1 платит своей маной")
	_fresh()
	for i in 4:
		_unit(SPOT + Vector2(10.0 * i, 0.0), 1)
	_set_mana(0.0, 100.0)
	var r: Dictionary = w.command(1, PvpCmd.rally(SPOT + Vector2(0.0, 60.0)))
	_check(bool(r.get("ok", false)), "«Сбор» стороны 1 при своей мане: %s" % str(r))
	_check(is_equal_approx(_mana(1), 100.0 - LegionCfg.RALLY_MANA),
		"списано у стороны 1: %.1f" % _mana(1))
	_check(is_equal_approx(_mana(0), 0.0), "мана стороны 0 не тронута: %.1f" % _mana(0))
	_check(_side(1).rally_cd > 0.0 and is_zero_approx(_side(0).rally_cd),
		"откат — у стороны 1: %.1f / %.1f" % [_side(0).rally_cd, _side(1).rally_cd])
	_fresh()
	for i in 4:
		_unit(SPOT + Vector2(10.0 * i, 0.0), 1)
	_set_mana(100.0, 0.0)
	r = w.command(1, PvpCmd.rally(SPOT + Vector2(0.0, 60.0)))
	_check(not bool(r.get("ok", true)), "«Сбор» стороны 1 без своей маны — отказ: %s" % str(r))
	_check(is_equal_approx(_mana(0), 100.0), "мана стороны 0 цела: %.1f" % _mana(0))


## Через call: до правки P2b у can_pay_ability нет параметра стороны — тест должен падать
## проверкой, а не разбором файла.
func _can_q(side: int) -> bool:
	return bool(w.call("can_pay_ability", LegionHero.SLOT_Q, side))


func _test_bot_reserve() -> void:
	print("— запас маны бота — у своей стороны")
	_fresh(true)
	for i in 2:
		_check(_side(i).bot is PvpBot
			and is_equal_approx(_side(i).ability_mana_reserve, LegionCfg.BOT_MANA_RESERVE),
			"сторона %d: бот PvP с запасом %.0f" % [i, _side(i).ability_mana_reserve])
	var need := w.ability_mana(LegionHero.SLOT_Q) + LegionCfg.BOT_MANA_RESERVE
	_set_mana(100.0, need - 1.0)
	_check(_can_q(0) and not _can_q(1),
		"оплата читает ману и запас своей стороны")
	_set_mana(need - 1.0, 100.0)
	_check(not _can_q(0) and _can_q(1),
		"и наоборот")
	# человек за сторону 0 против бота: запас только у стороны бота
	w.args.erase("pvp_bots")
	w.dev.erase("pvp_nobot")
	w.start_map(DUEL)
	_check(_side(0).bot == null and is_zero_approx(_side(0).ability_mana_reserve)
		and is_equal_approx(_side(1).ability_mana_reserve, LegionCfg.BOT_MANA_RESERVE),
		"человек против бота: запас 0 / %.0f" % _side(1).ability_mana_reserve)


func _test_world_edge() -> void:
	print("— край мира постройки — по размеру карты")
	_fresh()
	var b: LegionBuilding = _side(1).staff.cauldron
	_check(b != null and b.position.x > LegionCfg.WORLD_SIZE.x,
		"Котёл стороны 1 за кадром одиночки: x=%.0f" % (b.position.x if b != null else -1.0))
	if b == null:
		return
	var p := b.entry if w.terrain.walkable(b.entry) else b.position
	_check(bool(b.call("_door_reach", p)), "точка рождения у Котла стороны 1 годна: %s" % str(p))
	_check(not bool(b.call("_door_reach", Vector2(w.world_size.x + 20.0, p.y))),
		"точка за краем карты — нет")
