class_name Audio
extends Node

## Звуковой слой игры: музыка (бой/передышка/победа/поражение), эффекты ударов
## и заклинаний, голосовые реплики некроманта/скелетов. Контракт вызовов
## фиксирован (его дёргает world.gd) — имена и сигнатуры методов не менять.

const SFX_POOL_SIZE := 8
# короче этого интервала повторный тот же sfx не проигрываем — иначе от частых
# ударов по толпе получается каша из наложенных друг на друга щелчков
const SFX_MIN_INTERVAL_MSEC := 60
const MUSIC_CROSSFADE_SEC := 0.8
const MUTE_DB := -80.0

const MUSIC_VOLUME_DB := -12.0
const SFX_VOLUME_DB := -6.0
const VOICE_VOLUME_DB := -3.0

# шины раскладки default_bus_layout.tres (F0): громкость каждой — в Settings, экран — P6
const BUS_MUSIC := &"Music"
const BUS_SFX := &"SFX"
const BUS_VOICE := &"Voice"

# музыкальные треки. loop=false у victory/defeat — это разовые стингеры,
# зацикливать их звучало бы нелепо после конца волны
## P7: battle2 (волны 5–9), boss (волна 10) и story (катсцены) — три трека, которых не было
## в срезе v6 (тогда играла одна battle на всю игру). Ассеты скопированы из assets/music/ в
## godot/assets/audio/music/ (docs/PROTOTYPE_PLAN.md §7 «поправка A» — тот же принцип для музыки:
## всё нужное лежит в res:// и в git). CfgStory.track_for_wave() решает, что играть — сюда не лезет.
## 04.10.2026 (D-1004-01, подготовка к открытой публикации): старые музыка (mp3) и реплики
## (Piper TTS, голос ruslan — датасет CC BY-NC-SA, irina — лицензия неизвестна) удалены из
## res://. В режиме «По истечении договора» они не звучали: LegionAudio берёт отсюда только sfx()
## (синтез SfxGen), музыка и голос v15 — свои (legion_audio.gd). Словари пустые — контракт тот же.
const MUSIC_FILES: Dictionary = {}
const MUSIC_LOOP: Dictionary = {
	"battle": true,
	"battle2": true,
	"boss": true,
	"calm": true,
	"story": true,
	"victory": false,
	"defeat": false,
}

# эффекты. Часть id из контракта (cauldron_hit, rune_draw, rune_fail, cast_q,
# cast_w, cast_e) намеренно отсутствует в словаре — под них нет подходящего
# исходника среди имеющихся файлов, id просто отработают молча (см. отчёт)
## Боевые звуки СИНТЕЗИРУЮТСЯ (SfxGen), а не берутся из файлов: в наборе проекта лежат
## только голосовые реплики, настоящих ударов/разрядов там нет вовсе. Подставлять вместо
## удара реплику скелета — обман, который слышно с первого боя.
## Здесь остаются только те id, у которых есть честный сэмпл.
const SFX_FILES: Dictionary = {}

# голосовые реплики; там, где есть несколько дублей — выбираем случайный,
# чтобы одна и та же фраза не приедалась за матч
## 04.10.2026 (D-1004-01, подготовка к открытой публикации): старые музыка (mp3) и реплики
## (Piper TTS, голос ruslan — датасет CC BY-NC-SA, irina — лицензия неизвестна) удалены из
## res://. В режиме «По истечении договора» они не звучали: LegionAudio берёт отсюда только sfx()
## (синтез SfxGen), музыка и голос v15 — свои (legion_audio.gd). Словари пустые — контракт тот же.
const VOICE_FILES: Dictionary = {}

var _muted := false
## Приоритет реплики, которая сейчас звучит (или последней, если плеер уже отыграл) — нужен
## voice(), чтобы решить, перебивать её новой заявкой или нет (СП: 3 диктор/HR > 2 некромант >
## 1 скелеты, EM §12). Живёт здесь, а не в SpeechSystem: только Audio знает, что реально играет.
var _voice_priority := 0

# пул переиспользуемых плееров эффектов — не создаём AudioStreamPlayer
# в кадре боя, только по кругу занимаем готовые
var _sfx_players: Array[AudioStreamPlayer] = []
var _sfx_next_index := 0
var _sfx_last_played_msec: Dictionary = {}

# два плеера музыки нужны только для кроссфейда: пока звучит старый трек,
# новый плавно нарастает поверх
var _music_players: Array[AudioStreamPlayer] = []
var _music_active_index := 0
var _music_streams: Dictionary[String, AudioStream] = {}
var _current_music := "none"
var _music_tween: Tween

var _voice_player: AudioStreamPlayer


func setup(muted: bool) -> void:
	# Держим потоки в памяти до боя: смена волны не должна синхронно читать MP3.
	for track: String in MUSIC_FILES:
		if not _music_streams.has(track):
			var stream := load(String(MUSIC_FILES[track])) as AudioStream
			if stream is AudioStreamMP3:
				(stream as AudioStreamMP3).loop = bool(MUSIC_LOOP.get(track, false))
			_music_streams[track] = stream
	_muted = muted
	for player in _sfx_players:
		player.queue_free()
	_sfx_players.clear()
	for i in range(SFX_POOL_SIZE):
		var player := AudioStreamPlayer.new()
		player.bus = BUS_SFX
		add_child(player)
		_sfx_players.append(player)
	_sfx_next_index = 0
	_sfx_last_played_msec.clear()

	for player in _music_players:
		player.queue_free()
	_music_players.clear()
	for i in range(2):
		var music_player := AudioStreamPlayer.new()
		music_player.bus = BUS_MUSIC
		add_child(music_player)
		_music_players.append(music_player)
	_music_active_index = 0
	_current_music = "none"

	if _voice_player != null:
		_voice_player.queue_free()
	_voice_player = AudioStreamPlayer.new()
	_voice_player.bus = BUS_VOICE
	add_child(_voice_player)
	_voice_priority = 0

	_apply_volumes()


