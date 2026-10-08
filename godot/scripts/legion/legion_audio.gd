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
## (кроссфейд по образцу `audio.gd`, но отдельный код) — и голос `speech.voice(id, priority,
## класс)` на шине `Voice` (обе шины существуют в `default_bus_layout.tres`, слайдер громкости
## уже есть в Settings — трогать его не нужно). Голосовой контур — узел-ребёнок `speech`
## (LegionVoice, legion_voice.gd, D-1008-S15: вынесен за лимиты gdlint); здесь остались класс
## реплики `VoiceClass` и папка `VOICE_DIR` — их имена зовут экраны, катсцены и тесты.
##
## Звук к Steam (аудит 08.10, docs/dev/audit-1008/audio.md): эффекты всех ключевых действий
## (каст, «Сбор», удар и точный срыв залпа, комбо лестницей высоты, давка, прорыв, постройка,
## Таб, рогатка, Юрист, досрочный вызов, отказ каста), звуки интерфейса через LegionUiSfx и вход
## `LegionAudio.ui(id)` для экранов (разряд, подпись поправки, покупка), дакинг музыки под голос
## и «большие моменты», драматургия волн фильтром и громкостью на шине Music (эффекты шин —
## default_bus_layout.tres, на Master — лимитер). Числа — секция «Звук к Steam» в LegionCfg.

## Класс реплики — кто кого режет и кто кого ждёт (правило координатора 26.09,
## см. LegionVoice.voice()).
## Приоритет из LegionCfg.AUDIO_V15_PRIORITY_* — только ранжир ВНУТРИ класса.
enum VoiceClass {
	SHOUT,   ## выкрик боя: каст Ку/Дубль-вэ/Е, волна, простой, нехватка душ — только в тишине
	STORY,   ## сюжет: брифинг, босс в бою, итог боя, обучение, кадровик — ждёт в очереди
	SCENE,   ## кадр катсцены: всегда обрывает текущее и чистит очередь
}

# ── Свой музыкальный и голосовой слой v15 (константы — gdlint требует их перед var) ────────────
const MUSIC_DIR := "res://assets/legion/music/"
## music-1008 (SND-04, docs/dev/audit-1008/music-1008.md): длинные петли 84–111 с вместо 38–43 с.
## Обычный бой — battle_a/battle_b по объектам (_object_track_for), последняя волна — battle_final,
## босс — boss_long, все экраны вне боя — menu_long; стингеры итога прежние. Старые menu/battle/
## boss.ogg остаются в папке (решение о переносе — за Игорем), здесь не звучат.
const MUSIC_TRACKS: Dictionary = {
	"menu": MUSIC_DIR + "menu_long.ogg",
	"battle_a": MUSIC_DIR + "battle_a.ogg",
	"battle_b": MUSIC_DIR + "battle_b.ogg",
	"battle_final": MUSIC_DIR + "battle_final.ogg",
	"boss": MUSIC_DIR + "boss_long.ogg",
	"victory": MUSIC_DIR + "victory.ogg",
	"defeat": MUSIC_DIR + "defeat.ogg",
}
const MUSIC_LOOP: Dictionary = {
	"menu": true, "battle_a": true, "battle_b": true, "battle_final": true, "boss": true,
	"victory": false, "defeat": false,
}
const MUTE_DB := -80.0
const MUSIC_VOLUME_DB := -12.0
const VOICE_DIR := "res://assets/legion/voice/"
## Эффект каста по слоту: Ку — треск разряда, Дубль-вэ — подъём «воскрешения», Е — гул аврала
## (cast_w и cast_e были синтезированы, но нигде не звучали — SND-10).
const CAST_SFX := ["cast_q", "cast_w", "cast_e"]

## Последний поднятый узел (в игре он один на сеанс — LegionMain): через него экраны зовут
## `LegionAudio.ui(id)`, не держа ссылку, а LegionUiSfx решает, чей узел озвучивает кнопки.
## Все поднятые узлы по порядку: освободился последний — текущим становится предыдущий живой
## (verifier 08.10: одна ссылка обнулялась, хотя другой узел жил).
static var _instances: Array = []

