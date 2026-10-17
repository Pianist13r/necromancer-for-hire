extends SceneTree
## CLI driver: REPLAY_MODE=record|replay, REPLAY_FILE, REPLAY_RESULT and identities
## are supplied by tools/replay/run_input_replay.py in a fresh isolated process.

const Replay = preload("res://scripts/dev/input_replay.gd")
const TICKS := 1200
var checks := 0
var failures: Array[String] = []
var signal_counts := {"draw": 0, "release": 0, "cast": 0, "build": 0}


func _initialize() -> void:
	_run.call_deferred()


func check(ok: bool, label: String) -> void:
	checks += 1
	print("  %s %s" % ["ok" if ok else "FAIL", label])
	if not ok:
		failures.append(label)


func _run() -> void:
	Campaign.set_save_path("user://input_replay_test.cfg")
	Campaign.reset()
	var expected := Replay.identity(OS.get_environment("REPLAY_CODE_SHA256"), OS.get_environment("REPLAY_ENGINE_SHA256"))
	var mode := OS.get_environment("REPLAY_MODE")
	var path := OS.get_environment("REPLAY_FILE")
	var data: Variant = null
	var config := {"map": "_plots", "seed": 4242, "difficulty": "normal"}
	if mode == "replay":
		var file := FileAccess.open(path, FileAccess.READ)
		if file == null or file.get_length() > Replay.MAX_FILE:
			finish({"error": "file size or open", "tick": -1})
			return
		data = JSON.parse_string(file.get_as_text())
		var why := Replay.validate(data, expected)
		if why != "":
			finish({"error": why, "tick": -1})
			return
		config = data["config"]
	elif mode != "record" or FileAccess.file_exists(path):
		finish({"error": "mode or existing output", "tick": -1})
		return
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	var w := scene.instantiate() as LegionWorld
	w.embedded = true
	root.add_child(w)
	w.set_process(false)
	Replay.prepare(w, config)
	for i in 3000:
		if w.net_can_step():
			break
		await process_frame
	check(w.net_can_step() and w.bot == null and w.tutorial == null and not w.pvp, "fresh ready solo without bot/tutorial")
	var session := Replay.new()
	var started: bool = session.begin(w, expected) if mode == "record" else session.restore(w, data, expected)
	if not started or not failures.is_empty():
		var reason := session.error if session.error != "" else "world setup"
		w.queue_free()
		await process_frame
		finish({"error": reason, "tick": 0})
		return
	w.contract_created.connect(func(_c: Contract) -> void: signal_counts["draw"] += 1)
	w.segment_released.connect(func(_c: Contract, _s: int, n: int) -> void: signal_counts["release"] += n)
	w.hero_cast.connect(func(_slot: int, _at: Vector2) -> void: signal_counts["cast"] += 1)
	w.building_changed.connect(func(_b: Object) -> void: signal_counts["build"] += 1)
	var limit: int = TICKS if mode == "record" else int(data["ticks"])
	while w.net_tick < limit:
		if mode == "record":
			gesture(w, w.net_tick)
		var ok: bool = session.record_tick() if mode == "record" else session.replay_tick()
		if not ok:
			break
		# Deliberately different render-frame cadence in the separate replay process.
		if w.net_tick % (3 if mode == "record" else 11) == 0:
			await process_frame
	var tick := w.net_tick
	var final_score := Replay.score(w)
	var error: String = session.error
	if error == "":
		check(tick == limit, "all fixed simulation ticks executed")
		if mode == "record":
			# These prove this fixture is meaningful, not requirements on other replays.
			for name: String in signal_counts:
				check(int(signal_counts[name]) > 0, "actual gameplay effect: " + name)
			check(int(w.stats["buildings_built"]) > 0, "building was purchased")
			check(float(w.stats["mana_abilities"]) > 0, "spell spent real mana")
			check(int(w.stats["releases_manual"]) > 0, "manual release counted")
			check(Replay.validate(session.envelope, expected) == "", "record envelope validates")
			if failures.is_empty():
				var file := FileAccess.open(path, FileAccess.WRITE)
				file.store_string(JSON.stringify(session.envelope, "\t") + "\n")
				file.close()
	if error == "" and not failures.is_empty():
		error = "fixture checks"
	w.queue_free()
	await process_frame
	await process_frame
	finish({"error": error, "tick": tick, "score": final_score, "effects": signal_counts})


## Scripted human-style semantic gestures, never LegionBot/PvpBot. Drawing and release
## enter the actual ContractField native path; cast/build enter the same local_cmd as UI.
func gesture(w: LegionWorld, tick: int) -> void:
	var f := w.contracts
	if tick == 10:
		f.begin(Vector2(400.125, 270.125))
		for k in range(1, 19):
			f.extend(Vector2(400.125, 270.125 + k * 10.0))
		f.finish()
	if tick == 40:
		w.local_cmd(PvpCmd.plot(String(w.staff.plots[0]["id"]), PvpCmd.BUILD, LegionCfg.KIND_LABORER))
	if tick == 120:
		w.local_cmd(PvpCmd.cast(LegionHero.SLOT_E, Vector2(320.0, 360.0)))
	if tick == 300 and not f.contracts.is_empty():
		var c: Contract = f.contracts[0]
		for s in c.seg_count():
			if c.seg_alive(s) and c.seg_manned(s) > 0:
				f.click(c, s)
				break


func finish(result: Dictionary) -> void:
	result["checks"] = checks
	result["failures"] = failures
	result["mode"] = OS.get_environment("REPLAY_MODE")
	var file := FileAccess.open(OS.get_environment("REPLAY_RESULT"), FileAccess.WRITE)
	file.store_string(JSON.stringify(result, "\t") + "\n")
	file.close()
	print("INPUT REPLAY: ", JSON.stringify(result))
	quit(0 if result["error"] == "" and failures.is_empty() else 1)
