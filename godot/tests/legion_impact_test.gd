extends SceneTree
##
## Регресс «импакта» способностей (slow/impact, 26.09.2026, Игорь: «у скиллов, особенно у
## молнии, нужны сильно более интересные анимации, чтобы от них импакт чувствовался»):
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_impact_test.gd -- --mute
##
## 1) Ку в полной графике — молния из нескольких прыжков с задержкой картинки на прыжок,
##    ответвлениями и мерцанием формы; у целей — «под током»; всё само гаснет, узлы не копятся;
## 2) Ку в экономной графике — облегчённая, но читаемая молния (свечение + сердцевина), без слоя
##    эффектов; узлы тоже убираются;
## 3) Дубль-вэ, Е, натиск и «Точно!» рождают свои эффекты; у ускоренных Е — шлейф;
## 4) бой с кастами Ку/Дубль-вэ/Е одинаков до числа: полная графика, экономная и без слоя;
## 5) стоп-кадр Ку при кадрах движка (_process, фиксированный шаг) только откладывает шаги
##    мира: итог и число шагов те же, что в экономной графике без стоп-кадра.
## Итог «LEGION IMPACT: N/M OK»; код выхода 1, если что-то упало. Сохранение временное.
##

const SAVE := "user://legion_impact_test.cfg"
const DT := 1.0 / 60.0
const BATTLE_S := 45.0

var w: LegionWorld
var _fails := 0
var _checks := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(cond: bool, what: String) -> void:
	_checks += 1
	if cond:
		print("  ok   ", what)
	else:
		_fails += 1
		print("  FAIL ", what)


