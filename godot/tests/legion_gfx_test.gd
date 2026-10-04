extends SceneTree
##
## Регресс пакета «графика» (26.09.2026, B-053/B-054/B-049; правки verifier по коммиту
## 9845273 — см. DECISIONS.md):
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_gfx_test.gd -- --mute
##
## 1) Settings.is_economy_graphics(): по умолчанию «полная»; хранится и читается как остальные
##    видео-настройки, override (тесты/замеры) не пишет user://settings.cfg;
## 2) экономная гасит «живость» CharView СРАЗУ (статик-флаг, без пересборки узлов);
## 3) переключение живёт ВЕСЬ СЕАНС на одном LegionWorld (LegionMain создаёт его один раз,
##    не на бой, — verifier 26.09): бой → пауза-переключение → меню → снова бой, в обе
##    стороны, FX/тени появляются и пропадают на каждом шаге, а не только при первой сборке;
## 4) появление под экономной не морозит тень (_pop_t) и не откладывает подскок до полной;
## 5) B-049: возраст трупа гонится часами мира, а после конца боя (мир больше не шагает)
##    таяние возвращается на свои часы — труп не застревает целым на экране итога;
## 6) бой бота на одном сиде совпадает до числа между полной и экономной графикой;
## 7) экран настроек знает переключатель;
## 8) verifier 26.09 (второй заход, пробы C:/AI/necro/batches/legion/gfx/verify2): порядок
##    детей мира как на master 2c36dc6 — тени сразу перед Contracts, LegionFx сразу перед Fx
##    (эффекты под предупреждениями и полоской HP Котла), и после переключений посреди боя;
##    hold (игра по переписке) и пауза не растапливают и не «оживляют» трупы; переключение в
##    меню не возвращает фоновую жизнь карты; свежий мир под экономной собирается без слоёв.
## Итог «LEGION GFX: N/M OK»; код выхода 1, если что-то упало. Сохранение временное, реальный
## user://settings.cfg владельца не читается и не пишется (Settings._cfg подменяется в памяти).
##

const SAVE := "user://legion_gfx_test.cfg"
const WORLD_SCENE := "res://scenes/legion_world.tscn"
const DT := 1.0 / 60.0
const BATTLE_S := 40.0

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
	_test_settings_storage()
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	var scene: PackedScene = load(WORLD_SCENE)
	w = scene.instantiate() as LegionWorld
	root.add_child(w)
	await process_frame
	w.set_process(false)
	_test_motion_toggle()
	_test_pop_shadow_under_economy()
	_test_corpse_age_follows_world_clock()
	await _test_corpse_resumes_after_battle()
	await _test_persistent_world_sync()
	await _test_child_order()
	await _test_corpse_hold_and_pause()
	await _test_corpse_natural_victory()
	await _test_menu_no_ambient()
	Campaign.reset()
	await _test_fresh_build_gates()
	await _test_battle_equal()
	await _test_settings_screen_has_toggle()
	Settings._cfg = null
	Settings.economy_override = ""
	CharView.economy_motion = false
	print("LEGION GFX: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


## Карта без своих бойцов на старте.
func _fresh(map_id: String) -> void:
	w.dev["no_waves"] = "1"
	w.dev["spawn_units"] = "0"
	w.start_map(map_id)
	w.dev_invuln = false


## 1) Хранение — как fullscreen/vsync, override в памяти не пишет диск.
func _test_settings_storage() -> void:
	print("— настройка хранится и читается")
	Settings._cfg = ConfigFile.new()
	Settings.economy_override = ""
	_check(not Settings.is_economy_graphics(), "по умолчанию — полная графика")
	Settings._cfg.set_value(Settings.SEC_VIDEO, Settings.KEY_ECONOMY, true)
	_check(Settings.is_economy_graphics(), "записанная экономная — уважается")
	Settings.economy_override = "off"
	_check(not Settings.is_economy_graphics(), "override перекрывает файл: off")
	Settings.economy_override = "on"
	_check(Settings.is_economy_graphics(), "override перекрывает файл: on")
	Settings.economy_override = ""
	_check(Settings.is_economy_graphics(), "без override — снова файл (true)")
	# apply() читает CharView.economy_motion из файла и в безголовом прогоне (bench/gate) —
	# серии бота на экономной графике должны различаться и без окна.
	CharView.economy_motion = false
	Settings.apply()
	_check(CharView.economy_motion, "apply() переносит настройку в CharView.economy_motion")
	Settings._cfg.set_value(Settings.SEC_VIDEO, Settings.KEY_ECONOMY, false)
	Settings.apply()
	_check(not CharView.economy_motion, "apply(): полная графика тоже переносится")


## 2) «Живость» гасится и включается СРАЗУ, без пересборки узлов вида.
func _test_motion_toggle() -> void:
	print("— «живость» переключается сразу (статик-флаг)")
	CharView.economy_motion = false
	_fresh("_plots")
	var u := w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(500, 600))
	u.view.set_locomotion(0.0)
	var last: float = u.view.get("_ap_sy")
	var changed := false
	for i in 400:
		u.view._process(DT)
		var sy: float = u.view.get("_ap_sy")
		if not is_equal_approx(sy, last):
			changed = true
		last = sy
	_check(changed, "полная графика: дыхание меняет масштаб корпуса")
	CharView.economy_motion = true
	var frozen: float = u.view.get("_ap_sy")
	changed = false
	for i in 400:
		u.view._process(DT)
		if not is_equal_approx(float(u.view.get("_ap_sy")), frozen):
			changed = true
	_check(not changed, "экономная: дыхание встало на месте, без нового вызова опоры")
	CharView.economy_motion = false


