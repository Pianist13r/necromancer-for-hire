extends SceneTree
##
## Самопроверка озвучки событий v15 (integrate1): каст героя, постройка готова, улучшение,
## нехватка душ в меню участка, простой армии — и что ни одна реплика не трогает world.rng
## (COMMON п.9а: генератор симуляции сдвигать нельзя). Реплика «принята», если LegionAudio
## записал её время (_voice_last_msec) — со --mute плеер молчит, но решение то же.
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_voice_events_test.gd -- --mute
##
## Итог «LEGION VOICE: N/M OK»; код выхода 1, если что-то упало.
##

var w: LegionWorld
var audio: LegionAudio
var _checks := 0
var _fails := 0


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


func _said(ids: Array) -> bool:
	for id in ids:
		if audio._voice_last_msec.has(StringName(String(id))):
			return true
	return false


## Выкрик (LegionAudio.VoiceClass.SHOUT) звучит только в тишине (правило трёх классов 26.09),
## поэтому перед ним ждём, пока прошлая реплика сценария честно доиграет, — без сброса занятости.
## Реальное время ОС, пока голос не освободится и очередь не разберётся: занятость голоса
## меряется по Time.get_ticks_msec() (длина файла), а кадры под --fixed-fps идут быстрее.
func _wait_quiet() -> void:
	for i in 4:
		var left := audio._voice_busy_until_msec - Time.get_ticks_msec()
		if left > 0:
			OS.delay_msec(left + 80)
		await _frames(3)
		if audio._voice_busy_until_msec <= Time.get_ticks_msec():
			return


func _run() -> void:
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	w = scene.instantiate() as LegionWorld
	root.add_child(w)
	await _frames(2)
	w.dev["no_waves"] = "1"
	w.dev["spawn_units"] = "0"
	w.start_map("_plots")
	await _frames(2)
	for c in w.get_children():
		if c is LegionAudio:
			audio = c
	_check(audio != null, "узел озвучки боя найден")
	if audio == null:
		quit(1)
		return
	# у служебной карты _plots нет брифинга (lg_brief__plots.ogg нет) — голос свободен
	_check(audio._voice_busy_until_msec <= Time.get_ticks_msec(),
		"служебная карта без брифинга — голос свободен")

	# каст героя — своим генератором, world.rng не сдвинут
	var rng_state := w.rng.state
	audio._on_hero_cast(LegionHero.SLOT_E, Vector2(600, 300))
	_check(_said(["lg_cast_e_1", "lg_cast_e_2"]), "каст Е — реплика lg_cast_e_*")
	_check(w.rng.state == rng_state, "реплика каста не трогает world.rng")
	# каст Е ещё звучит, а выкрик того же ранга выкрик не перебивает: пока он звучит, Ку молчит
	audio._on_hero_cast(LegionHero.SLOT_Q, Vector2(700, 300))
	_check(not _said(["lg_cast_q_1", "lg_cast_q_2"]),
		"выкрик поверх звучащего выкрика того же ранга пропадает")
	await _wait_quiet()
	_check(not _said(["lg_cast_q_1", "lg_cast_q_2"]), "пропавший выкрик не звучит с опозданием")
	var foe := w.spawn_foe_on_path("zombie", PackedVector2Array([Vector2(700, 300)]), Vector2(700, 300))
	foe.speed = 0.0
	w.hero.cast(LegionHero.SLOT_Q, foe.position)
	_check(_said(["lg_cast_q_1", "lg_cast_q_2"]), "настоящий каст Ку через hero_cast — lg_cast_q_*")

	# постройка и улучшение: сюжет обрывает звучащий выкрик (каст Ку) — без подготовки
	var st := w.staff
	w.souls = 1000
	var b := st.build(st.plots[0], LegionCfg.KIND_LABORER)
	_check(b != null and _said(["lg_building_ready"]), "постройка готова — lg_building_ready")
	_check(not _said(["lg_upgrade_done"]), "постройка — не «улучшение»")
	# lg_building_ready ещё звучит: улучшение той же секунды — сюжет за сюжетом, встаёт в очередь
	st.upgrade(b)
	_check(not _said(["lg_upgrade_done"]), "улучшение сразу за постройкой ждёт, не режет её")
	await _wait_quiet()
	_check(_said(["lg_upgrade_done"]), "улучшение — lg_upgrade_done, своей очередью")

	# нехватка душ: нажатие по закрытой кнопке меню участка (выкрик — в тишине)
	await _wait_quiet()
	w.souls = 0
	w.souls_changed.emit(0)
	var p1: Dictionary = st.plots[1]
	w.plot_menu.open(p1, p1["pos"])
	await _frames(1)
	var pressed_any := false
	for btn in w.plot_menu.buttons():
		if btn.disabled:
			var ev := InputEventMouseButton.new()
			ev.button_index = MOUSE_BUTTON_LEFT
			ev.pressed = true
			btn.gui_input.emit(ev)
			pressed_any = true
			break
	_check(pressed_any and _said(["lg_souls_low"]), "клик без душ — lg_souls_low")
	w.plot_menu.close()

	# простой: армия без договоров стоит дольше порога — реплика, но не чаще 20 с боя
	await _wait_quiet()
	for i in LegionCfg.AUDIO_IDLE_VOICE_MIN_UNITS + 2:
		w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(300 + i * 12, 360))
	audio._idle_voice_at = w.now - LegionCfg.AUDIO_IDLE_VOICE_GAP - 1.0
	audio._voice_last_msec.erase(&"lg_idle")
	await _frames(int((LegionCfg.IDLE_NOTICE_TIME + 1.5) * 60.0))
	_check(_said(["lg_idle"]), "простой армии — lg_idle")
	var first_at := audio._idle_voice_at
	audio._voice_last_msec.erase(&"lg_idle")
	await _frames(180)
	_check(not _said(["lg_idle"]) and audio._idle_voice_at == first_at,
		"повтор простоя раньше 20 с боя не звучит")

	w.queue_free()
	await _frames(1)
	print("LEGION VOICE: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)