func _run() -> void:
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	Settings.economy_override = "off"
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	w = scene.instantiate() as LegionWorld
	root.add_child(w)
	await process_frame
	w.set_process(false)
	await _test_bolt_full()
	await _test_bolt_economy()
	_test_w_e_charge()
	await _test_battle_equal()
	await _test_hitstop_steps()
	Settings.economy_override = ""
	Campaign.reset()
	print("LEGION IMPACT: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


func _fx() -> LegionFx:
	return w.get_node_or_null("LegionFx") as LegionFx


## Слой «импакта» (или null на старом коде — тогда проверки падают, а не роняют скрипт).
func _impact() -> Object:
	var fx := _fx()
	if fx == null or not "impact" in fx:
		return null
	return fx.get("impact")


func _fresh(map_id := "fork") -> void:
	w.dev["no_waves"] = "1"
	w.dev["spawn_units"] = "0"
	w.start_map(map_id)
	w.dev_invuln = false


## Кучка врагов для цепи (Ку бьёт до 4 целей) — на открытой части «fork».
func _foes_at(center: Vector2, n: int) -> Array[Foe]:
	var out: Array[Foe] = []
	for k in n:
		var p := center + Vector2(34.0 * k, 22.0 * (k % 2))
		var f := w.spawn_foe_on_path("zombie", PackedVector2Array([p, p + Vector2(-2, 0)]), p)
		out.append(f)
	return out


func _count_nodes(n: Node) -> int:
	var c := 1
	for ch in n.get_children():
		c += _count_nodes(ch)
	return c


## Слой узлов героя (имя «HeroFx» не годится: после перезапуска карты старый ещё в дереве).
func _hero_fx() -> Node:
	return w.hero.get("_fx_layer") as Node


func _test_bolt_full() -> void:
	print("— Ку, полная графика")
	_fresh()
	var fx := _fx()
	_check(fx != null, "слой эффектов есть в полной графике")
	if fx == null:
		return
	fx.set_process(false)
	var imp := _impact()
	_check(imp != null, "у слоя есть «импакт» (LegionImpactFx)")
	var foes := _foes_at(Vector2(700, 470), 5)
	fx.tick(DT)
	var nodes0 := _count_nodes(w)
	var ok := w.hero.cast(LegionHero.SLOT_Q, foes[0].position)
	_check(ok, "Ку состоялась")
	if imp == null:
		return
	var st: Dictionary = imp.call("bolt_stats")
	_check(int(st.get("hops", 0)) == LegionCfg.Q_CHAIN_BASE_TARGETS,
		"цепь из %d прыжков: %d" % [LegionCfg.Q_CHAIN_BASE_TARGETS, int(st.get("hops", 0))])
	_check(int(st.get("visible", -1)) == 1, "в миг каста виден только первый прыжок (%d)"
		% int(st.get("visible", -1)))
	_check(int(st.get("points", 0)) >= 9, "канал — ломаная, а не отрезок (%d точек)"
		% int(st.get("points", 0)))
	_check(int(st.get("branches", 0)) >= 2, "ответвления есть (%d)" % int(st.get("branches", 0)))
	var shape0: PackedVector2Array = imp.call("bolt_shape", 0)
	var arrived_first := 0
	var reshaped := false
	for k in roundi(0.25 / DT):
		fx.tick(DT)
		if k == roundi(0.06 / DT):
			arrived_first = int((imp.call("bolt_stats") as Dictionary).get("visible", 0))
		var shape: PackedVector2Array = imp.call("bolt_shape", 0)
		if shape.size() > 0 and shape != shape0:
			reshaped = true
	_check(arrived_first >= 2 and arrived_first < LegionCfg.Q_CHAIN_BASE_TARGETS,
		"через 60 мс разряд дошёл дальше, но не до конца цепи (%d)" % arrived_first)
	_check(reshaped, "форма молнии пересобирается (мерцание)")
	_check(int((imp.call("bolt_stats") as Dictionary).get("visible", 0))
		== LegionCfg.Q_CHAIN_BASE_TARGETS, "к 0,25 с видны все прыжки")
	_check(int(imp.call("electrified_count")) >= 1, "цели «под током»")
	_check(int(imp.call("live_count")) > 0, "искры, кольца, пятна, отсветы — живы")
	var hero_fx := _hero_fx()
	_check(hero_fx != null and hero_fx.get_child_count() == 0,
		"в полной графике узлов-линий героя нет — молния рисуется слоем")
	for k in roundi(5.0 / DT):
		fx.tick(DT)
	var st2: Dictionary = imp.call("bolt_stats")
	_check(int(st2.get("hops", -1)) == 0, "через 5 с молнии нет")
	_check(int(imp.call("electrified_count")) == 0, "«под током» кончилось")
	_check(int(imp.call("live_count")) == 0, "частицы импакта отгорели (%d)"
		% int(imp.call("live_count")))
	await process_frame
	await process_frame
	_check(_count_nodes(w) <= nodes0, "узлы не копятся: %d → %d" % [nodes0, _count_nodes(w)])
	# electrify напрямую — крючок для оглушения Ку (другая ветка)
	var f := _foes_at(Vector2(500, 470), 1)[0]
	imp.call("electrify", f, 0.5)
	fx.tick(DT)
	_check(int(imp.call("electrified_count")) == 1, "electrify(foe, 0.5) — идёт")
	for k in roundi(0.6 / DT):
		fx.tick(DT)
	_check(int(imp.call("electrified_count")) == 0, "electrify: кончилось по времени")


func _test_bolt_economy() -> void:
	print("— Ку, экономная графика")
	Settings.economy_override = "on"
	w._sync_gfx_layers()
	await process_frame
	_fresh()
	_check(_fx() == null, "в экономной графике слоя эффектов нет")
	var foes := _foes_at(Vector2(700, 470), 5)
	var ok := w.hero.cast(LegionHero.SLOT_Q, foes[0].position)
	_check(ok, "Ку состоялась")
	var hero_fx := _hero_fx()
	var lines := 0
	for ch in hero_fx.get_children():
		if ch is Line2D:
			lines += 1
	_check(lines >= 2 * LegionCfg.Q_CHAIN_BASE_TARGETS,
		"читаемая молния: свечение и сердцевина на каждый прыжок (%d линий)" % lines)
	for k in 60:
		await process_frame
	_check(hero_fx.get_child_count() == 0, "через секунду узлы молнии убраны (%d)"
		% hero_fx.get_child_count())
	Settings.economy_override = "off"
	w._sync_gfx_layers()
	await process_frame


func _test_w_e_charge() -> void:
	print("— Дубль-вэ, Е, натиск")
	_fresh()
	var fx := _fx()
	var imp := _impact()
	if fx == null or imp == null:
		_check(false, "слой импакта для Дубль-вэ/Е")
		return
	fx.set_process(false)
	fx.clear_all()
	var f := _foes_at(Vector2(600, 470), 1)[0]
	f.take_damage(100000.0, f.position + Vector2(10, 0))
	var n0 := int(imp.call("live_count"))
	_check(w.hero.cast(LegionHero.SLOT_W, f.position), "Дубль-вэ поднял труп")
	_check(int(imp.call("live_count")) > n0 + 6, "Дубль-вэ: круг, столб, огоньки (%d)"
		% int(imp.call("live_count")))
	for k in roundi(3.0 / DT):
		fx.tick(DT)
	var units: Array[Legionnaire] = []
	for k in 4:
		units.append(w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(520 + 20 * k, 560)))
	fx.tick(DT)
	fx.clear_all()
	n0 = int(imp.call("live_count"))
	_check(w.hero.cast(LegionHero.SLOT_E, units[0].position), "Е состоялась")
	_check(int(imp.call("live_count")) > n0 + 8, "Е: волна и пыль (%d)" % int(imp.call("live_count")))
	for k in roundi(1.0 / DT):
		fx.tick(DT)
	# бойцы бегут — у ускоренных шлейф (мир не шагает: двигаем руками)
	var streaks0 := int(imp.call("haste_trails"))
	for k in roundi(0.5 / DT):
		for u in units:
			u.position += Vector2(3.0, 0.0)
		fx.tick(DT)
	_check(int(imp.call("haste_trails")) > streaks0, "у ускоренных — шлейф (%d → %d)"
		% [streaks0, int(imp.call("haste_trails"))])
	_check(units[0].view.modulate != Color.WHITE, "у ускоренных — цветной отлив")
	for k in roundi(4.0 / DT):
		fx.tick(DT)
	n0 = int(imp.call("live_count")) + fx.live_count()
	w.charge_impact.emit(Vector2(640, 500), false)
	var plain := int(imp.call("live_count")) + fx.live_count() - n0
	_check(plain > 3, "натиск: кольцо, пыль, искры (+%d)" % plain)
	for k in roundi(0.3 / DT):
		fx.tick(DT)
	n0 = int(imp.call("live_count")) + fx.live_count()
	w.charge_impact.emit(Vector2(640, 500), true)
	var perfect := int(imp.call("live_count")) + fx.live_count() - n0
	_check(perfect > plain + 4, "«Точно!» — сильнее обычного (+%d против +%d)" % [perfect, plain])
	# мир здесь не шагает — Аврал кончаем шагом героя, иначе отлив ускоренных шёл бы вечно
	w.hero.tick(LegionCfg.E_DURATION_CAP + 1.0)
	for k in roundi(5.0 / DT):
		fx.tick(DT)
	_check(units[0].view.modulate == Color.WHITE, "Аврал кончился — отлив снят")
	_check(int(imp.call("live_count")) == 0, "всё отгорело (%d)" % int(imp.call("live_count")))


