# gdlint: disable=max-file-lines
class_name NetSession
extends Node
##
## Сессия онлайн-«Схватки» (lockstep, docs/pvp/NET_LOCKSTEP.md): сокет к ретранслятору, лобби,
## ходы с задержкой ввода, остановка при отсутствии ввода соперника, сверка отпечатков, журнал.
##
## Мир сам в сетевом режиме не шагает — шагает сессия: каждый тик 1/60 с реального времени, но
## только когда ввод обеих сторон за текущий ход уже есть. Так два клиента проходят одинаковую
## последовательность «команды хода → тики» и считают один и тот же бой, не обмениваясь
## состоянием. Расхождение (разная арифметика машин, забытый прямой ввод) ловит отпечаток.
##
## Жизнь: connect_lobby(url, имя) → общее лобби (сигнал lobby: открытые комнаты, кто онлайн) →
## create_room(map) / join_room(code) → сигнал match_start → вызывающий (PvpFlow) запускает мир
## через start_net_match и зовёт attach(world) → «ready» обоих → бой → leave_match() → снова лобби.
##
## Прямое соединение (NetP2P, docs/pvp/NET_LOCKSTEP.md): с «start» параллельно загрузке поля идёт
## знакомство через ретранслятор и пробивка UDP. Ходы ВСЕГДА уходят ретранслятору (судья и запасной
## путь) и, если путь пробит, ещё напрямую; ход соперника берётся из того пути, что пришёл первым,
## а когда пришли оба — сырые строки сверяются (подлог выключает прямой путь). Задержка ввода у
## каждой стороны своя, по замеренному пути, и в матче может только расти.
##

signal status(text: String)
signal room_created(code: String)
signal lobby(rooms: Array, players: Array, in_game: int)
signal match_start(seed_value: int, map_id: String, side: int)
signal failed(text: String)
## Ретранслятор принял hello — мы в лобби (SteamNet по нему открывает комнату хозяина / входит в
## комнату хозяина у гостя).
signal welcomed
## Матч оборвался (связь потеряна, соперник ушёл на загрузке): вызывающий уводит игрока в лобби —
## без этого мир оставался в фазе боя на месте и выйти можно было только закрыв игру
## (проверка 01.10).
signal aborted(text: String)

enum Stage { IDLE, CONNECTING, LOBBY, LOADING, PLAYING, OVER }

## 2 — прямое соединение (cand/path/late/p2p_mismatch, токен p2p в start, задержка по пути).
const PROTO := 2
## Сборка: соперник с другой сборкой в комнату не войдёт (ретранслятор сравнит строки).
## 2026-10-05c — угловые фигуры и ульты: NetSnap.VERSION 4.
## 2026-10-08b — штрих: флаг stack (Шифт, B-044), подновление линии любого вида, пеньки (B-345).
## 2026-10-09a — автомарш только из резерва у дома, ближний первым (D-1009-C1, 0.3.1).
const BUILD := "net-2026-10-09a"
const DT := 1.0 / 60.0
## Ход — 3 тика (50 мс); ввод хода t стороны применяется в начале хода t + её задержки у обоих.
const TURN := 3
const TURN_MS := 50.0
## Задержка ввода (в ходах) у каждой стороны своя: в lockstep о ней не надо договариваться — ход k
## у обоих применяется на одном тике, отправитель сам решает, в какой k поставить свои команды.
## Нужно лишь, чтобы первые DELAY_MIN ходов у всех были пустыми (ретранслятор EMPTY_TURNS и судья
## держат ту же границу). 2 хода — 100 мс: меньше не бывает и в одной сети (кадр + обработка).
## Потолок 12 — 600 мс: дальше играть уже нельзя, лучше стоять, чем так запаздывать.
const DELAY_MIN := 2
const DELAY_MAX := 12
## Запас на разброс задержки: замер 01.10 через Франкфурт — p90 почти вдвое выше p50; верхний
## замер RTT уже несёт часть разброса, сверху ×1.25 и +20 мс, и ещё один ход (ход закрывается
## раз в 50 мс — команда ждёт закрытия в среднем полхода, худшем — ход).
const JITTER_MUL := 1.25
const JITTER_ADD_MS := 20.0
## RTT до ретранслятора, пока нет ни одного pong (пессимистично: лучше постоять меньше).
const RELAY_RTT_DEFAULT := 300
## Сколько последних pong помнить: задержка берётся по верхнему из них (без одиночного выброса).
const RTT_RING := 5
## Кадр дольше этого — заминка (загрузка поля): pong в нём не замер пути.
const HITCH_S := 0.1
## Сколько ждать первого замера RTT до сервера, прежде чем отправить кандидатов без него.
const CAND_RTT_WAIT_MS := 1500
## Опоздания соперника: окно оценки, порог простоя в окне и тишина после старта (на старте
## клиенты стартуют не в одну миллисекунду — простой от этого не повод растить задержку).
## «Систематически» — простой в окне набран не одним рывком (кадр-заминка), а на LATE_TURNS
## разных ходах. Растить задержку по опозданиям — не больше LATE_ADD_MAX ходов сверх выбранной:
## если не помогло, это не задержка пути, а медленная машина соперника, и запас только вредит.
const LATE_WINDOW := 2.0
const LATE_STALL := 0.12
const LATE_TURNS := 3
const LATE_GRACE := 1.5
const LATE_ADD_MAX := 4
## Пробивка не должна держать начало боя дольше этого (NetP2P сам укладывается в ~6,5 с).
const P2P_DEADLINE_MS := 8000
## Повтор неподтверждённых ходов напрямую, когда своих новых нет (стоим — соперник ждёт нас).
const UDP_RESEND_MS := 60
## Неподтверждённых ходов в очереди прямого пути не больше: дальше их несёт ретранслятор.
const UDP_UNACKED_MAX := 64
## Сверка путей: сколько ходов назад помнить пришедшую одним путём строку.
const MATCH_KEEP := 256
const MAX_CATCHUP := 6
const HASH_EVERY := 60
const PING_EVERY := 2.0
const PING_LOADING := 0.5
const CONNECT_TIMEOUT := 10.0
## Сколько стоять без ввода соперника, прежде чем показать «ждём соперника».
const STALL_SHOW := 0.35
## Ходы соперника (через сервер) принимаются не дальше этого вперёд от применённого. Ход за окном
## был бы потерян навсегда (сервер не повторяет), и клиент застрял бы, а честный с медленной
## машиной отстаёт от часов боя хоть на весь матч (verifier №3 01.10) — окно на час боя (72 000
## ходов) с запасом. Память держат ретранслятор: ход не дальше «часы + 52», и LOG_CAP на сторону.
const REMOTE_WINDOW := 80000
## Защита от придержки копии ходов на сервер (решение координатора 01.10 вместо «рвём
## отстающего»): ход k соперника, пришедший напрямую, применяется, только когда через сервер уже
## пришёл его ход k − RELAY_LAG_MAX. 200 ходов (10 с) — с запасом на честную заминку сети, а судья
## и сверка путей отстают не больше. Иначе — простой «Соперник не передаёт ходы на сервер…»; дольше
## RELAY_HOLD_ABORT (30 с) — матч прерывается без итога (придерживающий стоит тоже: ему нужны ходы
## честного, так что придержка лишь замораживает матч).
const RELAY_LAG_MAX := 200
const RELAY_HOLD_ABORT := 30.0
## «void»/«no_ready» — запросы: после отправки клиент остаётся в матче и ждёт ответа сервера
## (принято — оба в лобби без итога; отклонено — ждём и играем дальше). Нет ответа столько —
## сеть умерла: обычный обрыв соединения.
const REQUEST_REPLY_WAIT := 15.0
## Ходы напрямую дальше «пришедшее через сервер + RELAY_LAG_MAX + это» не храним: применить их всё
## равно нельзя, а память UDP-пакетов соперника не ограничена сервером (их повторят, ack не дан).
const UDP_AHEAD_KEEP := 64
## Своё поле загружено, а «ready» соперника нет столько — матч отменяется (обманщик мог держать
## «ready», пока честный стоит на загрузке без конца).
const READY_WAIT := 30.0
## Подтяжка снимком судьи (docs/pvp/NET_LOCKSTEP.md, «Подтяжка»): снимок боя приходит кусками
## {"t":"snap"} — строка «<размер var_to_bytes>:<base64 сжатого>», порезанная по SNAP_PART
## символов (пакет ретранслятора — до 16 КБ). Кусков не больше SNAP_PARTS_MAX, распакованный —
## не больше SNAP_RAW_MAX: больше — снимок не шлётся и не принимается.
const SNAP_PART := 12000
const SNAP_PARTS_MAX := 160
const SNAP_RAW_MAX := 32 * 1024 * 1024
## Сколько применённых ходов помнить: снимок судьи бывает старше своего тика (снимок идёт по сети,
## пока клиент играет дальше) — до своего тика клиент досчитывает его этими ходами. 1200 — 60 с.
const HIST_KEEP := 1200

