extends SceneTree
##
## Линия economy (27.09, B-085/B-095, D-0927-135…): души в бою получили повторяемую трату —
## «Срочный найм» павших постройки. Проверки: числа из legion_cfg, на которые завязан замер
## серии; найм (цена, места павших, а не новые; Котёл не нанимает; нехватка душ; вложение
## не растёт); кнопка меню площадки; решение бота (резерв на плановую покупку, no_rush).
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_economy_test.gd -- --mute
##
## Итог «LEGION ECONOMY: N/M OK»; код выхода 1, если что-то упало. Мир настоящий (карта
## _plots, волны выключены), штат тикается напрямую, сохранение — во временном файле.
##

const SAVE := "user://legion_economy_test.cfg"
const MAP := "_plots"
const DT := 0.01

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
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	w = scene.instantiate() as LegionWorld
	root.add_child(w)
	await process_frame
	w.set_process(false)
	_test_cfg()
	_test_rush()
	_test_rush_fresh_and_cauldron()
	await _test_menu()
	_test_bot()
	Campaign.reset()
	print("LEGION ECONOMY: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


func _fresh() -> void:
	w.dev["no_waves"] = "1"
	w.dev["spawn_units"] = "0"
	w.dev.erase("no_rush")
	w.start_map(MAP)
	w.dev_invuln = false


func _tick(seconds: float) -> void:
	for i in roundi(seconds / DT):
		w.now += DT
		w.staff.tick(DT)
		w._cleanup(DT)


func _home_units(b: LegionBuilding) -> Array[Legionnaire]:
	var out: Array[Legionnaire] = []
	for u in w.units:
		if u.alive and u.home == b:
			out.append(u)
	return out


## Бытовка на первой площадке, штат полный.
func _barracks() -> LegionBuilding:
	w.souls = 1000
	var b := w.staff.build(w.staff.plots[0], LegionCfg.KIND_LABORER)
	_tick(float(b.cap) * LegionCfg.STAFF_FILL_STEP + 1.0)
	return b


func _kill(b: LegionBuilding, n: int) -> void:
	var squad := _home_units(b)
	for i in n:
		squad[i].take_damage(1000.0, squad[i].position)
	_tick(0.1)


func _test_cfg() -> void:
	# замер серии (docs/dev/BALANCE.md, строка линии economy) сделан на этих числах
	_check(LegionCfg.RUSH_HIRE_PRICE == {LegionCfg.KIND_LABORER: 4, LegionCfg.KIND_GUARD: 6,
		LegionCfg.KIND_CLERK: 6}, "цена срочного найма 4 / 6 / 6 душ за бойца")
	_check(LegionCfg.BOT_RUSH_FRAC == 0.4 and LegionCfg.BOT_RUSH_MIN == 3,
		"бот нанимает, когда ждут ≥ 40 % штата и ≥ 3 мест")
	_check(LegionCfg.SOULS_START == 60 and LegionCfg.SOULS_WAVE == 15
		and int(LegionCfg.SOULS_PER_FOE["zombie"]) == 3,
		"доход душами прежний: старт 60, волна 15, зомби 3")
	_check(LegionCfg.MANA_MAX == 100.0 and LegionCfg.MANA_REGEN == 10.0
		and LegionCfg.MANA_PER_PX == 0.12, "мана: 100, 10/с, прежние 0,12 за px")


func _test_rush() -> void:
	_fresh()
	var st := w.staff
	var b := _barracks()
	_check(b.alive_count() == b.cap and b.waiting_count() == 0 and st.rush_price(b) == 0,
		"полный штат — нанимать некого, цена 0")
	_kill(b, 4)
	_check(b.waiting_count() == 4 and st.rush_price(b) == 16,
		"4 павших ждут возрождения — найм 4 × 4 = 16 душ")
	w.souls = 10
	_check(st.rush(b) == 0 and w.souls == 10 and b.alive_count() == b.cap - 4,
		"не хватает душ — найма нет, души целы")
	w.souls = 100
	var invested := b.invested
	var sell := LegionStaff.sell_value(b)
	_check(st.rush(b) == 4 and w.souls == 84 and b.alive_count() == b.cap
		and b.waiting_count() == 0, "найм: 4 бойца сразу, −16 душ, штат полный")
	_check(b.invested == invested and LegionStaff.sell_value(b) == sell,
		"найм — расход: вложение и цена продажи не растут")
	_check(int(w.stats.get("rush_souls", 0)) == 16 and int(w.stats.get("rush_units", 0)) == 4,
		"счёт найма в итоге боя (rush_souls, rush_units)")


func _test_rush_fresh_and_cauldron() -> void:
	_fresh()
	var st := w.staff
	var b := _barracks()
	_kill(b, 2)
	w.souls = 1000
	st.upgrade(b)
	# новые места после улучшения заполнятся сами — за них не платят
	_check(b.waiting_count() == 2 and st.rush_price(b) == 8,
		"после улучшения в цене только павшие (2 × 4), не новые места")
	_check(st.rush_price(st.cauldron) == 0 and st.rush(st.cauldron) == 0,
		"Котёл срочным наймом не нанимает (у него нет меню площадки)")


func _test_menu() -> void:
	_fresh()
	var st := w.staff
	var m := w.plot_menu
	var b := _barracks()
	_kill(b, 3)
	w.souls = 5
	m.open(st.plots[0], st.plots[0]["pos"])
	var btn := _rush_button()
	_check(btn != null and btn.text.contains("· 3 — 12 душ") and btn.disabled,
		"меню: «Срочный найм · 3 — 12 душ», закрыто при 5 душах")
	w.souls = 50
	w.souls_changed.emit(w.souls)
	_check(btn != null and not btn.disabled, "душ хватило — кнопка открылась")
	_kill(b, 1)
	await process_frame
	btn = _rush_button()
	_check(btn != null and btn.text.contains("· 4 — 16 душ"),
		"новый павший при открытом меню — цена на кнопке обновилась")
	if btn != null:
		btn.pressed.emit()
	_check(not m.is_open() and b.alive_count() == b.cap and w.souls == 34,
		"кнопка нанимает (−16) и закрывает меню")


func _rush_button() -> Button:
	for btn in w.plot_menu.buttons():
		if btn.text.begins_with("Срочный найм"):
			return btn
	return null


func _test_bot() -> void:
	_fresh()
	var b := _barracks()
	var need := maxi(LegionCfg.BOT_RUSH_MIN, ceili(b.cap * LegionCfg.BOT_RUSH_FRAC))
	_kill(b, need - 1)
	w.souls = 1000
	_check(not LegionStaff.bot_rush(w), "бот: павших меньше порога — не нанимает")
	_kill(b, 1)
	var price := need * LegionCfg.RUSH_HIRE_PRICE[LegionCfg.KIND_LABORER]
	# резерв — самая дорогая плановая покупка: пустые площадки есть, вне кампании открыты все
	# виды — Проходная/Бухгалтерия 60; улучшение Бытовки — тоже 60
	var reserve := 60
	_check(LegionStaff.build_price(LegionCfg.KIND_GUARD) == reserve
		and LegionStaff.upgrade_price(b) == reserve and w.staff.kind_unlocked(LegionCfg.KIND_GUARD),
		"бот: резерв на самую дорогую плановую покупку — 60")
	w.souls = price + reserve - 1
	_check(not LegionStaff.bot_rush(w) and b.waiting_count() == need,
		"бот: после найма не хватит на самую дорогую плановую покупку — копит")
	# та же проверка, что сломала бы прежний резерв «на самую дешёвую» (Бытовка, 40)
	w.souls = price + LegionStaff.build_price(LegionCfg.KIND_LABORER)
	_check(not LegionStaff.bot_rush(w), "бот: резерва на Бытовку (40) мало — найм не проедает стройку")
	w.dev["no_rush"] = "1"
	w.souls = price + reserve
	_check(not LegionStaff.bot_rush(w), "бот: --dev no_rush=1 — без найма")
	w.dev.erase("no_rush")
	_check(LegionStaff.bot_rush(w) and w.souls == reserve and b.waiting_count() == 0,
		"бот: хватает на найм и резерв — нанимает")
