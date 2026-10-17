class_name NetRejoin
extends RefCounted
##
## Клиентская половина переподключения в идущий матч (docs/pvp/NET_LOCKSTEP.md,
## «Переподключение»): состояние попыток, кольцо своих сырых ходов для досылки, отсчёт отсутствия
## соперника. Сокеты и протокол — у NetSession; здесь только данные и расписание, чтобы сессия не
## разрасталась.
##
## Жизнь: start матча с «rj» → reset_match(); обрыв сокета в бою → begin(); попытки по расписанию
## (пауза перед следующей — PAUSES, ответа нет ATTEMPT_WAIT_MS — следующая); сдаться — через
## GIVE_UP_MS от обрыва (сервер ждёт RECONNECT_GRACE_MS = 45 с с СВОЕГО обнаружения, оно позже
## нашего — запас 15 с) или на окончательный отказ сервера. После «rejoined» — досылка своих ходов
## с «next» из кольца (не больше RESYNC_PER_FRAME за кадр: предел частоты сервера на досылку снят,
## но сокет и чужие буферы — не резиновые), и только потом снова бой.
##

const GIVE_UP_MS := 60000
const ATTEMPT_WAIT_MS := 5000
## Паузы перед попытками (с): Wi-Fi/смена сети — 5–15 с; первые попытки часто, потом раз в 4 с.
const PAUSES: Array[float] = [0.5, 1.0, 2.0, 4.0]
## Своих сырых ходов помнить: при живом UDP соперник мог уйти вперёд копии на сервере до
## NetSession.RELAY_LAG_MAX (200) ходов + задержка — досылка до ~220; 512 — с запасом.
const OWN_KEEP := 512
const RESYNC_PER_FRAME := 40
## Досылка не кладёт в исходящий буфер канала больше этого (у клиентского WebSocket — 64 КиБ;
## ход со штрихом — до 8 КБ, 40 ходов за кадр байты не ограничивают).
const RESYNC_BUF := 32768
## Канал столько не берёт ни одного хода досылки — это обрыв (путь _on_closed, новый возврат), а не
## бесконечное ожидание.
const RESYNC_STALL_MS := 8000
## Отсчёт «Соперник переподключается…» — не дольше этого (защита от кривого ms).
const OPP_AWAY_MAX_MS := 120000

## Секрет стороны из start («rj», 32 hex); пусто — матч без возврата (старый сервер или соперник
## без caps): обрыв — как прежде, в лобби.
var token := ""
var code := ""
var side := -1
## Id переподключения (одного эпизода обрыва): повтор после потерянного «rejoined» — с тем же.
var rid := ""
var active := false
var attempt := 0
var started_ms := 0
var next_at_ms := 0
var attempt_ms := 0
## Удачных возвратов за матч и сколько всего были вне связи (сводка матча).
var count := 0
var away_ms := 0
## С какого своего хода досылать (-1 — досылки нет) и когда канал последний раз взял ход.
var resend_k := -1
var progress_ms := 0
## До какого времени показывать «Соперник переподключается…» (0 — соперник на связи).
var opp_away_until := 0
var _own: Dictionary = {}


## Новый матч: токен только валидный и только этого start — прежний не переживает матч.
func reset_match(rj: Variant, room: String, s: int) -> void:
	token = String(rj) if rj is String and String(rj).length() == 32 \
		and String(rj).is_valid_hex_number() else ""
	code = room
	side = s
	active = false
	attempt = 0
	count = 0
	away_ms = 0
	resend_k = -1
	opp_away_until = 0
	_own.clear()


func begin(now: int) -> void:
	active = true
	attempt = 0
	started_ms = now
	next_at_ms = now
	attempt_ms = 0
	resend_k = -1
	rid = Crypto.new().generate_random_bytes(8).hex_encode()


## Попытка не удалась (закрылась, отказ «busy», ответа нет) — следующая после паузы.
func schedule(now: int) -> void:
	next_at_ms = now + int(PAUSES[clampi(attempt - 1, 0, PAUSES.size() - 1)] * 1000.0)


func expired(now: int) -> bool:
	return now - started_ms > GIVE_UP_MS


func packet(have: int) -> Dictionary:
	return {"t": "rejoin", "code": code, "side": side, "rj": token, "have": have, "rid": rid}


## Вернулись: досылка своих ходов с next (сервер принимает строго следующий).
func finish(now: int, next: int) -> void:
	active = false
	count += 1
	away_ms += now - started_ms
	start_resend(next, now)


## Досылка своих ходов с k (после возврата или когда канал отказал в обычной отправке).
func start_resend(k: int, now: int) -> void:
	resend_k = k
	progress_ms = now


func remember(k: int, raw: String) -> void:
	_own[k] = raw
	_own.erase(k - OWN_KEEP)


func has_raw(k: int) -> bool:
	return _own.has(k)


func raw_of(k: int) -> String:
	return String(_own.get(k, ""))


func set_opp_away(ms: Variant, now: int) -> void:
	var v := int(ms) if (ms is int or ms is float) and is_finite(float(ms)) else 0
	opp_away_until = now + clampi(v, 0, OPP_AWAY_MAX_MS)


## «0:42» — сколько ещё ждать соперника по местным часам; пусто — не ждём.
func opp_away_text(now: int) -> String:
	if opp_away_until <= now:
		return ""
	var s := ceili((opp_away_until - now) / 1000.0)
	return "%d:%02d" % [s / 60, s % 60]
