extends SceneTree
##
## Регресс пакета «озвучка» (26.09.2026, worktree necro-voice, ветка slow/voice):
## новый набор MostAI читает медленнее прежней Silero (7-12 с против ~4-5 с), а кадр
## катсцены держался только max(3.0, длина_титра*0.055) — голос обрывался следующим
## кадром (см. `godot/scripts/legion/ui/legion_cutscene.gd`).
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_voice_test.gd -- --mute
##
## 1) каждый id из tools/voice/lines.tsv (список продублирован ниже — держать в
##    синхроне при следующей правке набора) грузится как AudioStream длиннее 0 с;
## 2) кадр катсцены с длинной репликой (lg_intro_1, ~11.3 с, короткий титр) не
##    сменяется раньше длины голоса — ДО фикса падает здесь: длина реплики известна
##    заранее (mostai_manifest.tsv), старый расчёт по титрам давал те же ~4 с.
##
## Итог «LEGION VOICE: N/M OK»; код выхода 1, если что-то упало.

# Тот же список id, что в tools/voice/lines.tsv (37 реплик пакета озвучки v15).
const VOICE_IDS: Array[String] = [
	"lg_intro_1", "lg_intro_2", "lg_intro_3", "lg_intro_4",
	"lg_brief_wasteland", "lg_brief_fork", "lg_brief_swamp", "lg_brief_maze",
	"lg_brief_bridge", "lg_brief_boss",
	"lg_victory_1", "lg_defeat_1", "lg_victory_2", "lg_defeat_2",
	"lg_cast_q_1", "lg_cast_q_2", "lg_cast_w_1", "lg_cast_w_2",
	"lg_cast_e_1", "lg_cast_e_2", "lg_souls_low",
	"lg_building_ready", "lg_upgrade_done",
	"lg_contract_new_1", "lg_contract_new_2", "lg_contract_new_3",
	"lg_office_enter", "lg_office_buy",
	"lg_tut_1", "lg_tut_2", "lg_tut_3", "lg_tut_4",
	"lg_wave_1", "lg_wave_2", "lg_wave_3", "lg_idle",
	"lg_boss_appear",
]

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
	_test_all_ids_load()
	await _test_frame_duration_covers_voice()
	print("LEGION VOICE: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


## Каждый id из lines.tsv должен грузиться как AudioStream и звучать хоть сколько-то —
## иначе кадр с ним замолчит и разъедет с длиной, посчитанной process_mostai.py.
func _test_all_ids_load() -> void:
	print("— все id пакета озвучки грузятся")
	for id in VOICE_IDS:
		var path := "res://assets/legion/voice/%s.ogg" % id
		var stream := load(path) as AudioStream
		_check(stream != null, "%s грузится (%s)" % [id, path])
		if stream != null:
			_check(stream.get_length() > 0.0, "%s длиннее 0 с (%.2f)" % [id, stream.get_length()])


## Кадр с короткой подписью, но длинной репликой не должен сменяться раньше конца голоса.
## Без фикса legion_cutscene.gd дальность держалась по титрам (~0.4 с, FRAME_MIN_SEC=3.0 с) —
## этот тест ловит именно ту регрессию: ждём дольше старого расчёта и раньше длины голоса,
## текущий кадр должен ещё стоять.
## Порог «длиннее старого расчёта» и контрольная точка ожидания понижены сессией ускорения
## озвучки 26.09.2026 вечер (process_mostai.py: подрезка пауз + ×1.30 темпа) — lg_intro_1
## сжался с ~11.3 с до ~6.25 с; 4.5/4.0 с всё ещё далеко от FRAME_MIN_SEC=3.0, старый баг
## по-прежнему ловится, просто с меньшим запасом, отражающим новую длительность.
func _test_frame_duration_covers_voice() -> void:
	print("— кадр катсцены держится не меньше длины голоса")
	var voice_stream := load("res://assets/legion/voice/lg_intro_1.ogg") as AudioStream
	if voice_stream == null:
		_check(false, "lg_intro_1.ogg не загрузился — нечем мерить кадр")
		return
	var voice_len := voice_stream.get_length()
	_check(voice_len > 4.5, "lg_intro_1 длиннее старого расчёта по титрам (%.2f с)" % voice_len)

	var c := LegionCutscene.new()
	root.add_child(c)
	var frame_a := LegionCutscene.Frame.new("Коротко.", &"lg_intro_1", _blank_texture())
	var frame_b := LegionCutscene.Frame.new("Второй кадр — сюда переходить рано.", &"", _blank_texture())
	var frames: Array[LegionCutscene.Frame] = [frame_a, frame_b]
	c.play(frames)

	# Старый расчёт (титр 8 символов * 0.055 = 0.44 с) дал бы кадр FRAME_MIN_SEC = 3.0 с;
	# ждём заметно дольше этого и заметно меньше длины голоса — кадр обязан ещё стоять.
	var wait_sec := 4.0
	_check(wait_sec > 3.0 and wait_sec < voice_len,
		"контрольная точка %.1f с между старым (3.0) и новым (%.2f) расчётом" % [wait_sec, voice_len])
	await create_timer(wait_sec).timeout
	_check(is_instance_valid(c) and c._caption_label.text == frame_a.caption,
		"кадр с голосом (%.2f с) ещё на экране через %.1f с" % [voice_len, wait_sec])

	if is_instance_valid(c):
		c.queue_free()


func _blank_texture() -> Texture2D:
	var img := Image.create(4, 4, false, Image.FORMAT_RGB8)
	return ImageTexture.create_from_image(img)
