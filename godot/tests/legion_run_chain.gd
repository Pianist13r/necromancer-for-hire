extends RefCounted
##
## B-358: забег «Бесконечного подряда» цепочкой — объекты 1..N ОДНОГО забега подряд через
## настоящий поток LegionMain (брифинг → бой → итог → поправка → «Контора» → брифинг k+1), с
## переносом всего, что переносит игра: поправок, артефактов, покупок «Конторы», стажа, душ.
## Ядро общее для раннера (legion_run_chain_runner.gd, бой ведёт бот) и регресс-теста
## (legion_run_chain_test.gd, бой кончает хук через world.force_end — без полного боя).
## Игру не меняет: экраны ведутся их же сигналами, как реальные клики (legion_endless_flow_test).
##
## Политики (D-0930-62, координатор): профиль «ветеран» (все карты кампании открыты и пройдены на
## 3★, обучение и вступление пройдены, герой без рангов); поправка — случайная из предложенных,
## rng от (сид забега, сид бота, k), или первая (upgrade_policy = "first"); «Контора» — жадно:
## пока хватает премии, самая дешёвая доступная покупка (равная цена — порядок OFFICE_SHOP_ORDER,
## внутри вида — KIND_ORDER); сложность закрепляется на забег до первого боя (lock_difficulty).
##

## Страховка от зависшего боя: кадров на один объект (--fixed-fps 60 → 1800 игровых секунд, как
## BALANCE TIMEOUT в legion_balance_runner.gd). Бой объекта в замере 30.09 — 190–260 с.
const DEFAULT_BATTLE_CAP_S := 1800.0
const FPS := 60

var tree: SceneTree
var main: LegionMain
var run_seed := 1
var bot_seed := 1
var objects := 10
var bot := "selective"
var difficulty := "normal"
var upgrade_policy := "random"   # random | first
var shop_on := true
var battle_cap_s := DEFAULT_BATTLE_CAP_S
var save_path := ""
## Тест: Callable(chain, k) — зовётся сразу после старта боя объекта k (бой ещё идёт); может
## кончить бой сам (world.force_end). Пустой — бой ведёт бот до исхода.
var battle_hook := Callable()
## Строки RUN_OBJECT и итог RUN_END — для теста и для печати.
var rows: Array[Dictionary] = []
var end_info: Dictionary = {}
## "" — всё шло по потоку; иначе — текст сбоя раннера (экран не тот, что ждали, и т.п.).
var error := ""
var quiet := false

var _last_final: Dictionary = {}
var _got_end := false


## opts — ключи --dev раннера: run_seed, bot_seed, run_objects, bot, difficulty, run_upgrade,
## run_shop, battle_cap_s, save (save — только из теста словарём; раннер отвергает --dev save:
## его видит и LegionMain._ready и сбрасывает профиль после prepare_profile).
func setup(t: SceneTree, opts: Dictionary) -> void:
	tree = t
	run_seed = int(String(opts.get("run_seed", "1")))
	bot_seed = int(String(opts.get("bot_seed", "1")))
	objects = maxi(1, int(String(opts.get("run_objects", "10"))))
	bot = String(opts.get("bot", "selective"))
	difficulty = LegionChallenge.valid(String(opts.get("difficulty", "normal")))
	upgrade_policy = "first" if String(opts.get("run_upgrade", "random")) == "first" else "random"
	shop_on = String(opts.get("run_shop", "on")) != "off"
	battle_cap_s = float(String(opts.get("battle_cap_s", str(DEFAULT_BATTLE_CAP_S))))
	save_path = String(opts.get("save",
		"user://legion_run_chain_%d_%d.cfg" % [run_seed, bot_seed]))


## Свежий профиль «ветеран» в своём файле (никогда не настоящий legion.cfg).
func prepare_profile() -> bool:
	if not Campaign.is_safe_dev_save(save_path):
		error = "сохранение %s — не своё user://имя.cfg" % save_path
		return false
	Campaign.set_save_path(save_path)
	Campaign.use_campaign_scope()
	Campaign.reset()
	Campaign.set_intro_cutscene_seen()
	Campaign.set_tutorial_done()
	Campaign.unlock_all()
	for m in Campaign.maps():
		Campaign.record_result(String(m.get("id", "")), true, 1.0)
	return true