var stage := Stage.IDLE
var side := -1
var room_code := ""
var map_id := ""
var seed_value := 0
var rtt_ms := -1
var my_name := ""
var opponent_name := ""
## Проба: остановиться ровно на этом тике (оба клиента — на одном), -1 — до конца матча.
var stop_at_tick := -1
## Итог по счёту сервера-судьи ({"why", "winner", "hp", "tick"}), пусто — судьи нет или ещё рано.
var verdict: Dictionary = {}
## Последняя причина обрыва — лобби покажет её, когда откроется.
var last_error := ""
## Прямое соединение разрешено (галочка лобби): выключено — кандидаты не уходят, IP не виден.
var direct_enabled := false
## Как назвать путь в строке «Связь: …» (хозяин и гость Steam-игры — «через Steam»).
var link_label := "через сервер"
## Спрашивать STUN (пробы на одной машине обходятся без интернета).
var use_stun := true
## Отладка проб: глушить UDP, терять процент входящих UDP, подменить по UDP первый непустой
## ход начиная с этого номера (подлог), -1 — нет.
var dbg_udp_off := false
var dbg_udp_loss := 0
var dbg_forge_at := -1
## Отладка проб: два клиента на одной машине (кандидат 127.0.0.1); придержать отправку своих ходов
## ретранслятору начиная с хода dbg_hold_from на dbg_hold_ms (копия на сервер «лагает» или
## придержана умышленно — проверка, что ретранслятор не рвёт честного лидера).
var dbg_loopback := false
var dbg_hold_from := -1
var dbg_hold_ms := 0
## Отладка проб verifier №4: задержка приёма с сервера (мс); заминка приёма с тика на мс; сброс
## придержанных копий разом через dbg_race_ms после того, как соперник встал (гонка «void»).
var dbg_down_lat := 0
var dbg_down_stall_tick := -1
var dbg_down_stall_ms := 0
var dbg_race_ms := 0
## Своя задержка ввода в ходах (выбирается на старте боя по пути, потом только растёт).
var delay := DELAY_MIN
## Каким путём идут ходы: «p2p» / «relay» (пусто — бой ещё не начался).
var path_mode := ""
## Ход, на котором прямой путь разошёлся с ретранслятором (-1 — не было).
var p2p_mismatch := -1
## Чей путь первым принёс ход соперника (сверка и проба).
var first_via := {"udp": 0, "relay": 0}
## Сервер доказал подмену хода (verdict why=forge): кто подменил (-1 — не было).
var forge_cheater := -1
## Код и причина последнего закрытия сокета сервера («-1 » — разорвано без закрывающего кадра).
var last_close := ""
## Жалоба, ушедшая серверу при несовпадении путей (пусто — не было).
var mismatch_report: Dictionary = {}
## Удачных подтяжек снимком судьи за матч.
var heals := 0

var _desync_judge := false
var _p2p: NetP2P
var _p2p_t0 := 0
var _cand_due := false
var _hitch := false
var _remote_relay_rtt := -1
var _remote_nat := ""
var _relay_rtts: Array[int] = []
var _next_out := 0
var _sent_raw: Dictionary = {}     ## свой ход → [сырая строка, её HMAC], пока не подтверждён
## Свой секретный ключ стороны (из start): HMAC ходов в UDP — доказательство подлога.
var _my_key := PackedByteArray()
var _hold_q: Array = []            ## [время отправки, строка] — придержанные ходы (dbg_hold)
var _udp_sent_at := 0
var _remote_contig := -1           ## последний ход соперника, до которого все пришли подряд
var _remote_have: Dictionary = {}
var _seen: Dictionary = {}         ## ход соперника → [сырая строка, путь], пока не пришёл второй
var _forged := false
var _since_go := 0.0
var _late_acc := 0.0
var _late_t := 0.0
var _late_turns := 0
var _stall_turn := -1
var _delay_start := DELAY_MIN
var _link: Label
var _last_text := ""
## Последний ход соперника, пришедший через сервер (сервер шлёт их по порядку), и простой из-за
## придержки копии на сервер.
var _relay_contig := -1
var _hold_stall := 0.0
## Запрос серверу («void» / «no_ready») ждёт ответа: сколько уже ждём (-1 — запроса нет).
var _req_wait := -1.0
var _dq: Array = []            ## [время выдачи, текст] — задержанный приём (dbg_down_*)
var _down_stall_end := 0
var _race_rc := -1
var _race_t := 0
## Сводка матча для ретранслятора (Игорь 01.10: «по relay.log видеть, как прошло у каждого»).
var _mstats := NetMatchStats.new()
var _ready_wait := 0.0
## Причина, которую сервер прислал перед разрывом (показать её вместо «связь потеряна»).
var _close_reason := ""
## Тик первого расхождения с судьёй — для сводки: после подтяжки _desync_tick сбрасывается
## (надписи «разошёлся» больше нет), а этот — нет.
var _desync_first := -1
## Тик расхождения, по которому судья снимает для нас снимок (-1 — не ждём): матч кончился раньше,
## чем снимок пришёл, или снимок не принят — надпись и итог судьи как без подтяжки.
var _heal_wait := -1
## Применённые ходы: ход → [команды стороны 0, стороны 1] (последние HIST_KEEP) — досчёт снимка.
var _hist: Dictionary = {}
## Снимок судьи, собираемый из кусков: номер подтяжки, сколько кусков ждём, пришедшие.
var _snap_id := -1
var _snap_n := 0
var _snap_parts := PackedStringArray()

## Канал к ретранслятору: WebSocket (сервер), пара концов в процессе (хозяин Steam-игры) или
## соединение Steam (гость). Протокол выше канала один и тот же.
var _chan: NetLink
var _pending_hello := {}
var _connect_t := 0.0
var _world: LegionWorld
var _acc := 0.0
var _local_queue: Array[Dictionary] = []      ## команды, ждущие ближайшего закрытия хода
var _turns: Array[Dictionary] = [{}, {}]      ## сторона → {ход: [команды в виде кодека]}
var _applied_turn := -1
var _ready_local := false
var _ready_remote := false
var _stall := 0.0
var _ping_t := 0.0
var _desync_tick := -1
var _remote_left := false
var _log_file: FileAccess
var _overlay: CanvasLayer
var _label: Label


