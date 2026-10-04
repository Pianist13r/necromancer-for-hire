extends SceneTree
##
## Регресс «вызова» (медленная сессия slow/challenge, 26.09.2026). Игорь 26.09: «можно легко
## пройти одним типом только линий… надо баланса и сложности добавить и вызова».
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_challenge_test.gd -- --mute
##
## Проверяет: «Стажёр» — прежние волны и сила бит в бит; «Штатный»/«Ад» меняют силу по одной
## таблице в одной точке рождения; выбор хранится в настройках и применяется к бою; флаг бота
## kinds=laborer ставит только подряд; на «Развилке» колонна щитоносцев прорывает подряд и не
## прорывает охрану равной численности; на «Мосте» волна призраков не гибнет от строя подряда;
## у каждой карты одна кульминация с наградой.
##
## Новый код берётся динамически (load по пути, Settings.get/set): на старом коде файл
## разбирается, и каждая новая проверка падает отдельной строкой FAIL, а не ошибкой разбора.
## Настройки — свой файл user://settings_challenge_test.cfg; сохранение кампании — своё.
## Итог «LEGION CHALLENGE: N/M OK»; код выхода 1, если что-то упало.
##

const SAVE := "user://legion_challenge_test.cfg"
const SETTINGS_FILE := "user://settings_challenge_test.cfg"
const CH_PATH := "res://scripts/legion/legion_challenge.gd"
const PICKER_PATH := "res://scripts/legion/ui/difficulty_picker.gd"
const MAPS: Array[String] = ["wasteland", "fork", "bridge", "maze", "swamp", "boss"]
const DT := 1.0 / 60.0
## Куда test_bridge_ghosts уводит лишних свободных: юго-восточный угол «Развилки», дальше
## HOME_GUARD_R + HOME_GUARD_PURSUE от Котла и вдали от северной дороги призраков.
const FAR_CORNER := Vector2(1240, 690)

var w: LegionWorld
var ch: Variant = null
var settings: GDScript = null
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
	settings = load("res://scripts/common/settings.gd")
	if ResourceLoader.exists(CH_PATH):
		ch = load(CH_PATH)
	check(ch != null, "есть таблица сложности LegionChallenge")
	w = (load("res://scenes/legion_world.tscn") as PackedScene).instantiate() as LegionWorld
	w.embedded = true
	root.add_child(w)
	root.size = Vector2i(1280, 720)
	await process_frame
	w.set_process(false)
	test_intern_identity()
	test_table_one_point()
	test_settings_persist()
	test_bot_laborer_only()
	test_fork_shields()
	test_bridge_ghosts()
	test_climax()
	# правки по verifier 26.09 (падают на a106325)
	test_agent_run_keeps_owner_file()
	test_shield_charge_cone()
	test_briefing()
	test_tutorial_intern()
	settings.set("difficulty_override", "")
	Campaign.reset()
	print("LEGION CHALLENGE: %d/%d OK" % [checks - fails, checks])
	quit(1 if fails else 0)


# ── помощники ────────────────────────────────────────────────────────────────

func _raw_without_tier(map_id: String) -> Array:
	var out: Array = []
	for wave: Dictionary in LegionWorld.load_map(map_id)["waves"]:
		var nw := wave.duplicate(true)
		var groups: Array = []
		for g: Dictionary in nw["groups"]:
			if not g.has("tier"):
				groups.append(g)
		nw["groups"] = groups
		out.append(nw)
	return out


## Исходные волны без tier, прореженные темпом читаемости D-0927-49: «массовка» (PACE_THIN) —
## pace_count, души поредевшей группы — souls_mult. Остальное — как в карте.
func _paced(waves: Array) -> Array:
	for wave: Dictionary in waves:
		for g: Dictionary in wave["groups"]:
			var n := int(g.get("count", 1))
			var m := int(ch.pace_count(String(g.get("type", "zombie")), n))
			if m != n:
				g["count"] = m
				g["souls_mult"] = float(n) / float(m)
	return waves


