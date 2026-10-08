extends "res://tests/legion_balance_runner.gd"
## Compare frozen layouts with one unchanged combat implementation and runner.

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var idx := args.find("--fixture")
	if idx < 0:
		quit(2)
		return
	var map := ProcGen.thaw(FileAccess.get_file_as_string(args[idx + 1]))
	if map.is_empty():
		quit(2)
		return
	map = PvpMaps.adapt_generated(map)
	Campaign.set_save_path("user://procgen_1008_balance.cfg")
	Campaign.reset()
	var w := BalanceWorld.new()
	w.embedded = true
	w.souls_changed.connect(w.on_souls_changed)
	root.add_child(w)
	w.start_map(String(map["id"]), map)
	if args.has("--pvp-bots") and not w.pvp:
		push_error("PvP fixture did not create sides")
		quit(2)
		return
	print("FIXTURE ", ProcGen.digest(map))