## 4) Верификатор 26.09: на 9845273 _pop_t замирал на 0.0 под economy_motion (никогда не
## доходил до -1.0), а shadow_alpha() умножает на _pop_t — новая фигура оставалась без тени
## навсегда, а при возврате к полной подскок «доигрывал» с опозданием.
func _test_pop_shadow_under_economy() -> void:
	print("— появление под экономной не морозит тень")
	CharView.economy_motion = false
	_fresh("_plots")
	var u1 := w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(400.0, 600.0))
	_check(is_equal_approx(float(u1.view.get("_pop_t")), 0.0), "полная: подскок идёт (_pop_t=0)")
	# рождение уже ПОД экономной — подскок сразу «закончен», тень не гасится
	CharView.economy_motion = true
	var u2 := w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(420.0, 600.0))
	_check(float(u2.view.get("_pop_t")) < 0.0, "экономная: новая фигура без подскока (_pop_t<0)")
	_check(u2.view.shadow_alpha() > 0.5,
		"экономная: тень новой фигуры не гасится (%.2f)" % u2.view.shadow_alpha())
	# переключение ПОСРЕДИ подскока полной графики — обязано завершиться немедленно, а не
	# застрять на дробном _pop_t (иначе тень гаснет насовсем, а при возврате доигрывает поздно)
	CharView.economy_motion = false
	var u3 := w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(440.0, 600.0))
	u3.view._process(DT)
	var mid: float = u3.view.get("_pop_t")
	_check(mid > 0.0 and mid < float(u3.view.get("_m_pop_time")), "подскок начался (%.4f)" % mid)
	CharView.economy_motion = true
	u3.view._process(DT)
	_check(float(u3.view.get("_pop_t")) < 0.0,
		"переключили посреди подскока — завершён немедленно, не заморожен")
	_check(u3.view.shadow_alpha() > 0.5,
		"тень восстановлена, не заморожена на нуле (%.2f)" % u3.view.shadow_alpha())
	CharView.economy_motion = false


