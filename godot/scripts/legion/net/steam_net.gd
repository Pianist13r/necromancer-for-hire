class_name SteamNet
extends Node
##
## Онлайн-«Схватка» через Steam (docs/dev/ONLINE.md, «Steam Networking»): лобби Steam вместо
## адреса сервера, соединение P2P через реле Valve (SDR) вместо нашего ретранслятора в облаке.
## Протокол lockstep тот же: хозяин лобби держит ядро ретранслятора (NetRelayCore, без судьи) у себя
## в процессе и подключён к нему парой NetLinkPipe; гость приходит каналом NetLinkSteam. NetSession
## у обоих работает как через сервер — для неё поменялся только канал.
##
## Поднимается только в Steam-сборке (фича `steam` экспортного пресета) или по NECRO_STEAM=1 (проба
## из редактора на Spacewar, NECRO_STEAM_APPID=480); иначе boot() возвращает null и «По сети»
## ведёт в прежнее лобби с адресом сервера. GodotSteam грузится на ходу из папки рядом с exe
## (godotsteam/godotsteam.gdextension; NECRO_STEAM_EXT — другой путь): в проекте расширения нет,
## сборки itch/GitHub его не несут, --check-only и гейт его не требуют.
##
## Доверие: ядро у хозяина, так что хозяин технически может подменять свои ходы и «desync»
## сопернику — третейского судьи, как на сервере, здесь нет. Отпечатки сверяются, журналы у обоих
## (user://net_logs) остаются; для игры с другом этого достаточно, рейтинга на этом не строить.
##

## Список открытых игр Steam: [{id, name, map, members}].
signal lobbies(rows: Array)
signal status(text: String)
signal failed(text: String)
## Роль / лобби / комната поменялись — экрану перерисоваться.
signal changed
## Приглашение принято, «Присоединиться» в списке друзей или запуск с +connect_lobby.
signal join_request(lobby_id: int)

const NODE_NAME := "SteamNet"
const GAME_KEY := "necro"
const VIRTUAL_PORT := 0
const LOBBY_MAX := 2
const LIST_MAX := 50
const REFRESH_S := 5.0
const JOIN_TIMEOUT_S := 15.0
const CREATE_RETRY_S := 3.0
const OWNER_CHECK_S := 0.5
## Входящее P2P от того, кого в нашем списке участников лобби ещё нет: список у Steam — локальная
## копия, обновляемая отдельным уведомлением (LobbyChatUpdate), и соединение гостя может прийти
## раньше неё — ждём столько, прежде чем отказать (verifier 08.10, риск 1).
const ACCEPT_GRACE_S := 8.0
const ACCEPT_CHECK_S := 0.25
## Хозяин в своём лобби «простаивает» сколько угодно: правило 10 минут — для общего сервера.
const HOST_IDLE_MS := 24 * 60 * 60 * 1000
const ENV_FORCE := "NECRO_STEAM"
const ENV_APPID := "NECRO_STEAM_APPID"
const ENV_EXT := "NECRO_STEAM_EXT"
const EXT_REL := "godotsteam/godotsteam.gdextension"
const CONNECT_PREFIX := "+connect_lobby"

var api: SteamApi
## Steam инициализирован (клиент запущен, расширение загружено).
var ok := false
var why_not := ""
var my_id := 0
var my_name := ""
## "" — не в игре; "host" — своё лобби; "guest" — в чужом.
var mode := ""
var lobby_id := 0
var map_id := ""
var session: NetSession
var relay: NetRelayCore
## Экран лобби открыт — обновлять список игр раз в REFRESH_S.
var auto_refresh := false
## Срок ожидания участника (тест ставит меньше).
var accept_grace_s := ACCEPT_GRACE_S

var _listen := 0
var _links: Dictionary = {}   ## дескриптор соединения → NetLinkSteam
var _player_name := ""
var _pending_join := 0
var _refresh_t := 0.0
var _auto_join := false
var _creating := false
var _create_t := 0.0
var _join_t := -1.0
## Лобби, в которое просили войти (ответ lobby_joined сверяется с ним; отмена до ответа — выйти).
var _join_lobby := 0
## Сколько createLobby ещё без ответа: ответ на запрос, отменённый leave(), освобождает лобби.
var _lobby_pending := 0
## Гость потерял соединение с хозяином — выйти из его лобби Steam (на следующем кадре).
var _guest_lost := false
var _owner_t := 0.0
## Входящие, ждущие появления в списке участников лобби: дескриптор → {identity, t}.
var _pending_accepts: Dictionary = {}
var _accept_t := 0.0


