extends SceneTree
##
## Самопроверка точек катсцен в кампании (integrate1, DESIGN_V15 §9): вступление — перед ПЕРВЫМ
## брифингом новой кампании и один раз; выход Прораба — перед боем на карте, в волнах которой
## есть босс (по данным, не по id); финал — после победы на последней карте, перед итогом
## «Кампания пройдена». Ведёт LegionMain; катсцену пропускаем как Esc (_skip_all).
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_cutscene_flow_test.gd -- --mute
##
## Итог «LEGION CUTSCENE FLOW: N/M OK»; код выхода 1, если что-то упало. Сохранение — временный
## файл (Campaign.set_save_path), реальный user://legion.cfg владельца не трогаем.
##

const TEST_PATH := "user://legion_cutscene_flow_test.cfg"

var main: LegionMain
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


func _cutscene() -> LegionCutscene:
	for c in main.get_children():
		if c is LegionCutscene and not c.is_queued_for_deletion():
			return c
	return null


## Реальное время ОС, пока голос не освободится и очередь не разберётся (занятость голоса —
## по Time.get_ticks_msec() и длине файла; кадры под --fixed-fps идут быстрее настоящих секунд).
func _wait_quiet(audio: LegionAudio) -> void:
	for i in 4:
		var left := audio._voice_busy_until_msec - Time.get_ticks_msec()
		if left > 0:
			OS.delay_msec(left + 80)
		await _frames(3)
		if audio._voice_busy_until_msec <= Time.get_ticks_msec():
			return


func _skip() -> void:
	var c := _cutscene()
	if c != null:
		c._skip_all()
	await _frames(3)


func _run() -> void:
	Campaign.set_save_path(TEST_PATH)
	Campaign.reset()
	var scene: PackedScene = load("res://scenes/legion.tscn")
	main = scene.instantiate() as LegionMain
	root.add_child(main)
	await _frames(2)

	var maps := Campaign.maps()
	var first := String(maps[0].get("id", ""))
	var second := String(maps[1].get("id", ""))
	var last := String(maps[maps.size() - 1].get("id", ""))

	# вступление
	main.show_briefing(second)
	await _frames(2)
	_check(_cutscene() == null and main.screen is Briefing, "брифинг не первой карты — без вступления")
	main.show_briefing(first)
	await _frames(2)
	_check(_cutscene() != null, "первый брифинг новой кампании — вступление")
	await _skip()
	_check(main.screen is Briefing, "после вступления — брифинг первой карты")
	main.show_briefing(first)
	await _frames(2)
	_check(_cutscene() == null and main.screen is Briefing, "вступление показано один раз")

	# выход Прораба — по данным карты
	_check(LegionMain._has_boss(last) and not LegionMain._has_boss(first),
		"карта босса определяется по волнам (%s)" % last)
	main.start_battle(first)
	await _frames(2)
	_check(_cutscene() == null and main.world.map_id == first, "бой на обычной карте — без катсцены")
	main.start_battle(last)
	await _frames(2)
	_check(_cutscene() != null, "бой на карте босса — сперва выход Прораба")
	await _skip()
	_check(main.world != null and main.world.map_id == last
			and main.world.phase == LegionWorld.Phase.BATTLE, "после катсцены — бой на карте босса")

	# финал
	main.world.stats["boss_killed"] = 1   # победа над Прорабом засчитывается только с убитым боссом
	main.world.force_end(true)
	await _frames(2)
	_check(_cutscene() != null, "победа на последней карте — финальная катсцена")
	await _skip()
	_check(main.screen is LegionResult, "после финала — экран итога")

	# integrate1: озвучка кампании узлом звука живого мира — «Контора» и новый вид на брифинге
	var audio := main._find_world_audio()
	_check(audio != null, "мир между картами держит узел озвучки")
	if audio != null:
		# Без сброса занятости (verifier 26.09 — сброс прятал потерю реплик): финал пропущен
		# Esc целиком, вместе с голосом, так что «Контора» здоровается сразу; объявление нового
		# вида на брифинге — сюжет за сюжетом, встаёт в очередь за приветствием и звучит следом.
		main.show_office(main.show_menu)
		await _frames(1)
		_check(audio._voice_last_msec.has(&"lg_office_enter"), "вход в «Контору» — lg_office_enter")
		Campaign.unlock_all()   # открыты вахтёр/счетовод, плашка «Новое» ещё не показана
		main.show_briefing(second)
		await _frames(2)
		await _wait_quiet(audio)
		var said_new := false
		for id in [&"lg_contract_new_1", &"lg_contract_new_2", &"lg_contract_new_3"]:
			said_new = said_new or audio._voice_last_msec.has(id)
		_check(said_new, "брифинг с новым видом — lg_contract_new_*")

	main.queue_free()
	await _frames(1)
	Campaign.reset()
	print("LEGION CUTSCENE FLOW: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)
