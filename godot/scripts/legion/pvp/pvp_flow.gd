class_name PvpFlow
extends RefCounted
##
## Вход в «Схватку» из главного меню (P6, D-0927-199): выбор поля → матч с ботом в том же мире,
## что и кампания. Вынесено из LegionMain отдельным файлом (max-file-lines); функции берут `main`
## первым параметром, как LegionCollectionFlow.
##
## Матч не касается кампании: поправки, «Контору» и артефакты забега мир в нём не читает
## (in_campaign = false, mods пусты, carry_items = false — у бота их нет, у человека тоже), итог
## показывает PvpResult, а не экран кампании, сохранение не пишется. Следующий бой кампании
## возвращает in_campaign через LegionMain._ensure_world(), а камеру — LegionWorld._apply_view().
##


static func show_field_select(main: LegionMain) -> void:
	main._ensure_audio().play_menu_music()
	main._teardown_screen()
	var s := PvpFieldSelect.new()
	s.via_steam = steam_active(main)
	main._set_screen(s)
	s.chosen.connect(func(map_id: String) -> void: start(main, map_id))
	s.back.connect(main.show_menu)
	s.net.connect(func() -> void: show_net_lobby(main))


# ── По сети (docs/pvp/NET_LOCKSTEP.md) ────────────────────────────────────────

## Сессия одна на всю игру — узел под LegionMain: соединение с лобби переживает экраны и матч.
static func net_session(main: LegionMain) -> NetSession:
	var s := main.get_node_or_null(^"NetSession") as NetSession
	if s == null:
		s = NetSession.new()
		s.name = "NetSession"
		main.add_child(s)
		s.match_start.connect(func(seed_value: int, map_id: String, side: int) -> void:
			start_net(main, seed_value, map_id, side))
		s.aborted.connect(func(_text: String) -> void:
			if main.world != null:
				main.world.go_to_menu()
			show_net_lobby(main))
	return s


static func show_net_lobby(main: LegionMain) -> void:
	if steam_active(main):
		show_steam_lobby(main, 0)
		return
	main._ensure_audio().play_menu_music()
	main._teardown_screen()
	var session := net_session(main)
	var lobby := NetLobby.new().setup(session)
	main._set_screen(lobby)
	lobby.back.connect(func() -> void:
		session.close()
		show_field_select(main))


## Steam-сборка с запущенным клиентом Steam: «По сети» — лобби Steam, не адрес сервера.
static func steam_active(main: LegionMain) -> bool:
	var steam := SteamNet.find(main)
	return steam != null and steam.active()


## Лобби Steam (SteamLobby); join_lobby — войти сразу (приглашение / +connect_lobby), 0 — список.
## Назад: сессия закрывается раньше SteamNet.leave() — иначе её канал закроет ядро ретранслятора
## хозяина, и она покажет «связь потеряна».
static func show_steam_lobby(main: LegionMain, join_lobby: int) -> void:
	main._ensure_audio().play_menu_music()
	main._teardown_screen()
	var session := net_session(main)
	var steam := SteamNet.find(main)
	var lobby := SteamLobby.new().setup(session, steam, join_lobby)
	main._set_screen(lobby)
	lobby.back.connect(func() -> void:
		session.close()
		steam.leave()
		show_field_select(main))


## Соперник найден: тот же мир, что у «Схватки» с ботом, но шагает его сессия, а ввод уходит
## в сеть. Выход из итога («В меню») возвращает в лобби, соединение не рвётся.
static func start_net(main: LegionMain, seed_value: int, map_id: String, side: int) -> void:
	if main._settle_abandoned_daily():
		return
	main._in_endless_battle = false
	main._in_collection_battle = false
	main._teardown_screen()
	var w := main._ensure_world()
	# E-1005: сетевой матч — вне кампании (как и «Схватка» с ботом): поправки забега в него не
	# текут. start_net_match() ставит то же повторно — здесь явно, по правилу «каждый старт боя
	# ставит режим себе сам», чтобы снятие строки там не оживило поправки в сети молча.
	w.in_campaign = false
	var session := net_session(main)
	w.start_net_match(map_id, seed_value, side)
	session.attach(w)
	# одноразово: если матч оборвался (aborted уже увёл в лобби), следующий бой с ботом идёт уже не
	# в сети — тогда не перехватываем его выход в меню
	w.pvp_menu_requested.connect(func() -> void:
		if not w.net_mode:
			return
		session.leave_match()
		show_net_lobby(main), CONNECT_ONE_SHOT)


static func start(main: LegionMain, map_id: String) -> void:
	if main._settle_abandoned_daily():
		return
	main._in_endless_battle = false
	main._in_collection_battle = false
	main._teardown_screen()
	var w := main._ensure_world()
	w.dev.erase("difficulty")
	w.mods = {}
	w.in_campaign = false
	w.carry_items = false
	w.battle_preparation = {}   # «Схватка» без поправок забега и подготовки «Конторы»
	w.start_map(map_id)


## Итог матча — экран самого PvP-HUD; сигнал match_ended кампании здесь ничего не даёт.
static func swallows_match_end(main: LegionMain) -> bool:
	return main.world != null and main.world.pvp
