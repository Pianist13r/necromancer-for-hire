extends SceneTree
##
## P7 «Схватки» (docs/dev/PVP_PLAN_0929.md): игра по переписке (scripts/dev/corr_play.gd, скилл
## corr-play) в PvP. Настоящий corr_play в настоящей «Дуэли» (боты выключены), ходы пишет тест:
##  1) состояние хода — поля PvP: часы, HP и армия обоих Котлов, армия соперника кучками,
##     координаты Котлов мировые (поле 1600×900);
##  2) штрих `draw` в МИРОВЫХ координатах ложится в мир туда же (камера ×0,8 не сдвигает);
##  3) `tap` по площадке (мир) открывает меню, пункты меню в состоянии — в мировых координатах,
##     `tap` по ним строит здание (координаты туда и обратно проходят один вид);
##  4) `key` Q с `at` (мир) кастует в чужого бойца у чужого Котла;
##  5) HUD «Схватки» считает в счётчике армии только свои (B-340: свободные соперника
##     раньше удваивали «свободно N»);
##  6) одиночка — состояние без блока pvp, штрих по-прежнему в тех же координатах.
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_pvp_corr_test.gd -- --mute
##
## Итог «LEGION PVP CORR: N/M OK»; код выхода 1, если что-то упало.
##

const SAVE := "user://legion_pvp_corr_test.cfg"
const DIR := "user://legion_pvp_corr_test"
const CORR := "res://scripts/dev/corr_play.gd"
const DUEL := "pvp:duel"
## Своя половина «Дуэли» между валунами (480,250 r42) и (640,450 r36), левее стыка (x 770).
const LAB := Vector2(580.0, 150.0)

var w: LegionWorld
var corr: Node
var dir_abs := ""
var _fails := 0
var _checks := 0
var _turn := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(cond: bool, what: String) -> void:
	_checks += 1
	if cond:
		print("  ok   ", what)
	else:
		_fails += 1
		print("  FAIL ", what)


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _near(a: Vector2, b: Vector2, eps := 1.0) -> bool:
	return a.distance_to(b) <= eps


func _pt(a: Variant) -> Vector2:
	return Vector2(float((a as Array)[0]), float((a as Array)[1]))


## Ход N: ждём, пока corr_play выложит состояние, читаем его.
func _state(n: int) -> Dictionary:
	var p := dir_abs.path_join("turn_%03d.json" % n)
	for i in 1200:
		if FileAccess.file_exists(p) and FileAccess.get_file_as_string(dir_abs.path_join("waiting.txt")) == str(n):
			break
		await process_frame
	await _frames(2)
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(p))
	return parsed as Dictionary if parsed is Dictionary else {}


## Записать ход N атомарно (временный файл → переименование) и дождаться хода N+1.
func _move(n: int, move: Dictionary) -> Dictionary:
	var p := dir_abs.path_join("move_%03d.json" % n)
	var f := FileAccess.open(p + ".tmp", FileAccess.WRITE)
	f.store_string(JSON.stringify(move))
	f.close()
	DirAccess.rename_absolute(p + ".tmp", p)
	return await _state(n + 1)


func _duel() -> void:
	Settings.scheme_override = Settings.SCHEME_SLING
	w.dev = {"no_waves": "1", "spawn_units": "0", "pvp_nobot": "1"}
	w.args.erase("bot")
	w.args.erase("pvp_bots")
	w._base_seed = 7
	w.start_map(DUEL)
	w.dev_invuln = false
	w.contracts.mana = w.contracts.mana_max
	await _frames(3)


func _attach(fresh_dir: String) -> void:
	dir_abs = ProjectSettings.globalize_path(fresh_dir)
	DirAccess.make_dir_recursive_absolute(dir_abs)
	for f in DirAccess.get_files_at(dir_abs):
		DirAccess.remove_absolute(dir_abs.path_join(f))
	corr = (load(CORR) as GDScript).new()
	corr.call("setup", w, dir_abs)
	root.add_child(corr)


func _detach() -> void:
	if corr != null:
		corr.queue_free()
		corr = null
	w.hold = false
	await _frames(2)


func _test_state() -> void:
	print("— PvP: состояние хода")
	await _duel()
	# соперник: 5 свободных бойцов у его Котла — «армия соперника кучками»
	for i in 5:
		w.spawn_unit(LegionCfg.KIND_LABORER, w.cauldron_of(1) + Vector2(-140.0, 20.0 * i), null, 1)
	_attach(DIR + "_a")
	var st := await _state(0)
	_check(st.has("pvp"), "в состоянии есть блок pvp")
	var pv: Dictionary = st.get("pvp", {})
	_check(is_equal_approx(float(pv.get("limit", 0.0)), PvpRules.MATCH_LIMIT),
		"предел матча: %s" % pv.get("limit"))
	var me: Dictionary = pv.get("me", {})
	var foe: Dictionary = pv.get("foe", {})
	_check(is_equal_approx(float(me.get("hp", -1.0)), w.cauldron_hp)
		and is_equal_approx(float(foe.get("hp", -1.0)), w.sides[1].cauldron_hp),
		"HP обоих Котлов: %s / %s" % [me.get("hp"), foe.get("hp")])
	_check(_near(_pt(foe.get("at", [0, 0])), w.cauldron_of(1), 1.0)
		and _near(_pt(me.get("at", [0, 0])), w.cauldron_of(0), 1.0),
		"Котлы в мировых координатах: свой %s, чужой %s" % [me.get("at"), foe.get("at")])
	_check(w.world_size == Vector2(1600, 900) and _pt(foe.get("at")).x > 1280.0,
		"чужой Котёл правее 1280 — вне экранных координат одиночки")
	var fa: Array = st.get("foe_army", [])
	var n := 0
	for g: Array in fa:
		n += int(g[2])
	_check(n == 5, "армия соперника кучками: %d бойцов" % n)
	_check(int(pv.get("foe", {}).get("army", -1)) == w.army_alive(1), "армия соперника числом")
	await _detach()


