extends SceneTree
##
## Регресс «пачки мелочей» 02.10.2026 (ветка slow/small-1002).
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_small_1002_test.gd -- --mute
##
## B-068: шпаргалка паузы берёт числа Дубль-вэ и «Аврала» из LegionCfg, а не пишет словами
## («до четырёх», «в 2,5 раза») — при смене W_RAISE_MAX / E_PRESS_HOLD_MULT не устареет.
## (B-094, B-096, B-097, B-072 уже закрыты в master и проверяются в legion_newbie2_test.gd;
## B-366 — сам legion_gate_jam_test.)
## Итог «LEGION SMALL 1002: N/M OK»; код выхода 1, если что-то упало.
##

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
	print("— B-068: шпаргалка паузы берёт числа из LegionCfg")
	var lines: Array[String] = LegionPause.cheatsheet()
	var w_line := ""
	var e_line := ""
	for l in lines:
		if l.begins_with("Дубль-вэ (W)"):
			w_line = l
		elif l.begins_with("Е (E)"):
			e_line = l
	_check(w_line != "", "строка Дубль-вэ есть")
	_check(e_line != "", "строка «Аврал» есть")
	_check(w_line.contains("до %d " % LegionCfg.W_RAISE_MAX),
		"Дубль-вэ: число трупов — W_RAISE_MAX цифрой (%s)" % w_line)
	_check(not w_line.contains("четыр"), "Дубль-вэ: числа словом нет")
	_check(e_line.contains("×" + LegionAbilityAim.num(LegionCfg.E_PRESS_HOLD_MULT)),
		"Аврал: множитель напора — E_PRESS_HOLD_MULT (%s)" % e_line)
	_check(not e_line.contains("раза"), "Аврал: «в 2,5 раза» словами нет")
	print("LEGION SMALL 1002: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)
