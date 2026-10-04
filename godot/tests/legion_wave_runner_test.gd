extends SceneTree
## Ручные часы и настоящий мир: тест расписания не зависит от скорости рендера и ИИ.

var w: LegionWorld
var _checks := 0
var _fails := 0
var _clears: Array[int] = []
var _warnings: Array[Dictionary] = []
var _opens: Array[String] = []
var _calls: Array[int] = []


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_fails += 1
	print("  %s %s" % ["ok" if ok else "FAIL", what])


func _run() -> void:
	Campaign.set_save_path("user://legion_wave_runner_test.cfg")
	Campaign.reset()
	w = LegionWorld.new()
	w.embedded = true
	root.add_child(w)
	w.set_process(false)
	w.wave_cleared.connect(func(i: int) -> void: _clears.append(i))
	w.breach_warned.connect(func(id: String, left: float, summary: Array) -> void:
		_warnings.append({"id": id, "left": left, "summary": summary}))
	w.breach_opened.connect(func(id: String) -> void: _opens.append(id))
	w.wave_called.connect(func(i: int, _bonus: int) -> void: _calls.append(i))
	_test_overlap()
	_test_call()
	_test_breach()
	_test_legacy()
	_test_hud_and_damage()
	_test_edge_cases()
	if w.args.has("shot"):
		await _capture_breach(String(w.args["shot"]))
	print("LEGION WAVES: %d/%d OK" % [_checks - _fails, _checks])
	w.queue_free()
	await process_frame
	quit(1 if _fails else 0)


func _setup(waves: Array) -> WaveRunner:
	w.start_map("_gray")
	for f in w.foes:
		f.queue_free()
	w.foes.clear()
	w.map["roads"] = [{"id": "east", "path": [[1000, 100], [800, 100], [800, 400]]}]
	w.map["waves"] = waves
	w.wave_runner.setup(w, w.map)
	_clears.clear()
	_warnings.clear()
	_opens.clear()
	_calls.clear()
	return w.wave_runner


func _group(n: int, delay := 0.0, interval := 1.0) -> Dictionary:
	return {"type": "zombie", "road": "east", "count": n, "delay": delay, "interval": interval}


func _kill(wave: int) -> void:
	for f in w.foes:
		if int(f.origin.get("wave", 0)) == wave:
			f.alive = false


func _test_overlap() -> void:
	var wr := _setup([
		{"pause": 0, "next_in": 2, "groups": [_group(4, 0, 2)]},
		{"pause": 0, "groups": [_group(3, 1, 1)]}])
	var initial_souls := w.souls
	wr.tick(0)
	wr.tick(2)
	_check(wr.wave_no() == 2 and wr.remaining_in_queue() == 5, "нахлёст сохраняет обе очереди")
	wr.tick(1)
	_kill(1)
	_kill(2)
	wr.tick(1)
	_check(w.phase == LegionWorld.Phase.BATTLE, "победы нет при непустом хвосте очереди")
	wr.tick(2)
	_check(w.foes.size() == 7, "ровно семь спавнов, нет потерь и дублей")
	var origins: Array[int] = [0, 0]
	for f in w.foes:
		origins[int(f.origin["wave"]) - 1] += 1
	_check(origins == [4, 3], "каждый спавн сохраняет свою волну")
	_kill(2)
	wr.tick(0)
	_check(_clears == [1], "вторая волна получает награду независимо от первой")
	_kill(1)
	wr.tick(0)
	wr.tick(100)
	_check(_clears == [1, 0] and w.souls - initial_souls == 30, "ровно 15 душ за каждый клир")
	_check(w.phase == LegionWorld.Phase.VICTORY, "победа только после всех очередей и врагов")


