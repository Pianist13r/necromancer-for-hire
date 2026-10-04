extends SceneTree
##
## Самопроверка рогатки v17 (DESIGN_V17 §2, поток CTL) НАСТОЯЩИМИ событиями ввода:
## Input.parse_input_event в координатах окна — тот же путь, что у мыши ОС (viewport →
## _unhandled_input поля договоров, затем мира), поэтому проверяется и порядок перехвата Esc.
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_sling_test.gd -- --mute
##
## Итог «LEGION SLING: N/M OK»; код выхода 1, если что-то упало. Схему управления тест
## переключает ТОЛЬКО в памяти (Settings.scheme_override) — user://settings.cfg владельца не
## пишется (проверка в конце: файла не было — не появился, был — mtime тот же). Сохранение
## кампании — во временный файл.
##

const SAVE := "user://legion_sling_test.cfg"
## Полоса карты _gray между рекой (x 620–706) и скалой (x 870+), вдали от Котла.
const LAB := Vector2(760, 120)
const DEVICE := 7
const FPS := 60.0

var w: LegionWorld
var _fails := 0
var _checks := 0
var _settings_existed := false
var _settings_mtime := 0


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


func _line(a: Vector2, b: Vector2, step := 8.0) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var n := maxi(1, ceili(a.distance_to(b) / step))
	for i in n + 1:
		pts.append(a.lerp(b, float(i) / n))
	return pts


# ── Настоящие события ввода ──────────────────────────────────────────────────

func _screen(p: Vector2) -> Vector2:
	return root.get_final_transform() * p


func _move(p: Vector2, mask: int = MOUSE_BUTTON_MASK_RIGHT) -> void:
	var ev := InputEventMouseMotion.new()
	ev.device = DEVICE
	ev.position = _screen(p)
	ev.global_position = ev.position
	ev.button_mask = mask
	Input.parse_input_event(ev)
	await _frames(1)


