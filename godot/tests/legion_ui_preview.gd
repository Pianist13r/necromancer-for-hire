extends Node
##
## Просмотрщик экранов пакета UI для приёмки кадром — не тест, не запускается гейтом.
## Строит один экран с тестовыми данными, ждёт кадр, снимает PNG (--shot), выходит.
## Запускать НЕ headless (headless не снимает кадр, см. godot/CLAUDE.md) и ВСЕГДА с --mute:
##
##   godot --path godot res://scenes/legion_ui_preview.tscn -- --mute \
##       --screen menu|maps|briefing|result_win|result_lose|upgrade|howto|pause --shot ПУТЬ
##   «Контора»/досье: --screen office_poor|office_part|office_rich|hero_poor|hero_part|hero_rich
##       --shot ПУТЬ
##

const TEST_SAVE_PATH := "user://legion_preview_test.cfg"


func _ready() -> void:
	# Прогон изолирован от реального прогресса владельца — свой файл сохранения.
	Campaign.set_save_path(TEST_SAVE_PATH)
	Campaign.reset()

	var args := _parse_args()
	var screen := String(args.get("screen", "menu"))
	var shot_path := String(args.get("shot", ""))

	var node := _build_screen(screen)
	if node == null:
		push_error("legion_ui_preview: неизвестный --screen %s" % screen)
		get_tree().quit(1)
		return
	add_child(node)

	await get_tree().process_frame
	await get_tree().process_frame

	if shot_path != "":
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		var err := img.save_png(shot_path)
		print(JSON.stringify({"shot": shot_path, "screen": screen, "error": err}))
	get_tree().quit()


func _parse_args() -> Dictionary:
	var out := {}
	var argv := OS.get_cmdline_user_args()
	var i := 0
	while i < argv.size():
		var a: String = argv[i]
		var next: String = argv[i + 1] if i + 1 < argv.size() else ""
		match a:
			"--screen", "--shot", "--tip":
				out[a.trim_prefix("--")] = next
				i += 1
		i += 1
	return out


func _build_screen(screen: String) -> Control:
	var builders: Dictionary = {
		"menu": _menu_fixture, "maps": _maps_fixture, "briefing": _briefing_fixture,
		"result_win": _result_fixture.bind(true), "result_lose": _result_fixture.bind(false),
		"upgrade": _upgrade_fixture, "howto": _howto_fixture,
		"pause": func() -> Control: return LegionPause.new(),
		"office_poor": _office_fixture.bind(0), "office_part": _office_fixture.bind(1),
		"office_rich": _office_fixture.bind(2), "hero_poor": _hero_fixture.bind(0),
		"hero_part": _hero_fixture.bind(1), "hero_rich": _hero_fixture.bind(2),
	}
	var builder: Callable = builders.get(screen, Callable())
	return builder.call() if builder.is_valid() else null


func _howto_fixture() -> Control:
	var howto := HowtoLegion.new()
	howto.closed.connect(func() -> void: print("closed"))
	return howto


func _menu_fixture() -> Control:
	# Первая карта пройдена на 3★ — «Продолжить» и звёзды карты видны не пустыми.
	Campaign.record_result(String(Campaign.maps()[0].get("id", "")), true, 0.9)
	var menu := LegionMenu.new()
	menu.continue_pressed.connect(func(id: String) -> void: print("continue: ", id))
	return menu


func _maps_fixture() -> Control:
	var maps := Campaign.maps()
	Campaign.record_result(String(maps[0].get("id", "")), true, 0.9)
	if maps.size() > 1:
		Campaign.record_result(String(maps[1].get("id", "")), true, 0.5)
	var screen := MapSelect.new()
	screen.map_chosen.connect(func(id: String) -> void: print("chosen: ", id))
	return screen


func _briefing_fixture() -> Control:
	var maps := Campaign.maps()
	var idx := mini(2, maps.size() - 1)
	var screen := Briefing.new()
	# populate() строит содержимое сама — вызвать после add_child, иначе UiStyle.card_box
	# кладёт карточку в дерево до готовности родителя. Планируем на первый кадр.
	call_deferred("_populate_briefing", screen, maps[idx])
	return screen


func _populate_briefing(screen: Briefing, data: Dictionary) -> void:
	screen.populate(data)


func _result_fixture(victory: bool) -> Control:
	var screen := LegionResult.new()
	var stats := {
		"map_title": "Мост через Стикс",
		"cauldron_hp": 160.0 if victory else 0.0,
		"cauldron_max": 200.0,
		"kills": 84,
		"lost": 12,
		"charges": 9,
		"refreshes": 21,
		"releases": 3,
		"time": 187.0,
	}
	call_deferred("_show_result", screen, victory, stats)
	return screen


func _show_result(screen: LegionResult, victory: bool, stats: Dictionary) -> void:
	screen.show_result(victory, stats, 3 if victory else 0, victory)


func _upgrade_fixture() -> Control:
	var screen := UpgradePicker.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = 1
	call_deferred("_offer_upgrade", screen, Campaign.offer_upgrades(rng))
	return screen


func _offer_upgrade(screen: UpgradePicker, options: Array) -> void:
	screen.offer(options)


## «Контора»: 0 — начало кампании, премии мало; 1 — разряд 4 открыл два слота, один пакет взят;
## 2 — всё открыто, премии много.
func _office_fixture(stage: int) -> Control:
	var maps := Campaign.maps()
	if stage == 0:
		Campaign._add_bounty(45)
	elif stage == 1:
		Campaign.record_result(String(maps[0].get("id", "")), true, 0.9)
		Campaign._add_hero_xp(int(LegionMetaCfg.HERO_LEVEL_THRESHOLDS[2]))   # разряд 4 — два слота
		Campaign._add_bounty(200)
		RunProgression.buy_service("souls")
		Campaign._add_bounty(-Campaign.bounty() + 75)
	else:
		Campaign.unlock_all()
		Campaign._add_bounty(900)
	return OfficeShop.new()


## Досье: 0 — разряд 1, только базовая колода; 1 — разряд ~5, часть карт открыта; 2 — потолок.
func _hero_fixture(stage: int) -> Control:
	if stage == 1:
		Campaign._add_hero_xp(1180)
	elif stage == 2:
		Campaign._add_hero_xp(4000)
	return HeroScreen.new()