## 5а) B-049: возраст трупа — часами мира (уже с масштабом «Отсрочки»), а не своими часами
## вида. В этом прогоне мир шагает вручную (foe.tick), без кадров движка — CharView._process
## (свои часы) никогда не вызывается, поэтому на старом коде (без view.set_corpse_age в
## foe.gd) _corpse_t остаётся 0.0, пока _dead_t идёт вперёд.
func _test_corpse_age_follows_world_clock() -> void:
	print("— B-049: труп тает по часам мира")
	_fresh("_plots")
	var p := Vector2(500.0, 400.0)
	var f := w.spawn_foe_on_path("zombie", PackedVector2Array([p, p + Vector2(-2.0, 0.0)]), p)
	f.take_damage(1000.0, p + Vector2(10.0, 0.0))
	_check(f.state == Foe.State.DEAD, "враг мёртв")
	if f.state != Foe.State.DEAD:
		return
	# «Отсрочка»: мир идёт в 0,35 от секунды — dt меньше часа́ реального времени
	for i in 40:
		f.tick(DT * 0.35)
	var dead_t: float = f.get("_dead_t")
	var corpse_t: float = f.view.get("_corpse_t")
	_check(dead_t > 0.0, "часы мира идут: %.3f" % dead_t)
	_check(is_equal_approx(corpse_t, dead_t),
		"возраст у вида = часам мира: вид %.4f, мир %.4f" % [corpse_t, dead_t])


## 5б) Верификатор 26.09: побочный эффект B-049 — foe.gd гонит set_corpse_age только пока
## мир шагает (phase == BATTLE). После конца боя _step() больше не идёт, и без отката на свои
## часы труп застревал бы целым (alpha=1.0) на экране итога навсегда. CharView — отдельный
## узел (PROCESS_MODE_PAUSABLE), кадры движка ему приходят независимо от w.set_process().
func _test_corpse_resumes_after_battle() -> void:
	print("— после конца боя труп снова тает")
	Settings.economy_override = "off"
	CharView.economy_motion = false
	_fresh("_plots")
	var p := Vector2(500.0, 400.0)
	var f := w.spawn_foe_on_path("zombie", PackedVector2Array([p, p + Vector2(-2.0, 0.0)]), p)
	f.take_damage(1000.0, p + Vector2(10.0, 0.0))
	for i in 20:
		w._step(DT)
	var mid_t: float = f.view.get("_corpse_t")
	_check(mid_t > 0.0, "труп тает в бою: %.4f" % mid_t)
	w.force_end(true)
	_check(w.phase != LegionWorld.Phase.BATTLE, "бой закончен (phase=%d)" % w.phase)
	for i in 45:
		await process_frame
	var after_t: float = f.view.get("_corpse_t")
	_check(after_t > mid_t, "труп продолжил таять после конца боя: %.4f → %.4f" % [mid_t, after_t])


## 3) Верификатор 26.09: LegionMain создаёт LegionWorld один раз на СЕССИЮ, не на бой
## (start_battle(): `if world == null`) — «со следующего боя» через _build() было неправдой,
## тот же мир возвращался в меню и в новый бой со старыми узлами. Настоящий путь: бой →
## переключение (как из паузы) → меню → снова бой, в обе стороны.
func _test_persistent_world_sync() -> void:
	print("— переключение живёт весь сеанс (тот же мир, не новый _build)")
	w.set_process(true)
	Settings.economy_override = "off"
	_fresh("_plots")
	await process_frame
	_check(w.get_node_or_null("LegionFx") != null, "полная: слой эффектов есть")
	_check(w.get_node_or_null("CharShadows") != null, "полная: тени есть")
	# полная → экономная ПОСРЕДИ боя (как из паузы) — применяется в тот же кадр, без выхода в меню
	Settings.economy_override = "on"
	await process_frame
	_check(w.get_node_or_null("LegionFx") == null, "экономная сразу в бою: слой эффектов снят")
	_check(w.get_node_or_null("CharShadows") == null, "экономная сразу в бою: тени сняты")
	# меню — тот же мир (go_to_menu ничего не пересобирает)
	w.go_to_menu()
	await process_frame
	_check(w.get_node_or_null("LegionFx") == null, "меню: слой эффектов по-прежнему снят")
	# снова в бой на том же мире — настройка не забылась
	_fresh("fork")
	await process_frame
	_check(w.get_node_or_null("LegionFx") == null,
		"новый бой (тот же мир), экономная: без слоя эффектов")
	_check(w.get_node_or_null("CharShadows") == null,
		"новый бой (тот же мир), экономная: без теней")
	# экономная → полная — так же через меню и новый бой, не только при первом _build()
	Settings.economy_override = "off"
	w.go_to_menu()
	await process_frame
	_fresh("fork")
	await process_frame
	_check(w.get_node_or_null("LegionFx") != null,
		"новый бой, вернули полную: слой эффектов создан")
	_check(w.get_node_or_null("CharShadows") != null,
		"новый бой, вернули полную: тени созданы")
	Settings.economy_override = ""
	w.set_process(false)


