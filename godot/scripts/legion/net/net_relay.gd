# gdlint: disable=max-file-lines
extends SceneTree
##
## Ретранслятор онлайн-«Схватки» (lockstep, docs/pvp/NET_LOCKSTEP.md). НЕ мир боя: общее лобби
## (кто онлайн, открытые комнаты), комната на двоих, сид и сторона, пересылка пакетов ввода и
## сверка отпечатков состояния. Бой считают оба клиента сами, одинаково, — поэтому серверу не нужен
## ни мир, ни процессор: он видит только чужой ввод и хеши.
##
## Лобби общее (Игорь 01.10: «чтобы любой с любым мог зайти поиграть»): каждый, кто подключился,
## видит открытые комнаты своей сборки и может войти в любую; код комнаты — запасной путь.
##
## Запуск (с 04.10.2026 — отдельная машина за HTTPS-прокси Caddy, который пускает только WebSocket):
##   Godot_console --headless --path godot --script res://scripts/legion/net/net_relay.gd -- \
##       [--port 18765] [--bind 127.0.0.1]
## По умолчанию слушает только loopback: снаружи до него доходит лишь туннель. `--bind 0.0.0.0`
## — для проверки по домашней сети.
##
## Пакеты — текст JSON (один объект на кадр WebSocket). Клиент → сервер:
##   {"t":"hello","v":2,"build":"…","name":"Игорь"}   войти в лобби
##   {"t":"create","map":"pvp:duel"}                  открыть комнату и ждать соперника
##   {"t":"join","code":"KXRT"}                       войти в открытую комнату → старт у обоих
##   {"t":"cancel"}                                   закрыть свою ожидающую комнату
##   {"t":"leave"}                                    выйти из матча обратно в лобби
##   {"t":"ready"}                     карта загружена — сопернику {"t":"ready"} один раз за матч
##   {"t":"in","k":<ход>,"c":[…]}      ввод своей стороны на ход k — пересылается сопернику как есть
##   {"t":"hash","k":<тик>,"h":"…"}    отпечаток состояния — сервер сверяет пары
##   {"t":"end", …}                    бой кончился — сопернику {"t":"end"} один раз за матч
##   {"t":"ping","ms":<число>}         → {"t":"pong","ms":…}
## Прямое соединение (протокол 2): в start — токен комнаты «p2p»; клиент шлёт
##   {"t":"cand","c":[{"ip","port","kind"}…],"rtt":…,"nat":…}  кандидаты — проверенными сопернику
##   {"t":"path","mode":"p2p|relay","rtt":…,"delay":…,"nat":…} → строка в лог
##   {"t":"p2p_mismatch","k":…}        ход соперника напрямую ≠ через сервер → строка в лог
##   {"t":"late"}                      ходы соперника опаздывают → сопернику (растит задержку)
## Подтяжка (docs/pvp/NET_LOCKSTEP.md, «Подтяжка»): {"t":"healed","id","ok","at"} — клиент принял
## (или нет) снимок судьи и досчитал бой до тика at.
## Сервер → клиент: welcome / lobby / room / start / ready / in / cand / late / desync / snap /
## verdict / left / error / pong.
##
## Судья (net_judge.gd): на каждый начатый матч ретранслятор запускает отдельный процесс судьи. Он
## входит пакетом {"t":"judge","v","room","key"} (ключ знает только ретранслятор), получает старт
## и ВЕСЬ ввод обеих сторон с начала матча (история комнаты — судья приходит на секунды позже
## игроков), считает бой и шлёт свои отпечатки и итог {"t":"verdict"}. Отпечаток игрока сверяется
## с судейским: desync уходит только тому, кто разошёлся. Нет судьи — сверка пары, как раньше.
##

const PROTO := 2
const MAX_PEERS := 48
const MAX_ROOMS := 24
## Штрих — до 160 точек по ~14 символов; 16 КБ — с запасом на ход с несколькими командами.
const MAX_MSG := 16384
const MAX_MSGS_PER_SEC := 240
const HELLO_TIMEOUT_MS := 10000
## Ping/heartbeat подтверждают связь, но не продлевают бессрочное ожидание в лобби.
const LOBBY_IDLE_MS := 10 * 60 * 1000
const ROOM_OP_BURST := 12
const ROOM_OP_MS := 1000
## Общее ведро не сбрасывается при leave/reconnect; иначе ограничение легко обходилось.
const JUDGE_START_BURST := 6
const JUDGE_START_MS := 10000
const LOGS_PER_SEC := 120
const PROOF_LOGS_PER_SEC := 12
## Отказ («нет комнаты», «соперник ушёл») сначала доходит до клиента, потом сокет закрывается:
## закрытие в том же кадре, что и отправка, клиент видит раньше текста — и не знает причины.
const KICK_MS := 700
const NAME_MAX := 20
## Код комнаты — без похожих букв (O/0, I/1), чтобы диктовать голосом.
const CODE_CHARS := "ABCDEFGHJKLMNPQRSTUVWXYZ"
## Судья — процесс игры целиком (сотни МБ памяти): сверх этого числа матчи идут без судьи.
const JUDGE_MAX := 6
## Пакет хода: десяток команд со штрихом по 160 точек укладывается с запасом.
const MAX_IN := 8192
## История ввода комнаты (для судьи) — предел на КАЖДУЮ сторону: обычный матч — единицы МБ;
## общий предел рвал бы того, кто его пересёк, а не того, кто нагнал объём (проверка 01.10).
const LOG_CAP := 8 * 1024 * 1024
## String движка хранит Unicode; считаем обе копии и запас на запись Array/Dictionary.
## Это бюджет удерживаемых данных, а не точное измерение RSS всего процесса/судей.
const HISTORY_SIDE_MAX := 32 * 1024 * 1024
const HISTORY_TOTAL_MAX := 256 * 1024 * 1024
const TURN_STORAGE_OVERHEAD := 256
## Судье историю отдаём порциями, не переполняя его исходящий буфер (иначе «не успевает»).
const JUDGE_BUF := 131072
## Игроку — так же (B-378): в исходящем буфере сокета не больше этого, остальное ждёт на сервере —
## ходы соперника в журнале комнаты, служебное в очереди игрока — и уходит, когда он прочтёт.
## Прежде сервер клал всё в сокет и при переполнении РВАЛ ПОЛУЧАТЕЛЯ: обманщик заливал пересылаемым
## (сырые «end»/«ready» по 16 КБ, ходы по 8 КБ), и честного с заминкой 1,5 с выбивало (verifier №5).
const PEER_BUF := 131072
## Служебного, ждущего игрока на сервере, не больше (байт). Соперник его почти не порождает
## («ready», «end», кандидаты — раз за матч, «late» — 2 в секунду), лобби сливается в последнее —
## предела достигает лишь тот, кто сам шлёт (ping) и сам не читает: его и отключаем.
const OUTQ_MAX := 262144
## Первые ходы (до нижней границы задержки ввода, NetSession.DELAY_MIN) у всех пустые: в них
## нечего применять, а непустые судья и соперник обработали бы по-разному (проверка 01.10 —
## подстава через ход 0). Задержка у каждой стороны своя (от DELAY_MIN), поэтому граница — нижняя:
## больше — ретранслятор рвал бы клиента с короткой задержкой.
const EMPTY_TURNS := 2
## Строк о пути и непроверенных жалобах в relay.log — не больше на СТОРОНУ (общий на комнату
## счётчик соперник выжигал спамом path, и настоящая жалоба честного не попадала в лог —
## verifier 01.10). Доказанный подлог имеет отдельный общий бюджет лога.
const PATH_LOGS_MAX := 40
## Жалоб, ждущих хода обвиняемого на сервере, не больше (на сторону).
const PENDING_MAX := 4
## Забег ходов меряем по ЧАСАМ, а не по сопернику: с прямым путём честный игрок законно уходит
## вперёд копии ходов соперника на сервере (её придержали или лагает WebSocket/Funnel) — прежний
## предел «не дальше 64 ходов от соперника» рвал как раз честного (verifier 01.10). Ход k стороны
## не может быть дальше, чем прошло ходов реального времени с ОБЩЕГО СТАРТА боя (оба прислали
## «ready») + потолок задержки ввода + запас AHEAD_SLACK (2 с на неровный шаг кадров) — дальше
## только спам будущими ходами. До общего старта — только стартовые ходы k < DELAY_MAX: иначе
## обманщик, придержав свой «ready», копил сотни ходов, пока честный грузит поле, и честный
## застревал на них (verifier №2 01.10). Клиент держит окно ходов соперника шире этого запаса
## (NetSession.REMOTE_WINDOW).
const TURN_MS := 50
const AHEAD_SLACK := 40
## Правила «рвать отстающего по разрыву ходов» больше нет (verifier №3 01.10: обманщик гнал ходы по
## часам, и честного с медленной машиной рвало за его же медлительность). Придержку копии ходов на
## сервер ловит клиент (NetSession.RELAY_LAG_MAX): стоит и через 30 с шлёт «void» — матч без итога.
## Сервер принимает «void», только если разрыв по ходам на сервере между сторонами не меньше этого
## (честный, упёршийся в придержку, впереди на ~RELAY_LAG_MAX = 200), иначе — как выход (сдача):
## так «void» не спасает от проигрыша, когда никто ничего не придерживал.
const VOID_MIN_GAP := 100
## «void» и «no_ready» — ЗАПРОСЫ: отклонённый не даёт ни выхода, ни сдачи (verifier №4: обманщик
## сбрасывал придержанные копии за миг до «void» честного, и тот получал сдачу). Повтор запроса от
## стороны — не чаще раза в REQUEST_MIN_MS (клиент ждёт столько же между запросами).
const REQUEST_MIN_MS := 25000
## Оба «ready» не пришли за столько с начала матча — комната закрывается без засчитывания сдачи
## (клиент ждёт «ready» соперника NetSession.READY_WAIT, сам путь решает до 8 с; здесь — запас).
const READY_TIMEOUT_MS := 60000
## Сводку матча стороны ждём и после закрытия комнаты столько (соперник ушёл — комната закрыта, а
## сводка оставшегося приходит следом); не пришла — строка «итог стороны N не пришёл».
const STATS_GRACE_MS := 15000
## Конец матча в сводке — только из этого набора (строка в relay.log — по-русски).
const STATS_END := {"win": "победа", "loss": "поражение", "draw": "ничья",
	"opp_left": "соперник ушёл", "leave": "вышел", "abort": "обрыв", "stop": "остановлен пробой",
	"forge_win": "победа (соперник подменил ход)", "forge_loss": "поражение (подмена хода)",
	"void": "прерван без итога (ходы соперника не доходили до сервера)",
	"no_ready": "отменён без итога (поле не загрузилось у обоих)"}
