class_name LegionAudio
extends Node
##
## Звук и сочность режима «По истечении договора» (docs/legion/PACKETS_V13.md, пакет audio).
## Слушает сигналы LegionWorld и дёргает старый звуковой слой игры (`Audio` + `SfxGen`, скрипты
## `scripts/game/`) и обёртку `Juice` — их контракт менять нельзя (SLICE_SPEC §0), поэтому вместо
## правки держим свой узел `Audio` ребёнком и свою секцию чисел в `LegionCfg` (в конце файла).
##
## Симуляцию НЕ трогает: используются только камерная тряска (`Juice.shake`, чистый визуал —
## сдвиг камеры не читает игровая логика) и вспышка (`Juice.flash`, модулирует `modulate` самого
## `LegionWorld` — он и есть Node2D/CanvasItem, отдельного оверлея нет). `legion.tscn` без камеры
## (в отличие от старого `world.gd`, который её создаёт), поэтому `_ensure_camera()` идемпотентно
## заводит свою в центре мира — без неё `Juicee`-тряска молча гасится предупреждением «no Camera2D
## in viewport» и ничего не трясёт (см. `_ensure_camera()` ниже).
## `Juice.hit_stop` (замедление `Engine.time_scale`) здесь не вызывается ни разу — иначе смоук
## бота и приёмочный `--bench` считали бы разное время между прогонами со звуком и без.
##
## Музыка и голос v15 (пакет audio, 2026-09-25) — СВОИ, а не через `Audio`: у `Audio.MUSIC_FILES`
## и `Audio.VOICE_FILES` фиксированный контракт (COMMON.md п.8, `Audio` трогать нельзя), а новые
## треки/реплики лежат в `godot/assets/legion/{music,voice}/`. Поэтому `_play_music()` ниже больше
## не зовёт `_audio.play_music()` — держит собственную пару `AudioStreamPlayer` на шине `Music`
## (кроссфейд по образцу `audio.gd`, но отдельный код) — и добавлен публичный
## `voice(id, priority, класс)` на шине `Voice` (обе шины существуют в `default_bus_layout.tres`,
## слайдер громкости уже есть в Settings — трогать его не нужно). `voice()` резолвит путь по
## конвенции `res://assets/legion/voice/<id>.ogg` — будущим пакетам достаточно уронить файл и
## позвать id, правка кода не нужна (список зарезервированных id — в отчёте пакета audio).

## Класс реплики — кто кого режет и кто кого ждёт (правило координатора 26.09, см. voice()).
## Приоритет из LegionCfg.AUDIO_V15_PRIORITY_* — только ранжир ВНУТРИ класса.
enum VoiceClass {
	SHOUT,   ## выкрик боя: каст Ку/Дубль-вэ/Е, волна, простой, нехватка душ — только в тишине
	STORY,   ## сюжет: брифинг, босс в бою, итог боя, обучение, кадровик — ждёт в очереди
	SCENE,   ## кадр катсцены: всегда обрывает текущее и чистит очередь
}

# ── Свой музыкальный и голосовой слой v15 (константы — gdlint требует их перед var) ────────────
const MUSIC_DIR := "res://assets/legion/music/"
const MUSIC_TRACKS: Dictionary = {
	"menu": MUSIC_DIR + "menu.ogg",
	"battle": MUSIC_DIR + "battle.ogg",
	"boss": MUSIC_DIR + "boss.ogg",
	"victory": MUSIC_DIR + "victory.ogg",
	"defeat": MUSIC_DIR + "defeat.ogg",
}
const MUSIC_LOOP: Dictionary = {
	"menu": true, "battle": true, "boss": true, "victory": false, "defeat": false,
}
const MUTE_DB := -80.0
const MUSIC_VOLUME_DB := -12.0
const VOICE_DIR := "res://assets/legion/voice/"
const VOICE_VOLUME_DB := -3.0
## Шаги обучения узнаются по имени: новый шаг заменяет в очереди устаревший (см. _enqueue_voice).
const TUTORIAL_VOICE_PREFIX := "lg_tut_"

