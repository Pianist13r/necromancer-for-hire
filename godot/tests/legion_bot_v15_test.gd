extends SceneTree
## Настоящие набор, путь, расход маны и герой; сохранение владельца не используется.

var w: LegionWorld
var bot: LegionBot
var checks := 0
var fails := 0


func _initialize() -> void:
	_run.call_deferred()


func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		fails += 1
	print("  %s %s" % ["ok" if ok else "FAIL", message])


func fresh(policy := LegionBot.SELECTIVE) -> void:
	w.dev["spawn_units"] = "0"
	w.dev["no_waves"] = "1"
	w.start_map("wasteland")
	w.set_process(false)
	w.terrain = LegionTerrain.new().setup({})
	w.grid.rebuild()
	w.hero.reset()
	bot = LegionBot.new()
	bot.setup(w, policy, {"bot_lines": [{"id": "front", "a": [600, 280],
		"b": [600, 380], "kind": "guard", "role": "front", "dir": [1, 0],
		"min_units": 3, "next_ids": [], "support_id": ""}]})
	w.bot = bot


func _run() -> void:
	Campaign.set_save_path("user://legion_bot_v15_test.cfg")
	Campaign.reset()
	w = (load("res://scenes/legion_world.tscn") as PackedScene).instantiate() as LegionWorld
	w.embedded = true
	root.add_child(w)
	await process_frame
	test_relay()
	test_front_build_hero()
	test_policies()
	test_package()
	test_hints()
	test_flank()
	test_w_exclusions()
	test_rear_warning()
	test_overlap_relay()
	test_no_build_and_call()
	Campaign.reset()
	print("LEGION BOT V15: %d/%d OK" % [checks - fails, checks])
	quit(1 if fails else 0)


func test_relay() -> void:
	fresh()
	for i in 8:
		w.spawn_unit(LegionCfg.KIND_GUARD, Vector2(220, 300 + i * 3))
	w.grid.rebuild()
	var mana := w.contracts.mana
	bot._tick_slot(bot.slots[0])
	check(bot.slots[0]["contracts"].is_empty(), "дальний договор без набора не создаётся")
	check(w.stats["relay_contracts"] == 1, "армия вне радиуса получает промежуточный договор")
	check(w.contracts.mana < mana, "relay оплачивается обычной маной")
	var relay: Contract = w.contracts.contracts[0]
	for post in relay.posts:
		var u: Legionnaire = post["unit"]
		if u != null:
			u.position = post["pos"]
			u._arrive()
	bot._relay_step()
	check(w.stats["releases_manual"] > 0, "доставка завершается настоящим выпуском")
	# Отдельный отказ: единичный боец не оправдывает пустой штрих.
	fresh()
	w.spawn_unit(LegionCfg.KIND_GUARD, Vector2(580, 320))
	w.grid.rebuild()
	mana = w.contracts.mana
	bot._tick_slot(bot.slots[0])
	check(w.contracts.mana == mana, "неполный штат не тратит ману")
	fresh()
	w.terrain = LegionTerrain.new().setup({"water": [
		[[400, 0], [440, 0], [440, 720], [400, 720]]
	]})
	for i in 6:
		w.spawn_unit(LegionCfg.KIND_GUARD, Vector2(390, 300 + i * 3))
	w.grid.rebuild()
	var blocked := bot._place(PackedVector2Array([Vector2(460, 280), Vector2(460, 370)]),
		1, LegionCfg.KIND_GUARD, Vector2.RIGHT, 3)
	check(blocked == null, "река без перехода запрещает набор в пределах радиуса")