const STATS_NAT := ["cone", "symmetric", "one", "none", "off", "fail"]
## «late» — не чаще раза в LATE_MIN_MS на сторону: честный клиент шлёт его раз в 2 с.
const LATE_MIN_MS := 500
## Подтяжка (docs/pvp/NET_LOCKSTEP.md, «Подтяжка»): сторона разошлась с судьёй — судья шлёт ей
## снимок боя кусками. Подтяжек за матч на сторону не больше HEAL_MAX: расходится снова и снова —
## строка в relay.log, и дальше как без подтяжки (desync, итог судьи).
const HEAL_MAX := 3
## Снимок не дошёл до стороны за столько (судья не снял его — велик, или завис) — подтяжка
## считается несостоявшейся: расхождение снова пишется и может просить следующий снимок.
const HEAL_WAIT_MS := 60000
## «healed» принимается, только если тик «at» не меньше тика K снимка и не больше K + столько:
## клиент
## досчитывает бой до своего тика (он может быть впереди судьи на задержку сети), но не на минуты.
## Иначе отчёт ложный (проверка 03.10: «at»=1e9 глушил расхождения до конца матча).
const HEAL_AT_SLACK := 1200
## Поле процгена: сид до 6 цифр, сложность 1–5 (меню и сервер дают 3). Длина цепочки больше
## делает генерацию минутами — так вешали судью (проверка 01.10, gen:1:2000000000:pvp).
const GEN_RE := "^gen:[0-9]{1,6}:[1-5]:pvp$"

var _server := TCPServer.new()
## Отдельный loopback-порт: Caddy виден как 127.0.0.1, поэтому IP не доказывает роль судьи.
## На этом входе всё равно обязателен случайный ключ комнаты; публичный вход judge не принимает.
var _judge_server := TCPServer.new()
var _judge_port := 0
## id → {ws, born, hello, name, build, room, side, win_start, win_count, [kick_at, kick_why]}
var _peers: Dictionary = {}
## code → {peers: [id…], host, map, build, started, hashes: {k: {side: h}}}
var _rooms: Dictionary = {}
var _next_id := 1
var _rng := RandomNumberGenerator.new()
var _lobby_dirty := false
var _port := 18765
## --judges N — сколько судей одновременно (0 — без судей: проба сверки пары, tools/net_probe.sh)
var _judge_max := JUDGE_MAX
## --judge-snap-limit N: судье — «снимок длиннее N знаков не слать» (проба tools/net_heal.sh big);
## 0 — нет
var _judge_snap_limit := 0
## --ready-timeout МС — для проб, иначе READY_TIMEOUT_MS
var _ready_timeout := READY_TIMEOUT_MS
## «комната:сторона» → {code, side, name, deadline}: чья сводка матча ещё ожидается
var _stats_wait: Dictionary = {}
## --stats-grace МС — для проб, иначе STATS_GRACE_MS
var _stats_grace := STATS_GRACE_MS
var _lobby_idle := LOBBY_IDLE_MS
var _judge_tokens := float(JUDGE_START_BURST)
var _judge_refill_at := 0
var _log_at := 0
var _log_count := 0
var _proof_log_count := 0
var _log_suppressed := 0


func _initialize() -> void:
	var port := 18765
	var bind := "127.0.0.1"
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == "--port" and i + 1 < args.size():
			port = int(args[i + 1])
			_port = port
		elif args[i] == "--stats-grace" and i + 1 < args.size():
			_stats_grace = int(args[i + 1])
		elif args[i] == "--ready-timeout" and i + 1 < args.size():
			_ready_timeout = int(args[i + 1])
		elif args[i] == "--judges" and i + 1 < args.size():
			_judge_max = clampi(int(args[i + 1]), 0, JUDGE_MAX)
		elif args[i] == "--judge-port" and i + 1 < args.size():
			_judge_port = int(args[i + 1])
		elif args[i] == "--lobby-idle" and i + 1 < args.size():
			_lobby_idle = maxi(1, int(args[i + 1]))
		elif args[i] == "--judge-snap-limit" and i + 1 < args.size():
			_judge_snap_limit = int(args[i + 1])
		elif args[i] == "--bind" and i + 1 < args.size():
			bind = args[i + 1]
	_rng.randomize()
	_judge_refill_at = Time.get_ticks_msec()
	var err := _server.listen(port, bind)
	if err != OK:
		_log("не удалось слушать %s:%d (ошибка %d)" % [bind, port, err])
		quit(1)
		return
	if _judge_max > 0:
		if _judge_port == 0:
			_judge_port = port + 1
		var judge_err := _judge_server.listen(_judge_port, "127.0.0.1")
		if judge_err != OK:
			_log("не удалось открыть внутренний порт судьи %d (ошибка %d)" % [
				_judge_port, judge_err])
			quit(1)
			return
	_log("ретранслятор слушает %s:%d, протокол %d" % [bind, port, PROTO])


func _process(_delta: float) -> bool:
	_accept()
	_accept_from(_judge_server, true)
	for id: int in _peers.keys():
		if _peers.has(id):
			_poll_peer(id)
	_pump_judges()
	_pump_out()
	_check_ready()
	_check_stats()
	if _lobby_dirty:
		_lobby_dirty = false
		_broadcast_lobby()
	return false


func _accept() -> void:
	_accept_from(_server, false)


func _accept_from(server: TCPServer, judge_only: bool) -> void:
	while server.is_connection_available():
		var stream := server.take_connection()
		if stream == null:
			return
		var count := 0
		for p: Dictionary in _peers.values():
			count += int(bool(p.get("judge_only", false)) == judge_only)
		if count >= (_judge_max if judge_only else MAX_PEERS):
			stream.disconnect_from_host()
			continue
		var ws := WebSocketPeer.new()
		ws.inbound_buffer_size = 65536
		ws.outbound_buffer_size = 262144
		# предел числа пакетов в очереди сокета — с запасом над PEER_BUF в байтах: пустые ходы по
		# ~25 байт упирались в 256 пакетов раньше, чем в байты, и отправка молча не проходила
		ws.max_queued_packets = 8192
		# пинг WebSocket раз в 20 с: загрузка поля одним кадром под нагрузкой — до ~16 с, а при
		# 5 с такой кадр рвал соединение на загрузке (verifier №4 01.10)
		ws.heartbeat_interval = 20.0
		if ws.accept_stream(stream) != OK:
			stream.disconnect_from_host()
			continue
		var id := _next_id
		_next_id += 1
		_peers[id] = {"ws": ws, "born": Time.get_ticks_msec(), "hello": false, "name": "",
			"build": "", "room": "", "side": -1, "win_start": Time.get_ticks_msec(),
			"win_count": 0, "outq": [], "outq_bytes": 0, "lobby_next": "", "tail": [],
			"tail_bytes": 0, "tail_cost": 0, "judge_only": judge_only,
			"idle_at": Time.get_ticks_msec(), "op_at": Time.get_ticks_msec(),
			"op_tokens": float(ROOM_OP_BURST)}


func _poll_peer(id: int) -> void:
	var p: Dictionary = _peers[id]
	var ws: WebSocketPeer = p["ws"]
	ws.poll()
	if p.has("kick_at"):
		if Time.get_ticks_msec() >= int(p["kick_at"]):
			_drop(id, String(p["kick_why"]))
		return
	var state := ws.get_ready_state()
	if state == WebSocketPeer.STATE_CLOSED:
		_drop(id, "закрыл соединение")
		return
	var late := Time.get_ticks_msec() - int(p["born"]) > HELLO_TIMEOUT_MS
	if state != WebSocketPeer.STATE_OPEN:
		if late:
			_drop(id, "рукопожатие не завершено")
		return
	if not bool(p["hello"]) and late:
		_send(id, {"t": "error", "code": "hello_timeout"})
		_kick(id, "нет hello")
		return
	if _idle_expired(p, Time.get_ticks_msec()):
		_send(id, {"t": "error", "code": "idle_timeout"})
		_kick(id, "простой в лобби")
		return
	_read_packets(id, p, ws)


func _idle_expired(p: Dictionary, now: int) -> bool:
	if not bool(p["hello"]) or bool(p.get("judge_only", false)):
		return false
	var code := String(p["room"])
	if code != "" and _rooms.has(code) and bool(_rooms[code]["started"]):
		return false
	return now - int(p["idle_at"]) >= _lobby_idle


