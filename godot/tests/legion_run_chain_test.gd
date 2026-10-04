extends SceneTree
##
## B-358: регресс раннера забега цепочкой (legion_run_chain.gd) — механика переноса без полного
## боя: бой каждого объекта кончает хук через world.force_end, как legion_endless_flow_test.
## Проверяет: k растёт, объект k+1 — gen:<тот же сид>:k+1, поправка взята из предложенных
## и записана, премия начислена и потрачена жадно, артефакт переносится в следующий бой, бот и сид
## боя попали в мир, сложность закреплена; поражение закрывает забег; настоящее сохранение цело.
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_run_chain_test.gd -- --mute
##

const Chain := preload("res://tests/legion_run_chain.gd")
const RUN_SEED := 3341246352
const SAVE := "user://legion_run_chain_test_run.cfg"

var _checks := 0
var _fails := 0
var _item: StringName = &""
var _k2_owned: Array[StringName] = []
var _k2_bot := ""
var _k2_seed := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(cond: bool, what: String) -> void:
	_checks += 1
	if cond:
		print("  ok   ", what)
	else:
		_fails += 1
		print("  FAIL ", what)


func _real_save_stamp() -> String:
	if not FileAccess.file_exists(Campaign.PATH):
		return "нет файла"
	return FileAccess.get_md5(Campaign.PATH)


func _run() -> void:
	var real_before := _real_save_stamp()
	_item = LegionItemDb.ids()[0]
	await _test_two_victories()
	await _test_defeat_closes_run()
	_check(_real_save_stamp() == real_before, "настоящее сохранение legion.cfg не тронуто")
	_check(Campaign._path == SAVE, "раннер писал в своё сохранение %s" % SAVE)
	print("LEGION RUN CHAIN: %d/%d OK" % [_checks - _fails, _checks])
	if FileAccess.file_exists(SAVE):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE))
	quit(1 if _fails > 0 else 0)


func _new_chain(extra: Dictionary) -> RefCounted:
	var opts := {"run_seed": str(RUN_SEED), "bot_seed": "91", "bot": "selective",
		"difficulty": "hell", "save": SAVE}
	opts.merge(extra, true)
	var c: RefCounted = Chain.new()
	c.setup(self, opts)
	c.quiet = true
	return c


## Хук двух побед: на объекте 1 выдаёт артефакт и кончает бой победой; на объекте 2 запоминает,
## что мир загрузил из забега, и тоже побеждает.
func _hook_wins(c: RefCounted, k: int) -> void:
	var w: LegionWorld = c.main.world
	if k == 1:
		w.items.grant(_item)
	else:
		_k2_owned = w.items.owned()
		_k2_bot = String(w.bot.policy) if w.bot != null else ""
		_k2_seed = w._base_seed
	w.force_end(true)
	await process_frame