var world: LegionWorld
## Голосовой контур (реплики, очередь, фразы обучения) — узел-ребёнок, D-1008-S15.
var speech: LegionVoice
var _audio: Audio
var _log_enabled := false
var _last_played_msec: Dictionary = {}  # event key -> FxClock.ms()
var _call_counts: Dictionary = {}       # event key -> сколько раз сигнал СРАБОТАЛ (не «сыграно»)
var _play_counts: Dictionary = {}       # event key -> сколько раз реально дошло до Audio.sfx()
var _log_t := 0.0
var _release_pending := false
var _current_track := "none"            # свой учёт — не лезем в приватное поле Audio
## Трек обычных волн этого объекта (battle_a/battle_b) — выбирается на старте боя.
var _object_track := "battle_a"

var _muted := false
var _music_players: Array[AudioStreamPlayer] = []
var _music_active_index := 0
var _music_streams: Dictionary = {}
var _music_tween: Tween

## integrate1: известные постройки участков → уровень (новая — «объект сдан», выше — «улучшение»).
var _building_levels: Dictionary = {}
var _idle_check_t := 0.0
## Время боя (world.now) последней реплики простоя: пауза и ускорение времени считаются честно.
var _idle_voice_at := 0.0
## Звук 08.10: дакинг и слои музыки (шина Music: фильтр + усиление из default_bus_layout.tres).
var _duck_db := 0.0
var _duck_pulse_until := 0
var _layer_db := 0.0
var _layer_db_target := 0.0
var _cutoff_hz := 20000.0
var _cutoff_target := 20000.0
var _combo_prev := 0


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
	speech = LegionVoice.new()
	speech.name = "Speech"
	add_child(speech)
	speech.setup(_muted, _log_enabled)
	_instances.append(self)
	var ui_sfx := LegionUiSfx.new()
	ui_sfx.name = "UiSfx"
	ui_sfx.setup(self)
	add_child(ui_sfx)
	_cutoff_hz = LegionCfg.AUDIO_MUSIC_CUTOFF_OPEN_HZ
	_cutoff_target = _cutoff_hz
	_apply_music_bus()


## Текущий узел звука (null, если его ещё нет или он освобождён).
static func current() -> LegionAudio:
	for i in range(_instances.size() - 1, -1, -1):
		var a: Variant = _instances[i]
		if is_instance_valid(a) and not (a as LegionAudio).is_queued_for_deletion():
			return a as LegionAudio
		_instances.remove_at(i)
	return null


## Звук интерфейса для экранов, у которых нет своего сигнала (Campaign — RefCounted без
## сигналов): `LegionAudio.ui(&"rank_up")` — новый разряд, `&"amend_sign"` — подпись поправки,
## `&"ui_buy"` — покупка. Узла нет (тест экрана без звука) — молча ничего.
static func ui(id: StringName) -> void:
	var a := current()
	if a != null:
		a.ui_sfx(id)


func ui_sfx(id: StringName, pitch := 1.0) -> void:
	_play(String(id), String(id), pitch)


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
	# 08.10 (SND-01): эффекты ключевых действий — сигналы мира legion_world.gd:24–85
	world.rally_used.connect(_on_rally_used)
	world.charge_impact.connect(_on_charge_impact)
	world.combo_changed.connect(_on_combo_changed)
	world.segment_broken.connect(_on_segment_broken)
	world.spring_released.connect(_on_spring_released)
	world.tab_erased.connect(_on_tab_erased)
	world.figure_ult.connect(_on_figure_ult)
	world.figure_slung.connect(_on_figure_slung)
	world.segment_torn.connect(_on_segment_torn)
	world.breach_warned.connect(_on_breach_warned)
	world.breach_opened.connect(_on_breach_opened)
	world.wave_called.connect(_on_wave_called)
	world.unit_spawned.connect(_on_unit_spawned)