func _read_packets(id: int, p: Dictionary, ws: WebSocketPeer) -> void:
	while _peers.has(id) and not p.has("kick_at") and ws.get_available_packet_count() > 0:
		var data := ws.get_packet()
		var msg: Variant = null
		var text := ""
		if data.size() <= MAX_MSG and ws.was_string_packet():
			text = data.get_string_from_utf8()
			msg = JSON.parse_string(text)
		if not (msg is Dictionary):
			_drop(id, "пакет не JSON-объект или больше %d" % MAX_MSG)
			return
		# судья (свой процесс, вошёл по ключу) — без предела частоты: догоняя бой, он шлёт
		# отпечатки пачкой, а снимок для подтяжки — десятками кусков
		if not bool(p.get("judge", false)) and not _rate_ok(p):
			_drop(id, "слишком часто")
			return
		_handle(id, msg as Dictionary, text)


func _rate_ok(p: Dictionary) -> bool:
	var t := Time.get_ticks_msec()
	if t - int(p["win_start"]) >= 1000:
		p["win_start"] = t
		p["win_count"] = 0
	p["win_count"] = int(p["win_count"]) + 1
	return int(p["win_count"]) <= MAX_MSGS_PER_SEC


## Leave всегда разрешён: ограничение не должно запирать человека в матче.
func _room_op_ok(id: int) -> bool:
	var p: Dictionary = _peers[id]
	var now := Time.get_ticks_msec()
	p["op_tokens"] = minf(ROOM_OP_BURST, float(p["op_tokens"])
		+ float(now - int(p["op_at"])) / ROOM_OP_MS)
	p["op_at"] = now
	if float(p["op_tokens"]) < 1.0:
		_send(id, {"t": "error", "code": "rate_limit"})
		return false
	p["op_tokens"] = float(p["op_tokens"]) - 1.0
	return true


func _take_judge_token(now: int) -> bool:
	_judge_tokens = minf(JUDGE_START_BURST, _judge_tokens
		+ float(maxi(0, now - _judge_refill_at)) / JUDGE_START_MS)
	_judge_refill_at = now
	if _judge_tokens < 1.0:
		return false
	_judge_tokens -= 1.0
	return true


func _handle(id: int, msg: Dictionary, raw: String) -> void:
	var t := _s(msg.get("t"), 16)
	if bool(_peers[id].get("judge_only", false)) and not bool(_peers[id].get("judge", false)):
		if t == "judge":
			_judge_hello(id, msg)
		else:
			_drop(id, "внутренний вход — только для судьи")
		return
	if t == "ping":
		_send(id, {"t": "pong", "ms": msg.get("ms", 0)})
		return
	if t == "hello":
		_hello(id, msg)
		return
	if t == "judge":
		_drop(id, "судья на публичном входе")
		return
	if bool(_peers[id].get("judge", false)):
		_judge_msg(id, t, raw)
		return
	if not bool(_peers[id]["hello"]):
		_drop(id, "пакет до hello")
		return
	match t:
		"create":
			if _room_op_ok(id):
				_create_room(id, _s(msg.get("map"), 32))
		"join":
			if _room_op_ok(id):
				_join_room(id, _s(msg.get("code"), 8).strip_edges().to_upper())
		"cancel", "leave":
			_leave_room(id)
		"in":
			_in(id, msg, raw)
		"ready":
			_on_ready(id)
		"end":
			_on_end(id)
		"hash":
			_hash(id, msg)
		"cand":
			_cand(id, msg)
		"late":
			var o := _other(id)
			var now := Time.get_ticks_msec()
			if o > 0 and _in_match(id) and now - int(_peers[id].get("late_at", -LATE_MIN_MS)) \
					>= LATE_MIN_MS:
				_peers[id]["late_at"] = now
				_send(o, {"t": "late"})
		"path":
			_path(id, msg)
		"p2p_mismatch":
			_mismatch(id, msg)
		"stats":
			_stats(id, msg)
		"void":
			_void(id)
		"no_ready":
			_no_ready(id)
		"healed":
			_healed(id, msg)


func _hello(id: int, msg: Dictionary) -> void:
	var p: Dictionary = _peers[id]
	if bool(p["hello"]):
		return
	if _i(msg.get("v"), 0) != PROTO:
		_send(id, {"t": "error", "code": "proto", "need": PROTO})
		_kick(id, "другая версия протокола")
		return
	p["hello"] = true
	p["build"] = _clean_build(_s(msg.get("build"), 64))
	p["idle_at"] = Time.get_ticks_msec()
	p["name"] = _clean_name(_s(msg.get("name"), 64), id)
	_send(id, {"t": "welcome", "id": id, "name": p["name"]})
	_log("игрок %d «%s» вошёл (сборка %s)" % [id, p["name"], p["build"]])
	_lobby_dirty = true


func _create_room(id: int, map_id: String) -> void:
	var p: Dictionary = _peers[id]
	if String(p["room"]) != "":
		return
	if _rooms.size() >= MAX_ROOMS:
		_send(id, {"t": "error", "code": "full"})
		return
	if not _map_ok(map_id):
		map_id = "pvp:duel"
	var code := _new_code()
	_rooms[code] = {"peers": [id], "host": p["name"], "map": map_id, "build": p["build"],
		"started": false, "hashes": {}, "seed": 0, "judge": 0, "judge_pid": -1, "key": "",
		"history_cost": [0, 0],
		"log": [], "log_bytes": [0, 0], "cursor": 0, "next_k": [0, 0], "raws": [{}, {}],
		"keys": [PackedByteArray(), PackedByteArray()], "logs": [0, 0], "pending": [],
		"start_ms": 0, "ready": [false, false], "go_ms": 0, "out_k": [0, 0],
		"ended": [false, false], "cand": [false, false],
		# подтяжка: сколько снимков запрошено, номер текущего, снимок в пути (ждём «healed»), до
		# какого тика отпечатки стороны устарели (сняты до подтяжки), куски к отправке
		"heal": [0, 0], "heal_id": [0, 0], "heal_busy": [false, false], "heal_upto": [-1, -1],
		"heal_over": [false, false], "heal_at": [0, 0], "snap": [{}, {}],
		# тик K снимка текущей подтяжки (из заголовка снимка судьи), отдан ли снимок стороне целиком,
		# тик расхождения, с которого подтяжку запросили
		"heal_k": [-1, -1], "heal_sent": [false, false], "heal_dk": [0, 0]}
	p["room"] = code
	p["side"] = 0
	p["idle_at"] = Time.get_ticks_msec()
	_send(id, {"t": "room", "code": code, "side": 0, "map": map_id})
	_log("комната %s открыта игроком «%s» (карта %s)" % [code, p["name"], map_id])
	_lobby_dirty = true


func _join_room(id: int, code: String) -> void:
	var p: Dictionary = _peers[id]
	if String(p["room"]) != "":
		return
	if not _rooms.has(code):
		_send(id, {"t": "error", "code": "no_room"})
		return
	var room: Dictionary = _rooms[code]
	if bool(room["started"]) or (room["peers"] as Array).size() >= 2:
		_send(id, {"t": "error", "code": "busy"})
		return
	if String(room["build"]) != String(p["build"]):
		_send(id, {"t": "error", "code": "build", "need": room["build"]})
		return
	if _judge_max > 0 and not _take_judge_token(Time.get_ticks_msec()):
		_send(id, {"t": "error", "code": "rate_limit"})
		return
	(room["peers"] as Array).append(id)
	room["started"] = true
	p["room"] = code
	p["side"] = 1
	var seed_value := _rng.randi_range(1, 999999)
	var map_id: String = room["map"]
	if map_id.begins_with("gen:") and map_id.count(":") < 3:
		# «Случайное поле» без сида: сид выбирает сервер, чтобы у обоих была одна карта
		map_id = "gen:%d:3:pvp" % _rng.randi_range(1, 99999)
	room["map"] = map_id
	room["seed"] = seed_value
	# токен прямого пути: каждый UDP-пакет его несёт, без него пакет отбрасывается молча —
	# знают его только двое игроков этой комнаты (судье не нужен: он ходит через ретранслятор)
	# токен и ключи — из криптографического генератора: соседние байты одного PCG32 предсказуемы
	# (verifier №2 01.10)
	var crypto := Crypto.new()
	var p2p := crypto.generate_random_bytes(16).hex_encode()
	room["start_ms"] = Time.get_ticks_msec()
	var names := [String(_peers[(room["peers"] as Array)[0]]["name"]), String(p["name"])]
	for pid: int in room["peers"]:
		var s := int(_peers[pid]["side"])
		# секретный ключ стороны — только ей: HMAC её ходов в UDP, по нему подлог доказуем
		var key := crypto.generate_random_bytes(16)
		(room["keys"] as Array)[s] = key
		var sk := "%s:%d" % [code, s]
		_peers[pid]["stats_key"] = sk
		_stats_wait[sk] = {"code": code, "side": s, "name": names[s], "deadline": 0}
		_send(pid, {"t": "start", "seed": seed_value, "map": map_id, "side": s,
			"code": code, "opponent": names[1 - s], "p2p": p2p, "key": key.hex_encode()})
	_log("комната %s: «%s» против «%s», сид %d, карта %s" % [code, names[0], names[1],
		seed_value, map_id])
	_spawn_judge(code)
	_lobby_dirty = true