## Узел под main, если Steam-сборка или NECRO_STEAM=1 (backend — заглушка в тестах); иначе null.
static func boot(parent: Node, backend: Object = null) -> SteamNet:
	if backend == null and not OS.has_feature("steam") and OS.get_environment(ENV_FORCE) != "1":
		return null
	var n := SteamNet.new()
	n.name = NODE_NAME
	parent.add_child(n)
	n._start(backend)
	return n


static func find(parent: Node) -> SteamNet:
	return parent.get_node_or_null(NodePath(NODE_NAME)) as SteamNet


func active() -> bool:
	return ok


## Лобби, в которое просили войти (приглашение / +connect_lobby), один раз.
func take_pending_join() -> int:
	var v := _pending_join
	_pending_join = 0
	return v


func _start(backend: Object) -> void:
	if backend == null:
		backend = SteamApi.find()
		if backend == null:
			_load_extension()
			backend = SteamApi.find()
	if backend == null:
		if why_not == "":
			why_not = "GodotSteam не загружен"
		push_warning("SteamNet: %s" % why_not)
		return
	api = SteamApi.new(backend)
	var app_env := OS.get_environment(ENV_APPID)
	var r := api.init(int(app_env) if app_env.is_valid_int() else 0)
	if int(r.get("status", 1)) != SteamApi.INIT_OK:
		why_not = "Steam не запущен (%s)" % String(r.get("verbal", ""))
		push_warning("SteamNet: %s" % why_not)
		return
	ok = true
	my_id = api.my_id()
	my_name = api.my_name()
	api.init_relay()
	api.on(&"lobby_created", _on_lobby_created)
	api.on(&"lobby_joined", _on_lobby_joined)
	api.on(&"lobby_match_list", _on_lobby_list)
	api.on(&"network_connection_status_changed", _on_conn_status)
	api.on(&"join_requested", _on_join_requested)
	api.on(&"join_game_requested", _on_join_game_requested)
	_parse_launch_args()


## GodotSteam лежит не в проекте, а рядом с exe (в Steam-сборке) — грузим на ходу.
func _load_extension() -> void:
	var path := OS.get_environment(ENV_EXT)
	if path == "":
		path = OS.get_executable_path().get_base_dir().path_join(EXT_REL)
	if not FileAccess.file_exists(path):
		why_not = "нет %s" % path
		return
	var st := GDExtensionManager.load_extension(path)
	if st != GDExtensionManager.LOAD_STATUS_OK and st != GDExtensionManager.LOAD_STATUS_ALREADY_LOADED:
		why_not = "GodotSteam не загрузилось из %s (код %d)" % [path, st]


## Steam запускает игру по приглашению как `игра +connect_lobby <id>`.
func _parse_launch_args() -> void:
	var argv := OS.get_cmdline_args()
	for i in argv.size():
		if argv[i] == CONNECT_PREFIX and i + 1 < argv.size() and argv[i + 1].is_valid_int():
			_pending_join = int(argv[i + 1])


func _exit_tree() -> void:
	leave()
	if ok:
		api.shutdown()
		ok = false


func _process(delta: float) -> void:
	if not ok:
		return
	api.run_callbacks()
	if relay != null:
		relay.process()
	for h: int in _links.keys():
		if (_links[h] as NetLinkSteam).state() == NetLink.State.CLOSED:
			_links.erase(h)   # закрыли сами (set_closed чужих — в _on_conn_status)
	if auto_refresh:
		_refresh_t += delta
		if _refresh_t >= REFRESH_S:
			_refresh_t = 0.0
			refresh()
	# хозяин без комнаты в лобби (после матча — leave_match, после обрыва — abort) открывает её
	# снова; ответа «room» нет CREATE_RETRY_S — просим ещё раз (ядро могло отказать по лимиту)
	if mode == "host" and session != null and session.stage == NetSession.Stage.LOBBY \
			and session.room_code == "":
		if not _creating:
			_create_room()
		else:
			_create_t += delta
			if _create_t > CREATE_RETRY_S:
				_creating = false
	if _join_t >= 0.0:
		_join_t += delta
		if _join_t > JOIN_TIMEOUT_S:
			_join_t = -1.0
			_fail("Лобби Steam не ответило")
			leave()
	if _guest_lost:
		_guest_lost = false
		leave()
	if not _pending_accepts.is_empty():
		_accept_t += delta
		if _accept_t >= ACCEPT_CHECK_S:
			_accept_t = 0.0
			_tick_pending_accepts(ACCEPT_CHECK_S)
	# у Steam при уходе хозяина владение лобби переходит оставшемуся: гость стал бы «хозяином»
	# рекламируемого лобби без сокета — выходим сами (соединение всё равно порвано)
	if mode == "guest" and lobby_id != 0:
		_owner_t += delta
		if _owner_t >= OWNER_CHECK_S:
			_owner_t = 0.0
			if api.lobby_owner(lobby_id) == my_id:
				status.emit("Хозяин вышел из игры")
				leave()


