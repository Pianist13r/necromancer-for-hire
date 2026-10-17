extends SceneTree
##
## B-505 (13.10.2026): в corr-партии при побайтно одинаковом вводе штрих Аудита хода 001 пропал:
## на peek2 черновика нет, в state002 договора нет. Здесь проверяется управляемая гипотеза:
## NOTIFICATION_APPLICATION_FOCUS_OUT отменяет жест (B-056, Alt+Tab человека).
## Исходный PS не содержит журнала фокуса и этому механизму НЕ атрибутирован. Оконный probe
## за 40 секунд не воспроизвёл APPLICATION_FOCUS_OUT; B-505 остаётся открытым.
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_corr_focus_test.gd -- --mute
##
## Проверяет: 1) штрих corr, посреди которого дерево получило FOCUS_OUT, всё равно даёт договор
## (мир отмечен synthetic_input); 2) ввод человека без флага по-прежнему отменяется (B-056);
## 3) штрих без черновика перед отпусканием оставляет строку в журнале состояния (диагностика);
## 4) события фокуса попадают в журнал. Итог «LEGION CORR FOCUS: N/M OK», код 1 при сбое.
##

const SAVE := "user://legion_corr_focus_test.cfg"
const DIR := "user://legion_corr_focus_test"
const CORR := "res://scripts/dev/corr_play.gd"
const MAP := "_gray"
const A := Vector2(300.0, 200.0)
const B := Vector2(300.0, 320.0)

var w: LegionWorld
var corr: Node
var dir_abs := ""
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


func _waiting() -> String:
	return FileAccess.get_file_as_string(dir_abs.path_join("waiting.txt"))


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


## Записать ход N атомарно (временный файл → переименование), не дожидаясь следующего хода.
func _write_move(n: int, move: Dictionary) -> void:
	var p := dir_abs.path_join("move_%03d.json" % n)
	var f := FileAccess.open(p + ".tmp", FileAccess.WRITE)
	f.store_string(JSON.stringify(move))
	f.close()
	DirAccess.rename_absolute(p + ".tmp", p)


## Ход со штрихом A→B; когда у поля появился черновик — всему дереву приходит FOCUS_OUT, как от
## движка при потере фокуса окна. Возвращает состояние следующего хода и был ли пойман черновик.
func _stroke_with_focus_out(n: int) -> Dictionary:
	var before := w.contracts.contracts.size()
	_write_move(n, {"actions": [{"draw": [[A.x, A.y], [B.x, B.y]]}], "wait": 0.2})
	var caught := false
	for i in 600:
		if w.contracts.has_draft():
			caught = true
			root.propagate_notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
			break
		await process_frame
	var st := await _state(n + 1)
	return {"state": st, "caught": caught, "added": w.contracts.contracts.size() - before}


func _attach() -> void:
	dir_abs = ProjectSettings.globalize_path(DIR)
	DirAccess.make_dir_recursive_absolute(dir_abs)
	for f in DirAccess.get_files_at(dir_abs):
		DirAccess.remove_absolute(dir_abs.path_join(f))
	corr = (load(CORR) as GDScript).new()
	corr.call("setup", w, dir_abs)
	root.add_child(corr)


func _log_has(st: Dictionary, needle: String) -> bool:
	for line in st.get("log", []):
		if String(line).contains(needle):
			return true
	return false


func _run() -> void:
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	Settings.scheme_override = Settings.SCHEME_SLING
	w = (load("res://scenes/legion_world.tscn") as PackedScene).instantiate() as LegionWorld
	root.add_child(w)
	await _frames(2)
	w.dev = {"no_waves": "1", "spawn_units": "0"}
	w.args.erase("bot")
	w.start_map(MAP)
	w.dev_invuln = false
	w.contracts.mana = w.contracts.mana_max
	await _frames(3)
	_check(not w.synthetic_input, "до corr мир считает ввод человеческим")

	print("— 1) штрих corr переживает потерю фокуса окна")
	_attach()
	var st := await _state(0)
	_check(w.synthetic_input, "corr отметил мир: ввод синтетический")
	_check(String(st.get("mode", "battle")) == "battle" and not bool(st.get("over", true)),
		"ход 0 — бой")
	var r := await _stroke_with_focus_out(0)
	_check(bool(r["caught"]), "FOCUS_OUT пришёл посреди протяжки (черновик был)")
	_check(int(r["added"]) == 1, "договор создан, несмотря на FOCUS_OUT (+%d)" % int(r["added"]))
	var cs: Array = (r["state"] as Dictionary).get("contracts", [])
	_check(cs.size() == 1, "в состоянии хода 1 ровно один договор (%d)" % cs.size())
	_check(_log_has(r["state"], "APPLICATION_FOCUS_OUT"),
		"событие фокуса записано в журнал состояния")
	_check(not _log_has(r["state"], "без черновика"),
		"ложной записи «штрих без черновика» нет")

	print("— 2) диагностика: штрих без черновика виден в журнале")
	w.contracts.mana = 0.0   # begin() молча откажет — ровно тот случай, что B-505 не показал
	_write_move(1, {"actions": [{"draw": [[A.x + 200.0, A.y], [B.x + 200.0, B.y]]}], "wait": 0.2})
	st = await _state(2)
	_check(w.contracts.contracts.size() == 1, "без маны новый договор не появился")
	_check(_log_has(st, "отпущен без черновика"),
		"в журнале хода: штрих отпущен без черновика (%s)" % [st.get("log", [])])
	w.contracts.mana = w.contracts.mana_max

	print("— 3) ввод человека: FOCUS_OUT по-прежнему отменяет штрих (B-056)")
	await corr.call("_button", A + Vector2(0.0, 300.0), MOUSE_BUTTON_LEFT, true)
	await corr.call("_move", A + Vector2(60.0, 300.0), MOUSE_BUTTON_MASK_LEFT)
	await corr.call("_key_state", KEY_SPACE, true)
	_check(w.contracts.has_draft() and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
		and Input.is_physical_key_pressed(KEY_SPACE), "до удаления corr есть незавершённый жест")
	corr.queue_free()
	await _frames(2)
	_check(not w.synthetic_input, "удаление corr снимает синтетический режим с живого мира")
	_check(not w.contracts.has_draft(), "удаление corr отменяет черновик без создания договора")
	_check(not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
		and not Input.is_physical_key_pressed(KEY_SPACE), "удаление corr отпускает свои ЛКМ и Пробел")
	var f := w.contracts
	var mana0 := f.mana
	f.begin(A + Vector2(0.0, 300.0))
	f.extend(A + Vector2(60.0, 300.0))
	_check(f.has_draft(), "черновик человека начат")
	root.propagate_notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	_check(not f.has_draft() and f.contracts.size() == 1 and is_equal_approx(f.mana, mana0),
		"потеря фокуса у человека: черновик снят, мана возвращена")

	print("— 4) с флагом, но без corr: жест не рвётся (флаг — единственное условие)")
	w.synthetic_input = true
	f.begin(A + Vector2(0.0, 400.0))
	f.extend(A + Vector2(60.0, 400.0))
	root.propagate_notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	_check(f.has_draft(), "черновик цел после FOCUS_OUT")
	f.cancel()

	w.queue_free()
	await process_frame
	Campaign.reset()
	print("LEGION CORR FOCUS: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)