## Выход из комнаты без разрыва соединения: хозяин закрыл ожидание, или матч кончился/брошен.
func _leave_room(id: int) -> void:
	var code := String(_peers[id]["room"])
	if code == "":
		return
	_close_room(code, id)
	_lobby_dirty = true


func _close_room(code: String, leaver: int) -> void:
	if not _rooms.has(code):
		return
	var room: Dictionary = _rooms[code]
	# Комната уже закрывается: бюджет истории уступает место хвостам получателей.
	_rooms.erase(code)
	for s in 2:
		var sk := "%s:%d" % [code, s]
		if _stats_wait.has(sk) and int(_stats_wait[sk]["deadline"]) == 0:
			_stats_wait[sk]["deadline"] = Time.get_ticks_msec() + _stats_grace
	var peers: Array = room["peers"]
	for i in peers.size():
		var pid: int = peers[i]
		if not _peers.has(pid):
			continue
		_peers[pid]["room"] = ""
		_peers[pid]["side"] = -1
		_peers[pid]["idle_at"] = Time.get_ticks_msec()
		if pid != leaver:
			# ходы соперника, ещё не дошедшие до игрока, — раньше «left», как и было, пока всё шло
			# прямо в сокет: отстающий честный досчитывает ход, на котором соперник закончил бой
			_tail_turns(room, i, pid)
			_send(pid, {"t": "left"})
	_stop_judge(room)
	_log("комната %s закрыта" % code)


func _hash(id: int, msg: Dictionary) -> void:
	var p: Dictionary = _peers[id]
	var code := String(p["room"])
	if code == "" or not _rooms.has(code):
		return
	var room: Dictionary = _rooms[code]
	var hashes: Dictionary = room["hashes"]
	var k := _i(msg.get("k"), -1)
	var h := _s(msg.get("h"), 80)
	if k < 0:
		return
	if not hashes.has(k):
		hashes[k] = {}
	var who: Variant = "j" if bool(p.get("judge", false)) else int(p["side"])
	(hashes[k] as Dictionary)[who] = h
	_check_hashes(code, room, k)
	# старые неполные отпечатки (кто-то отстал или ушёл) — не копить без конца
	if hashes.size() > 96:
		var keys := hashes.keys()
		keys.sort()
		for i in keys.size() - 48:
			hashes.erase(keys[i])


func _check_hashes(code: String, room: Dictionary, k: int) -> void:
	var hashes: Dictionary = room["hashes"]
	var got: Dictionary = hashes[k]
	if _judge_alive(room) or _judge_expected(room):
		if not got.has("j"):
			return
		for s in 2:
			if got.has(s) and not got.has("ok%d" % s):
				got["ok%d" % s] = true
				if String(got[s]) != String(got["j"]):
					_judge_mismatch(code, room, s, k)
		if got.has("ok0") and got.has("ok1"):
			hashes.erase(k)
		return
	if got.has(0) and got.has(1):
		if String(got[0]) != String(got[1]):
			_log("комната %s: РАССИНХРОН на тике %d (без судьи)" % [code, k])
			for pid: int in room["peers"]:
				_send(pid, {"t": "desync", "k": k})
		hashes.erase(k)


## Отпечаток стороны s на тике k не совпал с судейским. Снимок уже в пути или отпечаток снят до
## подтяжки (k не дальше тика, до которого клиент досчитал снимок) — устаревший, молча мимо. Иначе —
## строка в relay.log и, пока подтяжки не кончились (HEAL_MAX), судья снимает снимок для s; desync
## с «heal» — клиент не пишет игроку «разошёлся». Закончившему матч снимок не шлём (B-377): его бой
## решён, а снимок перезапустил бы мир и показал второй экран итога.
func _judge_mismatch(code: String, room: Dictionary, s: int, k: int) -> void:
	var busy: Array = room["heal_busy"]
	if bool(busy[s]) and Time.get_ticks_msec() - int((room["heal_at"] as Array)[s]) > HEAL_WAIT_MS:
		_log("комната %s: снимок для стороны %d не дошёл за %d с" % [code, s, HEAL_WAIT_MS / 1000])
		busy[s] = false
		(room["snap"] as Array)[s] = {}
	if bool(busy[s]) or k <= int((room["heal_upto"] as Array)[s]):
		return
	_log("комната %s: сторона %d разошлась с судьёй на тике %d" % [code, s, k])
	var pid: int = (room["peers"] as Array)[s]
	var heals: Array = room["heal"]
	if _judge_alive(room) and not bool((room["ended"] as Array)[s]) and int(heals[s]) < HEAL_MAX:
		heals[s] = int(heals[s]) + 1
		busy[s] = true
		(room["heal_at"] as Array)[s] = Time.get_ticks_msec()
		var ids: Array = room["heal_id"]
		ids[s] = int(ids[s]) + 1
		(room["heal_k"] as Array)[s] = -1
		(room["heal_sent"] as Array)[s] = false
		(room["heal_dk"] as Array)[s] = k
		_log("комната %s: судья снимает снимок для стороны %d (подтяжка %d из %d)" % [code, s,
			int(heals[s]), HEAL_MAX])
		_send(pid, {"t": "desync", "k": k, "judge": true, "heal": true})
		_send(int(room["judge"]), {"t": "heal", "s": s, "id": int(ids[s])})
		return
	if int(heals[s]) >= HEAL_MAX and not bool((room["heal_over"] as Array)[s]):
		(room["heal_over"] as Array)[s] = true
		_log("комната %s: сторона %d расходится с судьёй снова — подтяжек больше нет (%d за матч)"
			% [code, s, HEAL_MAX])
	_send(pid, {"t": "desync", "k": k, "judge": true})


## Кусок снимка от судьи для стороны s: по порядку, только для запрошенной подтяжки, в пределах
## NetSession.SNAP_PART/SNAP_PARTS_MAX. Сторона получает куски из своей очереди (_pump_snap), не
## через служебную очередь игрока: снимок в сотни КБ не должен выбивать честного «не успевает
## принимать» (B-378).
func _judge_snap(code: String, room: Dictionary, msg: Dictionary) -> void:
	var s := _i(msg.get("s"), -1)
	if not s in [0, 1] or not bool((room["heal_busy"] as Array)[s]) \
			or bool((room["ended"] as Array)[s]):
		return
	var id := _i(msg.get("id"), -1)
	var i := _i(msg.get("i"), -1)
	var n := _i(msg.get("n"), -1)
	var d := _s(msg.get("d"), NetSession.SNAP_PART + 1)
	if id != int((room["heal_id"] as Array)[s]) or n < 1 or n > NetSession.SNAP_PARTS_MAX \
			or d == "" or d.length() > NetSession.SNAP_PART:
		return
	var snaps: Array = room["snap"]
	var e: Dictionary = snaps[s]
	if i == 0:
		e = {"id": id, "k": _i(msg.get("k"), -1), "n": n, "parts": [], "out": 0}
		snaps[s] = e
		(room["heal_k"] as Array)[s] = int(e["k"])
	if e.is_empty() or int(e["id"]) != id or int(e["n"]) != n or i != (e["parts"] as Array).size():
		return
	(e["parts"] as Array).append(d)
	if i == n - 1:
		_log("комната %s: снимок для стороны %d снят судьёй на тике %d (%d кусков, %d КБ)" % [code, s,
			int(e["k"]), n, ((n - 1) * NetSession.SNAP_PART + d.length()) / 1024])


## Куски снимков — сторонам, не переполняя их сокет; за ходами соперника и служебным (как ходы).
func _pump_snap(room: Dictionary) -> void:
	var peers: Array = room["peers"]
	var snaps: Array = room["snap"]
	for s in mini(2, peers.size()):
		var e: Dictionary = snaps[s]
		if e.is_empty() or not _peers.has(int(peers[s])):
			continue
		var p: Dictionary = _peers[int(peers[s])]
		if not (p["outq"] as Array).is_empty() or not (p["tail"] as Array).is_empty():
			continue
		var parts: Array = e["parts"]
		while int(e["out"]) < parts.size():
			var i := int(e["out"])
			var text := JSON.stringify({"t": "snap", "id": e["id"], "k": e["k"], "i": i,
				"n": e["n"], "d": parts[i]})
			if not _try_send(p["ws"], text):
				break
			e["out"] = i + 1
		if int(e["out"]) >= int(e["n"]):
			snaps[s] = {}   # отправлен целиком — память комнаты свободна
			(room["heal_sent"] as Array)[s] = true


## Клиент подтянулся снимком (или отказался): отпечатки до тика «at» сняты до подтяжки — их
## расхождение с судьёй больше не повод для снимка.
func _healed(id: int, msg: Dictionary) -> void:
	if not _in_match(id):
		return
	var code := String(_peers[id]["room"])
	var room: Dictionary = _rooms[code]
	var s := int(_peers[id]["side"])
	var busy: Array = room["heal_busy"]
	if not bool(busy[s]) or _i(msg.get("id"), -1) != int((room["heal_id"] as Array)[s]):
		return
	var at := clampi(_i(msg.get("at"), -1), -1, 1000000000)
	var k := int((room["heal_k"] as Array)[s])
	var ok: bool = msg.get("ok") == true
	# «healed» — только для подтяжки, снимок которой мы ЦЕЛИКОМ отдали этой стороне, и с тиком «at» в
	# пределах [K, K + HEAL_AT_SLACK] (отказ клиента — «at» где угодно ниже верхней границы): номер
	# подтяжки предсказуем, а «at» клиент задаёт любым — без этой сверки ложный отчёт глушил
	# расхождения
	var upper := k + HEAL_AT_SLACK
	if k < 0 or not bool((room["heal_sent"] as Array)[s]) or at > upper or (ok and at < k):
		_log("комната %s: ложный healed от стороны %d (подтяжка %d, at %d, снимок тика %d, %s) — "
			% [code, s, int((room["heal_id"] as Array)[s]), at, k,
			"отдан целиком" if bool((room["heal_sent"] as Array)[s]) else "не отдан"]
			+ "подтяжка не засчитана")
		# снимок ещё не отдан целиком — настоящий «healed» впереди, ждём его; отдан — отчёт лжёт,
		# подтяжка не состоялась: расхождения с тиком > K пишутся снова
		if k >= 0 and bool((room["heal_sent"] as Array)[s]):
			busy[s] = false
			(room["heal_upto"] as Array)[s] = maxi(int((room["heal_upto"] as Array)[s]), k)
		return
	busy[s] = false
	(room["heal_upto"] as Array)[s] = at
	(room["snap"] as Array)[s] = {}
	if ok:
		_log("комната %s: сторона %d подтянута снимком судьи, бой досчитан до тика %d" % [code, s, at])
	else:
		_log("комната %s: сторона %d не приняла снимок судьи (тик %d)" % [code, s, at])