var world: LegionWorld
var _audio: Audio
var _log_enabled := false
var _last_played_msec: Dictionary = {}  # event key -> Time.get_ticks_msec()
var _call_counts: Dictionary = {}       # event key -> сколько раз сигнал СРАБОТАЛ (не «сыграно»)
var _play_counts: Dictionary = {}       # event key -> сколько раз реально дошло до Audio.sfx()
var _log_t := 0.0
var _release_pending := false
var _current_track := "none"            # свой учёт — не лезем в приватное поле Audio

var _muted := false
var _music_players: Array[AudioStreamPlayer] = []
var _music_active_index := 0
var _music_streams: Dictionary = {}
var _music_tween: Tween

var _voice_player: AudioStreamPlayer
var _voice_priority := 0
var _voice_class: VoiceClass = VoiceClass.SHOUT
var _voice_id: StringName = &""
## До этого Time.get_ticks_msec() последняя запущенная реплика ещё «звучит» (is_voice_busy) —
## по длине файла, а не AudioStreamPlayer.playing (под --mute плеер не играет вовсе, и занятость
## по .playing сделала бы любой --mute-тест очереди пустым).
var _voice_busy_until_msec := 0
## Очередь сюжетных реплик: [{id, priority, at, seq}], голова — следующая. Порядок — приоритет
## по убыванию, при равном — кто раньше встал (seq). Ёмкость и срок годности — LegionCfg.
## Разбирает `_process()`, когда голос свободен и дерево не на паузе.
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
var _voice_last_msec: Dictionary = {}  # id -> Time.get_ticks_msec() своего последнего проигрывания
## Свой генератор для выбора реплик: world.rng — генератор СИМУЛЯЦИИ, каждый лишний вызов из звука
## сдвигает бой и ломает детерминизм серий ботом и тестов (так упал прогон обучения на v15).
var _voice_rng := RandomNumberGenerator.new()
## integrate1: известные постройки участков → уровень (новая — «объект сдан», выше — «улучшение»).
var _building_levels: Dictionary = {}
var _idle_check_t := 0.0
## Время боя (world.now) последней реплики простоя: пауза и ускорение времени считаются честно.
var _idle_voice_at := 0.0
## B-059: пауза одиночки держит звучащую реплику (stream_paused) — узел под миром с
## PROCESS_MODE_ALWAYS, сам плеер на паузе иначе играл бы поверх меню.
var _voice_held := false
var _voice_hold_at := 0


func setup(w: LegionWorld) -> void:
	setup_standalone(w.args.has("mute"), w.args.has("trace") or w.dev.has("audio_log"))
	attach_world(w)


## polish1 (находка ревью 25.09.2026): музыка/голос без мира — этот узел раньше заводился
## только вместе с боем (`setup(w)` требовал `LegionWorld`), поэтому вступительная катсцена,
## «Контора», герой и меню кампании были немы до первого боя. `LegionMain` теперь держит ОДИН
## узел на весь сеанс (создаёт им через этот метод, ещё до существования мира) и передаёт его
## в мир через `attach_world()`, когда бой стартует первый раз — вместо того чтобы мир заводил
## свой второй узел (см. `LegionWorld._build()`).
func setup_standalone(muted: bool, log_enabled: bool) -> void:
	_muted = muted
	_log_enabled = log_enabled
	_audio = Audio.new()
	add_child(_audio)
	_audio.setup(_muted)
	_setup_music()
	_setup_voice()


