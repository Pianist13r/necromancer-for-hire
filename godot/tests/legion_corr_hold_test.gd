extends SceneTree
##
## B-504 (13.10.2026): кампания по переписке — бой, начавшийся, пока corr ждёт ход меню, шёл сам.
## Ход меню снят на «Подготовке боя…», мира ещё нет; загрузка кончается, пока агент думает,
## legion_main создаёт мир и начинает бой, а прежний world.hold к новому объекту не относился —
## в партии a1 ход 4 (меню) ждал 36 с, ход 5 был уже боем на t 66,3, вторая волна.
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_corr_hold_test.gd -- --mute
##
## Поддельный главный узел (как legion_corr_campaign_test), но мир настоящий (legion_world.tscn,
## карта _gray без волн и армии, embedded — как у LegionMain). Последовательность:
##  1) ход 0 — меню, мира нет; пока corr ждёт move_000, мир появляется и входит в бой —
##     часы мира стоят (на старом коде шли: это и есть B-504);
##  2) move_000 {wait 0,5} — ход исполняется как ход боя: часы ушли ровно на 0,5;
##     ход 1 — бой, и пока нет move_001, мир снова стоит;
##  3) бой кончился, пока corr ждёт, — экран итога не удерживается; ход 2 — меню;
##     следующий бой на том же объекте, начатый в ожидании, стоит, а move_002 его ведёт
##     (бой следующей карты не заморожен);
##  4) главный узел сменил объект мира — новый держится, прежний отпущен;
##  5) corr ушёл — удержание снято, мир идёт сам.
## Итог «LEGION CORR HOLD: N/M OK», код 1 при сбое.
##

const SAVE := "user://legion_corr_hold_test.cfg"
const DIR := "user://legion_corr_hold_test"
const CORR := "res://scripts/dev/corr_play.gd"
const WORLD := "res://scenes/legion_world.tscn"
const MAP := "_gray"
## Сколько кадров ждать без хода: на старом коде при --fixed-fps 60 бой уходил на 1,5 с.
const IDLE_FRAMES := 90
const WAIT := 0.5

var dir_abs := ""
var fake: Node
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


## Ход N: ждём, пока corr_play выложит состояние, читаем его.
func _state(n: int) -> Dictionary:
	var p := dir_abs.path_join("turn_%03d.json" % n)
	for i in 1200:
		if FileAccess.file_exists(p) and _waiting() == str(n):
			break
		await process_frame
	await _frames(2)
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(p))
	return parsed as Dictionary if parsed is Dictionary else {}


func _waiting() -> String:
	return FileAccess.get_file_as_string(dir_abs.path_join("waiting.txt"))


## Записать ход N атомарно (временный файл → переименование) и дождаться хода N+1.
func _move(n: int, move: Dictionary) -> Dictionary:
	var p := dir_abs.path_join("move_%03d.json" % n)
	var f := FileAccess.open(p + ".tmp", FileAccess.WRITE)
	f.store_string(JSON.stringify(move))
	f.close()
	DirAccess.rename_absolute(p + ".tmp", p)
	return await _state(n + 1)


## Бой на мире так же, как legion_main.start_battle: мир уже у главного узла, start_map сразу.
func _start_battle(w: LegionWorld) -> void:
	w.dev = {"no_waves": "1", "spawn_units": "0"}
	fake.set("world", w)
	w.start_map(MAP)
	for i in 600:
		if not w.is_ground_loading():
			break
		await process_frame


## Пока хода N нет, часы мира стоят IDLE_FRAMES кадров. Возвращает часы мира.
func _idle(w: LegionWorld, n: int, what: String) -> float:
	var t0 := w.now
	await _frames(IDLE_FRAMES)
	var no_move := not FileAccess.file_exists(dir_abs.path_join("move_%03d.json" % n))
	_check(_waiting() == str(n) and no_move, "%s: corr всё ещё ждёт ход %d" % [what, n])
	_check(w.hold and w.now == t0,
		"%s: без хода мир стоит (t %.3f → %.3f за %d кадров, hold %s)" % [what, t0, w.now,
			IDLE_FRAMES, w.hold])
	return w.now