## Судья не смог снять снимок (велик — больше SNAP_PARTS_MAX кусков): подтяжка не состоялась
## сразу, а
## не через HEAL_WAIT_MS. Дальше — как без подтяжек: снимок такого же размера не получится и в
## следующий раз, поэтому лимит подтяжек стороны выбран; игроку — обычная надпись о расхождении.
func _judge_heal_fail(code: String, room: Dictionary, msg: Dictionary) -> void:
	var s := _i(msg.get("s"), -1)
	if not s in [0, 1] or not bool((room["heal_busy"] as Array)[s]) \
			or _i(msg.get("id"), -1) != int((room["heal_id"] as Array)[s]):
		return
	(room["heal_busy"] as Array)[s] = false
	(room["snap"] as Array)[s] = {}
	(room["heal"] as Array)[s] = HEAL_MAX
	(room["heal_over"] as Array)[s] = true
	_log("комната %s: судья не снял снимок для стороны %d (%s) — подтяжки нет, сторона разошлась" % [
		code, s, _s(msg.get("why"), 80)])
	var pid: int = (room["peers"] as Array)[s]
	_send(pid, {"t": "desync", "k": int((room["heal_dk"] as Array)[s]), "judge": true})


# ── Прямое соединение (знакомство, docs/pvp/NET_LOCKSTEP.md) ───────────────────

func _in_match(id: int) -> bool:
	var code := String(_peers[id]["room"])
	return code != "" and _rooms.has(code) and bool((_rooms[code] as Dictionary)["started"])


## Кандидаты адресов игрока — только его сопернику по комнате, после проверки (≤ 8, настоящий
## IP, порт 1..65535). Пересобираем пакет сами: дальше уходят лишь проверенные поля.
func _cand(id: int, msg: Dictionary) -> void:
	var other := _other(id)
	if other <= 0 or not _in_match(id):
		return
	# клиент шлёт кандидатов раз за матч; повторы — только залив сопернику (B-378)
	var once: Array = (_rooms[String(_peers[id]["room"])] as Dictionary)["cand"]
	if bool(once[int(_peers[id]["side"])]):
		return
	once[int(_peers[id]["side"])] = true
	var c: Variant = NetP2P.clean_cands(msg.get("c"))
	if c == null:
		_log("комната %s: кривые кандидаты от «%s» — не пересланы" % [_peers[id]["room"],
			_peers[id]["name"]])
		c = []
	_send(other, {"t": "cand", "c": c, "rtt": clampi(_i(msg.get("rtt"), -1), -1, 60000),
		"nat": _word(msg.get("nat"))})


## Каким путём игрок получает ходы соперника — строкой в relay.log (владелец смотрит её вживую).
func _path(id: int, msg: Dictionary) -> void:
	if not _in_match(id) or not _path_log_ok(id):
		return
	var p: Dictionary = _peers[id]
	var mode := "напрямую" if _s(msg.get("mode"), 8) == "p2p" else "через сервер"
	_log("комната %s: сторона %d «%s» %s, %d мс в одну сторону, задержка %d ход(а), NAT %s" % [
		p["room"], int(p["side"]), p["name"], mode, clampi(_i(msg.get("rtt"), -1), -1, 99999),
		clampi(_i(msg.get("delay"), -1), -1, 99), _word(msg.get("nat"))])


## Жалоба: ход k соперника, пришедший напрямую (raw + его HMAC), не совпал с тем, что пришло через
## сервер. Проверяем ключом обвиняемого: HMAC верный и строка отличается от присланной им серверу
## за ход k — подлог ДОКАЗАН (подделать HMAC без его ключа нельзя). Иначе — непроверенная жалоба,
## без последствий. Хода k на сервере ещё нет — жалоба ждёт его.
func _mismatch(id: int, msg: Dictionary) -> void:
	if not _in_match(id):
		return
	var code := String(_peers[id]["room"])
	var room: Dictionary = _rooms[code]
	var side := int(_peers[id]["side"])
	var c := {"from": side, "k": _i(msg.get("k"), -1), "raw": _s(msg.get("raw"), MAX_IN),
		"mac": _s(msg.get("mac"), 64)}
	# строка жалобы — ход именно с этим номером: иначе обманщик предъявлял настоящий ход честного
	# с другим номером (его HMAC верен, а строка «не совпадает» с ходом k) — verifier №2 01.10
	if int(c["k"]) < 0 or not _turn_raw_is(String(c["raw"]), int(c["k"])):
		if int(c["k"]) >= 0 and _side_log_ok(room, side):
			_log("комната %s: непроверенная жалоба стороны %d на ход %d — строка не этого хода" % [
				code, side, int(c["k"])])
		return
	if int(c["k"]) >= int((room["next_k"] as Array)[1 - side]):
		var mine := 0
		for q: Dictionary in room["pending"]:
			mine += int(int(q["from"]) == side)
		if mine < PENDING_MAX:
			(room["pending"] as Array).append(c)
		return
	_judge_complaint(code, room, c)


# ── Сводка матча (docs/pvp/NET_LOCKSTEP.md, «Сводка матча») ───────────────────

## Одна сводка на сторону за матч: всё проверено и обрезано, строкой в relay.log (свой лимит —
## одна строка на сторону, другие лимиты её не глушат). Повтор и чужое — молча мимо.
func _stats(id: int, msg: Dictionary) -> void:
	var sk := String(_peers[id].get("stats_key", ""))
	if not _stats_wait.has(sk):
		return
	var w: Dictionary = _stats_wait[sk]
	_stats_wait.erase(sk)
	_peers[id]["stats_key"] = ""
	var udp := clampi(_i(msg.get("udp"), 0), 0, 10000000)
	var rel := clampi(_i(msg.get("relay"), 0), 0, 10000000)
	var parts: Array[String] = []
	parts.append("напрямую %d %% ходов" % (100 * udp / (udp + rel) if udp + rel > 0 else 0))
	var mode := _s(msg.get("mode"), 8)
	parts.append("в конце " + ("напрямую" if mode == "p2p" else "через сервер"))
	var fb := clampi(_i(msg.get("fb_tick"), -1), -1, 100000000)
	if fb >= 0:
		parts.append("переход на сервер на тике %d" % fb)
	parts.append("простой %s с (макс %s, %d раз)" % [_dec(_f(msg.get("stall_s"), 0.0, 1.0e5)),
		_dec(_f(msg.get("stall_max"), 0.0, 1.0e5)), clampi(_i(msg.get("stall_n"), 0), 0, 1000000)])
	parts.append("задержка %d→%d" % [clampi(_i(msg.get("d0"), -1), -1, 64),
		clampi(_i(msg.get("d1"), -1), -1, 64)])
	parts.append("пинг напрямую %s, до сервера %s" % [_ms_pair(msg.get("p2p50"), msg.get("p2p90")),
		_ms_pair(msg.get("rel50"), msg.get("rel90"))])
	var nat := _s(msg.get("nat"), 16)
	parts.append("NAT " + (nat if nat in STATS_NAT else "?"))
	var ds := clampi(_i(msg.get("desync"), -1), -1, 100000000)
	parts.append("расхождение " + ("нет" if ds < 0 else "на тике %d" % ds))
	var heals := clampi(_i(msg.get("heal"), 0), 0, HEAL_MAX)
	if heals > 0:
		parts.append("подтяжек снимком %d" % heals)
	var wall := int(_f(msg.get("wall"), 0.0, 1.0e6))
	parts.append("%d:%02d (%d тиков)" % [wall / 60, wall % 60,
		clampi(_i(msg.get("ticks"), 0), 0, 1000000000)])
	parts.append("конец (со слов стороны): " + String(STATS_END.get(_s(msg.get("end"), 16), "?")))
	_log("комната %s: итог стороны %d «%s»: %s" % [w["code"], int(w["side"]), w["name"],
		", ".join(parts)])


## Сводки, не пришедшие за STATS_GRACE_MS после закрытия комнаты, — строкой «не пришёл».
func _check_stats() -> void:
	var now := Time.get_ticks_msec()
	for sk: String in _stats_wait.keys():
		var w: Dictionary = _stats_wait[sk]
		if int(w["deadline"]) > 0 and now >= int(w["deadline"]):
			_stats_wait.erase(sk)
			_log("комната %s: итог стороны %d «%s» не пришёл" % [w["code"], int(w["side"]),
				w["name"]])


