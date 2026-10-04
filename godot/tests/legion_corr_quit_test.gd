extends SceneTree
##
## B-354 (30.09.2026): выход из игры по переписке. Скилл corr-play и докстринг corr_play.gd велят
## {"quit": true}, а код искал quit только внутри actions — верхний ключ молча становился пустым
## ходом, игра висела (две по ~0,9 ГБ в «Вызове дня»). Теперь выходят обе формы.
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_corr_quit_test.gd -- --mute
##
## Поддельный главный узел (как legion_corr_campaign_test): мира нет, ход меню. corr_play —
## подкласс с подменённым _quit (настоящий закрыл бы сам тест). Итог
## «LEGION CORR QUIT: N/M OK», код 1 при сбое.
##

const SAVE := "user://legion_corr_quit_test.cfg"
const DIR := "user://legion_corr_quit_test"
const CORR := "res://scripts/dev/corr_play.gd"

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
	var corr_script := load(CORR) as GDScript
	_check(corr_script.has_method("top_quit"), "corr_play знает верхний ключ quit (top_quit)")
	if not corr_script.has_method("top_quit"):
		_finish()
		return
	_check(bool(corr_script.call("top_quit", {"quit": true})), "{\"quit\": true} — выход")
	_check(not bool(corr_script.call("top_quit", {"actions": [], "wait": 1.0})),
		"обычный ход — не выход")
	_check(not bool(corr_script.call("top_quit", {"quit": false})), "{\"quit\": false} — не выход")
	# верхний ключ: игра закрывается на первом же ходе
	var got := await _play({"quit": true}, "top")
	_check(got == 0, "ход {\"quit\": true} закрывает игру кодом 0 (было: %d)" % got)
	# рабочая прежде форма — внутри actions — тоже закрывает
	got = await _play({"actions": [{"quit": true}]}, "inner")
	_check(got == 0, "ход {\"actions\": [{\"quit\": true}]} закрывает игру (было: %d)" % got)
	# обычный ход не закрывает: corr ждёт следующий ход
	got = await _play({"actions": [], "wait": 0.1}, "plain")
	_check(got == -1, "пустой ход игру не закрывает (было: %d)" % got)
	_finish()


## Один ход меню: ждать turn_000, положить move_000, дать corr поработать. Код выхода
## подменённого _quit или -1, если выхода не было.
func _play(move: Dictionary, tag: String) -> int:
	var dir_abs := ProjectSettings.globalize_path(DIR).path_join(tag)
	DirAccess.make_dir_recursive_absolute(dir_abs)
	for f in DirAccess.get_files_at(dir_abs):
		DirAccess.remove_absolute(dir_abs.path_join(f))
	var fake_src := GDScript.new()
	fake_src.source_code = "extends Node\nvar world = null\nvar screen: Control = null\n"
	fake_src.reload()
	var fake: Node = Node.new()
	fake.set_script(fake_src)
	root.add_child(fake)
	var screen := Control.new()
	screen.size = Vector2(1280, 720)
	fake.add_child(screen)
	fake.set("screen", screen)
	var probe_src := GDScript.new()
	probe_src.source_code = ("extends \"%s\"\nvar quit_code := -1\n" % CORR
		+ "func _quit(code: int) -> void:\n\tquit_code = code\n")
	probe_src.reload()
	var corr: Node = Node.new()
	corr.set_script(probe_src)
	corr.call("setup_main", fake, dir_abs)
	root.add_child(corr)
	var turn_path := dir_abs.path_join("turn_000.json")
	for i in 600:
		if FileAccess.file_exists(turn_path):
			break
		await process_frame
	_check(FileAccess.file_exists(turn_path), "[%s] ход 0 записан" % tag)
	var f := FileAccess.open(dir_abs.path_join("move_000.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(move))
	f.close()
	# ход меню ждёт MENU_WAIT реальных секунд после действий; выход — сразу после чтения хода
	var t_end := Time.get_ticks_msec() + 3000
	while Time.get_ticks_msec() < t_end and int(corr.get("quit_code")) == -1:
		await process_frame
	var code := int(corr.get("quit_code"))
	corr.queue_free()
	fake.queue_free()
	await process_frame
	return code


func _finish() -> void:
	Campaign.reset()
	print("LEGION CORR QUIT: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)
