extends SceneTree
##
## Дамп сгенерированных карт в JSON — глазами координатора (контактный лист —
## tools/procgen_sheet.py). Не бой, не сохранения.
##
##   "$GODOT" --headless --path godot --script res://tests/procgen_dump.gd \
##       -- --mute --seeds 1-20 --k 1-12 --out C:/AI/necro/batches/procgen/layout/dump
##
## Файлы: <out>/gen_<сид>_<k>.json; в конце — сводка: время генерации (медиана/максимум),
## архетипы, причины провалов попыток.
##


const SLOW_MS := 1000.0


func _initialize() -> void:
	var seeds := Vector2i(1, 20)
	var ks := Vector2i(1, 12)
	var out := "user://procgen_dump"
	var argv := OS.get_cmdline_user_args()
	for i in argv.size():
		var next: String = argv[i + 1] if i + 1 < argv.size() else ""
		match argv[i]:
			"--seeds":
				seeds = _range(next)
			"--k":
				ks = _range(next)
			"--out":
				out = next
	DirAccess.make_dir_recursive_absolute(out)
	var times: Array[float] = []
	var archs := {}
	var failed := 0
	for s in range(seeds.x, seeds.y + 1):
		for k in range(ks.x, ks.y + 1):
			var t0 := Time.get_ticks_usec()
			var map := ProcGen.generate(s, k)
			times.append((Time.get_ticks_usec() - t0) / 1000.0)
			if times[-1] > SLOW_MS:
				print("  медленно: gen:%d:%d — %.0f мс" % [s, k, times[-1]])
			if map.is_empty():
				failed += 1
				continue
			var a := String(map["procgen"]["card"]["archetype"])
			archs[a] = int(archs.get(a, 0)) + 1
			var f := FileAccess.open("%s/gen_%d_%d.json" % [out, s, k], FileAccess.WRITE)
			f.store_string(ProcGen.freeze(map))
			f.close()
	times.sort()
	print("PROCGEN DUMP: карт %d, пусто %d, мс медиана %.1f, максимум %.1f" % [
		times.size(), failed, times[times.size() / 2], times[-1]])
	print("архетипы: ", archs)
	var why: Array = ProcGen.fail_log.keys()
	why.sort_custom(func(a: String, b: String) -> bool:
		return int(ProcGen.fail_log[a]) > int(ProcGen.fail_log[b]))
	for w: String in why.slice(0, 40):
		print("  провал ×%d: %s" % [ProcGen.fail_log[w], w])
	quit(1 if failed > 0 else 0)


static func _range(s: String) -> Vector2i:
	var p := s.split("-")
	return Vector2i(p[0].to_int(), p[p.size() - 1].to_int())
