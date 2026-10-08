extends SceneTree
##
## Регресс звука к выпуску в Steam (аудит 08.10, docs/dev/audit-1008/audio.md, SND-01…SND-04):
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_audio_test.gd -- --mute
##
## (а) ключевые события боя подписаны в LegionAudio и доходят до эффекта (каст Ку/Дубль-вэ/Е,
##     «Сбор», удар и точный срыв залпа, комбо, давка, прорыв, постройка, пружина, Таб, рогатка,
##     Юрист, досрочный вызов, отказ каста) — и ни одно не сдвигает world.rng;
## (б) два подряд вызова одного эффекта звучат по-разному (высота/громкость), генератор свой;
## (в) пул эффектов не обрывает звучащий звук, когда звуков больше, чем было плееров (8);
## (г) голос приглушает музыку на шине Music и отпускает её, когда реплика кончилась;
## (д) на Master стоит лимитер; на Music — слои драматургии (фильтр и усиление);
## (е) синтез: у каждого эффекта свой тембр, пик ниже 0 dBFS, края без щелчка;
## (ж) кнопки интерфейса озвучены централизованно (наведение и нажатие), без правки экранов.
##
## Звук эффектов и музыки проверяется на СВОИХ неприглушённых узлах (Audio, LegionAudio): под
## --headless движок берёт драйвер Dummy, поэтому на колонки ничего не уходит, а плееры честно
## играют (проверено 08.10: позиция воспроизведения растёт). Мир с его узлом — под --mute.
## Методы новой версии зовутся через has_method/get — на старом коде тест печатает FAIL, а не
## падает разбором. Итог «LEGION AUDIO: N/M OK»; код выхода 1, если что-то упало.
##