func _process(delta: float) -> void:
	speech.tick(delta)
	_tick_idle_voice(delta)
	_tick_music_mix(delta)
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
	_object_track = object_track_for(map_id)
	_play_music(_object_track)
	_combo_prev = 0
	# отказ каста (нет цели / нет трупа) — у героя своей стороны; герой пересоздаётся с картой
	var hero := world.hero_of(world.local_side)
	if hero != null and not hero.cast_failed.is_connected(_on_cast_failed):
		hero.cast_failed.connect(_on_cast_failed)
	# Новый бой — прошлые заявки (шаг обучения, «объект сдан» прошлой карты) уже не про него.
	speech.clear_voice_queue()
	speech.voice(StringName("lg_brief_%s" % map_id), LegionCfg.AUDIO_V15_PRIORITY_NARRATOR,
		VoiceClass.STORY)


func _on_match_ended(victory: bool, _stats: Dictionary) -> void:
	_set_music_layer(0.0, LegionCfg.AUDIO_MUSIC_CUTOFF_OPEN_HZ)
	_play_music("victory" if victory else "defeat")
	# Один из двух дублей на исход (докстрин класса, §audio): рассказчик даёт сводку конторы,
	# некромант — личную реакцию. Оба не звучат разом — speech.voice() держит один голос.
	# Сюжет, не сцена: финальная катсцена кампании идёт сразу следом и своим кадром обрывает её.
	var ids := ["lg_victory_1", "lg_victory_2"] if victory else ["lg_defeat_1", "lg_defeat_2"]
	var prio_narrator := LegionCfg.AUDIO_V15_PRIORITY_NARRATOR
	var priority: int = prio_narrator if victory else LegionCfg.AUDIO_V15_PRIORITY_HR
	speech.voice_any(ids, priority, VoiceClass.STORY)


func _on_menu_entered() -> void:
	_set_music_layer(0.0, LegionCfg.AUDIO_MUSIC_CUTOFF_OPEN_HZ)
	_play_music("menu")
	silence_for_menu()


## Уход в главное меню: реплика боя/кампании в меню — шум (находка verifier 26.09: она звучала
## поверх меню и утекала в следующий бой). Очередь — прочь, текущая — коротким спадом, не
## доигрывать: 7-11-секундная реплика про бой над кнопками меню хуже, чем обрыв на 0.25 с.
func silence_for_menu() -> void:
	speech.stop_voice(LegionCfg.AUDIO_V15_VOICE_MENU_FADE_SEC)


## polish1: публичный вход для экранов кампании вне боя (меню, карты, брифинг, «Контора», герой)
## — все зовут этот метод, трек один и тот же, повторный вызов, пока он уже играет, ничего не
## перезапускает (`_play_music()` сам сверяет `_current_track`).
func play_menu_music() -> void:
	_set_music_layer(0.0, LegionCfg.AUDIO_MUSIC_CUTOFF_OPEN_HZ)
	_play_music("menu")


func _on_wave_started(i: int, total: int) -> void:
	_play("wave_started", "wave_start")
	_layer_for_wave(i, total)
	if _wave_has_boss(i):
		_play_music("boss")
		# Сюжет: появление босса обрывает выкрик (каст), но ждёт брифинга/обучения, не режет их.
		speech.voice(&"lg_boss_appear", LegionCfg.AUDIO_V15_PRIORITY_BOSS, VoiceClass.STORY)
	elif i >= total - 1:
		# последняя волна — плотнее и ярче; темп и тональность общие с a/b — долгий кроссфейд
		_play_music("battle_final", LegionCfg.AUDIO_MUSIC_FINAL_CROSSFADE_SEC)
	else:
		_play_music(_object_track)   # после волны с боссом — назад к треку объекта
	if not _wave_has_boss(i):
		speech.wave_shout()   # «иногда» выкрик строя (DESIGN_V15 §9)


