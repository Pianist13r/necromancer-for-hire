extends SceneTree
##
## Регресс пакета «обучение» (26.09.2026, worktree necro-teach, ветка slow/teach, поверх
## slow/input «зажатое колесо = Пробел» и slow/voice «новая озвучка»):
##
## 1) тексты обучения / «Как играть» / шпаргалки паузы не поминают устаревшую схему ввода
##    («Колесо мыши или клавиши 1/2/3», «ПКМ по линии» без строя над ней) — актуальная: зажатое
##    колесо = Пробел, прокрутка колеса — вид договора, ПКМ/Пробел/колесо берут и строй над линией.
## 2) озвучка по правилу трёх классов реплик (координатор 26.09, после опровержения verifier
##    очереди «одна важная реплика»): СЦЕНА (кадр катсцены) обрывает всё и чистит очередь; СЮЖЕТ
##    (брифинг, босс, итог, обучение, кадровик) режет выкрик, а за сценой/сюжетом ждёт в очереди;
##    ВЫКРИК (каст, волна, простой, души) — только в тишине. Очередь не разбирается на паузе,
##    чистится уходом в меню, новым боем и катсценой; отказ по откату её не стирает. Проверки А–Д
##    — пункты опровержения verifier 26.09 (катсцены, финал, потеря важной заявки, реплика боя в
##    меню, реплика поверх паузы) и «Контора»/новый вид после победной реплики.
##
## Проверки 2) ходят игровыми путями и через поля, которые есть и на 4c15df3, — на старом коде
## компилируются и падают проверками (демонстрация регресса), а не ошибкой разбора. Исключение —
## _tutorial_ttl_checks (поля очереди из e47fb50): второй раунд verifier 26.09, срок годности.
## Сохранение — временный файл (Campaign.set_save_path), user://legion.cfg владельца не трогаем.
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_teach_test.gd -- --mute
##
## Итог «LEGION TEACH: N/M OK»; код выхода 1, если что-то упало.
##

const TEST_SAVE := "user://legion_teach_test.cfg"

var main: LegionMain
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