# ── Хозяин ───────────────────────────────────────────────────────────────────

## Открыть свою игру: P2P-сокет, ядро ретранслятора у себя, лобби Steam с данными игры.
func host(sess: NetSession, map: String, player_name: String) -> void:
	leave()
	mode = "host"
	map_id = map
	_player_name = player_name
	_listen = api.listen_p2p(VIRTUAL_PORT)
	if _listen == SteamApi.INVALID_HANDLE:
		_fail("Steam не открыл P2P-сокет")
		leave()
		return
	relay = NetRelayCore.new()
	relay.judge_max = 0
	relay.lobby_idle = HOST_IDLE_MS
	var ends := NetLinkPipe.pair()
	relay.add_link(ends[0], false)
	_bind_session(sess)
	sess.link_label = "через Steam"
	sess.connect_link(ends[1], player_name)
	_lobby_pending += 1
	api.create_lobby(SteamApi.LOBBY_PUBLIC, LOBBY_MAX)
	status.emit("Открываем игру в Steam…")
	changed.emit()


func _on_lobby_created(result: int, lobby: int) -> void:
	_lobby_pending = maxi(0, _lobby_pending - 1)
	if mode != "host" or lobby_id != 0:
		# ответ на запрос, отменённый leave() (или второй из двух host() подряд): лобби создано на
		# наше имя — отпустить, иначе висит пустым в списке
		if result == SteamApi.RESULT_OK and lobby != 0:
			api.leave_lobby(lobby)
		return
	if result != SteamApi.RESULT_OK or lobby == 0:
		_fail("Steam не создал лобби (код %d)" % result)
		leave()
		return
	lobby_id = lobby
	_publish()
	status.emit("Игра открыта — ждём соперника")
	changed.emit()


## Данные лобби — по ним гость находит игру в списке и комнату у ретранслятора хозяина.
func _publish() -> void:
	if mode != "host" or lobby_id == 0 or session == null:
		return
	var code := session.room_code
	api.set_lobby_data(lobby_id, "game", GAME_KEY)
	api.set_lobby_data(lobby_id, "build", NetSession.BUILD)
	api.set_lobby_data(lobby_id, "name", my_name)
	api.set_lobby_data(lobby_id, "map", map_id)
	api.set_lobby_data(lobby_id, "room", code)
	api.set_lobby_data(lobby_id, "open", "1" if code != "" else "0")
	api.set_lobby_joinable(lobby_id, code != "")
	api.set_rich_presence("connect", "%s %d" % [CONNECT_PREFIX, lobby_id])
	api.set_rich_presence("status", "Схватка: ждёт соперника" if code != "" else "Схватка: в бою")


## Оверлей Steam «пригласить друга» (работает в игре, запущенной из клиента Steam).
func invite() -> void:
	if lobby_id != 0:
		api.invite_dialog(lobby_id)


# ── Гость ────────────────────────────────────────────────────────────────────

## Войти в чужую игру: лобби Steam → хозяин из лобби → P2P к нему → лобби ретранслятора хозяина.
func join(sess: NetSession, lobby: int, player_name: String) -> void:
	leave()
	mode = "guest"
	_player_name = player_name
	_bind_session(sess)
	_join_lobby = lobby
	api.join_lobby(lobby)
	_join_t = 0.0
	status.emit("Входим в игру…")
	changed.emit()