## Подключает уже готовый (возможно, созданный до мира — `setup_standalone()`) узел к сигналам
## боя и камере тряски. Идемпотентно: `LegionMain` держит мир один на весь сеанс кампании (создаёт
## один раз, дальше переиспользует), поэтому повторного вызова в обычном потоке не бывает, но
## защита не помешает.
func attach_world(w: LegionWorld) -> void:
	if world != null:
		return
	world = w
	_ensure_camera()
	world.match_started.connect(_on_match_started)
	world.match_ended.connect(_on_match_ended)
	world.wave_started.connect(_on_wave_started)
	world.wave_cleared.connect(_on_wave_cleared)
	world.cauldron_hit.connect(_on_cauldron_hit)
	world.contract_created.connect(_on_contract_created)
	world.segment_released.connect(_on_segment_released)
	world.unit_died.connect(_on_unit_died)
	world.foe_died.connect(_on_foe_died)
	world.boss_roared.connect(_on_boss_roared)
	world.boss_rammed.connect(_on_boss_rammed)
	# tutfix (item 6, правка чужого файла отчётом): раньше музыка боя/босса продолжала играть
	# в меню — трек менялся только по match_started/match_ended/wave_started, а go_to_menu() их
	# не шлёт (находка ревью 24.09.2026).
	world.menu_entered.connect(_on_menu_entered)
	# integrate1: озвучка событий v15 (каст героя, постройки, души, простой)
	world.hero_cast.connect(_on_hero_cast)
	world.building_changed.connect(_on_building_changed)
	world.souls_short.connect(_on_souls_short)
	# D-0927-140: способности не хватило маны — короткий «отказ» руны (реплики под это нет)
	world.mana_short.connect(func(_slot: int) -> void: _play("mana_short", "rune_fail"))
	world.match_started.connect(func(_id: String) -> void:
		_building_levels.clear()
		_idle_voice_at = world.now)


func _process(delta: float) -> void:
	_run_clock()
	_hold_voice_on_pause()
	_flush_voice_queue()
	_tick_idle_voice(delta)
	if not _log_enabled:
		return
	_log_t -= delta
	if _log_t <= 0.0:
		_log_t = LegionCfg.TRACE_PERIOD
		_print_counters()


func _print_counters() -> void:
	var parts := PackedStringArray()
	for key in _call_counts.keys():
		parts.append("%s=%d/%d" % [key, int(_play_counts.get(key, 0)), int(_call_counts[key])])
	print("AUDIO " + " ".join(parts))


# ── Сигналы мира ─────────────────────────────────────────────────────────────

func _on_match_started(map_id: String) -> void:
	_play_music("battle")
	# Новый бой — прошлые заявки (шаг обучения, «объект сдан» прошлой карты) уже не про него.
	clear_voice_queue()
	voice(StringName("lg_brief_%s" % map_id), LegionCfg.AUDIO_V15_PRIORITY_NARRATOR, VoiceClass.STORY)


func _on_match_ended(victory: bool, _stats: Dictionary) -> void:
	_play_music("victory" if victory else "defeat")
	# Один из двух дублей на исход (докстрин класса, §audio): рассказчик даёт сводку конторы,
	# некромант — личную реакцию. Оба не звучат разом — voice() всё равно держит один голос.
	# Сюжет, не сцена: финальная катсцена кампании идёт сразу следом и своим кадром обрывает её.
	var ids := ["lg_victory_1", "lg_victory_2"] if victory else ["lg_defeat_1", "lg_defeat_2"]
	var prio_narrator := LegionCfg.AUDIO_V15_PRIORITY_NARRATOR
	var priority: int = prio_narrator if victory else LegionCfg.AUDIO_V15_PRIORITY_HR
	voice(StringName(ids[_voice_rng.randi() % ids.size()]), priority, VoiceClass.STORY)


func _on_menu_entered() -> void:
	_play_music("menu")
	silence_for_menu()


## Уход в главное меню: реплика боя/кампании в меню — шум (находка verifier 26.09: она звучала
## поверх меню и утекала в следующий бой). Очередь — прочь, текущая — коротким спадом, не
## доигрывать: 7-11-секундная реплика про бой над кнопками меню хуже, чем обрыв на 0.25 с.
func silence_for_menu() -> void:
	stop_voice(LegionCfg.AUDIO_V15_VOICE_MENU_FADE_SEC)


## polish1: публичный вход для экранов кампании вне боя (меню, карты, брифинг, «Контора», герой)
## — все зовут этот метод, трек один и тот же, повторный вызов, пока он уже играет, ничего не
## перезапускает (`_play_music()` сам сверяет `_current_track`).
func play_menu_music() -> void:
	_play_music("menu")


