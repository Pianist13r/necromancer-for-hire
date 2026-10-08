# gdlint: disable=max-public-methods
class_name SteamApi
extends RefCounted
##
## Единственное место, где игра зовёт GodotSteam (GDExtension 4.23.1, godotsteam.com/classes/…).
## Синглтон «Steam» берётся динамически (Engine.get_singleton): сборки itch/GitHub расширения не
## несут, и код обязан компилироваться без него. Все вызовы — через call() по именам из
## документации GodotSteam; в тестах вместо синглтона — заглушка с теми же именами
## (tests/steam_fake.gd), так что всё выше этого класса проверяется без клиента Steam.
##
## Числа — из Steamworks SDK 1.65 / документации GodotSteam (08.10.2026): SteamAPIInitResult,
## Result, LobbyType, LobbyComparison, LobbyDistanceFilter, ChatRoomEnterResponse,
## NetworkingConnectionState, NETWORKING_SEND_*, диапазон причин закрытия приложения.
##

const SINGLETON := "Steam"

const INIT_OK := 0
const RESULT_OK := 1
const RESULT_LIMIT_EXCEEDED := 25
const LOBBY_PRIVATE := 0
const LOBBY_FRIENDS_ONLY := 1
const LOBBY_PUBLIC := 2
const LOBBY_COMPARISON_EQUAL := 0
const LOBBY_DISTANCE_WORLDWIDE := 3
const ENTER_SUCCESS := 1
const ENTER_DOESNT_EXIST := 2
const ENTER_NOT_ALLOWED := 3
const ENTER_FULL := 4
const SEND_RELIABLE := 8
const STATE_NONE := 0
const STATE_CONNECTING := 1
const STATE_FINDING_ROUTE := 2
const STATE_CONNECTED := 3
const STATE_CLOSED_BY_PEER := 4
const STATE_PROBLEM := 5
## Причины закрытия соединения, отданные приложению: 1000…1999.
const END_APP_MIN := 1000
const END_APP_MAX := 1999
const INVALID_HANDLE := 0

var backend: Object


func _init(b: Object) -> void:
	backend = b


## Синглтон GodotSteam, если расширение загружено (в itch-сборке — null).
static func find() -> Object:
	if Engine.has_singleton(SINGLETON):
		return Engine.get_singleton(SINGLETON)
	return null


# ── Запуск ─────────────────────────────────────────────────────────────────

## {status: SteamAPIInitResult, verbal: String}; app_id 0 — из клиента Steam (сборка в Steam),
## 480 — Spacewar для проб вне своего приложения.
func init(app_id: int) -> Dictionary:
	var r: Variant = backend.call(&"steamInitEx", app_id, false)
	return r if r is Dictionary else {"status": 1, "verbal": "steamInitEx вернул не словарь"}


func run_callbacks() -> void:
	backend.call(&"run_callbacks")


func is_running() -> bool:
	return bool(backend.call(&"isSteamRunning"))


func shutdown() -> void:
	backend.call(&"steamShutdown")


func my_id() -> int:
	return int(backend.call(&"getSteamID"))


func my_name() -> String:
	return String(backend.call(&"getPersonaName"))


func friend_name(steam_id: int) -> String:
	return String(backend.call(&"getFriendPersonaName", steam_id))


## Реле Valve (SDR) поднимается заранее — иначе первое P2P-соединение ждёт его инициализации.
func init_relay() -> void:
	backend.call(&"initRelayNetworkAccess")


## Сигнал синглтона → свой обработчик (нет такого сигнала — false, игра идёт дальше без него).
func on(signal_name: StringName, handler: Callable) -> bool:
	if not backend.has_signal(signal_name):
		return false
	if backend.is_connected(signal_name, handler):
		return true
	return backend.connect(signal_name, handler) == OK


# ── Лобби (ISteamMatchmaking) ──────────────────────────────────────────────

func create_lobby(lobby_type: int, max_members: int) -> void:
	backend.call(&"createLobby", lobby_type, max_members)


func join_lobby(lobby_id: int) -> void:
	backend.call(&"joinLobby", lobby_id)