func _run() -> void:
	_text_checks()
	await _howto_text_checks()
	await _voice_class_checks()
	await _tutorial_ttl_checks()
	print("LEGION TEACH: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


# ── Тексты: колесо/Пробел/ПКМ и захват по строю ──────────────────────────────

func _lesson_text(map_id: String, id: StringName) -> String:
	for l in LegionTutorial.parse(LegionWorld.load_map(map_id)):
		if l["id"] == id:
			return String(l["text"])
	return ""


func _text_checks() -> void:
	print("— тексты обучения и шпаргалки паузы")
	# v20: стрелку учит урок «Проходной» (D-0926-46) — его строка про Пробел и колесо
	var aim_text := _lesson_text("gatehouse", &"aim")
	_check(aim_text.contains("Пробел") and aim_text.contains("колес"),
		"урок стрелки: строка про Пробел упоминает и колесо (%s)" % aim_text)

	# урок натиска «Пустыря» — по id
	var release_text := _lesson_text("wasteland", &"release")
	_check(release_text.contains("строю") or release_text.contains("строем"),
		"шаг 2: текст говорит, что можно взять и за строй (%s)" % release_text)
	_check(not release_text.begins_with("ПКМ по линии: оттяни"),
		"шаг 2: текст не остался дословно старым без упоминания строя")

	var pause_joined := "\n".join(LegionPause.cheatsheet())
	_check(not pause_joined.contains("Колесо мыши или 1/2/3"),
		"пауза: устаревшая строка «Колесо мыши или 1/2/3» снята")
	_check(pause_joined.contains("Прокрутка колеса"),
		"пауза: «Прокрутка колеса» — новая формулировка вида договора")
	_check(pause_joined.contains("Пробел или колесо"),
		"пауза: «Пробел или колесо (зажать)» — стрелка для таяния")


func _howto_text_checks() -> void:
	print("— «Как играть»: колесо и захват по строю")
	var howto := HowtoLegion.new()
	root.add_child(howto)
	await _frames(2)
	var joined := ""
	for l in howto.find_children("*", "Label", true, false):
		joined += (l as Label).text + "\n"
	_check(not joined.contains("Колесо мыши или клавиши 1/2/3"),
		"«Как играть»: устаревшая строка про колесо снята")
	_check(joined.contains("Прокрутка колеса или клавиши 1/2/3"),
		"«Как играть»: вид договора — прокрутка колеса")
	_check(joined.contains("зажатое колесо") and joined.contains("строем над ней"),
		"«Как играть»: стрелка для таяния — Пробел или колесо, берётся и по строю")
	_check(joined.contains("договор подсветится заранее"),
		"«Как играть»: подсвечивается весь договор, а не «нужный участок»")
	howto.queue_free()
	await _frames(1)




# ── Голос: три класса реплик (сцена / сюжет / выкрик), координатор 26.09 ─────
# Только через игровые пути (катсцена, бой, постройка, пауза, меню, «Контора») и поля, которые
# есть и на 4c15df3 (`_voice_last_msec`, `_voice_busy_until_msec`, `_voice_player`,
# `_voice_rng`), — чтобы на старом коде проверки падали проверками, а не ошибкой компиляции.
# Никакого сброса занятости: ждём реальное время ОС (занятость голоса — по длине файла и
# Time.get_ticks_msec(); кадры под --fixed-fps 60 идут быстрее настоящих секунд).

func _len_msec(id: StringName) -> int:
	var stream := load("res://assets/legion/voice/%s.ogg" % id) as AudioStream
	return int(stream.get_length() * 1000.0) if stream != null else 0


func _started(id: StringName) -> int:
	return int(audio._voice_last_msec.get(id, -1))


## Сейчас звучит именно `id` (запущена последней и ещё не доиграла по своей длине).
func _current_is(id: StringName) -> bool:
	var st := _started(id)
	return st >= 0 and audio._voice_busy_until_msec > Time.get_ticks_msec() \
		and absi(audio._voice_busy_until_msec - st - _len_msec(id)) <= 2


func _quiet() -> bool:
	return audio._voice_busy_until_msec <= Time.get_ticks_msec()


func _wait_quiet() -> void:
	for i in 5:
		var left := audio._voice_busy_until_msec - Time.get_ticks_msec()
		if left > 0:
			OS.delay_msec(left + 80)
		await _frames(3)
		if _quiet():
			return


func _cutscene() -> LegionCutscene:
	for c in main.get_children():
		if c is LegionCutscene and not c.is_queued_for_deletion():
			return c
	return null


func _boss_wave() -> int:
	var waves: Array = main.world.map.get("waves", [])
	for i in waves.size():
		if audio._wave_has_boss(i):
			return i
	return -1


func _voice_class_checks() -> void:
	Campaign.set_save_path(TEST_SAVE)
	Campaign.reset()
	main = (load("res://scenes/legion.tscn") as PackedScene).instantiate() as LegionMain
	root.add_child(main)
	await _frames(2)
	audio = main._ensure_audio()
	await _scene_checks()
	await _fast_intro_checks()
	await _pause_menu_checks()
	await _story_checks()
	await _finale_checks()
	await _office_after_victory_checks()
	main.queue_free()
	await _frames(1)
	Campaign.reset()


## А: клик по кадру катсцены — звучит новый кадр, прошлая реплика обрывается.
func _scene_checks() -> void:
	print("— А: катсцена — каждый кадр своей репликой")
	main._play_cutscene(main._intro_frames(), audio, func() -> void: pass)
	await _frames(2)
	_check(_current_is(&"lg_intro_1"), "кадр 1 вступления — lg_intro_1")
	_check(not audio._voice_player.playing and not _quiet(),
		"под --mute плеер молчит (.playing=false), а голос «занят» по длине файла")
	for k in [2, 3, 4]:
		_cutscene()._skip_frame()
		await _frames(2)
		var id := StringName("lg_intro_%d" % k)
		_check(_current_is(id), "клик по кадру — звучит %s, прошлый кадр оборван" % id)
	_cutscene()._skip_all()
	await _frames(3)
	_check(_quiet(), "Esc (пропуск катсцены) гасит и её голос")


## Быстрый проклик вступления (verifier 26.09): 4 кадра по 0,3 с, «В бой» через 0,3 с — клик
## за последний кадр гасит голос кадра, брифинг и шаг 1 обучения звучат, а не протухают за ним.
func _fast_intro_checks() -> void:
	print("— быстрый проклик вступления → брифинг → бой")
	await _wait_quiet()
	audio._voice_last_msec.clear()
	main.show_briefing("wasteland")   # новая кампания: вступление перед первым брифингом
	await _frames(2)
	_check(_cutscene() != null, "вступление перед первым брифингом")
	for k in 4:
		OS.delay_msec(300)
		await _frames(1)
		if _cutscene() != null:
			_cutscene()._skip_frame()
		await _frames(1)
	await _frames(2)
	_check(_cutscene() == null and main.screen is Briefing, "клик за последний кадр — брифинг")
	_check(_quiet(), "клик за последний кадр гасит голос кадра (lg_intro_4 не звучит поверх)")
	OS.delay_msec(300)
	(main.screen as Briefing).start.emit("wasteland")   # «В бой»
	await _frames(3)
	_check(_current_is(&"lg_brief_wasteland"), "«В бой» — брифинг звучит сразу")
	await _wait_quiet()
	_check(_started(&"lg_tut_1") >= 0, "шаг 1 обучения прозвучал следом, не протух")


## Шаг обучения в очереди не стареет вовсе, остальной сюжет — по сроку годности. Через поля
## очереди (`_voice_queue`, `_voice_id`), которые появились в e47fb50: на нём компилируется и
## падает проверкой, на 4c15df3 — не компилируется (там очереди нет).
func _tutorial_ttl_checks() -> void:
	print("— срок годности: шаг обучения не стареет, прочий сюжет — стареет")
	var a := LegionAudio.new()
	root.add_child(a)
	a.setup_standalone(true, false)
	a.voice(&"lg_brief_wasteland", LegionCfg.AUDIO_V15_PRIORITY_NARRATOR, LegionAudio.VoiceClass.STORY)
	a.voice(&"lg_tut_1", LegionCfg.AUDIO_V15_PRIORITY_HR, LegionAudio.VoiceClass.STORY)
	a.voice(&"lg_building_ready", LegionCfg.AUDIO_V15_PRIORITY_HR, LegionAudio.VoiceClass.STORY)
	_check(a._voice_queue.size() == 2, "шаг 1 и «объект сдан» в очереди за брифингом")
	for e in a._voice_queue:   # обе записи «ждали» дольше срока годности
		e["at"] = int(e["at"]) - LegionCfg.AUDIO_V15_VOICE_QUEUE_TTL_MSEC - 1000
	OS.delay_msec(maxi(0, a._voice_busy_until_msec - Time.get_ticks_msec()) + 80)
	await _frames(2)
	_check(a._voice_id == &"lg_tut_1", "шаг обучения не протух")
	OS.delay_msec(maxi(0, a._voice_busy_until_msec - Time.get_ticks_msec()) + 80)
	await _frames(2)
	_check(not a._voice_last_msec.has(&"lg_building_ready"), "«объект сдан» дольше срока — отброшен")
	a.queue_free()
	await _frames(1)


## Д: пауза не разбирает очередь; Г: меню чистит очередь и гасит реплику боя; тур обучения.
func _pause_menu_checks() -> void:
	print("— Д/Г: пауза, меню, шаги обучения")
	await _wait_quiet()   # сценарий не зависит от того, чем кончилась катсцена
	audio._voice_last_msec.clear()
	main.start_battle("wasteland")   # первая карта: брифинг + обучение (tut_1 — за брифингом)
	await _frames(3)
	var w := main.world
	_check(_current_is(&"lg_brief_wasteland") and w.tutorial != null,
		"бой обучения: звучит брифинг")
	_check(_started(&"lg_tut_1") < 0, "шаг 1 обучения ждёт брифинга, не режет его")
	# сюжет не из обучения — «объект сдан» — встаёт за шагом 1 (у него срок годности есть)
	w.souls = 10000
	var built := w.staff.build(w.staff.plots[0], LegionCfg.KIND_LABORER)
	_check(built != null and _started(&"lg_building_ready") < 0, "«объект сдан» ждёт в очереди")
	# пауза 17 с — дольше срока годности очереди (verifier 26.09: пауза съедала срок, и после
	# неё отложенные реплики не звучали уже никогда)
	w.set_paused(true)
	await _frames(2)
	OS.delay_msec(17000)
	await _frames(4)
	_check(_started(&"lg_tut_1") < 0, "Д: на паузе отложенная реплика не звучит поверх меню паузы")
	w.set_paused(false)
	await _frames(3)
	# B-059: брифинг на паузе стоял, а не доигрывал — после паузы он продолжается, очередь ждёт его
	_check(audio.is_voice_busy() and _started(&"lg_tut_1") < 0,
		"Д: после паузы 17 с брифинг доигрывает с того же места, очередь ждёт")
	OS.delay_msec(maxi(0, audio._voice_busy_until_msec - Time.get_ticks_msec()) + 80)
	await _frames(3)
	_check(_current_is(&"lg_tut_1"), "Д: после паузы 17 с шаг 1 звучит своей очередью")
	OS.delay_msec(maxi(0, audio._voice_busy_until_msec - Time.get_ticks_msec()) + 80)
	await _frames(3)
	_check(_current_is(&"lg_building_ready"),
		"после паузы 17 с «объект сдан» не протух: пауза срок годности не съедает")

	# новый шаг заменяет в очереди устаревший: натиск (lg_tut_2) и Бытовка (lg_tut_3) пройдены,
	# пока звучит реплика. Шаги между ними (Сбор) без голоса — очередь не пополняют.
	w.tutorial._enter(w.tutorial.index_of(&"release"))
	w.tutorial._enter(w.tutorial.index_of(&"build"))
	await _frames(1)
	_check(_current_is(&"lg_building_ready"), "шаги 2-3 не обрывают звучащую реплику")
	OS.delay_msec(maxi(0, audio._voice_busy_until_msec - Time.get_ticks_msec()) + 80)
	await _frames(3)
	_check(_current_is(&"lg_tut_3"), "шаг 3 звучит следом")
	_check(_started(&"lg_tut_2") < 0, "устаревший шаг 2 не звучал")

	# урок без голоса (подновление) пройден, пока реплика Ку ждала очереди: она устарела и уходит
	w.tutorial._enter(w.tutorial.index_of(&"hero_q"))
	w.tutorial._enter(w.tutorial.index_of(&"refresh"))
	var stale := false
	for e in audio._voice_queue:
		if e["id"] == &"lg_tut_4":
			stale = true
	_check(not stale and _current_is(&"lg_tut_3"),
		"шаг без голоса убрал из очереди устаревшую реплику, звучащую не оборвал")

	# Г: реплика в очереди + звучащая — уход в меню
	w.tutorial._enter(w.tutorial.index_of(&"hero_q"))   # tut_4 встаёт за звучащим tut_3
	await _frames(1)
	_check(not _quiet() and _started(&"lg_tut_4") < 0, "шаг 4 ждёт в очереди за шагом 3")
	main.show_menu()
	await _frames(2)
	_check(_quiet(), "Г: уход в меню гасит реплику боя")
	OS.delay_msec(_len_msec(&"lg_tut_3") + 300)
	await _frames(4)
	_check(_started(&"lg_tut_4") < 0, "Г: реплика боя из очереди не звучит в главном меню")
	main.start_battle("fork")
	await _frames(3)
	await _wait_quiet()
	_check(_started(&"lg_tut_4") < 0, "Г: и не утекает в следующий бой")


## В: сюжетные заявки не теряются (откат, менее важная, новая), сюжет режет выкрик.
func _story_checks() -> void:
	print("— В: сюжет в очереди, выкрик — только в тишине")
	main._boss_cutscene_shown = true
	audio._voice_last_msec.clear()
	main.start_battle("boss")
	await _frames(3)
	var w := main.world
	_check(_current_is(&"lg_brief_boss"), "бой с боссом: звучит брифинг")
	var bi := _boss_wave()
	_check(bi >= 0, "у карты boss есть волна с боссом")
	audio._on_wave_started(bi, 1)
	_check(_started(&"lg_boss_appear") < 0 and _current_is(&"lg_brief_boss"),
		"появление босса ждёт брифинга, не режет его")
	# «объект сдан» только что звучал (откат по id): заявка отказана, но очередь не стирает
	audio._voice_last_msec[&"lg_building_ready"] = Time.get_ticks_msec()
	w.souls = 10000
	var st := w.staff
	var b := st.build(st.plots[0], LegionCfg.KIND_LABORER)
	_check(b != null, "постройка поставлена")
	OS.delay_msec(LegionCfg.AUDIO_V15_VOICE_COOLDOWN_MSEC + 100)
	st.upgrade(b)   # сюжет выше рангом (HR 3), чем босс (2): встаёт в очередь раньше него
	await _frames(1)
	_check(_started(&"lg_upgrade_done") < 0, "улучшение ждёт брифинга")
	await _wait_quiet()
	var t_up := _started(&"lg_upgrade_done")
	var t_boss := _started(&"lg_boss_appear")
	_check(t_boss >= 0, "В: появление босса не потеряно ни откатом, ни более важной заявкой")
	_check(t_up >= 0, "В: улучшение не потеряно")
	_check(t_up >= 0 and t_boss > t_up, "очередь по рангу: улучшение (HR) раньше босса")

	# сюжет обрывает выкрик; выкрик поверх сюжета пропадает
	audio._on_hero_cast(LegionHero.SLOT_Q, Vector2(700, 300))
	var cast_on := _current_is(&"lg_cast_q_1") or _current_is(&"lg_cast_q_2")
	_check(cast_on, "в тишине каст Ку звучит")
	audio._voice_last_msec.erase(&"lg_boss_appear")
	audio._on_wave_started(bi, 1)
	_check(_current_is(&"lg_boss_appear"), "появление босса обрывает выкрик каста сразу")
	audio._voice_last_msec.erase(&"lg_cast_e_1")
	audio._voice_last_msec.erase(&"lg_cast_e_2")
	audio._on_hero_cast(LegionHero.SLOT_E, Vector2(700, 300))
	await _wait_quiet()
	_check(_started(&"lg_cast_e_1") < 0 and _started(&"lg_cast_e_2") < 0,
		"каст поверх сюжета пропал, не прозвучал с опозданием")


## Б: финал кампании — кадр 1 «Акт подписан…» звучит lg_victory_1, даже если итог боя выбрал
## lg_victory_2 (сюжет итога обрывается сценой).
func _finale_checks() -> void:
	print("— Б: финал кампании после реплики итога")
	var w := main.world
	var seed_v2 := 1
	var probe := RandomNumberGenerator.new()
	while true:
		probe.seed = seed_v2
		if probe.randi() % 2 == 1:
			break
		seed_v2 += 1
	audio._voice_rng.seed = seed_v2   # итог боя выберет lg_victory_2
	audio._voice_last_msec.erase(&"lg_victory_1")
	audio._voice_last_msec.erase(&"lg_victory_2")
	w.stats["boss_killed"] = 1
	w.force_end(true)
	await _frames(2)
	_check(_cutscene() != null, "победа на последней карте — финальная катсцена")
	_check(_current_is(&"lg_victory_1"), "Б: кадр 1 финала звучит lg_victory_1, а не итог боя")
	_cutscene()._skip_frame()
	await _frames(2)
	_check(_current_is(&"lg_victory_2"), "кадр 2 финала — lg_victory_2")
	_cutscene()._skip_all()
	await _frames(3)


## «Контора» и новый вид договора после победной реплики обычной карты — не теряются.
func _office_after_victory_checks() -> void:
	print("— «Контора» и новый вид после победной реплики")
	audio._voice_last_msec.clear()
	main.start_battle("fork")
	await _frames(3)
	await _wait_quiet()   # брифинг доиграл
	main.world.force_end(true)
	await _frames(2)
	var won := _current_is(&"lg_victory_1") or _current_is(&"lg_victory_2")
	_check(won, "победа — звучит реплика итога")
	main.show_office(main.show_menu)
	await _frames(1)
	_check(won and _started(&"lg_office_enter") < 0, "приветствие «Конторы» ждёт реплику итога")
	Campaign.unlock_all()
	main.show_briefing("bridge")
	await _frames(2)
	await _wait_quiet()
	var t_office := _started(&"lg_office_enter")
	var t_new := maxi(maxi(_started(&"lg_contract_new_1"), _started(&"lg_contract_new_2")),
		_started(&"lg_contract_new_3"))
	_check(t_office >= 0, "«Контора» после победной реплики — lg_office_enter не потерян")
	_check(t_new > t_office, "новый вид договора — lg_contract_new_* следом, не потерян")