func _on_wave_started(i: int, _total: int) -> void:
	_play("wave_started", "wave_start")
	if _wave_has_boss(i):
		_play_music("boss")
		# Сюжет: появление босса обрывает выкрик (каст), но ждёт брифинга/обучения, не режет их.
		voice(&"lg_boss_appear", LegionCfg.AUDIO_V15_PRIORITY_BOSS, VoiceClass.STORY)
	else:
		_play_music("battle")
		# «Иногда» (DESIGN_V15 §9): не на каждую волну, иначе строй бубнит без остановки. Выкрик:
		# если голос занят, реплика просто пропадает — через 10 с она уже не к месту.
		if _voice_rng.randf() < 0.4:
			var wave_ids := ["lg_wave_1", "lg_wave_2", "lg_wave_3"]
			voice(StringName(wave_ids[_voice_rng.randi() % wave_ids.size()]),
				LegionCfg.AUDIO_V15_PRIORITY_TROOP, VoiceClass.SHOUT)


func _on_wave_cleared(_i: int) -> void:
	_play("wave_cleared", "wave_clear")


## Артефакт долетел в полоску (LegionItemBar._land) — звук находки.
func play_item() -> void:
	_play("item_gained", "item_get")


func _on_cauldron_hit(amount: float) -> void:
	_play("cauldron_hit", "cauldron_hit")
	var strength: float = clampf(
		LegionCfg.AUDIO_CAULDRON_SHAKE_MIN + amount * LegionCfg.AUDIO_CAULDRON_SHAKE_PER_DMG,
		LegionCfg.AUDIO_CAULDRON_SHAKE_MIN, LegionCfg.AUDIO_CAULDRON_SHAKE_MAX)
	Juice.shake(world, strength, LegionCfg.AUDIO_CAULDRON_SHAKE_DURATION)
	Juice.flash(world, LegionCfg.AUDIO_CAULDRON_FLASH_COLOR, LegionCfg.AUDIO_CAULDRON_FLASH_DURATION)


func _on_contract_created(_c: Contract) -> void:
	_play("contract_created", "rune_draw")


func _on_segment_released(_c: Contract, _seg: int, n_units: int) -> void:
	if n_units <= 0 or _release_pending:
		return
	# Растаявшая линия шлёт по сигналу на участок: один отклик на событие кадра.
	_release_pending = true
	_flush_release.call_deferred()


func _flush_release() -> void:
	_release_pending = false
	_play("segment_released", "cast_q")
	Juice.shake(world, LegionCfg.AUDIO_SEGMENT_SHAKE, LegionCfg.AUDIO_SEGMENT_SHAKE_DURATION)


func _on_unit_died(_unit: Legionnaire) -> void:
	# нет отдельного сигнала "удар печатью" (SLICE_SPEC §3) — гибель бойца в бою и есть тот
	# самый удар нотариуса по строю, честной альтернативы контракту сигналов нет
	_play("unit_died", "skel_hit")


func _on_foe_died(foe: Foe) -> void:
	_play("foe_died", "enemy_die")
	if foe != null and foe.type_id == "boss":
		Juice.shake(world, LegionCfg.AUDIO_BOSS_DEATH_SHAKE, LegionCfg.AUDIO_BOSS_DEATH_SHAKE_DURATION)
		Juice.flash(world, LegionCfg.AUDIO_BOSS_DEATH_FLASH_COLOR,
			LegionCfg.AUDIO_BOSS_DEATH_FLASH_DURATION)


## Рёв (пакет crypt) — предупреждение за BOSS_RAM_WARN до тарана. Умеренная тряска: игрок
## должен читать её как «сейчас будет удар», не как сам удар.
func _on_boss_roared(_foe: Foe, _target: Vector2) -> void:
	_play("boss_roared", "ult_cast")
	Juice.shake(world, LegionCfg.AUDIO_BOSS_ROAR_SHAKE, LegionCfg.AUDIO_BOSS_ROAR_SHAKE_DURATION)


## Сам таран (пакет crypt) — удар звуком и тряской заметнее сегмента, но слабее смерти босса.
func _on_boss_rammed(_foe: Foe, _target: Vector2) -> void:
	_play("boss_rammed", "mine_boom")
	Juice.shake(world, LegionCfg.AUDIO_BOSS_RAM_SHAKE, LegionCfg.AUDIO_BOSS_RAM_SHAKE_DURATION)