func _on_lobby_joined(lobby: int, _permissions: int, _locked: bool, response: int) -> void:
	if mode != "guest" or lobby_id != 0 or lobby != _join_lobby:
		# ответ на вход, который уже отменён (leave() до ответа) или не тот, что просили: Steam нас
		# в это лобби записал — выйти, иначе игра у хозяина «занята» призраком
		if response == SteamApi.ENTER_SUCCESS and lobby != 0:
			api.leave_lobby(lobby)
		return
	_join_t = -1.0
	if response != SteamApi.ENTER_SUCCESS:
		_fail(_enter_text(response))
		leave()
		return
	lobby_id = lobby
	var owner := api.lobby_owner(lobby)
	if owner == 0 or owner == my_id:
		_fail("В этой игре нет хозяина")
		leave()
		return
	var h := api.connect_p2p(owner, VIRTUAL_PORT)
	if h == SteamApi.INVALID_HANDLE:
		_fail("Steam не открыл соединение с хозяином")
		leave()
		return
	var link := NetLinkSteam.new(api, h)
	_links[h] = link
	_auto_join = true
	session.link_label = "через Steam"
	session.connect_link(link, _player_name)
	status.emit("Соединяемся с «%s»…" % api.get_lobby_data(lobby, "name"))
	changed.emit()


static func _enter_text(response: int) -> String:
	match response:
		SteamApi.ENTER_DOESNT_EXIST:
			return "Этой игры уже нет"
		SteamApi.ENTER_FULL:
			return "В этой игре уже двое"
		SteamApi.ENTER_NOT_ALLOWED:
			return "В эту игру нельзя войти"
	return "Steam не пустил в игру (код %d)" % response


# ── Соединения Steam ─────────────────────────────────────────────────────────

func _on_conn_status(handle: int, info: Dictionary, _old_state: int) -> void:
	var state := int(info.get("connection_state", SteamApi.STATE_NONE))
	var on_listen := _listen != 0 and int(info.get("listen_socket", 0)) == _listen
	match state:
		SteamApi.STATE_CONNECTING:
			# входящее к хозяину: только участник нашего лобби Steam (любой, кто знает SteamID, мог
			# бы подключиться к сокету напрямую) и только если есть место; участника ещё нет в
			# списке — ждём ACCEPT_GRACE_S (список обновляется отдельным уведомлением)
			if mode != "host" or not on_listen:
				return
			var identity := int(info.get("identity", 0))
			if relay == null or not relay.has_capacity(false) or lobby_id == 0:
				api.close_connection(handle, SteamApi.END_APP_MIN, "мест нет", false)
			elif identity in api.lobby_members(lobby_id):
				api.accept(handle)
			else:
				_pending_accepts[handle] = {"identity": identity, "t": 0.0}
		SteamApi.STATE_CONNECTED:
			if _links.has(handle):
				(_links[handle] as NetLinkSteam).set_open()
			elif mode == "host" and on_listen and relay != null:
				var link := NetLinkSteam.new(api, handle, true)
				if relay.add_link(link, false) == 0:
					link.close(1000, "мест нет")
				else:
					_links[handle] = link
		SteamApi.STATE_CLOSED_BY_PEER, SteamApi.STATE_PROBLEM:
			_pending_accepts.erase(handle)
			if _links.has(handle):
				(_links[handle] as NetLinkSteam).set_closed(int(info.get("end_reason", 0)),
					String(info.get("end_debug", "")))
				_links.erase(handle)
				if mode == "guest":
					_guest_lost = true   # сессия сама сообщит об обрыве; нам — выйти из лобби
			# дескриптор освобождает та сторона, которой пришло закрытие
			api.close_connection(handle, 0, "", false)


## Ждущие входящие: появился в списке участников — принять; срок вышел — отказать.
func _tick_pending_accepts(dt: float) -> void:
	var members: Array[int] = api.lobby_members(lobby_id) if lobby_id != 0 else []
	for handle: int in _pending_accepts.keys():
		var e: Dictionary = _pending_accepts[handle]
		e["t"] = float(e["t"]) + dt
		if mode == "host" and relay != null and int(e["identity"]) in members:
			_pending_accepts.erase(handle)
			if relay.has_capacity(false):
				api.accept(handle)
			else:
				api.close_connection(handle, SteamApi.END_APP_MIN, "мест нет", false)
		elif float(e["t"]) >= accept_grace_s or mode != "host":
			_pending_accepts.erase(handle)
			api.close_connection(handle, SteamApi.END_APP_MIN, "не в лобби", false)


# ── Сессия ───────────────────────────────────────────────────────────────────

func _bind_session(sess: NetSession) -> void:
	_unbind_session()
	session = sess
	sess.welcomed.connect(_on_welcomed)
	sess.room_created.connect(_on_room_created)
	sess.lobby.connect(_on_rooms)
	sess.match_start.connect(_on_match_start)