func _button(p: Vector2, button: MouseButton, pressed: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.device = DEVICE
	ev.position = _screen(p)
	ev.global_position = ev.position
	ev.button_index = button
	ev.pressed = pressed
	var bit := MOUSE_BUTTON_MASK_LEFT if button == MOUSE_BUTTON_LEFT else MOUSE_BUTTON_MASK_RIGHT
	ev.button_mask = bit if pressed else 0
	Input.parse_input_event(ev)
	await _frames(1)


func _esc() -> void:
	for pressed: bool in [true, false]:
		var ev := InputEventKey.new()
		ev.device = DEVICE
		ev.keycode = KEY_ESCAPE
		ev.physical_keycode = KEY_ESCAPE
		ev.pressed = pressed
		Input.parse_input_event(ev)
		await _frames(1)


## Натяжка рукой: ПКМ в from, ведём по кадру к to, НЕ отпускаем.
func _pull(from: Vector2, to: Vector2, steps := 8) -> void:
	await _move(from, 0)
	await _button(from, MOUSE_BUTTON_RIGHT, true)
	for i in range(1, steps + 1):
		await _move(from.lerp(to, float(i) / steps))


# ── Мир ──────────────────────────────────────────────────────────────────────

func _fresh(scheme: String) -> void:
	Settings.scheme_override = scheme
	w.dev["no_waves"] = "1"
	w.dev["spawn_units"] = "0"
	w.start_map("_gray")
	w.dev_invuln = false
	w.contracts.mana = w.contracts.mana_max


func _man(c: Contract) -> Array[Legionnaire]:
	var out: Array[Legionnaire] = []
	for p in c.posts:
		if p["unit"] != null or p["dead"]:
			continue
		var u := w.spawn_unit(c.kind, p["pos"])
		u.assign(c, p)
		u._arrive()
		out.append(u)
	return out


func _seg_units(squad: Array[Legionnaire], seg: int) -> Array[Legionnaire]:
	var out: Array[Legionnaire] = []
	for u in squad:
		if u.state == Legionnaire.State.POSTED and int(u.post["seg"]) == seg:
			out.append(u)
	return out


func _still_foe(at: Vector2) -> Foe:
	var f := w.spawn_foe_on_path("zombie", PackedVector2Array([at]), at)
	f.speed = 0.0
	f.hp = 100000.0
	f.max_hp = f.hp
	return f


## Договор-столбик в лаборатории: два участка по 64 px, стрелка по умолчанию — от Котла (+x).
func _column(y0: float) -> Contract:
	return w.contracts.add_contract(_line(LAB + Vector2(0, y0), LAB + Vector2(0, y0 + 128)), 1, false)


func _run() -> void:
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	_settings_existed = FileAccess.file_exists(Settings.PATH)
	if _settings_existed:
		_settings_mtime = FileAccess.get_modified_time(Settings.PATH)
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	w = scene.instantiate() as LegionWorld
	root.add_child(w)
	await _frames(2)
	await _test_click()
	await _test_sling_aim()
	await _test_cancel()
	await _test_stale_grab()
	await _test_classic()
	await _test_delay()
	await _test_combo()
	await _test_perfect()
	_check(FileAccess.file_exists(Settings.PATH) == _settings_existed
		and (not _settings_existed or FileAccess.get_modified_time(Settings.PATH) == _settings_mtime),
		"user://settings.cfg не тронут (был: %s)" % _settings_existed)
	Settings.scheme_override = ""
	Campaign.reset()
	print("LEGION SLING: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


## Щелчок ПКМ без натяжки = прежний роспуск: стрелка договора, сила 1.0 (множители 1/1/1).
func _test_click() -> void:
	_fresh(Settings.SCHEME_SLING)
	var c := _column(0)
	var squad := _man(c)
	var seg0 := _seg_units(squad, 0)
	var at := c.seg_center(0)
	await _move(at, 0)
	await _button(at, MOUSE_BUTTON_RIGHT, true)
	_check(c.seg_alive(0), "рогатка: нажатие ПКМ ещё не распускает (ждём отпускания)")
	await _move(at + Vector2(3, 2))   # дрожь руки меньше TAP_SLOP
	await _button(at + Vector2(3, 2), MOUSE_BUTTON_RIGHT, false)
	_check(not c.seg_alive(0) and c.seg_alive(1), "щелчок ПКМ распустил ровно участок 0")
	var ok := not seg0.is_empty()
	for u in seg0:
		ok = ok and u.state == Legionnaire.State.CHARGE and u._charge_dir.is_equal_approx(c.dir) \
			and is_equal_approx(float(u._volley["range"]), 1.0) \
			and is_equal_approx(float(u._volley["dmg"]), 1.0) \
			and is_equal_approx(float(u._volley["speed"]), 1.0) \
			and not bool(u._volley["perfect"])
	_check(ok, "щелчок: натиск по стрелке договора, множители 1.0/1.0/1.0 (%d бойцов)" % seg0.size())
	_check(not seg0.is_empty() and seg0[0]._charge_t > LegionCfg.CHARGE_TIME - 0.1
		and seg0[0]._charge_t <= LegionCfg.CHARGE_TIME, "щелчок: время натиска прежнее")
	_check(int(w.stats.get("sling_releases", 0)) == 0 and int(w.stats["releases_manual"]) == 1,
		"щелчок считается прежним ручным выпуском, не рогаткой")


## Натяжка назад: стрелка противоположна оттяжке, сила полная (26.09: длина оттяжки не важна,
## подробно — legion_sling_easy_test), мир замедлен; срыв по ней.
func _test_sling_aim() -> void:
	_fresh(Settings.SCHEME_SLING)
	var c := _column(0)
	var squad := _man(c)
	var seg1 := _seg_units(squad, 1)
	var at := c.seg_center(1)
	var pull := Vector2(-60, 45)      # назад-вниз, |pull| = 75
	await _pull(at, at + pull)
	var f := w.contracts
	_check(f.is_slinging(), "сдвиг >= SLING_ARM — натяжка")
	var aim := f.sling_aim()
	var want_dir := -pull.normalized()
	var want_t := 1.0
	_check((aim["dir"] as Vector2).is_equal_approx(want_dir),
		"стрелка противоположна оттяжке (%s)" % aim["dir"])
	_check(absf(float(aim["power"]) - want_t) < 0.01,
		"сила полная: %.3f (ждали %.3f)" % [float(aim["power"]), want_t])
	# Отсрочка: мир идёт ×DELAY_SLOW, пока натяжка
	var t0 := w.now
	await _frames(12)
	var ratio := (w.now - t0) / (12.0 / FPS)
	_check(absf(ratio - LegionCfg.DELAY_SLOW) < 0.05, "натяжка: мир идёт ×%.2f" % ratio)
	_check(c.seg_alive(1), "пока держим — участок жив")
	await _button(at + pull, MOUSE_BUTTON_RIGHT, false)
	_check(not c.seg_alive(1) and c.seg_alive(0), "отпустил — сорвался ровно участок 1")
	var ok := not seg1.is_empty()
	for u in seg1:
		ok = ok and u.state == Legionnaire.State.CHARGE and u._charge_dir.is_equal_approx(want_dir) \
			and absf(float(u._volley["power"]) - want_t) < 0.01 \
			and is_equal_approx(float(u._volley["range"]), lerpf(LegionCfg.SLING_RANGE.x,
				LegionCfg.SLING_RANGE.y, float(u._volley["power"]))) \
			and is_equal_approx(float(u._volley["dmg"]), lerpf(LegionCfg.SLING_DMG.x,
				LegionCfg.SLING_DMG.y, float(u._volley["power"])))
	_check(ok, "бойцы участка бегут по стрелке рогатки с её силой (%d)" % seg1.size())
	_check(int(w.stats.get("sling_releases", 0)) == 1, "срыв рогаткой посчитан")
	t0 = w.now
	await _frames(12)
	_check(absf((w.now - t0) / (12.0 / FPS) - 1.0) < 0.05, "после срыва мир снова ×1")


## Esc и ЛКМ во время натяжки — отмена: ничего не распущено, пауза не включилась, штрих не начат.
func _test_cancel() -> void:
	_fresh(Settings.SCHEME_SLING)
	var c := _column(0)
	_man(c)
	var at := c.seg_center(0)
	await _pull(at, at + Vector2(-50, 0))
	_check(w.contracts.is_slinging(), "натяжка перед Esc")
	await _esc()
	_check(not w.contracts.is_slinging() and not w.paused, "Esc отменил натяжку, паузы нет")
	await _button(at + Vector2(-50, 0), MOUSE_BUTTON_RIGHT, false)
	_check(c.seg_alive(0) and int(w.stats["releases"]) == 0, "после Esc отпускание ПКМ ничего не делает")
	await _pull(at, at + Vector2(-70, 10))
	await _button(at + Vector2(-70, 10), MOUSE_BUTTON_LEFT, true)
	_check(not w.contracts.is_slinging() and not w.contracts.has_draft(),
		"ЛКМ во время натяжки — отмена, штрих не начат")
	await _button(at + Vector2(-70, 10), MOUSE_BUTTON_LEFT, false)
	await _button(at + Vector2(-70, 10), MOUSE_BUTTON_RIGHT, false)
	_check(c.seg_alive(0) and int(w.stats["releases"]) == 0, "после ЛКМ участок жив")
	# пауза кнопкой посреди натяжки — натяжка снята (отпускание ПКМ на паузе не дойдёт)
	await _pull(at, at + Vector2(-60, 0))
	w.set_paused(true)
	_check(not w.contracts.is_slinging(), "пауза посреди натяжки снимает её")
	w.set_paused(false)
	await _button(at + Vector2(-60, 0), MOUSE_BUTTON_RIGHT, false)
	_check(c.seg_alive(0), "после паузы участок жив")
	# Esc без натяжки — снова пауза, как раньше
	await _esc()
	_check(w.paused, "Esc вне натяжки — пауза, как раньше")
	await _esc()
	_check(not w.paused, "Esc снимает паузу")


## Находки verifier v17: (1) отпускание ПКМ потерялось (Alt+Tab с зажатой кнопкой) — следующий
## щелчок ПКМ мимо участков не должен срывать старый захват; потеря фокуса снимает захват;
## (2) переключатель схемы в настройках действует сразу, посреди карты.
func _test_stale_grab() -> void:
	_fresh(Settings.SCHEME_SLING)
	var c := _column(0)
	_man(c)
	var at := c.seg_center(0)
	await _pull(at, at + Vector2(-90, 0))
	_check(w.contracts.is_slinging(), "натяжка перед потерей отпускания")
	# отпускание не пришло; через время — щелчок ПКМ по пустому месту
	var empty := LAB + Vector2(-200, 300)
	await _move(empty, 0)
	await _button(empty, MOUSE_BUTTON_RIGHT, true)
	await _button(empty, MOUSE_BUTTON_RIGHT, false)
	_check(c.seg_alive(0) and int(w.stats["releases"]) == 0,
		"щелчок ПКМ мимо после потерянного отпускания не срывает старый участок")
	await _pull(at, at + Vector2(-60, 0))
	w.contracts.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	_check(not w.contracts.is_slinging(), "потеря фокуса окна снимает натяжку")
	await _button(at + Vector2(-60, 0), MOUSE_BUTTON_RIGHT, false)
	_check(c.seg_alive(0), "после потери фокуса участок жив")
	# схема сменилась посреди карты (как из настроек на паузе) — действует со следующего нажатия
	Settings.scheme_override = Settings.SCHEME_CLASSIC
	await _move(at, 0)
	await _button(at, MOUSE_BUTTON_RIGHT, true)
	_check(not c.seg_alive(0), "смена схемы на классику посреди карты действует сразу")
	await _button(at, MOUSE_BUTTON_RIGHT, false)
	Settings.scheme_override = Settings.SCHEME_SLING


## Классика: ПКМ распускает по нажатию, натяжки и замедления нет, стрелка — договора.
func _test_classic() -> void:
	_fresh(Settings.SCHEME_CLASSIC)
	var c := _column(0)
	var squad := _man(c)
	var seg0 := _seg_units(squad, 0)
	var at := c.seg_center(0)
	await _move(at, 0)
	await _button(at, MOUSE_BUTTON_RIGHT, true)
	_check(not c.seg_alive(0), "классика: ПКМ распускает по нажатию")
	var t0 := w.now
	for i in range(1, 9):
		await _move(at + Vector2(-80, 0) * (i / 8.0))
	_check(not w.contracts.is_slinging() and absf((w.now - t0) / (8.0 / FPS) - 1.0) < 0.05,
		"классика: протяжка с ПКМ — не натяжка, мир ×1")
	await _button(at + Vector2(-80, 0), MOUSE_BUTTON_RIGHT, false)
	var ok := not seg0.is_empty()
	for u in seg0:
		ok = ok and u._charge_dir.is_equal_approx(c.dir) and is_equal_approx(float(u._volley["range"]), 1.0)
	_check(ok, "классика: натиск по стрелке договора с прежней силой")
	_check(c.seg_alive(1) and int(w.stats.get("sling_releases", 0)) == 0,
		"классика: отпускание ПКМ ничего не срывает")


## Отсрочка: тратится DELAY_DRAIN/с реального времени натяжки, копится DELAY_REGEN/с;
## пустая — натяжка без замедления.
func _test_delay() -> void:
	_fresh(Settings.SCHEME_SLING)
	var c := _column(0)
	_man(c)
	var f := w.contracts
	_check(is_equal_approx(f.delay, LegionCfg.DELAY_MAX), "Отсрочка полная на старте карты")
	var at := c.seg_center(0)
	await _pull(at, at + Vector2(-60, 0), 4)
	var d0 := f.delay
	await _frames(30)
	var spent := d0 - f.delay
	_check(absf(spent - LegionCfg.DELAY_DRAIN * 30.0 / FPS) < 1.5,
		"за 0,5 с натяжки ушло %.1f (ждали %.1f)" % [spent, LegionCfg.DELAY_DRAIN * 0.5])
	var gauge := w.hud.get_node_or_null("DelayGauge") as DelayGauge
	_check(gauge != null and gauge.shown(), "шкала Отсрочки видна во время натяжки")
	await _esc()
	d0 = f.delay
	await _frames(60)
	_check(absf(f.delay - d0 - LegionCfg.DELAY_REGEN) < 1.5,
		"за 1 с без натяжки накопилось %.1f (ждали %.1f)" % [f.delay - d0, LegionCfg.DELAY_REGEN])
	f.delay = 0.3
	await _pull(at, at + Vector2(-60, 0), 4)
	await _frames(2)
	var t0 := w.now
	await _frames(12)
	_check(f.delay == 0.0 and absf((w.now - t0) / (12.0 / FPS) - 1.0) < 0.05,
		"пустая Отсрочка — натяжка без замедления")
	await _esc()
	await _button(at + Vector2(-60, 0), MOUSE_BUTTON_RIGHT, false)


## Комбо: натиск игрока, задевший врага в пределах COMBO_WINDOW от прошлого, — +1; впустую — сброс;
## окно истекло — сброс. Множитель 1 + 0.1·(комбо − 1), счётчик на HUD.
func _test_combo() -> void:
	_fresh(Settings.SCHEME_SLING)
	var c := _column(0)
	var c2 := _column(300)
	var squad := _man(c)
	squad.append_array(_man(c2))
	var meter := w.hud.get_node_or_null("ComboMeter") as ComboMeter
	_check(meter != null, "счётчик комбо висит на HUD")
	for i in 3:
		var cc := c if i < 2 else c2
		var seg := i % 2
		_still_foe(cc.seg_center(seg) + cc.dir * 40.0)
		var at := cc.seg_center(seg)
		await _move(at, 0)
		await _button(at, MOUSE_BUTTON_RIGHT, true)
		await _button(at, MOUSE_BUTTON_RIGHT, false)
		await _frames(40)
	_check(w.combo == 3, "три задевших натиска подряд — комбо 3 (%d)" % w.combo)
	# 29.09 (D-0929-01) COMBO_STEP 0,1 → 0,15: ждём 1 + 2 шага из конфига, а не прежние ×1,2
	var combo3 := 1.0 + LegionCfg.COMBO_STEP * 2.0
	_check(is_equal_approx(w.combo_mult(), combo3),
		"множитель комбо 3 = ×%.2f (%.2f)" % [combo3, w.combo_mult()])
	_check(meter != null and meter.shown_combo() == 3, "HUD: «Комбо ×3»")
	# натиск впустую — сброс
	var at2 := c2.seg_center(1)
	await _move(at2, 0)
	await _button(at2, MOUSE_BUTTON_RIGHT, true)
	await _button(at2, MOUSE_BUTTON_RIGHT, false)
	var t := 0
	while w.combo != 0 and t < 4 * int(FPS):
		await process_frame
		t += 1
	_check(w.combo == 0 and t < int(LegionCfg.COMBO_WINDOW * FPS * 0.8),
		"натиск впустую сбросил комбо раньше окна (%.1f с)" % (t / FPS))
	# окно истекло — сброс
	var c3 := _column(420)
	_man(c3)
	_still_foe(c3.seg_center(0) + c3.dir * 40.0)
	w.contracts.release(c3, 0)
	await _frames(40)
	_check(w.combo == 1, "задевший натиск после сброса — комбо 1")
	t = 0
	while w.combo != 0 and t < 8 * int(FPS):
		await process_frame
		t += 1
	_check(w.combo == 0 and absf(t / FPS - LegionCfg.COMBO_WINDOW) < 0.9,
		"без задевшего натиска комбо гаснет через окно (%.1f с)" % (t / FPS))
	# потолок
	w.combo = 20
	_check(is_equal_approx(w.combo_mult(), LegionCfg.COMBO_CAP), "потолок множителя ×1.5")
	w.combo = 0


## Точный срыв: враг в зоне удара — стрелка золотая, срыв отмечен, «Точно!», отброс сильнее;
## обычный натиск отбрасывает на CHARGE_KNOCK.
func _test_perfect() -> void:
	_fresh(Settings.SCHEME_SLING)
	var c := _column(0)
	_man(c)
	var near := _still_foe(c.seg_center(0) + c.dir * 40.0)
	var near_x := near.position.x
	var at := c.seg_center(0)
	await _pull(at, at - c.dir * 90.0)
	var aim := w.contracts.sling_aim()
	_check(bool(aim["perfect"]), "враг в зоне удара — стрелка золотая")
	await _button(at - c.dir * 90.0, MOUSE_BUTTON_RIGHT, false)
	_check(int(w.stats.get("perfect_releases", 0)) == 1, "точный срыв посчитан")
	_check(not w.contracts._popups.is_empty(), "всплыло «Точно!»")
	await _frames(40)
	var knock := near.position.x - near_x
	_check(knock >= LegionCfg.PERFECT_KNOCK * 0.8, "точный срыв: отброс %.0f px" % knock)
	# вне зоны — не точно
	var far := _still_foe(c.seg_center(1) + c.dir * 160.0)
	var at1 := c.seg_center(1)
	await _pull(at1, at1 - c.dir * 30.0)
	_check(not bool(w.contracts.sling_aim()["perfect"]), "враг за зоной удара — не золотится")
	await _esc()
	await _button(at1 - c.dir * 30.0, MOUSE_BUTTON_RIGHT, false)
	far.position = c.seg_center(1) + c.dir * 40.0
	var far_x := far.position.x
	await _move(at1, 0)
	await _button(at1, MOUSE_BUTTON_RIGHT, true)
	await _button(at1, MOUSE_BUTTON_RIGHT, false)
	await _frames(40)
	var k2 := far.position.x - far_x
	# slow/intuit: враг уже в зоне — участок золотой, и щелчок по нему даёт «Точно!» (прежде —
	# обычный натиск); обычный отброс проверяем щелчком по участку без врага в зоне
	_check(k2 >= LegionCfg.PERFECT_KNOCK * 0.8,
		"щелчок по золотому участку: отброс как у «Точно!» %.0f px" % k2)
	var c2 := _column(300)
	_man(c2)
	var mid := _still_foe(c2.seg_center(0) + c2.dir * 104.0)   # за зоной «Точно!» (~91 px), до скалы (x 870)
	var mid_x := mid.position.x
	await _move(c2.seg_center(0), 0)
	await _button(c2.seg_center(0), MOUSE_BUTTON_RIGHT, true)
	await _button(c2.seg_center(0), MOUSE_BUTTON_RIGHT, false)
	await _frames(60)
	var k3 := mid.position.x - mid_x
	_check(k3 >= LegionCfg.CHARGE_KNOCK * 0.8 and k3 < LegionCfg.PERFECT_KNOCK * 0.8,
		"обычный натиск (враг за зоной): отброс %.0f px" % k3)
