extends SceneTree
##
## P5c «Схватки» (docs/dev/PVP_PLAN_0929.md): HUD боя двух сторон.
##  1) одиночка — HUD прежний: панель волн на месте, плашки соперника нет, шрифты подписей мира
##     не тронуты (масштаб вида 1);
##  2) PvP — на экране два HP Котлов (свой и соперника), часы матча; падение HP соперника
##     доходит до плашки;
##  3) PvP — панель волн не закрывает поле (B-302): превью спрятано, плашки — узкая полоса сверху
##     и не лежат на Котлах и героях;
##  4) PvP — подписи мира на экране прежнего размера (B-303): шрифт / масштаб вида;
##  5) PvP — маркер стороны на экране крупнее прежнего (B-304-рядом, кадр P5c);
##  6) PvP — итог матча: «Победа / Поражение / Ничья», причина, «Ещё раз» перезапускает матч,
##     «В меню» возвращает в меню; все причины конца (Котёл, время, сдача, обоюдный).
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_pvp_hud_test.gd -- --mute
##
## Итог «LEGION PVP HUD: N/M OK»; код выхода 1, если что-то упало.
##

const SAVE := "user://legion_pvp_hud_test.cfg"
const DUEL := "pvp:duel"

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


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _start(map_id: String) -> void:
	w.dev = {"no_waves": "1", "spawn_units": "0", "pvp_nobot": "1"}
	w.args.erase("bot")
	w.args.erase("pvp_bots")
	w._base_seed = 7
	w.start_map(map_id)
	await _frames(3)


## Окно (HUD-слой) → прямоугольник экрана мира содержит точку мира?
func _covers(rect: Rect2, world_p: Vector2) -> bool:
	return rect.has_point(w.world_to_screen(world_p))


func _test_single() -> void:
	print("— одиночка: HUD прежний")
	await _start("_gray")
	_check(not w.pvp and w.hud.pvp_plate == null, "PvP выключен, плашки соперника нет")
	_check(w.hud.preview_rect().size.x > 0.0
		and w.hud.preview_rect().position == LegionCfg.WAVE_PREVIEW_POS,
		"панель волн на месте: %s" % w.hud.preview_rect())
	_check(PvpView.fs(w, 20) == 20 and w.contracts._fsz(20) == 20 and w.contracts._core_fs()
		== LegionCfg.CORE_LABEL_SIZE, "шрифты подписей мира прежние (масштаб вида 1)")
	_check(w.hud.panel_rects().size() >= 3, "панели HUD для телеграфа угрозы: %d"
		% w.hud.panel_rects().size())


func _test_two_cauldrons() -> void:
	print("— PvP: два Котла и часы")
	await _start(DUEL)
	var plate := w.hud.pvp_plate
	_check(w.pvp and plate != null and plate.visible, "плашка соперника создана и видна")
	_check(plate != null and plate.rival() == w.sides[1], "соперник — сторона 1")
	_check(plate != null and plate.summary().begins_with(
		"Ваш Котёл %d · Котёл соперника %d" % [ceili(w.cauldron_hp),
		ceili(w.sides[1].cauldron_hp)]), "сводка: %s" % (plate.summary() if plate != null else ""))
	_check(plate != null and plate.summary().ends_with("Осталось %s" % PvpView.clock(
		PvpRules.MATCH_LIMIT - w.now)), "часы — остаток до предела матча %d с"
		% int(PvpRules.MATCH_LIMIT))
	w.sides[1].cauldron_hp = 300.0
	w.cauldron_hp = 450.0
	await _frames(40)
	_check(plate.summary().begins_with("Ваш Котёл 450 · Котёл соперника 300"),
		"падение HP обоих Котлов видно: %s" % plate.summary())
	_check(plate._hp.shown < 400.0, "полоса соперника догоняет HP (%.0f)" % plate._hp.shown)
	_check(w.hud._plate.visible, "плашка своего Котла на месте")


func _test_no_cover() -> void:
	print("— PvP: панель волн не закрывает поле")
	await _start(DUEL)
	_check(w.hud.preview_rect().size == Vector2.ZERO,
		"превью волны спрятано (rect %s)" % w.hud.preview_rect())
	var ok := true
	var top := 0.0
	for r in w.hud.panel_rects():
		if r.position.y < 100.0:
			top = maxf(top, r.end.y)
		for i in 2:
			if _covers(r, w.cauldron_of(i)) or _covers(r, w.sides[i].hero.position):
				ok = false
	_check(ok, "ни одна плашка не лежит на Котле или герое")
	_check(top <= 50.0, "верхние плашки — одна строка, до y=%.0f" % top)
	_check(w.hud.pvp_plate.panel_rect().end.x <= LegionCfg.WORLD_SIZE.x
		and w.hud.pvp_plate.panel_rect().position.x > 800.0,
		"плашка соперника — в правом углу, левее края (%s)" % w.hud.pvp_plate.panel_rect())