## 6) Итог боя бота совпадает до числа между полной и экономной графикой.
func _test_battle_equal() -> void:
	print("— бой одинаков в обеих графиках")
	var full := await _battle_with(false)
	var eco := await _battle_with(true)
	print("    полная: ", full)
	print("    экономная: ", eco)
	_check(int(full.get("kills", 0)) > 0, "в бою были убитые (%d)" % int(full.get("kills", 0)))
	_check(full == eco, "итоги мира совпадают")


func _battle_with(economy: bool) -> Dictionary:
	Settings.economy_override = "on" if economy else "off"
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	var scene: PackedScene = load(WORLD_SCENE)
	var world := scene.instantiate() as LegionWorld
	root.add_child(world)
	await process_frame
	world.set_process(false)
	world.args["bot"] = "selective"
	seed(7)
	world.start_map("fork")
	for k in roundi(BATTLE_S / DT):
		world._step(DT)
		if world.phase != LegionWorld.Phase.BATTLE:
			break
	var result := {"t": snappedf(world.now, 0.001), "kills": int(world.stats["kills"]),
		"lost": int(world.stats["lost"]), "hp": snappedf(world.cauldron_hp, 0.001),
		"units": world.army_alive(), "foes": world.foes.size(), "souls": world.souls,
		"mana": snappedf(world.contracts.mana, 0.001), "rng": world.rng.state}
	world.queue_free()
	await process_frame
	Settings.economy_override = ""
	Campaign.reset()
	return result


## 7) Экран настроек знает переключатель (нашёлся чекбокс с ожидаемой подписью).
func _test_settings_screen_has_toggle() -> void:
	print("— экран настроек содержит переключатель")
	Settings._cfg = ConfigFile.new()
	Settings.economy_override = "off"
	var screen := SettingsScreen.new()
	root.add_child(screen)
	await process_frame
	var found := _find_check(screen, "Экономная")
	_check(found != null, "чекбокс «Экономная графика» найден")
	if found != null:
		_check(not found.button_pressed, "начальное состояние — выключен (полная)")
	screen.queue_free()
	await process_frame


func _find_check(node: Node, needle: String) -> CheckBox:
	for c in node.get_children():
		if c is CheckBox and String((c as CheckBox).text).contains(needle):
			return c as CheckBox
		var deeper := _find_check(c, needle)
		if deeper != null:
			return deeper
	return null


# ── 8) verifier 26.09, второй заход ────────────────────────────────────────

func _frames(k: int) -> void:
	for i in k:
		await process_frame


## Роль ребёнка мира для сверки порядка (у TerrainView/PlotView имена автоматические).
func _kind(c: Node) -> String:
	if c is TerrainView:
		return "TerrainView"
	if c is LegionPlotView:
		return "PlotView"
	# новая подсветка рельефа входит, пока старая ещё в queue_free, — имя ей даёт движок
	if c is ObstacleHint:
		return "ObstacleHint"
	return String(c.name)


func _order_str() -> String:
	var out: PackedStringArray = []
	for c in w.get_children():
		out.append(_kind(c))
	return ", ".join(out)