func _ms_pair(a: Variant, b: Variant) -> String:
	var x := clampi(_i(a, -1), -1, 60000)
	var y := clampi(_i(b, -1), -1, 60000)
	return "—" if x < 0 else "%d/%d мс" % [x, y]


## Дробное из пакета: только конечное число в [lo, hi]; иначе lo.
func _f(v: Variant, lo: float, hi: float) -> float:
	if (v is float or v is int) and is_finite(float(v)):
		return clampf(float(v), lo, hi)
	return lo


func _dec(x: float) -> String:
	return ("%.1f" % x).replace(".", ",")


## Строка — ход вида {"t":"in","k":k,"c":[…]} ровно с номером k и без лишних полей.
func _turn_raw_is(raw: String, k: int) -> bool:
	var j := JSON.new()
	if raw == "" or j.parse(raw) != OK or not (j.data is Dictionary):
		return false
	var d: Dictionary = j.data
	return d.size() == 3 and d.get("t") == "in" and d.get("c") is Array \
		and _i(d.get("k"), -1) == k


## Оба прислали «ready» — общий старт боя: от него идут часы забега и правило разрыва.
## Сопернику — пересобранный {"t":"ready"} и только первый: сырую строку (до 16 КБ) и повторы
## обманщик слал заливом, чтобы переполнить очередь к честному (B-378).
func _on_ready(id: int) -> void:
	var code := String(_peers[id]["room"])
	var side := int(_peers[id]["side"])
	if code == "" or not _rooms.has(code) or side < 0:
		return
	var room: Dictionary = _rooms[code]
	if bool(room["ready"][side]):
		return
	(room["ready"] as Array)[side] = true
	var other := _other(id)
	if other > 0:
		_send(other, {"t": "ready"})
	if int(room["go_ms"]) == 0 and bool(room["ready"][0]) and bool(room["ready"][1]):
		room["go_ms"] = Time.get_ticks_msec()


## Бой у стороны кончился — сопернику {"t":"end"} один раз за матч (тот же залив, что с «ready»).
func _on_end(id: int) -> void:
	var code := String(_peers[id]["room"])
	var side := int(_peers[id]["side"])
	if code == "" or not _rooms.has(code) or side < 0:
		return
	var ended: Array = (_rooms[code] as Dictionary)["ended"]
	if bool(ended[side]):
		return
	ended[side] = true
	# закончившему снимок не нужен (B-377)
	((_rooms[code] as Dictionary)["snap"] as Array)[side] = {}
	var other := _other(id)
	if other > 0:
		_send(other, {"t": "end"})


## Матч, где за READY_TIMEOUT_MS кто-то так и не загрузил поле, закрывается без сдачи.
func _check_ready() -> void:
	var now := Time.get_ticks_msec()
	for code: String in _rooms.keys():
		var room: Dictionary = _rooms[code]
		if not bool(room["started"]) or int(room["go_ms"]) > 0 \
				or now - int(room["start_ms"]) < _ready_timeout:
			continue
		_log("комната %s: поле не загружено у обоих за %d с — закрыта без итога" % [code,
			_ready_timeout / 1000])
		for pid: int in room["peers"]:
			_send(pid, {"t": "error", "code": "no_ready"})
		_close_room(code, 0)
		_lobby_dirty = true


## Разобрать жалобу, когда ход обвиняемого на сервере уже есть.
func _judge_complaint(code: String, room: Dictionary, c: Dictionary) -> void:
	var accuser := int(c["from"])
	var cheat := 1 - accuser
	var k := int(c["k"])
	var srv: Variant = (room["raws"] as Array)[cheat].get(k)
	var key: PackedByteArray = (room["keys"] as Array)[cheat]
	var raw := String(c["raw"])
	var proven := srv is String and raw != String(srv) and String(c["mac"]) != "" \
		and NetP2P.mac(key, raw) == String(c["mac"])
	var peers: Array = room["peers"]
	var names := []
	for pid: int in peers:
		names.append(String(_peers[pid]["name"]) if _peers.has(pid) else "?")
	if not proven:
		if _side_log_ok(room, accuser):
			_log("комната %s: непроверенная жалоба стороны %d «%s» на ход %d — без последствий" % [
				code, accuser, names[accuser], k])
		return
	_log("комната %s: ПОДМЕНА ХОДА ДОКАЗАНА — сторона %d «%s», ход %d: напрямую одно, серверу " \
		% [code, cheat, names[cheat], k] + "другое; техническое поражение, победа «%s»"
		% names[accuser], true)
	for pid: int in peers:
		_send(pid, {"t": "verdict", "why": "forge", "winner": accuser, "cheat": cheat, "k": k})
	# матч закрыт как при сдаче подменщика: честному — «left», судья останавливается
	_close_room(code, int(peers[cheat]))
	_lobby_dirty = true


## Строк о пути и жалобах в relay.log — на сторону, а не на комнату.
func _path_log_ok(id: int) -> bool:
	return _side_log_ok(_rooms[String(_peers[id]["room"])], int(_peers[id]["side"]))


func _side_log_ok(room: Dictionary, side: int) -> bool:
	var logs: Array = room["logs"]
	logs[side] = int(logs[side]) + 1
	return int(logs[side]) <= PATH_LOGS_MAX


## Короткое слово из пакета (тип NAT): только латиница и цифры, до 16 символов.
func _word(v: Variant) -> String:
	var out := ""
	for ch in _s(v, 16):
		if (ch >= "a" and ch <= "z") or (ch >= "0" and ch <= "9"):
			out += ch
	return out if out != "" else "?"


# ── Судья ───────────────────────────────────────────────────────────────────

func _judge_alive(room: Dictionary) -> bool:
	return int(room["judge"]) > 0 and _peers.has(int(room["judge"]))


## Судья запущен и ещё не умер: пока он идёт, отпечатки ждут его, а не сверяются парой — иначе
## мусорный отпечаток до прихода судьи срывал начало матча desync'ом обоим.
func _judge_expected(room: Dictionary) -> bool:
	return int(room["judge_pid"]) > 0 and not bool(room.get("judge_dead", false))


func _spawn_judge(code: String) -> void:
	var active := 0
	for rc: String in _rooms:
		active += int(int((_rooms[rc] as Dictionary)["judge_pid"]) > 0)
	if active >= _judge_max:
		_log("комната %s: без судьи (занято %d)" % [code, active])
		return
	var room: Dictionary = _rooms[code]
	var key := Crypto.new().generate_random_bytes(16).hex_encode()
	room["key"] = key
	var args := ["--headless", "--path", ProjectSettings.globalize_path("res://"), "--fixed-fps",
		"60", "--script", "res://scripts/legion/net/net_judge.gd", "--", "--mute", "--url",
		"ws://127.0.0.1:%d" % _judge_port, "--room", code, "--key", key]
	if _judge_snap_limit > 0:
		args.append_array(["--snap-limit", str(_judge_snap_limit)])
	var pid := OS.create_process(OS.get_executable_path(), args, false)
	room["judge_pid"] = pid
	_log("комната %s: судья запущен (PID %d)" % [code, pid])


func _stop_judge(room: Dictionary) -> void:
	var jid := int(room["judge"])
	if jid > 0 and _peers.has(jid):
		_peers[jid]["room"] = ""
		_kick(jid, "матч закрыт")
	var pid := int(room["judge_pid"])
	if pid > 0:
		OS.kill(pid)
		room["judge_pid"] = -1


func _judge_hello(id: int, msg: Dictionary) -> void:
	if not bool(_peers[id].get("judge_only", false)):
		_drop(id, "судья на публичном входе")
		return
	var code := _s(msg.get("room"), 8)
	if not _rooms.has(code):
		_kick(id, "судья: нет комнаты")
		return
	var room: Dictionary = _rooms[code]
	if String(room["key"]) == "" or _s(msg.get("key"), 64) != String(room["key"]) \
			or int(room["judge"]) > 0 or _i(msg.get("v"), 0) != PROTO:
		_kick(id, "судья: чужой ключ")
		return
	var p: Dictionary = _peers[id]
	p["hello"] = true
	p["judge"] = true
	p["room"] = code
	room["judge"] = id
	_send(id, {"t": "start", "seed": room["seed"], "map": room["map"], "side": -1})
	room["cursor"] = 0
	_log("комната %s: судья на месте, история %d ходов" % [code, (room["log"] as Array).size()])


