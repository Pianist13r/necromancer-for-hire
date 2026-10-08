class_name LegionVoice
extends Node
##
## Голосовой контур LegionAudio: реплики, их классы, очередь сюжета, составные фразы обучения
## (фраза + клип текущей клавиши), выкрик каста поверх сюжета, пауза голоса. Вынесен из
## legion_audio.gd без изменения поведения (D-1008-S15): файл звука вырос за лимиты гейта gdlint
## (1000 строк, 20 публичных методов). Узел — ребёнок LegionAudio, доступ — `audio.speech`.
##
## Своего `_process()` нет: LegionAudio._process() зовёт `tick(delta)` на прежнем месте кадра —
## до реплики простоя и микса музыки (дакинг читает `is_voice_busy()` того же кадра).
## Шины, папка реплик и класс реплики (`LegionAudio.VoiceClass`, `LegionAudio.VOICE_DIR`) —
## прежние имена у LegionAudio: их зовут экраны, катсцены и настройки.
##
## Музыка и голос v15 (пакет audio, 2026-09-25): `voice(id, priority, класс)` на шине `Voice`
## резолвит путь по конвенции `res://assets/legion/voice/<id>.ogg` — будущим пакетам достаточно
## уронить файл и позвать id, правка кода не нужна (список зарезервированных id — в отчёте пакета
## audio). Таймеры — `FxClock.ms()` (D-1008-REC1).

const VOICE_DIR := LegionAudio.VOICE_DIR
const VOICE_VOLUME_DB := -3.0
const TutorialVoice := preload("res://scripts/legion/legion_tutorial_voice.gd")
const CAST_DUCK_DB := -6.0
## Шаги обучения узнаются по имени: новый шаг заменяет в очереди устаревший (см. _enqueue_voice).
const TUTORIAL_VOICE_PREFIX := "lg_tut_"

var _muted := false
var _log_enabled := false
var _voice_player: AudioStreamPlayer
var _voice_priority := 0
var _voice_class: LegionAudio.VoiceClass = LegionAudio.VoiceClass.SHOUT
var _voice_id: StringName = &""
## До этого FxClock.ms() последняя запущенная реплика ещё «звучит» (is_voice_busy) —
## по длине файла, а не AudioStreamPlayer.playing (под --mute плеер не играет вовсе, и занятость
## по .playing сделала бы любой --mute-тест очереди пустым).
var _voice_busy_until_msec := 0
## Очередь сюжетных реплик: [{id, priority, at, seq}], голова — следующая. Порядок — приоритет
## по убыванию, при равном — кто раньше встал (seq). Ёмкость и срок годности — LegionCfg.
## Разбирает `tick()`, когда голос свободен и дерево не на паузе.
var _voice_queue: Array[Dictionary] = []
var _voice_queue_seq := 0
## «Время без паузы» для срока годности очереди (verifier 26.09, вторая проверка: 17 с паузы
## съедали TTL, и шаг обучения из очереди не звучал уже никогда). Копится только, пока дерево
## не на паузе; см. _run_clock().
var _run_clock_msec := 0
var _run_clock_at := 0
var _run_clock_paused := false
var _voice_fade: Tween
var _voice_base_db := 0.0
var _voice_last_msec: Dictionary = {}  # id -> FxClock.ms() своего последнего проигрывания
## Свой генератор для выбора реплик: world.rng — генератор СИМУЛЯЦИИ, каждый лишний вызов из звука
## сдвигает бой и ломает детерминизм серий ботом и тестов (так упал прогон обучения на v15).
var _voice_rng := RandomNumberGenerator.new()
## B-059: пауза одиночки держит звучащую реплику (stream_paused) — узел под миром с
## PROCESS_MODE_ALWAYS, сам плеер на паузе иначе играл бы поверх меню.
var _voice_held := false
var _voice_hold_at := 0
var _voice_parts: Array[StringName] = []
var _voice_part := 0
var _voice_part_until := 0
var _voice_gap_until := 0
var _cast_player: AudioStreamPlayer
var _cast_until := 0


func setup(muted: bool, log_enabled: bool) -> void:
	_muted = muted
	_log_enabled = log_enabled
	_voice_player = AudioStreamPlayer.new()
	_voice_player.bus = &"Voice"
	add_child(_voice_player)
	_voice_base_db = _voice_player.volume_db
	_voice_priority = 0
	_voice_class = LegionAudio.VoiceClass.SHOUT
	_voice_id = &""
	_voice_busy_until_msec = 0
	_voice_queue.clear()
	_run_clock_at = FxClock.ms()


