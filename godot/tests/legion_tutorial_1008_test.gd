extends SceneTree
## Регресс обучения: числа, голос после переназначения, ввод пропуска, B-064/B-127.

var checks := 0
var failures := 0
var finished_count := 0


func _initialize() -> void:
	_run.call_deferred()


func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
	print("  %s %s" % ["ok" if ok else "FAIL", message])


func _run() -> void:
	Settings.path = "user://tutorial_1008_settings.cfg"
	Settings._cfg = ConfigFile.new()
	Campaign.set_save_path("user://tutorial_1008.cfg")
	Campaign.reset()
	Controls.reset()
	_test_numbers()
	await _test_voice()
	await _test_skip()
	await _test_consent()
	await _test_visible_keys()
	await _test_line()
	Controls.reset()
	print("LEGION TUTORIAL 1008: %d/%d OK" % [checks - failures, checks])
	quit(1 if failures else 0)


func _test_numbers() -> void:
	var tut := LegionTutorial.new()
	for map_id in ["fork", "bridge", "swamp", "maze"]:
		tut.lessons = LegionTutorial.parse(LegionWorld.load_map(map_id))
		for i in tut.lessons.size():
			var kind: StringName = tut.lessons[i]["kind"]
			var expected := ""
			match kind:
				&"hero_w": expected = "%d с" % roundi(LegionCfg.W_DURATION)
				&"hero_e": expected = "%d с" % roundi(LegionCfg.E_DURATION_BASE)
				&"stun_hit": expected = "×" + LegionTutorial._mult(LegionCfg.STUNNED_CHARGE_MULT)
			if expected != "":
				check(tut.step_text(i).contains(expected), "%s берёт число из LegionCfg" % kind)
			check(not tut.step_text(i).contains("%"), "%s: форматирование завершено" % kind)
			check(not tut.step_text(i).contains("{"), "%s: все токены раскрыты" % kind)
			if kind == &"figure_ult" and tut.lessons[i]["arg"] != "mini":
				var figure := StringName(tut.lessons[i]["arg"])
				var teaching := preload("res://scripts/legion/legion_teaching_text.gd")
				var count := teaching.seats(figure)
				var contract := Contract.new()
				contract.figure = figure
				for seat in count:
					contract.posts.append({})
				check(tut.step_text(i).contains("%d из %d" % [contract.charge_need(), count]),
					"%s: условие заряда совпадает с Contract.charge_need" % figure)
	tut = null
	check(HowtoLegion.facts("{cfg:perfect}") == LegionTutorial._mult(LegionCfg.PERFECT_FIRST_MULT),
		"справка: множитель «Точно!» из LegionCfg")
	check(HowtoLegion.facts("{cfg:delay}") == LegionTutorial._mult(
		LegionCfg.DELAY_MAX / LegionCfg.DELAY_DRAIN), "справка: время отсрочки из LegionCfg")


func _test_voice() -> void:
	var audio := LegionAudio.new()
	root.add_child(audio)
	audio.setup_standalone(true, false)
	check(audio.speech.has_method("voice_sequence"), "есть очередь фраза → текущая клавиша")
	if audio.speech.has_method("voice_sequence"):
		Controls.rebind(&"cast_q", KEY_Z)
		var sequence: Array = audio.speech.call("voice_sequence", &"lg_tut_4")
		check(sequence == [&"lg_tut_4_prompt", &"key_z"], "Q→Z выбирает клип Зэ")
		for part in sequence:
			check(ResourceLoader.exists(LegionAudio.VOICE_DIR + String(part) + ".ogg"),
				"клип существует: " + String(part))
		audio.speech.voice(&"lg_tut_4", 10, LegionAudio.VoiceClass.STORY)
		check(audio.speech._voice_parts == sequence, "выбранная последовательность реально стартует")
		Controls.rebind(&"cast_q", KEY_X)
		audio.speech._voice_part_until = 0
		audio.speech._voice_gap_until = 1
		paused = true
		audio.speech._tick_voice_parts()
		check(audio.speech._voice_part == 0, "пауза не запускает клип клавиши")
		paused = false
		audio.speech._tick_voice_parts()
		check(audio.speech._voice_parts[audio.speech._voice_part] == &"key_x",
			"переназначение во время фразы меняет ещё не произнесённое имя")
		audio.speech.stop_voice()
		check(audio.speech._voice_parts.is_empty(), "выход очищает составную реплику целиком")
		Controls.reset()
		audio.speech._voice_last_msec.clear()
		audio.speech.voice(&"lg_tut_1", 10, LegionAudio.VoiceClass.STORY)
		audio.speech.voice(&"lg_tut_4", 10, LegionAudio.VoiceClass.STORY)
		Controls.rebind(&"cast_q", KEY_Z)
		audio.speech._voice_busy_until_msec = 0
		audio.speech._flush_voice_queue()
		check(audio.speech._voice_parts == [&"lg_tut_4_prompt", &"key_z"],
			"очередь разрешает клавишу при старте, после смены привязки")
		audio.speech.voice(&"lg_intro_1", 10, LegionAudio.VoiceClass.SCENE)
		check(audio.speech._voice_parts == [&"lg_intro_1"], "катсцена убирает остаток имени клавиши")
		audio.speech.stop_voice()
		audio.speech._voice_last_msec.clear()
		Controls.reset()
	audio.speech.voice(&"lg_tut_1", 10, LegionAudio.VoiceClass.STORY)
	audio._on_hero_cast(0, Vector2.ZERO)
	check(audio.speech.has_method("is_cast_voice_busy") and audio.speech.call("is_cast_voice_busy"),
		"B-064: каст слышен во время реплики урока")
	check(audio.speech._voice_id == &"lg_tut_1", "каст не обрывает инструкцию")
	audio.queue_free()
	await process_frame


