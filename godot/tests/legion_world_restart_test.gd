extends SceneTree
##
## Бой на мире, который уже играл, — тот же, что на свежем мире (10.10.2026, slow/determinism):
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_world_restart_test.gd -- --mute
##
## LegionMain держит один мир на сеанс: «Ещё раз», следующая карта, серии на одном мире идут
## через start_map поверх прошлого боя. Часы вербовки _assign_t переживали start_map (сбрасывал
## их только start_net_match), и расписание вербовки сдвигалось на остаток прошлого боя — два
## одинаковых боя расходились с шага ~120 (fork s2, бот selective). Здесь отпечаток
## LegionWorld.net_digest() каждые 60 шагов до 600 на мире с историей сравнивается с боем на
## свежем встроенном мире:
##   1) «Ещё раз»: тот же fork s2 после недоигранного fork s2 (437 шагов — не кратно интервалу);
##   2) другая карта прежде: wasteland s3 (299 шагов), затем fork s2;
##   3) корневой мир (не embedded) сам стартовал бой из аргументов и прожил кадры, затем fork s2;
##   4) «Схватка» бот против бота pvp:duel s7 после недоигранной pvp:duel s7 (333 шага).
## Итог «LEGION WORLD RESTART: N/M OK»; код выхода 1, если что-то упало.
##

const SAVE := "user://legion_world_restart_test.cfg"
const WORLD_SCENE := "res://scenes/legion_world.tscn"
const DT := 1.0 / 60.0
const STEPS := 600
const DIGEST_EVERY := 60
## Кадров, которые корневой мир живёт своим боем до start_map (как меню/автостарт до «Начать»).
const ROOT_FRAMES := 5

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
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	print("— эталон: свежие встроенные миры")
	var fork_ref := await _fresh("fork", 2, false)
	var duel_ref := await _fresh("pvp:duel", 7, true)
	_check(fork_ref.size() == STEPS / DIGEST_EVERY, "fork s2: отпечатков %d" % fork_ref.size())
	_check(duel_ref.size() == STEPS / DIGEST_EVERY, "pvp:duel s7: отпечатков %d" % duel_ref.size())

	print("— 1) «Ещё раз»: fork s2 после недоигранного fork s2")
	var w := await _world(true)
	_play(w, "fork", 2, false, 437)
	_same(_play(w, "fork", 2, false, STEPS), fork_ref, "fork s2 повтором на том же мире")
	await _free(w)

	print("— 2) другая карта прежде: wasteland s3, затем fork s2")
	w = await _world(true)
	_play(w, "wasteland", 3, false, 299)
	_same(_play(w, "fork", 2, false, STEPS), fork_ref, "fork s2 после wasteland на том же мире")
	await _free(w)

	print("— 3) корневой мир: автостарт из аргументов, %d кадров, затем fork s2" % ROOT_FRAMES)
	w = await _world(false)
	w.set_process(true)
	for i in ROOT_FRAMES:
		await process_frame
	w.set_process(false)
	_same(_play(w, "fork", 2, false, STEPS), fork_ref, "fork s2 после автостарта корневого мира")
	await _free(w)

	print("— 4) «Схватка»: pvp:duel s7 после недоигранной pvp:duel s7")
	w = await _world(true)
	_play(w, "pvp:duel", 7, true, 333)
	_same(_play(w, "pvp:duel", 7, true, STEPS), duel_ref, "pvp:duel s7 повтором на том же мире")
	await _free(w)

	Campaign.reset()
	print("LEGION WORLD RESTART: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


func _world(embedded: bool) -> LegionWorld:
	var w := load(WORLD_SCENE).instantiate() as LegionWorld
	w.embedded = embedded
	root.add_child(w)
	await process_frame
	w.set_process(false)   # шагает тест (_step), кадр мира не вмешивается
	return w


func _free(w: LegionWorld) -> void:
	w.queue_free()
	await process_frame
	Campaign.reset()


func _fresh(map_id: String, seed_value: int, duel: bool) -> Array[String]:
	var w := await _world(true)
	var out := _play(w, map_id, seed_value, duel, STEPS)
	await _free(w)
	return out


## Бой с ботами на этом мире: steps шагов (или до конца боя); отпечатки каждые DIGEST_EVERY.
func _play(w: LegionWorld, map_id: String, seed_value: int, duel: bool,
		steps: int) -> Array[String]:
	w.dev = {"difficulty": "intern"}
	w.dev_invuln = false
	w.args.erase("bot")
	w.args.erase("pvp_bots")
	if duel:
		w.args["pvp_bots"] = true
	else:
		w.args["bot"] = "selective"
	w._base_seed = seed_value
	w.start_map(map_id)
	var out: Array[String] = []
	for n in range(1, steps + 1):
		if w.phase != LegionWorld.Phase.BATTLE:
			break
		w._step(DT)
		if n % DIGEST_EVERY == 0:
			out.append(w.net_digest())
	return out


func _same(got: Array[String], ref: Array[String], what: String) -> void:
	var first := -1
	for i in mini(got.size(), ref.size()):
		if got[i] != ref[i]:
			first = i
			break
	if first >= 0:
		print("    первое расхождение на шаге %d" % ((first + 1) * DIGEST_EVERY))
	_check(first < 0 and got.size() == ref.size(),
		"%s = свежий мир (%d отпечатков до шага %d)" % [what, got.size(), got.size() * DIGEST_EVERY])
