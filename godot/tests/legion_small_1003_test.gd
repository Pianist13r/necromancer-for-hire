extends SceneTree
##
## Регресс мелких правок 03.10.2026 (ветка slow/small-1003).
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_small_1003_test.gd -- --mute
##
## B-386 (1): реплика, НАЧАТАЯ на паузе, стартует приостановленной (stream_paused переносится на
##            новое воспроизведение) и «занят до» сдвигается только на паузу после её старта;
## B-390 (1): подсказка и всплывашка фигуры у верхнего края не ложатся на настоящие панели HUD
##            (в т.ч. правую «Вызвать»), а не на полосу 64 px;
## B-390 (2): «Обряд начат — набери строй» и совет «строй набран» не лежат друг на друге, если
##            строй набран сразу: совет ждёт, пока всплывашка погаснет;
## B-390 (3): Crypt._teaches() мерит до Котла человека за этим экраном, а не стороны 0;
## B-390 (4): табличка склепа «Болота» не лежит на площадках под постройку.
## Итог «LEGION SMALL 1003: N/M OK»; код выхода 1, если что-то упало. Сохранение временное.
##

const SAVE := "user://legion_small_1003_test.cfg"
const FC := Vector2(1130.0, 405.0)

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


func _run() -> void:
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	await _test_voice_started_on_pause()
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	w = scene.instantiate() as LegionWorld
	root.add_child(w)
	await _frames(2)
	w.set_process(false)
	Settings.hints_override = "on"
	await _test_hint_vs_panels()
	_test_popup_then_hint()
	await _test_crypts()
	Settings.hints_override = ""
	Settings.scheme_override = ""
	Campaign.reset()
	print("LEGION SMALL 1003: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


# ── B-386 (1) ─────────────────────────────────────────────────────────────────

func _test_voice_started_on_pause() -> void:
	print("— B-386 (1): реплика, начатая на паузе")
	var a := LegionAudio.new()
	a.process_mode = Node.PROCESS_MODE_ALWAYS   # как под миром одиночки
	root.add_child(a)
	a.setup_standalone(false, false)   # не mute: плеер реально играет (dummy-драйвер)
	await _frames(2)
	paused = true
	await _frames(3)
	a.voice(&"lg_intro_1", 5, LegionAudio.VoiceClass.SCENE)   # ~11 с, начата НА паузе
	var started: int = Time.get_ticks_msec()
	var until_start: int = a._voice_busy_until_msec
	await _frames(2)
	_check(a._voice_player.stream_paused, "флаг stream_paused на плеере стоит")
	OS.delay_msec(500)
	await _frames(3)
	var pos := a._voice_player.get_playback_position()
	_check(pos < 0.2, "на паузе новая реплика не продвинулась (позиция %.2f с)" % pos)
	paused = false
	await _frames(3)
	_check(not a._voice_player.stream_paused, "после паузы плеер идёт")
	var shift: int = a._voice_busy_until_msec - until_start
	var held: int = Time.get_ticks_msec() - started
	_check(shift >= 480 and shift <= held + 40,
		"«занят до» сдвинут на паузу после старта реплики (+%d мс, пауза %d мс)" % [shift, held])
	a.queue_free()
	await _frames(1)


# ── B-390 (1) ─────────────────────────────────────────────────────────────────

func _fresh() -> void:
	Settings.scheme_override = Settings.SCHEME_SLING
	Campaign.reset()
	w.in_campaign = false
	w.dev = {"no_waves": "1", "spawn_units": "0"}
	w.start_map("_gray")
	w.dev_invuln = false
	w.contracts.mana = w.contracts.mana_max


func _fig(fig: StringName, r: float, at: Vector2) -> Contract:
	var pts := LegionLessonBot.template(String(fig), at, r)
	var n := w.contracts.contracts.size()
	w.contracts.call("_create", pts, 1, LegionCfg.KIND_LABORER, false, fig)
	if w.contracts.contracts.size() == n:
		return null
	var c: Contract = w.contracts.contracts[n]
	return c if c.figure == fig else null


func _man(c: Contract) -> void:
	for p in c.posts:
		if p["unit"] == null and not p["dead"]:
			var u := w.spawn_unit(c.kind, p["pos"])
			u.assign(c, p)
			u._arrive()


func _test_hint_vs_panels() -> void:
	print("— B-390 (1): место сверху — по настоящим панелям HUD")
	_fresh()
	await _frames(3)
	var panels := w.hud_world_rects()
	_check(panels.size() >= 3, "панели HUD видны (%d)" % panels.size())
	var preview := w.hud.preview_rect()
	_check(preview.has_area(), "панель «Вызвать» на экране: %s" % preview)
	if not preview.has_area():
		return
	var pw := w.screen_to_world(preview.position)
	var pe := w.screen_to_world(preview.end)
	var worst_hint := 0
	var worst_pop := 0
	var tried := 0
	# строй у верхнего правого угла: верх фигуры по очереди на разной высоте под/у нижнего края панели
	for cy in range(int(pe.y) + 10, int(pe.y) + 110, 8):
		_fresh()
		var c := _fig(&"triangle", 60.0, Vector2((pw.x + pe.x) * 0.5, float(cy)))
		if c == null:
			continue
		tried += 1
		_man(c)
		var rects := w.hud_world_rects()
		# совет: прямоугольник подписи в обоих концах всплытия (k = 0 и 1)
		for k in [0.0, 1.0]:
			var at: Vector2 = w.intuit.fig_hint_pos(c) + Vector2(
				0.0, -IntuitCfg.HINT_UP - IntuitCfg.HINT_RISE * k)
			var tr: Rect2 = w.intuit.call("_text_rect", at, IntuitCfg.HINT_RITE,
				PvpView.fs(w, IntuitCfg.HINT_SIZE), true)
			for r in rects:
				if r.intersects(tr):
					worst_hint += 1
		# всплывашка имени: прямоугольник в начале жизни (кегль ×POPUP_POP, подъём 0 и RISE)
		var psz := roundi(ContractField.POPUP_POP * float(w.contracts.call("_fsz", 30)))
		var text := FigureCfg.RITE_BEGUN_LABEL
		var tw := UiStyle.FONT_TITLE.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, psz).x
		var pp := w.contracts.fig_popup_pos(c)
		for rise in [0.0, ContractField.POPUP_RISE]:
			var base: float = pp.y - ContractField.POPUP_LIFT - rise
			var pr := Rect2(pp.x - tw * 0.5, base - psz, tw, psz + 4.0)
			for r in rects:
				if r.intersects(pr):
					worst_pop += 1
	_check(tried >= 8, "построено фигур для проверки: %d" % tried)
	_check(worst_hint == 0, "подсказка «Обряд» не задевает панели (пересечений %d)" % worst_hint)
	_check(worst_pop == 0, "всплывашка имени не задевает панели (пересечений %d)" % worst_pop)


