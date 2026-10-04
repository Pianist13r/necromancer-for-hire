extends SceneTree
## Diagnostic90s match, normal bots and carrier schedule; no forced awards.
var w: LegionWorld
var awards: Array[Dictionary] = []


func _initialize() -> void:
	_run.call_deferred()


func _award(id: StringName, at: Vector2, side: int) -> void:
	awards.append({"side": side, "id": id, "t": w.now, "x": at.x, "y": at.y})


func _run() -> void:
	Campaign.set_save_path("user://pvp_items_short.cfg")
	Campaign.reset()
	w = (load("res://scenes/legion_world.tscn") as PackedScene).instantiate() as LegionWorld
	w.embedded = true
	root.add_child(w)
	await process_frame
	w.set_process(false)
	w.args["pvp_bots"] = true
	w.dev = {"noview": "1"}
	w._base_seed = 7
	w.start_map("pvp:duel")
	for side in w.sides:
		side.items.gained.connect(_award.bind(side.index))
	for tick in 5400:
		if w.phase != LegionWorld.Phase.BATTLE:
			break
		w._step(1.0 / 60.0)
		if tick % 8 == 0:
			await process_frame
	var state: Array[Dictionary] = []
	for side in w.sides:
		state.append({"side": side.index, "hp": side.cauldron_hp, "items": side.items.owned()})
	print("PVP_ITEMS_SHORT " + JSON.stringify({"seed": 7, "time": w.now, "sides": state,
		"awards": awards, "carriers": w.stats.get("carriers", 0),
		"geometry_fail": w.stats.get("pvp_carrier_geometry_fail", 0), "phase": w.phase}))
	w.queue_free()
	await process_frame
	Campaign.reset()
	quit()
