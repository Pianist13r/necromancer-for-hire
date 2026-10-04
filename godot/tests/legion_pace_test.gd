extends SceneTree
##
## Регресс «темпа читаемости» (D-0927-49, медленная сессия slow/pace, 27.09.2026). Игорь после
## «Штатного»: «нужно, чтоб поменьше всего происходило… чтоб поменьше и солдаты
## восстанавливались… чтобы успевали отслеживать, что происходит».
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_pace_test.gd -- --mute
##
## Проверяет на ВСЕХ уровнях (в т.ч. «Стажёре», который раньше был картой бит в бит):
## - «массовка» (зомби, жуки) в группах волн реже, но не меньше 1; щитоносцы, призраки,
##   нотариусы, Прораб и Юристы — как в карте; промежутки внутри группы не растянуты;
## - враг «массовки» толще (PACE_HP), остальные — нет;
## - души за волну — прежние (souls_mult группы), и живое убийство платит их без потерь на
##   округлении;
## - возрождение Котла, построек и склепа медленнее, штат Котла, построек и склепа меньше;
## - итог боя несёт метрику читаемости (пики и средние врагов и своих).
## На старом коде (beea92c) файл не разбирается (нет PACE_*, paced, foe_souls) — гейт падает.
## Итог «LEGION PACE: N/M OK»; код выхода 1, если что-то упало.
##

const SAVE := "user://legion_pace_test.cfg"
const MAPS: Array[String] = ["wasteland", "gatehouse", "fork", "archive", "bridge", "maze",
	"swamp", "boss"]
const LEVELS: Array[String] = ["intern", "normal", "hell"]
## Прежние числа (до D-0927-49) — то, от чего темп отсчитывается.
const OLD_CAULDRON_RESPAWN := 6.0
const OLD_CRYPT_RESPAWN := 8.0
const OLD_BUILD_RESPAWN := {"laborer": [8.0, 6.0, 5.0], "guard": [10.0, 8.0, 6.0],
	"clerk": [10.0, 8.0, 6.0]}
const OLD_CRYPT_STAFF := 8

var w: LegionWorld
var checks := 0
var fails := 0


func _initialize() -> void:
	_run.call_deferred()


func check(ok: bool, text: String) -> void:
	checks += 1
	if not ok:
		fails += 1
	print("  %s %s" % ["ok  " if ok else "FAIL", text])


func _run() -> void:
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	w = (load("res://scenes/legion_world.tscn") as PackedScene).instantiate() as LegionWorld
	w.embedded = true
	root.add_child(w)
	await process_frame
	w.set_process(false)
	test_waves_thinner()
	test_souls_per_wave()
	test_hp()
	test_live_souls()
	test_respawn_and_staff()
	test_metric()
	Campaign.reset()
	print("LEGION PACE: %d/%d OK" % [checks - fails, checks])
	quit(1 if fails else 0)


## Группы волны карты на уровне d без группы tier выше уровня — в исходном виде (сверка).
func _raw_groups(map_id: String, d: String) -> Array:
	var tier := int(LegionChallenge.TABLE[d]["tier"])
	var out: Array = []
	for wave: Dictionary in LegionWorld.load_map(map_id)["waves"]:
		var gs: Array = []
		for g: Dictionary in wave.get("groups", []):
			if int(g.get("tier", 0)) <= tier:
				gs.append(g)
		out.append(gs)
	return out


func test_waves_thinner() -> void:
	print("— массовка реже на всех уровнях, штучные враги как в карте")
	for d in LEVELS:
		var thin_before := 0
		var thin_after := 0
		var ok_min := true
		var ok_fixed := true
		var ok_interval := true
		for map_id in MAPS:
			var raw := _raw_groups(map_id, d)
			var got: Array = LegionChallenge.apply_map(LegionWorld.load_map(map_id), d)["waves"]
			for i in raw.size():
				var gs: Array = got[i]["groups"]
				for j in (raw[i] as Array).size():
					var r: Dictionary = raw[i][j]
					var g: Dictionary = gs[j]
					var type := String(r.get("type", "zombie"))
					var n := int(r.get("count", 1))
					var m := int(g.get("count", 1))
					var k := float(LegionChallenge.value(d, "count"))
					var lvl_n := n if d == "intern" else maxi(n, floori(n * k + 0.5))
					if LegionChallenge.PACE_THIN.has(type):
						thin_before += lvl_n
						thin_after += m
						ok_min = ok_min and (m >= 1 or n == 0) and m <= lvl_n
					else:
						ok_fixed = ok_fixed and m == lvl_n
					var kk := 1.0 if d == "intern" else float(LegionChallenge.value(d, "interval"))
					ok_interval = ok_interval and is_equal_approx(float(g.get("interval", 1.0)),
						float(r.get("interval", 1.0)) * (kk if r.has("interval") else 1.0))
		var ratio := float(thin_after) / maxf(1.0, float(thin_before))
		check(ratio < 0.65, "%s: массовки %d → %d (×%.2f, < 0,65)" % [d, thin_before, thin_after,
			ratio])
		check(ok_min, "%s: группа массовки не пропадает (≥ 1) и не растёт" % d)
		check(ok_fixed, "%s: щиты, призраки, нотариусы, Прораб, Юристы — число уровня" % d)
		check(ok_interval, "%s: промежутки внутри группы не растянуты темпом" % d)