func _ready() -> void:
	_overlay = CanvasLayer.new()
	_overlay.layer = 90
	add_child(_overlay)
	_label = Label.new()
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	# Якоря и поля — явно и во всю ширину вьюпорта. Пресет CENTER_TOP, поставленный ДО add_child
	# (узел ещё вне дерева, родительский прямоугольник нулевой), оставлял смещения от нуля:
	# подпись вставала в rect 640…1920 — половина строки состояния уезжала за правую кромку
	# (нашёл аудит наложений, clickwalk_menu.gd).
	_label.anchor_left = 0.0
	_label.anchor_right = 1.0
	_label.offset_left = 0.0
	_label.offset_right = 0.0
	_label.offset_top = 92.0
	_label.offset_bottom = 132.0
	_label.add_theme_font_size_override("font_size", 22)
	_label.add_theme_color_override("font_color", Color(1.0, 0.86, 0.5))
	_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_label.add_theme_constant_override("outline_size", 6)
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.add_child(_label)
	# строка состояния связи — мелко в правом нижнем углу, мышь не ловит (HUD не перехватывает)
	_link = Label.new()
	_link.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_link.position = Vector2(1280.0 - 330.0, 720.0 - 24.0)
	_link.size = Vector2(322.0, 20.0)
	_link.add_theme_font_size_override("font_size", 13)
	_link.add_theme_color_override("font_color", Color(0.85, 0.85, 0.8, 0.75))
	_link.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	_link.add_theme_constant_override("outline_size", 4)
	_link.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.add_child(_link)


# ── Лобби ───────────────────────────────────────────────────────────────────

func connect_lobby(url: String, player_name: String) -> void:
	_open(url, {"t": "hello", "v": PROTO, "build": BUILD, "name": player_name})


## Лобби по готовому каналу (Steam: NetLinkSteam гостя или конец NetLinkPipe хозяина): дальше всё
## как через сервер — hello, комнаты, матч.
func connect_link(link: NetLink, player_name: String) -> void:
	close()
	_open_link(link, {"t": "hello", "v": PROTO, "build": BUILD, "name": player_name})


## Открыть свою комнату и ждать соперника (map: «pvp:duel» или «gen:» — поле выберет сервер).
func create_room(map: String) -> void:
	_send({"t": "create", "map": map})


func join_room(code: String) -> void:
	_send({"t": "join", "code": code.strip_edges().to_upper()})


## Закрыть свою ожидающую комнату.
func cancel_room() -> void:
	room_code = ""
	_send({"t": "cancel"})


## Матч кончился или брошен — вернуться в лобби, не разрывая соединения.
func leave_match() -> void:
	_send_stats("leave")
	_send({"t": "leave"})
	_detach_world()
	_stop_p2p()
	room_code = ""
	side = -1
	if _chan != null:
		stage = Stage.LOBBY


func is_online() -> bool:
	return _chan != null and _chan.state() == NetLink.State.OPEN


func _open(url: String, hello: Dictionary) -> void:
	close()
	var u := NetCodec.normalize_url(url)
	if u == "":
		failed.emit("Укажите адрес сервера")
		return
	var link := NetLinkWs.client()
	var err := link.connect_to_url(u)
	if err != OK:
		failed.emit("Не удалось подключиться к %s (ошибка %d)" % [u, err])
		return
	_open_link(link, hello)


func _open_link(link: NetLink, hello: Dictionary) -> void:
	_chan = link
	_pending_hello = hello
	_close_reason = ""
	_dq.clear()
	_connect_t = 0.0
	stage = Stage.CONNECTING
	status.emit("Подключение к серверу…" if link.kind() == "ws" else "Подключение…")


func close() -> void:
	if _chan != null:
		_chan.close(1000, "bye")
	_chan = null
	stage = Stage.IDLE
	_detach_world()
	_stop_p2p()


func _detach_world() -> void:
	if _world != null and is_instance_valid(_world) and _world.net_out.is_valid():
		_world.net_out = Callable()
	_world = null
	_label.text = ""
	_link.text = ""
	if _log_file != null:
		_log_file.close()
		_log_file = null


# ── Бой ─────────────────────────────────────────────────────────────────────

## Мир уже запущен через start_net_match(map_id, seed_value, side): с этого момента ввод
## человека идёт сюда, а шагает мир только эта сессия.
func attach(world: LegionWorld) -> void:
	_world = world
	_world.net_out = _on_local_cmd
	_acc = 0.0
	last_error = ""
	_desync_judge = false
	verdict = {}
	_local_queue.clear()
	_turns = [{}, {}]
	_applied_turn = -1
	_ready_local = false
	_ready_remote = false
	_desync_tick = -1
	_desync_first = -1
	_heal_wait = -1
	heals = 0
	_hist.clear()
	_snap_id = -1
	_snap_n = 0
	_snap_parts = PackedStringArray()
	_remote_left = false
	delay = DELAY_MIN
	path_mode = ""
	_next_out = 0
	_sent_raw.clear()
	_since_go = 0.0
	_late_acc = 0.0
	_late_t = 0.0
	_late_turns = 0
	_stall_turn = -1
	_delay_start = DELAY_MIN
	_mstats.reset()
	stage = Stage.LOADING
	_open_log()
	# первые DELAY_MIN ходов у обоих пусты — иначе нечего было бы применить в ходе 0; остальные
	# пустые (до своей задержки) уйдут при первом закрытии хода, когда задержка выбрана
	for t in DELAY_MIN:
		_send_turn(t, [])
	_label.text = "Загрузка поля…"


func _on_local_cmd(cmd: Dictionary) -> void:
	if stage != Stage.PLAYING and stage != Stage.LOADING:
		return
	var enc := NetCodec.encode(cmd)
	if NetCodec.decode(JSON.parse_string(JSON.stringify(enc))).is_empty():
		push_warning("NetSession: своя команда не прошла кодек: %s" % str(cmd))
		return
	_local_queue.append(enc)


func _process(delta: float) -> void:
	if _chan == null:
		return
	_hitch = delta > HITCH_S
	while not _hold_q.is_empty() and Time.get_ticks_msec() >= int(_hold_q[0][0]):
		_chan.send_text(String(_hold_q[0][1]))
		_hold_q.pop_front()
	_chan.poll()
	var st := _chan.state()
	if st == NetLink.State.OPEN:
		if not _pending_hello.is_empty():
			_send(_pending_hello)
			_pending_hello = {}
			status.emit("Подключено, вход в лобби…")
		# UDP — раньше сокета сервера: ход обоими путями за кадр засчитан прямому пути
		_tick_p2p()
		_dbg_race()
		while _chan != null and _chan.available() > 0:
			_dq.append([_dbg_release(), _chan.take_text()])
		while _chan != null and not _dq.is_empty() and Time.get_ticks_msec() >= int(_dq[0][0]):
			var text: String = _dq.pop_front()[1]
			var msg: Variant = JSON.parse_string(text)
			if msg is Dictionary:
				_last_text = text   # сырой текст хода — для сверки с прямым путём
				_handle(msg as Dictionary)
	elif st == NetLink.State.CONNECTING:
		_connect_t += delta
		if _connect_t > maxf(CONNECT_TIMEOUT, _chan.connect_timeout()):
			_fail("Сервер не отвечает — проверьте адрес" if _chan.kind() == "ws"
				else "Соперник не отвечает — соединение не установлено")
			return
	elif st == NetLink.State.CLOSED:
		# причина разрыва (error) могла прийти последним пакетом — дочитать, а не «связь потеряна»
		while _chan.available() > 0:
			var m: Variant = JSON.parse_string(_chan.take_text())
			if m is Dictionary and (m as Dictionary).get("t") == "error":
				_close_reason = _error_text(String((m as Dictionary).get("code", "")))
		_on_closed()
		return
	if _chan == null:
		return
	_ping_t += delta
	# на загрузке — чаще: к старту боя нужен замер RTT без заминок кадра (по нему задержка ввода)
	if _ping_t >= (PING_LOADING if stage == Stage.LOADING else PING_EVERY):
		_ping_t = 0.0
		_send({"t": "ping", "ms": Time.get_ticks_msec()})
	_tick_request(delta)
	if stage == Stage.LOADING:
		_tick_loading()
	elif stage == Stage.PLAYING:
		_tick_playing(delta)