func _test_call() -> void:
	var wr := _setup([
		{"pause": 2, "next_in": 100, "groups": [_group(1)]},
		{"pause": 10, "next_in": 40, "groups": [_group(1)]},
		{"pause": 10, "next_in": 20, "groups": [_group(1)]},
		{"pause": 10, "groups": [_group(1)]}])
	_check(wr.call_next() == -1, "первая волна не вызывается")
	wr.tick(2)
	_check(not wr.can_call(), "нельзя вызвать до выпуска групп")
	wr.tick(1)
	_check(wr.call_next() == 8 and _calls == [1], "бонус ограничен восемью, сигнал 0-based")
	wr.tick(1)
	_check(wr.call_next() == -1, "защита от повторного вызова раньше 10 секунд")
	wr.tick(9)
	_check(wr.call_next() == 7, "ровно через 10 секунд floor(30 × 0.25) = 7")
	wr.tick(10)
	_check(wr.call_next() == 2, "floor(10 × 0.25) = 2")
	_check(wr.call_next() == -1 and wr.next_start_in() == -1, "после старта последней вызывать нечего")
	_check(w.stats["waves_called"] == 3 and w.stats["call_bonus"] == 17, "статистика вызовов и бонусов")
	wr = _setup([
		{"pause": 0, "next_in": 10, "groups": [_group(1)]},
		{"pause": 0, "next_in": 0, "groups": [_group(1)]},
		{"pause": 0, "groups": [_group(1)]}])
	wr.tick(0)
	wr.tick(1)
	_kill(1)
	wr.tick(9)
	_check(wr.wave_no() == 2 and wr.call_next() == -1, "клир + таймер + кнопка дают один старт")
	wr = _setup([{"pause": 0, "groups": [_group(1)]}, {"groups": [_group(1)]}])
	wr.tick(0)
	wr.tick(1)
	_check(is_inf(wr.next_start_in()) and wr.call_next() == 0, "неизвестное время до клира без выдуманного бонуса")


func _test_breach() -> void:
	var g := _group(2, 12, 1)
	g["breach"] = "bend"
	g["road"] = "ignored"
	g["at"] = 1
	var column := _group(1)
	column["at"] = 250
	var wr := _setup([{"pause": 0, "groups": [column, g]}])
	w.map["breaches"] = [{"id": "bend", "road": "east", "at": 300}]
	_check(wr.next_wave_groups()[1]["from"] == "breach:bend", "превью сохраняет источник")
	wr.held = true
	wr.tick(100)
	_check(wr.wave_no() == 0 and _warnings.is_empty(), "held замораживает первую паузу")
	wr.held = false
	wr.tick(0)
	wr.tick(1)
	_check(w.foes[0].position == Vector2(800, 150), "at отмеряется по ломаной дороги")
	_check(w.foes[0]._path == PackedVector2Array([Vector2(800, 150), Vector2(800, 400)]),
		"остаток пути не возвращает врага к воротам")
	wr.tick(1)
	_check(_warnings.size() == 1 and _warnings[0]["left"] == 10.0, "предупреждение ровно за 10 секунд")
	_check(w.breach_pos("bend") == Vector2(800, 200), "позиция трещины из road + at")
	wr.held = true
	wr.tick(100)
	_check(_opens.is_empty() and w.foes.size() == 1, "held замораживает предупреждение и спавн")
	wr.held = false
	wr.tick(9)
	_check(_opens.is_empty(), "трещина не открывается раньше срока")
	wr.tick(1)
	wr.tick(1)
	_check(_warnings.size() == 1 and _opens == ["bend"], "одно предупреждение и открытие на волну")
	_check(w.foes.size() == 3 and w.foes[1].position == Vector2(800, 200), "трещина переопределяет road и at")
	w.foe_reached_cauldron(w.foes[1])
	w.foe_reached_cauldron(w.foes[0])
	_check(w.stats["breach_leaks"] == 1, "прорыв из трещины учитывается отдельно от ворот")
	g["delay"] = 3
	wr = _setup([{"pause": 0, "groups": [g]}])
	wr.tick(0)
	_check(_warnings.size() == 1 and _warnings[0]["left"] == 3.0, "короткая задержка предупреждает на старте")


func _test_legacy() -> void:
	w.start_map("_gray")
	var sleepers := w.foes.size()
	var wr := w.wave_runner
	var waves: Array = w.map["waves"]
	var count := 0
	for wave: Dictionary in waves:
		for g: Dictionary in wave["groups"]:
			count += int(g.get("count", 1))
	wr.tick(float(waves[0]["pause"]))
	wr.tick(100)
	_check(wr.wave_no() == 1, "_gray без next_in ждёт клира даже после 100 секунд")
	for i in waves.size():
		_kill(i + 1)
		wr.tick(0)
		if i + 1 < waves.size():
			var pause := float(waves[i + 1]["pause"])
			_check(is_equal_approx(wr.next_start_in(), pause), "_gray берёт pause следующей волны")
			wr.tick(pause)
			wr.tick(100)
	_check(w.foes.size() == count + sleepers and w.phase == LegionWorld.Phase.VICTORY, "_gray выпускает прежний состав до победы")


