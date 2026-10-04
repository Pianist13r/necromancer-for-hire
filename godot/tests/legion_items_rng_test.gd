extends SceneTree
## Предметная случайность отделена от боевой: v1 съедал world.rng при смерти элитного.
## Поэтому эталоны боёв после items-v2 обновляются лишь после парного контрфактического
## прогона (docs/dev/CODEX_A.md). Этот тест защищает саму причину расхождения.

var w: LegionWorld
var checks := 0
var fails := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		fails += 1
	print("  %s %s" % ["ok" if ok else "FAIL", label])


func _run() -> void:
	Campaign.set_save_path("user://legion_items_rng_test.cfg")
	Campaign.reset()
	w = (load("res://scenes/legion_world.tscn") as PackedScene).instantiate() as LegionWorld
	w.embedded = true
	root.add_child(w)
	await process_frame
	w.set_process(false)
	for drop: String in ["0", "1"]:
		w.dev = {"no_waves": "1", "spawn_units": "0", "carriers": "", "drop": drop}
		w.start_map("fork")
		var at := Vector2(900, 300)
		var f := w.spawn_foe_on_path("zombie", PackedVector2Array([at]), at)
		f.make_elite()
		var before := w.rng.state
		w.items._on_foe_killed(f, at)
		_check(w.rng.state == before, "смерть элитного, drop=%s: боевой RNG не сдвинут" % drop)
		_check(w.items.total() == int(drop), "drop=%s: получено %d артефактов" % [drop, w.items.total()])
	w.items.reset()
	w.dev.erase("carriers")
	var before := w.rng.state
	if w.items.has_method("plan_battle"):
		w.items.call("plan_battle", 6)
		var plan: Array = w.items.get("plan").duplicate()
		_check(w.rng.state == before, "план носителей не сдвигает боевой RNG")
		w.rng.randf()
		before = w.rng.state
		w.items.call("plan_battle", 6)
		_check(w.items.get("plan") == plan and w.rng.state == before,
			"план воспроизводим и не зависит от состояния боевого RNG")
	else:
		_check(false, "есть независимый план носителей")
	Campaign.reset()
	print("LEGION ITEMS RNG: %d/%d OK" % [checks - fails, checks])
	quit(1 if fails > 0 else 0)