const SAVE := "user://legion_audio_test.cfg"
## Длинные эффекты (≥ 0,4 с), по одному на каждый плеер старого пула (8) и ещё один сверху.
const LONG_IDS := [
	"ult_blast", "ult_cast", "wave_start", "totem_place", "mine_boom",
	"item_get", "cast_w", "cast_e", "ult_ready",
]
## Полный пул (16) длинными эффектами; первый — рёв босса (проба verifier 08.10, probe_pool.gd).
const FULL_POOL_IDS := [
	"boss_roar", "ult_blast", "ult_cast", "totem_place", "mine_boom", "item_get", "cast_w",
	"cast_e", "ult_ready", "breach_open", "rank_up", "rally", "ui_buy", "amend_sign",
	"charge_perfect", "wave_call",
]

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
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	w = scene.instantiate() as LegionWorld
	root.add_child(w)
	await _frames(2)
	w.dev["no_waves"] = "1"
	w.dev["spawn_units"] = "0"
	w.start_map("_plots")
	await _frames(2)
	await _test_world_events()
	await _test_world_rng_live()
	await _test_variation()
	await _test_pool()
	await _test_pool_priority()
	await _test_ducking()
	_test_buses()
	_test_music_tracks()
	_test_synth()
	await _test_ui()
	await _test_current_fallback()
	await _test_warm_survives_reparent()
	Campaign.reset()
	SfxGen.clear_cache()
	print("LEGION AUDIO: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


func _sfx_id_of(p: AudioStreamPlayer) -> String:
	if p.stream == null:
		return ""
	return String(p.stream.get_meta(&"sfx_id", ""))


## Плеер, который этот вызов только что занял: заиграл заново или сменил поток.
func _started_player(a: Audio, before: Array) -> AudioStreamPlayer:
	var players: Array = a._sfx_players
	for i in players.size():
		var p: AudioStreamPlayer = players[i]
		var was: Dictionary = before[i]
		if p.playing and (not bool(was["playing"]) or p.stream != was["stream"]):
			return p
	return null


func _snapshot(a: Audio) -> Array:
	var out := []
	for p: AudioStreamPlayer in a._sfx_players:
		out.append({"playing": p.playing, "stream": p.stream})
	return out


## Число LegionCfg по имени (на старом коде константы нет — тест печатает FAIL, а не падает).
func _cfg(name: String, fallback: Variant) -> Variant:
	return (LegionCfg as Script).get_script_constant_map().get(name, fallback)


func _new_audio() -> Audio:
	var a := Audio.new()
	root.add_child(a)
	a.setup(false)
	return a


# ── (а) события боя ───────────────────────────────────────────────────────────

func _test_world_events() -> void:
	print("— (а) события боя → эффекты")
	var audio: LegionAudio = w.audio
	_check(audio != null, "у мира есть узел LegionAudio")
	if audio == null:
		return
	var key_signals := [
		&"hero_cast", &"rally_used", &"charge_impact", &"combo_changed", &"segment_broken",
		&"breach_warned", &"breach_opened", &"building_changed", &"spring_released",
		&"tab_erased", &"figure_ult", &"figure_slung", &"segment_torn", &"wave_called",
	]
	var missing := PackedStringArray()
	for s: StringName in key_signals:
		var hit := false
		for c: Dictionary in w.get_signal_connection_list(s):
			var cb: Callable = c["callable"]
			if cb.get_object() == audio:
				hit = true
		if not hit:
			missing.append(String(s))
	_check(missing.is_empty(), "ключевые сигналы мира подписаны в LegionAudio (нет: %s)"
		% ", ".join(missing))
	var subscribed := 0
	for sig: Dictionary in w.get_signal_list():
		for c: Dictionary in w.get_signal_connection_list(StringName(sig["name"])):
			if (c["callable"] as Callable).get_object() == audio:
				subscribed += 1
				break
	_check(subscribed >= 15 + key_signals.size() - 2,
		"подписано сигналов мира: %d (было 15)" % subscribed)

	# Зовём только обработчики LegionAudio (из списка подключений), а не emit: у тех же сигналов
	# есть другие слушатели (поле договоров, обучение), которым пустой договор — не событие.
	var rng_state := w.rng.state
	audio._call_counts.clear()
	_fire(audio, &"hero_cast", [0, Vector2(400, 300)])
	_fire(audio, &"hero_cast", [1, Vector2(400, 300)])
	_fire(audio, &"hero_cast", [2, Vector2(400, 300)])
	_fire(audio, &"rally_used", [Vector2(500, 300), 4])
	_fire(audio, &"charge_impact", [Vector2(500, 300), false])
	_fire(audio, &"charge_impact", [Vector2(520, 300), true])
	_fire(audio, &"combo_changed", [3, 1.2])
	_fire(audio, &"segment_broken", [null, 0, 5])
	_fire(audio, &"breach_warned", ["gate", 3.0, []])
	_fire(audio, &"breach_opened", ["gate"])
	_fire(audio, &"spring_released", [null, 0, 0.8])
	_fire(audio, &"tab_erased", [null, 2, 5])
	_fire(audio, &"figure_ult", [null])
	_fire(audio, &"figure_slung", [null])
	_fire(audio, &"segment_torn", [null, 0, 3])
	_fire(audio, &"wave_called", [1, 10])
	var hero := w.hero_of(w.local_side)
	if hero != null:
		for c: Dictionary in hero.get_signal_connection_list(&"cast_failed"):
			var cb: Callable = c["callable"]
			if cb.get_object() == audio:
				cb.call(0, &"no_target")
	await _frames(2)
	_check(w.rng.state == rng_state, "эффекты событий не сдвинули world.rng")
	w.souls = 1000
	var plot: Dictionary = w.staff.plots[0]
	var b := w.staff.build(plot, LegionCfg.KIND_LABORER)
	_check(b != null, "постройка для события «объект сдан» поставлена")
	await _frames(2)
	var events := {
		"hero_cast": "каст Ку/Дубль-вэ/Е", "rally": "«Сбор»", "charge_hit": "удар залпа",
		"charge_perfect": "точный срыв", "combo": "комбо", "segment_broken": "давка",
		"breach_warned": "предупреждение прорыва", "breach_opened": "прорыв открыт",
		"building": "постройка", "spring": "пружина", "tab_erased": "стирание Табом",
		"figure_ult": "заряженная фигура", "figure_slung": "рогатка", "segment_torn": "Юрист",
		"wave_called": "досрочный вызов волны", "cast_failed": "отказ каста",
	}
	for key: String in events:
		_check(audio._call_counts.has(key), "эффект «%s» (%s)" % [key, events[key]])
	_check(int(audio._call_counts.get("hero_cast", 0)) == 3, "каст: по эффекту на каждый слот")
	var ids := SfxGen.ids()
	var need_ids := ["charge", "charge_hit", "charge_perfect", "combo", "rally", "crush",
		"spring", "erase", "sling", "tear", "breach_warn", "breach_open", "wave_call", "build",
		"boss_roar", "rank_up", "amend_sign", "ui_hover", "ui_press", "ui_buy"]
	var no_ids := PackedStringArray()
	for id: String in need_ids:
		if not ids.has(id):
			no_ids.append(id)
	_check(no_ids.is_empty(), "синтез знает новые эффекты (нет: %s)" % ", ".join(no_ids))
	# натиск — свой звук, не молния Ку (SND-09)
	var src := (audio.get_script() as Script).source_code
	_check(not src.contains("_play(\"segment_released\", \"cast_q\")"),
		"натиск звучит своим эффектом, а не молнией Ку")
	_check(audio.has_method(&"ui"),
		"есть вход LegionAudio.ui(id) для экранов (разряд, поправка, покупка)")


## Тот же набор событий через НЕприглушённый узел, подключённый к миру (verifier 08.10: под
## --mute Audio.sfx() выходит до генератора, и проверка world.rng выше ничего не доказывала).
## Здесь эффекты реально занимают плееры и крутят свой генератор вариаций.
func _test_world_rng_live() -> void:
	print("— (а2) звук событий со включённым звуком не сдвигает world.rng")
	var lu := LegionAudio.new()
	root.add_child(lu)
	lu.setup_standalone(false, false)
	lu.attach_world(w)
	await _frames(1)
	var rng_state := w.rng.state
	var vary_state: int = lu._audio._sfx_rng.state
	_fire(lu, &"hero_cast", [0, Vector2(400, 300)])
	_fire(lu, &"rally_used", [Vector2(500, 300), 4])
	_fire(lu, &"charge_impact", [Vector2(500, 300), true])
	_fire(lu, &"combo_changed", [3, 1.2])
	_fire(lu, &"segment_broken", [null, 0, 5])
	_fire(lu, &"breach_opened", ["gate"])
	_fire(lu, &"tab_erased", [null, 2, 5])
	_fire(lu, &"figure_slung", [null])
	_fire(lu, &"segment_torn", [null, 0, 3])
	_fire(lu, &"wave_called", [1, 10])
	var playing := 0
	for p: AudioStreamPlayer in lu._audio._sfx_players:
		if p.playing:
			playing += 1
	_check(playing >= 8, "неприглушённый узел сыграл эффекты событий (%d плееров)" % playing)
	_check(lu._audio._sfx_rng.state != vary_state, "вариации крутят свой генератор")
	_check(w.rng.state == rng_state, "со звуком эффекты событий не сдвинули world.rng")
	lu.queue_free()
	await _frames(1)


## Вызвать обработчики сигнала `sig` мира, которые принадлежат узлу `audio`.
func _fire(audio: LegionAudio, sig: StringName, args: Array) -> void:
	for c: Dictionary in w.get_signal_connection_list(sig):
		var cb: Callable = c["callable"]
		if cb.get_object() == audio:
			cb.callv(args)


# ── (б) вариации ──────────────────────────────────────────────────────────────

func _test_variation() -> void:
	print("— (б) повтор одного эффекта звучит по-разному")
	var a := _new_audio()
	await _frames(1)
	var rng_state := w.rng.state
	var seen := []
	for i in 6:
		var before := _snapshot(a)
		a.sfx("enemy_die")
		var p := _started_player(a, before)
		if p != null:
			seen.append([snappedf(p.pitch_scale, 0.0001), snappedf(p.volume_db, 0.001)])
		OS.delay_msec(Audio.SFX_MIN_INTERVAL_MSEC + 15)
		await _frames(1)
	_check(seen.size() == 6, "каждый вызов занял плеер (%d/6)" % seen.size())
	if seen.size() >= 2:
		_check(seen[0] != seen[1], "два подряд вызова: высота/громкость разные %s vs %s"
			% [str(seen[0]), str(seen[1])])
	var pitches := {}
	var in_range := true
	for s: Array in seen:
		pitches[s[0]] = true
		in_range = in_range and float(s[0]) >= 0.85 and float(s[0]) <= 1.15
	_check(pitches.size() >= 4, "из 6 повторов разных высот: %d" % pitches.size())
	_check(in_range, "разброс высоты в пределах ±15 %")
	_check(w.rng.state == rng_state, "вариации не трогают world.rng")
	a.queue_free()
	await _frames(1)


# ── (в) пул ───────────────────────────────────────────────────────────────────

func _test_pool() -> void:
	print("— (в) пул не обрывает звучащее")
	var a := _new_audio()
	await _frames(1)
	var first: String = LONG_IDS[0]
	var first_stream := SfxGen.get_stream(first)
	for id: String in LONG_IDS:
		a.sfx(id)
	var alive := false
	for p: AudioStreamPlayer in a._sfx_players:
		if p.playing and (p.stream == first_stream or _sfx_id_of(p) == first):
			alive = true
	_check(alive, "после %d эффектов подряд первый (%s) ещё звучит" % [LONG_IDS.size(), first])
	OS.delay_msec(Audio.SFX_MIN_INTERVAL_MSEC + 15)
	a.sfx("enemy_die")
	OS.delay_msec(Audio.SFX_MIN_INTERVAL_MSEC + 15)
	a.sfx("enemy_die")
	var dupes := 0
	for p: AudioStreamPlayer in a._sfx_players:
		if p.playing and _sfx_id_of(p) == "enemy_die":
			dupes += 1
	_check(dupes >= 2, "два дубля одного эффекта звучат одновременно (%d)" % dupes)
	a.queue_free()
	await _frames(1)


## Полный пул: важное не вытесняется неважным (verifier 08.10: щелчок приоритета 0 обрывал рёв
## приоритета 3), а равное и более важное — вытесняет самое давнее.
func _test_pool_priority() -> void:
	print("— (в2) полный пул и приоритеты")
	# синтез заранее: иначе 16 синтезов подряд в вызовах длятся ~1 с реального времени, и
	# короткие звуки успевают доиграть до проверки (плеер Dummy играет в реальном времени)
	for id in SfxGen.ids():
		for v in SfxGen.variant_count(id):
			SfxGen.get_stream(id, v)
	var a := _new_audio()
	await _frames(1)
	# высота 0,5 — вдвое длиннее (≥ 0,9 с): на загруженной машине вызовы идут медленнее, и
	# короткие звуки иначе доигрывали бы до проверки, освобождая плеер
	for id: String in FULL_POOL_IDS:
		a.sfx(id, 0.5, 0.0, 3)
	var busy := 0
	for p: AudioStreamPlayer in a._sfx_players:
		if p.playing:
			busy += 1
	_check(busy == Audio.SFX_POOL_SIZE, "пул занят целиком: %d/%d" % [busy, Audio.SFX_POOL_SIZE])
	OS.delay_msec(Audio.SFX_MIN_INTERVAL_MSEC + 15)
	var click := a.sfx("skel_hit", 1.0, 0.0, 0)
	_check(click == null, "щелчок приоритета 0 не занял плеер, когда все важнее")
	_check(_playing_id(a, "boss_roar"), "рёв босса (приоритет 3) звучит дальше")
	var gong := a.sfx("wave_start", 1.0, 0.0, 3)
	_check(gong != null, "звук того же приоритета вытесняет самый давний")
	_check(not _playing_id(a, "boss_roar"), "самый давний (рёв) уступил место равному по важности"
		+ " (слот гонга %d, %s)" % [a._sfx_players.find(gong), _ids(a)])
	a.queue_free()
	await _frames(1)
	var b := _new_audio()
	await _frames(1)
	for id: String in FULL_POOL_IDS:
		b.sfx(id, 0.5)
	OS.delay_msec(Audio.SFX_MIN_INTERVAL_MSEC + 15)
	_check(b.sfx("skel_hit") != null, "пул обычных звуков: новый вытесняет самый давний")
	_check(not _playing_id(b, "boss_roar"), "вытеснен именно самый давний")
	b.queue_free()
	await _frames(1)


func _ids(a: Audio) -> String:
	var out := PackedStringArray()
	for p: AudioStreamPlayer in a._sfx_players:
		out.append(_sfx_id_of(p) if p.playing else "-")
	return ",".join(out)


func _playing_id(a: Audio, id: String) -> bool:
	for p: AudioStreamPlayer in a._sfx_players:
		if p.playing and _sfx_id_of(p) == id:
			return true
	return false


# ── (г) дакинг ────────────────────────────────────────────────────────────────

func _amplify_db() -> float:
	var idx := AudioServer.get_bus_index(&"Music")
	for i in AudioServer.get_bus_effect_count(idx):
		var fx := AudioServer.get_bus_effect(idx, i)
		if fx is AudioEffectAmplify:
			return (fx as AudioEffectAmplify).volume_db
	return INF


func _test_ducking() -> void:
	print("— (г) голос приглушает музыку")
	var la := LegionAudio.new()
	root.add_child(la)
	la.setup_standalone(false, false)
	la.play_menu_music()
	await _frames(3)
	_check(la.has_method(&"music_duck_db"), "у LegionAudio есть music_duck_db()")
	if not la.has_method(&"music_duck_db"):
		la.queue_free()
		return
	var base: float = la.call(&"music_duck_db")
	_check(absf(base) < 0.5, "без голоса музыка не приглушена (%.1f дБ)" % base)
	la.speech.voice(&"lg_wave_1", LegionCfg.AUDIO_V15_PRIORITY_TROOP, LegionAudio.VoiceClass.SHOUT)
	_check(la.speech.is_voice_busy(), "реплика пошла")
	for i in 20:
		OS.delay_msec(16)
		await process_frame
	var target: float = _cfg("AUDIO_DUCK_VOICE_DB", -6.0)
	var ducked: float = la.call(&"music_duck_db")
	_check(ducked <= target + 0.5 and target <= -4.0,
		"под голосом музыка ушла на %.1f дБ (цель %.1f)" % [ducked, target])
	var amp := _amplify_db()
	_check(amp <= target + 0.5,
		"шина Music: усиление %.1f дБ — приглушение дошло до микса" % amp)
	la.speech.stop_voice(0.0)
	for i in 70:
		OS.delay_msec(16)
		await process_frame
	var back: float = la.call(&"music_duck_db")
	_check(absf(back) < 0.5, "голос кончился — музыка вернулась (%.1f дБ)" % back)
	la.queue_free()
	await _frames(1)


# ── (д) шины ──────────────────────────────────────────────────────────────────

## Эффект класса `cls` на шине; `enabled_only` — только включённый (фильтр музыки драматургия
## выключает, когда он открыт, — его наличие проверяем без этого условия).
func _has_fx(bus: StringName, cls: String, enabled_only := true) -> AudioEffect:
	var idx := AudioServer.get_bus_index(bus)
	if idx < 0:
		return null
	for i in AudioServer.get_bus_effect_count(idx):
		var fx := AudioServer.get_bus_effect(idx, i)
		if fx.is_class(cls) and (not enabled_only or AudioServer.is_bus_effect_enabled(idx, i)):
			return fx
	return null


func _test_buses() -> void:
	print("— (д) лимитер и слои музыки")
	var lim := _has_fx(&"Master", "AudioEffectHardLimiter")
	_check(lim != null, "на Master стоит AudioEffectHardLimiter")
	if lim != null:
		_check((lim as AudioEffectHardLimiter).ceiling_db <= -0.5,
			"потолок лимитера ниже 0 dBFS (%.1f дБ)" % (lim as AudioEffectHardLimiter).ceiling_db)
	_check(_has_fx(&"Music", "AudioEffectAmplify") != null, "на Music — усиление (дакинг, слои)")
	_check(_has_fx(&"Music", "AudioEffectLowPassFilter", false) != null, "на Music — фильтр (драматургия)")
	var audio: LegionAudio = w.audio
	if audio != null and audio.has_method(&"music_layer_db"):
		var total := 5
		audio._on_wave_started(0, total)
		var early: float = audio.call(&"music_layer_db")
		var early_hz: float = audio.call(&"music_cutoff_hz")
		audio._on_wave_started(total - 1, total)
		var last: float = audio.call(&"music_layer_db")
		var last_hz: float = audio.call(&"music_cutoff_hz")
		_check(last > early and last_hz > early_hz,
			"последняя волна громче и ярче первой (%.1f→%.1f дБ, %d→%d Гц)"
			% [early, last, int(early_hz), int(last_hz)])
	else:
		_check(false, "у LegionAudio есть слои музыки по волнам (music_layer_db)")



# ── (к) треки music-1008 ──────────────────────────────────────────────────────

## Длинные петли (docs/dev/audit-1008/music-1008.md §4): объект — battle_a/b по месту в кампании,
## последняя волна — battle_final, босс — boss_long, меню — menu_long. Мир под --mute: трек не
## звучит, но выбор (_current_track) тот же.
func _test_music_tracks() -> void:
	print("— (к) выбор музыкальных треков")
	var audio: LegionAudio = w.audio
	var tracks: Dictionary = LegionAudio.MUSIC_TRACKS
	var missing := PackedStringArray()
	for key: String in ["menu", "battle_a", "battle_b", "battle_final", "boss", "victory", "defeat"]:
		if not tracks.has(key) or not ResourceLoader.exists(String(tracks[key])):
			missing.append(key)
	_check(missing.is_empty(), "все треки есть и грузятся (нет: %s)" % ", ".join(missing))
	_check(String(tracks.get("menu", "")).ends_with("menu_long.ogg")
		and String(tracks.get("boss", "")).ends_with("boss_long.ogg"), "меню и босс — длинные петли")
	var maps := Campaign.maps()
	if maps.size() >= 2:
		var id0 := String(maps[0]["id"])
		var id1 := String(maps[1]["id"])
		_check(LegionAudio.object_track_for(id0) == "battle_a"
			and LegionAudio.object_track_for(id1) == "battle_b",
			"объекты кампании чередуют battle_a/battle_b (%s, %s)" % [id0, id1])
	_check(LegionAudio.object_track_for("_plots") == LegionAudio.object_track_for("_plots"),
		"трек объекта вне кампании детерминирован")
	var saved_waves: Variant = w.map.get("waves", [])
	var plain := {"groups": [{"type": "zombie", "count": 1}]}
	var boss := {"groups": [{"type": "boss", "count": 1}]}
	w.map["waves"] = [plain, boss, plain, plain]
	audio._object_track = "battle_b"
	audio._on_wave_started(0, 4)
	_check(audio._current_track == "battle_b", "обычная волна — трек объекта (%s)" % audio._current_track)
	audio._on_wave_started(1, 4)
	_check(audio._current_track == "boss", "волна с боссом — boss_long (%s)" % audio._current_track)
	audio._on_wave_started(2, 4)
	_check(audio._current_track == "battle_b", "после босса — назад к треку объекта")
	audio._on_wave_started(3, 4)
	_check(audio._current_track == "battle_final", "последняя волна — battle_final")
	w.map["waves"] = [plain, boss]
	audio._on_wave_started(1, 2)
	_check(audio._current_track == "boss", "босс на последней волне — boss_long важнее battle_final")
	w.map["waves"] = saved_waves
	audio.play_menu_music()
	_check(audio._current_track == "menu", "экраны вне боя — menu_long")
	_check(LegionCfg.AUDIO_MUSIC_FINAL_WAVE_DB <= 1.5, "надбавка последней волны снижена (%.1f дБ)"
		% LegionCfg.AUDIO_MUSIC_FINAL_WAVE_DB)


# ── (е) синтез ────────────────────────────────────────────────────────────────

func _test_synth() -> void:
	print("— (е) синтез эффектов")
	var ids := SfxGen.ids()
	var bad := PackedStringArray()
	var prints := {}
	for id: String in ids:
		var m: Dictionary = SfxGen.measure(id)
		if float(m["peak"]) > 0.95 or float(m["peak"]) < 0.05 \
				or absf(float(m["first"])) > 0.02 or absf(float(m["last"])) > 0.02:
			bad.append("%s(пик %.2f)" % [id, float(m["peak"])])
		prints[hash(SfxGen.get_stream(id).data)] = id
	_check(bad.is_empty(), "пик 0,05–0,95, края у нуля (плохо: %s)" % ", ".join(bad))
	_check(prints.size() == ids.size(), "у всех %d эффектов разный звук (%d уникальных)"
		% [ids.size(), prints.size()])
	_check(SfxGen.MIX_RATE >= 44100, "частота синтеза %d Гц (верх не срезан)" % SfxGen.MIX_RATE)


# ── (ж) интерфейс ─────────────────────────────────────────────────────────────

func _test_ui() -> void:
	print("— (ж) кнопки интерфейса")
	var la := LegionAudio.new()
	root.add_child(la)
	la.setup_standalone(true, false)
	await _frames(1)
	var btn := Button.new()
	btn.text = "Проба"
	root.add_child(btn)
	await _frames(2)
	var hooked := false
	for c: Dictionary in btn.pressed.get_connections():
		var o: Object = (c["callable"] as Callable).get_object()
		if o != null and o != btn:
			hooked = true
	_check(hooked, "новая кнопка подписана на звук нажатия без правки экрана")
	la._call_counts.clear()
	btn.mouse_entered.emit()
	btn.pressed.emit()
	await _frames(1)
	_check(la._call_counts.has("ui_hover"), "наведение на кнопку звучит")
	_check(la._call_counts.has("ui_press"), "нажатие кнопки звучит")
	btn.queue_free()
	la.queue_free()
	await _frames(1)


# ── (з) текущий узел и прогрев ────────────────────────────────────────────────

## Освободился последний поднятый узел — текущим становится живой предыдущий (verifier 08.10).
func _test_current_fallback() -> void:
	print("— (з) LegionAudio.current() после освобождения")
	var a1 := LegionAudio.new()
	root.add_child(a1)
	a1.setup_standalone(true, false)
	var a2 := LegionAudio.new()
	root.add_child(a2)
	a2.setup_standalone(true, false)
	_check(LegionAudio.current() == a2, "текущий — последний поднятый")
	a2.queue_free()
	await _frames(1)
	_check(LegionAudio.current() == a1, "последний освобождён — текущим стал живой предыдущий")
	a1.queue_free()
	await _frames(1)


## Прогрев переживает перенос узла по дереву (verifier 08.10, probe_reparent.gd): LegionWorld при
## старте боя делает remove_child/add_child общему узлу звука — кэш синтеза не должен пропасть.
func _test_warm_survives_reparent() -> void:
	print("— (и) прогрев синтеза переживает перенос узла в мир")
	SfxGen.clear_cache()
	var menu := Node.new()
	var world_node := Node.new()
	root.add_child(menu)
	root.add_child(world_node)
	var la := LegionAudio.new()
	menu.add_child(la)
	la.setup_standalone(false, false)
	var t := Time.get_ticks_msec()
	while not la._audio.is_warm() and Time.get_ticks_msec() - t < 30000:
		OS.delay_msec(20)
		await process_frame
	await _frames(1)
	_check(SfxGen.has_cached("boss_roar", 1) and SfxGen.has_cached("ult_blast", 0),
		"прогрев в меню положил весь набор в кэш")
	la.get_parent().remove_child(la)
	world_node.add_child(la)
	await _frames(2)
	_check(SfxGen.has_cached("boss_roar", 1) and SfxGen.has_cached("rank_up", 0),
		"после переноса в мир кэш цел")
	var t0 := Time.get_ticks_usec()
	la._audio.sfx("ult_blast", 1.0, 0.0, 3)
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	_check(ms < 20.0, "первый ult_blast в бою без синтеза в кадре: %.1f мс" % ms)
	la.queue_free()
	menu.queue_free()
	world_node.queue_free()
	await _frames(1)