func _test_draw() -> void:
	print("— PvP: штрих и рогатка в мировых координатах")
	await _duel()
	_attach(DIR + "_b")
	await _state(0)
	var a := LAB
	var b := LAB + Vector2(0, 150)
	var st := await _move(0, {"actions": [{"draw": [[a.x, a.y], [b.x, b.y]]}], "wait": 0.5})
	var cs: Array = w.contracts.contracts
	_check(cs.size() == 1, "штрих создал договор (%d)" % cs.size())
	if cs.size() == 1:
		var c: Contract = cs[0]
		var p0 := c.points[0]
		var p1 := c.points[c.points.size() - 1]
		_check(_near(p0, a, 10.0) and _near(p1, b, 10.0),
			"договор в мире под ходом: %s … %s (ждали %s … %s)" % [p0, p1, a, b])
	var segs: Array = []
	for c: Dictionary in st.get("contracts", []):
		segs.append(c)
	st = await _move(1, {"actions": [], "wait": 0.1})
	var found := false
	for c: Dictionary in st.get("contracts", []):
		for g: Dictionary in c["segs"]:
			var at := _pt(g["at"])
			if at.x > 560.0 and at.x < 600.0 and at.y > 140.0 and at.y < 320.0:
				found = true
	_check(found, "участок договора в состоянии — в тех же мировых координатах")
	# рогатка по участку (мир) срывает его
	var grip: Vector2 = w.contracts.contracts[0].seg_center(0)
	var dir: Vector2 = w.contracts.contracts[0].dir
	var pull := grip - dir * 80.0
	# D-1008-C2/C3 (B-345): бойцов на местах нет (spawn_units 0), поэтому остаток после срыва —
	# «пенёк» и гаснет на том же шаге вместе с договором. Факт срыва рогаткой проверяем по
	# самому договору (причина срыва участка 0 — ручная) и счётчику рогатки, а не по тому,
	# что договор остался в списке.
	var torn_c: Contract = w.contracts.contracts[0]
	var slung0 := int(w.stats.get("sling_releases", 0))
	await _move(2, {"actions": [{"sling": [[grip.x, grip.y], [pull.x, pull.y]]}], "wait": 0.2})
	_check(not torn_c.seg_alive(0) and torn_c.release_causes.get(0, &"") == &"manual"
		and int(w.stats.get("sling_releases", 0)) == slung0 + 1,
		"рогатка по участку в мировых координатах сорвала его (причины %s)" % torn_c.release_causes)
	_check(not w.contracts.contracts.has(torn_c),
		"остаток без бойцов погас пеньком (D-1008-C3)")
	await _detach()


func _test_menu_and_cast() -> void:
	print("— PvP: меню площадки в мировых координатах, Ку")
	await _duel()
	w.souls = 5000
	var plot: Dictionary = {}
	for p: Dictionary in w.staff.plots:
		if String(p.get("id", "")) == "s0_a":
			plot = p
	_check(not plot.is_empty(), "площадка s0_a есть")
	if plot.is_empty():
		return
	var pos: Vector2 = plot["pos"]
	var enemy := w.spawn_unit(LegionCfg.KIND_LABORER, w.cauldron_of(1) + Vector2(-140.0, 0.0), null, 1)
	_attach(DIR + "_c")
	await _state(0)
	var st := await _move(0, {"actions": [{"tap": [pos.x, pos.y]}], "wait": 0.0})
	var menu: Array = st.get("menu", [])
	_check(menu.size() >= 1, "меню открылось, пунктов %d" % menu.size())
	if menu.is_empty():
		await _detach()
		return
	var item := _pt((menu[0] as Dictionary)["at"])
	# пункт — в мировых координатах: рядом с площадкой (в экранных он был бы левее на 20 %)
	var scr := w.world_to_screen(item)
	var scr_pos := w.world_to_screen(pos)
	_check(item.x > pos.x + 100.0 and absf((scr.x - scr_pos.x) - (item.x - pos.x) * 0.8) < 1.0,
		"пункт меню в мировых координатах: (%d,%d), площадка (%d,%d)" % [item.x, item.y, pos.x, pos.y])
	var before := w.buildings.size()
	st = await _move(1, {"actions": [{"tap": [item.x, item.y]}], "wait": 0.3})
	_check(w.buildings.size() == before + 1, "tap по пункту построил здание (%d → %d)" % [before,
		w.buildings.size()])
	# Ку: клавиша Q с at в мире
	var hp0 := enemy.hp
	var spot := enemy.position
	await _move(2, {"actions": [{"key": "Q", "at": [spot.x, spot.y]}], "wait": 0.2})
	var at: Vector2 = w.hero.last_cast.get("at", Vector2.INF)
	_check(_near(at, spot, 2.0), "Ку — в точку мира: %s (боец %s)" % [at, spot])
	_check(enemy.hp < hp0 or not enemy.alive, "чужой боец задет: %.1f → %.1f" % [hp0, enemy.hp])
	# второй Ку сразу: в откате — не сработает, и ход об этом предупреждает (B-350, инструмент)
	var cd_before := w.hero.cd_left(0)
	st = await _move(3, {"actions": [{"key": "Q", "at": [spot.x, spot.y]}], "wait": 0.1})
	var warn: Array = st.get("warn", [])
	_check(cd_before > 0.0 and warn.size() == 1 and String(warn[0]).contains("откате"),
		"Ку в откате — предупреждение хода: %s" % [warn])
	st = await _move(4, {"actions": [], "wait": 0.1})
	_check((st.get("warn", []) as Array).is_empty(), "предупреждение живёт один ход")
	await _detach()


