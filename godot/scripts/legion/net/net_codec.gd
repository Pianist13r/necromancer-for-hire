class_name NetCodec
extends RefCounted
##
## Кодек команд онлайн-«Схватки» (docs/pvp/NET_LOCKSTEP.md): словарь PvpCmd ↔ словарь из целых
## чисел и коротких строк, который переживает JSON без потерь.
##
## Почему квантование, а не float как есть: JSON.stringify печатает float не во всех знаках, и
## соперник получил бы точку на миллионную пикселя в стороне — для lockstep это рассинхрон. Поэтому
## координаты — целые 1/8 px, и ОТПРАВИТЕЛЬ применяет у себя не исходную команду, а
## `decode(encode(cmd))`: оба клиента применяют побитово одно и то же.
##
## decode ничему не верит: пустой словарь — команда отброшена (одинаково у обоих клиентов, потому
## что разбор детерминирован). Сторону кодек не несёт — её знает сессия по тому, чей это ход.
##

const Q := 8.0
## Поле PvP 1600×900; запас на кромку и оттяжку рогатки.
const COORD_MIN := -4096.0
const COORD_MAX := 4096.0
const MAX_PTS := 160
const MAX_ID := 1 << 30
const MAX_SEG := 4096
const MAX_STR := 32
const PLOT_ACTIONS := ["build", "upgrade", "sell", "rush"]
const TYPES := ["stroke", "aim", "sling", "click", "erase", "plot", "cast", "rally",
	"surrender"]


static func encode(cmd: Dictionary) -> Dictionary:
	var t := String(cmd.get("type", ""))
	var out := {"type": t}
	match t:
		"stroke":
			var pts: PackedVector2Array = cmd.get("pts", PackedVector2Array())
			var flat: Array[int] = []
			for p in pts:
				flat.append(_q(p.x))
				flat.append(_q(p.y))
			out["pts"] = flat
			out["kind"] = String(cmd.get("kind", ""))
			if cmd.has("arrow"):
				out["arrow"] = _qv(cmd["arrow"])
		"aim":
			out["contract"] = int(cmd.get("contract", -1))
			out["at"] = _qv(cmd.get("at", Vector2.ZERO))
		"sling":
			out["contract"] = int(cmd.get("contract", -1))
			out["seg"] = int(cmd.get("seg", -1))
			out["pull"] = _qv(cmd.get("pull", Vector2.ZERO))
		"click", "erase":
			out["contract"] = int(cmd.get("contract", -1))
			out["seg"] = int(cmd.get("seg", -1))
		"plot":
			out["plot"] = String(cmd.get("plot", ""))
			out["action"] = String(cmd.get("action", ""))
			out["kind"] = String(cmd.get("kind", ""))
		"cast":
			out["slot"] = int(cmd.get("slot", -1))
			out["at"] = _qv(cmd.get("at", Vector2.ZERO))
		"rally":
			out["at"] = _qv(cmd.get("at", Vector2.ZERO))
	return out


## Разбор пришедшего (или своего закодированного) словаря. Числа из JSON приходят float — всё
## приводится int() до использования, поэтому свой и чужой разбор дают одно и то же.
static func decode(d: Variant) -> Dictionary:
	if not (d is Dictionary):
		return {}
	var src: Dictionary = d
	var t := String(src.get("type", ""))
	if not t in TYPES:
		return {}
	match t:
		"stroke":
			return _decode_stroke(src)
		"aim":
			var at: Variant = _dv(src.get("at"))
			if at == null or not _id_ok(src.get("contract")):
				return {}
			return {"type": t, "contract": int(src["contract"]), "at": at}
		"sling":
			var pull: Variant = _dv(src.get("pull"))
			if pull == null or not _id_ok(src.get("contract")) or not _seg_ok(src.get("seg")):
				return {}
			return {"type": t, "contract": int(src["contract"]), "seg": int(src["seg"]), "pull": pull}
		"click", "erase":
			if not _id_ok(src.get("contract")) or not _seg_ok(src.get("seg")):
				return {}
			return {"type": t, "contract": int(src["contract"]), "seg": int(src["seg"])}
		"plot":
			return _decode_plot(src)
		"cast":
			var at: Variant = _dv(src.get("at"))
			var slot: Variant = src.get("slot")
			if at == null or not _num(slot) or int(slot) < 0 or int(slot) > 3:
				return {}
			return {"type": t, "slot": int(slot), "at": at}
		"rally":
			var at: Variant = _dv(src.get("at"))
			if at == null:
				return {}
			return {"type": t, "at": at}
	return {"type": t}   # surrender — без полей