func _frames(n: int) -> void:
	for i in n:
		await tree.process_frame


func _fail(what: String) -> void:
	if error == "":
		error = what


## Весь забег. Возвращает end_info (то же, что строка RUN_END).
func run() -> Dictionary:
	rows.clear()
	end_info = {}
	if not prepare_profile():
		return _finish("error", 0)
	var scene: PackedScene = load("res://scenes/legion.tscn")
	main = scene.instantiate() as LegionMain
	tree.root.add_child(main)
	await _frames(2)
	# забег с заданным сидом и закреплённой сложностью — ДО _start_endless_flow: тот продолжает
	# активный забег, а не заводит свой случайный (endless_active), и lock_difficulty в
	# _start_endless_battle уже no-op
	Campaign.use_endless_scope()
	LegionRunStore.endless_start(run_seed)
	LegionRunStore.lock_difficulty(false, difficulty)
	main._start_endless_flow(false)
	await _frames(2)
	var won := 0
	for k in range(1, objects + 1):
		var reason := await _play_object(k)
		if error != "":
			return _finish("error", won)
		if reason != "victory":
			return _finish(reason, won)
		won += 1
	return _finish("objects", won)


func _finish(reason: String, won: int) -> Dictionary:
	end_info = {
		"run_seed": run_seed, "bot_seed": bot_seed, "bot": bot, "difficulty": difficulty,
		"objects_target": objects, "objects_won": won, "objects_played": rows.size(),
		"reason": reason, "upgrade_policy": upgrade_policy, "shop": shop_on,
	}
	if error != "":
		end_info["error"] = error
	if not quiet:
		print("RUN_END ", JSON.stringify(end_info))
	return end_info


func _on_match_ended(_victory: bool, final: Dictionary) -> void:
	_last_final = final
	_got_end = true


## Один объект: брифинг → бой → итог; победа — поправка и «Контора». Возвращает "victory",
## "defeat", "timeout" или "" (сбой потока — текст в error).
func _play_object(k: int) -> String:
	var map_id := await _start_battle(k)
	if map_id == "":
		return ""
	var w := main.world
	if battle_hook.is_valid():
		await battle_hook.call(self, k)
	var cap := int(battle_cap_s * FPS)
	var n := 0
	while not _got_end and n < cap:
		await tree.process_frame
		n += 1
	var row := {"k": k, "map": map_id, "run_seed": LegionRunStore.endless_seed(false)}
	if not _got_end:
		row.merge({"result": "timeout", "t": snappedf(w.now, 0.1),
			"hp": snappedf(w.cauldron_hp, 0.1), "cauldron_max": w.cauldron_max,
			"wave": w.wave_runner.wave_no() if w.wave_runner else 0})
		_emit_row(row)
		return "timeout"
	await _frames(2)
	var f := _last_final
	row.merge({
		"result": String(f.get("result", "")), "hp": f.get("hp", 0.0),
		"cauldron_max": snappedf(w.cauldron_max, 0.1), "lost": int(f.get("lost", 0)),
		"kills": int(f.get("kills", 0)), "t": f.get("t", 0.0), "wave": int(f.get("wave", 0)),
		"difficulty": String(f.get("difficulty", "")), "bot": String(f.get("bot", "")),
		"seed": int(f.get("seed", 0)),
	})
	if String(f.get("result", "")) != "victory":
		_defeat_row(k, row)
		return "defeat"
	var ok: bool = await _after_victory(k, row)
	return "victory" if ok else ""


