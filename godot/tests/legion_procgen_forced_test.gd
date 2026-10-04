extends SceneTree
##
## Регресс «заданной карточки» процгена (D-0927-91: на ней стоит перегенерированная кампания;
## verifier 27.09: star+mimic_mine, pincers+runway и др. давали пустую карту):
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_procgen_forced_test.gd -- --mute
##
## 1) все 17 архетипов × 5 биомов (где таблица §6.1 не «—») × сиды 1–3 — ни одной пустой карты,
##    заданные архетип и биом соблюдены;
## 2) каждая изюминка §4.1 × каждый совместимый архетип — ни одной пустой, изюминка на карте;
## 3) изюминка без архетипа (архетип дотягивается совместимым) — ни одной пустой;
## 4) невозможное (склепы в конторе, пролитый кофе на кладбище) — пусто и понятная причина.
## Итог «LEGION PROCGEN FORCED: N/M OK»; код выхода 1 при провале. Сохранений не пишет.
##

const K := 4

var _checks := 0
var _fails := 0


func _initialize() -> void:
	_arch_biome()
	_quirk_arch()
	_impossible()
	print("LEGION PROCGEN FORCED: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_fails += 1
		print("  FAIL ", what)


func _arch_biome() -> void:
	var empty: Array[String] = []
	var dishonored: Array[String] = []
	var n := 0
	for a in PgTables.ARCH_ORDER:
		for b in PgTables.BIOMES:
			if PgTables.arch_cell(a, b) == "-":
				continue
			for s in [1, 2, 3]:
				n += 1
				var m := ProcGen.generate(s, K, {"card": {"archetype": a, "biome": b}})
				if m.is_empty():
					empty.append("%s/%s/%d (%s)" % [a, b, s, ProcGen.last_error])
					continue
				var c: Dictionary = m["procgen"]["card"]
				if c["archetype"] != a or c["biome"] != b or m["biome"] != b:
					dishonored.append("%s/%s/%d" % [a, b, s])
	print("архетип × биом: %d карт, пустых %d" % [n, empty.size()])
	_check(empty.is_empty(), "архетип × биом без пустых: %s" % [empty.slice(0, 8)])
	_check(dishonored.is_empty(), "заданные архетип и биом соблюдены: %s" % [dishonored])


func _quirk_arch() -> void:
	var empty: Array[String] = []
	var missing: Array[String] = []
	var n := 0
	for q in PgTables.QUIRK_ORDER:
		for a in PgTables.ARCH_ORDER:
			if not PgForced.quirk_fits(q, a):
				continue
			var biome := ""
			for b in PgTables.BIOMES:
				if biome == "" and PgTables.arch_cell(a, b) != "-" \
						and PgTables.quirk_cell(q, b) != "-":
					biome = b
			if biome == "":
				continue
			n += 1
			var m := ProcGen.generate(1, K, {"card": {"archetype": a, "biome": biome,
				"quirks": [q]}})
			if m.is_empty():
				empty.append("%s+%s (%s)" % [a, q, ProcGen.last_error])
			elif not (m["procgen"]["card"]["quirks"] as Array).has(q):
				missing.append("%s+%s" % [a, q])
		# изюминка без архетипа: архетип дотягивается совместимым
		for s in [1, 2]:
			n += 1
			var m2 := ProcGen.generate(s, 6, {"card": {"quirks": [q]}})
			if m2.is_empty():
				empty.append("%s без архетипа, сид %d (%s)" % [q, s, ProcGen.last_error])
			elif not (m2["procgen"]["card"]["quirks"] as Array).has(q):
				missing.append("%s без архетипа" % q)
	print("изюминка × архетип: %d карт, пустых %d" % [n, empty.size()])
	_check(empty.is_empty(), "изюминка × совместимый архетип без пустых: %s" % [empty.slice(0, 8)])
	_check(missing.is_empty(), "заданная изюминка на карте: %s" % [missing])


func _impossible() -> void:
	for bad: Dictionary in [{"archetype": "crypts", "biome": "office"},
			{"biome": "grave", "quirks": ["coffee"]}, {"archetype": "island", "quirks": ["flight"]},
			{"archetype": "nope"}]:
		var m := ProcGen.generate(1, K, {"card": bad})
		_check(m.is_empty() and not ProcGen.last_error.is_empty(),
			"невозможное %s — пусто с причиной «%s»" % [bad, ProcGen.last_error])
