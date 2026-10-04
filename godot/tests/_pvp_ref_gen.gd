extends SceneTree
## ВРЕМЕННЫЙ: снять эталон одиночки на коде ДО линии L1 (удалить после). Функция дайджеста —
## дословная копия _single_digest из legion_pvp_core_test.gd.
const DT := 1.0 / 60.0
const SINGLE_RUNS := [["wasteland", 3], ["fork", 2]]
const SINGLE_MAX_STEPS := 60 * 60 * 20
var w: LegionWorld


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	Campaign.set_save_path("user://legion_pvp_core_test.cfg")
	Campaign.reset()
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	w = scene.instantiate() as LegionWorld
	root.add_child(w)
	await process_frame
	await process_frame
	w.set_process(false)
	for run: Array in SINGLE_RUNS:
		var t0 := Time.get_ticks_msec()
		var d := _single_digest(run[0], run[1])
		print("SINGLEREF %s %d %s" % [run[0], run[1], d])
		print("  (%d мс)" % (Time.get_ticks_msec() - t0))
	quit(0)


func _single_digest(map_id: String, seed: int) -> String:
	Settings.scheme_override = ""
	w.dev = {"difficulty": "intern"}
	w.dev_invuln = false
	w.args["bot"] = "selective"
	w._base_seed = seed
	w.start_map(map_id)
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_MD5)
	var i := 0
	while w.phase == LegionWorld.Phase.BATTLE and i < SINGLE_MAX_STEPS:
		w._step(DT)
		i += 1
		if i % 60 != 0:
			continue
		var line := "%d|%.4f|%.4f|%d|%d|%d|" % [i, w.cauldron_hp, w.contracts.mana, w.souls,
			w.army_alive(), w.active_foes()]
		for u in w.units:
			line += "%.2f,%.2f,%.2f,%d;" % [u.position.x, u.position.y, u.hp, u.state]
		ctx.update(line.to_utf8_buffer())
	var fin := w.final_stats(w.phase == LegionWorld.Phase.VICTORY)
	var keys := fin.keys()
	keys.sort()
	var tail := ""
	for k in keys:
		tail += "%s=%s," % [k, str(fin[k])]
	ctx.update(tail.to_utf8_buffer())
	w.args.erase("bot")
	print("  итог %s s%d: %s за %d шагов" % [map_id, seed, fin["result"], i])
	return ctx.finish().hex_encode()