## Каст по правилу, зависящему только от состояния мира (одинаково во всех графиках).
func _force_casts(world: LegionWorld, k: int) -> void:
	var h := world.hero
	if k % 90 == 0:
		for f in world.foes:
			if f.alive:
				h.cast(LegionHero.SLOT_Q, f.position)
				break
	if k % 150 == 30:
		for f in world.foes:
			if f.is_fresh_corpse():
				h.cast(LegionHero.SLOT_W, f.position)
				break
	if k % 240 == 60:
		for u in world.units:
			if u.alive:
				h.cast(LegionHero.SLOT_E, u.position)
				break


func _result(world: LegionWorld) -> Dictionary:
	return {"t": snappedf(world.now, 0.001), "kills": int(world.stats["kills"]),
		"lost": int(world.stats["lost"]), "hp": snappedf(world.cauldron_hp, 0.001),
		"units": world.army_alive(), "foes": world.foes.size(), "souls": world.souls,
		"mana": snappedf(world.contracts.mana, 0.001), "rng": world.rng.state,
		"cd": [snappedf(world.hero.cd_left(0), 0.001), snappedf(world.hero.cd_left(1), 0.001),
			snappedf(world.hero.cd_left(2), 0.001)]}


## mode: &"full" | &"economy" | &"nofx"
func _battle(mode: StringName) -> Dictionary:
	Settings.economy_override = "on" if mode == &"economy" else "off"
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	var world := scene.instantiate() as LegionWorld
	root.add_child(world)
	await process_frame
	if mode == &"nofx":
		# как --dev fx=0: полная графика, но без слоя (dev разбирается в _ready — ставим после)
		world.dev["fx"] = "0"
		world._sync_gfx_layers()
		await process_frame
	world.set_process(false)
	world.args["bot"] = "selective"
	seed(7)
	world.start_map("fork")
	var fx := world.get_node_or_null("LegionFx") as LegionFx
	if fx != null:
		fx.set_process(false)
	var casts := [0]
	world.hero_cast.connect(func(_s: int, _a: Vector2) -> void: casts[0] += 1)
	for k in roundi(BATTLE_S / DT):
		_force_casts(world, k)
		world._step(DT)
		if fx != null:
			fx.tick(DT)
		if world.phase != LegionWorld.Phase.BATTLE:
			break
	var res := _result(world)
	res["casts"] = casts[0]
	res["fx"] = fx != null
	world.queue_free()
	await process_frame
	Settings.economy_override = "off"
	return res


