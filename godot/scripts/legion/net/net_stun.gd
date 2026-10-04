class_name NetStun
extends RefCounted
##
## STUN (RFC 5389) своими руками — только Binding Request и разбор ответа: узнать, под каким
## внешним адресом и портом наш UDP-сокет виден из интернета (docs/pvp/NET_LOCKSTEP.md, «Прямое
## соединение»). Своя реализация, а не WebRTC: тому нужен GDExtension под каждую ОС, а пробивка
## без TURN-сервера у нас та же самая.
##
## Запрос шлётся с ТОГО ЖЕ сокета, по которому потом пойдут ходы: внешний порт привязан к сокету,
## адрес с другого сокета сопернику бесполезен.
##

const BINDING_REQUEST := 0x0001
const BINDING_SUCCESS := 0x0101
const MAGIC := 0x2112A442
const ATTR_MAPPED := 0x0001
const ATTR_XOR_MAPPED := 0x0020
const HEADER := 20
## Ответ сервера — пара атрибутов; больше этого читать незачем (и не верить чужой длине).
const MAX_RESPONSE := 548


## 12 случайных байт — по ним ответ отличается от чужого (и от старого повтора).
static func new_txid(rng: RandomNumberGenerator) -> PackedByteArray:
	var id := PackedByteArray()
	for i in 12:
		id.append(rng.randi_range(0, 255))
	return id


static func make_request(txid: PackedByteArray) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(HEADER)
	out.encode_u16(0, _be16(BINDING_REQUEST))
	out.encode_u16(2, 0)   # длина атрибутов — ноль
	out.encode_u32(4, _be32(MAGIC))
	for i in 12:
		out[8 + i] = txid[i]
	return out


## Это пакет STUN (а не наш JSON)? Первые два бита STUN-заголовка — нули, и magic cookie на месте.
static func looks_like_stun(data: PackedByteArray) -> bool:
	return data.size() >= HEADER and (data[0] & 0xC0) == 0 and _u32(data, 4) == MAGIC


## Разбор Binding Success: {"ip": "a.b.c.d", "port": N} или пусто (не ответ, чужой txid, обрезан,
## нет адреса). XOR-MAPPED-ADDRESS важнее MAPPED: обычный адрес некоторые NAT переписывают в теле.
static func parse_response(data: PackedByteArray, txid: PackedByteArray) -> Dictionary:
	if data.size() < HEADER or data.size() > MAX_RESPONSE or txid.size() != 12:
		return {}
	if _u16(data, 0) != BINDING_SUCCESS or _u32(data, 4) != MAGIC:
		return {}
	for i in 12:
		if data[8 + i] != txid[i]:
			return {}
	var body_len := _u16(data, 2)
	if HEADER + body_len > data.size():
		return {}
	var mapped := {}
	var at := HEADER
	var end := HEADER + body_len
	while at + 4 <= end:
		var typ := _u16(data, at)
		var alen := _u16(data, at + 2)
		var v := at + 4
		if v + alen > end:
			return {}
		if typ == ATTR_XOR_MAPPED:
			var x := _addr(data, v, alen, true)
			if not x.is_empty():
				return x
		elif typ == ATTR_MAPPED and mapped.is_empty():
			mapped = _addr(data, v, alen, false)
		at = v + ((alen + 3) & ~3)   # атрибуты выровнены на 4 байта
	return mapped


## Адрес из атрибута: только IPv4 (семейство 0x01) — внешний адрес IPv6 у нас не используется.
static func _addr(data: PackedByteArray, v: int, alen: int, xored: bool) -> Dictionary:
	if alen < 8 or data[v + 1] != 0x01:
		return {}
	var port := _u16(data, v + 2)
	var ip := _u32(data, v + 4)
	if xored:
		port ^= MAGIC >> 16
		ip ^= MAGIC
	if port == 0:
		return {}
	return {"ip": "%d.%d.%d.%d" % [(ip >> 24) & 255, (ip >> 16) & 255, (ip >> 8) & 255, ip & 255],
		"port": port}


static func _u16(d: PackedByteArray, at: int) -> int:
	return (d[at] << 8) | d[at + 1]


static func _u32(d: PackedByteArray, at: int) -> int:
	return (d[at] << 24) | (d[at + 1] << 16) | (d[at + 2] << 8) | d[at + 3]


## encode_u16/u32 пишут в порядке машины (little-endian) — сетевой порядок собираем перестановкой.
static func _be16(v: int) -> int:
	return ((v & 0xFF) << 8) | ((v >> 8) & 0xFF)


static func _be32(v: int) -> int:
	return ((v & 0xFF) << 24) | (((v >> 8) & 0xFF) << 16) | (((v >> 16) & 0xFF) << 8) \
		| ((v >> 24) & 0xFF)