## Трек обычных волн объекта: у карты своё «лицо», повторный заход звучит так же (music-1008 §4.1).
## Карта кампании — по чётности места в списке кампании (order дробный — берём индекс, не поле):
## 1-я, 3-я… — battle_a, 2-я, 4-я… — battle_b. Прочие (схватка, служебные) — по хешу id.
static func object_track_for(map_id: String) -> String:
	var maps := Campaign.maps()
	for k in maps.size():
		if String(maps[k].get("id", "")) == map_id:
			return "battle_a" if k % 2 == 0 else "battle_b"
	return "battle_a" if absi(hash(map_id)) % 2 == 0 else "battle_b"


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
	# SND-09: натиск — свой звук (шорох рывка и костяной перестук), молния Ку — только касту Ку
	_play("segment_released", "charge")
	Juice.shake(world, LegionCfg.AUDIO_SEGMENT_SHAKE, LegionCfg.AUDIO_SEGMENT_SHAKE_DURATION)


func _on_unit_died(_unit: Legionnaire) -> void:
	# нет отдельного сигнала "удар печатью" (SLICE_SPEC §3) — гибель бойца в бою и есть тот
	# самый удар нотариуса по строю, честной альтернативы контракту сигналов нет
	_play("unit_died", "skel_hit")


func _on_foe_died(foe: Foe) -> void:
	_play("foe_died", "enemy_die")
	if foe != null and foe.type_id == "boss":
		duck_pulse()
		Juice.shake(world, LegionCfg.AUDIO_BOSS_DEATH_SHAKE, LegionCfg.AUDIO_BOSS_DEATH_SHAKE_DURATION)
		Juice.flash(world, LegionCfg.AUDIO_BOSS_DEATH_FLASH_COLOR,
			LegionCfg.AUDIO_BOSS_DEATH_FLASH_DURATION)


## Рёв (пакет crypt) — предупреждение за BOSS_RAM_WARN до тарана. Умеренная тряска: игрок
## должен читать её как «сейчас будет удар», не как сам удар.
func _on_boss_roared(_foe: Foe, _target: Vector2) -> void:
	_play("boss_roared", "boss_roar")   # SND-09: был замах ульты
	Juice.shake(world, LegionCfg.AUDIO_BOSS_ROAR_SHAKE, LegionCfg.AUDIO_BOSS_ROAR_SHAKE_DURATION)


## Сам таран (пакет crypt) — удар звуком и тряской заметнее сегмента, но слабее смерти босса.
func _on_boss_rammed(_foe: Foe, _target: Vector2) -> void:
	_play("boss_rammed", "mine_boom", 0.82)   # взрыв, опущенный ниже, — тяжесть тарана
	Juice.shake(world, LegionCfg.AUDIO_BOSS_RAM_SHAKE, LegionCfg.AUDIO_BOSS_RAM_SHAKE_DURATION)


# ── 08.10: эффекты ключевых действий (SND-01) ─────────────────────────────────

## «Сбор» (R): медный зов; некого звать (n = 0) — отказ, как у нехватки маны.
func _on_rally_used(_at: Vector2, n: int) -> void:
	if n > 0:
		_play("rally", "rally")
	else:
		_play("cast_failed", "rune_fail")


## Удар залпа: низкий удар; точный срыв — ещё и звон, и короткий спад музыки (большой момент).
## Поле договоров (contract_field.gd) кладёт сверху свой skel_hit — тембры подобраны слоями.
func _on_charge_impact(_at: Vector2, perfect: bool) -> void:
	if perfect:
		_play("charge_perfect", "charge_perfect")
		duck_pulse()
	else:
		_play("charge_hit", "charge_hit")


## Комбо: каждое новое звено — щипок на ступень выше (лестница до +60 %), сброс — тишина.
func _on_combo_changed(combo: int, _mult: float) -> void:
	if combo >= 2 and combo > _combo_prev:
		var pitch := minf(1.0 + LegionCfg.AUDIO_COMBO_PITCH_STEP * float(combo - 1),
			LegionCfg.AUDIO_COMBO_PITCH_CAP)
		_play("combo", "combo", pitch)
	_combo_prev = combo


func _on_segment_broken(_c: Contract, _seg: int, _n: int) -> void:
	_play("segment_broken", "crush")


func _on_spring_released(_c: Contract, _seg: int, bend: float) -> void:
	_play("spring", "spring", 1.0 + 0.15 * clampf(bend, 0.0, 1.0))