func _tick_loading() -> void:
	if _world == null:
		return
	# «ready» — когда поле загружено И путь решён: задержка ввода выбирается по пути на старте,
	# а уменьшить её потом нельзя (ход k дважды не отправить)
	if _p2p != null and not _p2p.decided() and Time.get_ticks_msec() - _p2p_t0 > P2P_DEADLINE_MS:
		_p2p.fail("не уложились в %d с" % (P2P_DEADLINE_MS / 1000))
	var path_ok := _p2p == null or _p2p.decided()
	if not _ready_local and _world.net_can_step() and path_ok:
		_ready_local = true
		_ready_wait = 0.0
		_send({"t": "ready"})
	if _ready_local and not _ready_remote:
		_ready_wait += get_process_delta_time()
		if _ready_wait > READY_WAIT:
			_ready_wait = 0.0
			_request("no_ready")   # запрос: сервер отменит матч обоим или откажет (соперник готов)
	if _ready_local and _ready_remote:
		stage = Stage.PLAYING
		_label.text = ""
		_choose_delay()
		_log({"ev": "go", "delay": delay, "path": path_mode})
		_mstats.delay_go = delay
		_mstats.go_ms = Time.get_ticks_msec()
	elif _ready_local:
		_label.text = "Ждём соперника…"
	elif _world.net_can_step():
		_label.text = "Ищем прямой путь к сопернику…"


func _tick_playing(delta: float) -> void:
	if _world == null or not is_instance_valid(_world):
		return
	if not _world.net_can_step():
		# бой кончился (или мир ушёл в меню) — ходить больше нечего
		if _world.phase != LegionWorld.Phase.BATTLE:
			_finish()
		return
	_acc = minf(_acc + delta, 0.25)
	var steps := 0
	var stalled := false
	var hold := false
	while _acc >= DT and steps < MAX_CATCHUP:
		var tick := _world.net_tick
		if stop_at_tick >= 0 and tick >= stop_at_tick:
			break
		if tick % TURN == 0 and tick / TURN > _applied_turn:
			var t := tick / TURN
			if not (_turns[1 - side] as Dictionary).has(t):
				stalled = true
				if t != _stall_turn:
					_stall_turn = t
					_late_turns += 1
				break
			if t - RELAY_LAG_MAX > _relay_contig:
				hold = true   # ход напрямую есть, а копии на сервере нет давно — не применяем
				break
			_close_local_turn(t)
			_apply_turn(t)
		_world.net_step()
		steps += 1
		_acc -= DT
		if _world.net_tick % HASH_EVERY == 0:
			var h := _world.net_digest()
			_send({"t": "hash", "k": _world.net_tick, "h": h})
			_log({"ev": "hash", "k": _world.net_tick, "h": h})
		if not _world.net_can_step():
			break
	if hold:
		_acc = minf(_acc, DT)
		_mstats.on_stall(_hold_stall, delta, STALL_SHOW)   # в сводке — тоже простой
		_hold_stall += delta
		if _hold_stall > RELAY_HOLD_ABORT and _req_wait < 0.0:
			_request("void")   # запрос: принят — оба в лобби без итога; отклонён — ждём дальше
	else:
		_hold_stall = 0.0
	# ждём ввод — время не копим, иначе после паузы мир рванул бы вперёд
	if stalled:
		_acc = minf(_acc, DT)
		_mstats.on_stall(_stall, delta, STALL_SHOW)
		_stall += delta
		_late_acc += delta
	else:
		_stall = 0.0
	_watch_late(delta)
	_update_label()


## Соперник систематически опаздывает (мы стоим) — просим его добавить ход задержки. Растить
## можно только свою задержку (ход k не отправляется дважды), поэтому просьба идёт ему.
func _watch_late(delta: float) -> void:
	_since_go += delta
	_late_t += delta
	if _late_t < LATE_WINDOW:
		return
	if _late_acc >= LATE_STALL and _late_turns >= LATE_TURNS and _since_go >= LATE_GRACE:
		_send({"t": "late"})
		_log({"ev": "late_sent", "stall": snappedf(_late_acc, 0.01), "turns": _late_turns,
			"tick": _world.net_tick})
	_late_t = 0.0
	_late_acc = 0.0
	_late_turns = 0


## Соперник стоит из-за нас — ещё ход задержки (следующее закрытие хода вставит пустой ход).
func _on_late() -> void:
	if stage != Stage.PLAYING or delay >= mini(DELAY_MAX, _delay_start + LATE_ADD_MAX):
		return
	delay += 1
	_log({"ev": "delay", "delay": delay, "tick": _world.net_tick if _world != null else -1})
	_report_path()


## Выбор задержки на старте боя: по замеренной задержке пути до соперника (в одну сторону).
func _choose_delay() -> void:
	path_mode = "p2p" if _p2p != null and _p2p.is_active() else "relay"
	delay = delay_for(_oneway_ms(true))
	_delay_start = delay
	_report_path()


## Оценка «ход доходит до соперника за …» в мс: напрямую — половина RTT пути; через сервер —
## половина своего RTT до сервера + половина RTT соперника до сервера (он прислал его в cand).
## hi — верхний замер (для задержки), иначе текущий (для строки состояния).
func _oneway_ms(hi: bool) -> float:
	if path_mode == "p2p" and _p2p != null and _p2p.is_active():
		return (_p2p.rtt_hi if hi else _p2p.rtt_ms) / 2.0
	var mine := _relay_rtt(hi)
	var theirs := _remote_relay_rtt if _remote_relay_rtt >= 0 else mine
	return mine / 2.0 + theirs / 2.0


func _relay_rtt(hi: bool) -> int:
	if _relay_rtts.is_empty():
		return RELAY_RTT_DEFAULT
	return NetP2P._high_of(_relay_rtts) if hi else _relay_rtts[-1]


## Задержка в ходах для пути, который доносит ход за oneway_ms (в одну сторону).
static func delay_for(oneway_ms: float) -> int:
	var need := oneway_ms * JITTER_MUL + JITTER_ADD_MS + TURN_MS
	return clampi(ceili(need / TURN_MS), DELAY_MIN, DELAY_MAX)


## Команды, набранные человеком до этого момента, уходят как ход t + delay (и применятся у обоих
## в нём). Выросла задержка — пропущенные номера уходят пустыми ходами: нумерация строго подряд.
func _close_local_turn(t: int) -> void:
	var target := t + delay
	if target < _next_out:
		return   # ход уже ушёл (страховка после подтяжки снимком): дважды ход k не отправить
	while _next_out < target:
		_send_turn(_next_out, [])
	var cmds: Array = _local_queue.duplicate()
	_local_queue.clear()
	_send_turn(target, cmds)


## Свой ход k: ретранслятору (всегда) и, если путь пробит, напрямую — ТОЙ ЖЕ строкой: судья
## получает этот текст через ретранслятор, и соперник должен разобрать ровно его (пересборка JSON
## меняет точность дробных — ловили 01.10).
func _send_turn(k: int, cmds: Array) -> void:
	(_turns[side] as Dictionary)[k] = cmds
	_next_out = k + 1
	var raw := JSON.stringify({"t": "in", "k": k, "c": cmds})
	if dbg_hold_from >= 0 and k >= dbg_hold_from:
		_hold_q.append([Time.get_ticks_msec() + dbg_hold_ms, raw])
	elif _chan != null:
		_chan.send_text(raw)
	if _p2p == null or _p2p.state == NetP2P.State.FAILED or _p2p.state == NetP2P.State.OFF:
		return
	if dbg_forge_at >= 0 and k >= dbg_forge_at and not cmds.is_empty() and not _forged:
		# проба подлога: сопернику напрямую — пустой ход вместо настоящего
		_forged = true
		raw = JSON.stringify({"t": "in", "k": k, "c": []})
		_log({"ev": "forge", "k": k})
	_sent_raw[k] = [raw, NetP2P.mac(_my_key, raw)]
	while _sent_raw.size() > UDP_UNACKED_MAX:
		_sent_raw.erase(_sent_raw.keys()[0])
	_send_udp_turns()