func _run() -> void:
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	dir_abs = ProjectSettings.globalize_path(DIR)
	DirAccess.make_dir_recursive_absolute(dir_abs)
	for f in DirAccess.get_files_at(dir_abs):
		DirAccess.remove_absolute(dir_abs.path_join(f))

	var fake_src := GDScript.new()
	fake_src.source_code = "extends Node\nvar world = null\nvar screen: Control = null\n"
	fake_src.reload()
	fake = Node.new()
	fake.set_script(fake_src)
	root.add_child(fake)
	var screen := Control.new()
	screen.size = Vector2(1280, 720)
	fake.add_child(screen)
	fake.set("screen", screen)
	var loading := Label.new()
	loading.text = "Подготовка боя…"
	loading.position = Vector2(240, 300)
	screen.add_child(loading)

	# corr — ребёнок главного узла раньше мира, как в legion_main._ready
	var corr: Node = (load(CORR) as GDScript).new()
	corr.call("setup_main", fake, dir_abs)
	fake.add_child(corr)

	print("— 1) бой начался, пока corr ждёт ход меню")
	var st := await _state(0)
	_check(String(st.get("mode", "")) == "menu", "ход 0 — меню (мира ещё нет)")
	var w := (load(WORLD) as PackedScene).instantiate() as LegionWorld
	w.embedded = true
	fake.add_child(w)
	await _start_battle(w)
	_check(w.phase == LegionWorld.Phase.BATTLE and not w.is_ground_loading(),
		"мир в бою на %s" % MAP)
	await process_frame
	var n0 := w.now
	_check(n0 < 0.05, "бой удержан с первого кадра (t %.3f)" % n0)
	n0 = await _idle(w, 0, "ход меню 0")

	print("— 2) ход к кадру меню исполняется как ход боя")
	st = await _move(0, {"actions": [], "wait": WAIT})
	var n1 := w.now
	_check(String(st.get("mode", "")) == "battle", "ход 1 — бой")
	_check(n1 >= n0 + WAIT - 0.001 and n1 <= n0 + WAIT + 0.05,
		"ход отдал свой wait: t %.3f → %.3f (ждали +%.1f)" % [n0, n1, WAIT])
	_check(absf(float(st.get("t", -1.0)) - n1) <= 0.051,
		"кадр хода 1 снят на тех же часах: %s" % st.get("t"))
	await _idle(w, 1, "ход боя 1")

	print("— 3) итог не удерживается, следующий бой стоит до своего хода")
	w.force_end(false)
	await _frames(2)
	_check(w.phase == LegionWorld.Phase.DEFEAT and not w.hold,
		"экран итога: мир не на удержании")
	st = await _move(1, {"actions": [], "wait": 0.1})
	_check(String(st.get("mode", "")) == "menu", "ход 2 — меню (итог)")
	await _start_battle(w)
	await process_frame
	var n2 := w.now
	_check(w.phase == LegionWorld.Phase.BATTLE and n2 < 0.05,
		"следующий бой на том же мире удержан с начала (t %.3f)" % n2)
	n2 = await _idle(w, 2, "ход меню 2")
	st = await _move(2, {"actions": [], "wait": WAIT})
	_check(String(st.get("mode", "")) == "battle" and w.now >= n2 + WAIT - 0.001
		and w.now <= n2 + WAIT + 0.05,
		"ход 3 — бой, часы ушли на свой wait: t %.3f → %.3f" % [n2, w.now])

	print("— 4) главный узел сменил объект мира")
	var other := (load(WORLD) as PackedScene).instantiate() as LegionWorld
	# вне дерева: проверяется только, кого держит corr (hold — поле объекта)
	other.phase = LegionWorld.Phase.BATTLE
	fake.set("world", other)
	await _frames(2)
	_check(other.hold, "новый объект мира в бою удержан")
	_check(not w.hold, "прежний объект отпущен")
	_check(other.synthetic_input and not w.synthetic_input,
		"синтетический ввод перешёл на новый мир; старый снова подчиняется фокусу")
	fake.set("world", w)
	await _frames(2)
	_check(w.hold and not other.hold, "вернули прежний — держится он, второй отпущен")
	_check(w.synthetic_input and not other.synthetic_input, "флаг ввода следует за миром corr")
	other.free()

	print("— 5) corr ушёл — удержания нет")
	corr.queue_free()
	await _frames(2)
	var n5 := w.now
	await _frames(30)
	_check(not w.hold and w.now > n5, "мир без corr идёт сам: t %.3f → %.3f" % [n5, w.now])
	_check(not w.synthetic_input, "после удаления corr в кампании вернулся человеческий ввод")

	w.queue_free()
	fake.queue_free()
	await process_frame
	_finish()


func _finish() -> void:
	Campaign.reset()
	print("LEGION CORR HOLD: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)
