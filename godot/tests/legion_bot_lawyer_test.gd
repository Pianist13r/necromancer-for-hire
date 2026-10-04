extends SceneTree
##
## Регресс B-008: бот отвечает на Юриста тем, что есть у человека, — Ку в него и «Сбор» свободных
## к точке зачитки, когда участок-цель пуст (так бывает почти всегда: стоящие на участке бьют
## Юриста сами). Раньше бот о Юристе не знал ничего, и пустой участок рвался без ответа.
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_bot_lawyer_test.gd -- --mute
##
## Настоящий мир (все шаги _step), открытая земля, изолированное сохранение. Итог
## «LEGION BOT LAWYER: N/M OK»; код выхода 1, если что-то упало.
##

const SAVE := "user://legion_bot_lawyer_test.cfg"
const DT := 1.0 / 60.0
## Откуда приходит Юрист: спереди, наискось, сверху и снизу рубежа.
const STARTS: Array[Vector2] = [Vector2(780, 340), Vector2(760, 250), Vector2(740, 470),
	Vector2(820, 420)]

var w: LegionWorld
var checks := 0
var fails := 0


func _initialize() -> void:
	_run.call_deferred()


func check(ok: bool, text: String) -> void:
	checks += 1
	if not ok:
		fails += 1
	print("  %s %s" % ["ok" if ok else "FAIL", text])


func _run() -> void:
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	w = (load("res://scenes/legion_world.tscn") as PackedScene).instantiate() as LegionWorld
	w.embedded = true
	root.add_child(w)
	root.size = Vector2i(1280, 720)
	await process_frame
	test_empty_segment()
	test_manned_no_rally()
	test_no_rally_from_fight()
	Campaign.reset()
	print("LEGION BOT LAWYER: %d/%d OK" % [checks - fails, checks])
	quit(1 if fails else 0)


## Пустая карта без волн, открытая земля; bot — с пустыми рубежами (не строит, не чертит).
func fresh(with_bot: bool) -> void:
	w.dev["spawn_units"] = "0"
	w.dev["no_waves"] = "1"
	w.dev["no_build"] = "1"
	w.start_map("wasteland")
	w.set_process(false)
	w.terrain = LegionTerrain.new().setup({})
	w.grid.rebuild()
	w.dev_invuln = false
	w.hero.reset()
	w.bot = null
	if with_bot:
		var bot := LegionBot.new()
		bot.setup(w, LegionBot.SELECTIVE, {"bot_lines": []})
		w.bot = bot


## Договор вахтёров на x = 600 (два участка), вахтёров нет — места пусты; позади рубежа
## шестеро свободных подрядчиков (на договор вахтёров они не встанут).
func scene(start: Vector2) -> Dictionary:
	var c := w.contracts.add_contract(PackedVector2Array([Vector2(600, 280), Vector2(600, 408)]),
		1, false, LegionCfg.KIND_GUARD)
	for i in 6:
		w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(470 + (i % 2) * 14, 310 + i * 12))
	var f := w.spawn_foe_on_path("lawyer", PackedVector2Array([start, w.cauldron_pos]), start)
	return {"c": c, "f": f}


## Шагаем мир, пока Юрист жив и участков не рвали; не дольше limit с.
func play(f: Foe, limit: float) -> void:
	var t := 0.0
	while t < limit and f.alive and int(w.stats.get("segments_torn", 0)) == 0:
		w._step(DT)
		t += DT


func test_empty_segment() -> void:
	print("— пустой участок: Юрист без ответа рвёт, бот спасает")
	var torn_off := 0
	var saved_on := 0
	var q_on := 0
	var rally_on := 0
	for start in STARTS:
		for with_bot in [false, true]:
			fresh(with_bot)
			var s := scene(start)
			var f: Foe = s["f"]
			play(f, 15.0)
			var torn := int(w.stats.get("segments_torn", 0)) > 0
			if not with_bot:
				torn_off += int(torn)
				continue
			saved_on += int(not torn and not f.alive)
			q_on += int(w.stats.get("bot_lawyer_q", 0))
			rally_on += int(w.stats.get("bot_lawyer_rallies", 0))
			print("    старт %s: %s, Ку %d, «Сбор» %d" % [start, "порван" if torn else
				("Юрист убит" if not f.alive else "жив"), int(w.stats.get("bot_lawyer_q", 0)),
				int(w.stats.get("bot_lawyer_rallies", 0))])
	check(torn_off == STARTS.size(),
		"без бота Юрист рвёт пустой участок: %d/%d" % [torn_off, STARTS.size()])
	check(saved_on == STARTS.size(),
		"с ботом участок цел, Юрист убит: %d/%d" % [saved_on, STARTS.size()])
	check(q_on >= STARTS.size(), "Ку ушёл в Юриста в каждом случае: %d" % q_on)
	check(rally_on >= STARTS.size(), "«Сбор» к точке зачитки в каждом случае: %d" % rally_on)


## v20: строй Юриста не бьёт (Foe.is_law_immune) — занятый участок сам себя уже не спасает, бот
## отвечает Ку и на него. До v20 здесь проверялось обратное: «Ку не тратили — участок держат свои».
func test_manned_no_rally() -> void:
	print("— занятый участок: строй Юриста не бьёт, бот отвечает Ку")
	for with_bot in [false, true]:
		fresh(with_bot)
		var s := scene(STARTS[0])
		var c: Contract = s["c"]
		var f: Foe = s["f"]
		for p in c.posts:
			var u := w.spawn_unit(LegionCfg.KIND_GUARD, p["pos"])
			u.assign(c, p)
			u._arrive()
		play(f, 15.0)
		var torn := int(w.stats.get("segments_torn", 0)) > 0
		if not with_bot:
			check(torn, "без бота Юрист рвёт и ЗАНЯТЫЙ участок: строй его не трогает")
			continue
		check(int(w.stats.get("bot_lawyer_q", 0)) >= 1, "Ку ушёл в Юриста")
		check(not f.alive and not torn, "Юрист убит, участок цел")


## Свободные рядом с точкой уже дерутся: «Сбор» их из драки не выдёргивает (первая версия
## выдёргивала и проигрывала «Лабиринт»); Ку в Юриста при этом уходит.
func test_no_rally_from_fight() -> void:
	print("— «Сбор» не выдёргивает дерущихся")
	fresh(true)
	var s := scene(STARTS[0])
	var f: Foe = s["f"]
	# зомби стоит вплотную к свободным и не идёт — они с ним дерутся
	var z := w.spawn_foe_on_path("zombie", PackedVector2Array([Vector2(490, 340)]),
		Vector2(490, 340))
	z.speed = 0.0
	w.dev_invuln = false
	z.hp = 1.0e6
	z.max_hp = z.hp
	var t := 0.0
	while t < 6.0 and f.alive and f.law_c == null:
		w._step(DT)
		t += DT
	for i in 60:
		w._step(DT)
	check(f.law_c != null or not f.alive, "Юрист выбрал пустой участок")
	check(int(w.stats.get("bot_lawyer_q", 0)) >= 1, "Ку в Юриста")
	check(int(w.stats.get("bot_lawyer_rallies", 0)) == 0, "«Сбор» не звали: рядом драка")