func test_front_build_hero() -> void:
	fresh()
	for i in 3:
		w.spawn_foe_on_path("zombie", PackedVector2Array([Vector2(650, 320 + i * 10)]),
			Vector2(650, 320 + i * 10))
	w.grid.rebuild()
	bot._observe()
	check(bot._choose_kind(bot.slots[0]) == LegionCfg.KIND_GUARD, "вахтёр против пехоты")
	for i in 6:
		w.spawn_unit(LegionCfg.KIND_GUARD, Vector2(570, 290 + i * 8))
	bot._tick_slot(bot.slots[0])
	check(not bot.slots[0]["contracts"].is_empty()
		and bot.slots[0]["contracts"][0].kind == LegionCfg.KIND_GUARD,
		"создан настоящий договор вахтёров")
	check(bot.slots[0]["contracts"][0].dir == Vector2.RIGHT, "стрелка из dir подсказки")
	w.souls = 100
	bot._build_step()
	check(w.staff.plots[0]["building"].kind == LegionCfg.KIND_GUARD,
		"постройка по preferred_kinds")
	bot._hero_step()
	check(w.stats["casts_q"] == 1, "Ку по скоплению из трёх врагов")
	bot._hero_step()
	check(w.stats["casts_q"] == 1, "отказ по откату не считается кастом")
	var corpse := w.spawn_foe_on_path("zombie", PackedVector2Array([Vector2(580, 310)]),
		Vector2(580, 310))
	w.spawn_unit(LegionCfg.KIND_GUARD, Vector2(580, 330))
	corpse.take_damage(10000, Vector2.ZERO)
	w._cleanup(0.1)
	# Независимая проверка W: линия и предыдущий Q уже потратили ману.
	w.contracts.mana = w.contracts.mana_max
	bot._hero_step()
	check(w.stats["casts_w"] == 1 and not w._corpses.has(corpse),
		"Дубль-вэ видит свежий труп после уборки кадра")


func test_policies() -> void:
	var baseline: Array = []
	for policy in [LegionBot.HOLD, LegionBot.RELEASE, LegionBot.SELECTIVE,
			LegionBot.MELT, LegionBot.BUTTON]:
		fresh(policy)
		for i in 8:
			w.spawn_unit(LegionCfg.KIND_GUARD, Vector2(220, 300 + i * 3))
		for i in 3:
			w.spawn_foe_on_path("zombie", PackedVector2Array([Vector2(650, 320 + i * 10)]),
				Vector2(650, 320 + i * 10))
		w.grid.rebuild()
		bot.tick(0.1)
		var snapshot := [w.stats["relay_contracts"], w.stats["casts_q"],
			w.stats["buildings_built"], bot._choose_kind(bot.slots[0]), w.contracts.mana]
		if baseline.is_empty():
			baseline = snapshot
		check(snapshot == baseline, "одинаковая логистика/герой/стройка: " + String(policy))
		var c: Contract = w.contracts.contracts[0]
		c.seg_age[0] = c.ttl - 1.0
		var before := int(w.stats["refreshes"])
		# Промежуточные договоры общие; проверяем политику боевого рубежа отдельно.
		bot.slots[0]["contracts"] = [c]
		bot._tick_slot(bot.slots[0])
		check((int(w.stats["refreshes"]) > before) == (policy != LegionBot.RELEASE),
			"решение продления отличается у release: " + String(policy))


func test_package() -> void:
	fresh()
	var pair: Array[Contract] = []
	for k in [LegionCfg.KIND_GUARD, LegionCfg.KIND_CLERK]:
		var x := 600.0 if k == LegionCfg.KIND_GUARD else 552.0
		var c := w.contracts.add_contract(PackedVector2Array([
			Vector2(x, 280), Vector2(x, 350)]), 1, false, k)
		for post in c.posts:
			var u := w.spawn_unit(k, post["pos"])
			u.assign(c, post)
			u._arrive()
		pair.append(c)
	w.contracts.tick_packages(LegionCfg.PACKAGE_HOLD_TIME)
	bot._measure(0.1)
	check(w.stats["packages"] > 0, "счётчик реального пакета")
	w.contracts.refresh(pair[0], PackedInt32Array([0]), false)
	bot.slots[0]["contracts"] = [pair[0]]
	bot._plan_package(bot.slots[0])
	check(bot.slots[0].get("melt_contract") == pair[0], "бот планирует таяние ради печати")
	pair[0].seg_age[0] = pair[0].ttl - 0.1
	bot._refresh_due(pair[0], bot.slots[0])
	w.contracts.tick(0.2, 1.0)
	bot._measure(0.1)
	check(w.stats["seals"] > 0, "счётчик реально выданной печати")
	check(pair[1].seg_alive(0), "поддержка остаётся занятой при таянии фронта")