## На выходе движок иначе ругается «2 ObjectDB instances were leaked / 1 resources still in
## use»: играющий AudioStreamPlayer держит поток MP3, и тот переживает очистку сцены
## (диагноз получен через --verbose, а не угадан). Останавливаем и отвязываем сами.
## Немедленно оборвать всё звучащее (закрытие окна, конец партии в агентном прогоне).
func silence_all() -> void:
	if _music_tween != null and _music_tween.is_valid():
		_music_tween.kill()
	for player in _music_players:
		player.stop()
		player.stream = null
	for player in _sfx_players:
		player.stop()
		player.stream = null
	if _voice_player != null:
		_voice_player.stop()
		_voice_player.stream = null


func _exit_tree() -> void:
	silence_all()
	SfxGen.clear_cache()


func play_music(track: String) -> void:
	if track == _current_music:
		return
	# в заглушённом прогоне музыку вообще не поднимаем: крутить MP3, который никто не слышит,
	# незачем, а на выходе движок ещё и ругался утечкой потока (проверено --verbose)
	if _muted:
		_current_music = track
		return
	if track == "none":
		_current_music = "none"
		var active_player := _music_players[_music_active_index]
		_fade_player_out(active_player)
		return
	if not MUSIC_FILES.has(track):
		return
	_current_music = track
	var stream: AudioStream = _music_streams.get(track)
	if stream == null:
		return

	var next_index: int = 1 - _music_active_index
	var prev_player := _music_players[_music_active_index]
	var next_player := _music_players[next_index]

	next_player.stream = stream
	next_player.volume_db = MUTE_DB
	next_player.play()

	var target_db := MUTE_DB if _muted else MUSIC_VOLUME_DB
	if _music_tween != null and _music_tween.is_valid():
		# убитый посреди кроссфейда tween не доигрывает свой chain-колбэк «остановить старый
		# трек» — без явного stop() прошлая музыка осталась бы играть под новой
		_music_tween.kill()
		for player in _music_players:
			if player != prev_player and player != next_player:
				player.stop()
		if prev_player.playing and prev_player.volume_db <= MUTE_DB + 1.0:
			prev_player.stop()
	_music_tween = create_tween()
	_music_tween.set_parallel(true)
	_music_tween.tween_property(next_player, "volume_db", target_db, MUSIC_CROSSFADE_SEC)
	if prev_player.playing:
		_music_tween.tween_property(prev_player, "volume_db", MUTE_DB, MUSIC_CROSSFADE_SEC)
		_music_tween.chain().tween_callback(prev_player.stop)

	_music_active_index = next_index


func sfx(id: String) -> void:
	if _muted:
		return
	var now_msec := Time.get_ticks_msec()
	var last_msec: int = int(_sfx_last_played_msec.get(id, -SFX_MIN_INTERVAL_MSEC * 10))
	if now_msec - last_msec < SFX_MIN_INTERVAL_MSEC:
		return
	var stream: AudioStream = SfxGen.get_stream(id)
	if stream == null and SFX_FILES.has(id):
		var path: String = SFX_FILES[id]
		if ResourceLoader.exists(path):
			stream = load(path)
	if stream == null:
		return
	_sfx_last_played_msec[id] = now_msec
	var player := _sfx_players[_sfx_next_index]
	_sfx_next_index = (_sfx_next_index + 1) % _sfx_players.size()
	player.stream = stream
	player.play()


## priority по умолчанию 2 (некромант) — так вели себя вызовы этого метода из world.gd ДО
## того, как P7 добавил приоритеты (q/w/e/win/lose/match_start/no_target/cauldron_panic;
## контракт world.gd менять нельзя, поэтому их фактический приоритет остаётся 2 — см.
## docs/port/DEBT_P7.md «Приоритет вызовов world.gd»). Возврат true — заявка принята (звук
## реально пошёл ИЛИ файла честно нет, но очередь считает реплику «сказанной» ради субтитра);
## false — более приоритетная реплика ещё звучит, заявку стоит вернуть в очередь (SpeechSystem).
func voice(id: String, priority: int = 2) -> bool:
	if _muted:
		return true
	if _voice_player.playing and priority < _voice_priority:
		return false
	if not VOICE_FILES.has(id):
		# неизвестный id — не наша забота (SpeechSystem не должен был звать); не считаем занятым
		return true
	var variants: Array = VOICE_FILES[id]
	if variants.is_empty():
		return true
	var path: String = variants[randi() % variants.size()]
	_voice_priority = priority
	if not ResourceLoader.exists(path):
		return true
	_voice_player.stream = load(path)
	_voice_player.play()
	return true


func set_muted(muted: bool) -> void:
	_muted = muted
	_apply_volumes()


func _apply_volumes() -> void:
	for player in _sfx_players:
		player.volume_db = MUTE_DB if _muted else SFX_VOLUME_DB
	if _music_players.size() > 0:
		_music_players[_music_active_index].volume_db = MUTE_DB if _muted else MUSIC_VOLUME_DB
	if _voice_player != null:
		_voice_player.volume_db = MUTE_DB if _muted else VOICE_VOLUME_DB


func _fade_player_out(player: AudioStreamPlayer) -> void:
	if not player.playing:
		return
	if _music_tween != null and _music_tween.is_valid():
		_music_tween.kill()
	_music_tween = create_tween()
	_music_tween.tween_property(player, "volume_db", MUTE_DB, MUSIC_CROSSFADE_SEC)
	_music_tween.tween_callback(player.stop)
