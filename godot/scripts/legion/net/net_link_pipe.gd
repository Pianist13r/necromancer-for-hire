class_name NetLinkPipe
extends NetLink
##
## Пара концов в одном процессе: что отправлено в один, читается из другого в том же порядке.
## Хозяин Steam-игры держит ретранслятор (NetRelayCore) у себя и подключается к нему этим каналом,
## а соперник приходит через Steam (NetLinkSteam) — протокол у обоих тот же, что через сервер.
## Одиночный (непарный) конец — заглушка в тестах: CONNECTING, отправка не проходит.
##

## Второй конец. Не типизирован своим же классом и зовётся через call(): страховка от падений
## движка на выходе при самоссылочных типах (legion_net_security_test 08.10.2026 падал с кодом 139
## раз в ~6 прогонов, пока заглушки игроков были NetLinkPipe; причина до конца не установлена).
var _peer: RefCounted
var _in: Array[String] = []
var _sizes: Array[int] = []
var _state := State.CONNECTING
var _code := 0
var _reason := ""
var _last_size := 0


## Два открытых конца: [a, b].
static func pair() -> Array:
	var a := NetLinkPipe.new()
	var b := NetLinkPipe.new()
	a._peer = b
	b._peer = a
	a._state = State.OPEN
	b._state = State.OPEN
	return [a, b]


func state() -> int:
	return _state


func send_text(text: String) -> Error:
	if _state != State.OPEN or _peer == null:
		return ERR_UNAVAILABLE
	_peer.call(&"_receive", text)
	return OK


func _receive(text: String) -> void:
	_in.append(text)
	_sizes.append(text.to_utf8_buffer().size())


func available() -> int:
	return _in.size()


func take_text() -> String:
	if _in.is_empty():
		return ""
	_last_size = _sizes.pop_front()
	return _in.pop_front()


func last_size() -> int:
	return _last_size


## Ссылки концов друг на друга — цикл RefCounted: при закрытии рвём его с обеих сторон, иначе
## пара утекала на каждый host() (verifier 08.10, п. 3d).
func close(code: int, reason: String) -> void:
	if _state == State.CLOSED:
		return
	_state = State.CLOSED
	_code = code
	_reason = reason
	var peer := _peer
	_peer = null
	if peer != null:
		peer.call(&"_on_peer_closed", code, reason)


func _on_peer_closed(code: int, reason: String) -> void:
	_peer = null
	if _state == State.CLOSED:
		return
	_state = State.CLOSED
	_code = code
	_reason = reason


func close_code() -> int:
	return _code


func close_reason() -> String:
	return _reason


func kind() -> String:
	return "pipe"