func _test_fonts_markers() -> void:
	print("— PvP: подписи и маркеры сторон на ×0,8")
	await _start(DUEL)
	var k := w.view_scale()
	_check(is_equal_approx(k, 0.8), "вид ×0,8")
	for size in [13, 16, 20, 22]:
		var on_screen := float(PvpView.fs(w, size)) * k
		_check(absf(on_screen - float(size)) <= 0.5 * k,
			"шрифт %d → мировой %d → на экране %.1f" % [size, PvpView.fs(w, size), on_screen])
	_check(w.contracts._core_fs() == roundi(float(LegionCfg.CORE_LABEL_SIZE) / k),
		"подпись «наберёт N / мест M»: шрифт поля растёт на 1/масштаб (%d)"
		% w.contracts._core_fs())
	var screen_r := PvpView.marker_radius(w, 7.0) * k
	_check(screen_r >= 9.0, "маркер бойца на экране r=%.1f px (было %.1f)" % [screen_r, 7.0 * k])
	_check(is_equal_approx(PvpView.marker_radius(w, 14.0, 1.0) * k, 14.0),
		"маркер постройки — прежний экранный размер")
	# чужой маркер отличается цветом и формой от своего (CfgFx.MEANING_COLOR side_0/side_1)
	_check(PvpRules.marker_color(0) != PvpRules.marker_color(1)
		and PvpRules.marker_points(Vector2.ZERO, 0, 7.0).size()
		!= PvpRules.marker_points(Vector2.ZERO, 1, 7.0).size(), "своя и чужая сторона: цвет и форма")


func _test_result() -> void:
	print("— PvP: итог матча")
	await _start(DUEL)
	var res := w.hud.pvp_result
	_check(res != null and not res.is_open(), "экран итога создан, пока закрыт")
	w.surrender(1)
	await _frames(2)
	var d := PvpResult.describe(w.pvp_stats())
	_check(res.is_open() and d["title"] == "Победа" and d["reason"] == "Соперник сдался",
		"сдача соперника: %s / %s" % [d["title"], d["reason"]])
	_check(res.button("Ещё раз") != null and res.button("В главное меню") != null, "кнопки итога есть")
	res.button("Ещё раз").pressed.emit()
	await _frames(3)
	_check(not res.is_open() and w.phase == LegionWorld.Phase.BATTLE and w.now < 5.0
		and w.sides[1].cauldron_hp > 0.0, "«Ещё раз»: новый матч (t=%.1f), итог закрыт" % w.now)
	w.surrender(0)
	await _frames(2)
	d = PvpResult.describe(w.pvp_stats())
	_check(res.is_open() and d["title"] == "Поражение" and d["reason"] == "Вы сдались",
		"своя сдача: %s / %s" % [d["title"], d["reason"]])
	res.button("Ещё раз").pressed.emit()
	await _frames(3)
	w.sides[1].cauldron_hp = 0.0
	await _frames(3)
	d = PvpResult.describe(w.pvp_stats())
	_check(res.is_open() and d["title"] == "Победа" and d["reason"] == "Котёл соперника разрушен",
		"Котёл соперника разрушен: %s / %s" % [d["title"], d["reason"]])
	res.button("Ещё раз").pressed.emit()
	await _frames(3)
	w.cauldron_hp = 0.0
	await _frames(3)
	d = PvpResult.describe(w.pvp_stats())
	_check(d["title"] == "Поражение" and d["reason"] == "Ваш Котёл разрушен",
		"свой Котёл разрушен: %s / %s" % [d["title"], d["reason"]])
	res.button("Ещё раз").pressed.emit()
	await _frames(3)
	w.pvp_match.limit = w.now + 0.2
	await _frames(20)
	d = PvpResult.describe(w.pvp_stats())
	_check(res.is_open() and d["title"] == "Ничья" and String(d["reason"]).begins_with("Время вышло"),
		"предел матча, HP равны: %s / %s" % [d["title"], d["reason"]])
	res.button("Ещё раз").pressed.emit()
	await _frames(3)
	w.sides[1].cauldron_hp = 100.0
	w.pvp_match.limit = w.now + 0.2
	await _frames(20)
	d = PvpResult.describe(w.pvp_stats())
	_check(d["title"] == "Победа" and d["reason"] == "Время вышло: у вас больше HP Котла",
		"предел матча по HP: %s / %s" % [d["title"], d["reason"]])
	# HP Котла — из правил PvP (P3 30.09: 600 → 300), не числом в тесте
	var full := "Ваш Котёл: %d" % int(PvpRules.CAULDRON_HP)
	_check((d["lines"] as Array).size() == 3 and String(d["lines"][0]).contains(full),
		"строки итога: %s" % [d["lines"]])
	res.button("В главное меню").pressed.emit()
	await _frames(2)
	_check(w.phase == LegionWorld.Phase.MENU, "«В меню»: мир в меню (фаза %d)" % w.phase)
	# обоюдное разрушение и текст итога без данных — без падения
	var both := PvpResult.describe({"winner": -1, "reason": PvpMatch.REASON_DRAW, "sides": [], "t": 5})
	_check(both["title"] == "Ничья" and both["reason"] == "Оба Котла разрушены одновременно",
		"обоюдное разрушение: %s" % both["reason"])


func _run() -> void:
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	w = scene.instantiate() as LegionWorld
	w.embedded = true
	root.add_child(w)
	await _frames(2)
	await _test_single()
	await _test_two_cauldrons()
	await _test_no_cover()
	await _test_fonts_markers()
	await _test_result()
	await _start("_gray")
	_check(not w.pvp and w.hud.preview_rect().size.x > 0.0 and not w.hud.pvp_plate.visible,
		"одиночка после «Схватки»: панель волн вернулась, плашка соперника скрыта")
	Campaign.reset()
	print("LEGION PVP HUD: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)