func _send_udp_turns() -> void:
	if _p2p == null or not _p2p.is_active():
		return
	var now := Time.get_ticks_msec()
	var raws: Array = []
	var macs: Array = []
	for v: Array in _sent_raw.values():
		raws.append(v[0])
		macs.append(v[1])
	_p2p.send_turns(raws, macs, _remote_contig, now)
	_udp_sent_at = now


func _apply_turn(t: int) -> void:
	_applied_turn = t
	_seen.erase(t - MATCH_KEEP)
	_hist[t] = [(_turns[0] as Dictionary).get(t, []), (_turns[1] as Dictionary).get(t, [])]
	_hist.erase(t - HIST_KEEP)
	for s in 2:
		var turns: Dictionary = _turns[s]
		var cmds: Array = turns.get(t, [])
		turns.erase(t)
		for raw: Variant in cmds:
			var cmd := NetCodec.decode(raw)
			if cmd.is_empty():
				continue
			var res := _world.net_apply(s, cmd)
			_log({"ev": "cmd", "tick": _world.net_tick, "side": s, "cmd": raw,
				"ok": bool(res.get("ok", false)), "why": String(res.get("reason", ""))})


func _update_label() -> void:
	if forge_cheater >= 0:
		_label.text = "Соперник подменил ход — победа засчитана вам" if forge_cheater != side \
			else "Сервер засчитал вам поражение: ход напрямую не совпал с отправленным серверу"
	elif _remote_left:
		_label.text = "Соперник отключился"
	elif _desync_tick >= 0 and verdict.has("winner"):
		var win := int(verdict["winner"])
		var who := "ничья" if win < 0 else ("ваша победа" if win == side else "победа соперника")
		_label.text = "Итог по счёту сервера: %s" % who
	elif _desync_tick >= 0 and not _desync_judge:
		var t0 := "Бой у вас с соперником разошёлся (тик %d) — судьи нет, итог может отличаться"
		_label.text = t0 % _desync_tick
	elif _desync_tick >= 0:
		var t := "Бой у вас разошёлся с сервером (тик %d) — итог засчитает сервер"
		_label.text = t % _desync_tick
	elif _hold_stall >= STALL_SHOW:
		_label.text = "Соперник не передаёт ходы на сервер…"
	elif _stall >= STALL_SHOW:
		_label.text = "Ждём соперника…"
	else:
		_label.text = ""
	_link.text = link_text()


## «Связь: напрямую 9 мс» / «Связь: через сервер 210 мс» — сколько ход идёт до соперника.
func link_text() -> String:
	if path_mode == "":
		return ""
	var ms := int(round(_oneway_ms(false)))
	if p2p_mismatch >= 0:
		return "Связь: через сервер %d мс (прямой путь отключён: ход не сошёлся)" % ms
	var how := "напрямую" if path_mode == "p2p" else link_label
	return "Связь: %s %d мс · задержка %d" % [how, ms, delay]


func _finish() -> void:
	if stage == Stage.OVER:
		return
	stage = Stage.OVER
	_heal_unwait()
	_send({"t": "end", "tick": _world.net_tick if _world != null else -1})
	_send_stats(NetMatchStats.end_result(_world, side))
	_log({"ev": "end"})
	_label.text = ""


# ── Пакеты ──────────────────────────────────────────────────────────────────

func _handle(msg: Dictionary) -> void:
	match String(msg.get("t", "")):
		"welcome":
			my_name = String(msg.get("name", ""))
			stage = Stage.LOBBY
			_ping_t = PING_EVERY   # первый замер RTT до сервера — сразу (по нему задержка ввода)
			status.emit("Вы в лобби как «%s»" % my_name)
			welcomed.emit()
		"lobby":
			lobby.emit(msg.get("rooms", []) as Array, msg.get("players", []) as Array,
				int(msg.get("in_game", 0)))
		"room":
			room_code = String(msg.get("code", ""))
			side = int(msg.get("side", 0))
			room_created.emit(room_code)
			status.emit("Комната %s открыта — ждём соперника" % room_code)
		"start":
			seed_value = int(msg.get("seed", 1))
			map_id = String(msg.get("map", "pvp:duel"))
			side = clampi(int(msg.get("side", 0)), 0, 1)
			room_code = String(msg.get("code", room_code))
			opponent_name = String(msg.get("opponent", "соперник"))
			status.emit("Соперник — «%s», загрузка…" % opponent_name)
			# пробивка — до запуска мира: идёт параллельно загрузке поля
			var key: Variant = msg.get("key")
			_my_key = String(key).hex_decode() if key is String and String(key).length() == 32 \
				and String(key).is_valid_hex_number() else PackedByteArray()
			_start_p2p(String(msg.get("p2p", "")) if msg.get("p2p") is String else "")
			match_start.emit(seed_value, map_id, side)
		"ready":
			_ready_remote = true
		"in":
			_on_remote_turn(msg, _last_text, "relay")
		"cand":
			_on_cand(msg)
		"late":
			_on_late()
		"void_denied":
			_on_request_denied("void")
		"no_ready_denied":
			_on_request_denied("no_ready")
		"desync":
			var dk := int(msg.get("k", 0))
			if _desync_first < 0:
				_desync_first = dk
			# «heal» — судья уже снимает снимок для нас: подтяжка незаметна, надписи нет
			if bool(msg.get("heal", false)):
				_log({"ev": "desync", "k": dk, "heal": true})
				_heal_wait = dk
			elif _desync_tick < 0:
				_heal_wait = -1   # судья снимок не снимет (велик) — ждать нечего, надпись сразу
				_desync_tick = dk
				_desync_judge = bool(msg.get("judge", false))
				_log({"ev": "desync", "k": _desync_tick})
				push_warning("NetSession: рассинхрон на тике %d" % _desync_tick)
		"snap":
			_on_snap_part(msg)
		"verdict":
			verdict = msg
			_log({"ev": "verdict", "v": msg})
			if String(msg.get("why", "")) == "forge":
				_on_forge_verdict(msg)
			_update_label()
		"pong":
			rtt_ms = Time.get_ticks_msec() - int(msg.get("ms", 0))
			# pong, пролежавший в сокете, пока у нас стоял кадр (загрузка поля), — замер заминки,
			# а не пути: в задержку ввода его не берём (01.10: так локально выходило 167 мс)
			if rtt_ms >= 0 and rtt_ms < 60000 and not _hitch:
				_relay_rtts.append(rtt_ms)
				_mstats.add_relay_rtt(rtt_ms)
				if _relay_rtts.size() > RTT_RING:
					_relay_rtts.pop_front()
		"left":
			_on_remote_left()
		"error":
			var code := String(msg.get("code", ""))
			# отказы внутри лобби («нет комнаты», «занята», «другая версия») не рвут соединение
			if code in ["no_ready", "void"]:
				if stage == Stage.LOADING or stage == Stage.PLAYING:
					_req_wait = -1.0
					_send_stats(code)   # «прерван/отменён без итога», а не «обрыв»
					# не загрузился вовремя сам — свой текст, а не «соперник отключился»
					_abort("Матч отменён: поле не загрузилось вовремя" if code == "no_ready"
						and not _ready_local else _error_text(code))
			elif code in ["no_room", "busy", "build", "full", "rate_limit"]:
				failed.emit(_error_text(code))
			else:
				_fail(_error_text(code))