func _test_hud_and_damage() -> void:
	var wr := _setup([{"pause": 0, "groups": [_group(1)]}, {"groups": [_group(1)]}])
	wr.tick(0)
	wr.tick(1)
	w.contracts.human_input = false
	_check(w.call_wave() == -1, "бот не вызывает через человеческий API")
	w.contracts.human_input = true
	wr.held = true
	w.hud.tick(1)
	_check(w.hud._preview_text.text == "Обучение" and not w.hud._call.visible,
		"HUD показывает обучение без кнопки")
	wr.held = false
	w.hud.tick(1)
	_check(w.hud._call.visible and not w.hud._call.disabled, "HUD разрешает вызов человеку")
	w.paused = true
	_check(w.call_wave() == -1, "пауза запрещает кнопку и N")
	w.paused = false
	var f := w.foes[0]
	var before := {f: f.hp}
	w.now = 7.0
	f.take_damage(1, f.position)
	w._track_damage(before, 1)
	w._track_damage({f: f.hp}, 2)
	_check(w.stats["first_contact_t"] == 7.0 and w.stats["no_dmg_s"] == 2.0,
		"первый урон и секунды текущего затишья")
	f.take_damage(1, f.position)
	w._track_damage(before, 1)
	_check(w.stats["first_contact_t"] == 7.0 and w.stats["no_dmg_s"] == 0.0,
		"новый удар сбрасывает затишье, но сохраняет первый контакт")


func _test_edge_cases() -> void:
	var wr := _setup([{"pause": 0, "groups": []}])
	var souls := w.souls
	wr.tick(0)
	wr.tick(1)
	_check(w.phase == LegionWorld.Phase.VICTORY and w.souls == souls + 15,
		"пустая последняя волна тоже получает единственную награду")
	wr = _setup([{"pause": 0, "next_in": 30, "groups": [_group(1)]},
		{"pause": 0, "next_in": 0, "groups": []}, {"groups": []}])
	wr.tick(0)
	wr.tick(1)
	_check(wr.call_next() == 7, "вызов до шага с клиром")
	_kill(1)
	wr.tick(1)
	_check(wr.wave_no() == 2, "ручной вызов перед тиком не дублируется автостартом в этом тике")
	wr = _setup([{"pause": 0, "groups": [_group(1)]}, {"groups": [_group(1)]}])
	wr.tick(0)
	wr.tick(1)
	_kill(1)
	wr.tick(0)
	_check(wr.next_start_in() == 10.0, "отсутствующий pause даёт 10 секунд")
	var key := InputEventKey.new()
	key.physical_keycode = KEY_N
	key.pressed = true
	w._unhandled_input(key)
	_check(wr.wave_no() == 2 and w.stats["waves_called"] == 1, "клавиша N вызывает волну")
	wr = _setup([{"pause": 0, "groups": [_group(1)]}, {"groups": [_group(1)]}])
	wr.tick(0)
	wr.tick(1)
	_kill(1)
	wr.tick(0)
	var fkey := InputEventKey.new()
	fkey.physical_keycode = KEY_F
	fkey.pressed = true
	w._unhandled_input(fkey)
	_check(wr.wave_no() == 2, "клавиша F вызывает волну (v18: левая рука не уходит с Q W E R)")
	var main := LegionMain.new()
	main.world = w
	var result := LegionResult.new()
	main.add_child(result)
	w.phase = LegionWorld.Phase.VICTORY
	w.stats["has_breaches"] = true
	w.stats["breach_leaks"] = 0
	w.stats["breach_spawned"] = 0
	_check(not result._breach_closed({}), "трещина, которая не открывалась, отметки не даёт")
	w.stats["breach_spawned"] = 3
	_check(result._breach_closed({}), "экран кампании читает отметку из завершённого мира")
	w.stats["breach_leaks"] = 1
	_check(not result._breach_closed({}), "утечка убирает отметку итога")
	_check(not result._breach_closed({"has_breaches": false}), "карта без трещин не получает отметку")
	main.free()


## Не меняем JSON пакета M: для кадра используем копию данных настоящего Пустыря.
func _capture_breach(path: String) -> void:
	w.start_map("wasteland")
	w.map["breaches"] = [{"id": "bend", "road": "east", "at": 1380}]
	var g := _group(6, 12)
	g["breach"] = "bend"
	w.map["waves"] = [{"pause": 0, "next_in": 24, "groups": [g]},
		{"groups": [_group(8), {"type": "beetle", "count": 4, "breach": "bend", "delay": 12}]}]
	w.wave_runner.setup(w, w.map)
	w.wave_runner.tick(0)
	w.wave_runner.tick(2)
	w.now = 2
	w.hud.tick(1)
	w._fx.queue_redraw()
	for i in 90:
		await process_frame
	await RenderingServer.frame_post_draw
	var error := get_root().get_texture().get_image().save_png(path)
	_check(error == OK, "кадр предупреждения сохранён: " + path)