## Кадр голоса — зовёт LegionAudio._process() первым делом (порядок прежний: часы, пауза, вторая
## часть фразы, микс выкрика каста, разбор очереди).
func tick(delta: float) -> void:
	_run_clock()
	_hold_voice_on_pause()
	_tick_voice_parts()
	_tick_cast_mix(delta)
	_flush_voice_queue()


## Публичный API пакета audio: реплика `id` (файл `res://assets/legion/voice/<id>.ogg`, конвенция
## по имени — новых записей не требует правки кода, см. докстринг класса). Один голос одновременно;
## кто кого режет — по КЛАССУ реплики (координатор 26.09, после находок verifier: одиночный слот
## «важной» реплики терял сюжет, резал катсцены и звучал в меню/на паузе):
## - SCENE (кадр катсцены) — всегда обрывает текущую реплику любого класса и чистит очередь:
##   игрок сменил кадр — звучит новый кадр. Откат по id не действует (кадр выбрал сам игрок); та
##   же реплика, уже звучащая (итог боя = кадр 1 финала), не перезапускается, а становится сценой.
## - STORY (сюжет) — обрывает выкрик; если звучит сцена или сюжет — встаёт в очередь (ёмкость
##   AUDIO_V15_VOICE_QUEUE_CAP, порядок по приоритету, без дублей id, новый шаг обучения заменяет
##   устаревший, запись живёт AUDIO_V15_VOICE_QUEUE_TTL_MSEC).
## - SHOUT (выкрик боя) — только в тишине и при пустой очереди; иначе пропадает (устарел). Внутри
##   класса ранжир прежний: выкрик строго выше приоритетом перебивает более слабый выкрик.
## Откат `AUDIO_V15_VOICE_COOLDOWN_MSEC` по id — поверх класса; заявка, отказанная по откату, не
## трогает ни текущую реплику, ни очередь. В `--mute` реально не играет, но решения и след в
## трейс-логе (`--trace` / `dev=audio_log`) те же — так --mute-прогон подтверждает вызов.
func voice(id: StringName, priority: int = 0,
		cls: LegionAudio.VoiceClass = LegionAudio.VoiceClass.SHOUT) -> void:
	if _log_enabled:
		print("VOICE ", id, " prio=", priority, " class=", LegionAudio.VoiceClass.keys()[cls])
	match cls:
		LegionAudio.VoiceClass.SCENE:
			clear_voice_queue()
			if is_voice_busy() and id == _voice_id:
				_voice_class = LegionAudio.VoiceClass.SCENE
				_voice_priority = priority
				return
			_cut_voice()
			_start_voice(id, priority, cls, true)
		LegionAudio.VoiceClass.STORY:
			if not _can_start(id):
				return
			if is_voice_busy() and _voice_class != LegionAudio.VoiceClass.SHOUT:
				_enqueue_voice(id, priority)
			elif _voice_queue.is_empty():
				_start_voice(id, priority, cls)
			else:
				# очередь ещё не разобрана (пауза или тот же кадр) — встаём по приоритету; звучащий
				# выкрик сюжет всё равно обрывает
				_enqueue_voice(id, priority)
				if is_voice_busy():
					_cut_voice()
				_flush_voice_queue()
		_:
			if is_cast_voice_busy() or not _can_start(id):
				return
			if is_voice_busy():
				if _voice_class == LegionAudio.VoiceClass.SHOUT and priority > _voice_priority:
					_start_voice(id, priority, cls)
				return
			if _voice_queue.is_empty():
				_start_voice(id, priority, cls)


## Одна реплика из набора — своим генератором (_voice_rng), не world.rng (COMMON п.9а).
func voice_any(ids: Array, priority: int = 0,
		cls: LegionAudio.VoiceClass = LegionAudio.VoiceClass.SHOUT) -> void:
	if ids.is_empty():
		return
	voice(StringName(String(ids[_voice_rng.randi() % ids.size()])), priority, cls)


## Выкрик строя на старте обычной волны. «Иногда» (DESIGN_V15 §9): не на каждую волну, иначе
## строй бубнит без остановки. Выкрик: если голос занят, реплика просто пропадает — через 10 с она
## уже не к месту.
func wave_shout() -> void:
	if _voice_rng.randf() < 0.4:
		var wave_ids := ["lg_wave_1", "lg_wave_2", "lg_wave_3"]
		voice(StringName(wave_ids[_voice_rng.randi() % wave_ids.size()]),
			LegionCfg.AUDIO_V15_PRIORITY_TROOP, LegionAudio.VoiceClass.SHOUT)


