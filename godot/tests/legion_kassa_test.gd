extends SceneTree
##
## «Касса» — сток душ одиночного боя (B-022/B-085/B-280/B-353; решение инстанса, D-1001-01):
## души по ходу боя закладываются порцией в «кассу», заложенное в бою недоступно, курс падает к
## концу боя, потолок премии за бой, при поражении касса сгорает; премия — туда же, куда премия
## за бой (кампания и забег «Бесконечного подряда»); в «Схватке» и в переигровке из коллекции
## кассы нет; бот без --dev bot_kassa=1 кассой не пользуется.
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_kassa_test.gd -- --mute
##
## Новый API берётся через get()/call(): на старом коде тест не падает разбором, а честно
## проваливает проверки. Итог «LEGION KASSA: N/M OK»; код выхода 1, если что-то упало.
##

const SAVE := "user://legion_kassa_test.cfg"
const CHAIN_SAVE := "user://legion_kassa_test_run.cfg"
const KASSA_PATH := "res://scripts/legion/kassa.gd"
const Chain := preload("res://tests/legion_run_chain.gd")
const RUN_SEED := 3341246352
const DT := 1.0 / 60.0

var w: LegionWorld
var _fails := 0
var _checks := 0
var _hook_text := ""
var _hook_kassa := -1


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


## Число из LegionCfg по имени: на старом коде константы нет — fallback, а не ошибка разбора.
func _cfg(name: String, fallback: Variant) -> Variant:
	var consts := (LegionCfg as Script).get_script_constant_map()
	return consts.get(name, fallback)


func _real_save_stamp() -> String:
	if not FileAccess.file_exists(Campaign.PATH):
		return "нет файла"
	return FileAccess.get_md5(Campaign.PATH)