## Ход соперника из любого пути: raw — его сырая строка (как пришла), via — «relay» / «udp»,
## mac — HMAC строки, приложенный соперником к UDP-пакету (через сервер — пусто).
func _on_remote_turn(msg: Dictionary, raw: String, via: String, mac := "") -> void:
	if side < 0:
		return
	var k := NetP2P._int(msg.get("k"), -1)
	var c: Variant = msg.get("c", [])
	if k < 0 or not (c is Array) or k > _applied_turn + REMOTE_WINDOW:
		return
	if via == "udp" and k > _relay_contig + RELAY_LAG_MAX + UDP_AHEAD_KEEP:
		return
	if via == "relay":
		_relay_contig = maxi(_relay_contig, k)
	if _p2p != null and k > _applied_turn - MATCH_KEEP:
		_reconcile(k, raw, via, mac)
	var theirs: Dictionary = _turns[1 - side]
	# ход приходит один раз; повтор или ход сильно впереди — не наш порядок, не перезаписываем
	if k <= _applied_turn or theirs.has(k):
		return
	# первые ходы у всех пустые (ретранслятор рвёт нарушителя; здесь — вторая страховка)
	theirs[k] = [] if k < DELAY_MIN else c
	_remote_have[k] = true
	while _remote_have.has(_remote_contig + 1):
		_remote_contig += 1
		_remote_have.erase(_remote_contig)


## Сверка путей: когда ход k пришёл и напрямую, и через ретранслятор, строки обязаны совпасть.
## Не совпали — соперник шлёт нам одно, а судье другое (честный игрок разошёлся бы с судьёй и был
## бы назван виновным). Применённый ход не отменить — выключаем прямой путь и сообщаем серверу.
func _reconcile(k: int, raw: String, via: String, mac: String) -> void:
	if p2p_mismatch >= 0:
		return
	if not _seen.has(k):
		_seen[k] = [raw, via, mac]
		if k > _applied_turn and not (_turns[1 - side] as Dictionary).has(k):
			first_via[via] = int(first_via.get(via, 0)) + 1
		return
	var prev: Array = _seen[k]
	if String(prev[1]) == via:
		return   # повтор тем же путём (избыточность UDP)
	_seen.erase(k)
	if String(prev[0]) != raw:
		# серверу — то, что пришло НАПРЯМУЮ, с HMAC соперника: ретранслятор сверит его ключом
		# соперника и строкой, которую тот прислал ему, — так подлог доказуем
		var udp: Array = prev if String(prev[1]) == "udp" else [raw, via, mac]
		_on_mismatch(k, String(udp[0]), String(udp[2]))


func _on_mismatch(k: int, udp_raw: String, udp_mac: String) -> void:
	p2p_mismatch = k
	push_warning("NetSession: ход %d соперника по прямому пути не совпал с сервером" % k)
	_log({"ev": "p2p_mismatch", "k": k, "raw": udp_raw, "mac": udp_mac})
	mismatch_report = {"t": "p2p_mismatch", "k": k, "raw": udp_raw, "mac": udp_mac}
	_send(mismatch_report)
	if _p2p != null:
		_p2p.fail("ход %d не совпал с сервером" % k)
	_sent_raw.clear()
	if path_mode != "":
		_fallback_to_relay()


## Сервер доказал подмену хода (HMAC подменщика на строке, отличной от посланной серверу):
## техническое поражение подменщику — у обоих клиентов он сдаётся, матч закрывается.
func _on_forge_verdict(msg: Dictionary) -> void:
	var cheat := NetP2P._int(msg.get("cheat"), -1)
	if not cheat in [0, 1] or forge_cheater >= 0:
		return
	forge_cheater = cheat
	_log({"ev": "forge_verdict", "cheat": cheat, "k": msg.get("k")})
	_send_stats("forge_loss" if cheat == side else "forge_win")
	if stage == Stage.PLAYING and _world != null and _world.phase == LegionWorld.Phase.BATTLE:
		_world.net_apply(cheat, {"type": "surrender"})
		_world.net_step()


# ── Подтяжка снимком судьи (docs/pvp/NET_LOCKSTEP.md, «Подтяжка») ──────────────

## Снимок → куски для пакетов {"t":"snap"} (судья). Пусто — снимок больше SNAP_PARTS_MAX кусков (или
## limit знаков: ключ судьи --snap-limit для проб «снимок слишком большой»).
static func snap_parts(snap: Dictionary, limit := SNAP_PART * SNAP_PARTS_MAX) -> PackedStringArray:
	var raw := var_to_bytes(snap)
	var packed := raw.compress(FileAccess.COMPRESSION_ZSTD)
	var text := "%d:%s" % [raw.size(), Marshalls.raw_to_base64(packed)]
	var out := PackedStringArray()
	if raw.size() > SNAP_RAW_MAX or text.length() > limit:
		return out
	for i in range(0, text.length(), SNAP_PART):
		out.append(text.substr(i, SNAP_PART))
	return out


## Куски → снимок (клиент). Пусто — кусок испорчен или размер вне пределов. Объекты bytes_to_var
## не создаёт (без allow_objects): снимок — только простые Variant.
static func snap_join(parts: PackedStringArray) -> Dictionary:
	var text := "".join(parts)
	var colon := text.find(":")
	if colon <= 0 or colon > 10 or not text.left(colon).is_valid_int():
		return {}
	var size := text.left(colon).to_int()
	if size <= 0 or size > SNAP_RAW_MAX:
		return {}
	var packed := Marshalls.base64_to_raw(text.substr(colon + 1))
	if packed.is_empty():
		return {}
	var raw := packed.decompress(size, FileAccess.COMPRESSION_ZSTD)
	if raw.size() != size:
		return {}
	var v: Variant = bytes_to_var(raw)
	return v if v is Dictionary else {}


## Кусок снимка от судьи (через ретранслятор, по порядку). Последний кусок — подтяжка, и ответ
## ретранслятору {"t":"healed"}: удалась ли и до какого тика досчитан бой.
func _on_snap_part(msg: Dictionary) -> void:
	var id := NetP2P._int(msg.get("id"), -1)
	var i := NetP2P._int(msg.get("i"), -1)
	var n := NetP2P._int(msg.get("n"), -1)
	var d: Variant = msg.get("d")
	if id < 0 or n < 1 or n > SNAP_PARTS_MAX or not (d is String) \
			or (d as String).length() > SNAP_PART:
		return
	if id != _snap_id:
		if i != 0:
			return
		_snap_id = id
		_snap_n = n
		_snap_parts = PackedStringArray()
	if i != _snap_parts.size() or n != _snap_n:
		return
	_snap_parts.append(d as String)
	if _snap_parts.size() < _snap_n:
		return
	var t0 := Time.get_ticks_usec()
	var snap := snap_join(_snap_parts)
	_snap_parts = PackedStringArray()
	var was := _world.net_tick if _world != null and is_instance_valid(_world) else -1
	var why := heal(snap) if not snap.is_empty() else "снимок не разобран"
	var at := _world.net_tick if _world != null and is_instance_valid(_world) else -1
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	_log({"ev": "heal", "id": id, "ok": why == "", "why": why, "k": int(msg.get("k", -1)),
		"from": was, "at": at, "ms": snappedf(ms, 0.1), "parts": n})
	_send({"t": "healed", "id": id, "ok": why == "", "at": at})
	if why != "":
		push_warning("NetSession: снимок судьи не принят — %s" % why)
		_heal_unwait()
	else:
		_heal_wait = -1


## Подтяжки не будет (матч кончился раньше снимка, снимок не принят): расхождение — как без неё,
## надпись «разошёлся с сервером» и итог по счёту судьи.
func _heal_unwait() -> void:
	if _heal_wait >= 0 and _desync_tick < 0:
		_desync_tick = _heal_wait
		_desync_judge = true
		push_warning("NetSession: рассинхрон на тике %d, подтяжки не было" % _desync_tick)
	_heal_wait = -1


