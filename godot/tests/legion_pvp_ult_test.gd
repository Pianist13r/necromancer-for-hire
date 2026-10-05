# gdlint: disable=max-file-lines
extends SceneTree
##
## Регресс независимого ревью J, находка J6 (05.10.2026): в «Схватке» ульты «Комиссии» и
## «Неустойки» действуют на армию СОПЕРНИКА так же, как на врагов в одиночке.
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_pvp_ult_test.gd -- --mute
##
## Проверяется НАСТОЯЩИЙ вход ульт — LegionWorld.on_charge_contact (первое касание группы залпа),
## а не вызов _ult_contact напрямую: важно, что сторона залпа доходит до замедления.
##   · метка «Комиссии» ложится на ЧУЖОГО бойца, и участники той же группы бьют его сильнее;
##   · «Неустойка» замедляет чужих бойцов вокруг точки удара и НЕ трогает своих;
##   · одиночный путь (метка на врага PvE) не сломан.
##
## Новые поля читаются через get(): на прежнем коде тест не падает разбором, а проваливает
## проверки. Итог «LEGION PVP ULT: N/M OK»; код выхода 1, если что-то упало.
##

const SAVE := "user://legion_pvp_ult_test.cfg"
const DUEL := "pvp:duel"
const FIG_CFG_PATH := "res://scripts/legion/figure_cfg.gd"
const DT := 1.0 / 60.0

var w: LegionWorld
var fcfg: Script = null
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
	if ResourceLoader.exists(FIG_CFG_PATH):
		fcfg = load(FIG_CFG_PATH)
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	w = scene.instantiate() as LegionWorld
	root.add_child(w)
	await _frames(2)
	w.set_process(false)
	_test_unit_ults()
	_test_solo_foe_still_marked()
	Campaign.reset()
	print("LEGION PVP ULT: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


# ── Сцена (как в legion_pvp_core_test) ───────────────────────────────────────

func _fresh() -> void:
	w.dev = {"spawn_units": "0", "pvp_nobot": "1", "no_waves": "1"}
	w.args.erase("pvp_bots")
	w.args.erase("bot")
	w.dev_invuln = false
	w._base_seed = 7
	w.start_map(DUEL)


func _unit(kind: StringName, at: Vector2, side: int) -> Legionnaire:
	return w.call("spawn_unit", kind, at, null, side) as Legionnaire


func _cfg(key: String, fallback: Variant) -> Variant:
	return fcfg.get_script_constant_map().get(key, fallback) if fcfg != null else fallback


## Залп «первого касания»: те же ключи, что кладёт LegionWorld._volley.
func _volley(extra: Dictionary = {}) -> Dictionary:
	var v := {
		"dir": Vector2.RIGHT, "power": 1.0, "perfect": false, "manual": false,
		"range": 1.0, "dmg": 1.0, "speed": 1.0, "units": 0, "hit": false,
		"combo_mult": 1.0, "knocked": {},
	}
	for k: Variant in extra:
		v[k] = extra[k]
	return v


## Чтение нового поля без падения на прежнем коде: get() там даёт null.
func _ival(o: Object, key: String) -> int:
	var v: Variant = o.get(key)
	return int(v) if v is int else -1


func _fval(o: Object, key: String) -> float:
	var v: Variant = o.get(key)
	return float(v) if v is int or v is float else 0.0


## Урон удара a по b через настоящий путь мира (PvP-удар отложен до конца шага бойцов).
func _strike_damage(a: Legionnaire, b: Node2D) -> float:
	a.set("_atk_cd", 0.0)
	var before := float(b.get("hp"))
	a.call("_strike", b, 1.0, false)
	w.call("_flush_pvp_hits")
	return before - float(b.get("hp"))


# ── J6: ульты по армии соперника ─────────────────────────────────────────────

func _test_unit_ults() -> void:
	print("— J6: «Комиссия» и «Неустойка» в «Схватке»")
	_fresh()
	_check(bool(w.get("pvp")), "мир в режиме «Схватки»")
	var a := _unit(LegionCfg.KIND_LABORER, Vector2(300.0, 150.0), 0)
	var b := _unit(LegionCfg.KIND_LABORER, Vector2(330.0, 150.0), 1)
	var mate := _unit(LegionCfg.KIND_LABORER, Vector2(330.0, 190.0), 0)
	if a == null or b == null or mate == null:
		_check(false, "бойцы расставлены")
		return
	# На прежнем коде полей нет — проверки ниже просто проваливаются (get() не падает разбором)
	_check(_ival(b, "mark_hit_group") == -1 and _fval(b, "ult_slow_t") == 0.0,
		"у бойца есть поля метки и замедления чужого залпа")
	b.hp = 100000.0
	b.max_hp = 100000.0
	var plain := _strike_damage(a, b)
	_check(plain > 0.0, "базовый удар по чужому бойцу проходит (%.1f)" % plain)
	# метка «Комиссии»: id группы из залпа ложится на цель первого касания
	var group := 4242
	a.set("mark_group_id", group)
	w.call("on_charge_contact", a, b, _volley({"mark_group": group}))
	_check(_ival(b, "mark_hit_group") == group,
		"первое касание залпа метит ЧУЖОГО бойца (id %d)" % _ival(b, "mark_hit_group"))
	var marked := _strike_damage(a, b)
	var mult := float(_cfg("PENTA_MARK_MULT", 1.0))
	_check(marked > plain and absf(marked / maxf(plain, 0.001) - mult) < 0.05,
		"участник группы бьёт помеченного сильнее: %.1f против %.1f (×%.2f)" % [marked, plain, mult])
	# «Неустойка»: замедление чужих вокруг точки удара, свои не задеты
	var slow := float(_cfg("D_SLOW_MULT", 0.65))
	w.call("on_charge_contact", a, b, _volley({"slow": {
		"r": float(_cfg("D_SLOW_R", 40.0)), "mult": slow, "t": float(_cfg("D_SLOW_T", 2.0))}}))
	_check(_fval(b, "ult_slow_t") > 0.0 and _fval(b, "ult_slow_mult") < 1.0,
		"«Неустойка» замедлила чужого бойца (×%.2f)" % _fval(b, "ult_slow_mult"))
	_check(b.call("_item_speed") < 1.0,
		"замедление дошло до скорости бойца (%.2f)" % float(b.call("_item_speed")))
	_check(_fval(mate, "ult_slow_t") == 0.0, "свой боец рядом замедления не получил")


# ── Одиночный путь не сломан ─────────────────────────────────────────────────

func _test_solo_foe_still_marked() -> void:
	print("— метка врага PvE прежняя")
	_fresh()
	var a := _unit(LegionCfg.KIND_LABORER, Vector2(300.0, 150.0), 0)
	if a == null:
		_check(false, "боец стороны 0 расставлен")
		return
	var at := Vector2(360.0, 150.0)
	var f := w.spawn_foe_on_path("zombie", PackedVector2Array([at, at + Vector2(0.0, 400.0)]), at)
	f.speed = 0.0
	f.hp = 100000.0
	f.max_hp = 100000.0
	var group := 77
	a.set("mark_group_id", group)
	w.call("on_charge_contact", a, f, _volley({"mark_group": group}))
	_check(_ival(f, "mark_group_id") == group and _fval(f, "mark_t") > 0.0,
		"враг PvE по-прежнему получает метку группы (id %d)" % _ival(f, "mark_group_id"))
	var plain := _strike_damage(a, f)
	_check(plain > 0.0, "удар по помеченному врагу проходит (%.1f)" % plain)