## Голос каста героя (эффект каста играет LegionAudio): под сюжетом — тихий выкрик вторым плеером
## поверх реплики, иначе обычный выкрик (только в тишине).
func hero_cast_voice(slot: int) -> void:
	var letter: String = ["q", "w", "e"][clampi(slot, 0, 2)]
	if is_voice_busy() and _voice_class == LegionAudio.VoiceClass.STORY:
		_play_cast_over_story(StringName("lg_cast_%s_%d" % [letter, 1 + _voice_rng.randi() % 2]))
		return
	voice_any(["lg_cast_%s_1" % letter, "lg_cast_%s_2" % letter],
		LegionCfg.AUDIO_V15_PRIORITY_NECROMANCER, LegionAudio.VoiceClass.SHOUT)


## true — последняя запущенная реплика ещё звучит (по длине файла, см. _voice_busy_until_msec).
func is_voice_busy() -> bool:
	return FxClock.ms() < _voice_busy_until_msec \
		or (_voice_parts.size() > 1 and _voice_part < _voice_parts.size() - 1)


func clear_voice_queue() -> void:
	_voice_queue.clear()


## Конец обучения (пройдено, пропущено, прервано): его шаги из очереди больше не звучат.
func drop_tutorial_voice() -> void:
	for i in range(_voice_queue.size() - 1, -1, -1):
		if String(_voice_queue[i]["id"]).begins_with(TUTORIAL_VOICE_PREFIX):
			_voice_queue.remove_at(i)


## Уроки сняты (конец боя, рестарт, меню): их реплики в очереди и звучащая сейчас — прочь.
func end_tutorial_voice() -> void:
	drop_tutorial_voice()
	if is_voice_busy() and String(_voice_id).begins_with(TUTORIAL_VOICE_PREFIX):
		stop_voice(LegionCfg.AUDIO_V15_VOICE_MENU_FADE_SEC, false)


## Уход из катсцены любым путём (клик за последний кадр, Esc, конец): голос кадра, если ещё
## звучит, гаснет спадом (verifier 26.09: клик по последнему кадру оставлял 9,7-секундную
## lg_intro_4 поверх брифинга, и брифинг с шагом обучения ждали за ней). Кадр, чей голос уже
## договорил, ничего не меняет. Очередь не трогаем — её и так чистит каждый кадр-сцена.
func end_scene_voice() -> void:
	if is_voice_busy() and _voice_class == LegionAudio.VoiceClass.SCENE:
		stop_voice(LegionCfg.AUDIO_V15_VOICE_MENU_FADE_SEC, false)


## Замолчать: очередь — прочь (если `clear_queue`), текущую реплику — спадом за `fade_sec`
## (0 — сразу). Уход в меню, конец катсцены.
func stop_voice(fade_sec: float = 0.0, clear_queue := true) -> void:
	if clear_queue:
		clear_voice_queue()
	_voice_busy_until_msec = 0
	_voice_parts.clear()
	_cast_until = 0
	if _cast_player != null:
		_cast_player.stop()
	_voice_id = &""
	if fade_sec <= 0.0 or _muted or not _voice_player.playing:
		_cut_voice()
		return
	_kill_voice_fade()
	_voice_fade = create_tween()
	_voice_fade.tween_property(_voice_player, "volume_db", LegionAudio.MUTE_DB, fade_sec)
	_voice_fade.tween_callback(_cut_voice)


## Разрешаем привязку при начале воспроизведения, а не при постановке в очередь.
func voice_sequence(id: StringName) -> Array[StringName]:
	return TutorialVoice.sequence(id)


## Из настроек вернулись в тот же урок: повторить инструкцию с новой привязкой.
func refresh_tutorial_voice(id: StringName) -> void:
	if not LessonsCfg.VOICE_KEYS.has(id):
		return
	drop_tutorial_voice()
	if String(_voice_id).begins_with(TUTORIAL_VOICE_PREFIX):
		stop_voice(0.0, false)
	_voice_last_msec.erase(id)
	voice(id, LegionCfg.AUDIO_V15_PRIORITY_HR, LegionAudio.VoiceClass.STORY)


func is_cast_voice_busy() -> bool:
	return _run_clock() < _cast_until


