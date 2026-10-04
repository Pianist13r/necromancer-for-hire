extends "res://tests/legion_intuit_test.gd"
## Диагностика: один и тот же бой до/после items-v2 без элитных и артефактов.

func _run() -> void:
	Campaign.set_save_path("user://items_trace_probe.cfg")
	Campaign.reset()
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	w = scene.instantiate() as LegionWorld
	w.embedded = true
	root.add_child(w)
	await _frames(2)
	for run: Array in [["bridge", 1, 3600], ["fork", 2, 3600], ["wasteland", 3, 3600],
		["gatehouse", 1, 4800], ["archive", 2, 4800], ["wasteland", 3, 4800],
		["bridge", 1, 4800], ["fork", 2, 4800]]:
		print("PROBE %s %d %d %s" % [run[0], run[1], run[2], _bot_digest(run[0], run[1], run[2])])
	quit()

func _bot_digest(map_id: String, seed: int, steps: int) -> String:
	Settings.scheme_override = ""
	w.dev = {"difficulty": "intern", "elite": "0", "drop": "0", "carriers": ""}
	if OS.get_environment("TRACE_ELITES") == "1":
		w.dev.erase("elite")
	w.dev_invuln = false
	w.args["bot"] = "selective"
	w._base_seed = seed
	w.start_map(map_id)
	if OS.get_environment("TRACE_LEGACY") == "1" and w.foe_killed.is_connected(w.items._on_foe_killed):
		w.foe_killed.disconnect(w.items._on_foe_killed)
		w.foe_killed.connect(_legacy_kill)
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_MD5)
	for i in steps:
		w._step(1.0 / 60.0)
		if i % 30 != 0:
			continue
		var line := "%d|%.4f|%.4f|%d|" % [i, w.cauldron_hp, w.contracts.mana, w.souls]
		for u in w.units:
			line += "%.3f,%.3f,%.3f,%d;" % [u.position.x, u.position.y, u.hp, u.state]
		for f in w.foes:
			line += "%s:%.3f,%.3f,%.3f;" % [f.type_id, f.position.x, f.position.y, f.hp]
		for c in w.contracts.contracts:
			line += "c%d:%.2f:%s;" % [c.id, c.length, str(c.seg_age)]
		var keys := w.stats.keys()
		keys.sort()
		for k in keys:
			line += "%s=%s," % [k, str(w.stats[k])]
		ctx.update(line.to_utf8_buffer())
	w.args.erase("bot")
	return ctx.finish().hex_encode()

func _legacy_kill(f: Foe, pos: Vector2) -> void:
	if f.elite and not f.has_meta(&"summoned"):
		w.rng.randf()
	w.items._on_foe_killed(f, pos)
