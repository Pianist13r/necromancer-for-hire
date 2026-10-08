extends SceneTree
##
## Регресс «вид не трогает глобальный генератор случайных чисел» (D-1008-S14, 08.10.2026):
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_view_rng_test.gd -- --mute
##
## Симуляция ходит на world.rng; глобальные randf()/randi() — ничьи. Пока тряска Juicee брала
## сид шума из randi(), а окно Juice.permit шло по настенным часам, число тряск за бой зависело
## от нагрузки машины, и тест линий (п. 5: бой одинаков в полной и экономной графике) под
## параллельным гейтом ловил расхождение глобального RNG между графиками. Здесь два уровня:
## 1) живой: после тряски и вспышки через обёртку Juice глобальный RNG даёт то же число, что без них;
## 2) статический: ни один скрипт игры (addons/juicee, scripts/**) вне тестов не зовёт глобальные
##    randf/randi/randf_range/randi_range/randfn/randomize/seed, pick_random/shuffle —
##    кроме перечисленных исключений вне симуляции и вида (меню «Схватки»: случайный номер поля).
## Итог «LEGION VIEW RNG: N/M OK»; код выхода 1, если что-то упало.
##

const SAVE := "user://legion_view_rng_test.cfg"
const WORLD_SCENE := "res://scenes/legion_world.tscn"
const SCAN_DIRS := ["res://addons/juicee", "res://scripts"]
## Вне симуляции и вида: номер поля для меню «Схватки» — не бой и не кадр.
const ALLOWED := ["res://scripts/legion/pvp/pvp_field_select.gd"]
const GLOBAL_RNG := "(^|[^\\w.])(randf_range|randi_range|randf|randi|randfn|randomize|seed)\\s*\\("
const ARRAY_RNG := "\\.(pick_random|shuffle)\\s*\\("

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
	await _live()
	_static()
	print("LEGION VIEW RNG: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


## Тряска и вспышка через обёртку Juice (как удары Котла, молния, каст героя) не сдвигают
## глобальный RNG: тот же seed → то же число после эффектов, что и без них.
func _live() -> void:
	print("— живой: тряска и вспышка Juicee не трогают глобальный RNG")
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	var w := load(WORLD_SCENE).instantiate() as LegionWorld
	root.add_child(w)
	await process_frame
	w.set_process(false)
	_check(Settings.is_screen_shake_enabled(), "тряска включена (настройки по умолчанию)")
	_check(Settings.is_flashes_enabled(), "вспышки включены (настройки по умолчанию)")
	_check(root.get_node_or_null("Juicee") != null, "автолоад Juicee есть")
	seed(2026_10_08)
	var expect := randi()
	seed(2026_10_08)
	# два окна permit: FxClock — настенные часы вне записи, окно 300 мс
	Juice.shake(w, 6.0, 0.18)
	Juice.flash(w, Color.WHITE, 0.15)
	for i in 30:
		await process_frame
	await create_timer(0.35).timeout
	Juice.shake(w, 6.0, 0.18)
	for i in 30:
		await process_frame
	var got := randi()
	_check(got == expect, "после тряски и вспышки глобальный RNG не тронут (%d == %d)" % [got, expect])
	w.queue_free()
	await process_frame
	Campaign.reset()


## Статически: глобальный RNG не зовётся нигде в игре, кроме исключений.
func _static() -> void:
	print("— статический: скрипты игры не зовут глобальный RNG")
	var re_global := RegEx.new()
	re_global.compile(GLOBAL_RNG)
	var re_array := RegEx.new()
	re_array.compile(ARRAY_RNG)
	var files: Array[String] = []
	for d in SCAN_DIRS:
		_collect(d, files)
	_check(files.size() > 100, "просканировано скриптов: %d" % files.size())
	var hits: Array[String] = []
	for path in files:
		if path in ALLOWED or path.begins_with("res://scripts/dev/"):
			continue
		var text := FileAccess.get_file_as_string(path)
		var n := 0
		for line in text.split("\n"):
			n += 1
			var code := line.get_slice("#", 0) if not line.begins_with("##") else ""
			if code.strip_edges().is_empty():
				continue
			if re_global.search(code) != null or re_array.search(code) != null:
				hits.append("%s:%d: %s" % [path, n, line.strip_edges()])
	for h in hits:
		print("    ", h)
	_check(hits.is_empty(), "вызовов глобального RNG вне исключений нет (%d)" % hits.size())


func _collect(dir: String, out: Array[String]) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	d.list_dir_begin()
	var name := d.get_next()
	while name != "":
		var path := dir.path_join(name)
		if d.current_is_dir():
			if not name.begins_with("."):
				_collect(path, out)
		elif name.ends_with(".gd"):
			out.append(path)
		name = d.get_next()
	d.list_dir_end()