func test_hints() -> void:
	for id in ["wasteland", "fork", "bridge", "maze", "swamp", "boss"]:
		var map := LegionWorld.load_map(id)
		var ids: Array = []
		for hint in map["bot_lines"]:
			ids.append(hint["id"])
		var valid := true
		for hint in map["bot_lines"]:
			valid = valid and hint.has_all(["id", "kind", "role", "dir", "min_units",
				"next_ids", "support_id"])
			valid = valid and hint["role"] in ["front", "back", "flank", "relay", "rear"]
			valid = valid and ids.has(hint["support_id"]) and int(hint["min_units"]) >= 3
			for next in hint["next_ids"]:
				valid = valid and ids.has(next)
		for plot in map["plots"]:
			valid = valid and plot.has_all(["serves_lines", "preferred_kinds", "bot_priority"])
			for line in plot["serves_lines"]:
				valid = valid and ids.has(line)
		check(valid, "полные подсказки и разрешимые ссылки: " + id)


func test_flank() -> void:
	fresh()
	var slot: Dictionary = bot.slots[0]
	slot["role"] = "flank"
	slot["dir"] = Vector2.UP
	var f := w.spawn_foe_on_path("shield_inspector", PackedVector2Array([Vector2(650, 320)]),
		Vector2(650, 320))
	bot._observe()
	bot._velocity[f.get_instance_id()] = Vector2.LEFT * 28.0
	bot._prepare_flank(slot)
	var tpl: Contract = slot["template"]
	var at := tpl.point_at(tpl.length * 0.5)
	check(at.y > f.position.y and is_equal_approx(at.x, f.position.x),
		"фланговый карман сбоку от измеренного движения щитоносца")
	check(bot._choose_kind(slot) == LegionCfg.KIND_LABORER, "на фланг идут подрядчики")


func test_w_exclusions() -> void:
	fresh()
	var at := Vector2(200, 200)
	var summon := w.spawn_foe_on_path("zombie", PackedVector2Array([at]), at)
	summon.set_meta(&"summoned", true)
	summon.take_damage(10000, Vector2.ZERO)
	var ally := w.spawn_unit(LegionCfg.KIND_LABORER, at)
	ally.alive = false
	ally.state = Legionnaire.State.DEAD
	w._cleanup(0.1)
	check(not w.hero.cast(LegionHero.SLOT_W, at), "W не поднимает свиту и собственных бойцов")
	check(w.hero.cd_left(LegionHero.SLOT_W) == 0.0, "отказ W не тратит откат")


