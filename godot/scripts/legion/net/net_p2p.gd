class_name NetP2P
extends RefCounted
##
## Прямой UDP-путь между двумя клиентами онлайн-«Схватки» (docs/pvp/NET_LOCKSTEP.md, «Прямое
## соединение»). Ретранслятор знакомит (кандидаты адресов идут через него пакетом «cand»), дальше
## обе стороны одновременно шлют пробы на все адреса соперника — так NAT каждой стороны открывает
## дыру навстречу (пробивка). Получилось — ходы идут ещё и напрямую, кто пришёл первым, тот и
## применяется; не получилось — всё как раньше, через ретранслятор. Ретранслятор ходы получает
## всегда: судья и сверка путей держатся на нём.
##
## Свой UDP на PacketPeerUDP, не WebRTC: WebRTC — это GDExtension под Windows и Mac, а TURN-сервера
## у нас нет, то есть шанс пробивки тот же. Сокет несвязанный (bind(0)): один сокет и для STUN, и
## для проб, и для ходов — внешний порт NAT привязан именно к нему.
##
## Всё, что приходит на сокет, — недоверенное: размер, ASCII, JSON, токен комнаты, своя сторона,
## адрес. Мусор отбрасывается молча (никаких сообщений в лог на каждый пакет).
##

enum State { OFF, GATHER, WAIT_REMOTE, PUNCH, ACTIVE, FAILED }

## Бесплатные публичные STUN. Два разных — чтобы отличить симметричный NAT (разные внешние порты
## для разных адресатов: пробивка с такой стороной почти наверняка не выйдет).
const STUN_SERVERS := [["stun.l.google.com", 19302], ["stun.cloudflare.com", 3478]]
## UDP теряется — запрос повторяем; дольше STUN_TIMEOUT не ждём: LAN-кандидаты уже есть, а
## пробивка должна уложиться в загрузку поля.
const STUN_RETRY_MS := 250
const STUN_TIMEOUT_MS := 1500
## Кандидаты соперника идут через ретранслятор; не пришли за это время — соперник без прямого пути.
const REMOTE_WAIT_MS := 4000
## Пробы: 16 в секунду на каждый адрес — дыры в NAT открываются с обеих сторон почти сразу, а
## трафик ничтожный (8 адресов × ~90 байт).
const PROBE_EVERY_MS := 60
## Сколько всего пробовать: бой не ждёт пробивку дольше (ТЗ координатора: ~5 с).
const PUNCH_TIMEOUT_MS := 5000
## После первого ответа ещё столько ждём ответов с других адресов — выбрать самый быстрый
## (LAN против внешнего адреса) и набрать замеры RTT.
const SETTLE_MS := 300
## В бою держим дыру в NAT открытой и меряем RTT (NAT забывает молчащий путь за десятки секунд).
const KEEPALIVE_MS := 500
## Ничего не слышно столько — прямой путь умер (NAT сменил порт, сеть ушла): дальше ретранслятор.
const DEAD_MS := 3000
## Больше кандидатов не бывает у честного клиента (внешний + несколько сетевых карт).
const MAX_CANDS := 8
## Потолок UDP-пакета: меньше типичного MTU 1500 с запасом на заголовки VPN/PPPoE — без
## фрагментации, которую часть NAT режет.
const PACKET_MAX := 1200
## За один кадр читаем не больше — флуд на сокет не повесит игру.
const MAX_PACKETS_PER_POLL := 256
const RTT_SAMPLES := 16
## Опрос позже этого после прошлого — у нас стоял кадр (загрузка поля): RTT в нём не замер пути.
const HITCH_MS := 100
## Дольше этого RTT — не ответ на нашу пробу (или подделка времени).
const RTT_MAX_MS := 4000
const KINDS := ["stun", "lan"]
## Слова в имени виртуальных адаптеров (Windows, Mac, Linux): их адреса не кандидаты.
const VIRTUAL_IF := ["vethernet", "hyper-v", "wsl", "virtualbox", "vmware", "docker", "tailscale",
	"openvpn", "wireguard", "tap-", "tun", "utun", "loopback", "vbox", "virbr", "zerotier",
	"hamachi", "bridge"]