## Подтянуть свой бой к снимку судьи: загрузить снимок (тик K судьи) на месте, без перезапуска мира,
## и досчитать до своего тика своими применёнными ходами (снимок старше — судья отставал или снимок
## шёл по сети). Снимок новее своего тика — бой просто перескакивает вперёд: ходы до K уже в снимке.
## "" — подтянут; иначе причина отказа (мир не тронут).
func heal(snap: Dictionary) -> String:
	var why := _heal_refusal(snap)
	if why != "":
		return why
	var k := int((snap["world"] as Dictionary)["net_tick"])
	var now := _world.net_tick
	var first := (k + TURN - 1) / TURN   # первый ход, которого в снимке ещё нет
	var reg := _world.load_snapshot(snap)
	if not reg.errors.is_empty() or not reg.misses.is_empty():
		_log({"ev": "heal_load", "errors": Array(reg.errors), "misses": Array(reg.misses).slice(0, 8)})
	_applied_turn = first - 1
	if k < now:
		while _world.net_tick < now and _world.net_can_step():
			var tick := _world.net_tick
			if tick % TURN == 0 and tick / TURN > _applied_turn:
				_applied_turn = tick / TURN
				var h: Array = _hist[_applied_turn]
				for s in 2:
					for raw: Variant in h[s]:
						var cmd := NetCodec.decode(raw)
						if not cmd.is_empty():
							_world.net_apply(s, cmd)
			_world.net_step()
	else:
		for s in 2:
			var turns: Dictionary = _turns[s]
			for t: int in turns.keys():
				if t <= _applied_turn:
					turns.erase(t)
	# ходы соперника до применённого уже в бою (в снимке или в журнале): подтверждение для UDP-пакета
	# сдвигаем к ним. Иначе после перескока вперёд _remote_contig застревал навсегда — ходы ≤ applied
	# отсекаются в _on_remote_turn раньше, чем помечаются, — и в пакет уходили только старые ходы
	_remote_contig = maxi(_remote_contig, _applied_turn)
	for t: int in _remote_have.keys():
		if t <= _remote_contig:
			_remote_have.erase(t)
	while _remote_have.has(_remote_contig + 1):
		_remote_contig += 1
		_remote_have.erase(_remote_contig)
	_desync_tick = -1
	heals += 1
	return ""


## Почему снимок нельзя принять ("" — можно); мир при этом не трогается.
func _heal_refusal(snap: Dictionary) -> String:
	if stage != Stage.PLAYING or _world == null or not is_instance_valid(_world):
		return "матч не идёт"
	# B-377 (1): закончившему матч снимок не нужен — иначе мир перезапустился бы (SnapWorld.prepare)
	# и игрок увидел бы второй экран итога
	if _world.phase != LegionWorld.Phase.BATTLE:
		return "бой уже кончился"
	var wd: Variant = snap.get("world")
	if int(snap.get("v", -1)) != NetSnap.VERSION or not (wd is Dictionary) \
			or not ((wd as Dictionary).get("cfg") is Dictionary) \
			or int((wd as Dictionary).get("net_tick", -1)) < 0:
		return "снимок версии %s (у нас %d) или без мира и тика" % [str(snap.get("v")),
			NetSnap.VERSION]
	# только на месте: другой бой (карта, сид) снимок перезапустил бы с экраном загрузки
	var other := SnapWorld.mismatch(_world, (wd as Dictionary)["cfg"])
	if other != "":
		return "другой бой: " + other
	var k := int((wd as Dictionary)["net_tick"])
	if k < _world.net_tick:
		for t in range((k + TURN - 1) / TURN, _applied_turn + 1):
			if not _hist.has(t):
				return "нет хода %d для досчёта с тика %d до %d" % [t, k, _world.net_tick]
	return ""


# ── Прямое соединение (NetP2P) ───────────────────────────────────────────────

func _start_p2p(token: String) -> void:
	_stop_p2p()
	p2p_mismatch = -1
	forge_cheater = -1
	mismatch_report = {}
	_close_reason = ""
	_relay_contig = -1
	_hold_stall = 0.0
	_req_wait = -1.0
	_hold_q.clear()
	first_via = {"udp": 0, "relay": 0}
	_seen.clear()
	_remote_have.clear()
	_remote_contig = -1
	_remote_relay_rtt = -1
	_remote_nat = ""
	_forged = false
	_p2p_t0 = Time.get_ticks_msec()
	_ping_t = PING_EVERY   # замер RTT до сервера — сразу, к кандидатам
	_cand_due = true   # «cand» уходит всегда (пустой — без прямого пути): в нём и RTT до сервера
	# токен комнаты — 32 hex от ретранслятора; без него прямой путь не включаем. Через Steam и у
	# хозяина Steam-игры (канал в своём процессе) пробивать нечего — реле Valve уже прямой путь.
	if not direct_enabled or token.length() < 32 or not token.is_valid_hex_number() \
			or _chan == null or not _chan.direct_allowed():
		return
	_p2p = NetP2P.new()
	_p2p.dbg_off = dbg_udp_off
	_p2p.dbg_loss = dbg_udp_loss
	_p2p.allow_loopback = dbg_loopback
	if not _p2p.start(token, side, use_stun, _p2p_t0):
		_log({"ev": "p2p", "fail": _p2p.fail_why})


func _stop_p2p() -> void:
	if _p2p != null:
		_p2p.close()
	_p2p = null
	_sent_raw.clear()


func _send_cand(cands: Array, nat: String) -> void:
	_send({"t": "cand", "c": cands, "rtt": _relay_rtt(true), "nat": nat})
	_log({"ev": "cand_sent", "n": cands.size(), "nat": nat})


func _on_cand(msg: Dictionary) -> void:
	_remote_relay_rtt = clampi(NetP2P._int(msg.get("rtt"), -1), -1, 60000)
	_remote_nat = String(msg.get("nat", "")).left(16) if msg.get("nat") is String else ""
	var c: Variant = NetP2P.clean_cands(msg.get("c"))
	_log({"ev": "cand_got", "n": (c as Array).size() if c is Array else -1, "nat": _remote_nat})
	if _p2p != null:
		_p2p.set_remote(c as Array if c is Array else [], Time.get_ticks_msec())


## Кандидаты уходят, когда собраны И есть хоть один замер RTT до сервера (соперник считает по нему
## задержку пути через сервер; без замера ушло бы пессимистичное значение по умолчанию) — или
## когда ждать замера дольше нельзя.
func _tick_cand() -> void:
	if not _cand_due or (_p2p != null and not _p2p.gathered()):
		return
	if _relay_rtts.is_empty() and Time.get_ticks_msec() - _p2p_t0 < CAND_RTT_WAIT_MS:
		return
	_cand_due = false
	if _p2p == null:
		_send_cand([], "off")
	elif _p2p.state == NetP2P.State.FAILED:
		_send_cand([], "fail")
	else:
		_send_cand(_p2p.local_candidates(), _p2p.nat)


func _tick_p2p() -> void:
	_tick_cand()
	if _p2p == null:
		return
	var now := Time.get_ticks_msec()
	var was := _p2p.state
	var got := _p2p.poll(now)
	if _p2p.state != was:
		_log({"ev": "p2p", "state": NetP2P.State.keys()[_p2p.state], "why": _p2p.fail_why,
			"rtt": _p2p.rtt_ms, "nat": _p2p.nat, "path": _p2p.chosen_key != ""})
	var j := JSON.new()
	for item in got:
		var raw := String(item["raw"])
		if j.parse(raw) != OK or not (j.data is Dictionary):
			continue
		var d: Dictionary = j.data
		if d.get("t") == "in":
			_on_remote_turn(d, raw, "udp", String(item["mac"]))
	if _p2p.is_active():
		# соперник подтвердил наши ходы до remote_ack — больше их напрямую не повторяем
		while not _sent_raw.is_empty() and int(_sent_raw.keys()[0]) <= _p2p.remote_ack:
			_sent_raw.erase(_sent_raw.keys()[0])
		if stage == Stage.PLAYING and now - _udp_sent_at >= UDP_RESEND_MS:
			_send_udp_turns()
	elif path_mode == "p2p":
		_fallback_to_relay()