## Число группы на уровне d после темпа (как LegionChallenge._scaled_group).
func _level_n(type: String, n: int, d: String) -> int:
	var m := int(ch.pace_count(type, n))
	if d == "intern":
		return m
	return maxi(m, floori(m * float(ch.value(d, "count")) + 0.5))


func _applied(map_id: String, d: String) -> Array:
	if ch == null:
		return []
	return ch.apply_map(LegionWorld.load_map(map_id), d)["waves"]


## Групп вида type на дороге road в волне i (уже применённой).
func _count(waves: Array, i: int, type: String, road := "") -> int:
	var n := 0
	if i < 0 or i >= waves.size():
		return 0
	for g: Dictionary in waves[i]["groups"]:
		if String(g["type"]) == type and (road == "" or String(g.get("road", "")) == road):
			n += int(g["count"])
	return n


func _start(map_id: String, d: String, waves := false) -> void:
	w.dev.erase("no_waves")
	if not waves:
		w.dev["no_waves"] = "1"
	w.dev["spawn_units"] = "0"
	if d == "":
		w.dev.erase("difficulty")
	else:
		w.dev["difficulty"] = d
	w.start_map(map_id)
	w.set_process(false)


## Стена n бойцов вида kind поперёк северной дороги «Развилки» (земля без оград — как в
## legion_press_test: ограды легли ровно туда, где сцена ставит стену).
func _wall(kind: StringName, n_units: int, d: String) -> Contract:
	_start("fork", d)
	var bare := w.map.duplicate(true)
	bare.erase("walls")
	w.terrain = LegionTerrain.new().setup(bare)
	w.dev_invuln = true
	for i in n_units:
		w.spawn_unit(kind, Vector2(300.0 + 8.0 * float(i % 10), 262.0 + 6.0 * float(i / 10)))
	var pts := PackedVector2Array([Vector2(290, 230), Vector2(390, 230)])
	var c := w.contracts.add_contract(pts, w.contracts.default_side(pts), false, kind)
	c.set_dir(Vector2.UP)
	c.ttl = 9999.0
	for step in roundi(4.0 / DT):
		w._step(DT)
	w.dev_invuln = false
	return c


## Колонна по дороге сверху: сначала types[0] × counts[0], за ним следующие, шаг 18 px.
func _column(types: Array, counts: Array) -> Array[Foe]:
	var path := PackedVector2Array([Vector2(340, 160), Vector2(340, 290), Vector2(180, 360)])
	var out: Array[Foe] = []
	var k := 0
	for j in types.size():
		for i in int(counts[j]):
			var at := Vector2(340.0 + (6.0 if k % 2 == 0 else -6.0), 150.0 - 18.0 * float(k))
			var f := w.spawn_foe_on_path(String(types[j]), path, at, false, {"wave": 1})
			if f != null:
				out.append(f)
			k += 1
	return out


# ── проверки ─────────────────────────────────────────────────────────────────

func test_intern_identity() -> void:
	# D-0927-49: «Стажёр» = прежние волны × темп читаемости (не бит в бит с картой) — проверка
	# та же, эталон — карта, прореженная по PACE_THIN, а не голая карта
	print("— «Стажёр»: прежние волны × темп читаемости, сила × PACE_HP")
	for map_id in MAPS:
		var got := _applied(map_id, "intern")
		var same := got.size() == _raw_without_tier(map_id).size()
		var want := _paced(_raw_without_tier(map_id)) if ch != null else []
		for i in mini(got.size(), want.size()):
			var a: Dictionary = (got[i] as Dictionary).duplicate(true)
			a.erase("climax")
			var b: Dictionary = (want[i] as Dictionary).duplicate(true)
			b.erase("climax")
			same = same and a == b
		check(ch != null and same, "%s: волны «Стажёра» = исходные без групп tier" % map_id)
	_start("fork", "intern")
	var f := w.spawn_foe_on_path("zombie", PackedVector2Array([Vector2(340, 100),
		w.cauldron_pos]), Vector2(340, 100), false, {"wave": 1})
	var pace_hp := float(ch.PACE_HP) if ch != null else 1.0
	check(w.get("difficulty") == "intern" and pace_hp > 1.0
		and is_equal_approx(f.max_hp, float(LegionCfg.FOES["zombie"]["hp"]) * pace_hp),
		"«Стажёр»: HP зомби волны %.0f × PACE_HP %.2f" % [float(LegionCfg.FOES["zombie"]["hp"]),
		pace_hp])


