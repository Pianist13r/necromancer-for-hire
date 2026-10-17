extends SceneTree
## Рычаг свиты меняет только конкретного Прораба, не общий LegionCfg.FOES.

const RUNNER := preload("res://tests/legion_balance_runner.gd")

var _checks := 0
var _fails := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, description: String) -> void:
	_checks += 1
	if not ok:
		_fails += 1
	print("  %s %s" % ["OK" if ok else "FAIL", description])


func _run() -> void:
	Campaign.set_save_path("user://legion_balance_escort_override_test.cfg")
	Campaign.reset()
	var original_escort := int(LegionCfg.FOES["boss"]["escort"])
	var original_hp := float(LegionCfg.FOES["boss"]["hp"])
	var world := RUNNER.BalanceWorld.new() as LegionWorld
	world.embedded = true
	root.add_child(world)
	await process_frame
	world.set_process(false)
	world.dev = {"no_waves": "1", "spawn_units": "0", "escort_n": "0"}
	world.start_map("_gray")
	var route := PackedVector2Array([Vector2(100, 100), Vector2(80, 100)])
	var no_escort := world._add_foe("boss", route, {})
	_check(int(no_escort.def["escort"]) == 0 and no_escort.hp == original_hp,
		"escort-only override changes this boss without changing its health")
	_check(int(LegionCfg.FOES["boss"]["escort"]) == original_escort,
		"escort-only override leaves the shared definition unchanged")

	world.dev.erase("escort_n")
	var ordinary := world._add_foe("boss", route, {})
	_check(int(ordinary.def["escort"]) == original_escort,
		"a later ordinary boss still has the original escort count")
	_check(int(no_escort.def["escort"]) == 0,
		"changing runner options does not change the first boss")

	world.dev["boss_hp"] = "6000"
	world.dev["escort_n"] = "0"
	var stressed := world._add_foe("boss", route, {})
	_check(stressed.hp == 6000.0 and stressed.max_hp == 6000.0
		and int(stressed.def["escort"]) == 0,
		"HP and zero-escort controls compose on the same boss")
	_check(ordinary.hp == original_hp and int(ordinary.def["escort"]) == original_escort,
		"combined controls do not alter an earlier ordinary boss")

	world.dev.erase("boss_hp")
	world.dev["escort_n"] = str(original_escort)
	var neutral := world._add_foe("boss", route, {})
	_check(neutral.hp == original_hp and int(neutral.def["escort"]) == original_escort,
		"explicit original escort count is neutral")
	_check(float(LegionCfg.FOES["boss"]["hp"]) == original_hp
		and int(LegionCfg.FOES["boss"]["escort"]) == original_escort,
		"all overrides leave the shared boss definition intact")
	world.queue_free()
	await process_frame
	Campaign.reset()
	print("LEGION BALANCE ESCORT OVERRIDE: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails else 0)