## `legion.tscn` — голый `Node2D` без камеры (никто её не создаёт: grep по scripts/legion/*.gd
## и сцене — ноль совпадений на Camera2D), поэтому `Juicee`-тряска (`JuiceeShakeEffect._apply()`)
## молча гасится: `get_viewport().get_camera_2d()` возвращает null, эффект уходит через
## `push_warning` и ничего не трясёт. Ставим свою — идемпотентно (на случай, если камеру заведёт
## другой пакет раньше нас), позиционируем в центр мира (`LegionCfg.WORLD_SIZE * 0.5`), как
## делает старый `world.gd` для классического режима.
func _ensure_camera() -> void:
	if world.get_viewport().get_camera_2d() != null:
		return
	var cam := Camera2D.new()
	cam.name = "LegionAudioCam"
	cam.position = LegionCfg.WORLD_SIZE * 0.5
	cam.enabled = true
	world.add_child(cam)


# ── Внутреннее ────────────────────────────────────────────────────────────────

## Играет `sfx_id`, если с прошлого проигрывания этого `event_key` прошло достаточно
## (`LegionCfg.AUDIO_EVENT_INTERVAL_MSEC`) — свой лимит ПО ТИПУ события поверх общего
## 60-мс лимита `Audio.sfx()` (см. докстринг секции AUDIO в legion_cfg.gd).
func _play(event_key: String, sfx_id: String) -> void:
	_call_counts[event_key] = int(_call_counts.get(event_key, 0)) + 1
	var now_msec := Time.get_ticks_msec()
	var interval: int = int(LegionCfg.AUDIO_EVENT_INTERVAL_MSEC.get(event_key, 0))
	var last_msec: int = int(_last_played_msec.get(event_key, -interval * 10))
	if now_msec - last_msec < interval:
		return
	_last_played_msec[event_key] = now_msec
	_play_counts[event_key] = int(_play_counts.get(event_key, 0)) + 1
	_audio.sfx(sfx_id)


## Свой кроссфейд (не Audio.play_music() — новые треки v15 в её MUSIC_FILES не заводим,
## см. докстринг класса): те же грабли, что у audio.gd — повторный вызов с тем же треком
## не должен перезапускать проигрывание.
func _play_music(track: String) -> void:
	if track == _current_track:
		return
	_current_track = track
	if _muted:
		return
	if track == "none" or not MUSIC_TRACKS.has(track):
		var active := _music_players[_music_active_index]
		_fade_music_out(active)
		return
	var stream: AudioStream = _music_streams.get(track)
	if stream == null:
		return
	var next_index: int = 1 - _music_active_index
	var prev_player := _music_players[_music_active_index]
	var next_player := _music_players[next_index]
	next_player.stream = stream
	next_player.volume_db = MUTE_DB
	next_player.play()
	if _music_tween != null and _music_tween.is_valid():
		_music_tween.kill()
		for p in _music_players:
			if p != prev_player and p != next_player:
				p.stop()
	_music_tween = create_tween()
	_music_tween.set_parallel(true)
	_music_tween.tween_property(next_player, "volume_db", MUSIC_VOLUME_DB,
		LegionCfg.AUDIO_V15_MUSIC_CROSSFADE_SEC)
	if prev_player.playing:
		_music_tween.tween_property(prev_player, "volume_db", MUTE_DB,
			LegionCfg.AUDIO_V15_MUSIC_CROSSFADE_SEC)
		_music_tween.chain().tween_callback(prev_player.stop)
	_music_active_index = next_index


func _fade_music_out(player: AudioStreamPlayer) -> void:
	if not player.playing:
		return
	if _music_tween != null and _music_tween.is_valid():
		_music_tween.kill()
	_music_tween = create_tween()
	_music_tween.tween_property(player, "volume_db", MUTE_DB, LegionCfg.AUDIO_V15_MUSIC_CROSSFADE_SEC)
	_music_tween.tween_callback(player.stop)


func _setup_music() -> void:
	for track: String in MUSIC_TRACKS:
		var path: String = MUSIC_TRACKS[track]
		if not ResourceLoader.exists(path):
			continue
		var stream := load(path) as AudioStream
		if stream is AudioStreamOggVorbis:
			(stream as AudioStreamOggVorbis).loop = bool(MUSIC_LOOP.get(track, false))
		_music_streams[track] = stream
	for i in range(2):
		var p := AudioStreamPlayer.new()
		p.bus = &"Music"
		add_child(p)
		_music_players.append(p)
	_music_active_index = 0
	_current_track = "none"