func _on_tab_erased(_c: Contract, _n_segs: int, _n_units: int) -> void:
	_play("tab_erased", "erase")


func _on_figure_ult(_c: Contract) -> void:
	_play("figure_ult", "ult_blast")
	duck_pulse()


func _on_figure_slung(_c: Contract) -> void:
	_play("figure_slung", "sling")


func _on_segment_torn(_c: Contract, _seg: int, _n: int) -> void:
	_play("segment_torn", "tear")


func _on_breach_warned(_id: String, _in_s: float, _summary: Array) -> void:
	_play("breach_warned", "breach_warn")


func _on_breach_opened(_id: String) -> void:
	_play("breach_opened", "breach_open")


func _on_wave_called(_i: int, _bonus: int) -> void:
	_play("wave_called", "wave_call")


func _on_unit_spawned(_u: Legionnaire) -> void:
	if world.phase == LegionWorld.Phase.BATTLE:
		_play("unit_spawned", "spawn")


## Каст не состоялся: нет цели или трупа (нехватку маны озвучивает mana_short — без дубля).
func _on_cast_failed(_slot: int, reason: StringName) -> void:
	if reason != &"no_mana":
		_play("cast_failed", "rune_fail")


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
## 08.10: громкость и приоритет в пуле — по событию (LegionCfg.AUDIO_SFX_GAIN_DB/PRIORITY),
## `pitch` — множитель высоты (лестница комбо); разброс высоты и громкости добавляет Audio.sfx().
func _play(event_key: String, sfx_id: String, pitch := 1.0) -> void:
	_call_counts[event_key] = int(_call_counts.get(event_key, 0)) + 1
	var now_msec := FxClock.ms()
	var interval: int = int(LegionCfg.AUDIO_EVENT_INTERVAL_MSEC.get(event_key, 0))
	var last_msec: int = int(_last_played_msec.get(event_key, -interval * 10))
	if now_msec - last_msec < interval:
		return
	_last_played_msec[event_key] = now_msec
	_play_counts[event_key] = int(_play_counts.get(event_key, 0)) + 1
	_audio.sfx(sfx_id, pitch, float(LegionCfg.AUDIO_SFX_GAIN_DB.get(event_key, 0.0)),
		int(LegionCfg.AUDIO_SFX_PRIORITY.get(event_key, 0)))


## Свой кроссфейд (не Audio.play_music() — новые треки v15 в её MUSIC_FILES не заводим,
## см. докстринг класса): те же грабли, что у audio.gd — повторный вызов с тем же треком
## не должен перезапускать проигрывание.
func _play_music(track: String, fade_sec := -1.0) -> void:
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
	if _music_tween != null and _music_tween.is_valid():
		_music_tween.kill()
	# 08.10 (SND-04): кроссфейд равной мощности по амплитуде (sin/cos), а не линия в децибелах:
	# линия от −80 дБ давала провал посередине (старый трек гас за первые 0,15 с, новый вступал
	# в конце), и смена трека слышалась «дыркой». Уходящий трек гаснет с той громкости, на
	# которой его застала смена (прерванный кроссфейд не прыгает вверх).
	var prev_gain := _music_gain(prev_player) if prev_player.playing else 0.0
	next_player.stream = stream
	_set_music_gain(next_player, 0.0)
	next_player.play()
	_music_tween = create_tween()
	var sec := LegionCfg.AUDIO_V15_MUSIC_CROSSFADE_SEC if fade_sec < 0.0 else fade_sec
	_music_tween.tween_method(_crossfade_step.bind(prev_player, next_player, prev_gain), 0.0, 1.0,
		sec)
	_music_tween.tween_callback(prev_player.stop)
	_music_active_index = next_index


func _crossfade_step(t: float, prev: AudioStreamPlayer, next: AudioStreamPlayer,
		prev_gain: float) -> void:
	_set_music_gain(next, sin(t * PI * 0.5))
	if prev.playing:
		_set_music_gain(prev, prev_gain * cos(t * PI * 0.5))