func _idx(kind: String) -> int:
	for c in w.get_children():
		if _kind(c) == kind:
			return c.get_index()
	return -1


func _count(kind: String) -> int:
	var n := 0
	for c in w.get_children():
		if _kind(c) == kind:
			n += 1
	return n


## Порядок детей мира на master 2c36dc6 (у всех z_index 0 — решает он) — сплошной отрезок:
## TerrainView, PlotView, ObstacleHint, CharShadows, Contracts, FxGround, Entities,
## ContractOverlay, LegionFx, Fx (дальше HUD и прочее — CanvasLayer/Node). В экономной — тот же
## отрезок без CharShadows, FxGround и LegionFx.
func _check_order(tag: String, full: bool) -> void:
	print("    ", tag, ": ", _order_str())
	var chain: Array[String] = ["TerrainView", "PlotView", "ObstacleHint", "Contracts", "Entities",
		"ContractOverlay", "Fx"]
	if full:
		chain = ["TerrainView", "PlotView", "ObstacleHint", "CharShadows", "Contracts", "FxGround",
			"Entities", "ContractOverlay", "LegionFx", "Fx"]
	var prev := -1
	var ok := true
	for k in chain:
		var i := _idx(k)
		if i < 0 or (prev >= 0 and i != prev + 1):
			ok = false
		prev = i
	_check(ok, "%s: порядок как на master" % tag)
	var want := 1 if full else 0
	var n_fx := _count("LegionFx")
	var n_sh := _count("CharShadows")
	var n_gr := _count("FxGround")
	_check(n_fx == want and n_sh == want and n_gr == want,
		"%s: слоёв ровно по %d (fx=%d, тени=%d, земля=%d)" % [tag, want, n_fx, n_sh, n_gr])


## A/B: на 651cf7e LegionFx вставал ПОСЛЕ Fx (move_child под HUD — а HUD CanvasLayer), а тени
## после экономной → полной посреди боя — первым ребёнком, под рельефом и участками.
func _test_child_order() -> void:
	print("— порядок детей мира как на master")
	w.set_process(true)
	Settings.economy_override = "off"
	CharView.economy_motion = false
	w.start_map("fork")
	await _frames(5)
	_check_order("полная, start_map", true)
	Settings.economy_override = "on"
	await _frames(3)
	_check_order("полная → экономная посреди боя", false)
	Settings.economy_override = "off"
	await _frames(3)
	_check_order("экономная → полная посреди боя", true)
	w.set_paused(true)
	Settings.economy_override = "on"
	await _frames(3)
	Settings.economy_override = "off"
	await _frames(3)
	w.set_paused(false)
	_check_order("туда-обратно в паузе", true)
	for i in 5:
		Settings.economy_override = "on"
		await _frames(2)
		Settings.economy_override = "off"
		await _frames(2)
	_check_order("пять переключений подряд", true)
	Settings.economy_override = "on"
	await _frames(2)
	w.start_map("fork")
	await _frames(3)
	_check_order("новая карта под экономной", false)
	Settings.economy_override = "off"
	await _frames(3)
	_check_order("и снова полная", true)
	Settings.economy_override = ""
	w.set_process(false)


func _kill_foe_at(p: Vector2) -> Foe:
	var f := w.spawn_foe_on_path("zombie", PackedVector2Array([p, p + Vector2(-2.0, 0.0)]), p)
	f.take_damage(1000.0, p + Vector2(10.0, 0.0))
	return f