func _setup_voice() -> void:
	_voice_player = AudioStreamPlayer.new()
	_voice_player.bus = &"Voice"
	add_child(_voice_player)
	_voice_base_db = _voice_player.volume_db
	_voice_priority = 0
	_voice_class = VoiceClass.SHOUT
	_voice_id = &""
	_voice_busy_until_msec = 0
	_voice_queue.clear()
	_run_clock_at = Time.get_ticks_msec()


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
func voice(id: StringName, priority: int = 0, cls: VoiceClass = VoiceClass.SHOUT) -> void:
	if _log_enabled:
		print("VOICE ", id, " prio=", priority, " class=", VoiceClass.keys()[cls])
	match cls:
		VoiceClass.SCENE:
			clear_voice_queue()
			if is_voice_busy() and id == _voice_id:
				_voice_class = VoiceClass.SCENE
				_voice_priority = priority
				return
			_cut_voice()
			_start_voice(id, priority, cls, true)
		VoiceClass.STORY:
			if not _can_start(id):
				return
			if is_voice_busy() and _voice_class != VoiceClass.SHOUT:
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
			if not _can_start(id):
				return
			if is_voice_busy():
				if _voice_class == VoiceClass.SHOUT and priority > _voice_priority:
					_start_voice(id, priority, cls)
				return
			if _voice_queue.is_empty():
				_start_voice(id, priority, cls)


## Одна реплика из набора — своим генератором (_voice_rng), не world.rng (COMMON п.9а).
func voice_any(ids: Array, priority: int = 0, cls: VoiceClass = VoiceClass.SHOUT) -> void:
	if ids.is_empty():
		return
	voice(StringName(String(ids[_voice_rng.randi() % ids.size()])), priority, cls)


## true — последняя запущенная реплика ещё звучит (по длине файла, см. _voice_busy_until_msec).
func is_voice_busy() -> bool:
	return Time.get_ticks_msec() < _voice_busy_until_msec


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
	if is_voice_busy() and _voice_class == VoiceClass.SCENE:
		stop_voice(LegionCfg.AUDIO_V15_VOICE_MENU_FADE_SEC, false)


## Замолчать: очередь — прочь (если `clear_queue`), текущую реплику — спадом за `fade_sec`
## (0 — сразу). Уход в меню, конец катсцены.
func stop_voice(fade_sec: float = 0.0, clear_queue := true) -> void:
	if clear_queue:
		clear_voice_queue()
	_voice_busy_until_msec = 0
	_voice_id = &""
	if fade_sec <= 0.0 or _muted or not _voice_player.playing:
		_cut_voice()
		return
	_kill_voice_fade()
	_voice_fade = create_tween()
	_voice_fade.tween_property(_voice_player, "volume_db", MUTE_DB, fade_sec)
	_voice_fade.tween_callback(_cut_voice)


func _can_start(id: StringName) -> bool:
	if not ResourceLoader.exists(VOICE_DIR + String(id) + ".ogg"):
		return false
	var last_msec: int = int(_voice_last_msec.get(id, -LegionCfg.AUDIO_V15_VOICE_COOLDOWN_MSEC * 10))
	return Time.get_ticks_msec() - last_msec >= LegionCfg.AUDIO_V15_VOICE_COOLDOWN_MSEC


func _start_voice(id: StringName, priority: int, cls: VoiceClass, ignore_cooldown := false) -> bool:
	if ignore_cooldown:
		if not ResourceLoader.exists(VOICE_DIR + String(id) + ".ogg"):
			return false
	elif not _can_start(id):
		return false
	var now_msec := Time.get_ticks_msec()
	_voice_last_msec[id] = now_msec
	_voice_priority = priority
	_voice_class = cls
	_voice_id = id
	# Длина файла читается из ресурса (не AudioStreamPlayer.playing): под --mute плеер не играет
	# вовсе, а is_voice_busy() (и тестам) нужен тот же сигнал «ещё звучит», что в настоящем прогоне.
	var stream: AudioStream = load(VOICE_DIR + String(id) + ".ogg")
	var len_msec := int(stream.get_length() * 1000.0) if stream != null else 0
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
	var now := Time.get_ticks_msec()
	_voice_held = p
	if p:
		_voice_hold_at = now
		_voice_player.stream_paused = true
		return
	_voice_player.stream_paused = false
	if _voice_busy_until_msec > _voice_hold_at:
		_voice_busy_until_msec += now - _voice_hold_at