func test_souls_per_wave() -> void:
	print("— души за волну прежние (souls_mult группы)")
	# «Ад» — ровно ×1,3 к «Штатному» (verify 27.09: темп до уровня давал группе из 2 жука с весом
	# 3,0): его группа = множитель уровня к группе «Штатного», вес головы — тот же, что там
	var hell_ok := true
	var max_mult := 0.0
	for map_id in MAPS:
		var nrm: Array = LegionChallenge.apply_map(LegionWorld.load_map(map_id), "normal")["waves"]
		var hel: Array = LegionChallenge.apply_map(LegionWorld.load_map(map_id), "hell")["waves"]
		var k := float(LegionChallenge.value("hell", "count"))
		for i in nrm.size():
			var j := 0
			for g: Dictionary in hel[i]["groups"]:
				if int(g.get("tier", 0)) > 1:
					continue   # группы только «Ада»
				var ng: Dictionary = nrm[i]["groups"][j]
				j += 1
				var m := int(ng.get("count", 1))
				var want := m if String(g.get("type", "zombie")) in LegionChallenge.COUNT_FIXED \
					else maxi(m, floori(m * k + 0.5))
				var sm := float(g.get("souls_mult", 1.0))
				max_mult = maxf(max_mult, sm)
				hell_ok = hell_ok and int(g.get("count", 1)) == want \
					and is_equal_approx(sm, float(ng.get("souls_mult", 1.0)))
	check(hell_ok, "«Ад»: группа = «Штатный» × 1,3, вес головы тот же")
	check(max_mult <= 2.0 + 1e-6, "вес головы не больше 2 (%.2f)" % max_mult)
	for d in ["intern", "normal"]:
		var worst := 0.0
		for map_id in MAPS:
			var raw := _raw_groups(map_id, d)
			var got: Array = LegionChallenge.apply_map(LegionWorld.load_map(map_id), d)["waves"]
			for i in raw.size():
				var before := 0.0
				var after := 0.0
				for j in (raw[i] as Array).size():
					var r: Dictionary = raw[i][j]
					var g: Dictionary = got[i]["groups"][j]
					var per := float(LegionCfg.SOULS_PER_FOE.get(String(r.get("type", "zombie")), 0))
					var n := int(r.get("count", 1))
					var k := float(LegionChallenge.value(d, "count"))
					var type := String(r.get("type", "zombie"))
					var lvl_n := n if d == "intern" or type in LegionChallenge.COUNT_FIXED \
						else maxi(n, floori(n * k + 0.5))
					before += per * lvl_n
					after += per * int(g.get("count", 1)) * float(g.get("souls_mult", 1.0))
				worst = maxf(worst, absf(after - before))
		check(worst < 0.01, "%s: души волны до/после совпали (худшее расхождение %.3f)" % [d, worst])


func _start(map_id: String, d: String) -> void:
	w.dev = {"no_waves": "1", "spawn_units": "0", "difficulty": d}
	w.start_map(map_id)
	w.set_process(false)


func test_hp() -> void:
	print("— массовка толще на всех уровнях, штучные — как прежде")
	check(LegionChallenge.PACE_HP > 1.0, "PACE_HP %.2f > 1" % LegionChallenge.PACE_HP)
	for d in LEVELS:
		_start("fork", d)
		var path := PackedVector2Array([Vector2(340, 100), w.cauldron_pos])
		var z := w.spawn_foe_on_path("zombie", path, path[0], false, {"wave": 1})
		var s := w.spawn_foe_on_path("signer", path, path[0], false, {"wave": 1})
		var lvl := float(LegionChallenge.value(d, "hp"))
		check(is_equal_approx(z.max_hp,
			float(LegionCfg.FOES["zombie"]["hp"]) * LegionChallenge.PACE_HP * lvl),
			"%s: зомби волны %.1f = база × PACE_HP × уровень" % [d, z.max_hp])
		check(is_equal_approx(s.max_hp, float(LegionCfg.FOES["signer"]["hp"]) * lvl),
			"%s: нотариус волны без темпа (%.1f)" % [d, s.max_hp])


