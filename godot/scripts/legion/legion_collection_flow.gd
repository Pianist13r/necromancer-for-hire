class_name LegionCollectionFlow
extends RefCounted
##
## D-0927-162: флоу «Коллекции» (сохранить карту объекта во время боя/на итоге, переиграть вне
## забега) — вынесено из LegionMain отдельным файлом ради max-file-lines. Функции берут `main`
## первым параметром и читают/пишут его поля напрямую (world/screen/_endless_daily…), как и сам
## LegionMain делал бы — то же самое дерево вызовов, просто не внутри класса LegionMain.
##

# ── D-0927-162: коллекция сохранённых карт (сидов) процгена, переигровка ────────────────────────

## Данные для LegionCollection.save() из ТЕКУЩЕГО/только что законченного объекта забега —
## main.world.map_id/map ещё те же (мир переиспользуется, следующий start_map() их перепишет).
## card — map.procgen.card, если генератор его положил (STAGE2.md §3); в стаб-режиме этой ветки
## его нет — biome/archetype просто пустые, коллекция это переживает (см. LegionCollectionScreen).
static func entry_from_world(main: LegionMain) -> Dictionary:
	var card: Dictionary = main.world.map.get("procgen", {}).get("card", {})
	return {
		"map_id": main.world.map_id,
		"version": LegionEndless.STUB_VERSION,
		"title": String(main.world.map.get("title", main.world.map_id)),
		"biome": String(card.get("biome", "")),
		"archetype": String(card.get("archetype", "")),
		"difficulty": LegionRunStore.run_difficulty(main._endless_daily)
			if LegionRunStore.is_difficulty_locked(main._endless_daily) else Settings.difficulty(),
		"source": "daily" if main._endless_daily else "endless",
		"saved_date": LegionEndless.today_date(),
		"best_result": {},
	}


## Пауза (главное место, Игорь: «если проигрываешь или тебе надо бежать»), итог объекта и
## некролог зовут этот же метод — сохранение не завязано на то, откуда его вызвали.
static func save_current(main: LegionMain) -> void:
	if main.world == null or not main._collectible_map_id(main.world.map_id):
		return
	LegionCollection.save(entry_from_world(main))
	main.world.toast("Карта сохранена в коллекцию", &"info")


static func show_screen(main: LegionMain) -> void:
	Campaign.use_campaign_scope()
	main._ensure_audio().play_menu_music()
	main._teardown_screen()
	var c := LegionCollectionScreen.new()
	main._set_screen(c)
	c.play_requested.connect(func(id: String) -> void: start_battle(main, id))
	c.back.connect(main.show_menu)


## «Играть» из коллекции: одиночный бой ВНЕ забега/дня — армия с нуля (как и везде, start_map()
## сам это делает), поправки/«Контора» ЗАБЕГА не применяются (Campaign.use_replay_scope() —
## своя песочница, reset_replay_scratch() чистит её перед КАЖДЫМ разом, никогда не копится).
## Рекорды забега и «Вызова дня» не трогает — это отдельная ветка матч-энда
## (on_match_ended в этом же файле), не _on_endless_match_ended в LegionMain.
static func start_battle(main: LegionMain, map_id: String) -> void:
	if main._settle_abandoned_daily():   # D-0927-121: открытый бой дня — сперва засчитать уход
		return
	var data := main._load_object_map_data(map_id)
	if data.is_empty():
		show_screen(main)
		return
	main._teardown_screen()
	main._ensure_world()
	main._in_endless_battle = false
	main._in_collection_battle = true
	# D-0927-163 (интеграция items-v2 × mode): переигровка из коллекции — ОДИНОЧНЫЙ бой, артефакты
	# за забег не переносятся. Мир переживает все бои сеанса, и флаг остался бы висеть true
	# после кампании/забега — ставим явно, как это делают два других старта боя.
	main.world.carry_items = false
	main.world.kassa_allowed = false   # «Касса» (D-1001-01): премии в переигровке нет — и кассы
	Campaign.use_replay_scope()
	LegionRunStore.reset_replay_scratch()
	main.world.dev.erase("difficulty")
	# E-1005: переигровка — ОДИНОЧНЫЙ бой с открытиями игрока (виды/способности/фигуры живут в
	# разделе progress, от scope не зависят), поэтому in_campaign = true. Поправок при этом нет ПО
	# ПОСТРОЕНИЮ: колода берётся из replay-скоупа, а его обнуляет reset_replay_scratch() выше —
	# в отличие от забега, снимать in_campaign здесь нечего (иначе открытия стали бы «всё сразу»).
	main.world.in_campaign = true
	main.world.mods = Campaign.active_mods()
	main.world.battle_preparation = {}   # переигровка вне забега — без подготовки «Конторы»
	main.world.start_map(map_id)


## Итог переигровки — простой win/lose, без поправки/«Конторы»/следующего объекта (это не
## забег): «Ещё раз» переигрывает ТУ ЖЕ карту, «Меню» — в главное меню. Обновляет только
## best_result записи коллекции (сама запись уже существует — её сохранили раньше).
static func on_match_ended(main: LegionMain, victory: bool, stats: Dictionary) -> void:
	var map_id := main.world.map_id
	var ratio := clampf(float(stats.get("hp", 0.0)) / maxf(1.0, main.world.cauldron_max), 0.0, 1.0)
	LegionCollection.record_replay(map_id, {
		"victory": victory, "hp_ratio": ratio, "kills": int(stats.get("kills", 0)),
	})
	Campaign.use_campaign_scope()
	var view_stats := {
		"map_title": String(main.world.map.get("title", map_id)),
		"cauldron_hp": float(stats.get("hp", 0.0)),
		"cauldron_max": maxf(1.0, main.world.cauldron_max),
		"kills": int(stats.get("kills", 0)),
		"lost": int(stats.get("lost", 0)),
		"charges": int(stats.get("charges", 0)),
		"refreshes": int(stats.get("refreshes", 0)),
		"time": float(stats.get("t", 0.0)),
	}
	main._teardown_screen()
	var r := LegionResult.new()
	main._set_screen(r)
	r.call_deferred("show_result", victory, view_stats, 0, false, false, {}, true, false, false)
	r.retry.connect(func() -> void: start_battle(main, map_id))
	r.menu.connect(main.show_menu)