## C: на 651cf7e через 0,3 с молчания set_corpse_age вид уходил на свои часы — в hold (дерево
## не на паузе) труп таял за время раздумий агента, а первый же шаг после hold его «оживлял»
## (alpha 1). Мир стоит — стоит и труп; мир пошёл — труп идёт с того же места.
func _test_corpse_hold_and_pause() -> void:
	print("— hold и пауза не растапливают и не «оживляют» трупы")
	w.set_process(true)
	Settings.economy_override = "off"
	CharView.economy_motion = false
	_fresh("_plots")
	await _frames(2)
	# смерть — и сразу hold, до единого шага мира (труп ещё ни разу не вели tick-ом)
	var f0 := _kill_foe_at(Vector2(560.0, 420.0))
	w.hold = true
	await _frames(60)
	_check(is_zero_approx(float(f0.view.get("_corpse_t"))),
		"hold сразу после смерти: труп не стареет (%.3f)" % float(f0.view.get("_corpse_t")))
	w.hold = false
	var f := _kill_foe_at(Vector2(500.0, 400.0))
	await _frames(30)
	var c0: float = f.view.get("_corpse_t")
	var a0: float = f.view.get("_corpse_a")
	_check(c0 > 0.0, "в бою труп стареет (%.3f)" % c0)
	w.hold = true
	await _frames(420)  # 7 с при --fixed-fps 60, как у verifier
	var c1: float = f.view.get("_corpse_t")
	var a1: float = f.view.get("_corpse_a")
	_check(is_equal_approx(c1, c0) and is_equal_approx(a1, a0),
		"hold 7 с: возраст %.3f → %.3f, alpha %.2f → %.2f" % [c0, c1, a0, a1])
	w.hold = false
	await _frames(1)
	var c2: float = f.view.get("_corpse_t")
	_check(c2 >= c1 and c2 - c1 < 0.05,
		"после hold — дальше с того же места, без скачка: %.3f → %.3f" % [c1, c2])
	w.set_paused(true)
	await _frames(120)
	var c3: float = f.view.get("_corpse_t")
	_check(is_equal_approx(c3, c2), "пауза 2 с: труп стоит (%.3f → %.3f)" % [c2, c3])
	w.set_paused(false)
	await _frames(10)
	_check(float(f.view.get("_corpse_t")) > c3, "после паузы труп снова стареет")
	# выход в меню — бой кончился, мир больше не шагает: труп дотаивает по своим часам
	var cm: float = f.view.get("_corpse_t")
	w.go_to_menu()
	await _frames(30)
	var ce: float = f.view.get("_corpse_t")
	_check(ce > cm + 0.3, "в меню труп дотаивает по своим часам (%.3f → %.3f)" % [cm, ce])
	w.set_process(false)
	Settings.economy_override = ""


## C, verifier-3: НАСТОЯЩАЯ победа наступает внутри _step() (wave_runner.tick →
## on_all_waves_cleared → _end), а тот же шаг потом ещё тикает врагов и трупы (foes[i].tick,
## _cleanup). На 2244b29 они снова брали вид на часы мира после _release_corpses — трупы
## стояли целыми под экраном итога. force_end (тест выше) этого не видел: он зовётся вне шага.
## Второй случай — враг умер в том же шаге, но уже ПОСЛЕ конца боя (спящий не мешает победе,
## добиваем его из match_ended, то есть изнутри того же _step).
func _test_corpse_natural_victory() -> void:
	print("— естественная победа внутри шага: трупы тают под экраном итога")
	w.set_process(false)
	Settings.economy_override = "off"
	CharView.economy_motion = false
	# настоящие волны карты (без no_waves пустой список сразу ставит раннеру DONE), но держим
	# их, пока готовим трупы; потом список волн пуст — следующий tick раннера объявит победу
	w.dev.erase("no_waves")
	w.dev["spawn_units"] = "0"
	w.start_map("fork")
	w.dev["no_waves"] = "1"
	w.wave_runner.held = true
	var f := _kill_foe_at(Vector2(520.0, 420.0))
	var sp := Vector2(700.0, 380.0)
	var sleeper := w.spawn_foe_on_path("zombie", PackedVector2Array([sp, sp + Vector2(-2.0, 0.0)]), sp)
	sleeper.state = Foe.State.SLEEP
	for i in 30:
		w._step(DT)
	_check(w.phase == LegionWorld.Phase.BATTLE and w._corpses.has(f),
		"до победы: бой идёт, труп в _corpses (phase=%d)" % w.phase)
	var kill_late := func(_victory: bool, _stats: Dictionary) -> void:
		sleeper.take_damage(1000.0, sp + Vector2(10.0, 0.0))
	w.match_ended.connect(kill_late, CONNECT_ONE_SHOT)
	w.wave_runner.held = false
	w.wave_runner.waves = []
	w._step(DT)  # волны кончились сами — победа в этом шаге
	_check(w.phase == LegionWorld.Phase.VICTORY, "победа наступила внутри _step (phase=%d)" % w.phase)
	_check(sleeper.state == Foe.State.DEAD, "спящий убит в том же шаге, после конца боя")
	var f0: float = f.view.get("_corpse_t")
	var s0: float = sleeper.view.get("_corpse_t")
	await _frames(120)
	var f1: float = f.view.get("_corpse_t")
	var s1: float = sleeper.view.get("_corpse_t")
	_check(f1 > f0 + 1.5, "труп из боя тает под экраном итога: %.3f → %.3f" % [f0, f1])
	_check(s1 > s0 + 1.5, "труп, убитый после конца боя в том же шаге, тает: %.3f → %.3f" % [s0, s1])
	Settings.economy_override = ""