func test_live_souls() -> void:
	print("— живые убийства поредевшей группы платят души прежней группы")
	_start("fork", "intern")
	var s0 := w.souls
	var at := Vector2(760, 130)
	# группа из 5 зомби стала 3 (×0,5 → 2,5 → 3): души за троих = душам за пятерых
	for i in 3:
		var z := w.spawn_foe_on_path("zombie", PackedVector2Array([at]), at, false,
			{"wave": 1, "souls_mult": 5.0 / 3.0})
		z.take_damage(100000.0, at)
	check(w.souls - s0 == 15, "три зомби × 5/3 → 15 душ, как пять по 3 (получено %d)"
		% (w.souls - s0))
	var p := LegionChallenge.pace_count("zombie", 5)
	check(p == 3, "pace_count зомби 5 → %d (3)" % p)


func test_respawn_and_staff() -> void:
	print("— возрождение медленнее, штат меньше")
	check(LegionCfg.CAULDRON_RESPAWN > OLD_CAULDRON_RESPAWN * 1.2,
		"Котёл: %.1f с (было 6)" % LegionCfg.CAULDRON_RESPAWN)
	check(LegionCfg.CRYPT_RESPAWN > OLD_CRYPT_RESPAWN * 1.2,
		"склеп: %.1f с (было 8)" % LegionCfg.CRYPT_RESPAWN)
	var ok := true
	for kind: String in OLD_BUILD_RESPAWN:
		var now: Array = LegionCfg.BUILDINGS[StringName(kind)]["respawn"]
		for i in 3:
			ok = ok and float(now[i]) > float(OLD_BUILD_RESPAWN[kind][i]) * 1.2
	check(ok, "постройки: все уровни медленнее прежних ×1,2+ (Бытовка %s)"
		% str(LegionCfg.BUILDINGS[LegionCfg.KIND_LABORER]["respawn"]))
	check(is_equal_approx(LegionCfg.STAFF_FILL_STEP, 0.4), "заполнение новых мест прежнее (0,4 с)")
	check(LegionStaff.paced(LegionCfg.CRYPT_STAFF) < OLD_CRYPT_STAFF,
		"штат склепа %d < 8" % LegionStaff.paced(LegionCfg.CRYPT_STAFF))
	var l1 := LegionStaff.paced(int(LegionCfg.BUILDINGS[LegionCfg.KIND_LABORER]["cap"][0]))
	check(l1 >= 7 and l1 < 10, "Бытовка 1-го ур. %d мест: меньше 10, линия подряда набирается (≥ 7)"
		% l1)
	check(LegionStaff.paced(1) == 1, "штат не падает до нуля")
	w.dev = {"no_waves": "1", "difficulty": "normal"}
	w.start_map("gatehouse")
	w.set_process(false)
	var start := int(LegionWorld.load_map("gatehouse")["start_army"])
	var c := w.staff.cauldron
	check(c.cap < start and c.cap == LegionStaff.paced(start) and w.army_alive() == c.cap,
		"«Проходная»: штат Котла %d < %d карты, выдан сразу" % [c.cap, start])
	check(is_equal_approx(c.respawn_t, LegionCfg.CAULDRON_RESPAWN),
		"«Проходная»: Котёл возрождает раз в %.1f с" % c.respawn_t)


func test_metric() -> void:
	print("— итог боя несёт метрику читаемости")
	_start("fork", "normal")
	var path := PackedVector2Array([Vector2(340, 100), w.cauldron_pos])
	for i in 4:
		w.spawn_foe_on_path("zombie", path, path[0], false, {"wave": 1})
	for i in 30:
		w._step(1.0 / 60.0)
	var fin := w.final_stats(false)
	check(int(fin.get("peak_foes", -1)) == 4, "peak_foes %s (4)" % str(fin.get("peak_foes")))
	check(fin.has("peak_army") and fin.has("avg_foes") and fin.has("avg_army"),
		"peak_army/avg_foes/avg_army в итоге")
	check(not w.stats.has("peak_foes"), "метрика вне stats (эталон трассы бота не двигается)")
