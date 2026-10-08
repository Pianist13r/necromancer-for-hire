# gdlint: disable=function-name
extends RefCounted
##
## Заглушка синглтона GodotSteam для регресса без клиента Steam (tests/legion_net_steam_test.gd):
## имена методов и сигналов — ровно те, что зовёт SteamApi (godotsteam.com/classes/*, 4.23.1),
## семантика — упрощённый Steam: несколько «клиентов» в одном процессе делят общее «облако»
## (лобби, слушающие сокеты), соединения P2P — пара дескрипторов у двух заглушек, сообщения
## надёжные и по порядку, обратные вызовы приходят только из run_callbacks() (как у Steam —
## не внутри вызова). Проба порчи: corrupt_next — испортить байт следующего входящего сообщения.
##

signal lobby_created(connect: int, lobby: int)
signal lobby_joined(lobby_id: int, permissions: int, locked: bool, response: int)
signal lobby_match_list(lobbies: Array)
signal lobby_data_update(success: bool, lobby_id: int, member_id: int)
signal network_connection_status_changed(connect_handle: int, connection: Dictionary,
	old_state: int)
signal join_requested(lobby: int, steam_id: int)
signal join_game_requested(user: int, connect: String)

const STATE_CONNECTING := 1
const STATE_CONNECTED := 3
const STATE_CLOSED_BY_PEER := 4
const STATE_PROBLEM := 5
const END_MISC_PEER_SENT_NO_CONNECTION := 5010
const RESULT_OK := 1
const RESULT_NO_CONNECTION := 3
const RESULT_INVALID_STATE := 11
const ENTER_SUCCESS := 1
const ENTER_DOESNT_EXIST := 2
const ENTER_FULL := 4

## Общее «облако» всех заглушек процесса.
static var lobbies: Dictionary = {}     ## id → {owner, data, members, joinable, type, max}
static var listeners: Dictionary = {}   ## "steam_id:port" → [заглушка, дескриптор]
static var users: Dictionary = {}       ## steam_id → заглушка
static var next_lobby := 1000

var steam_id := 0
var persona := ""
## Клиент «не запущен»: steamInitEx отвечает NO_STEAM_CLIENT.
var running := true
var initialized := false
var rich: Dictionary = {}
var corrupt_next := false
var sent := 0
var received := 0

var _next_handle := 1
var _conns: Dictionary = {}    ## дескриптор → {peer, peer_h, state, identity, listen, inbox, …}
var _listens: Dictionary = {}  ## дескриптор → порт
var _pending: Array[Callable] = []
var _filters: Dictionary = {}
var _msg_no := 0


func _init(id: int, name: String) -> void:
	steam_id = id
	persona = name
	users[id] = self


static func reset_cloud() -> void:
	lobbies.clear()
	listeners.clear()
	users.clear()
	next_lobby = 1000


# ── Main / User / Friends ───────────────────────────────────────────────────

func steamInitEx(_app_id: int, _embed_callbacks: bool) -> Dictionary:
	initialized = running
	return {"status": 0 if running else 2, "verbal": "" if running else "no client"}


func run_callbacks() -> void:
	var q := _pending
	_pending = []
	for c: Callable in q:
		c.call()


func isSteamRunning() -> bool:
	return running


func steamShutdown() -> void:
	initialized = false


func getSteamID() -> int:
	return steam_id


func getPersonaName() -> String:
	return persona


func getFriendPersonaName(id: int) -> String:
	return String(users[id].persona) if users.has(id) else ""


func initRelayNetworkAccess() -> void:
	pass


func setRichPresence(key: String, value: String) -> bool:
	rich[key] = value
	return true


func clearRichPresence() -> void:
	rich.clear()


func activateGameOverlayInviteDialog(_lobby_id: int) -> void:
	pass


## Проба: друг принял приглашение в лобби.
func simulate_invite(lobby_id: int, friend_id: int) -> void:
	_later(func() -> void: join_requested.emit(lobby_id, friend_id))


# ── Matchmaking ─────────────────────────────────────────────────────────────

func createLobby(lobby_type: int, max_members: int) -> void:
	var id := next_lobby
	next_lobby += 1
	lobbies[id] = {"owner": steam_id, "data": {}, "members": [steam_id], "joinable": true,
		"type": lobby_type, "max": max_members}
	_later(func() -> void: lobby_created.emit(RESULT_OK, id))


