extends SceneTree
##
## Потеря фокуса окна посреди одиночного боя ДОЛЖНА открывать меню паузы.
##
## Регресс к багу владельца 06.10.2026: «игра ставится на паузу, но меню паузы не открывается,
## но снимается с паузы эскейпом». Причина — не в логике паузы, а в способе доставки уведомления
## движком: при NOTIFICATION_APPLICATION_FOCUS_OUT SceneTree зовёт
## get_root()->propagate_notification() (scene/main/scene_tree.cpp), а Node::propagate_notification
## поднимает Node.data.blocked на КАЖДОМ узле-предке на время прохода. Пока проход не дошёл до
## мира, LegionMain «занят» (data.blocked > 0), и синхронный add_child(экран паузы) падает с
## «Parent node is busy setting up children». Экран создан, но в дерево не добавлен → пауза есть,
## меню нет.
##
## Здесь уведомление рассылается ТЕМ ЖЕ способом (propagate_notification), а пауза взводится
## водителем-узлом внутри LegionMain: в headless сам мир паузу от уведомления не ставит
## (legion_world.gd:2830 — прогоны без окна не зависят от фокуса), но механика доставки та же.

var _checks := 0
var _fails := 0
var main: Node
var w: LegionWorld


## Взводит паузу ровно как мир в своём _notification(NOTIFICATION_APPLICATION_FOCUS_OUT): адресно
## зовёт focus_lost() (в headless мир сам это пропускает по гарду, см. докстринг файла).
class _FocusDriver:
	extends Node
	var world: LegionWorld

	func _notification(what: int) -> void:
		if what == Node.NOTIFICATION_APPLICATION_FOCUS_OUT and world != null:
			world.focus_lost()


func _initialize() -> void:
	_run.call_deferred()


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_fails += 1
		print("FAIL: ", message)


func _pause_screen() -> Node:
	return main.get("_pause_screen")


func _menu_open() -> bool:
	var ps := _pause_screen()
	return is_instance_valid(ps) and ps.is_inside_tree()


func _deliver_focus_out() -> void:
	# Ровно как движок: рассылка по всему дереву (поднимает data.blocked у предков LegionMain).
	root.propagate_notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	await process_frame   # отложенная вставка экрана (фикс) успевает выполниться
	await process_frame


func _run() -> void:
	Campaign.set_save_path("user://legion_focus_pause_menu_test.cfg")
	Campaign.reset()
	main = (load("res://scenes/legion.tscn") as PackedScene).instantiate()
	root.add_child(main)
	await process_frame
	await process_frame
	main.call("start_battle", "wasteland")
	var guard := 0
	while (w == null or w.phase != LegionWorld.Phase.BATTLE) and guard < 900:
		w = main.get("world")
		await process_frame
		guard += 1
	if w == null or w.phase != LegionWorld.Phase.BATTLE:
		print("FAIL: бой не стартовал")
		quit(1)
		return
	await process_frame
	var drv := _FocusDriver.new()
	drv.world = w
	main.add_child(drv)

	# 1. Потеря фокуса → пауза и открытое меню.
	await _deliver_focus_out()
	_check(w.paused, "потеря фокуса ставит бой на паузу")
	_check(_menu_open(), "меню паузы открылось (экран в дереве)")

	# 2. Esc снимает паузу и закрывает меню.
	w.set_paused(false)
	await process_frame
	await process_frame
	_check(not w.paused, "Esc снимает паузу")
	_check(not _menu_open(), "меню паузы закрылось")

	# 3. Повторная потеря фокуса снова открывает меню (а не молчит из-за осиротевшего экрана).
	await _deliver_focus_out()
	_check(w.paused, "повторная потеря фокуса ставит паузу")
	_check(_menu_open(), "повторное меню паузы открылось")

	w.set_paused(false)
	await process_frame
	drv.queue_free()
	main.queue_free()
	await process_frame
	print("FOCUS PAUSE MENU: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails else 0)
