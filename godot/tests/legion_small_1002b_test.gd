extends SceneTree
##
## Регресс мелких правок 02.10.2026 (ветка slow/small-1002b).
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_small_1002b_test.gd -- --mute
##
## B-059: пауза одиночки приостанавливает голос (stream_paused) и сдвигает «занят до» на длину паузы —
##        реплика продолжается с того же места, а не обрывается и не начинается заново;
## B-065: нормально пройденное обучение не стирает из очереди реплику последнего шага
##        (прерванное/пропущенное — по-прежнему стирает);
## B-062: --dev save=user://имя.cfg уводит настройки в user://имя_settings.cfg.
## Итог «LEGION SMALL 1002B: N/M OK»; код выхода 1, если что-то упало.
##

const SAVE := "user://legion_small_1002b_test.cfg"

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
	await _test_voice_pause()
	await _test_tutorial_end_voice()
	_test_settings_path()
	Campaign.reset()
	print("LEGION SMALL 1002B: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _test_voice_pause() -> void:
	print("— B-059: пауза держит голос")
	var a := LegionAudio.new()
	a.process_mode = Node.PROCESS_MODE_ALWAYS   # как под миром одиночки
	root.add_child(a)
	a.setup_standalone(false, false)   # не mute: плеер реально играет (звук dummy-драйвера, headless)
	await _frames(2)
	a.speech.voice(&"lg_intro_1", 5, LegionAudio.VoiceClass.SCENE)   # ~11 с
	var until_before: int = a.speech._voice_busy_until_msec
	_check(a.speech.is_voice_busy(), "реплика звучит")
	paused = true
	await _frames(3)
	_check(a.speech._voice_player.stream_paused, "на паузе плеер голоса приостановлен")
	OS.delay_msec(400)
	await _frames(2)
	paused = false
	await _frames(3)
	_check(not a.speech._voice_player.stream_paused, "после паузы плеер голоса снова идёт")
	_check(a.speech._voice_busy_until_msec - until_before >= 380,
		"«занят до» сдвинут на длину паузы (+%d мс)" % (a.speech._voice_busy_until_msec - until_before))
	_check(a.speech.is_voice_busy(), "реплика не оборвана паузой")
	# выкрик на паузе без звучащей реплики: ничего не ломается и сдвига нет
	a.speech.stop_voice()
	var idle_until: int = a.speech._voice_busy_until_msec
	paused = true
	await _frames(2)
	OS.delay_msec(100)
	paused = false
	await _frames(2)
	_check(a.speech._voice_busy_until_msec == idle_until, "тишина паузой не «удлиняется»")
	a.queue_free()
	await _frames(1)


func _test_tutorial_end_voice() -> void:
	print("— B-065: конец обучения не съедает последнюю реплику")
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	var w := scene.instantiate() as LegionWorld
	root.add_child(w)
	await _frames(2)
	w.dev["no_waves"] = "1"
	w.dev["spawn_units"] = "0"
	w.start_map("wasteland")
	await _frames(2)
	var audio: LegionAudio = w.audio
	_check(audio != null, "озвучка боя есть")
	if audio == null:
		w.queue_free()
		return
	for done in [true, false]:
		audio.speech.clear_voice_queue()
		audio.speech.voice(&"lg_intro_1", 5, LegionAudio.VoiceClass.SCENE)   # занять голос
		var t := LegionTutorial.new()
		var lesson := {"id": &"x", "start": true, "kind": &"line", "when": "start", "text": "t",
			"done": "contract_created", "mark": "", "hold": false, "voice": &"lg_tut_1"}
		t.world = w
		t.lessons = [lesson]
		audio.speech.voice(&"lg_tut_1", LegionCfg.AUDIO_V15_PRIORITY_HR, LegionAudio.VoiceClass.STORY)
		_check(_queued(audio, "lg_tut_1"), "реплика шага ждёт в очереди (%s)" % ("пройдено" if done else "прервано"))
		t.call("_disconnect", done) if t.get_method_argument_count("_disconnect") > 0 else t.call("_disconnect")
		if done:
			_check(_queued(audio, "lg_tut_1"), "обучение пройдено — реплика последнего шага осталась")
		else:
			_check(not _queued(audio, "lg_tut_1"), "обучение прервано — реплика стёрта")
	audio.speech.stop_voice()
	w.queue_free()
	await _frames(1)


func _queued(audio: LegionAudio, id: String) -> bool:
	for e in audio.speech._voice_queue:
		if String(e["id"]) == id:
			return true
	return false


func _test_settings_path() -> void:
	print("— B-062: настройки пары к --dev save")
	var old_path := Settings.path
	_check(old_path == "user://settings.cfg", "без --dev save — общий settings.cfg")
	_use_dev_save("user://probe_1002b.cfg")
	_check(Settings.path == "user://probe_1002b_settings.cfg", "путь пары: " + Settings.path)
	_use_dev_save("")
	_check(Settings.path == "user://settings.cfg", "пустой save возвращает общий файл")
	Settings.path = old_path
	Settings._cfg = null


## Динамический вызов: на старом коде метода нет — проверка падает FAIL-ом, а не ошибкой разбора.
func _use_dev_save(p: String) -> void:
	var s: GDScript = load("res://scripts/common/settings.gd")
	if s.has_method("use_dev_save"):
		s.call("use_dev_save", p)
