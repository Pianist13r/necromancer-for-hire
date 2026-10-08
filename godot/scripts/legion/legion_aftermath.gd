class_name LegionAftermath
extends RefCounted
## Экраны завершённого боя. Сохранение наград остаётся транзакцией LegionMain/Campaign.


static func result(main: LegionMain, map_id: String, victory: bool, stats: Dictionary,
		stars: int, has_next: bool, complete: bool, rewards: Dictionary) -> void:
	main._teardown_screen()
	var screen := LegionResult.new()
	main._set_screen(screen)
	screen.call_deferred("show_result", victory, stats, stars, has_next, complete, rewards)
	screen.next.connect(main._on_result_next)
	# Повтор — такой же выбор карты: сначала незабранная награда, затем подготовка.
	screen.retry.connect(func() -> void: main._on_map_chosen(map_id))
	screen.maps.connect(main.show_map_select)
	screen.menu.connect(main.show_menu)


static func necrolog(main: LegionMain, report: Dictionary, foe: String, title: String,
		collect: bool) -> void:
	main._teardown_screen()
	var screen := Necrolog.new()
	main._set_screen(screen)
	screen.call_deferred("show_report", report, foe, title, collect)
	screen.menu.connect(main.show_menu)
	if collect:
		screen.collect_pressed.connect(func() -> void: LegionCollectionFlow.save_current(main))
	screen.restart.connect(func() -> void:
		main._start_endless_flow(bool(report.get("daily", false))))