func _test_hud_count() -> void:
	print("— HUD «Схватки»: счётчик армии только своих (B-340)")
	await _duel()
	for i in 6:
		w.spawn_unit(LegionCfg.KIND_LABORER, w.cauldron_of(1) + Vector2(-100.0, 15.0 * i), null, 1)
	for i in 3:
		w.spawn_unit(LegionCfg.KIND_LABORER, w.cauldron_of(0) + Vector2(100.0, 15.0 * i), null, 0)
	w.hud._t = 0.0
	w.hud.tick(0.0)
	var plate: Object = w.hud._plate
	var mine := 0
	for u in w.units:
		mine += int(u.alive and u.side == 0 and u.state == Legionnaire.State.FREE)
	_check(int(plate.get("_free")) == mine and mine >= 3,
		"«свободно» = только свои: %d (своих %d, чужих %d)" % [int(plate.get("_free")), mine,
			w.army_alive(1)])


func _test_lull_hint() -> void:
	print("— «Схватка»: совета «F зовёт волну» нет (B-341)")
	Settings.scheme_override = Settings.SCHEME_SLING
	w.dev = {"spawn_units": "0", "pvp_nobot": "1"}
	w.args.erase("bot")
	w.args.erase("pvp_bots")
	w.start_map(DUEL)
	await _frames(3)
	var was_hints := Settings.hints_enabled()
	Settings.set_hints(true)
	w.dev_invuln = true
	var could_call := false
	var offered := false
	# 100 с боя шагами мира: волна 1 уходит на 60-й секунде, дальше затишье, где раньше
	# (в одиночке и так — и сейчас) совет предлагался бы, будь волну можно звать
	for i in 6000:
		w._step(1.0 / 60.0)
		if i % 15 == 0:
			could_call = could_call or w.wave_runner.can_call()
			w.intuit.scan()
			for l: Dictionary in w.intuit._labels:
				offered = offered or String(l["type"]) == "call"
	_check(could_call, "проверка не пустая: в затишье волну «можно было бы звать» (can_call)")
	_check(not offered and w.intuit.hints_shown(&"call") == 0,
		"в «Схватке» совет про F не предлагается")
	Settings.set_hints(was_hints)


func _test_single() -> void:
	print("— одиночка: состояние без pvp, координаты прежние")
	Settings.scheme_override = Settings.SCHEME_SLING
	w.dev = {"no_waves": "1", "spawn_units": "0"}
	w.args.erase("bot")
	w.args.erase("pvp_bots")
	w.start_map("_gray")
	w.dev_invuln = false
	w.contracts.mana = w.contracts.mana_max
	await _frames(3)
	_attach(DIR + "_d")
	var st := await _state(0)
	_check(not st.has("pvp") and not st.has("foe_army"), "в одиночке блока pvp нет")
	var a := Vector2(300, 200)
	var b := Vector2(300, 320)
	await _move(0, {"actions": [{"draw": [[a.x, a.y], [b.x, b.y]]}], "wait": 0.3})
	var cs: Array = w.contracts.contracts
	_check(cs.size() == 1 and _near(cs[0].points[0], a, 10.0),
		"штрих одиночки — под ходом (%s)" % [cs[0].points[0] if cs.size() == 1 else "нет"])
	await _detach()


func _run() -> void:
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	w = scene.instantiate() as LegionWorld
	root.add_child(w)
	await _frames(2)
	await _test_state()
	await _test_draw()
	await _test_menu_and_cast()
	await _test_hud_count()
	await _test_lull_hint()
	await _test_single()
	Campaign.reset()
	print("LEGION PVP CORR: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)
