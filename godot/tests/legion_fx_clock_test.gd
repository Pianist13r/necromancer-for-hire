extends SceneTree
##
## Регресс REC-01 (аудит записи 08.10.2026): часы эффектов и звуковых ограничителей — кадровые.
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_fx_clock_test.gd -- --mute
##
## --fixed-fps снимает синхронизацию с реальным временем: 60 кадров проходят за миллисекунды, как
## офлайн-рендер Movie Maker — только наоборот (запись 1080p идёт медленнее жизни). Эффект или
## лимит, который считает Time.get_ticks_msec(), здесь «не видит» прошедшей секунды кадров, —
## ровно то расхождение, из-за которого в записи схлопывались вспышки и накладывались звуки.
## Режим кадров FxClock включается сам в Movie Maker; здесь — FxClock.use_frames(), как у
## режиссёра записи (живая игра без записи остаётся на настенных часах).
## Проверяется настоящими путями игры, без чтения FxClock в самих проверках 2–4:
## 1) FxClock за 60 кадров при 60 fps — 1000 мс;
## 2) вспышка «стена» (ContractField._wall_bump): вторая — через 70 кадров (> WALL_GAP 1 с);
## 3) лимит события LegionAudio._play («wave_started», 400 мс): второе — через 30 кадров (500 мс);
## 4) занятость реплики LegionAudio по длине файла: занята сразу, свободна через длину + 10 кадров.
## Итог «LEGION FX CLOCK: N/M OK»; код выхода 1, если что-то упало.
##

const FPS := 60
const VOICE_ID := &"lg_boss_appear"

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
	FxClock.use_frames()
	await _frames(2)
	await _test_clock()
	await _test_wall_bump()
	await _test_audio_limit()
	await _test_voice_busy()
	print("LEGION FX CLOCK: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


func _test_clock() -> void:
	var a := FxClock.ms()
	await _frames(FPS)
	var d := FxClock.ms() - a
	_check(FxClock.frames_mode() and absi(d - 1000) <= 2, "FxClock: 60 кадров при --fixed-fps 60 = %d мс (ждём 1000)" % d)


func _test_wall_bump() -> void:
	var f := ContractField.new()
	f._wall_bump(Vector2(100, 100))
	var first := f.wall_bumps
	await _frames(70)
	f._wall_bump(Vector2(100, 100))
	_check(first == 1 and f.wall_bumps == 2,
		"«стена»: вторая вспышка через 70 кадров (> 1 с кадров) — вспышек %d (ждём 2)" % f.wall_bumps)
	f.free()


func _test_audio_limit() -> void:
	var la := LegionAudio.new()
	root.add_child(la)
	la.setup_standalone(true, false)
	la._play("wave_started", "wave_horn")
	await _frames(30)
	la._play("wave_started", "wave_horn")
	var played := int(la._play_counts.get("wave_started", 0))
	_check(played == 2, "лимит звука 400 мс: второй через 30 кадров (500 мс) — сыграно %d (ждём 2)"
		% played)
	la.queue_free()
	await _frames(1)


func _test_voice_busy() -> void:
	var stream: AudioStream = load(LegionAudio.VOICE_DIR + String(VOICE_ID) + ".ogg")
	var len_frames := ceili(stream.get_length() * FPS)
	var la := LegionAudio.new()
	root.add_child(la)
	la.setup_standalone(true, false)
	la.speech.voice(VOICE_ID, 2, LegionAudio.VoiceClass.STORY)
	var busy0 := la.speech.is_voice_busy()
	await _frames(len_frames + 10)
	var busy1 := la.speech.is_voice_busy()
	_check(busy0 and not busy1,
		"реплика %.2f с: занята сразу (%s), свободна через %d кадров (%s)"
			% [stream.get_length(), busy0, len_frames + 10, not busy1])
	# и не раньше: за половину длины реплика ещё звучит
	la.speech.voice(VOICE_ID, 2, LegionAudio.VoiceClass.SCENE)
	await _frames(len_frames / 2)
	_check(la.speech.is_voice_busy(), "реплика: на половине длины в кадрах ещё занята")
	la.queue_free()
	await _frames(1)