## Ход игрока: номер хода строго следующий для его стороны (повтор хода с другими командами —
## способ подставить честного соперника под судью, проверка 01.10), размер и история ограничены.
func _in(id: int, msg: Dictionary, raw: String) -> void:
	var p: Dictionary = _peers[id]
	var code := String(p["room"])
	if code == "" or not _rooms.has(code) or not bool((_rooms[code] as Dictionary)["started"]):
		return
	var room: Dictionary = _rooms[code]
	var side := int(p["side"])
	var k: Variant = msg.get("k")
	var c: Variant = msg.get("c")
	if raw.length() > MAX_IN or not (k is float or k is int) or not (c is Array) or side < 0:
		_drop(id, "кривой пакет хода")
		return
	var next: Array = room["next_k"]
	if int(k) != int(next[side]):
		_drop(id, "ход %d вне очереди (ждали %d)" % [int(k), int(next[side])])
		return
	if int(k) < EMPTY_TURNS and not (c as Array).is_empty():
		_drop(id, "команды в ходе %d до начала боя" % int(k))
		return
	var go := int(room["go_ms"])
	var clock := (Time.get_ticks_msec() - go) / TURN_MS if go > 0 else -1
	if int(k) > (clock + NetSession.DELAY_MAX + AHEAD_SLACK if go > 0 else NetSession.DELAY_MAX - 1):
		_drop(id, "ход %d раньше времени (по часам боя — %d)" % [int(k), clock])
		return
	# судье — РОВНО тот текст, что получил соперник: пересборка JSON печатает дробные числа с
	# потерей точности, и подобранное число (1.999…) судья прочёл бы иначе, чем игроки — так
	# подставляли честного игрока (проверка 01.10)
	var line := JSON.stringify({"t": "in", "s": side, "raw": raw})
	var sizes: Array = room["log_bytes"]
	var costs: Array = room["history_cost"]
	var cost := _text_cost(line) + _text_cost(raw) + TURN_STORAGE_OVERHEAD
	if int(sizes[side]) + line.length() > LOG_CAP \
			or int(costs[side]) + cost > HISTORY_SIDE_MAX:
		_drop(id, "слишком много данных за матч")
		return
	_make_history_space(id, cost)
	if _peers.has(id) and _rooms.has(code):
		next[side] = int(next[side]) + 1
		sizes[side] = int(sizes[side]) + line.length()
		costs[side] = int(costs[side]) + cost
		(room["log"] as Array).append(line)
		# строка хода по номеру — для жалоб на подлог и отправки сопернику из журнала
		(room["raws"] as Array)[side][int(k)] = raw
		_pump_turns(room)
		_after_in(code, room, side, int(k))


func _text_cost(text: String) -> int:
	return text.length() * 4 + 64


func _history_total() -> int:
	var total := 0
	for room: Dictionary in _rooms.values():
		var costs: Array = room["history_cost"]
		total += int(costs[0]) + int(costs[1])
	for p: Dictionary in _peers.values():
		total += int(p["tail_cost"])
	return total


## Общий предел нельзя вешать на того, кто прислал СЛЕДУЮЩИЙ ход: чужой залив подставлял бы
## честного. Освобождаем крупнейший вклад (история стороны + её недочитанный хвост), учитывая
## новый ход при выборе. Закрытие его комнаты сохраняет допустимый хвост сопернику.
func _make_history_space(id: int, cost: int) -> void:
	while _peers.has(id) and _history_total() + cost > HISTORY_TOTAL_MAX:
		var largest := id
		var largest_cost := -1
		for pid: int in _peers:
			var p: Dictionary = _peers[pid]
			var held := int(p["tail_cost"]) + (cost if pid == id else 0)
			var code := String(p["room"])
			var s := int(p["side"])
			if _rooms.has(code) and s in [0, 1]:
				held += int((_rooms[code]["history_cost"] as Array)[s])
			if held > largest_cost:
				largest = pid
				largest_cost = held
		_drop(largest, "общий бюджет истории: слишком много удерживаемых данных")

## После хода стороны: жалобы на этот её ход, ждавшие его на сервере.
func _after_in(code: String, room: Dictionary, side: int, k: int) -> void:
	var pend: Array = room["pending"]
	for i in range(pend.size() - 1, -1, -1):
		var q: Dictionary = pend[i]
		if int(q["from"]) == 1 - side and int(q["k"]) <= k:
			pend.remove_at(i)
			_judge_complaint(code, room, q)
			if not _rooms.has(code):
				return



## Клиент не получает через сервер ходов соперника дольше 30 с (придержка) — матч без итога.
## Обоснованно, только если на сервере эта сторона впереди соперника на VOID_MIN_GAP ходов.
func _void(id: int) -> void:
	if not _in_match(id):
		return
	var code := String(_peers[id]["room"])
	var room: Dictionary = _rooms[code]
	var side := int(_peers[id]["side"])
	var next: Array = room["next_k"]
	var gap := int(next[side]) - int(next[1 - side])
	var names := _names(room)
	if not _request_ok(id):
		return
	if int(room["go_ms"]) == 0 or gap < VOID_MIN_GAP:
		_log("комната %s: отклонено прерывание стороны %d «%s» (разрыв %d ходов) — матч идёт"
			% [code, side, names[side], gap])
		_send(id, {"t": "void_denied", "gap": gap})
		return
	_log("комната %s: матч прерван без итога — сторона %d «%s» не получает через сервер ходов " \
		% [code, side, names[side]] + "стороны %d «%s» (разрыв %d ходов)" % [1 - side,
		names[1 - side], gap])
	for pid: int in room["peers"]:
		_send(pid, {"t": "error", "code": "void"})
	_close_room(code, 0)
	_lobby_dirty = true


## Клиент ждал «ready» соперника дольше NetSession.READY_WAIT — матч отменяется обоим без итога.
func _no_ready(id: int) -> void:
	if not _in_match(id):
		return
	var code := String(_peers[id]["room"])
	var room: Dictionary = _rooms[code]
	var side := int(_peers[id]["side"])
	var ready: Array = room["ready"]
	if not _request_ok(id):
		return
	if int(room["go_ms"]) > 0 or not bool(ready[side]) or bool(ready[1 - side]):
		# соперник уже прислал «ready» (гонка) — бой начинается как обычно
		_log("комната %s: отклонена отмена загрузки стороны %d — соперник уже загрузил поле"
			% [code, side])
		_send(id, {"t": "no_ready_denied"})
		return
	_log("комната %s: сторона %d не дождалась загрузки соперника — отменена без итога" % [code, side])
	for pid: int in room["peers"]:
		_send(pid, {"t": "error", "code": "no_ready"})
	_close_room(code, 0)
	_lobby_dirty = true


## Запрос «void»/«no_ready» от стороны — не чаще раза в REQUEST_MIN_MS; чаще — молча мимо.
func _request_ok(id: int) -> bool:
	var now := Time.get_ticks_msec()
	if now - int(_peers[id].get("req_at", -REQUEST_MIN_MS)) < REQUEST_MIN_MS:
		return false
	_peers[id]["req_at"] = now
	return true


func _names(room: Dictionary) -> Array:
	var names := []
	for pid: int in room["peers"]:
		names.append(String(_peers[pid]["name"]) if _peers.has(pid) else "?")
	return names


## История ввода — судье порциями, пока его исходящий буфер не наполнится.
func _pump_judges() -> void:
	for code: String in _rooms:
		var room: Dictionary = _rooms[code]
		if not _judge_alive(room):
			continue
		var jp: Dictionary = _peers[int(room["judge"])]
		if not (jp["outq"] as Array).is_empty():
			continue   # «start» судье ещё ждёт в очереди — история только после него
		var ws: WebSocketPeer = jp["ws"]
		var hist: Array = room["log"]
		var i := int(room["cursor"])
		while i < hist.size() and ws.get_current_outbound_buffered_amount() < JUDGE_BUF:
			if ws.send_text(hist[i]) != OK:
				break   # очередь сокета полна — этот же ход в следующем кадре, а не мимо
			i += 1
		room["cursor"] = i


## Очереди к игрокам: сначала хвост ходов закрытого матча, потом служебное, потом свежее лобби;
## затем ходы идущих матчей из журналов комнат.
func _pump_out() -> void:
	for id: int in _peers:
		var p: Dictionary = _peers[id]
		var ws: WebSocketPeer = p["ws"]
		var tail: Array = p["tail"]
		while not tail.is_empty() and _try_send(ws, String(tail[0])):
			p["tail_bytes"] = int(p["tail_bytes"]) - String(tail[0]).length()
			p["tail_cost"] = int(p["tail_cost"]) - _text_cost(String(tail[0]))
			tail.pop_front()
		if not tail.is_empty():
			continue
		var q: Array = p["outq"]
		while not q.is_empty() and _try_send(ws, String(q[0])):
			p["outq_bytes"] = int(p["outq_bytes"]) - String(q[0]).length()
			q.pop_front()
		if q.is_empty() and String(p["lobby_next"]) != "" and _try_send(ws, p["lobby_next"]):
			p["lobby_next"] = ""
	for code: String in _rooms:
		if bool((_rooms[code] as Dictionary)["started"]):
			_pump_turns(_rooms[code])
			_pump_snap(_rooms[code])


## Ходы стороны s — её сопернику из журнала комнаты, по порядку и не переполняя его сокет. Пока у
## получателя ждёт служебное (или хвост), ходы стоят за ним: порядок «служебное → ходы» тот же, что
## был, когда всё шло прямо в сокет. Индекс в room.peers — сторона.
func _pump_turns(room: Dictionary) -> void:
	var peers: Array = room["peers"]
	if peers.size() < 2:
		return
	var out: Array = room["out_k"]
	var next: Array = room["next_k"]
	for s in 2:
		var to: int = peers[1 - s]
		if not _peers.has(to):
			continue
		var p: Dictionary = _peers[to]
		if not (p["outq"] as Array).is_empty() or not (p["tail"] as Array).is_empty():
			continue
		var raws: Dictionary = (room["raws"] as Array)[s]
		while int(out[s]) < int(next[s]) and _try_send(p["ws"], String(raws[int(out[s])])):
			out[s] = int(out[s]) + 1