func _test_consent() -> void:
	var metrics := PlayMetrics.new()
	root.add_child(metrics)
	check(metrics.has_method("consider_consent"), "статистика ждёт конца первого боя")
	if metrics.has_method("consider_consent"):
		metrics._allowed = true
		metrics.consider_consent(false, true, 10.0)
		check(not metrics._offered, "на первом меню окно статистики не открывается")
		metrics.consider_consent(true, false, 30.0)
		check(not metrics._offered, "окно не перебивает первый бой")
		metrics.consider_consent(false, true, 3.1)
		check(metrics._offered, "после боя окно предлагается")
		var dialog := metrics.get_child(0) as ConfirmationDialog
		check(dialog != null, "показан диалог согласия")
		if dialog != null:
			dialog.custom_action.emit(&"later")
			check(not PlayMetrics.consent(), "Позже не включает отправку")
			check(Settings.get_value(PlayMetrics.SECTION, PlayMetrics.KEY, "pending") == "pending",
				"Позже не записывает отказ вместо отложенного решения")
	metrics.queue_free()
	await process_frame


func _test_skip() -> void:
	root.size = Vector2i(1280, 720)
	var scene := LegionCutscene.new()
	root.add_child(scene)
	scene.finished.connect(func() -> void: finished_count += 1)
	scene.play([LegionCutscene.Frame.new("Первый"), LegionCutscene.Frame.new("Второй")])
	var key := InputEventKey.new()
	key.keycode = KEY_SPACE
	key.pressed = true
	key.echo = true
	scene._unhandled_input(key)
	check(scene._index == 0, "удержание Пробела не пролистывает вступление")
	key.echo = false
	key.keycode = KEY_ESCAPE
	Input.parse_input_event(key)
	await process_frame
	check(finished_count == 1, "одно нажатие Esc пропускает всю катсцену")
	if is_instance_valid(scene):
		scene.queue_free()
	await process_frame
	scene = LegionCutscene.new()
	root.add_child(scene)
	scene.finished.connect(func() -> void: finished_count += 1)
	scene.play([LegionCutscene.Frame.new("Первый"), LegionCutscene.Frame.new("Второй")])
	await process_frame
	var buttons := scene.find_children("*", "Button", true, false)
	check(not buttons.is_empty(), "пропуск виден как кнопка")
	if not buttons.is_empty():
		var button := buttons[0] as Button
		var position := button.get_global_rect().get_center()
		var motion := InputEventMouseMotion.new()
		motion.position = position
		motion.global_position = position
		Input.parse_input_event(motion)
		await process_frame
		for pressed in [true, false]:
			var click := InputEventMouseButton.new()
			click.button_index = MOUSE_BUTTON_LEFT
			click.position = position
			click.global_position = position
			click.pressed = pressed
			click.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
			Input.parse_input_event(click)
			await process_frame
	check(finished_count == 2, "один щелчок по кнопке пропускает всё вступление")
	if is_instance_valid(scene):
		scene.queue_free()
	await process_frame


func _test_visible_keys() -> void:
	Controls.rebind(&"cast_q", KEY_Z)
	var pause := LegionPause.new()
	root.add_child(pause)
	pause._show_keys()
	var dialog := pause.get_node("ControlsCheatsheet") as AcceptDialog
	check(dialog.visible and dialog.dialog_text.contains("Z"),
		"TU-05: шпаргалка действительно видна и называет переназначенную клавишу")
	check(dialog.dialog_text.contains("Касса") and dialog.dialog_text.contains("звук"),
		"TU-05: в шпаргалке есть Касса и звук")
	var teaching := preload("res://scripts/legion/legion_teaching_text.gd")
	check(dialog.dialog_text.contains(teaching.render("{charge:triangle}")),
		"шпаргалка объясняет точный состав обряда из FigureCfg")
	pause.queue_free()
	await process_frame
	Controls.reset()


func _test_line() -> void:
	var packed: PackedScene = load("res://scenes/legion_world.tscn")
	var world := packed.instantiate() as LegionWorld
	world.embedded = true
	root.add_child(world)
	await process_frame
	world.start_map("wasteland")
	world.start_tutorial()
	world.tutorial.force_step(3)
	var max_ratio := 0.0
	for i in 3600:
		await process_frame
		for contract in world.contracts.contracts:
			for segment in contract.seg_count():
				if contract.seg_alive(segment):
					max_ratio = maxf(max_ratio, contract.seg_age[segment] / contract.ttl)
	check(world.tutorial.step_kind() == &"perfect", "B-127: 60 секунд ожидания не откатывают урок")
	check(max_ratio <= LegionTutorial.LINE_AGE_CAP + 0.01, "B-127: возраст линии ≤ половины срока")
	world.queue_free()
	await process_frame