func test_table_one_point() -> void:
	print("— «Штатный»/«Ад»: одна таблица, одна точка рождения")
	for d in ["normal", "hell"]:
		if ch == null:
			check(false, "%s: таблица" % d)
			continue
		var k := float(ch.value(d, "count"))
		var hp_k := float(ch.value(d, "hp"))
		var raw: Array = LegionWorld.load_map("fork")["waves"]
		var got := _applied("fork", d)
		var n := int(raw[1]["groups"][0]["count"])
		var want := _level_n("zombie", n, d)   # темп D-0927-49 под уровнем
		var paced_n := int(ch.pace_count("zombie", n))
		check(int(got[1]["groups"][0]["count"]) == want and (k <= 1.0 or want > paced_n),
			"%s: зомби волны 2 «Развилки» %d → %d (×%.2f)" % [d, n, want, k])
		check(is_equal_approx(float(got[1]["groups"][0]["interval"]),
			float(raw[1]["groups"][0]["interval"]) * float(ch.value(d, "interval"))),
			"%s: колонна плотнее (интервал ×%.2f)" % [d, float(ch.value(d, "interval"))])
		var lawyers_ok := true
		for map_id in MAPS:
			var waves := _applied(map_id, d)
			for i in waves.size():
				lawyers_ok = lawyers_ok and _count(waves, i, "lawyer") <= 2 \
					and _count(waves, i, "boss") <= 1
		check(lawyers_ok, "%s: Юристов не больше 2 за волну, Прораб один" % d)
		_start("fork", d)
		var path := PackedVector2Array([Vector2(340, 100), w.cauldron_pos])
		var wave_foe := w.spawn_foe_on_path("zombie", path, Vector2(340, 100), false, {"wave": 1})
		var summoned := w.spawn_foe_on_path("zombie", path, Vector2(340, 100), true, {"wave": 1})
		var dev_foe := w.spawn_foe_on_path("zombie", path, Vector2(340, 100))
		var base := float(LegionCfg.FOES["zombie"]["hp"])
		var hp_all := hp_k * float(ch.PACE_HP)   # темп D-0927-49 × уровень
		check(w.get("difficulty") == d and is_equal_approx(wave_foe.max_hp, base * hp_all)
			and is_equal_approx(wave_foe.hp, base * hp_all),
			"%s: HP зомби волны %.1f = %.0f × %.2f × PACE_HP" % [d, wave_foe.max_hp, base, hp_k])
		check(summoned.max_hp == base and dev_foe.max_hp == base,
			"%s: свита Прораба и враг вне волны — без множителя" % d)


