extends SceneTree
## Fixed dictionaries let before/after measure the filter, not a different layout.

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var idx := args.find("--dir")
	if idx < 0:
		quit(2)
		return
	var folder := args[idx + 1]
	var quick := args.has("--quick")
	var invalid := args.has("--invalid")
	var files := DirAccess.get_files_at(folder)
	var times: Array[float] = []
	var bad := 0
	for file in files:
		if not file.ends_with(".json"):
			continue
		var map := ProcGen.thaw(FileAccess.get_file_as_string(folder.path_join(file)))
		if invalid:
			map["plots"] = []
		for repeat in 3:
			var start := Time.get_ticks_usec()
			var problems := PgFilter.rejection(map) if quick else PgFilter.check(map)
			times.append((Time.get_ticks_usec() - start) / 1000.0)
			bad += int(problems.is_empty() == invalid)
	times.sort()
	print(JSON.stringify({"checks": times.size(), "failed": bad, "quick": quick, "invalid": invalid,
		"median_ms": times[times.size() / 2], "p95_ms": times[int(times.size() * 0.95)],
		"max_ms": times[-1]}))
	quit(1 if bad > 0 else 0)