## D: на 651cf7e экономная → полная в меню заново грузила фоновую жизнь прошлой карты
## (_on_match_started), хотя вход в меню её очистил.
func _test_menu_no_ambient() -> void:
	print("— переключение в меню не грузит фоновую жизнь")
	w.set_process(true)
	Settings.economy_override = "off"
	w.start_map("fork")
	await _frames(5)
	_check(_ambient() > 0, "в бою на «fork» фоновая жизнь есть (%d)" % _ambient())
	w.go_to_menu()
	await _frames(3)
	Settings.economy_override = "on"
	await _frames(3)
	Settings.economy_override = "off"
	await _frames(3)
	_check(w.get_node_or_null("LegionFx") != null, "в меню вернули полную: слой эффектов создан")
	_check(_ambient() == 0, "в меню фоновой жизни нет (излучателей и ореолов: %d)" % _ambient())
	w.start_map("fork")
	await _frames(3)
	_check(_ambient() > 0, "новый бой из меню — фоновая жизнь карты загрузилась (%d)" % _ambient())
	Settings.economy_override = ""
	w.set_process(false)


## Излучатели и ореолы фоновой жизни карты у слоя эффектов; -1 — слоя нет.
func _ambient() -> int:
	var fx := w.get_node_or_null("LegionFx")
	if fx == null:
		return -1
	return (fx.get("_amb_emit") as Array).size() + (fx.get("_amb_glows") as Array).size()


## E: свежий мир, собранный под экономной, — без слоёв; под полной — с ними, на местах master.
func _test_fresh_build_gates() -> void:
	print("— свежий мир собирается по настройке")
	for economy: bool in [true, false]:
		Settings.economy_override = "on" if economy else "off"
		var scene: PackedScene = load(WORLD_SCENE)
		var world := scene.instantiate() as LegionWorld
		root.add_child(world)
		await process_frame
		world.set_process(false)
		var tag := "экономная" if economy else "полная"
		var fx := world.get_node_or_null("LegionFx")
		var shadows := world.get_node_or_null("CharShadows")
		if economy:
			_check(fx == null, "%s: слой эффектов не создан" % tag)
			_check(shadows == null, "%s: слой теней не создан" % tag)
		else:
			_check(fx != null, "%s: слой эффектов создан" % tag)
			_check(shadows != null, "%s: слой теней создан" % tag)
			if fx != null and shadows != null:
				_check(shadows.get_index() + 1 == world.contracts.get_index()
					and fx.get_index() + 1 == world.get_node("Fx").get_index(),
					"%s: тени перед Contracts, эффекты перед Fx" % tag)
		world.queue_free()
		await process_frame
	Settings.economy_override = ""
