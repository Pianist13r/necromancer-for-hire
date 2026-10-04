extends SceneTree
##
## Линия economy-mana (D-0927-140; Игорь «Да, делай» — D-0927-202): способности стоят маны
## сверх отката. Проверки: числа legion_cfg, на которых сделан замер серии; каст списывает ману
## только состоявшись; нехватка — отказ без траты отката, сигнал mana_short, слово у курсора;
## «Сбор» так же; запас бота; подсказки intuit и урок не зовут без маны; цена в «Как играть».
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_economy_mana_test.gd -- --mute
##
## Итог «LEGION ECONOMY MANA: N/M OK»; код выхода 1, если что-то упало. Мир настоящий (карта
## _gray, без волн и стартовой армии), сохранение — во временном файле.
##

const SAVE := "user://legion_economy_mana_test.cfg"
const LAB := Vector2(760, 120)   ## тихий кусок _gray (как в legion_hero_test)

var w: LegionWorld
var hero: LegionHero
var _fails := 0
var _checks := 0
var _short: Array[int] = []


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
	w.mana_short.connect(func(slot: int) -> void: _short.append(slot))
	_test_cfg()
	_test_cast_pays()
	_test_cast_short()
	_test_aim_word()
	_test_rally()
	_test_bot_reserve()
	_test_hints()
	_test_howto()
	await _test_bar_blink()
	Campaign.reset()
	print("LEGION ECONOMY MANA: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


func _fresh() -> void:
	w.dev["no_waves"] = "1"
	w.dev["spawn_units"] = "0"
	w.start_map("_gray")
	w.dev_invuln = false
	hero = w.hero
	hero.reset()
	w.ability_mana_reserve = 0.0
	w.contracts.mana = w.contracts.mana_max
	_short.clear()


func _still_foe(at: Vector2) -> Foe:
	var f := w.spawn_foe_on_path("zombie", PackedVector2Array([at]), at)
	f.speed = 0.0
	return f


func _test_cfg() -> void:
	_check(LegionCfg.ABILITY_MANA == [45.0, 55.0, 35.0] and LegionCfg.RALLY_MANA == 20.0,
		"цены одиночки B-402: Ку 45, Дубль-вэ 55, Е 35, «Сбор» 20")
	_check(LegionCfg.MANA_REGEN == 10.0 and LegionCfg.MANA_MAX == 100.0,
		"одиночка: восстановление 10/с, потолок 100")
	_check(LegionCfg.BOT_MANA_RESERVE == 30.0, "бот оставляет на линии 30 маны")
	_fresh()
	_check(w.ability_mana(LegionHero.SLOT_W) == 55.0
		and w.ability_mana(LegionCfg.RALLY_SLOT) == LegionCfg.RALLY_MANA,
		"ability_mana: слот героя и слот «Сбора»")


func _test_cast_pays() -> void:
	_fresh()
	var f := _still_foe(LAB)
	var spent0 := float(w.stats["mana_spent"])
	var ok := hero.cast(LegionHero.SLOT_Q, LAB)
	_check(ok and is_equal_approx(w.contracts.mana, 55.0), "Ку по цели: −45 маны (100 → 55)")
	_check(is_equal_approx(float(w.stats["mana_abilities"]), 45.0)
		and is_equal_approx(float(w.stats["mana_spent"]) - spent0, 45.0),
		"мана способности — в mana_spent и отдельно в mana_abilities")
	var m := w.contracts.mana
	hero._cd[LegionHero.SLOT_Q] = 0.0
	ok = hero.cast(LegionHero.SLOT_Q, LAB + Vector2(900, 900))
	_check(not ok and w.contracts.mana == m, "нет цели — маны не взяли")
	f.take_damage(100000.0, f.position)


func _test_cast_short() -> void:
	_fresh()
	var f := _still_foe(LAB)
	w.contracts.mana = 44.0
	var reasons: Array[StringName] = []
	var on_fail := func(_slot: int, reason: StringName) -> void: reasons.append(reason)
	hero.cast_failed.connect(on_fail)
	var ok := hero.cast(LegionHero.SLOT_Q, LAB)
	hero.cast_failed.disconnect(on_fail)
	_check(not ok and w.contracts.mana == 44.0 and hero.cd_left(LegionHero.SLOT_Q) == 0.0
		and f.hp == float(f.def["hp"]),
		"мало маны (44 < 45): каста нет, мана и откат целы, враг не задет")
	_check(reasons == [&"no_mana"] and _short == [LegionHero.SLOT_Q],
		"отказ с причиной no_mana и сигналом mana_short (слот мигает, звук)")
	w.contracts.mana = 45.0
	_check(hero.cast(LegionHero.SLOT_Q, LAB) and w.contracts.mana == 0.0,
		"ровно 45 — каст проходит, мана 0")
	f.take_damage(100000.0, f.position)


func _test_aim_word() -> void:
	_fresh()
	var f := _still_foe(LAB)
	w.contracts.mana = 10.0
	var aim := w.ability_aim
	_check(aim.preview_text(LegionHero.SLOT_Q, LAB) == "мало маны: 10 из 45",
		"прицел пишет «мало маны: 10 из 45» до отпускания")
	_check(not aim.cast_at(LegionHero.SLOT_Q, LAB), "каст из прицела не проходит")
	f.take_damage(100000.0, f.position)


func _test_rally() -> void:
	_fresh()
	var u := w.spawn_unit(LegionCfg.KIND_LABORER, LAB)
	w.contracts.mana = 19.0
	_check(w.rally(LAB + Vector2(30, 0)) == -1 and w.rally_cd == 0.0 and w.contracts.mana == 19.0
		and _short == [LegionCfg.RALLY_SLOT],
		"«Сбор» при 19 < 20: не зовёт, откат и мана целы, mana_short(«Сбор»)")
	w.contracts.mana = 50.0
	_check(w.rally(LAB + Vector2(30, 0)) == 1 and w.contracts.mana == 30.0 and w.rally_cd > 0.0,
		"«Сбор» при 50: позвал, −20 маны, откат пошёл")
	u.take_damage(100000.0, u.position)
	w.rally_cd = 0.0
	w.contracts.mana = 50.0
	_check(w.rally(LAB + Vector2(30, 0)) == 0 and w.contracts.mana == 50.0,
		"«Сбор» без свободных — маны не взял")


func _test_bot_reserve() -> void:
	_fresh()
	var f := _still_foe(LAB)
	w.ability_mana_reserve = LegionCfg.BOT_MANA_RESERVE
	w.contracts.mana = 74.0
	_check(not hero.cast(LegionHero.SLOT_Q, LAB) and w.contracts.mana == 74.0,
		"бот: 74 < 45 + 30 запаса — не бьёт, мана остаётся линиям")
	w.contracts.mana = 75.0
	_check(hero.cast(LegionHero.SLOT_Q, LAB) and w.contracts.mana == 30.0,
		"бот: 75 — бьёт, на линии остаётся 30")
	w.ability_mana_reserve = 0.0
	f.take_damage(100000.0, f.position)


func _test_hints() -> void:
	_fresh()
	w.contracts.mana = 5.0
	_check(not w.intuit._slot_ready(hero, LegionHero.SLOT_Q),
		"подсказка на поле не зовёт Ку без маны")
	w.contracts.mana = 100.0
	_check(w.intuit._slot_ready(hero, LegionHero.SLOT_Q), "с маной — зовёт")
	var tut := LegionTutorial.new()
	tut.world = w
	var lesson := {"id": &"economy_q", "kind": &"hero_q"}
	w.contracts.mana = 5.0
	_check(not tut._slot_ready(lesson), "урок Ку посреди боя не встаёт без маны")
	w.contracts.mana = 100.0
	_check(tut._slot_ready(lesson), "с маной — встаёт")


## Отказ виден на панели: героя пересоздаёт каждый start_map, и панель должна слушать нового
## (до правки подписка шла в setup(), когда героя ещё не было, — слот не мигал никогда).
func _test_bar_blink() -> void:
	_fresh()
	await process_frame
	var bar: AbilityBar = w.hud._ability_bar
	w.contracts.mana = 0.0
	hero.cast(LegionHero.SLOT_E, LAB)
	_check(bar._blink[LegionHero.SLOT_E] > 0.0, "мало маны — слот Е мигает красным на панели")
	w.rally_cd = 0.0
	w.rally(LAB)
	_check(bar._rally_blink > 0.0, "мало маны — слот «Сбор» мигает красным")


func _test_howto() -> void:
	var src := FileAccess.get_file_as_string("res://scripts/legion/ui/howto_legion.gd")
	_check(src.contains("Способности стоят маны сверх отката")
		and src.contains("LegionCfg.ABILITY_MANA[0]") and src.contains("LegionCfg.RALLY_MANA"),
		"«Как играть»: цены способностей берутся из legion_cfg")