# ── Внутреннее ────────────────────────────────────────────────────────────────

func _can_start(id: StringName) -> bool:
	if not _sequence_available(voice_sequence(id)):
		return false
	var last_msec: int = int(_voice_last_msec.get(id, -LegionCfg.AUDIO_V15_VOICE_COOLDOWN_MSEC * 10))
	return FxClock.ms() - last_msec >= LegionCfg.AUDIO_V15_VOICE_COOLDOWN_MSEC


func _start_voice(id: StringName, priority: int, cls: LegionAudio.VoiceClass,
		ignore_cooldown := false) -> bool:
	if ignore_cooldown:
		if not _sequence_available(voice_sequence(id)):
			return false
	elif not _can_start(id):
		return false
	var now_msec := FxClock.ms()
	_voice_last_msec[id] = now_msec
	_voice_priority = priority
	_voice_class = cls
	_voice_id = id
	# Длина файла читается из ресурса (не AudioStreamPlayer.playing): под --mute плеер не играет
	# вовсе, а is_voice_busy() (и тестам) нужен тот же сигнал «ещё звучит», что в настоящем прогоне.
	_voice_parts = voice_sequence(id)
	_voice_part = 0
	_voice_gap_until = 0
	var stream: AudioStream = load(VOICE_DIR + String(_voice_parts[0]) + ".ogg")
	var len_msec := 0
	for part in _voice_parts:
		var clip: AudioStream = load(VOICE_DIR + String(part) + ".ogg")
		len_msec += int(clip.get_length() * 1000.0)
	len_msec += maxi(0, _voice_parts.size() - 1) * TutorialVoice.GAP_MSEC
	_voice_part_until = _run_clock() + int(stream.get_length() * 1000.0)
	_voice_busy_until_msec = now_msec + len_msec
	if _voice_held:
		_voice_hold_at = now_msec   # новая реплика на паузе: сдвиг считается с её старта
	_kill_voice_fade()
	_voice_player.volume_db = _voice_base_db
	if _muted:
		return true
	_voice_player.stream = stream
	_voice_player.play()
	if _voice_held:
		# B-386 (1): флаг остался с прошлой паузы, а новое воспроизведение паузы не знает — не играет
		# поверх меню паузы: снять и поставить заново, чтобы он лёг на свежее воспроизведение.
		_voice_player.stream_paused = false
		_voice_player.stream_paused = true
	return true


## Жёсткий обрыв (кадр катсцены) — без спада: новый кадр сразу говорит своё.
func _cut_voice() -> void:
	_kill_voice_fade()
	_voice_parts.clear()
	_cast_until = 0
	if _cast_player != null:
		_cast_player.stop()
	_voice_busy_until_msec = 0
	_voice_player.stop()
	_voice_player.volume_db = _voice_base_db


func _kill_voice_fade() -> void:
	if _voice_fade != null and _voice_fade.is_valid():
		_voice_fade.kill()
	_voice_fade = null


func _enqueue_voice(id: StringName, priority: int) -> void:
	for e in _voice_queue:
		if e["id"] == id:
			return
	if String(id).begins_with(TUTORIAL_VOICE_PREFIX):
		# устаревший шаг обучения звучать не должен — игрок его уже прошёл
		for i in range(_voice_queue.size() - 1, -1, -1):
			if String(_voice_queue[i]["id"]).begins_with(TUTORIAL_VOICE_PREFIX):
				_voice_queue.remove_at(i)
	_voice_queue_seq += 1
	_voice_queue.append({
		"id": id, "priority": priority, "at": _run_clock(), "seq": _voice_queue_seq})
	_voice_queue.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if int(a["priority"]) != int(b["priority"]):
			return int(a["priority"]) > int(b["priority"])
		return int(a["seq"]) < int(b["seq"]))
	while _voice_queue.size() > LegionCfg.AUDIO_V15_VOICE_QUEUE_CAP:
		_voice_queue.pop_back()   # наименее важная и самая свежая из них


## B-059: на паузе дерева голос приостановлен, а «занят до» (стенные часы) сдвигается на длину
## паузы — реплика продолжается с того же места и не считается доигравшей, пока ей не вышло время.
## Без паузы (в «Схватке» её нет) — ничего не делает.
func _hold_voice_on_pause() -> void:
	var p := is_inside_tree() and get_tree().paused
	if p == _voice_held or _voice_player == null:
		return
	var now := FxClock.ms()
	_voice_held = p
	if p:
		_voice_hold_at = now
		_voice_player.stream_paused = true
		return
	_voice_player.stream_paused = false
	if _voice_busy_until_msec > _voice_hold_at:
		_voice_busy_until_msec += now - _voice_hold_at