func test_settings_persist() -> void:
	print("— выбор хранится в настройках и применяется к бою")
	var old_path: Variant = settings.get("path")
	if old_path == null:
		check(false, "Settings: путь файла и сложность (нет на старом коде)")
		check(false, "переключатель в меню")
		return
	settings.set("path", SETTINGS_FILE)
	settings.set("_cfg", null)
	settings.set("difficulty_override", "")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SETTINGS_FILE))
	check(settings.call("difficulty") == "normal", "без файла — «Штатный» по умолчанию")
	settings.call("set_difficulty", "hell")
	settings.set("_cfg", null)
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_FILE)
	check(cfg.get_value("game", "difficulty", "") == "hell" and settings.call("difficulty") == "hell",
		"«Ад» записан в файл настроек и перечитан")
	_start("fork", "")
	var raw_n := int(LegionWorld.load_map("fork")["waves"][1]["groups"][0]["count"])
	check(w.get("difficulty") == "hell" and int(w.map["waves"][1]["groups"][0]["count"])
		== _level_n("zombie", raw_n, "hell"),
		"бой без --dev берёт уровень из настроек и раскладывает волны под него")
	var picker: Control = (load(PICKER_PATH) as GDScript).new()
	root.add_child(picker)
	picker.call("select", "intern")
	settings.set("_cfg", null)
	cfg.load(SETTINGS_FILE)
	check(cfg.get_value("game", "difficulty", "") == "intern"
		and (picker.get("buttons")["intern"] as Button).button_pressed
		and not (picker.get("buttons")["hell"] as Button).button_pressed,
		"переключатель: «Стажёр» нажат, записан, «Ад» отжат")
	picker.queue_free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SETTINGS_FILE))
	settings.set("path", old_path)
	settings.set("_cfg", null)


func test_bot_laborer_only() -> void:
	print("— флаг бота kinds=laborer: только подряд (линии и постройки)")
	for only in [false, true]:
		if only:
			w.dev["kinds"] = "laborer"
		_start("fork", "normal", true)
		w.bot = LegionBot.new()
		w.bot.setup(w, LegionBot.SELECTIVE, w.map)
		w.contracts.human_input = false
		for step in roundi(90.0 / DT):
			w._step(DT)
			if w.phase != LegionWorld.Phase.BATTLE:
				break
		var kinds := {}
		for p: Dictionary in w.staff.plots:
			if p["building"] != null:
				kinds[String((p["building"] as LegionBuilding).kind)] = true
		var guards := int(w.stats.get("contracts_guard", 0))
		var clerks := int(w.stats.get("contracts_clerk", 0))
		var labor := int(w.stats.get("contracts_laborer", 0))
		print("    (kinds=%s: подряд %d, охрана %d, аудит %d, постройки %s)" % [
			"laborer" if only else "все", labor, guards, clerks, kinds.keys()])
		if only:
			check(guards == 0 and clerks == 0 and labor > 0, "только линии подряда")
			check(kinds.keys().all(func(k: String) -> bool: return k == "laborer"),
				"только постройки подряда")
		else:
			check(guards > 0, "без флага бот ставит и охрану (флаг что-то меняет)")
		w.bot = null
		w.dev.erase("kinds")


func test_fork_shields() -> void:
	print("— «Развилка»: щитоносцы впереди колонны прорывают подряд, охрану — нет")
	var waves := _applied("fork", "normal")
	var first := -1
	var lead := true
	for i in waves.size():
		if _count(waves, i, "shield_inspector") > 0 and first < 0:
			first = i
		for g: Dictionary in waves[i]["groups"]:
			if String(g["type"]) != "shield_inspector":
				continue
			for z: Dictionary in waves[i]["groups"]:
				if String(z["type"]) == "zombie" and z["road"] == g["road"] \
						and not z.has("tier"):
					lead = lead and float(g.get("delay", 0.0)) <= float(z.get("delay", 0.0))
	check(first >= 0 and first <= 2, "щитоносцы с волны %d «Развилки» (не позже 3-й)" % (first + 1))
	check(first >= 0 and lead, "щиты идут впереди основных колонн зомби на своей дороге")
	var climax := -1
	for i in waves.size():
		if bool(waves[i].get("climax", false)):
			climax = i
	var shields := _count(waves, climax, "shield_inspector", "north") if climax >= 0 else 0
	var zombies := 8
	check(shields >= 4, "в кульминации «Развилки» на севере щитоносцев: %d (≥4)" % shields)
	var res := {}
	for kind in [LegionCfg.KIND_LABORER, LegionCfg.KIND_GUARD]:
		var c := _wall(kind, 14, "normal")
		_column(["shield_inspector", "zombie"], [shields, zombies])
		for step in roundi(30.0 / DT):
			w._step(DT)
		res[kind] = int(w.stats.get("press_breaks", 0))
		print("    (%s ×14 против %d щитов + %d зомби: прорывов %d, потерь %d)" % [kind,
			shields, zombies, res[kind], int(w.stats.get("lost", 0))])
		c.ttl = 0.0
	check(shields > 0 and int(res[LegionCfg.KIND_LABORER]) >= 1, "подряд прорван")
	check(shields > 0 and int(res[LegionCfg.KIND_GUARD]) == 0, "охрану равной численности не прорвали")