## Громкость музыкального плеера как доля 0..1 от MUSIC_VOLUME_DB (амплитуда, не децибелы).
func _music_gain(p: AudioStreamPlayer) -> float:
	return clampf(db_to_linear(p.volume_db - MUSIC_VOLUME_DB), 0.0, 1.0)


func _set_music_gain(p: AudioStreamPlayer, g: float) -> void:
	p.volume_db = maxf(MUSIC_VOLUME_DB + linear_to_db(maxf(g, 0.00001)), MUTE_DB)


func _fade_music_out(player: AudioStreamPlayer) -> void:
	if not player.playing:
		return
	if _music_tween != null and _music_tween.is_valid():
		_music_tween.kill()
	var from := _music_gain(player)
	_music_tween = create_tween()
	var fade := func(t: float) -> void: _set_music_gain(player, from * cos(t * PI * 0.5))
	_music_tween.tween_method(fade, 0.0, 1.0, LegionCfg.AUDIO_V15_MUSIC_CROSSFADE_SEC)
	_music_tween.tween_callback(player.stop)


## SND-05: стингер победы/поражения (9–10 с без петли) раньше оставлял экран итога в тишине до
## перехода в меню. Доиграл — плавно вступает трек меню (тот же, что включат экраны кампании).
func _on_music_finished(p: AudioStreamPlayer) -> void:
	if p == _music_players[_music_active_index] and not bool(MUSIC_LOOP.get(_current_track, true)):
		_play_music("menu")


# ── 08.10: дакинг и слои музыки (SND-04/05/06) ────────────────────────────────

## Короткий спад музыки на большой момент (смерть босса, заряженная фигура, точный срыв).
func duck_pulse() -> void:
	_duck_pulse_until = FxClock.ms() + int(LegionCfg.AUDIO_DUCK_PULSE_SEC * 1000.0)


## Текущее приглушение музыки, дБ (0 — нет; под голосом — до AUDIO_DUCK_VOICE_DB).
func music_duck_db() -> float:
	return _duck_db


## Цель слоя громкости музыки по волне, дБ (последняя волна громче).
func music_layer_db() -> float:
	return _layer_db_target


## Цель среза фильтра музыки по волне, Гц (первая волна приглушена, последняя открыта).
func music_cutoff_hz() -> float:
	return _cutoff_target


func _set_music_layer(db: float, hz: float) -> void:
	_layer_db_target = db
	_cutoff_target = hz


## Бой «раскрывается» к последней волне: срез фильтра растёт по экспоненте (слух — логарифм
## частоты), громкость добавляется только на последней. Волна с боссом — свой трек, открытый.
func _layer_for_wave(i: int, total: int) -> void:
	var first := LegionCfg.AUDIO_MUSIC_CUTOFF_FIRST_HZ
	var open := LegionCfg.AUDIO_MUSIC_CUTOFF_OPEN_HZ
	if _wave_has_boss(i):
		_set_music_layer(LegionCfg.AUDIO_MUSIC_BOSS_DB, open)
		return
	var frac := clampf(float(i) / float(maxi(total - 1, 1)), 0.0, 1.0)
	var last := i >= total - 1
	_set_music_layer(LegionCfg.AUDIO_MUSIC_FINAL_WAVE_DB if last else 0.0,
		open if last else first * pow(open / first, frac))


