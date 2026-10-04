extends SceneTree
##
## Правила длины матча «Схватки» (P3, docs/dev/PVP_PLAN_0929.md; D-0929-51, B-291):
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_pvp_seals_test.gd -- --mute
##
## 1) «Печати Котла»: множитель урона Котлу — SEALS_START до SEALS_FROM, растёт до SEALS_END к
##    SEALS_TO, дальше SEALS_END;
## 2) в PvP урон Котлу (любой стороны) умножается на множитель момента матча; в одиночке — нет;
## 3) генерированное поле получает волны PvpMaps.waves на своих дорогах PvE: WAVES волн, первая
##    на FIRST_WAVE, у обеих сторон одинаковые составы.
## Итог «LEGION PVP SEALS: N/M OK»; выход 1 при провале.
##

const SAVE := "user://legion_pvp_seals_test.cfg"

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
	_test_curve()
	_test_damage()
	_test_gen_waves()
	Campaign.reset()
	print("LEGION PVP SEALS: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


func _test_curve() -> void:
	print("— кривая печатей")
	var s0 := PvpRules.SEALS_START
	var s1 := PvpRules.SEALS_END
	_check(s0 < 1.0 and s1 > 1.0 and PvpRules.SEALS_FROM < PvpRules.SEALS_TO
		and PvpRules.SEALS_TO < PvpRules.MATCH_LIMIT,
		"печати: сначала крепче (%.2f), к %d с слабее (%.1f), до предела матча" % [s0, int(PvpRules.SEALS_TO), s1])
	_check(is_equal_approx(PvpRules.cauldron_mult(0.0), s0)
		and is_equal_approx(PvpRules.cauldron_mult(PvpRules.SEALS_FROM), s0),
		"до %d с множитель %.2f" % [int(PvpRules.SEALS_FROM), s0])
	var mid := (PvpRules.SEALS_FROM + PvpRules.SEALS_TO) * 0.5
	_check(is_equal_approx(PvpRules.cauldron_mult(mid), (s0 + s1) * 0.5),
		"посередине — среднее: %.3f" % PvpRules.cauldron_mult(mid))
	_check(is_equal_approx(PvpRules.cauldron_mult(PvpRules.SEALS_TO), s1)
		and is_equal_approx(PvpRules.cauldron_mult(PvpRules.MATCH_LIMIT), s1),
		"с %d с и до предела — %.1f" % [int(PvpRules.SEALS_TO), s1])


func _start(id: String) -> void:
	w.dev = {"spawn_units": "0", "no_waves": "1", "pvp_nobot": "1"}
	w.args.erase("pvp_bots")
	w.args.erase("bot")
	w.dev_invuln = false
	w._base_seed = 3
	w.start_map(id)


func _test_damage() -> void:
	print("— урон Котлу по печатям")
	_start("pvp:duel")
	for side in 2:
		for t: float in [0.0, PvpRules.SEALS_TO]:
			var s: PvpSide = w.sides[side]
			s.cauldron_hp = PvpRules.CAULDRON_HP
			w.now = t
			w.damage_cauldron(10.0, "", side)
			var lost := PvpRules.CAULDRON_HP - s.cauldron_hp
			_check(is_equal_approx(lost, 10.0 * PvpRules.cauldron_mult(t)),
				"PvP, сторона %d, %d с: удар 10 снял %.2f" % [side, int(t), lost])
	_start("bridge")
	_check(not w.pvp, "одиночная карта — не PvP")
	var hp := w.cauldron_hp
	w.now = PvpRules.SEALS_TO
	w.damage_cauldron(10.0)
	_check(is_equal_approx(hp - w.cauldron_hp, 10.0),
		"одиночка: удар 10 снял %.2f — печатей нет" % (hp - w.cauldron_hp))


func _test_gen_waves() -> void:
	print("— волны генерированного поля")
	var m := PvpMaps.adapt_generated(ProcGen.map_from_id("gen:7:3:pvp"))
	var waves: Array = m.get("waves", [])
	_check(waves.size() == PvpMaps.WAVES, "волн %d (как у «Дуэли» — %d)" % [waves.size(), PvpMaps.WAVES])
	if waves.is_empty():
		return
	_check(is_equal_approx(float(waves[0]["pause"]), PvpRules.FIRST_WAVE),
		"первая — на %d-й секунде" % int(PvpRules.FIRST_WAVE))
	var pve := {}
	for r: Dictionary in m["roads"]:
		if String(r.get("kind", "")) == "pve":
			pve[String(r["id"])] = int(r["side"])
	var ok := pve.size() == 2
	for wv: Dictionary in waves:
		var by_side := [[], []]
		for g: Dictionary in wv["groups"]:
			var road := String(g["road"])
			ok = ok and pve.has(road)
			if pve.has(road):
				(by_side[int(pve[road])] as Array).append("%s×%d" % [g["type"], int(g["count"])])
		ok = ok and by_side[0] == by_side[1] and not (by_side[0] as Array).is_empty()
	_check(ok, "каждая волна — по дорогам PvE обеих сторон, составы равны (дороги %s)" % [pve.keys()])
