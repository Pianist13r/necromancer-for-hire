extends SceneTree
##
## Регресс «вес головы» и «урок главнее совета» (ветка slow/pace2, 27.09.2026; финальный
## проверяющий опроверг два пункта темпа D-0927-49 на 07a0c43):
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_heads_test.gd -- --mute
##
## A. Поредевший враг весит souls_mult прежних голов — всё, что платит «за голову», его учитывает:
##    «Счётчик сдельщины» (мана и «Сдельная премия»), «Душеприказчик», опыт кампании
##    (kills_rewardable), шанс элитного; премия элитного душами — сверх веса, не ×вес.
## B. Пока идёт урок (плашка), советы-подписи поля молчат и не тратят свой лимит; метка пружины —
##    состояние боя — остаётся.
## Всё зовётся через публичные вызовы мира и предметов: на 07a0c43 файл разбирается, и каждая
## проверка падает отдельной строкой FAIL. Итог «LEGION HEADS: N/M OK»; код 1, если что-то упало.
##

const SAVE := "user://legion_heads_test.cfg"
const W2 := 2.0   ## вес головы группы 2 → 1 (темп ×0,5)

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


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _run() -> void:
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	root.size = Vector2i(1280, 720)
	w = (load("res://scenes/legion_world.tscn") as PackedScene).instantiate() as LegionWorld
	w.embedded = true
	root.add_child(w)
	await _frames(2)
	w.set_process(false)
	# «Счётчик сдельщины» и «Премия квартала» ушли из пула с артефактами v2 (D-0927-163) —
	# их проверка снята вместе с ними
	test_soul_heal()
	test_kills_rewardable()
	test_elite_chance()
	test_elite_souls()
	await test_lesson_silences_hints()
	Campaign.reset()
	print("LEGION HEADS: %d/%d OK" % [checks - fails, checks])
	quit(1 if fails else 0)


func _start(map_id: String) -> void:
	w.in_campaign = false
	w.dev = {"no_waves": "1", "spawn_units": "0", "difficulty": "normal", "elite": "0"}
	w.start_map(map_id)
	w.set_process(false)


func _foe(mult: float, type := "zombie") -> Foe:
	var at := Vector2(760, 130)
	return w.spawn_foe_on_path(type, PackedVector2Array([at]), at, false,
		{"wave": 1, "souls_mult": mult})


## Убить натиском: событие предметов charge_kill, затем смерть (как Legionnaire._tick_charge).
func _charge_kill(f: Foe) -> void:
	w.items.on(&"charge_kill", [f])
	f.take_damage(1.0e7, f.position)


func test_soul_heal() -> void:
	print("— «Душеприказчик» лечит за прежние головы")
	_start("fork")
	w.items.grant(&"soul_magnet")
	w.cauldron_hp = 100.0
	_foe(W2).take_damage(1.0e7, Vector2(760, 130))
	# лечение за голову — из реестра (v2: 0,5), вес 2 → вдвое
	var heal := 2.0 * float(LegionItemDb.item(&"soul_magnet")["params"]["heal"])
	check(is_equal_approx(w.cauldron_hp, 100.0 + heal), "вес 2 → лечение %.1f (Котёл %.1f)"
		% [heal, w.cauldron_hp])


func test_kills_rewardable() -> void:
	print("— опыт кампании за прежние головы")
	_start("fork")
	var k0 := int(w.stats["kills_rewardable"])
	for i in 3:
		_foe(5.0 / 3.0).take_damage(1.0e7, Vector2(760, 130))
	var got := int(w.stats["kills_rewardable"]) - k0
	check(got == 5, "три врага группы 5 → 3: kills_rewardable +%d (5)" % got)
	check(int(w.stats["kills"]) == 3, "упокоено на экране — сами тела (3)")


