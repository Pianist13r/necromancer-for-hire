extends SceneTree
## Поведенческий red на старом L1: чужая Скрепка не усиливает героя стороны 1.
## Использует только старые API, поэтому red не может быть отсутствием нового метода.
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
	Campaign.set_save_path("user://pvp_items_boundary.cfg")
	Campaign.reset()
	Campaign.set_run_items(["clip_of_fate"])
	w = (load("res://scenes/legion_world.tscn") as PackedScene).instantiate() as LegionWorld
	w.embedded = true
	root.add_child(w)
	await process_frame
	w.set_process(false)
	w.dev = {"no_waves": "1", "spawn_units": "0", "pvp_nobot": "1", "noview": "1"}
	w.carry_items = true
	w.start_map("pvp:duel")
	_check(w.items.total() == 0, "PvP не загружает артефакты сохранения кампании")
	w.items.reset()
	var h0 := w.sides[0].hero
	var h1 := w.sides[1].hero
	var q0 := h0.q_chain_len()
	var q1 := h1.q_chain_len()
	var stun1 := h1.q_stun()
	w.items.grant(&"clip_of_fate")
	_check(h0.q_chain_len() == q0 + 2, "свой предмет действительно усиливает Ку")
	_check(h1.q_chain_len() == q1, "чужая Скрепка не добавляет звенья Ку")
	_check(h1.q_stun() == stun1, "чужая Скрепка не усиливает оглушение")
	_check(Campaign.run_items() == [&"clip_of_fate"], "бой не меняет артефакты кампании")
	w.queue_free()
	await process_frame
	Campaign.reset()
	print("LEGION PVP ITEMS BOUNDARY: %d/%d OK" % [checks - fails, checks])
	quit(1 if fails > 0 else 0)