## Брифинг объекта k → старт боя ботом. Возвращает id карты, "" — сбой потока.
func _start_battle(k: int) -> String:
	if not (main.screen is EndlessBriefing):
		_fail("объект %d: ждали брифинг забега, экран %s" % [k, main.screen])
		return ""
	var store_k := LegionRunStore.endless_k(false)
	var store_seed := LegionRunStore.endless_seed(false)
	if store_k != k or store_seed != run_seed:
		_fail("объект %d: в сохранении k=%d сид=%d" % [k, store_k, store_seed])
		return ""
	var map_id := LegionEndless.object_map_id(store_seed, store_k, false)
	# мир — тот же узел на весь забег; бот и сид боя — через его args (командная строка раннера
	# не несёт --bot/--seed: иначе LegionMain ушёл бы в compat-путь одного боя)
	var w := main._ensure_world()
	w.args["bot"] = bot
	w._base_seed = bot_seed
	if not w.match_ended.is_connected(_on_match_ended):
		w.match_ended.connect(_on_match_ended)
	_got_end = false
	_last_final = {}
	(main.screen as EndlessBriefing).start.emit(map_id)
	await _frames(1)
	if w.map_id != map_id or not main._in_endless_battle and not _got_end:
		_fail("объект %d: бой %s не стартовал как объект забега" % [k, map_id])
		return ""
	return map_id


## Поражение: забег закрыт игрой (endless_end_run, некролог), стаж/души — сданные объекты.
func _defeat_row(k: int, row: Dictionary) -> void:
	row.merge({"upgrade": "", "upgrades": _ids(_endless_upgrades()),
		"items": _ids(_endless_items()), "bounty_before": _endless_bounty(),
		"bounty_after": _endless_bounty(), "bought": [],
		"tenure": LegionRunStore.endless_tenure(false),
		"souls": LegionRunStore.endless_souls(false),
		"run_active": LegionRunStore.endless_active(false)})
	if not (main.screen is Necrolog):
		_fail("объект %d: поражение, но экран не некролог (%s)" % [k, main.screen])
	_emit_row(row)


## Победа: итог → «Дальше» → поправка → «Контора» (жадно) → «Дальше» к брифингу k+1.
func _after_victory(k: int, row: Dictionary) -> bool:
	if not (main.screen is LegionResult):
		_fail("объект %d: победа, но экран не итог (%s)" % [k, main.screen])
		return false
	row["items"] = _ids(Campaign.run_items())
	# «Дальше» → предложение поправок из world.rng. Состояние rng снимаем в том же кадре и
	# повторяем тот же вызов на копии — узнаём ровно предложенные карточки (UpgradePicker их не
	# хранит), не трогая игру; ниже сверяем с заголовками карточек на экране.
	var probe := RandomNumberGenerator.new()
	probe.seed = main.world.rng.seed
	probe.state = main.world.rng.state
	var offered := Campaign.offer_upgrades(probe)
	(main.screen as LegionResult).next.emit()
	await _frames(2)
	var picked := ""
	if main.screen is UpgradePicker:
		if not _offer_matches_screen(k, offered):
			return false
		picked = String(_choose_upgrade(offered, k))
		(main.screen as UpgradePicker).picked.emit(StringName(picked))
		await _frames(2)
	row["offered"] = _ids(offered)
	row["upgrade"] = picked
	if not (main.screen is OfficeShop):
		_fail("объект %d: после поправки ждали «Контору», экран %s" % [k, main.screen])
		return false
	row["bounty_before"] = Campaign.bounty()
	var bought: Array[String] = []
	if shop_on:
		bought = greedy_shop()
		(main.screen as OfficeShop).refresh()
	row["bought"] = bought
	row["bounty_after"] = Campaign.bounty()
	row["upgrades"] = _ids(Campaign.upgrades())
	row["shop"] = shop_levels()
	row["tenure"] = LegionRunStore.endless_tenure(false)
	row["souls"] = LegionRunStore.endless_souls(false)
	(main.screen as OfficeShop).back.emit()
	await _frames(2)
	_emit_row(row)
	return true