## Длина HMAC хода в hex (16 байт).
const MAC_HEX := 32
## Адресов соперника, с которых принимаем пакеты, не больше: честному хватает кандидатов и пары
## адресов от NAT; без потолка соперник с токеном (1500 портов) раздувал таблицу и наши ответы.
const VERIFIED_MAX := 16

var state := State.OFF
var token := ""
var side := -1
## Тип NAT по STUN: cone (один внешний порт для всех), symmetric, one (ответил один сервер),
## none (STUN не ответил), off (не спрашивали).
var nat := "off"
var fail_why := ""
## RTT выбранного пути: для строки «Связь» (сглаженный) и для задержки ввода (верхний замер).
var rtt_ms := -1
var rtt_hi := -1
var chosen_key := ""
## Номер последнего подряд хода, который соперник подтвердил (из его пакетов ходов).
var remote_ack := -1
## Отладка проб: глушить UDP целиком, терять процент входящих пакетов; разрешить 127.0.0.1
## (два клиента на одной машине; в живой игре loopback не шлём и не принимаем).
var dbg_off := false
var allow_loopback := false
var dbg_loss := 0
var stats := {"sent": 0, "recv": 0, "junk": 0, "turns_in": 0}

var _udp: PacketPeerUDP
var _rng := RandomNumberGenerator.new()
var _stun: Array[Dictionary] = []
var _stun_addrs: Array[Dictionary] = []
var _local: Array[Dictionary] = []
var _remote: Array[Dictionary] = []
var _remote_set := false
var _t0 := 0
var _gathered_at := -1
var _punch_t0 := 0
var _probe_t := 0
var _confirmed_at := -1
var _peer_ok := false
## «ip:port» → true: адреса, с которых пришёл пакет с верным токеном (только с них берём ходы).
var _verified: Dictionary = {}
var _samples: Dictionary = {}
var _chosen_ip := ""
var _chosen_port := 0
var _last_send := 0
var _last_heard := 0
var _last_poll := 0
var _hitch := false


func start(room_token: String, my_side: int, use_stun: bool, now: int) -> bool:
	close()
	token = room_token
	side = my_side
	_rng.randomize()
	_udp = PacketPeerUDP.new()
	if _udp.bind(0) != OK:
		_udp = null
		_fail("не открыть UDP-сокет")
		return false
	_t0 = now
	_last_poll = now
	state = State.GATHER
	_local = _lan_candidates(_udp.get_local_port(), allow_loopback)
	if use_stun:
		nat = "none"
		for s: Array in STUN_SERVERS:
			_stun.append({"host": s[0], "port": s[1], "rid": IP.resolve_hostname_queue_item(
				String(s[0]), IP.TYPE_IPV4), "ip": "", "txid": NetStun.new_txid(_rng),
				"sent": -STUN_RETRY_MS, "done": false})
	return true


func close() -> void:
	for s in _stun:
		if int(s["rid"]) >= 0 and not bool(s["done"]) and String(s["ip"]) == "":
			IP.erase_resolve_item(int(s["rid"]))
	_stun.clear()
	_stun_addrs.clear()
	if _udp != null:
		_udp.close()
	_udp = null
	state = State.OFF
	_remote.clear()
	_remote_set = false
	_verified.clear()
	_samples.clear()
	_confirmed_at = -1
	_peer_ok = false
	chosen_key = ""


func is_active() -> bool:
	return state == State.ACTIVE


## Решено ли, каким путём играть (сессия не начинает бой, пока пробивка идёт).
func decided() -> bool:
	return state in [State.OFF, State.ACTIVE, State.FAILED]


func gathered() -> bool:
	return state != State.GATHER


func local_candidates() -> Array:
	var out: Array = []
	for c in _stun_addrs:
		out.append({"ip": c["ip"], "port": c["port"], "kind": "stun"})
		if nat == "cone":
			break   # оба сервера дали один адрес — второй раз его слать незачем
	for c in _local:
		if out.size() >= MAX_CANDS:
			break
		out.append(c)
	return out


## Кандидаты соперника (уже проверенные clean_cands). Пусто — у соперника прямое выключено.
func set_remote(cands: Array, now: int) -> void:
	if state in [State.OFF, State.FAILED, State.ACTIVE] or _remote_set:
		return
	_remote_set = true
	_remote.clear()
	for c: Variant in cands:
		# 127.0.0.1 соперника в живой игре — это наша же машина: пробы ушли бы в чужие процессы
		if c is Dictionary and (allow_loopback or not is_loopback(String((c as Dictionary)["ip"]))):
			_remote.append(c as Dictionary)
	if _remote.is_empty():
		_fail("у соперника прямое соединение выключено")
		return
	if state == State.WAIT_REMOTE:
		_begin_punch(now)


