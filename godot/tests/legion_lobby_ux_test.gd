extends SceneTree
##
## «Схватка» без тупиков (ветка slow/lobby-ux; B-331, B-332): ведёт LegionMain настоящим вводом
## (Input.parse_input_event — нажатие и отпускание мыши по центру кнопки), без окна:
## 1) уровень бота и сторона на экране выбора поля: клик → user://settings.cfg (через Settings),
##    повторный вход показывает выбор, матч берёт уровень (PvpBot) и сторону (человек справа);
##    по умолчанию — «Подрядчик» слева, мир без ключей pvp_bot_level/pvp_swap (серии не поехали);
## 2) «Другое поле» — новый сид без выхода в меню, «Случайное поле» стартует показанный сид;
##    итог матча с ботом — «Ещё раз на новом поле» (новый сид, бой с нуля);
## 3) лобби «По сети» без сервера (закрытый порт): «Подключаемся…» → «Сервер недоступен — …» и
##    кнопка «Никого нет — сыграть с ботом» → матч с ботом, сессия закрыта;
## 4) лобби с ретранслятором в процессе (NetRelayCore + NetLinkPipe): «Открытых комнат нет»,
##    предложение бота — только после LegionCfg.LOBBY_BOT_OFFER_S; чужая комната его снимает;
##    своя комната: «Ждём соперника · м:сс», бот — на поле комнаты, комната закрыта.
## Тест читает новые API через узлы по имени и карту констант — на старом коде он падает
## проверками, а не разбором.
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_lobby_ux_test.gd -- --mute
##
## Итог «LEGION LOBBY UX: N/M OK»; код выхода 1, если что-то упало.
##

const SAVE := "user://legion_lobby_ux_test.cfg"
const PREFS := "user://legion_lobby_ux_test_settings.cfg"
const DEAD_URL := "ws://127.0.0.1:9"
const SERVER_DOWN := "Сервер недоступен — проверьте адрес или играйте с ботом"
const BOT_TEXT := "Никого нет — сыграть с ботом"

var main: LegionMain
var relay: NetRelayCore = null
var _checks := 0
var _fails := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(cond: bool, what: String) -> void:
	_checks += 1
	if cond:
		print("  ok   ", what)
	else:
		_fails += 1
		print("  FAIL ", what)


func _frames(n: int) -> void:
	for i in n:
		if relay != null:
			relay.process()
		await process_frame


## Константа LegionCfg без разбора на старом коде (нет константы — null).
func _cfgv(key: String) -> Variant:
	return (load("res://scripts/legion/legion_cfg.gd") as GDScript).get_script_constant_map().get(key)


## Клик мышью по центру кнопки настоящим вводом (как legion_flow_test): курсор в точку окна
## (вьюпорт 1280×720 растянут на окно — final_transform), нажатие, отпускание.
func _click(c: Control) -> void:
	if c == null:
		return
	var at := root.get_final_transform() * c.get_global_rect().get_center()
	var motion := InputEventMouseMotion.new()
	motion.device = 8
	motion.position = at
	motion.global_position = at
	Input.parse_input_event(motion)
	await _frames(1)
	for down: bool in [true, false]:
		var ev := InputEventMouseButton.new()
		ev.device = 8
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.pressed = down
		ev.button_mask = MOUSE_BUTTON_MASK_LEFT if down else 0
		ev.position = at
		ev.global_position = at
		Input.parse_input_event(ev)
		await _frames(2)


func _button(where: Node, node_name: String) -> Button:
	return where.find_child(node_name, true, false) as Button if where != null else null


func _button_text(where: Node, text: String) -> Button:
	if where == null:
		return null
	for b in where.find_children("*", "Button", true, false):
		if (b as Button).text == text and (b as Button).is_visible_in_tree():
			return b as Button
	return null


func _label(where: Node, node_name: String) -> Label:
	return where.find_child(node_name, true, false) as Label if where != null else null


## Карточка экрана целиком в кадре 1280×720 и выше строки «← Назад» (раскладка без окна).
func _fits(screen: Node) -> bool:
	var card := screen.find_child("Card", true, false) as Control if screen != null else null
	var nav := screen.find_child("Navigation", true, false) as Control if screen != null else null
	if card == null or nav == null:
		return false
	var r := card.get_global_rect()
	var ok := Rect2(0, 0, 1280, 720).encloses(r) and r.end.y <= nav.get_global_rect().position.y
	if not ok:
		print("    карточка %s, навигация %s" % [r, nav.get_global_rect()])
	return ok