func _unbind_session() -> void:
	if session == null:
		return
	for pair: Array in [[session.welcomed, _on_welcomed], [session.room_created, _on_room_created],
			[session.lobby, _on_rooms], [session.match_start, _on_match_start]]:
		var sig: Signal = pair[0]
		if sig.is_connected(pair[1]):
			sig.disconnect(pair[1])
	session = null


func _on_welcomed() -> void:
	if mode == "host":
		_create_room()
	elif mode == "guest" and lobby_id != 0:
		var code := api.get_lobby_data(lobby_id, "room")
		if code != "" and _auto_join:
			_auto_join = false
			session.join_room(code)


func _create_room() -> void:
	if session != null and session.room_code == "" and not _creating:
		_creating = true
		_create_t = 0.0
		session.create_room(map_id)


func _on_room_created(_code: String) -> void:
	_creating = false
	_publish()
	changed.emit()


## Лобби ретранслятора хозяина: гость с _auto_join входит в первую чужую комнату (хозяин ещё не
## успел записать код в лобби Steam); хозяин без комнаты открывает её снова из _process.
func _on_rooms(rooms: Array, _players: Array, _in_game: int) -> void:
	if session == null or session.stage != NetSession.Stage.LOBBY:
		return
	if mode == "guest" and _auto_join and session.room_code == "":
		for r: Variant in rooms:
			if r is Dictionary and not bool((r as Dictionary).get("mine", false)):
				_auto_join = false
				session.join_room(String((r as Dictionary).get("code", "")))
				break
	changed.emit()


func _on_match_start(_seed_value: int, _map_id: String, _side: int) -> void:
	if mode == "host" and lobby_id != 0:
		api.set_lobby_data(lobby_id, "open", "0")
		api.set_lobby_joinable(lobby_id, false)
		api.set_rich_presence("status", "Схватка: в бою")
	changed.emit()


# ── Список игр ───────────────────────────────────────────────────────────────

func refresh() -> void:
	if not ok:
		return
	api.request_lobby_list({"game": GAME_KEY, "build": NetSession.BUILD, "open": "1"}, LIST_MAX)


func _on_lobby_list(ids: Array) -> void:
	var rows: Array = []
	for v: Variant in ids:
		var lid := int(v)
		if lid == 0 or (lid == lobby_id and mode == "host"):
			continue
		rows.append({"id": lid, "name": api.get_lobby_data(lid, "name"),
			"map": api.get_lobby_data(lid, "map"), "members": api.lobby_member_count(lid)})
	lobbies.emit(rows)


# ── Приглашения ──────────────────────────────────────────────────────────────

func _on_join_requested(lobby: int, _friend_id: int) -> void:
	if lobby != 0:
		_pending_join = lobby
		join_request.emit(lobby)


func _on_join_game_requested(_user: int, connect_string: String) -> void:
	var parts := connect_string.strip_edges().split(" ", false)
	if parts.size() == 2 and parts[0] == CONNECT_PREFIX and parts[1].is_valid_int():
		_on_join_requested(int(parts[1]), 0)


# ── Уход ─────────────────────────────────────────────────────────────────────

## Выйти из игры/лобби: соединения, сокет, ядро, лобби Steam. Сессию вызывающий закрывает сам
## (до leave(): иначе её канал закроет ядро, и она покажет «связь потеряна»).
func leave() -> void:
	for h: int in _links.keys():
		(_links[h] as NetLinkSteam).close(1000, "bye")
	_links.clear()
	for h: int in _pending_accepts.keys():
		api.close_connection(h, SteamApi.END_APP_MIN, "хозяин ушёл", false)
	_pending_accepts.clear()
	if relay != null:
		relay.shutdown("хозяин ушёл")
		relay = null
	if _listen != 0:
		api.close_listen(_listen)
		_listen = 0
	if lobby_id != 0:
		api.leave_lobby(lobby_id)
		lobby_id = 0
	elif _join_lobby != 0:
		api.leave_lobby(_join_lobby)   # вход отменён до ответа: Steam мог уже записать нас в лобби
	_join_lobby = 0
	if ok and mode != "":
		api.clear_rich_presence()
	_unbind_session()
	mode = ""
	_creating = false
	_auto_join = false
	_guest_lost = false
	_join_t = -1.0
	_owner_t = 0.0
	changed.emit()


func _fail(text: String) -> void:
	push_warning("SteamNet: %s" % text)
	failed.emit(text)
