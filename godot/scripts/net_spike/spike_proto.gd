extends RefCounted
##
## Спайк сети PvP (docs/pvp/DESIGN.md §6): общий двоичный протокол сервера и клиента.
## НЕ часть игры — доказательство, что каркас «клиент шлёт команду → сервер применяет →
## рассылает снимок» живой, и замер трафика снимка условного боя.
##
## Почему свой двоичный формат, а не RPC/MultiplayerSynchronizer: публичный сервер должен
## проверять КАЖДЫЙ байт от клиента сам (длина, версия, границы, частота), а RPC разбирает
## Variant-аргументы движком до нашей проверки и тянет server_relay (по умолчанию включён).
## Сырые пакеты ENetMultiplayerPeer — минимум поверхности атаки и точный счёт байтов.
##
## Пакеты (все числа — little-endian, координаты — целые в 1/COORD_Q px мира):
##   HELLO   [ver u8][type u8][code 6 байт ASCII]                      клиент → сервер, надёжно
##   WELCOME [ver u8][type u8][side u8][units u16]                     сервер → клиент, надёжно
##   CMD     [ver u8][type u8][seq u32][kind u8][x u16][y u16]         клиент → сервер, надёжно
##   SNAP    [ver u8][type u8][tick u32][ack u32][n u16] + n × UNIT    сервер → клиент, ненадёжно
##   UNIT    [id u16][x u16][y u16][hp u8][flags u8]                   8 байт на бойца
##

const VERSION := 1

const T_HELLO := 1
const T_WELCOME := 2
const T_CMD := 3
const T_SNAP := 4

## Команды спайка. PULL — свои бойцы в радиусе бегут к точке (перебежка), HIT — чужие в
## радиусе теряют HP (удар). Настоящий набор команд — DESIGN.md §6.4.
const K_PULL := 1
const K_HIT := 2

## 1/8 px мира: поле до 8191 px в u16 — с запасом на масштаб PvP (1600 px).
const COORD_Q := 8.0
const HELLO_LEN := 8
const WELCOME_LEN := 5
const CMD_LEN := 12
const SNAP_HDR := 12
const UNIT_LEN := 8
const CODE_LEN := 6

## Канал ENet под снимки: команды идут надёжно по каналу 0, снимки — «ненадёжно по порядку»
## по своему каналу, чтобы потерянный снимок не задерживал команды (и наоборот).
const CH_CMD := 0
const CH_SNAP := 1
const CHANNELS := 2


static func q(v: float) -> int:
	return clampi(roundi(v * COORD_Q), 0, 65535)


static func dq(v: int) -> float:
	return float(v) / COORD_Q


static func hello(code: String) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(HELLO_LEN)
	b.encode_u8(0, VERSION)
	b.encode_u8(1, T_HELLO)
	var raw := code.to_ascii_buffer()
	for i in CODE_LEN:
		b.encode_u8(2 + i, raw[i] if i < raw.size() else 0)
	return b


static func welcome(side: int, units: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(WELCOME_LEN)
	b.encode_u8(0, VERSION)
	b.encode_u8(1, T_WELCOME)
	b.encode_u8(2, side)
	b.encode_u16(3, units)
	return b


static func cmd(seq: int, kind: int, at: Vector2) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(CMD_LEN)
	b.encode_u8(0, VERSION)
	b.encode_u8(1, T_CMD)
	b.encode_u32(2, seq)
	b.encode_u8(6, kind)
	b.encode_u16(7, q(at.x))
	b.encode_u16(9, q(at.y))
	return b


## Тело снимка без шапки: одно на всех получателей, шапка (ack) — своя у каждого.
static func snap_body(pos: PackedVector2Array, hp: PackedByteArray,
		flags: PackedByteArray) -> PackedByteArray:
	var n := pos.size()
	var b := PackedByteArray()
	b.resize(n * UNIT_LEN)
	for i in n:
		var o := i * UNIT_LEN
		b.encode_u16(o, i)
		b.encode_u16(o + 2, q(pos[i].x))
		b.encode_u16(o + 4, q(pos[i].y))
		b.encode_u8(o + 6, hp[i])
		b.encode_u8(o + 7, flags[i])
	return b


static func snap(tick: int, ack: int, n: int, body: PackedByteArray) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(SNAP_HDR)
	b.encode_u8(0, VERSION)
	b.encode_u8(1, T_SNAP)
	b.encode_u32(2, tick)
	b.encode_u32(6, ack)
	b.encode_u16(10, n)
	b.append_array(body)
	return b
