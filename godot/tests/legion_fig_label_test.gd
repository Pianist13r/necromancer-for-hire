extends SceneTree
##
## Регресс подписи фигуры (запись промо 08.10, кадр «Обряд 3/2»): счёт мест в строю над фигурой
## не выходит за порог награды. У «Обряда» мест три, нужно два — «в строю» бывает 3, подпись
## обязана показывать 2/2, а не 3/2.
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_fig_label_test.gd -- --mute
##
## Итог «LEGION FIG LABEL: N/M OK»; код выхода 1, если что-то упало.
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
	var t := ContractField.fig_progress_text("Обряд", 3, 2)
	_check(t == "Обряд 2/2", "три в строю при пороге 2 → «%s» (ждём «Обряд 2/2»)" % t)
	t = ContractField.fig_progress_text("Обряд", 1, 2)
	_check(t == "Обряд 1/2", "один из двух → «%s»" % t)
	t = ContractField.fig_progress_text("Каре", 4, 0)
	_check(t == "Каре 4", "без порога — просто число → «%s»" % t)
	# порог «Обряда» по конфигу — два из трёх мест (FigureCfg.RITE_FILL), подпись не больше него
	var need := ceili(3 * FigureCfg.RITE_FILL - 0.001)
	t = ContractField.fig_progress_text("Обряд", 3, need)
	_check(need == 2 and t.ends_with("%d/%d" % [need, need]), "порог Обряда %d из 3, подпись «%s»"
		% [need, t])
	print("LEGION FIG LABEL: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)
