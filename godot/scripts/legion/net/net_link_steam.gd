class_name NetLinkSteam
extends NetLink
##
## Канал поверх соединения Steam Networking Sockets (P2P через реле Valve, надёжный упорядоченный
## поток — NETWORKING_SEND_RELIABLE). Состояние меняет SteamNet по сигналу
## network_connection_status_changed (set_open / set_closed): сам канал только шлёт и читает.
##
## Каждое сообщение — «<fnv1a-32 hex8>:<текст>»: Steam и так шифрует и проверяет поток, но
## сообщество GodotSteam ловило повреждённые пакеты и при Reliable (brogolem35, rollback-with-
## godotsteam) — повреждённое сообщение в lockstep обошлось бы рассинхроном без объяснения.
## Контрольная сумма не сошлась — канал закрывается с причиной «повреждено», а не молчит.
##

const CLOSE_CORRUPT := 1007   ## как у WebSocket: данные не разобраны
const RECEIVE_BATCH := 64
const FNV_OFFSET := 0x811c9dc5
const FNV_PRIME := 0x01000193

var api: SteamApi
var handle := 0
var _state := State.CONNECTING
var _in: Array[String] = []
var _sizes: Array[int] = []
var _last_size := 0
var _violation := ""
var _code := 0
var _reason := ""
var _buffered := 0


func _init(a: SteamApi, h: int, open := false) -> void:
	api = a
	handle = h
	if open:
		_state = State.OPEN


## Соединение установлено (CONNECTED).
func set_open() -> void:
	if _state == State.CONNECTING:
		_state = State.OPEN


## Соперник закрыл соединение или оно оборвалось (CLOSED_BY_PEER / PROBLEM_DETECTED_LOCALLY):
## end_reason — код причины, end_debug — строка закрывшей стороны.
func set_closed(end_reason: int, end_debug: String) -> void:
	if _state == State.CLOSED:
		return
	_state = State.CLOSED
	_code = end_reason - SteamApi.END_APP_MIN + 1000 if end_reason >= SteamApi.END_APP_MIN \
		and end_reason <= SteamApi.END_APP_MAX else end_reason
	_reason = end_debug


func poll() -> void:
	if _state != State.OPEN:
		return
	for m: Variant in api.receive(handle, RECEIVE_BATCH):
		if not (m is Dictionary):
			continue
		var p: Variant = (m as Dictionary).get("payload")
		var bytes: PackedByteArray
		if p is PackedByteArray:
			bytes = p
		elif p is String:
			bytes = (p as String).to_utf8_buffer()
		else:
			continue
		var text := bytes.get_string_from_utf8()
		if text.length() < 9 or text[8] != ":" or checksum(text.substr(9)) != text.substr(0, 8):
			_violation = "повреждённое сообщение"
			close(CLOSE_CORRUPT, "повреждено")
			return
		_in.append(text.substr(9))
		_sizes.append(bytes.size() - 9)
	var st := api.status(handle)
	_buffered = int(st.get("pending_reliable", 0)) + int(st.get("pending_unreliable", 0))


func state() -> int:
	return _state


func send_text(text: String) -> Error:
	if _state != State.OPEN:
		return ERR_UNAVAILABLE
	var frame := (checksum(text) + ":" + text).to_utf8_buffer()
	var r := api.send(handle, frame, SteamApi.SEND_RELIABLE)
	if r == SteamApi.RESULT_OK:
		return OK
	return ERR_BUSY if r == SteamApi.RESULT_LIMIT_EXCEEDED else ERR_CANT_CONNECT


func available() -> int:
	return _in.size()


func take_text() -> String:
	if _in.is_empty():
		return ""
	_last_size = _sizes.pop_front()
	return _in.pop_front()


func last_size() -> int:
	return _last_size


func violation() -> String:
	return _violation


func buffered_out() -> int:
	return _buffered


## code — как у WebSocket (1000 — штатно); сопернику уходит причина приложения 1000…1999 и текст.
func close(code: int, reason: String) -> void:
	if _state == State.CLOSED:
		return
	_state = State.CLOSED
	_code = code
	_reason = reason
	api.close_connection(handle, SteamApi.END_APP_MIN + clampi(code - 1000, 0, 999), reason, true)


func close_code() -> int:
	return _code


func close_reason() -> String:
	return _reason


func kind() -> String:
	return "steam"


func connect_timeout() -> float:
	return 20.0


## FNV-1a 32 бит по UTF-8, hex8 — быстро на GDScript для сообщений в десятки байт.
static func checksum(text: String) -> String:
	var h := FNV_OFFSET
	for b: int in text.to_utf8_buffer():
		h = ((h ^ b) * FNV_PRIME) & 0xffffffff
	return "%08x" % h
