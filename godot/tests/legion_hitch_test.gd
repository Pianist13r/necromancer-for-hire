extends SceneTree
##
## Регресс трека оптимизации (10.10.2026): подвисание при первом появлении вида в бою.
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_hitch_test.gd -- --mute
##
## Мир при старте прогревал кадры только восьми персонажей (LegionWorld.ALL_CHARS), а
## «охранник», «писарь» и «юрист» из CfgAnim.CHARS — нет: первый такой боец или враг читал
## с диска ~325 кадров прямо в шаге мира. Замер стенда tests/legion_perf_bench.gd (bridge,
## бот selective, сид 1): из редактора 6–8 с стоп-кадра на t≈64 (охранник) и t≈99 (юрист),
## в собранном exe (dist 10.10) tickMaxMs 899 мс.
## 1) после старта мира в кэше CharView все персонажи CfgAnim.CHARS;
## 2) первый боец каждого вида и первый враг каждого типа не читают кадры с диска (прирост
##    ресурсов движка < RES_BUDGET; у непрогретого персонажа — сотни).
## Итог «LEGION HITCH: N/M OK»; код выхода 1, если что-то упало.
##

const SAVE := "user://legion_hitch_test.cfg"
## Своё на каждую сущность (материалы вида и т. п.) — единицы; кадры персонажа — сотни.
const RES_BUDGET := 20

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
	w.set_process(false)
	_test_warm()
	_test_first_spawn()
	Campaign.reset()
	print("LEGION HITCH: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


func _test_warm() -> void:
	var missing: Array = []
	for id: String in CfgAnim.CHARS:
		if not CharView._cache.has(id):
			missing.append(id)
	_check(missing.is_empty(), "кадры всех %d персонажей прогреты при старте мира (нет: %s)"
		% [CfgAnim.CHARS.size(), missing])


func _test_first_spawn() -> void:
	w.dev["no_waves"] = "1"
	w.dev["spawn_units"] = "0"
	w.start_map("bridge")
	w.dev_invuln = true
	var at := w.cauldron_pos + Vector2(-60.0, 0.0)
	for kind: StringName in LegionCfg.UNIT_KINDS:
		var r0 := _res()
		var t0 := Time.get_ticks_usec()
		var u := w.spawn_unit(kind, at)
		var ms := (Time.get_ticks_usec() - t0) / 1000.0
		_check(u != null and _res() - r0 < RES_BUDGET,
			"первый боец «%s»: +%d ресурсов, %.1f мс" % [kind, _res() - r0, ms])
	for type: String in LegionCfg.FOES:
		var r0 := _res()
		var t0 := Time.get_ticks_usec()
		var p := at + Vector2(-120.0, 0.0)
		var f := w.spawn_foe_on_path(type, PackedVector2Array([p, w.cauldron_pos]), p)
		var ms := (Time.get_ticks_usec() - t0) / 1000.0
		_check(f != null and _res() - r0 < RES_BUDGET,
			"первый враг «%s»: +%d ресурсов, %.1f мс" % [type, _res() - r0, ms])


func _res() -> int:
	return int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT))