func _has_text_part(where: Node, part: String) -> bool:
	for l in where.find_children("*", "Label", true, false):
		if (l as Label).text.contains(part) and (l as Label).is_visible_in_tree():
			return true
	return false


func _run() -> void:
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	Campaign.set_intro_cutscene_seen()
	# чистый лист: SafeConfig без основного файла поднимает .bak — убираем оба
	for p: String in [PREFS, PREFS + ".bak"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
	var net := ConfigFile.new()
	net.set_value("net", "name", "Тест")
	net.set_value("net", "url", DEAD_URL)
	net.save(NetLobby.CFG)
	main = (load("res://scenes/legion.tscn") as PackedScene).instantiate() as LegionMain
	root.add_child(main)
	await _frames(3)
	# LegionMain._ready ставит путь настроек сам (use_dev_save) — свой файл после него
	Settings.path = PREFS
	Settings._cfg = null
	await _test_default_match()
	await _test_level_and_side()
	await _test_reroll_and_result()
	await _test_lobby_server_down()
	await _test_lobby_offer()
	if relay != null:
		relay.shutdown("bye")
		relay = null
	main.queue_free()
	await _frames(2)
	Settings.path = Settings.PATH
	Settings._cfg = null
	Campaign.reset()
	print("LEGION LOBBY UX: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


func _open_select() -> Control:
	if not (main.screen is LegionMenu):
		main.show_menu()
		await _frames(2)
	(main.screen.find_child("PvpAction", true, false) as Button).pressed.emit()
	await _frames(3)
	return main.screen


func _surrender_to_menu() -> void:
	var w := main.world
	w.command(0, PvpCmd.surrender())
	await _frames(20)
	var b := w.hud.pvp_result.button("В главное меню") if w.hud.pvp_result != null else null
	if b != null:
		b.pressed.emit()
	await _frames(3)


func _bot_level(b: Variant) -> String:
	var v: Variant = (b as PvpBot).get("level_id") if b is PvpBot else null
	return str(v) if v != null else ""


## По умолчанию — прежнее поведение: «Подрядчик» слева, ключей боя в dev нет.
func _test_default_match() -> void:
	print("— по умолчанию")
	var s := await _open_select()
	var def: Variant = _cfgv("PVP_BOT_LEVEL_DEFAULT")
	_check(def != null and String(def) == "contractor", "уровень по умолчанию — «Подрядчик»")
	var contractor := _button(s, "PvpBotLevel_contractor")
	_check(contractor != null and contractor.button_pressed, "на экране нажат «Подрядчик»")
	var left := _button(s, "PvpSideLeft")
	_check(left != null and left.button_pressed, "на экране нажата левая сторона")
	(s.find_child("PvpFieldDuel", true, false) as Button).pressed.emit()
	await _frames(4)
	var w := main.world
	_check(w.pvp and w.sides.size() == 2 and w.sides[0].bot == null
		and _bot_level(w.sides[1].bot) == "contractor", "матч: человек — сторона 0, бот — «Подрядчик»")
	_check(not w.dev.has("pvp_bot_level") and not w.dev.has("pvp_swap"),
		"по умолчанию мир без ключей pvp_bot_level/pvp_swap (как серия)")
	_check(w.sides[0].cauldron_pos.x < w.world_size.x * 0.5, "человек — на левой половине")
	_check(is_equal_approx(w.sides[1].ability_mana_reserve, LegionCfg.BOT_MANA_RESERVE),
		"запас маны бота по умолчанию — BOT_MANA_RESERVE")
	await _surrender_to_menu()


func _test_level_and_side() -> void:
	print("— уровень бота и сторона (B-331)")
	var s := await _open_select()
	var titles: Array[String] = []
	for id: String in ["intern", "contractor", "foreman"]:
		var b := _button(s, "PvpBotLevel_" + id)
		titles.append(b.text if b != null else "?")
	_check(titles == ["Стажёр", "Подрядчик", "Прораб"], "три уровня: %s" % [titles])
	_check(_fits(s), "карточка выбора в кадре и не заходит под «← Назад»")
	await _click(_button(s, "PvpBotLevel_foreman"))
	await _click(_button(s, "PvpSideRight"))
	_check(main.screen == s, "выбор уровня и стороны не уводит с экрана")
	var cfg := ConfigFile.new()
	cfg.load(PREFS)
	_check(String(cfg.get_value("pvp", "bot_level", "")) == "foreman"
		and int(cfg.get_value("pvp", "side", -1)) == 1,
		"выбор записан в файл настроек (Settings): Прораб, правая")
	main.show_menu()
	await _frames(2)
	Settings._cfg = null   # перечитать файл: выбор живёт на диске, не только в памяти
	s = await _open_select()
	var fore := _button(s, "PvpBotLevel_foreman")
	var right := _button(s, "PvpSideRight")
	_check(fore != null and fore.button_pressed and right != null and right.button_pressed,
		"повторный вход показывает сохранённый выбор")
	(s.find_child("PvpFieldDuel", true, false) as Button).pressed.emit()
	await _frames(4)
	var w := main.world
	_check(w.sides[0].bot == null and _bot_level(w.sides[1].bot) == "foreman",
		"матч: бот — «Прораб» (%s)" % _bot_level(w.sides[1].bot))
	_check(w.sides[0].cauldron_pos.x > w.world_size.x * 0.5
		and w.sides[1].cauldron_pos.x < w.world_size.x * 0.5,
		"человек (сторона 0) — на правой половине, бот — на левой")
	var levels: Variant = _cfgv("PVP_BOT_LEVELS")
	var want := float((levels as Dictionary)["foreman"]["mana_reserve"]) \
		if levels is Dictionary else -1.0
	_check(is_equal_approx(w.sides[1].ability_mana_reserve, want), "запас маны бота — уровня")
	await _surrender_to_menu()
	# вернуть умолчания тем же вводом — дальше лобби играет с ботом по умолчанию
	s = await _open_select()
	await _click(_button(s, "PvpBotLevel_contractor"))
	await _click(_button(s, "PvpSideLeft"))
	cfg.load(PREFS)
	_check(String(cfg.get_value("pvp", "bot_level", "")) == "contractor"
		and int(cfg.get_value("pvp", "side", -1)) == 0, "обратно: Подрядчик, левая")


func _test_reroll_and_result() -> void:
	print("— другое поле (B-332)")
	var s := await _open_select()
	var reroll := _button(s, "PvpFieldReroll")
	_check(reroll != null and reroll.text == "Другое поле", "на экране выбора есть «Другое поле»")
	var id0 := String(s.get("random_id")) if s.get("random_id") != null else ""
	_check(id0.begins_with("gen:") and id0.ends_with(":3:pvp"), "поле наготове: %s" % id0)
	await _click(reroll)
	var id1 := String(s.get("random_id")) if s.get("random_id") != null else ""
	_check(main.screen == s and id1 != id0 and id1.begins_with("gen:") and id1.ends_with(":3:pvp"),
		"«Другое поле» — новый сид без выхода в меню (%s → %s)" % [id0, id1])
	var seed_text := id1.trim_prefix("gen:").get_slice(":", 0)
	_check(seed_text != "" and _has_text_part(s, seed_text),
		"на экране виден номер поля %s" % seed_text)
	await _click(s.find_child("PvpFieldRandom", true, false) as Control)
	await _frames(4)
	var w := main.world
	_check(w != null and w.pvp and w.map_id == id1, "«Случайное поле» стартует показанное поле")
	w.command(0, PvpCmd.surrender())
	await _frames(20)
	var again := w.hud.pvp_result.button("Ещё раз на новом поле")
	_check(again != null, "на итоге матча с ботом — «Ещё раз на новом поле»")
	await _click(again)
	await _frames(3)
	_check(w.pvp and w.map_id != id1 and w.map_id.begins_with("gen:") and w.map_id.ends_with(":3:pvp")
		and w.phase == LegionWorld.Phase.BATTLE and w.now < 1.0 and not w.hud.pvp_result.is_open(),
		"«Ещё раз на новом поле» — новый сид, бой с нуля (%s)" % w.map_id)
	await _surrender_to_menu()


func _lobby_status(lobby: Node) -> String:
	var l := _label(lobby, "LobbyStatus")
	return l.text if l != null else ""


func _open_lobby() -> NetLobby:
	var s := await _open_select()
	(s.find_child("PvpFieldNet", true, false) as Button).pressed.emit()
	await _frames(3)
	return main.screen as NetLobby


func _test_lobby_server_down() -> void:
	print("— лобби без сервера")
	var lobby := await _open_lobby()
	_check(lobby != null, "«По сети» — лобби")
	if lobby == null:
		return
	_check(_button_text(lobby, BOT_TEXT) == null, "до подключения бота не предлагают")
	await _click(_button_text(lobby, "Подключиться"))
	_check(_lobby_status(lobby) == "Подключаемся…",
		"статус: «Подключаемся…» (%s)" % _lobby_status(lobby))
	var bot: Button = null
	for i in 1500:
		await _frames(1)
		bot = _button_text(lobby, BOT_TEXT)
		if bot != null:
			break
	_check(_lobby_status(lobby) == SERVER_DOWN, "статус: «%s»" % _lobby_status(lobby))
	_check(bot != null, "сервер недоступен — кнопка «%s»" % BOT_TEXT)
	_check(_fits(lobby), "карточка лобби (с кнопкой бота) в кадре")
	await _click(bot)
	await _frames(4)
	var w := main.world
	var session := PvpFlow.net_session(main)
	_check(main.screen == null and w != null and w.pvp and not w.net_mode and w.map_id == PvpMaps.DUEL
		and w.phase == LegionWorld.Phase.BATTLE, "бот из лобби: матч на «Дуэли» без главного меню")
	_check(w.sides[0].bot == null and w.sides[1].bot is PvpBot, "человек против бота")
	_check(session.stage == NetSession.Stage.IDLE and not session.is_online(), "сессия закрыта")
	await _surrender_to_menu()


func _test_lobby_offer() -> void:
	print("— лобби с сервером: предложение бота")
	var offer: Variant = _cfgv("LOBBY_BOT_OFFER_S")
	_check(offer != null and float(offer) >= 10.0, "LOBBY_BOT_OFFER_S в cfg (%s с)" % [offer])
	var offer_s := float(offer) if offer != null else 20.0
	var lobby := await _open_lobby()
	if lobby == null:
		return
	relay = NetRelayCore.new()
	var ends := NetLinkPipe.pair()
	relay.add_link(ends[0], false)
	var session := PvpFlow.net_session(main)
	session.connect_link(ends[1], "Тест")
	for i in 120:
		await _frames(1)
		if session.stage == NetSession.Stage.LOBBY:
			break
	await _frames(3)
	_check(session.stage == NetSession.Stage.LOBBY, "в лобби ретранслятора")
	_check(_lobby_status(lobby) == "Открытых комнат нет", "статус: «%s»" % _lobby_status(lobby))
	await _frames(int(offer_s * 60.0) - 120)
	_check(_button_text(lobby, BOT_TEXT) == null, "за %.0f с до порога бота не предлагают" % 2.0)
	await _frames(240)
	_check(_button_text(lobby, BOT_TEXT) != null, "пусто дольше порога — «%s»" % BOT_TEXT)
	_check(_fits(lobby), "карточка лобби в сети (с кнопкой бота) в кадре")
	# кто-то открыл комнату — предложение снимается
	var other := NetLinkPipe.pair()
	relay.add_link(other[0], false)
	(other[1] as NetLink).send_text(JSON.stringify({"t": "hello", "v": NetSession.PROTO,
		"build": NetSession.BUILD, "name": "Боря"}))
	(other[1] as NetLink).send_text(JSON.stringify({"t": "create", "map": "pvp:duel"}))
	await _frames(30)
	_check(_has_text_part(lobby, "«Боря»") and _button_text(lobby, BOT_TEXT) == null,
		"чужая комната в списке — бота не предлагают")
	(other[1] as NetLink).close(1000, "bye")
	await _frames(30)
	_check(not _has_text_part(lobby, "«Боря»"), "комната ушла из списка")
	# своя комната: ожидание со временем, бот — на её поле
	await _click(_button_text(lobby, "Открыть: Случайное поле"))
	await _frames(70)
	var st := _lobby_status(lobby)
	_check(RegEx.create_from_string("^Ждём соперника · 0:0[1-2]$").search(st) != null,
		"статус: «%s»" % st)
	_check(session.room_code != "" and _has_text_part(lobby, session.room_code),
		"код своей комнаты виден (%s)" % session.room_code)
	_check(_button_text(lobby, BOT_TEXT) == null, "ожидание короче порога — бота не предлагают")
	await _frames(int(offer_s * 60.0))
	st = _lobby_status(lobby)
	_check(st.begins_with("Ждём соперника · 0:") and _button_text(lobby, BOT_TEXT) != null,
		"ждём дольше порога — «%s» (%s)" % [BOT_TEXT, st])
	await _click(_button_text(lobby, BOT_TEXT))
	await _frames(6)
	var w := main.world
	_check(main.screen == null and w.pvp and not w.net_mode and w.map_id.begins_with("gen:")
		and w.map_id.ends_with(":3:pvp") and w.phase == LegionWorld.Phase.BATTLE,
		"бот на поле своей комнаты (случайное: %s)" % w.map_id)
	_check(session.stage == NetSession.Stage.IDLE and not session.is_online(), "сессия закрыта")
	_check(relay._rooms.is_empty(), "комната на сервере закрыта")
	await _surrender_to_menu()