func test_bridge_ghosts() -> void:
	print("— «Мост»: волна призраков проходит сквозь строй подряда")
	var waves := _applied("bridge", "normal")
	var most := 0
	var at := -1
	for i in waves.size():
		var n := _count(waves, i, "ghost", "north")
		if n > most:
			most = n
			at = i
	check(most >= 8, "волна призраков «Моста»: %d на северной дороге в волне %d (≥8)" % [most,
		at + 1])
	for kind in [LegionCfg.KIND_LABORER, LegionCfg.KIND_CLERK]:
		_wall(kind, 14, "normal")
		# проверка — про строй. Лишние четверо свободных стоят в 144–177 px от Котла «Развилки», в
		# зоне дома: с «обороной дома» (slow/home-guard) они сами ловят призраков у Котла, и урон
		# мерил бы уже их, а не стену — уводим их в угол карты, подальше от дороги и Котла
		for u in w.units:
			if u.state == Legionnaire.State.FREE:
				u.position = FAR_CORNER
		var hp0 := w.cauldron_hp
		var ghosts := _column(["ghost"], [maxi(most, 1)])
		for step in roundi(40.0 / DT):
			w._step(DT)
		var dead := 0
		for f in ghosts:
			if not f.alive:
				dead += 1
		var dmg := hp0 - w.cauldron_hp
		print("    (%s ×14: убито призраков %d из %d, урон Котлу %.0f)" % [kind, dead, ghosts.size(),
			dmg])
		if kind == LegionCfg.KIND_LABORER:
			check(most >= 8 and dmg >= 20.0 * most * 0.75,
				"строй подряда пропустил волну: урон Котлу %.0f из %.0f" % [dmg, hp0])
		else:
			check(dmg <= 20.0 * most * 0.25, "аудит равной численности волну снял: урон Котлу %.0f"
				% dmg)


func test_climax() -> void:
	print("— кульминация: одна на карту, предпоследняя волна, награда по уровню")
	for map_id in MAPS:
		var waves: Array = LegionWorld.load_map(map_id)["waves"]
		var idx: Array[int] = []
		for i in waves.size():
			if bool(waves[i].get("climax", false)):
				idx.append(i)
		check(idx.size() == 1 and idx[0] == waves.size() - 2,
			"%s: кульминация — волна %s из %d" % [map_id, str(idx.map(func(i: int) -> int:
				return i + 1)), waves.size()])
	# Та же волна с флагом и без: разница душ — ровно премия (остальное — обычные души за клир).
	for d in ["intern", "normal"]:
		var got := {}
		for climax in [false, true]:
			_start("wasteland", d)
			var wr := w.wave_runner
			wr.setup(w, {"waves": [{"pause": 0.0, "next_in": 999.0, "climax": climax, "groups": [
				{"road": "east", "type": "zombie", "count": 1, "interval": 0.1, "delay": 0.0}]},
				{"pause": 5.0, "groups": [{"road": "east", "type": "zombie", "count": 1}]}]})
			for step in 3:
				wr.tick(DT)
			for f in w.foes:
				f.take_damage(9999.0, f.position)
			var souls := w.souls
			for step in 30:
				wr.tick(DT)
			got[climax] = w.souls - souls
		var want := int(ch.value(d, "climax_souls")) if ch != null else -1
		var bonus := int(got[true]) - int(got[false])
		check(ch != null and bonus == want and (d == "intern" or want > 0),
			"%s: отбитая кульминация даёт %d душ сверх клира (получено %d)" % [d, want, bonus])