func _test_battle_equal() -> void:
	print("— бой с кастами одинаков: полная / экономная / без слоя")
	var full := await _battle(&"full")
	var eco := await _battle(&"economy")
	var nofx := await _battle(&"nofx")
	print("    полная:     ", full)
	print("    экономная:  ", eco)
	print("    без слоя:   ", nofx)
	_check(bool(full["fx"]) and not bool(eco["fx"]) and not bool(nofx["fx"]),
		"слой эффектов только в полной графике")
	_check(int(full["casts"]) >= 5, "касты были (%d)" % int(full["casts"]))
	_check(int(full["kills"]) > 0, "убитые были (%d)" % int(full["kills"]))
	full.erase("fx")
	eco.erase("fx")
	nofx.erase("fx")
	_check(full == eco, "полная == экономная")
	_check(full == nofx, "полная == без слоя")


## Бой кадрами движка (_process с фиксированным delta): стоп-кадр Ку пропускает кадры, но
## шаги мира те же. Сравниваем после одинакового числа ШАГОВ; кадров у полной — больше.
func _process_battle(economy: bool) -> Dictionary:
	Settings.economy_override = "on" if economy else "off"
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	var world := scene.instantiate() as LegionWorld
	root.add_child(world)
	await process_frame
	world.set_process(false)
	world.args["bot"] = "selective"
	seed(7)
	world.start_map("fork")
	var fx := world.get_node_or_null("LegionFx") as LegionFx
	if fx != null:
		fx.set_process(false)
	var steps := [0]
	var dts := PackedFloat32Array()
	world.hero_cast.connect(func(_s: int, _a: Vector2) -> void: pass)
	var frames := 0
	var last_now := world.now
	var k := 0
	while k < roundi(BATTLE_S / DT) and frames < roundi(BATTLE_S / DT) * 2:
		frames += 1
		if world.now == last_now:
			# шаг мира ещё не сделан на этом «k» — каст по правилу до шага, как в _battle
			_force_casts(world, k)
		world._process(DT)
		if fx != null:
			fx.tick(DT)
		if world.now != last_now:
			dts.append(world.now - last_now)
			last_now = world.now
			steps[0] += 1
			k += 1
		if world.phase != LegionWorld.Phase.BATTLE:
			break
	var res := _result(world)
	res["steps"] = steps[0]
	res["dt_hash"] = hash(dts)
	res["frames"] = frames
	world.queue_free()
	await process_frame
	Settings.economy_override = "off"
	return res


func _test_hitstop_steps() -> void:
	print("— стоп-кадр Ку не меняет шаги мира")
	var full := await _process_battle(false)
	var eco := await _process_battle(true)
	print("    полная:    ", full)
	print("    экономная: ", eco)
	_check(int(full["frames"]) > int(eco["frames"]),
		"стоп-кадр в полной есть: кадров %d > %d" % [int(full["frames"]), int(eco["frames"])])
	var ff := int(full["frames"])
	var ef := int(eco["frames"])
	full.erase("frames")
	eco.erase("frames")
	_check(full == eco, "шаги (%d) и итог мира совпадают" % int(full["steps"]))
	_check(ff - ef < roundi(BATTLE_S / DT) / 20, "стоп-кадр скромный: +%d кадров" % (ff - ef))
