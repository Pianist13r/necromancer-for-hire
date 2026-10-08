class_name NetLink
extends RefCounted
##
## Транспорт онлайн-«Схватки» (docs/pvp/NET_LOCKSTEP.md, «Транспорт»): текстовые сообщения
## протокола lockstep ходят по одному из каналов — WebSocket к ретранслятору (NetLinkWs), пара
## концов в одном процессе (NetLinkPipe: хозяин Steam-игры говорит со своим же ретранслятором) или
## соединение Steam Networking Sockets (NetLinkSteam). NetSession и NetRelayCore знают только этот
## класс: протокол один, каналы разные.
##
## Семантика — как у WebSocketPeer: poll() раз в кадр, состояние CONNECTING → OPEN → CLOSED,
## после закрытия уже принятые пакеты всё ещё читаются (в них может лежать причина разрыва).
##

enum State { CONNECTING, OPEN, CLOSED }


func poll() -> void:
	pass


func state() -> int:
	return State.CLOSED


## Текст в канал; ERR_UNAVAILABLE — канал не открыт, ERR_BUSY — очередь полна (повторить позже).
func send_text(_text: String) -> Error:
	return ERR_UNAVAILABLE


## Сколько принятых сообщений ждут чтения.
func available() -> int:
	return 0


## Следующее принятое сообщение (пусто, если нет или пакет не текст — см. violation()).
func take_text() -> String:
	return ""


## Размер последнего взятого сообщения в байтах (предел сообщения у ретранслятора — в байтах).
func last_size() -> int:
	return 0


## Нарушение протокола канала (двоичный пакет, повреждённое сообщение) — причина; пусто — нет.
func violation() -> String:
	return ""


## Байт в исходящей очереди канала, ещё не ушедших (ретранслятор не кладёт больше PEER_BUF).
func buffered_out() -> int:
	return 0


func close(_code: int, _reason: String) -> void:
	pass


func close_code() -> int:
	return 0


func close_reason() -> String:
	return ""


## «ws» / «pipe» / «steam» — для журнала и надписей.
func kind() -> String:
	return ""


## Прямой UDP-путь (NetP2P) имеет смысл только рядом с нашим ретранслятором: через Steam и
## внутри процесса пробивать нечего.
func direct_allowed() -> bool:
	return false


## Сколько ждать открытия (с) — у Steam маршрут через реле ищется дольше, чем открывается WebSocket.
func connect_timeout() -> float:
	return 10.0