## Каждый кадр: голос и «большой момент» тянут музыку вниз (быстро), отпускают медленно; слой
## волны и срез фильтра плывут к цели за AUDIO_MUSIC_LAYER_SEC. Пишет в шину только текущий
## узел — в тестах их бывает несколько, и чужой перетирал бы приглушение каждый кадр.
func _tick_music_mix(delta: float) -> void:
	var target := 0.0
	if speech.is_voice_busy():
		target = LegionCfg.AUDIO_DUCK_VOICE_DB
	if FxClock.ms() < _duck_pulse_until:
		target = minf(target, LegionCfg.AUDIO_DUCK_PULSE_DB)
	var span := absf(LegionCfg.AUDIO_DUCK_VOICE_DB)
	var sec := LegionCfg.AUDIO_DUCK_RELEASE_SEC
	if target < _duck_db:
		sec = LegionCfg.AUDIO_DUCK_ATTACK_SEC
	_duck_db = move_toward(_duck_db, target, span * delta / sec)
	var layer_span := maxf(absf(LegionCfg.AUDIO_MUSIC_FINAL_WAVE_DB), 1.0)
	_layer_db = move_toward(_layer_db, _layer_db_target,
		layer_span * delta / LegionCfg.AUDIO_MUSIC_LAYER_SEC)
	var octaves := log(LegionCfg.AUDIO_MUSIC_CUTOFF_OPEN_HZ / LegionCfg.AUDIO_MUSIC_CUTOFF_FIRST_HZ)
	_cutoff_hz = exp(move_toward(log(_cutoff_hz), log(_cutoff_target),
		octaves * delta / LegionCfg.AUDIO_MUSIC_LAYER_SEC))
	if current() == self:
		_apply_music_bus()


## Эффекты шины Music из default_bus_layout.tres (ищем по классу, не по номеру — порядок в
## раскладке можно менять в редакторе). Открытый фильтр выключаем: на краю слышимого он ничего
## не режет, а выключенный точно не окрашивает звук.
func _apply_music_bus() -> void:
	var bus := AudioServer.get_bus_index(&"Music")
	if bus < 0:
		return
	for i in AudioServer.get_bus_effect_count(bus):
		var fx := AudioServer.get_bus_effect(bus, i)
		if fx is AudioEffectAmplify:
			(fx as AudioEffectAmplify).volume_db = _layer_db + _duck_db
		elif fx is AudioEffectLowPassFilter:
			(fx as AudioEffectLowPassFilter).cutoff_hz = _cutoff_hz
			AudioServer.set_bus_effect_enabled(bus, i,
				_cutoff_hz < LegionCfg.AUDIO_MUSIC_CUTOFF_OPEN_HZ - 500.0)


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
		p.finished.connect(_on_music_finished.bind(p))
		_music_players.append(p)
	_music_active_index = 0
	_current_track = "none"


# ── integrate1: озвучка событий v15 ───────────────────────────────────────────

func _on_hero_cast(slot: int, _at: Vector2) -> void:
	# SND-01: эффект каста звучит всегда; голосовой выкрик ниже — только в тишине (SHOUT)
	_play("hero_cast", CAST_SFX[clampi(slot, 0, 2)])
	speech.hero_cast_voice(slot)


func _on_building_changed(obj: Object) -> void:
	var b := obj as LegionBuilding
	if b == null or b.source != LegionBuilding.SOURCE_PLOT:
		return
	var key := b.get_instance_id()
	if not world.buildings.has(b):
		_building_levels.erase(key)   # продана
		return
	if not _building_levels.has(key) or b.level > int(_building_levels[key]):
		_play("building", "build")   # стук молотка — и постройке, и улучшению
	if not _building_levels.has(key):
		_building_levels[key] = b.level
		# Сюжет (событие кадровика): ждёт конца текущей реплики — оно не устаревает так быстро,
		# как боевой выкрик.
		speech.voice(&"lg_building_ready", LegionCfg.AUDIO_V15_PRIORITY_HR, VoiceClass.STORY)
	elif b.level > int(_building_levels[key]):
		_building_levels[key] = b.level
		speech.voice(&"lg_upgrade_done", LegionCfg.AUDIO_V15_PRIORITY_HR, VoiceClass.STORY)


func _on_souls_short() -> void:
	speech.voice(&"lg_souls_low", LegionCfg.AUDIO_V15_PRIORITY_NECROMANCER, VoiceClass.SHOUT)


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
		speech.voice(&"lg_idle", LegionCfg.AUDIO_V15_PRIORITY_TROOP, VoiceClass.SHOUT)


func _wave_has_boss(i: int) -> bool:
	var waves: Array = world.map.get("waves", [])
	if i < 0 or i >= waves.size():
		return false
	var groups: Array = waves[i].get("groups", [])
	for g in groups:
		if String(g.get("type", "")) == "boss":
			return true
	return false