# ── B-390 (2) ─────────────────────────────────────────────────────────────────

func _test_popup_then_hint() -> void:
	print("— B-390 (2): «Обряд начат» и совет «строй набран» не друг на друге")
	_fresh()
	var c := _fig(&"triangle", 80.0, FC)
	_check(c != null, "треугольник собран")
	if c == null:
		return
	_man(c)   # строй набран сразу
	w.contracts.call("_on_figure_made", c)
	_check(w.contracts.fig_popup_alive(c), "всплывашка «Обряд начат» на поле")
	w.intuit.scan()
	_check(w.intuit.label_rect(&"rite") == Rect2(),
		"пока всплывашка видна, совета «строй набран» нет")
	# Кадр боя — это И шаг мира, И real_tick (legion_world зовёт tick в _step, real_tick в
	# _process): всплывашку гасит только real_tick, а заряд фигуры копит только tick. Кадров
	# хватает на оба порога: PERFECT_POPUP_TIME 0,9 с и CHARGE_TIME 1,5 с (совет — заряженному).
	for i in int(FigureCfg.CHARGE_TIME / (1.0 / 60.0)) + 6:
		w._step(1.0 / 60.0)
		w.contracts.real_tick(1.0 / 60.0)
	_check(not w.contracts.fig_popup_alive(c), "всплывашка погасла")
	w.intuit.scan()
	_check(w.intuit.label_rect(&"rite").has_area(), "после неё совет «строй набран» появился")


# ── B-390 (3), (4) ────────────────────────────────────────────────────────────

func _test_crypts() -> void:
	print("— B-390 (3): «учит» склеп, ближний к Котлу человека")
	Campaign.reset()
	w.in_campaign = false
	w.dev = {"no_waves": "1"}
	w.args["bot"] = "off"
	w.start_map("pvp:duel")
	await _frames(3)
	_check(w.sides.size() == 2, "«Схватка»: две стороны (%d)" % w.sides.size())
	if w.sides.size() == 2:
		var home0 := w.cauldron_of(0)
		var home1 := w.cauldron_of(1)
		var near0 := _crypt_at(home0.lerp(home1, 0.3))
		var near1 := _crypt_at(home0.lerp(home1, 0.7))
		w.local_side = 0
		_check(near0.call("_teaches") and not near1.call("_teaches"),
			"человек слева: учит склеп у его Котла")
		w.local_side = 1
		_check(near1.call("_teaches") and not near0.call("_teaches"),
			"человек справа: учит склеп у ЕГО Котла (%s / %s)"
			% [near1.call("_teaches"), near0.call("_teaches")])
		w.local_side = 0
		for c in [near0, near1]:
			w.crypts.erase(c)
			c.queue_free()
	print("— B-390 (4): табличка склепа не на площадке")
	Campaign.reset()
	w.in_campaign = false
	w.dev = {"no_waves": "1"}
	w.args["bot"] = "off"
	w.start_map("swamp")
	await _frames(3)
	for c in w.crypts:
		c.nearby_units = 0
		_check_chip_off_plots(c, "склеп у %s (%s)" % [c.position, c.label_text()])
	# длинная табличка верхнего склепа: сажаем склеп так, чтобы она лежала прямо на площадке
	var plots := w.plot_rects()
	_check(not plots.is_empty(), "на «Болоте» есть площадки (%d)" % plots.size())
	if plots.is_empty():
		return
	var c0: LegionCrypt = w.crypts[0]
	c0.allegiance = LegionCrypt.Owner.NEUTRAL
	var p0: Rect2 = plots[0]
	c0.position = Vector2(p0.get_center().x, p0.get_center().y - LegionCfg.CRYPT_LABEL_Y)
	_check_chip_off_plots(c0, "склеп над площадкой %s" % p0)


func _check_chip_off_plots(c: LegionCrypt, what: String) -> void:
	var chip: Rect2 = c.label_rect()
	chip.position += c.position
	var hit := Rect2()
	for r in w.plot_rects():
		if r.intersects(chip):
			hit = r
	_check(not hit.has_area(), "%s: табличка %s мимо площадок%s" % [what, chip,
		"" if not hit.has_area() else " (лежит на %s)" % hit])


func _crypt_at(p: Vector2) -> LegionCrypt:
	var c := LegionCrypt.new()
	c.setup(w, p)
	w.entities.add_child(c)
	w.crypts.append(c)
	return c