# ── правки по verifier 26.09 ─────────────────────────────────────────────────

## Агентный прогон (--mute) с настоящим путём настроек: выбор — только в память, файл владельца
## не трогается (как scheme_override/economy_override). На a106325 set_difficulty писал файл —
## поэтому на старом коде этот тест гоняют только с APPDATA-песочницей.
func test_agent_run_keeps_owner_file() -> void:
	print("— агентный прогон: выбор сложности не пишет файл настроек владельца")
	var real := String(settings.get("PATH")) if settings.get("PATH") != null else "user://settings.cfg"
	settings.set("path", real)
	settings.set("_cfg", null)
	settings.set("difficulty_override", "")
	var mtime := FileAccess.get_modified_time(real) if FileAccess.file_exists(real) else 0
	var before: Variant = (settings.call("_file") as ConfigFile).get_value("game", "difficulty", "—")
	settings.call("set_difficulty", "hell")
	var picker: Control = (load(PICKER_PATH) as GDScript).new()
	root.add_child(picker)
	picker.call("select", "hell")
	var cfg := settings.call("_file") as ConfigFile
	var after: Variant = cfg.get_value("game", "difficulty", "—")
	var mtime2 := FileAccess.get_modified_time(real) if FileAccess.file_exists(real) else 0
	check(settings.call("difficulty") == "hell", "выбор действует в прогоне (в памяти)")
	check(after == before and mtime2 == mtime,
		"settings.cfg не тронут: ключ %s → %s, время %d → %d" % [str(before), str(after), mtime,
		mtime2])
	picker.queue_free()
	settings.set("difficulty_override", "")


## Щит «Штатного»: ×0,25 — только удар с разбега и только в конусе ±55° хода; удары в окне
## после натиска и «Точно!» во фланг — полные.
func test_shield_charge_cone() -> void:
	print("— щит: разбег в лоб ослаблен, после натиска и во фланг — полный удар")
	_start("fork", "normal")
	w.terrain = LegionTerrain.new().setup({})
	var at := Vector2(700, 360)
	var path := PackedVector2Array([at, Vector2(200, 360)])   # идёт влево
	var shield := w.spawn_foe_on_path("shield_inspector", path, at, false, {"wave": 1})
	if ch != null:
		var ang := {0.0: 0.25, 50.0: 0.25, 60.0: 1.0, 84.0: 1.0, 90.0: 1.0}
		var ok := true
		var got := PackedStringArray()
		for deg: float in ang:
			var from := at + Vector2.LEFT.rotated(deg_to_rad(deg)) * 20.0
			var m := float(ch.charge_mult(shield, from))
			got.append("%.0f°→%.2f" % [deg, m])
			ok = ok and is_equal_approx(m, float(ang[deg]))
		check(ok, "конус лба ±%.0f°: %s" % [float(ch.get("SHIELD_FRONT_DEG")) if ch.get(
			"SHIELD_FRONT_DEG") != null else -1.0, ", ".join(got)])
	else:
		check(false, "конус лба щита")
	var res := {}
	for side in ["front", "flank"]:
		for f in w.foes:
			f.queue_free()
		w.foes.clear()
		for u in w.units:
			u.queue_free()
		w.units.clear()
		shield = w.spawn_foe_on_path("shield_inspector", path, at, false, {"wave": 1})
		var dir := Vector2.RIGHT if side == "front" else Vector2.DOWN
		var u := w.spawn_unit(LegionCfg.KIND_LABORER, at - dir * 60.0)
		var volley := {"perfect": true, "hit": false, "manual": false, "dmg": 1.0,
			"combo_mult": 1.0, "knocked": {}, "dir": dir, "units": 0}
		u.start_charge(dir, volley)
		var hp0 := shield.hp
		for step in 120:
			w.grid.rebuild()
			u.tick(DT)
			if shield.hp < hp0:
				break
		var ram := hp0 - shield.hp
		# следующий удар в окне после натиска (_bonus_t): вплотную, без отката
		u.position = shield.position - dir * 18.0
		u.set("_atk_cd", 0.0)
		w.grid.rebuild()
		var hp1 := shield.hp
		u.call("_tick_free", DT)
		res[side] = [ram, hp1 - shield.hp]
	var base := float(LegionCfg.UNIT_KINDS[LegionCfg.KIND_LABORER]["dmg"]) \
		* float(LegionCfg.UNIT_KINDS[LegionCfg.KIND_LABORER]["charge_dmg_mult"])
	var perfect := base * LegionCfg.PERFECT_FIRST_MULT
	print("    (разбег «Точно!»: лоб %.2f, фланг %.2f; удар после натиска: лоб %.2f, фланг %.2f)"
		% [res["front"][0], res["flank"][0], res["front"][1], res["flank"][1]])
	check(is_equal_approx(float(res["front"][0]), perfect * 0.25),
		"«Точно!» в лоб щита ×0,25: %.2f" % float(res["front"][0]))
	check(is_equal_approx(float(res["flank"][0]), perfect), "«Точно!» во фланг — полный: %.2f"
		% float(res["flank"][0]))
	check(is_equal_approx(float(res["front"][1]), base) and is_equal_approx(float(res["flank"][1]),
		base), "удар в окне после натиска полный и в лоб, и во фланг: %.2f / %.2f" % [
		float(res["front"][1]), float(res["flank"][1])])


