class_name NetLinkWs
extends NetLink
##
## Канал WebSocket (NetLink поверх WebSocketPeer): клиент к ретранслятору (connect_to_url) и
## принятое ретранслятором соединение (accept). Размеры буферов — те же, что были в NetSession и
## net_relay.gd до вынесения транспорта (B-378: пустые ходы по ~25 байт упирались в 256 пакетов
## раньше, чем в байты; пинг раз в 20 с — долгий кадр загрузки не рвёт связь).
##

var _ws: WebSocketPeer
var _violation := ""
var _last_size := 0


func _init(ws: WebSocketPeer = null) -> void:
	_ws = ws if ws != null else WebSocketPeer.new()


## Клиентский канал к ретранслятору.
static func client() -> NetLinkWs:
	var ws := WebSocketPeer.new()
	ws.inbound_buffer_size = 262144
	ws.outbound_buffer_size = 65536
	ws.max_queued_packets = 512
	ws.heartbeat_interval = 20.0
	return NetLinkWs.new(ws)


## Соединение, принятое ретранслятором (null — рукопожатие не началось).
static func accept(stream: StreamPeerTCP) -> NetLinkWs:
	var ws := WebSocketPeer.new()
	ws.inbound_buffer_size = 65536
	ws.outbound_buffer_size = 262144
	ws.max_queued_packets = 8192
	ws.heartbeat_interval = 20.0
	if ws.accept_stream(stream) != OK:
		return null
	return NetLinkWs.new(ws)


func connect_to_url(url: String) -> Error:
	return _ws.connect_to_url(url)


func poll() -> void:
	_ws.poll()


func state() -> int:
	match _ws.get_ready_state():
		WebSocketPeer.STATE_OPEN:
			return State.OPEN
		WebSocketPeer.STATE_CONNECTING:
			return State.CONNECTING
	return State.CLOSED


func send_text(text: String) -> Error:
	if _ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return ERR_UNAVAILABLE
	return _ws.send_text(text)


func available() -> int:
	return _ws.get_available_packet_count()


func take_text() -> String:
	var data := _ws.get_packet()
	_last_size = data.size()
	if not _ws.was_string_packet():
		_violation = "двоичный пакет"
		return ""
	return data.get_string_from_utf8()


func last_size() -> int:
	return _last_size


func violation() -> String:
	return _violation


func buffered_out() -> int:
	return _ws.get_current_outbound_buffered_amount()


func close(code: int, reason: String) -> void:
	_ws.close(code, reason)


func close_code() -> int:
	return _ws.get_close_code()


func close_reason() -> String:
	return _ws.get_close_reason()


func kind() -> String:
	return "ws"


func direct_allowed() -> bool:
	return true