func joinLobby(lobby_id: int) -> void:
	_later(func() -> void:
		if not lobbies.has(lobby_id):
			lobby_joined.emit(lobby_id, 0, false, ENTER_DOESNT_EXIST)
			return
		var l: Dictionary = lobbies[lobby_id]
		if (l["members"] as Array).size() >= int(l["max"]) or not bool(l["joinable"]):
			lobby_joined.emit(lobby_id, 0, false, ENTER_FULL)
			return
		(l["members"] as Array).append(steam_id)
		lobby_joined.emit(lobby_id, 0, false, ENTER_SUCCESS))


func leaveLobby(lobby_id: int) -> void:
	if not lobbies.has(lobby_id):
		return
	var l: Dictionary = lobbies[lobby_id]
	var members: Array = l["members"]
	members.erase(steam_id)
	# как у Steam: владение переходит оставшемуся участнику, пустое лобби пропадает
	if members.is_empty():
		lobbies.erase(lobby_id)
	elif int(l["owner"]) == steam_id:
		l["owner"] = int(members[0])


func setLobbyData(lobby_id: int, key: String, value: String) -> bool:
	if not lobbies.has(lobby_id) or int(lobbies[lobby_id]["owner"]) != steam_id:
		return false
	(lobbies[lobby_id]["data"] as Dictionary)[key] = value
	return true


func getLobbyData(lobby_id: int, key: String) -> String:
	if not lobbies.has(lobby_id):
		return ""
	return String((lobbies[lobby_id]["data"] as Dictionary).get(key, ""))


func setLobbyJoinable(lobby_id: int, joinable: bool) -> bool:
	if not lobbies.has(lobby_id):
		return false
	lobbies[lobby_id]["joinable"] = joinable
	return true


func getLobbyOwner(lobby_id: int) -> int:
	return int(lobbies[lobby_id]["owner"]) if lobbies.has(lobby_id) else 0


func getNumLobbyMembers(lobby_id: int) -> int:
	return (lobbies[lobby_id]["members"] as Array).size() if lobbies.has(lobby_id) else 0


func getLobbyMemberByIndex(lobby_id: int, i: int) -> int:
	return int((lobbies[lobby_id]["members"] as Array)[i]) if lobbies.has(lobby_id) else 0


func addRequestLobbyListStringFilter(key: String, value: String, _comparison: int) -> void:
	_filters[key] = value


func addRequestLobbyListDistanceFilter(_distance: int) -> void:
	pass


func addRequestLobbyListResultCountFilter(_max_results: int) -> void:
	pass


func requestLobbyList() -> void:
	var filters := _filters.duplicate()
	_filters.clear()
	var ids: Array = []
	for id: int in lobbies:
		var data: Dictionary = lobbies[id]["data"]
		var ok := true
		for k: String in filters:
			if String(data.get(k, "")) != String(filters[k]):
				ok = false
		if ok:
			ids.append(id)
	_later(func() -> void: lobby_match_list.emit(ids))


# ── Networking Sockets ──────────────────────────────────────────────────────

func createListenSocketP2P(virtual_port: int, _options: Dictionary) -> int:
	var h := _next_handle
	_next_handle += 1
	_listens[h] = virtual_port
	listeners["%d:%d" % [steam_id, virtual_port]] = [self, h]
	return h


func closeListenSocket(h: int) -> bool:
	if not _listens.has(h):
		return false
	listeners.erase("%d:%d" % [steam_id, int(_listens[h])])
	_listens.erase(h)
	return true


func connectP2P(remote_steam_id: int, virtual_port: int, _options: Dictionary) -> int:
	var h := _next_handle
	_next_handle += 1
	var key := "%d:%d" % [remote_steam_id, virtual_port]
	if not listeners.has(key):
		_conns[h] = {"peer": null, "peer_h": 0, "state": STATE_CONNECTING,
			"identity": remote_steam_id, "listen": 0, "inbox": [],
			"end_reason": END_MISC_PEER_SENT_NO_CONNECTION, "end_debug": "no listener"}
		_later(func() -> void: _set_state(h, STATE_PROBLEM, STATE_CONNECTING))
		return h
	var target: RefCounted = listeners[key][0]
	var th: int = target._next_handle
	target._next_handle += 1
	_conns[h] = {"peer": target, "peer_h": th, "state": STATE_CONNECTING,
		"identity": remote_steam_id, "listen": 0, "inbox": [], "end_reason": 0, "end_debug": ""}
	target._conns[th] = {"peer": self, "peer_h": h, "state": STATE_CONNECTING,
		"identity": steam_id, "listen": int(listeners[key][1]), "inbox": [], "end_reason": 0,
		"end_debug": ""}
	target._later(func() -> void: target._emit_status(th, 0))
	return h