## Брифинг: щитоносец назван по-русски, враги — по уровню боя.
func test_briefing() -> void:
	print("— брифинг: «Щитоносец» и волны по уровню")
	check(String(Briefing.FOE_NAMES.get("shield_inspector", "")) == "Щитоносец",
		"FOE_NAMES знает щитоносца")
	var b := Briefing.new()
	var fork := Campaign.map("fork")
	settings.set("difficulty_override", "intern")
	var intern: Array[String] = b.call("_threat_list", fork)
	settings.set("difficulty_override", "normal")
	var normal: Array[String] = b.call("_threat_list", fork)
	b.free()
	check(not intern.has("Щитоносец") and not intern.has("shield_inspector"),
		"«Стажёр»: на «Развилке» щитоносцев в брифинге нет: %s" % ", ".join(intern))
	check(normal.has("Щитоносец"), "«Штатный»: щитоносец в брифинге есть: %s" % ", ".join(normal))
	settings.set("difficulty_override", "")


## Обучение «Пустыря» — всегда «Стажёр», даже если заранее выбран «Ад».
func test_tutorial_intern() -> void:
	print("— обучение «Пустыря» идёт «Стажёром»")
	settings.set("difficulty_override", "hell")
	_start("wasteland", "", true)
	var before: Variant = w.get("difficulty")
	w.start_tutorial()
	var raw: Array = LegionWorld.load_map("wasteland")["waves"]
	# D-0927-49: «как в карте» теперь — карта × темп читаемости «Стажёра» (без множителя «Ада»)
	var raw_n := _level_n("zombie", int(raw[1]["groups"][0]["count"]), "intern")
	var same := int(w.map["waves"][1]["groups"][0]["count"]) == raw_n
	check(before == "hell" and w.get("difficulty") == "intern" and same
		and int(w.wave_runner.waves[1]["groups"][0]["count"]) == raw_n,
		"до обучения %s, с обучением %s, волна 2 — %d зомби (карта × темп)" % [str(before),
		str(w.get("difficulty")), int(w.wave_runner.waves[1]["groups"][0]["count"])])
	if w.tutorial != null:
		w.tutorial.teardown()
		w.tutorial = null
	settings.set("difficulty_override", "")