## Карточки экрана показывают ровно предсказанные поправки (по заголовкам).
func _offer_matches_screen(k: int, offered: Array[StringName]) -> bool:
	if offered.is_empty():
		_fail("объект %d: экран поправок при пустом предложении" % k)
		return false
	var shown := _label_texts(main.screen)
	for id in offered:
		var data: Dictionary = LegionMetaCfg.UPGRADE_POOL.get(String(id), {})
		var title := String(data.get("title", String(id)))
		if not shown.has(title):
			_fail("объект %d: предсказанной поправки «%s» нет на экране" % [k, title])
			return false
	return true


func _choose_upgrade(offered: Array[StringName], k: int) -> StringName:
	if upgrade_policy == "first":
		return offered[0]
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([run_seed, bot_seed, k])
	return offered[rng.randi_range(0, offered.size() - 1)]


## Покупки «Конторы» по правилам доступности экрана (ui/office_shop.gd _apply_state): вид бойца
## открыт, уровни подряд (покупается только следующий), хватает премии. Жадно — самая дешёвая,
## при равной цене — раньше по OFFICE_SHOP_ORDER, внутри вида — по KIND_ORDER. «id» или «id:вид».
static func shop_candidates() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for id: String in LegionMetaCfg.OFFICE_SHOP_ORDER:
		var kinds: Array[String] = [""]
		if bool(LegionMetaCfg.OFFICE_SHOP[id].get("per_kind", false)):
			kinds.clear()
			for kind: StringName in LegionCfg.KIND_ORDER:
				kinds.append(String(kind))
		for kind in kinds:
			if kind != "" and Campaign.stat(StringName("kind_unlocked_%s" % kind)) < 0.5:
				continue
			var cost := Campaign.shop_cost(id, kind)
			if cost < 0:
				continue
			out.append({"id": id, "kind": kind, "cost": cost})
	return out


static func greedy_shop() -> Array[String]:
	var bought: Array[String] = []
	while true:
		var best: Dictionary = {}
		for c in shop_candidates():
			var cost := int(c["cost"])
			if cost <= Campaign.bounty() and (best.is_empty() or cost < int(best["cost"])):
				best = c
		if best.is_empty():
			break
		if not Campaign.shop_buy(String(best["id"]), String(best["kind"])):
			break
		bought.append(String(best["id"]) if String(best["kind"]) == "" \
			else "%s:%s" % [best["id"], best["kind"]])
	return bought


## Уровни купленного: {"range:laborer": 1, "mana": 2, …} — только ненулевые.
static func shop_levels() -> Dictionary:
	var out := {}
	for id: String in LegionMetaCfg.OFFICE_SHOP_ORDER:
		if bool(LegionMetaCfg.OFFICE_SHOP[id].get("per_kind", false)):
			for kind: StringName in LegionCfg.KIND_ORDER:
				var lvl := Campaign.shop_level(id, String(kind))
				if lvl > 0:
					out["%s:%s" % [id, kind]] = lvl
		elif Campaign.shop_level(id) > 0:
			out[id] = Campaign.shop_level(id)
	return out


## После поражения игра уже вернула кампанийный scope — секция забега читается напрямую.
func _endless_upgrades() -> Array:
	return Campaign.raw_file().get_value(Campaign.ENDLESS_SECTION, "upgrades", [])


func _endless_items() -> Array:
	return Campaign.raw_file().get_value(Campaign.ENDLESS_SECTION, CfgItems.SAVE_KEY, [])


func _endless_bounty() -> int:
	return int(Campaign.raw_file().get_value(Campaign.ENDLESS_SECTION, "bounty", 0))


static func _label_texts(node: Node) -> Array[String]:
	var out: Array[String] = []
	for ch in node.find_children("*", "Label", true, false):
		out.append((ch as Label).text)
	return out


static func _ids(arr: Array) -> Array[String]:
	var out: Array[String] = []
	for v: Variant in arr:
		out.append(String(v))
	return out


func _emit_row(row: Dictionary) -> void:
	rows.append(row)
	if not quiet:
		print("RUN_OBJECT ", JSON.stringify(row))


func cleanup() -> void:
	if main != null and is_instance_valid(main):
		main.queue_free()
	Campaign.use_campaign_scope()