## Прямой путь пропал (или выключен подлогом) посреди боя — дальше ретранслятор. Задержку сразу
## поднимаем до нужной серверному пути (расти можно), а не ждём опозданий: прямой путь давал 2 хода,
## через сервер их может понадобиться 7.
func _fallback_to_relay() -> void:
	if _mstats.fallback_tick < 0 and _world != null and is_instance_valid(_world):
		_mstats.fallback_tick = _world.net_tick
	path_mode = "relay"
	delay = maxi(delay, delay_for(_oneway_ms(true)))
	_delay_start = delay
	_log({"ev": "fallback", "delay": delay})
	_report_path()


## Сводка «вручную» — пробам, которые останавливают бой на тике, не доводя его до конца.
func send_stats(end: String) -> void:
	_send_stats(end)

## Сводка матча — один раз за матч, пока сокет жив: ретранслятор пишет её одной строкой в
## relay.log (docs/pvp/NET_LOCKSTEP.md, «Сводка матча»).
func _send_stats(end: String) -> void:
	if _mstats.sent or not is_online():
		return
	_mstats.sent = true
	var pk := _mstats.packet(self, end)
	_send(pk)
	_log({"ev": "stats", "v": pk})


## Путь, его задержка и задержка ввода — в журнал игрока и ретранслятору (тот пишет в relay.log).
func _report_path() -> void:
	var nat := _p2p.nat if _p2p != null else "off"
	var ms := int(round(_oneway_ms(true)))
	var entry := {"t": "path", "mode": path_mode, "rtt": ms, "delay": delay, "nat": nat}
	_send(entry)
	_log({"ev": "path", "mode": path_mode, "oneway_ms": ms, "delay": delay, "nat": nat,
		"remote_nat": _remote_nat, "p2p_rtt": _p2p.rtt_ms if _p2p != null else -1,
		"relay_rtt": _relay_rtt(true), "remote_relay_rtt": _remote_relay_rtt,
		"why": _p2p.fail_why if _p2p != null else ""})


func _on_remote_left() -> void:
	_remote_left = true
	_log({"ev": "left"})
	if stage == Stage.PLAYING or stage == Stage.LOADING:
		_send_stats("opp_left")
	if stage == Stage.PLAYING and _world != null and forge_cheater < 0:
		# соперника больше нет — локально засчитываем его сдачу (согласовывать уже не с кем)
		_world.net_apply(1 - side, {"type": "surrender"})
		_world.net_step()
	elif stage == Stage.LOADING:
		_abort("Соперник отключился")
		return
	_update_label()


func _on_closed() -> void:
	var was := stage
	# код и причина закрытия — в журнал и пробам (разбор «связь потеряна»)
	last_close = "%d %s" % [_chan.close_code(), _chan.close_reason()]
	var kind := _chan.kind()
	_log({"ev": "ws_closed", "code": _chan.close_code(), "reason": _chan.close_reason(),
		"kind": kind})
	_chan = null
	var lost := "Связь с сервером потеряна" if kind == "ws" else "Связь с соперником потеряна"
	if was == Stage.CONNECTING:
		failed.emit("Не удалось подключиться к серверу" if kind == "ws"
			else "Не удалось соединиться с хозяином игры")
	elif (was == Stage.PLAYING and not _remote_left) or was == Stage.LOADING:
		_log({"ev": "closed"})
		_abort(_close_reason if _close_reason != "" else lost)
		return
	elif was == Stage.LOBBY:
		failed.emit(_close_reason if _close_reason != "" else lost)
	if was != Stage.PLAYING:
		stage = Stage.IDLE


## Копия ходов соперника на сервер не приходит дольше RELAY_HOLD_ABORT — матч без итога у обоих
## (не сдача): серверу «void» (он сверит разрыв ходов и закроет комнату), себе — в лобби.
func _request(what: String) -> void:
	_log({"ev": "request", "what": what, "relay_contig": _relay_contig, "applied": _applied_turn})
	_send({"t": what})
	_req_wait = 0.0


## Когда выдать пакет сервера (пробы: задержка и заминка приёма; без отладки — сразу).
func _dbg_release() -> int:
	var now := Time.get_ticks_msec()
	if dbg_down_stall_tick >= 0 and _down_stall_end == 0 and stage == Stage.PLAYING \
			and _world != null and _world.net_tick >= dbg_down_stall_tick:
		_down_stall_end = now + dbg_down_stall_ms
	var r := maxi(now + dbg_down_lat, _down_stall_end)
	return maxi(r, int(_dq[-1][0])) if not _dq.is_empty() else r


## Проба гонки «void»: соперник встал (его ходы не идут) dbg_race_ms — сбросить придержанное.
func _dbg_race() -> void:
	if dbg_race_ms <= 0 or stage != Stage.PLAYING or _hold_q.is_empty():
		return
	var now := Time.get_ticks_msec()
	if _remote_contig > _race_rc:
		_race_rc = _remote_contig
		_race_t = now
	elif now - _race_t >= dbg_race_ms:
		_log({"ev": "dbg_race_flush", "n": _hold_q.size()})
		for e: Array in _hold_q:
			e[0] = 0
		dbg_hold_from = -1
		dbg_race_ms = 0


## Ждём ответа на запрос: нет его REQUEST_REPLY_WAIT — связь мертва, рвём её как обрыв.
func _tick_request(delta: float) -> void:
	if _req_wait < 0.0:
		return
	_req_wait += delta
	if _req_wait > REQUEST_REPLY_WAIT and _chan != null:
		_log({"ev": "request_timeout"})
		_req_wait = -1.0
		_chan.close(1000, "no reply")


## Сервер отклонил запрос — без последствий: ждём/играем дальше, следующий — не раньше чем через
## RELAY_HOLD_ABORT (простой отсчитывается заново).
func _on_request_denied(what: String) -> void:
	_log({"ev": "request_denied", "what": what})
	_req_wait = -1.0
	_hold_stall = 0.0
	_ready_wait = 0.0


func _abort(text: String) -> void:
	last_error = text
	_send_stats("abort")
	_detach_world()
	_stop_p2p()
	room_code = ""
	side = -1
	stage = Stage.LOBBY if is_online() else Stage.IDLE
	if stage == Stage.LOBBY:
		_send({"t": "leave"})
	aborted.emit(text)


func _fail(text: String) -> void:
	failed.emit(text)
	close()


static func _error_text(code: String) -> String:
	match code:
		"no_room":
			return "Нет такой комнаты — проверьте код"
		"busy":
			return "В комнате уже двое"
		"build":
			return "У соперника другая версия игры"
		"proto":
			return "Версия сервера не совпадает с игрой"
		"full":
			return "Сервер занят — попробуйте позже"
		"rate_limit":
			return "Слишком частые запросы — попробуйте через несколько секунд"
		"idle_timeout":
			return "Ожидание в лобби истекло — подключитесь снова"
		"no_ready":
			return "Соперник не загрузил поле — матч отменён"
		"void":
			return "Матч прерван без итога: ходы не доходили до сервера"
	return "Ошибка сервера: %s" % code


func _send(msg: Dictionary) -> void:
	if _chan != null:
		_chan.send_text(JSON.stringify(msg))


# ── Журнал (user://net_logs/) — для повтора боя на одной машине при рассинхроне ─────────

func _open_log() -> void:
	DirAccess.make_dir_recursive_absolute("user://net_logs")
	var stamp := Time.get_datetime_string_from_system().replace(":", "-")
	_log_file = FileAccess.open("user://net_logs/%s_%s_side%d.jsonl" % [stamp, room_code, side],
		FileAccess.WRITE)
	_log({"ev": "start", "build": BUILD, "room": room_code, "map": map_id, "seed": seed_value,
		"side": side, "turn": TURN, "delay_min": DELAY_MIN, "direct": _p2p != null})


func _log(entry: Dictionary) -> void:
	if _log_file != null:
		_log_file.store_line(JSON.stringify(entry))