func acceptConnection(h: int) -> int:
	if not _conns.has(h) or int(_conns[h]["state"]) != STATE_CONNECTING:
		return RESULT_INVALID_STATE
	var c: Dictionary = _conns[h]
	var peer: RefCounted = c["peer"]
	if peer == null:
		return RESULT_NO_CONNECTION
	c["state"] = STATE_CONNECTED
	_later(func() -> void: _emit_status(h, STATE_CONNECTING))
	var ph := int(c["peer_h"])
	peer._conns[ph]["state"] = STATE_CONNECTED
	peer._later(func() -> void: peer._emit_status(ph, STATE_CONNECTING))
	return RESULT_OK


func closeConnection(h: int, reason: int, debug_message: String, _linger: bool) -> bool:
	if not _conns.has(h):
		return false
	var c: Dictionary = _conns[h]
	_conns.erase(h)
	var peer: RefCounted = c["peer"]
	if peer != null and peer._conns.has(int(c["peer_h"])):
		var ph := int(c["peer_h"])
		var pc: Dictionary = peer._conns[ph]
		var old := int(pc["state"])
		pc["state"] = STATE_CLOSED_BY_PEER
		pc["end_reason"] = reason
		pc["end_debug"] = debug_message
		pc["peer"] = null
		peer._later(func() -> void: peer._emit_status(ph, old))
	return true


func sendMessageToConnection(h: int, data: PackedByteArray, _flags: int) -> Dictionary:
	if not _conns.has(h) or int(_conns[h]["state"]) != STATE_CONNECTED:
		return {"result": RESULT_NO_CONNECTION}
	var c: Dictionary = _conns[h]
	var peer: RefCounted = c["peer"]
	if peer == null:
		return {"result": RESULT_NO_CONNECTION}
	var payload := data.duplicate()
	if peer.corrupt_next and payload.size() > 0:
		peer.corrupt_next = false
		payload[payload.size() - 1] = (payload[payload.size() - 1] + 1) & 0xff
	_msg_no += 1
	sent += 1
	(peer._conns[int(c["peer_h"])]["inbox"] as Array).append({"payload": payload,
		"size": payload.size(), "connection": int(c["peer_h"]), "identity": steam_id,
		"message_number": _msg_no, "flags": _flags})
	return {"result": RESULT_OK, "message_number": _msg_no}


func receiveMessagesOnConnection(h: int, max_messages: int) -> Array:
	if not _conns.has(h):
		return []
	var inbox: Array = _conns[h]["inbox"]
	var out: Array = []
	while not inbox.is_empty() and out.size() < max_messages:
		out.append(inbox.pop_front())
		received += 1
	return out


func getConnectionRealTimeStatus(h: int, _lanes: int, _get_status: bool) -> Dictionary:
	if not _conns.has(h):
		return {}
	return {"connection_status": {"state": int(_conns[h]["state"]), "ping": 0,
		"pending_reliable": 0, "pending_unreliable": 0}}


## Сколько соединений открыто у этой заглушки (проба: дескрипторы освобождаются).
func open_connections() -> int:
	return _conns.size()


func _set_state(h: int, state: int, old: int) -> void:
	if _conns.has(h):
		_conns[h]["state"] = state
		_emit_status(h, old)


func _emit_status(h: int, old: int) -> void:
	var c: Dictionary = _conns.get(h, {})
	network_connection_status_changed.emit(h, {"identity": int(c.get("identity", 0)),
		"listen_socket": int(c.get("listen", 0)), "connection_state": int(c.get("state", 0)),
		"end_reason": int(c.get("end_reason", 0)), "end_debug": String(c.get("end_debug", "")),
		"remote_address": ""}, old)


func _later(c: Callable) -> void:
	_pending.append(c)