## Матч закрыт: ходы стороны 1 − i, не дошедшие до игрока pid (сторона i), — в его хвост. За матч
## это не больше LOG_CAP (предел стороны), OUTQ_MAX сюда не считается: это не залив, а долг
## сервера. Но хвост, не дочитанный к концу СЛЕДУЮЩЕГО матча, копился бы матч за матчем (verifier
## B-378). Один матч даёт не больше LOG_CAP ходов + OUTQ_MAX служебного (больше служебного — уже
## отключён), поэтому сверх их суммы — только недочитанное с прошлых матчей: его отключаем.
func _tail_turns(room: Dictionary, i: int, pid: int) -> void:
	if (room["peers"] as Array).size() < 2:
		return
	var s := 1 - i
	var out: Array = room["out_k"]
	var raws: Dictionary = (room["raws"] as Array)[s]
	var p: Dictionary = _peers[pid]
	var tail: Array = p["tail"]
	var bytes := int(p["tail_bytes"])
	var cost := int(p["tail_cost"])
	# служебное, уже ждущее игрока, шло раньше этих ходов — пусть и уйдёт раньше
	var q: Array = p["outq"]
	if not q.is_empty():
		tail.append_array(q)
		bytes += int(p["outq_bytes"])
		for text: String in q:
			cost += _text_cost(text)
		q.clear()
		p["outq_bytes"] = 0
	for k in range(int(out[s]), int((room["next_k"] as Array)[s])):
		# хода может не быть: отключённого за объём (LOG_CAP) номер уже сдвинут, а строка не
		# записана (verifier B-378 — SCRIPT ERROR здесь)
		var r: Variant = raws.get(k)
		if r is String:
			tail.append(r)
			bytes += (r as String).length()
			cost += _text_cost(r)
	out[s] = int((room["next_k"] as Array)[s])
	p["tail_bytes"] = bytes
	p["tail_cost"] = cost
	if bytes > LOG_CAP + OUTQ_MAX or cost > HISTORY_SIDE_MAX + OUTQ_MAX * 4 \
			or _history_total() > HISTORY_TOTAL_MAX:
		_kick(pid, "не успевает принимать")
		# Получатель уже отключается. Освобождаем недоставленное сразу, до следующего матча.
		tail.clear()
		p["tail_bytes"] = 0
		p["tail_cost"] = 0


func _judge_msg(id: int, t: String, raw: String) -> void:
	var code := String(_peers[id]["room"])
	if code == "" or not _rooms.has(code):
		return
	if t == "hash":
		_hash(id, JSON.parse_string(raw) as Dictionary)
	elif t == "snap":
		_judge_snap(code, _rooms[code], JSON.parse_string(raw) as Dictionary)
	elif t == "heal_fail":
		_judge_heal_fail(code, _rooms[code], JSON.parse_string(raw) as Dictionary)
	elif t == "verdict":
		_log("комната %s: итог судьи %s" % [code, raw])
		for pid: int in (_rooms[code] as Dictionary)["peers"]:
			_send_raw(pid, raw)


## Лобби — всем, кто не в идущем матче: открытые комнаты СВОЕЙ сборки (в чужую войти нельзя) и
## кто онлайн. Шлётся целиком при любом изменении — игроков единицы, экономить не на чем.
func _broadcast_lobby() -> void:
	var in_game := 0
	var names: Array[String] = []
	for id: int in _peers:
		var p: Dictionary = _peers[id]
		if not bool(p["hello"]) or p.has("kick_at") or bool(p.get("judge", false)):
			continue
		if String(p["room"]) != "" and bool((_rooms[p["room"]] as Dictionary)["started"]):
			in_game += 1
		else:
			names.append(String(p["name"]))
	for id: int in _peers:
		var p: Dictionary = _peers[id]
		if not bool(p["hello"]) or p.has("kick_at") or bool(p.get("judge", false)):
			continue
		var code := String(p["room"])
		if code != "" and bool((_rooms[code] as Dictionary)["started"]):
			continue
		var rooms: Array = []
		for rc: String in _rooms:
			var r: Dictionary = _rooms[rc]
			if not bool(r["started"]) and String(r["build"]) == String(p["build"]):
				rooms.append({"code": rc, "host": r["host"], "map": r["map"], "mine": rc == code})
		var text := JSON.stringify({"t": "lobby", "rooms": rooms, "players": names,
			"in_game": in_game})
		if (p["outq"] as Array).is_empty() and (p["tail"] as Array).is_empty():
			p["lobby_next"] = ""
			_send_raw(id, text)
		else:
			# игрок не успевает читать — лобби ему нужно только последнее: прежнее заменяем, а не
			# копим (иначе тот, кто дёргает create/cancel, растил бы очередь всем в лобби)
			p["lobby_next"] = text


func _other(id: int) -> int:
	var code := String(_peers[id]["room"])
	if code == "" or not _rooms.has(code):
		return 0
	for pid: int in (_rooms[code] as Dictionary)["peers"]:
		if pid != id:
			return pid
	return 0


func _map_ok(map_id: String) -> bool:
	if map_id == "pvp:duel" or map_id == "gen:":
		return true
	var re := RegEx.create_from_string(GEN_RE)
	return re.search(map_id) != null


## Целое из пакета: только конечное число; иначе def (int() от словаря — SCRIPT ERROR).
func _i(v: Variant, def: int) -> int:
	if v is int:
		return v
	if v is float and is_finite(v) and absf(v) < 1.0e15 and v == floorf(v):
		return int(v)
	return def


## Строка из пакета: только если это строка, обрезанная до n символов; иначе пусто.
func _s(v: Variant, n: int) -> String:
	return (v as String).left(n) if v is String else ""


func _clean_build(raw: String) -> String:
	var out := ""
	for c in raw:
		if c in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-":
			out += c
	return out


func _clean_name(raw: String, id: int) -> String:
	var out := ""
	for c in raw.strip_edges():
		# буквы любых алфавитов, цифры, пробел и немного знаков; управляющие, кавычки (имя стоит в
		# «ёлочках» строк лога) и двунаправленные символы (переворачивают строку лога) — прочь
		var u := c.unicode_at(0)
		if u < 32 or (u >= 0x7F and u <= 0x9F) or (u >= 0x202A and u <= 0x202E) \
				or (u >= 0x2066 and u <= 0x2069) or u in [0x200E, 0x200F, 0x061C, 0xFEFF]:
			continue
		if not c in ["<", ">", "\"", "\\", "[", "]", "«", "»", "'", "`", "„", "“", "”"]:
			out += c
	out = out.strip_edges().left(NAME_MAX)
	return out if out != "" else "Игрок %d" % id


func _new_code() -> String:
	while true:
		var code := ""
		for i in 4:
			code += CODE_CHARS[_rng.randi_range(0, CODE_CHARS.length() - 1)]
		if not _rooms.has(code):
			return code
	return ""


func _send(id: int, msg: Dictionary) -> void:
	_send_raw(id, JSON.stringify(msg))


## Служебное игроку: сразу в сокет, если перед ним ничего не ждёт и буфер позволяет, иначе — в его
## очередь на сервере (_pump_out). Ждущее лобби встаёт в очередь первым — порядок сообщений тот же.
func _send_raw(id: int, text: String) -> void:
	if not _peers.has(id):
		return
	var p: Dictionary = _peers[id]
	var q: Array = p["outq"]
	if String(p["lobby_next"]) != "":
		q.append(p["lobby_next"])
		p["outq_bytes"] = int(p["outq_bytes"]) + String(p["lobby_next"]).length()
		p["lobby_next"] = ""
	if q.is_empty() and (p["tail"] as Array).is_empty() and _try_send(p["ws"], text):
		return
	q.append(text)
	p["outq_bytes"] = int(p["outq_bytes"]) + text.length()
	if int(p["outq_bytes"]) > OUTQ_MAX:
		_kick(id, "не успевает принимать")


## В сокет, если он открыт и исходящий буфер не выйдет за PEER_BUF (пустой буфер берёт и большее);
## нет — false, сообщение ждёт своей очереди. Отказ сокета (полна очередь пакетов) — тоже false.
func _try_send(ws: WebSocketPeer, text: String) -> bool:
	if ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return false
	var buffered := ws.get_current_outbound_buffered_amount()
	if buffered > 0 and buffered + text.length() > PEER_BUF:
		return false
	return ws.send_text(text) == OK


func _kick(id: int, why: String) -> void:
	if _peers.has(id) and not (_peers[id] as Dictionary).has("kick_at"):
		_peers[id]["kick_at"] = Time.get_ticks_msec() + KICK_MS
		_peers[id]["kick_why"] = why


func _drop(id: int, why: String) -> void:
	if not _peers.has(id):
		return
	var p: Dictionary = _peers[id]
	var code := String(p["room"])
	_peers.erase(id)
	(p["ws"] as WebSocketPeer).close(1000, why.left(60))
	_log("игрок %d отключён: %s" % [id, why])
	if bool(p.get("judge", false)):
		if code != "" and _rooms.has(code):
			(_rooms[code] as Dictionary)["judge"] = 0   # дальше — сверка пары без судьи
			(_rooms[code] as Dictionary)["judge_dead"] = true
		return
	if code != "":
		_close_room(code, id)
	if bool(p["hello"]):
		_lobby_dirty = true


func _log(text: String, proof := false) -> void:
	var now := Time.get_ticks_msec()
	if now - _log_at >= 1000:
		if _log_suppressed > 0:
			print("[relay %s] подавлено повторных событий: %d" % [
				Time.get_datetime_string_from_system(), _log_suppressed])
		_log_at = now
		_log_count = 0
		_proof_log_count = 0
		_log_suppressed = 0
	if (_proof_log_count >= PROOF_LOGS_PER_SEC if proof else _log_count >= LOGS_PER_SEC):
		_log_suppressed += 1
		return
	if proof:
		_proof_log_count += 1
	else:
		_log_count += 1
	print("[relay %s] %s" % [Time.get_datetime_string_from_system(), text])