func leave_lobby(lobby_id: int) -> void:
	backend.call(&"leaveLobby", lobby_id)


func set_lobby_data(lobby_id: int, key: String, value: String) -> bool:
	return bool(backend.call(&"setLobbyData", lobby_id, key, value))


func get_lobby_data(lobby_id: int, key: String) -> String:
	return String(backend.call(&"getLobbyData", lobby_id, key))


func set_lobby_joinable(lobby_id: int, joinable: bool) -> bool:
	return bool(backend.call(&"setLobbyJoinable", lobby_id, joinable))


func lobby_owner(lobby_id: int) -> int:
	return int(backend.call(&"getLobbyOwner", lobby_id))


func lobby_member_count(lobby_id: int) -> int:
	return int(backend.call(&"getNumLobbyMembers", lobby_id))


func lobby_members(lobby_id: int) -> Array[int]:
	var out: Array[int] = []
	for i in lobby_member_count(lobby_id):
		out.append(int(backend.call(&"getLobbyMemberByIndex", lobby_id, i)))
	return out


## Список лобби, где каждая пара ключ=значение совпадает буквально; ответ — сигнал
## lobby_match_list(Array[uint64]).
func request_lobby_list(filters: Dictionary, max_results: int) -> void:
	for key: String in filters:
		backend.call(&"addRequestLobbyListStringFilter", key, String(filters[key]),
			LOBBY_COMPARISON_EQUAL)
	backend.call(&"addRequestLobbyListDistanceFilter", LOBBY_DISTANCE_WORLDWIDE)
	backend.call(&"addRequestLobbyListResultCountFilter", max_results)
	backend.call(&"requestLobbyList")


# ── Друзья и оверлей (ISteamFriends) ──────────────────────────────────────

func set_rich_presence(key: String, value: String) -> bool:
	return bool(backend.call(&"setRichPresence", key, value))


func clear_rich_presence() -> void:
	backend.call(&"clearRichPresence")


func invite_dialog(lobby_id: int) -> void:
	backend.call(&"activateGameOverlayInviteDialog", lobby_id)


# ── Соединения (ISteamNetworkingSockets, P2P через SDR) ───────────────────

func listen_p2p(virtual_port: int) -> int:
	return int(backend.call(&"createListenSocketP2P", virtual_port, {}))


func connect_p2p(remote_steam_id: int, virtual_port: int) -> int:
	return int(backend.call(&"connectP2P", remote_steam_id, virtual_port, {}))


func accept(handle: int) -> int:
	return int(backend.call(&"acceptConnection", handle))


## reason — из диапазона приложения END_APP_MIN…END_APP_MAX (соперник увидит и debug_message).
func close_connection(handle: int, reason: int, debug_message: String, linger: bool) -> bool:
	return bool(backend.call(&"closeConnection", handle, reason, debug_message, linger))


func close_listen(handle: int) -> bool:
	return bool(backend.call(&"closeListenSocket", handle))


## Код Result (RESULT_OK — ушло в очередь; RESULT_LIMIT_EXCEEDED — буфер отправки полон).
func send(handle: int, data: PackedByteArray, flags: int) -> int:
	var r: Variant = backend.call(&"sendMessageToConnection", handle, data, flags)
	if r is Dictionary:
		return int((r as Dictionary).get("result", 0))
	return int(r) if r is int else 0


## Принятые сообщения: словари с «payload» (PackedByteArray или String — документация 4.23
## пишет string, исходники отдают байты; NetLinkSteam берёт оба).
func receive(handle: int, max_messages: int) -> Array:
	var r: Variant = backend.call(&"receiveMessagesOnConnection", handle, max_messages)
	return r if r is Array else []


## Состояние соединения в реальном времени: {state, ping, pending_reliable, …} или пусто.
func status(handle: int) -> Dictionary:
	var r: Variant = backend.call(&"getConnectionRealTimeStatus", handle, 0, true)
	if r is Dictionary and (r as Dictionary).get("connection_status") is Dictionary:
		return (r as Dictionary)["connection_status"]
	return {}
