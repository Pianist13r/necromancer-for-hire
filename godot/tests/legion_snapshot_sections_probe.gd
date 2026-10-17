extends SceneTree
## QA-only section timing for NetSnap.save. Does not replace legion_snapshot_test.gd.

const DT := 1.0 / 60.0
const STEPS := 90 * 60
const REPEATS := 5
const MAP := "gen:7:3:pvp"
const SAVE := "user://b485_section_probe.cfg"
const PREFIX := "B485_SECTION "

var _checks := 0
var _fails := 0


func _initialize() -> void:
	_run.call_deferred()


## Same calls and order as NetSnap.save; only clocks are added between calls.
func _staged_save(w: LegionWorld) -> Dictionary:
	var t := Time.get_ticks_usec()
	var reg := NetSnap.Reg.new(w)
	var us := {"reg_new": Time.get_ticks_usec() - t}
	var stage_order: Array[String] = ["reg_new"]
	t = Time.get_ticks_usec()
	reg.index_world()
	us["index_world"] = Time.get_ticks_usec() - t
	stage_order.append("index_world")
	t = Time.get_ticks_usec()
	var out := {"v": NetSnap.VERSION, "tick": roundi(w.now * 60.0)}
	us["header"] = Time.get_ticks_usec() - t
	stage_order.append("header")
	for key in NetSnap.CHUNKS:
		t = Time.get_ticks_usec()
		out[String(key)] = NetSnap._chunk(key).save(w, reg)
		us[String(key)] = Time.get_ticks_usec() - t
		stage_order.append(String(key))
	t = Time.get_ticks_usec()
	out[NetSnap.SHARED] = reg.save_shared()
	us["shared"] = Time.get_ticks_usec() - t
	stage_order.append("shared")
	return {"snapshot": out, "section_us": us, "stage_order": stage_order}


func _sample(w: LegionWorld, label: String) -> bool:
	# First pair warms caches but is still byte checked. Five later pairs form the sample.
	for i in range(REPEATS + 1):
		var t := Time.get_ticks_usec()
		var canonical := w.snapshot()
		var canonical_us := Time.get_ticks_usec() - t
		var staged := _staged_save(w)
		t = Time.get_ticks_usec()
		var canonical_bytes := var_to_bytes(canonical)
		var canonical_wire_us := Time.get_ticks_usec() - t
		t = Time.get_ticks_usec()
		var staged_bytes := var_to_bytes(staged["snapshot"])
		var staged_wire_us := Time.get_ticks_usec() - t
		if canonical_bytes != staged_bytes:
			print("B485_SECTION_ERROR byte_mismatch at=", label, " sample=", i)
			_fails += 1
			return false
		if i == 0:
			continue
		_checks += 1
		print(
			(
				PREFIX
				+ JSON.stringify(
					{
						"at": label,
						"sample": i,
						"now": w.now,
						"phase": w.phase,
						"units": w.units.size(),
						"foes": w.foes.size(),
						"corpses": w._corpses.size(),
						"bytes": canonical_bytes.size(),
						"canonical_us": canonical_us,
						"section_us": staged["section_us"],
						"stage_order": staged["stage_order"],
						"canonical_wire_us": canonical_wire_us,
						"staged_wire_us": staged_wire_us
					}
				)
			)
		)
	return true


func _run() -> void:
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	var w := (load("res://scenes/legion_world.tscn") as PackedScene).instantiate() as LegionWorld
	w.embedded = true
	root.add_child(w)
	await process_frame
	w.set_process(false)
	w.dev = {"noview": "1"}
	w.no_view = true
	w.args["pvp_bots"] = true
	w._base_seed = 7
	w.start_map(MAP)
	var valid := w.phase == LegionWorld.Phase.BATTLE
	if valid:
		valid = _sample(w, "t0")
	if valid:
		for tick in range(STEPS):
			if w.phase != LegionWorld.Phase.BATTLE:
				print("B485_SECTION_ERROR battle_ended at_tick=", tick)
				valid = false
				break
			w._step(DT)
			await process_frame
	if valid:
		valid = w.phase == LegionWorld.Phase.BATTLE
		if valid:
			valid = _sample(w, "t90")
	w.queue_free()
	await process_frame
	Campaign.reset()
	if valid and _fails == 0 and _checks == 2 * REPEATS:
		print("B485 SECTION PROBE: 10/10 OK")
		quit(0)
	else:
		print("B485 SECTION PROBE: %d/10 INCOMPLETE" % _checks)
		quit(1)