## Свою команду — через тот же путь, что и чужую (см. шапку).
static func roundtrip(cmd: Dictionary) -> Dictionary:
	return decode(JSON.parse_string(JSON.stringify(encode(cmd))))


## Адрес как его вставит человек: «https://xxx.trycloudflare.com», «xxx.trycloudflare.com»,
## «192.168.1.5:18765» — всё приводится к ws:// или wss://.
static func normalize_url(text: String) -> String:
	var s := text.strip_edges()
	if s == "":
		return ""
	if s.begins_with("https://"):
		s = "wss://" + s.substr(8)
	elif s.begins_with("http://"):
		s = "ws://" + s.substr(7)
	elif not s.begins_with("ws://") and not s.begins_with("wss://"):
		# голый IP/имя с портом — домашняя сеть без TLS; имя без порта — туннель с TLS
		var host := s.split("/")[0]
		s = ("ws://" if ":" in host else "wss://") + s
	return s


static func _decode_stroke(src: Dictionary) -> Dictionary:
	var flat: Variant = src.get("pts")
	if not (flat is Array) or (flat as Array).size() % 2 != 0:
		return {}
	var arr: Array = flat
	if arr.size() < 4 or arr.size() > MAX_PTS * 2:
		return {}
	var pts := PackedVector2Array()
	for i in range(0, arr.size(), 2):
		var v: Variant = _dv([arr[i], arr[i + 1]])
		if v == null:
			return {}
		pts.append(v)
	var kind := _str(src.get("kind"))
	if kind == "":
		return {}
	var out := {"type": "stroke", "pts": pts, "kind": kind}
	if src.has("arrow"):
		var a: Variant = _dv(src["arrow"])
		if a == null:
			return {}
		out["arrow"] = a
	return out


static func _decode_plot(src: Dictionary) -> Dictionary:
	var plot := _str(src.get("plot"))
	var action := _str(src.get("action"))
	if plot == "" or not action in PLOT_ACTIONS:
		return {}
	return {"type": "plot", "plot": plot, "action": action, "kind": _str(src.get("kind"))}


static func _q(x: float) -> int:
	if is_nan(x) or is_inf(x):
		return 0
	return int(round(clampf(x, COORD_MIN, COORD_MAX) * Q))


static func _qv(v: Variant) -> Array[int]:
	var p: Vector2 = v if v is Vector2 else Vector2.ZERO
	return [_q(p.x), _q(p.y)]


## [x, y] в 1/8 px → Vector2; null — мусор.
static func _dv(v: Variant) -> Variant:
	if not (v is Array) or (v as Array).size() != 2:
		return null
	var a: Array = v
	if not _num(a[0]) or not _num(a[1]):
		return null
	var x := float(int(a[0])) / Q
	var y := float(int(a[1])) / Q
	if x < COORD_MIN or x > COORD_MAX or y < COORD_MIN or y > COORD_MAX:
		return null
	return Vector2(x, y)


static func _num(v: Variant) -> bool:
	if v is int:
		return true
	if v is float:
		# только целые: дробное число разные пути JSON печатают по-разному, и клиенты/судья
		# прочли бы одну команду по-разному — такие команды отбрасываются у всех одинаково
		var f: float = v
		return not is_nan(f) and not is_inf(f) and absf(f) < 1.0e9 and f == floorf(f)
	return false


static func _id_ok(v: Variant) -> bool:
	return _num(v) and int(v) >= 0 and int(v) < MAX_ID


static func _seg_ok(v: Variant) -> bool:
	return _num(v) and int(v) >= 0 and int(v) < MAX_SEG


static func _str(v: Variant) -> String:
	if not (v is String):
		return ""
	var s: String = v
	if s.length() > MAX_STR:
		return ""
	for c in s:
		if not (c == "_" or c == "-" or c == ":" or (c >= "a" and c <= "z")
				or (c >= "A" and c <= "Z") or (c >= "0" and c <= "9")):
			return ""
	return s
