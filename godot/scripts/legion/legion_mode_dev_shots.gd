class_name LegionModeDevShots
extends RefCounted
##
## Кадры экранов mode line для приёмки (--dev screen=menu_endless|menu_daily_locked|
## endless_briefing|necrolog|necrolog_abandon|collection) — вынесены из
## LegionMain._capture_dev_screen ради max-file-lines (тот же приём, что LegionCollectionFlow).
## Сохранение уже подменено на временное вызывающим (user://legion_dev_shot.cfg) — настоящее
## владельца не трогается.
##


## true — кадр этого имени поставлен; false — имя не из mode line (вызывающий сообщит об ошибке).
static func show(main: LegionMain, screen_name: String) -> bool:
	match screen_name:
		"menu_endless":
			# меню с открытыми «Бесконечным подрядом»/«Вызовом дня» — кампания пройдена целиком;
			# плюс запись коллекции (D-0927-162), чтобы был виден пункт «Коллекция».
			_complete_campaign()
			LegionCollection.save({
				"map_id": "gen:1001:3", "version": LegionEndless.STUB_VERSION,
				"title": "Винтовая аллея согласований", "biome": "grave", "archetype": "спираль",
				"difficulty": LegionChallenge.NORMAL, "source": "endless",
				"saved_date": LegionEndless.today_date(), "best_result": {},
			})
			main.show_menu()
		"menu_daily_locked":
			# D-0927-96: меню с закрытой на сегодня кнопкой «Вызов дня» (попытка уже сыграна).
			_complete_campaign()
			Campaign.use_daily_scope()
			LegionRunStore.endless_start(LegionEndless.daily_seed(LegionEndless.today_date()),
				LegionEndless.today_date())
			LegionRunStore.endless_object_won(90)
			LegionRunStore.endless_end_run()
			Campaign.use_campaign_scope()
			main.show_menu()
		"endless_briefing":
			main._endless_daily = false
			Campaign.use_endless_scope()
			LegionRunStore.endless_start(LegionEndless.random_seed())
			main.show_endless_briefing()
		"necrolog":
			Campaign.use_endless_scope()
			LegionRunStore.endless_start(LegionEndless.random_seed())
			LegionRunStore.endless_object_won(120)
			LegionRunStore.endless_object_won(340)
			var report := LegionRunStore.endless_end_run()
			Campaign.use_campaign_scope()
			main._show_necrolog(report, "signer", "Проходная у Моста")
		"necrolog_abandon":
			# D-0927-96: некролог от подтверждённого выхода посреди объекта «Вызова дня».
			Campaign.use_daily_scope()
			LegionRunStore.endless_start(LegionEndless.daily_seed(LegionEndless.today_date()),
				LegionEndless.today_date())
			LegionRunStore.lock_daily_difficulty(Settings.difficulty())
			LegionRunStore.endless_object_won(90)
			var report_ab := LegionRunStore.endless_end_run()
			Campaign.use_campaign_scope()
			main._show_necrolog(report_ab, LegionEndless.ABANDON_TYPE, "Проходная у Моста")
		"collection":
			# два образца — свежий и «старая версия генератора» — на кадр приёмки.
			LegionCollection.save({
				"map_id": "gen:1001:3", "version": LegionEndless.STUB_VERSION,
				"title": "Винтовая аллея согласований", "biome": "grave", "archetype": "спираль",
				"difficulty": LegionChallenge.NORMAL, "source": "endless",
				"saved_date": LegionEndless.today_date(),
				"best_result": {"victory": true, "hp_ratio": 0.72, "kills": 140},
			})
			LegionCollection.save({
				"map_id": "gen:1002:5", "version": LegionEndless.STUB_VERSION - 1,
				"title": "Котлован особой важности", "biome": "site", "archetype": "остров",
				"difficulty": LegionChallenge.HELL, "source": "daily",
				"saved_date": LegionEndless.today_date(), "best_result": {},
			})
			LegionCollectionFlow.show_screen(main)
		_:
			return false
	return true


static func _complete_campaign() -> void:
	for m in Campaign.maps():
		Campaign.record_result(String(m.get("id", "")), true, 0.9)