func test_elite_chance() -> void:
	print("— шанс элитного ×вес головы")
	_start("fork")
	w.dev.erase("elite")
	var heavy := _foe(W2)
	var light := _foe(1.0)
	var n := 2000
	var got := {}
	for f: Foe in [heavy, light]:
		var e0 := int(w.stats.get("elites", 0))
		for i in n:
			f.elite = false
			w.items.roll_elite(f)
		got[f] = int(w.stats.get("elites", 0)) - e0
	var base := CfgItems.ELITE_CHANCE * n
	check(absf(float(got[light]) - base) < base * 0.4, "вес 1: элитных %d из %d (≈ %.0f)"
		% [got[light], n, base])
	check(absf(float(got[heavy]) - 2.0 * base) < base * 0.5, "вес 2: элитных %d из %d (≈ %.0f)"
		% [got[heavy], n, 2.0 * base])
	# потолок не съедает компенсацию: шанс на потолке × вес
	# шанс выше потолка: тот же ключ elite_chance, что у поправки «Хедхантеры» (v2 — не артефакт)
	w.mods = {"elite_chance": 0.075}
	var e1 := int(w.stats.get("elites", 0))
	for i in n:
		heavy.elite = false
		w.items.roll_elite(heavy)
	var capped := int(w.stats.get("elites", 0)) - e1
	w.mods = {}
	var want := CfgItems.ELITE_CHANCE_CAP * 2.0 * n
	check(absf(float(capped) - want) < want * 0.25, "на потолке вес 2: %d из %d (≈ %.0f)"
		% [capped, n, want])


func test_elite_souls() -> void:
	print("— премия элитного душами — сверх веса головы")
	_start("fork")
	var s0 := w.souls
	var f := _foe(W2)
	f.make_elite()
	f.take_damage(1.0e7, f.position)
	# зомби 3 души: вес 2 → 6, премия элитного (×4 − 1) × 3 = 9 → 15
	check(w.souls - s0 == 15, "элитный вес 2: +%d душ (15 = 3×2 + 3×3)" % (w.souls - s0))


## Урок идёт — советы молчат (зонд проверяющего fvprobe/lesson_hint.gd, случаи 1 и 1b).
func test_lesson_silences_hints() -> void:
	print("— урок на плашке: советы поля молчат, метка пружины есть")
	Campaign.reset()
	Campaign.unlock_all()
	w.in_campaign = true
	w.dev = {"difficulty": "intern", "no_waves": "1"}
	w.start_map("gatehouse")
	w.start_lessons(true)
	var tut := w.tutorial
	await _frames(2)
	var bl: Dictionary = (w.map["bot_lines"] as Array)[2]
	var a := Vector2(float(bl["a"][0]), float(bl["a"][1]))
	var b := Vector2(float(bl["b"][0]), float(bl["b"][1]))
	w.contracts.set_kind(LegionCfg.KIND_LABORER)
	var c := w.contracts.add_contract(PackedVector2Array([a, b]),
		w.contracts.default_side(PackedVector2Array([a, b])), false)
	c.ttl = 999.0
	for i in 12 * 60:
		var manned := 0
		for s in c.seg_count():
			manned += c.seg_manned(s)
		if manned >= 4:
			break
		w._step(1.0 / 60.0)
	tut.force_lesson(&"spring")
	for k in w.contracts.contracts:
		for s in k.seg_count():
			if k.seg_alive(s):
				k.seg_bend[s] = LegionCfg.PRESS_BREAK * 0.6
	var shown0 := 0
	for t: StringName in LegionIntuit.TYPES:
		shown0 += w.intuit.hints_shown(t)
	w.intuit.scan()
	var spring_seen := false
	for s in c.seg_count():
		spring_seen = spring_seen or w.intuit.spring_mult(c, s) > 0.0
	check(tut != null and tut.step_id() == &"spring", "урок «пружина» на плашке")
	check(w.intuit._labels.is_empty(), "советов на поле нет при уроке «пружина» (%d)"
		% w.intuit._labels.size())
	w.hero._cd[2] = 0.0
	w.intuit.scan()
	check(w.intuit._labels.is_empty(), "и совета «Е — строй прогибается» тоже нет (Е готова)")
	var shown := 0
	for t: StringName in LegionIntuit.TYPES:
		shown += w.intuit.hints_shown(t)
	check(shown == shown0, "лимит советов не потрачен (%d → %d)" % [shown0, shown])
	check(spring_seen, "метка пружины (состояние боя) при уроке есть")
	w.in_campaign = false
	if w.tutorial != null:
		w.tutorial.teardown()
		w.tutorial = null