## Часы «без паузы» (мс): отрезок с прошлого учёта засчитывается, только если тогда дерево не
## было на паузе. Учёт — каждый кадр (_process) и при каждой постановке/разборе очереди, так что
## погрешность — не больше кадра на границе паузы.
func _run_clock() -> int:
	var t := Time.get_ticks_msec()
	if not _run_clock_paused:
		_run_clock_msec += t - _run_clock_at
	_run_clock_at = t
	_run_clock_paused = is_inside_tree() and get_tree().paused
	return _run_clock_msec


## Голос свободен и игра не на паузе — следующая годная запись очереди. Пауза: мир держит
## PROCESS_MODE_ALWAYS (и этот узел под ним), так что _process крутится и на паузе — без этой
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
		if _start_voice(e["id"], int(e["priority"]), VoiceClass.STORY):
			return


# ── integrate1: озвучка событий v15 ───────────────────────────────────────────

func _on_hero_cast(slot: int, _at: Vector2) -> void:
	var letter: String = ["q", "w", "e"][clampi(slot, 0, 2)]
	voice_any(["lg_cast_%s_1" % letter, "lg_cast_%s_2" % letter],
		LegionCfg.AUDIO_V15_PRIORITY_NECROMANCER, VoiceClass.SHOUT)


func _on_building_changed(obj: Object) -> void:
	var b := obj as LegionBuilding
	if b == null or b.source != LegionBuilding.SOURCE_PLOT:
		return
	var key := b.get_instance_id()
	if not world.buildings.has(b):
		_building_levels.erase(key)   # продана
		return
	if not _building_levels.has(key):
		_building_levels[key] = b.level
		# Сюжет (событие кадровика): ждёт конца текущей реплики — оно не устаревает так быстро,
		# как боевой выкрик.
		voice(&"lg_building_ready", LegionCfg.AUDIO_V15_PRIORITY_HR, VoiceClass.STORY)
	elif b.level > int(_building_levels[key]):
		_building_levels[key] = b.level
		voice(&"lg_upgrade_done", LegionCfg.AUDIO_V15_PRIORITY_HR, VoiceClass.STORY)


func _on_souls_short() -> void:
	voice(&"lg_souls_low", LegionCfg.AUDIO_V15_PRIORITY_NECROMANCER, VoiceClass.SHOUT)


## Простой армии: значок простоя core (FREE дольше IDLE_NOTICE_TIME) у заметной части армии —
## «Простой... опять», не чаще AUDIO_IDLE_VOICE_GAP секунд боя (и не в первые столько же — на
## старте армия стоит, пока игрок не начертил договор). Проверка раз в секунду, без world.rng.
func _tick_idle_voice(delta: float) -> void:
	if world == null or world.phase != LegionWorld.Phase.BATTLE or world.paused:
		return
	_idle_check_t -= delta
	if _idle_check_t > 0.0:
		return
	_idle_check_t = 1.0
	if world.now - _idle_voice_at < LegionCfg.AUDIO_IDLE_VOICE_GAP:
		return
	var idle := 0
	for u in world.units:
		if u.alive and u.state == Legionnaire.State.FREE and u.idle_time >= LegionCfg.IDLE_NOTICE_TIME:
			idle += 1
	if idle >= LegionCfg.AUDIO_IDLE_VOICE_MIN_UNITS:
		_idle_voice_at = world.now
		voice(&"lg_idle", LegionCfg.AUDIO_V15_PRIORITY_TROOP, VoiceClass.SHOUT)


func _wave_has_boss(i: int) -> bool:
	var waves: Array = world.map.get("waves", [])
	if i < 0 or i >= waves.size():
		return false
	var groups: Array = waves[i].get("groups", [])
	for g in groups:
		if String(g.get("type", "")) == "boss":
			return true
	return false