func test_rear_warning() -> void:
	for policy in [LegionBot.SELECTIVE, LegionBot.HOLD, LegionBot.RELEASE]:
		fresh(policy)
		var slot: Dictionary = bot.slots[0]
		slot["role"] = "rear"
		slot["kind"] = LegionCfg.KIND_CLERK
		check(bot._choose_kind(slot) == LegionCfg.KIND_LABORER,
			"rear не выбирает счетовода: " + String(policy))
		for i in 6:
			w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(580, 300 + i * 8))
		w.grid.rebuild()
		bot._tick_slot(slot)
		check(slot["contracts"].is_empty(), "резерв ждёт публичного предупреждения")
		w.breach_warned.emit("crack", 10.0, [{"type": "beetle", "count": 4}])
		for i in 120:
			w._process(1.0 / 60.0)
		check(bot._line_manned(slot), "резерв занял rear до выхода трещины")
		var c: Contract = slot["contracts"][0]
		c.seg_age[0] = c.ttl - 0.1
		var before := int(w.stats["refreshes"])
		bot._tick_slot(slot)
		check(int(w.stats["refreshes"]) > before, "подготовка rear держится даже у release")
		w.breach_opened.emit("crack")
		check(slot["breach_pending"].is_empty(), "открытие возвращает обычную политику")
		w.breach_warned.emit("crack", 10.0, [])
		w.breach_warned.emit("crack", 10.0, [])
		w.breach_opened.emit("crack")
		check(not slot["breach_pending"].is_empty(), "нахлёст предупреждений одного id сохранён")
		slot["kind"] = LegionCfg.KIND_GUARD
		check(bot._choose_kind(slot) == LegionCfg.KIND_GUARD, "rear сохраняет доступный вид данных")


func test_overlap_relay() -> void:
	fresh()
	for i in 6:
		w.spawn_unit(LegionCfg.KIND_GUARD, Vector2(220, 300 + i * 3))
	w.grid.rebuild()
	bot._tick_slot(bot.slots[0])
	check(not bot._relays.is_empty(), "relay создан перед нахлёстом")
	var c: Contract = w.contracts.contracts[0]
	for post in c.posts:
		var u: Legionnaire = post["unit"]
		if u != null:
			u.alive = false
			u.state = Legionnaire.State.DEAD
			post["unit"] = null
	bot._relay_step()
	check(bot._relays.is_empty(), "потерянный relay не продлевается бесконечно")
	w.wave_runner = WaveRunner.new()
	w.wave_runner.setup(w, {"waves": [{"pause": 0.0, "next_in": 0.1, "groups": [
		{"type": "zombie", "road": "east", "count": 2, "interval": 1.0}]},
		{"pause": 10.0, "groups": [
		{"type": "beetle", "road": "east", "count": 2, "interval": 1.0}]}]})
	for i in 180:
		w._process(1.0 / 60.0)
	check(w.wave_runner.wave_no() == 2, "бот пережил две одновременно выпускаемые волны")
	check(w.stats["waves_called"] == 0, "по умолчанию бот не вызывает волну")
	fresh()
	for i in 6:
		w.spawn_unit(LegionCfg.KIND_GUARD, Vector2(220, 300 + i * 3))
	w.grid.rebuild()
	bot._tick_slot(bot.slots[0])
	w.now = LegionCfg.BOT_V16_RELAY_TIMEOUT + 1.0
	bot._relay_step()
	check(bot._relays.is_empty(), "застрявший марш снимается по сроку доставки")


func test_no_build_and_call() -> void:
	fresh()
	w.souls = 1000
	w.dev["no_build"] = "1"
	bot._build_step()
	check(w.stats["buildings_built"] == 0 and w.souls == 1000,
		"no_build запрещает строительство без списания душ")
	w.dev.erase("no_build")
	var slot: Dictionary = bot.slots[0]
	var c := w.contracts.add_contract(slot["pts"], 1, false, LegionCfg.KIND_GUARD)
	slot["contracts"] = [c]
	for post in c.posts:
		var u := w.spawn_unit(LegionCfg.KIND_GUARD, post["pos"])
		u.assign(c, post)
		u._arrive()
	check(bot._line_manned(slot, true), "досрочный вызов требует полного первого рубежа")
	w.wave_runner.setup(w, {"waves": [{"pause": 0.0, "next_in": 50.0,
		"groups": [{"type": "zombie", "road": "east", "count": 1}]},
		{"pause": 10.0, "groups": []}]})
	w.wave_runner.tick(0.1)
	w.wave_runner.tick(0.1)
	w.dev["call_early"] = "1"
	bot._think_t = 0.0
	bot.tick(0.1)
	check(w.stats["waves_called"] == 1, "call_early вызывает волну через публичный API")
	w.dev.erase("call_early")
