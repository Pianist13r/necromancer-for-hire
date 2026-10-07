extends SceneTree
##
## Регресс B-435: окна подтверждения в стиле игры, а не серый системный диалог Godot.
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_dialog_style_test.gd -- --mute
##
## Запись Игоря 07.10 (r4, 10.08–10.93 с): «В главное меню» из паузы показал серое окно с
## английским заголовком «Please Confirm…» — `LegionUi.confirm` создавал голый
## ConfirmationDialog. Им же подтверждаются «Заново» и удаление карты из коллекции.
## Проверяем оформление обоих путей (подтверждения и окна согласия статистики) и что
## подтверждение по-прежнему выполняет действие, а «Отмена» — нет.
## Итог «LEGION DIALOG STYLE: N/M OK»; код выхода 1, если что-то упало.
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


func _dialog_of(parent: Node) -> ConfirmationDialog:
	for child in parent.get_children():
		if child is ConfirmationDialog and not child.is_queued_for_deletion():
			return child
	return null


## Общие признаки «окно в стиле игры»: русский заголовок, своя рамка окна и панель,
## шрифты игры у заголовка и текста, художественные кнопки.
func _check_styled(d: ConfirmationDialog, where: String) -> void:
	_check(d != null, "%s: окно создано" % where)
	if d == null:
		return
	_check(d.title != "" and not d.title.begins_with("Please"),
		"%s: заголовок свой, не «Please Confirm…» (%s)" % [where, d.title])
	_check(d.has_theme_stylebox_override("embedded_border"),
		"%s: рамка окна своя (embedded_border)" % where)
	_check(d.has_theme_stylebox_override("embedded_unfocused_border"),
		"%s: рамка окна без фокуса своя" % where)
	_check(d.has_theme_stylebox_override("panel"), "%s: панель своя" % where)
	_check(d.has_theme_font_override("title_font"), "%s: шрифт заголовка игры" % where)
	_check(d.get_label().has_theme_font_override("font"), "%s: шрифт текста игры" % where)
	_check(d.get_ok_button().has_theme_stylebox_override("normal"),
		"%s: кнопка «%s» оформлена" % [where, d.get_ok_button().text])
	_check(d.get_cancel_button().has_theme_stylebox_override("normal"),
		"%s: кнопка «%s» оформлена" % [where, d.get_cancel_button().text])


func _run() -> void:
	var parent := Control.new()
	root.add_child(parent)
	await process_frame

	var fired := [0]
	LegionUi.confirm(parent, "Бой будет прерван. Награды прошлых боёв сохранены.",
		func() -> void: fired[0] += 1)
	var d := _dialog_of(parent)
	_check_styled(d, "подтверждение")
	if d != null:
		_check(d.get_ok_button().text == "Подтвердить" and d.get_cancel_button().text == "Отмена",
			"подтверждение: кнопки по-русски")
		d.canceled.emit()
		await process_frame
		_check(fired[0] == 0, "«Отмена» действие не выполняет")
	LegionUi.confirm(parent, "Бой будет начат заново.", func() -> void: fired[0] += 1)
	d = _dialog_of(parent)
	if d != null:
		d.confirmed.emit()
		await process_frame
	_check(fired[0] == 1, "«Подтвердить» выполняет действие ровно один раз")

	# Окно согласия статистики — тот же стиль (раньше рамка окна оставалась серой).
	var metrics := PlayMetrics.new()
	parent.add_child(metrics)
	await process_frame
	metrics.show_consent()
	_check_styled(_dialog_of(metrics), "согласие статистики")

	parent.queue_free()
	await process_frame
	print("LEGION DIALOG STYLE: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)