func fail(why: String) -> void:
	_fail(why)


## Опрос сокета: STUN, пробы, ответы. Возвращает ходы соперника, пришедшие напрямую:
## [{"raw": сырая строка, "mac": её HMAC от соперника (для жалобы на подлог)}].
func poll(now: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if _udp == null or state in [State.OFF, State.FAILED]:
		return out
	_hitch = now - _last_poll > HITCH_MS
	_last_poll = now
	_tick_stun(now)
	var n := 0
	while _udp != null and _udp.get_available_packet_count() > 0 and n < MAX_PACKETS_PER_POLL:
		n += 1
		var data := _udp.get_packet()
		var ip := _udp.get_packet_ip()
		var port := _udp.get_packet_port()
		if dbg_off or (dbg_loss > 0 and _rng.randi_range(1, 100) <= dbg_loss):
			continue
		if NetStun.looks_like_stun(data):
			_on_stun(data)
			continue
		var msg := unpack(token, data)
		if msg.is_empty() or int(msg["sd"]) == side:
			stats["junk"] = int(stats["junk"]) + 1
			continue
		stats["recv"] = int(stats["recv"]) + 1
		_on_packet(msg, ip, port, now, out)
	match state:
		State.GATHER:
			if _gather_done(now):
				_gathered_at = now
				state = State.WAIT_REMOTE
				if _remote_set:
					_begin_punch(now)
		State.WAIT_REMOTE:
			if now - _gathered_at > REMOTE_WAIT_MS:
				_fail("кандидаты соперника не пришли")
		State.PUNCH:
			_tick_punch(now)
		State.ACTIVE:
			if now - _last_heard > DEAD_MS:
				_fail("прямой путь пропал")
			elif now - _last_send >= KEEPALIVE_MS:
				_send_to(_chosen_ip, _chosen_port, {"y": "pr", "ts": now, "ok": 1})
	return out


## Свои ходы, ещё не подтверждённые соперником, + номер последнего подряд полученного его хода.
## macs[i] — HMAC строки raws[i] своим ключом стороны (ретранслятор по нему докажет подлог).
func send_turns(raws: Array, macs: Array, ack: int, now: int) -> void:
	if state != State.ACTIVE:
		return
	var data := pack_turns(token, side, ack, raws, macs, PACKET_MAX)
	if data.size() > 0:
		_put(_chosen_ip, _chosen_port, data)
		_last_send = now


# ── Пакеты (статические — их проверяет tests/net_p2p_test.gd) ───────────────────────────────

static func pack(room_token: String, my_side: int, fields: Dictionary) -> PackedByteArray:
	var d := fields.duplicate()
	d["p"] = room_token
	d["sd"] = my_side
	return JSON.stringify(d).to_ascii_buffer()


## Пакет ходов: столько своих сырых строк (старые первыми) с их HMAC, сколько влезает в потолок.
## Ход, что не влезает сам по себе (длинный штрих), пропускается — его донесёт ретранслятор.
static func pack_turns(room_token: String, my_side: int, ack: int, raws: Array, macs: Array,
		cap: int) -> PackedByteArray:
	var base := {"p": room_token, "sd": my_side, "y": "tu", "a": ack, "r": [], "m": []}
	var size := JSON.stringify(base).length()
	var take: Array[String] = []
	var take_m: Array[String] = []
	for i in raws.size():
		var s := String(raws[i])
		var m := String(macs[i]) if i < macs.size() else ""
		var add := JSON.stringify(s).length() + JSON.stringify(m).length() \
			+ (2 if not take.is_empty() else 0)
		if size + add > cap:
			continue
		take.append(s)
		take_m.append(m)
		size += add
	base["r"] = take
	base["m"] = take_m
	var out := JSON.stringify(base).to_ascii_buffer()
	return out if out.size() <= cap else PackedByteArray()


## Разбор входящего: пусто — мусор (размер, не ASCII, не JSON-объект, чужой токен, кривые поля).
static func unpack(room_token: String, data: PackedByteArray) -> Dictionary:
	if data.size() < 2 or data.size() > PACKET_MAX or data[0] != 0x7B or room_token == "":
		return {}
	for b in data:
		if b < 0x20 or b > 0x7E:
			return {}
	var j := JSON.new()
	if j.parse(data.get_string_from_ascii()) != OK or not (j.data is Dictionary):
		return {}
	var d: Dictionary = j.data
	if not (d.get("p") is String) or String(d["p"]) != room_token:
		return {}
	var sd := _int(d.get("sd"), -1)
	var y: Variant = d.get("y")
	if not sd in [0, 1] or not (y is String) or not String(y) in ["pr", "pa", "tu"]:
		return {}
	var out := {"y": String(y), "sd": sd, "ts": _int(d.get("ts"), -1),
		"ok": _int(d.get("ok"), 0) == 1}
	if String(y) == "tu":
		var r: Variant = d.get("r")
		if not (r is Array):
			return {}
		# HMAC — параллельным массивом; кривой или отсутствующий — пустая строка (жалобу с ним
		# ретранслятор отклонит, а ход всё равно применяется: проверить его мы не можем)
		var m: Variant = d.get("m")
		var ms: Array = m if m is Array else []
		var raws: Array[String] = []
		var macs: Array[String] = []
		for i in (r as Array).size():
			var s: Variant = (r as Array)[i]
			if not (s is String):
				continue
			raws.append(String(s))
			var mi: Variant = ms[i] if i < ms.size() else ""
			macs.append(String(mi) if mi is String and String(mi).length() == MAC_HEX
				and String(mi).is_valid_hex_number() else "")
		out["r"] = raws
		out["m"] = macs
		out["a"] = _int(d.get("a"), -1)
	return out


## Кандидаты из пакета «cand» (их проверяют и ретранслятор, и клиент): не больше MAX_CANDS, ip —
## настоящий IPv4/IPv6 без широковещания и мультикаста, порт 1..65535. null — пакет кривой.
static func clean_cands(v: Variant) -> Variant:
	if not (v is Array) or (v as Array).size() > MAX_CANDS:
		return null
	var out: Array = []
	for c: Variant in v:
		if not (c is Dictionary):
			return null
		var d: Dictionary = c
		var ip: Variant = d.get("ip")
		var port := _int(d.get("port"), 0)
		var kind: Variant = d.get("kind")
		if not (ip is String) or String(ip).length() > 45 or not String(ip).is_valid_ip_address():
			return null
		if port < 1 or port > 65535 or not (kind is String) or not String(kind) in KINDS:
			return null
		if not ":" in String(ip):
			var first := String(ip).get_slice(".", 0).to_int()
			if first == 0 or first >= 224:
				return null
		out.append({"ip": String(ip), "port": port, "kind": String(kind)})
	return out


static func is_loopback(ip: String) -> bool:
	return ip.begins_with("127.") or ip == "::1"


## HMAC-SHA256 сырой строки хода ключом стороны, первые 16 байт hex. Ключ знают только сторона
## и ретранслятор: соперник проверить не может, но предъявить серверу — может (доказательство
## подлога). 128 бит — с запасом для подделки за время матча и вдвое короче в UDP-пакете.
static func mac(key: PackedByteArray, raw: String) -> String:
	if key.is_empty():
		return ""
	var h := HMACContext.new()
	h.start(HashingContext.HASH_SHA256, key)
	var data := raw.to_utf8_buffer()
	if not data.is_empty():   # пустой update движок считает ошибкой
		h.update(data)
	return h.finish().slice(0, MAC_HEX / 2).hex_encode()


## Целое из JSON: только конечное целое разумной величины; иначе def.
static func _int(v: Variant, def: int) -> int:
	if v is int:
		return v
	if v is float and is_finite(v) and absf(v) < 1.0e12 and v == floorf(v):
		return int(v)
	return def


# ── Внутреннее ──────────────────────────────────────────────────────────────

## Свои адреса для соперника из той же сети (на «свой же внешний адрес» роутеры часто не пускают —
## hairpin). Только IPv4 частных сетей. Не раскрываем: адреса Tailscale (100.64/10 — по ним
## соперник узнал бы о нашей личной сети), link-local 169.254 (мусор виртуальных адаптеров);
## 127.0.0.1 — только в пробах на одной машине (loopback); адреса виртуальных адаптеров
## (Hyper-V/WSL «vEthernet», VPN, точка доступа Windows — «…* N» в имени) — соперник до них не
## достанет, а пробы на них — лишний трафик и лишнее раскрытие.
static func _lan_candidates(port: int, loopback: bool) -> Array[Dictionary]:
	var lan: Array[Dictionary] = []
	if loopback:
		lan.append({"ip": "127.0.0.1", "port": port, "kind": "lan"})
	var ranked: Array = []
	for a: String in _physical_addresses():
		if ":" in a or not a.is_valid_ip_address():
			continue
		var o := a.split(".")
		var o0 := o[0].to_int()
		var o1 := o[1].to_int()
		var rank := -1
		if o0 == 192 and o1 == 168:
			rank = 0
		elif o0 == 10:
			rank = 1
		elif o0 == 172 and o1 >= 16 and o1 <= 31:
			rank = 2
		if rank >= 0:
			ranked.append([rank, a])
	ranked.sort_custom(func(x: Array, y: Array) -> bool: return int(x[0]) < int(y[0]))
	for r: Array in ranked:
		if lan.size() >= MAX_CANDS - 2:   # место для двух STUN-адресов
			break
		lan.append({"ip": String(r[1]), "port": port, "kind": "lan"})
	return lan


## Адреса сетевых карт, кроме виртуальных — по имени адаптера (IP.get_local_interfaces).
static func _physical_addresses() -> Array[String]:
	var out: Array[String] = []
	for itf: Dictionary in IP.get_local_interfaces():
		var name := (String(itf.get("friendly", "")) + " " + String(itf.get("name", ""))).to_lower()
		if "*" in name or VIRTUAL_IF.any(func(w: String) -> bool: return w in name):
			continue
		for a: Variant in itf.get("addresses", []):
			out.append(String(a))
	return out


func _tick_stun(now: int) -> void:
	for s in _stun:
		if bool(s["done"]):
			continue
		if String(s["ip"]) == "":
			var rid := int(s["rid"])
			var st := IP.get_resolve_item_status(rid)
			if st == IP.RESOLVER_STATUS_WAITING:
				continue
			s["ip"] = IP.get_resolve_item_address(rid) if st == IP.RESOLVER_STATUS_DONE else ""
			IP.erase_resolve_item(rid)
			s["rid"] = -1
			if String(s["ip"]) == "":
				s["done"] = true
				continue
		if now - int(s["sent"]) >= STUN_RETRY_MS and now - _t0 < STUN_TIMEOUT_MS:
			s["sent"] = now
			_put(String(s["ip"]), int(s["port"]), NetStun.make_request(s["txid"]))


func _on_stun(data: PackedByteArray) -> void:
	for s in _stun:
		if bool(s["done"]):
			continue
		var r := NetStun.parse_response(data, s["txid"])
		if r.is_empty():
			continue
		s["done"] = true
		_stun_addrs.append(r)
		if _stun_addrs.size() == 1:
			nat = "one"
		else:
			var a: Dictionary = _stun_addrs[0]
			nat = "cone" if a["ip"] == r["ip"] and a["port"] == r["port"] else "symmetric"
		return


func _gather_done(now: int) -> bool:
	if now - _t0 >= STUN_TIMEOUT_MS:
		return true
	for s in _stun:
		if not bool(s["done"]):
			return false
	return true


func _begin_punch(now: int) -> void:
	state = State.PUNCH
	_punch_t0 = now
	_probe_t = now - PROBE_EVERY_MS


func _tick_punch(now: int) -> void:
	if now - _probe_t >= PROBE_EVERY_MS:
		_probe_t = now
		var ok := 1 if _confirmed_at >= 0 else 0
		for c in _remote:
			_send_to(String(c["ip"]), int(c["port"]), {"y": "pr", "ts": now, "ok": ok})
	if _confirmed_at >= 0 and _peer_ok and now - _confirmed_at >= SETTLE_MS:
		_choose(now)
	elif now - _punch_t0 > PUNCH_TIMEOUT_MS:
		_fail("пробивка не удалась за %d с" % (PUNCH_TIMEOUT_MS / 1000))


## Из адресов, откуда пришёл ответ на пробу, — с наименьшим RTT.
func _choose(now: int) -> void:
	var best := ""
	var best_rtt := RTT_MAX_MS + 1
	for key: String in _samples:
		var m := _min_of(_samples[key])
		if m < best_rtt:
			best_rtt = m
			best = key
	if best == "":
		return
	chosen_key = best
	_chosen_ip = best.rsplit(":", true, 1)[0]
	_chosen_port = best.rsplit(":", true, 1)[1].to_int()
	rtt_ms = best_rtt
	rtt_hi = _high_of(_samples[best])
	state = State.ACTIVE
	_last_heard = now
	_last_send = now


func _on_packet(msg: Dictionary, ip: String, port: int, now: int, out: Array[Dictionary]) -> void:
	var key := "%s:%d" % [ip, port]
	var y := String(msg["y"])
	if not _verified.has(key) and (_verified.size() >= VERIFIED_MAX
			or (not allow_loopback and is_loopback(ip))):
		return
	if state == State.ACTIVE:
		# после выбора пути — только с проверенных адресов (токен знают лишь двое из комнаты)
		if not _verified.has(key):
			return
		_last_heard = now
	if bool(msg["ok"]):
		_peer_ok = true
	match y:
		"pr":
			_verified[key] = true
			# адреса нет среди кандидатов (симметричный NAT соперника дал новый порт) — тоже
			# пробуем его: так пробивается пара «симметричный ↔ обычный»
			if state == State.PUNCH and _remote.size() < MAX_CANDS * 2 and not _known(ip, port):
				_remote.append({"ip": ip, "port": port, "kind": "prflx"})
			_send_to(ip, port, {"y": "pa", "ts": int(msg["ts"]), "ok": 1 if _confirmed_at >= 0
				or state == State.ACTIVE else 0})
		"pa":
			var rtt := now - int(msg["ts"])
			if int(msg["ts"]) < 0 or rtt < 0 or rtt > RTT_MAX_MS:
				return
			_verified[key] = true
			if _confirmed_at < 0:
				_confirmed_at = now
			var arr: Array = _samples.get(key, [])
			# ответ, пролежавший в сокете, пока у нас стоял кадр (загрузка поля), — замер не пути,
			# а нашей заминки: в RTT не идёт (кроме самого первого — без замера путь не выбрать)
			if _hitch and not arr.is_empty():
				return
			arr.append(rtt)
			if arr.size() > RTT_SAMPLES:
				arr.pop_front()
			_samples[key] = arr
			if state == State.ACTIVE and key == chosen_key:
				rtt_ms = int(round(rtt_ms * 0.8 + rtt * 0.2))
				rtt_hi = _high_of(arr)
		"tu":
			if state != State.ACTIVE:
				return
			remote_ack = maxi(remote_ack, int(msg["a"]))
			var macs: Array = msg["m"]
			for i in (msg["r"] as Array).size():
				out.append({"raw": msg["r"][i], "mac": macs[i]})
				stats["turns_in"] = int(stats["turns_in"]) + 1


func _known(ip: String, port: int) -> bool:
	for c in _remote:
		if String(c["ip"]) == ip and int(c["port"]) == port:
			return true
	return false


func _send_to(ip: String, port: int, fields: Dictionary) -> void:
	_put(ip, port, pack(token, side, fields))


func _put(ip: String, port: int, data: PackedByteArray) -> void:
	if _udp == null or dbg_off:
		return
	_udp.set_dest_address(ip, port)
	_udp.put_packet(data)
	stats["sent"] = int(stats["sent"]) + 1


func _fail(why: String) -> void:
	state = State.FAILED
	fail_why = why
	if _udp != null:
		_udp.close()
		_udp = null


static func _min_of(a: Array) -> int:
	var m := RTT_MAX_MS + 1
	for v: int in a:
		m = mini(m, v)
	return m


## Верхний замер без одиночного выброса (80-й процентиль): заминку кадра у соперника мы не видим,
## а один такой замер раздул бы задержку ввода на весь матч (её нельзя уменьшить).
static func _high_of(a: Array) -> int:
	if a.is_empty():
		return 0
	var s := a.duplicate()
	s.sort()
	return int(s[ceili(0.8 * (s.size() - 1))])