func _run() -> void:
	var real_before := _real_save_stamp()
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	w = scene.instantiate() as LegionWorld
	root.add_child(w)
	await process_frame
	w.set_process(false)
	_test_rates()
	_test_deposit()
	_test_cap()
	_test_final_stats()
	await _test_key_and_button()
	_test_pvp()
	_test_bot()
	_test_tutorial_hold()
	w.queue_free()
	await _frames(2)
	await _test_campaign()
	await _test_endless()
	_check(_real_save_stamp() == real_before, "настоящее сохранение legion.cfg не тронуто")
	for p in [SAVE, CHAIN_SAVE]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
	print("LEGION KASSA: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


## Пока обучение держит волны, кассы нет и для клавиши Дэ: кнопка пряталась, а Дэ закладывала
## 50 из 60 стартовых душ новичка (проверка 01.10).
func _test_tutorial_hold() -> void:
	print("— касса под удержанием обучения")
	_fresh("wasteland")
	w.start_tutorial()
	var steps := 0
	while steps < 600 and not (w.tutorial != null and w.tutorial.holding()):
		w._process(1.0 / 60.0)
		steps += 1
	_check(w.tutorial != null and w.tutorial.holding(), "обучение держит волны (шагов %d)" % steps)
	w.staff.add_souls(500)
	var before := w.souls
	var res: Dictionary = w.request_kassa()
	_check(not bool(res.get("ok", true)) and w.souls == before,
		"Дэ под удержанием обучения не закладывает (%s, души %d → %d)" % [res, before, w.souls])
	w.tutorial = null


func _kassa() -> Object:
	return w.get("kassa") as Object


func _fresh(map_id: String) -> void:
	w.dev.erase("no_waves")
	w.dev["spawn_units"] = "0"
	w.dev["difficulty"] = "normal"
	w.args.erase("bot")
	w.start_map(map_id)
	w.dev_invuln = false


## Курс по трети волн: 10 → 20 → 40 душ за единицу премии (числа — LegionCfg.KASSA_RATES).
func _test_rates() -> void:
	print("— курс кассы по трети волн")
	var script: Script = load(KASSA_PATH) if ResourceLoader.exists(KASSA_PATH) else null
	_check(script != null, "есть scripts/legion/kassa.gd")
	var rates: Array = _cfg("KASSA_RATES", [])
	_check(rates == [10, 20, 40], "курсы в LegionCfg.KASSA_RATES: %s" % [rates])
	if script == null:
		return
	var got: Array = []
	for wn in [0, 1, 2, 3, 4, 5]:
		got.append(script.call("rate_for", wn, 5))
	_check(got == [10, 10, 10, 20, 20, 40], "5 волн: до первой и 1–2 — 10, 3–4 — 20, 5 — 40 (%s)"
		% [got])
	var six: Array = []
	for wn in [1, 2, 3, 4, 5, 6]:
		six.append(script.call("rate_for", wn, 6))
	_check(six == [10, 10, 20, 20, 40, 40], "6 волн: по две на треть (%s)" % [six])
	_check(int(script.call("rate_for", 0, 0)) == 10, "карта без волн — первый курс")


## Порция уходит из душ, премия копится по курсу; душ меньше порции — отказ без списания.
func _test_deposit() -> void:
	print("— закладка порции")
	_fresh("bridge")
	var k := _kassa()
	_check(k != null, "у мира есть касса (world.kassa)")
	if k == null or not w.has_method("request_kassa"):
		_check(false, "у мира есть request_kassa()")
		return
	var portion := int(_cfg("KASSA_PORTION", 0))
	_check(portion == 50, "порция LegionCfg.KASSA_PORTION = 50 (%d)" % portion)
	w.souls = 200
	var res: Dictionary = w.call("request_kassa")
	_check(bool(res.get("ok", false)), "до первой волны закладка проходит (%s)" % res)
	_check(w.souls == 150, "из душ ушла порция: осталось %d" % w.souls)
	_check(int(k.get("souls")) == 50, "в кассе 50 душ (%d)" % int(k.get("souls")))
	_check(int(k.call("earned")) == 5, "по курсу 10:1 — +5 премии (%d)" % int(k.call("earned")))
	w.souls = 30
	res = w.call("request_kassa")
	_check(not bool(res.get("ok", true)) and String(res.get("reason", "")) == "souls",
		"душ меньше порции — отказ «souls» (%s)" % res)
	_check(w.souls == 30 and int(k.get("souls")) == 50, "при отказе ничего не списано")
	# последняя треть волн: курс 40:1 — 50 душ дают 1,25 → в итог идёт целая часть
	w.wave_runner.index = w.wave_runner.total() - 1
	w.souls = 100
	res = w.call("request_kassa")
	_check(bool(res.get("ok", false)) and int(res.get("rate", 0)) == 40,
		"в последней трети курс 40:1 (%s)" % res)
	_check(int(k.call("earned")) == 6, "5 + 1,25 → в итог +6 (%d)" % int(k.call("earned")))


## Потолок: премии за бой не больше KASSA_CAP, последняя порция — ровно до потолка.
func _test_cap() -> void:
	print("— потолок кассы")
	_fresh("bridge")
	var k := _kassa()
	if k == null or not w.has_method("request_kassa"):
		_check(false, "касса есть")
		return
	var cap := int(_cfg("KASSA_CAP", 0))
	_check(cap == 25, "потолок LegionCfg.KASSA_CAP = 25 (%d)" % cap)
	w.wave_runner.index = 2   # 3-я волна из 5 у Моста: курс 20:1
	var rate := int(k.call("rate", w))
	w.souls = 10000
	var n := 0
	while bool((w.call("request_kassa") as Dictionary).get("ok", false)) and n < 100:
		n += 1
	_check(int(k.call("earned")) == cap, "премия упёрлась в потолок %d (%d)" % [cap,
		int(k.call("earned"))])
	_check(int(k.get("souls")) == cap * rate, "заложено ровно %d душ, не больше (%d)" % [
		cap * rate, int(k.get("souls"))])
	_check(w.souls == 10000 - cap * rate, "лишнее в душах осталось (%d)" % w.souls)
	var res: Dictionary = w.call("request_kassa")
	_check(String(res.get("reason", "")) == "full", "после потолка — отказ «full» (%s)" % res)


## В итог боя «kassa» попадает только если касса была в деле (иначе ключи итога — прежние:
## эталоны трасс бота хэшируют итог).
func _test_final_stats() -> void:
	print("— итог боя")
	_fresh("bridge")
	_check(not w.final_stats(true).has("kassa"), "касса не тронута — в итоге ключа «kassa» нет")
	if not w.has_method("request_kassa"):
		_check(false, "касса есть")
		return
	w.souls = 100
	w.call("request_kassa")
	var fin := w.final_stats(true)
	_check(int(fin.get("kassa", -1)) == 5 and int(fin.get("kassa_souls", -1)) == 50,
		"после закладки в итоге kassa=5, kassa_souls=50 (%s/%s)" % [fin.get("kassa"),
			fin.get("kassa_souls")])
	_check(int(w.final_stats(false).get("kassa", -1)) == 0,
		"поражение: касса сгорает (kassa=0)")
	_fresh("bridge")
	_check(_kassa() != null and int(_kassa().get("souls")) == 0, "новый бой — касса пуста")


## Клавиша Дэ в одиночке закладывает порцию; кнопка в HUD видна в бою и закладывает щелчком.
func _test_key_and_button() -> void:
	print("— клавиша Дэ и кнопка HUD")
	_fresh("bridge")
	var k := _kassa()
	if k == null:
		_check(false, "касса есть")
		return
	w.souls = 200
	var ev := InputEventKey.new()
	ev.physical_keycode = KEY_D
	ev.pressed = true
	w._unhandled_input(ev)
	_check(int(k.get("souls")) == 50 and w.souls == 150, "Дэ — одна порция в кассу (%d, души %d)"
		% [int(k.get("souls")), w.souls])
	await _frames(2)
	var btn := w.hud.get("kassa_button") as Control
	_check(btn != null, "в HUD есть кнопка кассы (LegionHud.kassa_button)")
	if btn == null:
		return
	_check(btn.visible, "кнопка видна в одиночном бою")
	_check(btn.mouse_filter == Control.MOUSE_FILTER_STOP and btn.size.x <= 140.0,
		"кнопка ловит мышь только своим прямоугольником (%s)" % [btn.size])
	var r := btn.get_global_rect()
	var plate_end := 8.0 + 804.0
	_check(r.position.x >= plate_end and r.end.x <= LegionCfg.WAVE_PREVIEW_POS.x,
		"между плашкой статов и превью волны (%s)" % [r])
	_check(w.hud.panel_rects().has(r), "телеграф угрозы знает прямоугольник кнопки")
	var mb := InputEventMouseButton.new()
	mb.button_index = MOUSE_BUTTON_LEFT
	mb.pressed = true
	btn._gui_input(mb)
	_check(int(k.get("souls")) == 100, "щелчок по кнопке — ещё порция (%d)" % int(k.get("souls")))
	_check(String(btn.call("summary")).contains("+10"), "подпись кнопки: %s" % btn.call("summary"))


## «Схватка»: кассы нет (кнопка спрятана, Дэ там ничего не делает, request_kassa отказывает).
func _test_pvp() -> void:
	print("— «Схватка» без кассы")
	w.dev.erase("difficulty")
	w.start_map("pvp:duel")
	_check(w.pvp, "матч «Схватки» начат")
	if not w.has_method("request_kassa"):
		_check(false, "касса есть")
		return
	w.souls = 500
	var res: Dictionary = w.call("request_kassa")
	_check(not bool(res.get("ok", true)) and String(res.get("reason", "")) == "off",
		"в «Схватке» касса отказывает (%s)" % res)
	_check(w.souls == 500, "души не тронуты")
	var btn := w.hud.get("kassa_button") as Control
	if btn != null:
		btn.call("_process", 0.0)
	_check(btn != null and not btn.visible, "кнопки кассы в «Схватке» нет")
	_check(not w.final_stats(true).has("kassa"), "в итоге «Схватки» ключа kassa нет")


## Бот: без флага кассу не трогает; с --dev bot_kassa=1 закладывает излишек, когда строить нечего.
func _test_bot() -> void:
	print("— бот и касса")
	for flag in [false, true]:
		if flag:
			w.dev["bot_kassa"] = "1"
		else:
			w.dev.erase("bot_kassa")
		w.dev["no_waves"] = "1"
		w.dev["difficulty"] = "normal"
		w.args["bot"] = "selective"
		w.start_map("bridge")
		w.souls = 5000
		for i in roundi(40.0 / DT):
			w._step(DT)
		var k := _kassa()
		var got := int(k.get("souls")) if k != null else -1
		if flag:
			_check(got > 0, "с bot_kassa=1 бот закладывает излишек (%d душ)" % got)
			var built := 0
			for p: Dictionary in w.staff.plots:
				if p["building"] != null:
					built += 1
			_check(built == w.staff.plots.size(), "сначала всё построено (%d/%d)" % [built,
				w.staff.plots.size()])
		else:
			_check(got == 0, "без флага бот кассой не пользуется (%d)" % got)
	w.args.erase("bot")
	w.dev.erase("bot_kassa")
	w.dev.erase("no_waves")


## Кампания через LegionMain: победа — премия боя + касса и строка «Касса: +N премии» на итоге;
## поражение — касса сгорает; переигровка из коллекции — кассы нет.
func _test_campaign() -> void:
	print("— кампания: касса в премию")
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	Campaign.set_intro_cutscene_seen()
	Campaign.set_tutorial_done()
	# Проверяем кассу после обучения, а не её запрет под hold урока треугольника.
	Campaign.mark_hint_seen(LegionTutorial.flag("bridge", &"triangle"))
	Campaign.unlock_all()
	var scene: PackedScene = load("res://scenes/legion.tscn")
	var main := scene.instantiate() as LegionMain
	root.add_child(main)
	await _frames(2)
	var map_id := "bridge"
	for victory in [true, false]:
		main.start_battle(map_id)
		await _frames(2)
		w = main.world
		_check(w != null and w.phase == LegionWorld.Phase.BATTLE and w.map_id == map_id,
			"бой кампании на %s" % map_id)
		if not w.has_method("request_kassa"):
			_check(false, "касса есть")
			break
		w.souls = 100
		w.call("request_kassa")
		var before := Campaign.bounty()
		w.force_end(victory)
		await _frames(3)
		var gained := Campaign.bounty() - before
		var text := _screen_text(main.screen)
		if victory:
			var base := LegionMetaCfg.bounty_for_result(true, 3, 0)
			_check(gained == base + 5, "победа: премия %d = %d за бой + 5 из кассы" % [gained, base])
			_check(text.contains("Касса: +5 премии"), "на итоге строка «Касса: +5 премии»")
		else:
			var base := LegionMetaCfg.bounty_for_result(false, 0, 0)
			_check(gained == base, "поражение: касса сгорела, премия только %d (%d)" % [base, gained])
			_check(text.contains("Касса сгорела"), "на итоге поражения — «Касса сгорела»")
	# переигровка из коллекции: премии там нет — и кассы нет
	LegionCollectionFlow.start_battle(main, "gen:%d:1" % RUN_SEED)
	await _frames(2)
	_check(main._in_collection_battle, "бой переигровки из коллекции начат")
	if main._in_collection_battle and main.world.has_method("request_kassa"):
		main.world.souls = 300
		var res: Dictionary = main.world.call("request_kassa")
		_check(String(res.get("reason", "")) == "off", "переигровка из коллекции — кассы нет (%s)"
			% res)
		main.world.force_end(true)
		await _frames(2)
	main.start_battle(map_id)
	await _frames(2)
	_check(main.world.get("kassa_allowed") == true, "следующий бой кампании — касса снова есть")
	main.queue_free()
	await _frames(2)


func _screen_text(n: Node) -> String:
	if n == null:
		return ""
	var out := ""
	if n is Label:
		out += (n as Label).text + "\n"
	for c in n.get_children():
		out += _screen_text(c)
	return out


## Забег: премия объекта + касса — в раздел забега, «Контора» видит её; итог объекта со строкой.
func _hook_endless(c: RefCounted, _k: int) -> void:
	var ww: LegionWorld = c.main.world
	if ww.has_method("request_kassa"):
		ww.souls = 1000
		for i in 10:
			ww.call("request_kassa")
		_hook_kassa = int(ww.final_stats(true).get("kassa", -1))
	ww.force_end(true)
	await _frames(3)
	_hook_text = _screen_text(c.main.screen)


func _test_endless() -> void:
	print("— забег: касса в премию объекта")
	var c: RefCounted = Chain.new()
	c.setup(self, {"run_seed": str(RUN_SEED), "bot_seed": "91", "bot": "selective",
		"difficulty": "normal", "save": CHAIN_SAVE, "run_objects": "1", "run_shop": "off"})
	c.quiet = true
	c.battle_hook = _hook_endless
	await c.run()
	_check(c.error == "", "поток забега без сбоя (%s)" % c.error)
	_check(_hook_kassa == 25, "в объекте забега касса до потолка: +25 (%d)" % _hook_kassa)
	var rows: Array = c.rows
	if rows.size() == 1:
		var base := LegionMetaCfg.bounty_for_result(true, 3, 0)
		_check(int(rows[0]["bounty_before"]) == base + 25,
			"премия объекта %d + касса 25 = %d в «Конторе» забега" % [base,
				int(rows[0]["bounty_before"])])
	else:
		_check(false, "одна строка объекта")
	_check(_hook_text.contains("Касса: +25 премии"), "на итоге объекта строка «Касса: +25 премии»")
	c.cleanup()
	await process_frame
