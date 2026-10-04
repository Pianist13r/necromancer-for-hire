extends SceneTree
## Временный зонд (не в git): попытки раскладки без выбора — что отбраковывает фильтр.
##   -- --mute --seeds 1-20 --k 1-12 --out DIR


func _initialize() -> void:
	var seeds := Vector2i(1, 20)
	var ks := Vector2i(1, 12)
	var out := ""
	var argv := OS.get_cmdline_user_args()
	for i in argv.size() - 1:
		match argv[i]:
			"--seeds":
				var p := argv[i + 1].split("-")
				seeds = Vector2i(p[0].to_int(), p[-1].to_int())
			"--k":
				var p := argv[i + 1].split("-")
				ks = Vector2i(p[0].to_int(), p[-1].to_int())
			"--out":
				out = argv[i + 1]
	if out != "":
		DirAccess.make_dir_recursive_absolute(out)
	var rules := {}
	var by_arch := {}
	var arch_n := {}
	var total := 0
	var bad := 0
	var saved := {}
	var t_layout := 0.0
	var t_filter := 0.0
	for s in range(seeds.x, seeds.y + 1):
		for k in range(ks.x, ks.y + 1):
			var card: Dictionary = PgCard.chain(s, k)[-1].duplicate(true)
			card.erase("alts")
			var t0 := Time.get_ticks_usec()
			var lay := PgLayout.new()
			var map := lay.build(card, PgRng.make(s, "layout:%d" % k, 0))
			if map.is_empty():
				continue
			map["id"] = ProcGen.make_id(s, k)
			var pg: Dictionary = map["procgen"]
			pg["card"] = card
			map["waves"] = PgWaves.build(map, card, PgRng.make(s, "waves:%d" % k, 0))
			PgNames.apply(map, card, PgRng.make(s, "names:%d" % k, 0))
			var t1 := Time.get_ticks_usec()
			var probs := PgFilter.check(map)
			var t2 := Time.get_ticks_usec()
			t_layout += (t1 - t0) / 1000.0
			t_filter += (t2 - t1) / 1000.0
			total += 1
			var a := String(card["archetype"])
			arch_n[a] = int(arch_n.get(a, 0)) + 1
			if probs.is_empty():
				continue
			bad += 1
			by_arch[a] = int(by_arch.get(a, 0)) + 1
			var rule := probs[0].split(":")[0]
			rules[rule] = int(rules.get(rule, 0)) + 1
			print("BAD %d:%d %s | %s" % [s, k, a, probs[0]])
			if out != "" and int(saved.get(rule, 0)) < 4:
				saved[rule] = int(saved.get(rule, 0)) + 1
				var f := FileAccess.open("%s/rej_%s_%d_%d.json" % [out, rule.replace("-", ""), s, k],
					FileAccess.WRITE)
				f.store_string(ProcGen.freeze(map))
				f.close()
	print("REJECT %d/%d = %.1f%%" % [bad, total, 100.0 * bad / maxi(total, 1)])
	print("RULES ", rules)
	print("ARCH N ", arch_n)
	print("ARCH BAD ", by_arch)
	print("TIME layout %.1f ms/map, filter %.1f ms/map" % [t_layout / maxi(total, 1),
		t_filter / maxi(total, 1)])
	for key: String in PgLayout.prof:
		print("  шаг %s %.1f мс/карту" % [key, float(PgLayout.prof[key]) / maxi(total, 1)])
	quit(0)