func _test_two_victories() -> void:
	var c: RefCounted = _new_chain({"run_objects": "2"})
	c.battle_hook = _hook_wins
	var info: Dictionary = await c.run()
	_check(c.error == "", "поток прошёл без сбоя (%s)" % c.error)
	_check(String(info.get("reason", "")) == "objects" and int(info.get("objects_won", 0)) == 2,
		"забег дошёл до N=2: %s" % info)
	var rows: Array = c.rows
	_check(rows.size() == 2, "две строки RUN_OBJECT")
	if rows.size() < 2:
		c.cleanup()
		return
	var r1: Dictionary = rows[0]
	var r2: Dictionary = rows[1]
	_check(r1["map"] == "gen:%d:1" % RUN_SEED and r2["map"] == "gen:%d:2" % RUN_SEED,
		"объекты — gen:<сид>:1 и gen:<сид>:2 (%s, %s)" % [r1["map"], r2["map"]])
	_check(int(r2["run_seed"]) == RUN_SEED, "сид забега на объекте 2 тот же")
	_check(int(r1["tenure"]) == 1 and int(r2["tenure"]) == 2, "стаж 1 → 2")
	var offered: Array = r1["offered"]
	_check(offered.size() >= 1 and offered.has(r1["upgrade"]),
		"поправка объекта 1 взята из предложенных (%s из %s)" % [r1["upgrade"], offered])
	_check((r2["upgrades"] as Array).has(r1["upgrade"]) and (r2["upgrades"] as Array).size() == 2,
		"поправки копятся: %s" % [r2["upgrades"]])
	# воспроизводимость выбора: тот же rng от (забег, бот, k)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([RUN_SEED, 91, 1])
	_check(r1["upgrade"] == offered[rng.randi_range(0, offered.size() - 1)],
		"случайная поправка — от (сид забега, сид бота, k)")
	# премия: победа 3★ = 30 + 15×3 = 75; жадно: 40 (дальность подрядчика) → 35, дальше не на что
	_check(int(r1["bounty_before"]) == LegionMetaCfg.bounty_for_result(true, 3, 0),
		"премия за объект начислена (%d)" % int(r1["bounty_before"]))
	_check(r1["bought"] == ["range:laborer"] and int(r1["bounty_after"]) == 35,
		"жадная «Контора»: самая дешёвая по порядку (%s, осталось %d)"
			% [r1["bought"], r1["bounty_after"]])
	_check(int(r2["bounty_before"]) == 35 + 75,
		"премия переносится между объектами (%d)" % int(r2["bounty_before"]))
	_check(_no_affordable(int(r2["bounty_after"])),
		"после покупок не осталось доступной покупки по карману (премия %d)" % int(r2["bounty_after"]))
	_check((r2["shop"] as Dictionary).get("range:laborer", 0) >= 1,
		"покупка объекта 1 на месте у объекта 2")
	_check((r1["items"] as Array).has(String(_item)), "артефакт боя 1 записан в забег")
	_check(_k2_owned.has(_item), "артефакт боя 1 перенесён в бой объекта 2 (%s)" % [_k2_owned])
	_check(_k2_bot == "selective", "бот мира — из опций раннера (%s)" % _k2_bot)
	_check(_k2_seed == 91 and int(r2["seed"]) == 91, "сид боя — сид бота (%d)" % _k2_seed)
	_check(r1["difficulty"] == "hell" and r2["difficulty"] == "hell"
		and LegionRunStore.run_difficulty(false) == "hell", "сложность закреплена на забег")
	_check(Campaign.stars(String(Campaign.maps()[-1].get("id", ""))) == 3,
		"профиль «ветеран»: последняя карта кампании на 3★")
	_check(c.main.screen is EndlessBriefing and LegionRunStore.endless_k(false) == 3,
		"после «Конторы» — брифинг объекта 3")
	c.cleanup()
	await process_frame


func _no_affordable(bounty: int) -> bool:
	for cnd: Dictionary in Chain.shop_candidates():
		if int(cnd["cost"]) <= bounty:
			return false
	return true


func _hook_win_then_lose(c: RefCounted, k: int) -> void:
	c.main.world.force_end(k == 1)
	await process_frame


func _test_defeat_closes_run() -> void:
	var c: RefCounted = _new_chain({"run_objects": "5", "run_shop": "off", "run_upgrade": "first"})
	c.battle_hook = _hook_win_then_lose
	var info: Dictionary = await c.run()
	_check(c.error == "", "поток с поражением прошёл без сбоя (%s)" % c.error)
	_check(String(info.get("reason", "")) == "defeat" and int(info.get("objects_won", 0)) == 1
		and c.rows.size() == 2, "поражение на объекте 2 кончает забег: %s" % info)
	if c.rows.size() == 2:
		var r1: Dictionary = c.rows[0]
		var r2: Dictionary = c.rows[1]
		_check(r1["upgrade"] == (r1["offered"] as Array)[0], "run_upgrade=first — первая предложенная")
		_check((r1["bought"] as Array).is_empty() and int(r1["bounty_after"]) == int(r1["bounty_before"]),
			"run_shop=off — «Контора» без покупок")
		_check(r2["result"] == "defeat" and not bool(r2["run_active"]), "поражение закрыло забег (k=0)")
		_check(int(r2["tenure"]) == 1, "стаж в некрологе — сданные объекты (1)")
	_check(c.main.screen is Necrolog, "после поражения — некролог")
	# свежий профиль: второй прогон начал с нуля, а не продолжил забег первого
	_check(c.rows.size() > 0 and int(c.rows[0]["tenure"]) == 1, "каждый прогон — с чистого профиля")
	c.cleanup()
	await process_frame