## Часы «без паузы» (мс): отрезок с прошлого учёта засчитывается, только если тогда дерево не
## было на паузе. Учёт — каждый кадр (tick) и при каждой постановке/разборе очереди, так что
## погрешность — не больше кадра на границе паузы.
func _run_clock() -> int:
	var t := FxClock.ms()
	if not _run_clock_paused:
		_run_clock_msec += t - _run_clock_at
	_run_clock_at = t
	_run_clock_paused = is_inside_tree() and get_tree().paused
	return _run_clock_msec


## Голос свободен и игра не на паузе — следующая годная запись очереди. Пауза: мир держит
## PROCESS_MODE_ALWAYS (и этот узел под ним), так что tick() крутится и на паузе — без этой
## проверки отложенная реплика заговорила бы поверх меню паузы (находка verifier 26.09).
func _flush_voice_queue() -> void:
	if _voice_queue.is_empty() or is_voice_busy() or not is_inside_tree() or get_tree().paused:
		return
	var now_run := _run_clock()
	while not _voice_queue.is_empty():
		var e: Dictionary = _voice_queue.pop_front()
		# Шаг обучения не стареет (координатор 26.09): его вытесняет только следующий шаг, а
		# конец обучения, меню и новый бой чистят очередь. Остальное — по сроку годности.
		var tut := String(e["id"]).begins_with(TUTORIAL_VOICE_PREFIX)
		if not tut and now_run - int(e["at"]) > LegionCfg.AUDIO_V15_VOICE_QUEUE_TTL_MSEC:
			continue
		if _start_voice(e["id"], int(e["priority"]), LegionAudio.VoiceClass.STORY):
			return


func _sequence_available(parts: Array[StringName]) -> bool:
	for part in parts:
		if not ResourceLoader.exists(VOICE_DIR + String(part) + ".ogg"):
			return false
	return not parts.is_empty()


func _tick_voice_parts() -> void:
	if _voice_parts.size() < 2 or get_tree().paused:
		return
	var now := _run_clock()
	if now >= _voice_part_until and _voice_part >= _voice_parts.size() - 1:
		_voice_parts.clear()
	if now < _voice_part_until or _voice_parts.is_empty():
		return
	if _voice_gap_until == 0:
		_voice_gap_until = now + TutorialVoice.GAP_MSEC
		return
	if now < _voice_gap_until:
		return
	# Настройки могли смениться на паузе даже во время первой половины фразы.
	_voice_parts = voice_sequence(_voice_id)
	_voice_part += 1
	if _voice_part >= _voice_parts.size():
		_voice_parts.clear()
		return
	var path := VOICE_DIR + String(_voice_parts[_voice_part]) + ".ogg"
	if not ResourceLoader.exists(path):
		_voice_parts.clear()
		return
	var clip := load(path) as AudioStream
	_voice_part_until = now + int(clip.get_length() * 1000.0)
	_voice_busy_until_msec = FxClock.ms() + int(clip.get_length() * 1000.0)
	_voice_gap_until = 0
	if not _muted:
		_voice_player.stream = clip
		_voice_player.play()


func _play_cast_over_story(id: StringName) -> void:
	if is_cast_voice_busy() or not _can_start(id):
		return
	if _cast_player == null:
		_cast_player = AudioStreamPlayer.new()
		_cast_player.bus = &"Voice"
		_cast_player.volume_db = VOICE_VOLUME_DB - 2.0
		add_child(_cast_player)
	var clip := load(VOICE_DIR + String(id) + ".ogg") as AudioStream
	_voice_last_msec[id] = FxClock.ms()
	_cast_until = _run_clock() + int(clip.get_length() * 1000.0)
	if not _muted:
		_cast_player.stream = clip
		_cast_player.play()


func _tick_cast_mix(delta: float) -> void:
	if _cast_player == null:
		return
	_cast_player.stream_paused = get_tree().paused
	if _voice_fade != null and _voice_fade.is_valid():
		return
	var target := _voice_base_db + (CAST_DUCK_DB if is_cast_voice_busy() else 0.0)
	_voice_player.volume_db = move_toward(_voice_player.volume_db, target, delta * 40.0)
