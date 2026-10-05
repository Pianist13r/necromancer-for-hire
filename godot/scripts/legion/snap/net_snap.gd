class_name NetSnap
extends RefCounted
##
## Снимок боя «Схватки» для сетевого судьи (Игорь 01.10: «чтобы бой корректировался судьёй
## сразу, быстро и незаметно»): сервер при расхождении присылает клиенту полное состояние боя на
## тике K, клиент загружает его и досчитывает до текущего тика. После load() дальнейшая
## симуляция обязана идти побитово так же, как в мире, с которого снят снимок.
##
## Снимок — только простые Variant (числа, строки, Vector2, Packed*Array, Array, Dictionary):
## он уходит по сети как var_to_bytes(d), точность float сохраняется. Снимать — только на
## границе шага (между двумя LegionWorld._step): однокадровые буферы мира тогда пусты.
##
## Формат: {"v": VERSION, "tick": кадр 1/60, <кусок>: {...}, "shared": [...]}. Кусок — файл
## snap_*.gd со статическими save/build/link/finish (интерфейс — в докстринге SnapWorld и ниже,
## у load()). Ссылки между объектами — только строковыми ключами реестра Reg (ref_of/resolve),
## общие словари (залп натиска, жест) — через Reg.share/shared.
##

## Версия формата: меняется при любой несовместимой правке состава кусков или ключей.
## 2 — без ключей «Доноса» (D-1002-09); 3 — фаза PHASE_DECIDED (−1, «матч решён», SnapWorld):
## сборка с версией 2 прочла бы её как поражение, поэтому старый снимок и новый друг другу чужие
## (B-377); 4 — угловые фигуры и их ульты: у договора мини-размер/заряд/углы, у бойца щит и метка,
## у врага замедление и метка, у фигур счётчик id групп (SnapField/SnapUnits).
const VERSION := 4
## Порядок кусков = порядок save, build, link и finish. Мир первым: он готовит свежий мир
## (start_map) и стороны, остальным есть куда класть своё. Поле — до армии (бойцы стоят на
## местах договоров), штат — до армии (у бойца есть дом), артефакты и потоки — последними
## (их состояние ссылается на всех).
const CHUNKS: Array[StringName] = [&"world", &"field", &"staff", &"units", &"items", &"flow"]
const CHUNK_TITLES := {
	&"world": "К1 мир и стороны", &"field": "К2 поле и договоры", &"units": "К3 армия",
	&"staff": "К4 штат и герой", &"flow": "К5 потоки давления", &"items": "К6 артефакты",
}
const SHARED := "shared"
const REF := "@ref"
const SH := "@sh"


## Снять снимок мира w (на границе шага).
static func save(w: LegionWorld) -> Dictionary:
	var reg := Reg.new(w)
	reg.index_world()
	var out := {"v": VERSION, "tick": roundi(w.now * 60.0)}
	for key in CHUNKS:
		out[String(key)] = _chunk(key).save(w, reg)
	out[SHARED] = reg.save_shared()
	return out


## Загрузить снимок d в мир w. Возвращает реестр: в нём misses — ключи, которые не нашлись
## (кусок не воссоздал объект, на который ссылаются), и errors — несовместимости.
##
## Фазы (каждая — по всем кускам в порядке CHUNKS, прежде чем начнётся следующая):
##   1. build  — создать/перезаписать свои объекты и поля-данные; ссылки НЕ разрешать
##               (объекты других кусков могут ещё не существовать). К1 здесь же готовит мир.
##   —         реестр индексирует мир заново (массивы уже в порядке снимка) и восстанавливает
##               общие словари "shared".
##   2. link   — разрешить ссылки (reg.resolve / reg.dec / reg.shared).
##   3. finish — то, что build/link могли сдвинуть побочными эффектами: состояния RNG, счётчики.
##   —         grid.rebuild() (индексы idx бойцов и врагов, цепочки сетки).
static func load(w: LegionWorld, d: Dictionary) -> Reg:
	var reg := Reg.new(w)
	if int(d.get("v", -1)) != VERSION:
		reg.errors.append("версия снимка %s, ожидается %d" % [str(d.get("v")), VERSION])
		return reg
	for key in CHUNKS:
		_chunk(key).build(w, d.get(String(key), {}), reg)
	reg.index_world()
	reg.load_shared(d.get(SHARED, []))
	for key in CHUNKS:
		_chunk(key).link(w, d.get(String(key), {}), reg)
	for key in CHUNKS:
		_chunk(key).finish(w, d.get(String(key), {}), reg)
	w.grid.rebuild()
	return reg


## Кусок готов (не заглушка) — для отчёта теста.
static func chunk_ready(key: StringName) -> bool:
	return bool(_chunk(key).get_script_constant_map().get("READY", false))


static func _chunk(key: StringName) -> GDScript:
	match key:
		&"world":
			return SnapWorld
		&"field":
			return SnapField
		&"units":
			return SnapUnits
		&"staff":
			return SnapStaff
		&"flow":
			return SnapFlow
		&"items":
			return SnapItems
	push_error("NetSnap: неизвестный кусок %s" % key)
	return null


# ── RNG ─────────────────────────────────────────────────────────────────────

## Генератор: seed И state. Одного seed мало — state двигается каждым вызовом.
static func save_rng(r: RandomNumberGenerator) -> Dictionary:
	return {"seed": r.seed, "state": r.state}


## Порядок важен: присвоение seed сбрасывает state, поэтому state — вторым.
static func load_rng(r: RandomNumberGenerator, d: Dictionary) -> void:
	r.seed = int(d.get("seed", 0))
	r.state = int(d.get("state", 0))


# ── Поля объектов ───────────────────────────────────────────────────────────

## Значения свойств names объекта o (только простые; ссылки — через Reg). Массивы и словари —
## глубокой копией: снимок не должен делить их с живым миром.
static func props_save(o: Object, names: Array) -> Dictionary:
	var out := {}
	for n: String in names:
		out[n] = copy_data(o.get(n))
	return out


## duplicate(true) отделяет Array/Dictionary, но оставляет вложенные Packed*Array общими.
## Снимок многократно загружается локально: копируем и упакованные буферы на обоих путях.
static func copy_data(v: Variant) -> Variant:
	if v is Array:
		var out: Array = (v as Array).duplicate()
		for i in out.size():
			out[i] = copy_data(out[i])
		return out
	if v is Dictionary:
		var out: Dictionary = (v as Dictionary).duplicate()
		for k: Variant in out:
			out[k] = copy_data(out[k])
		return out
	match typeof(v):
		TYPE_PACKED_BYTE_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY, \
		TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_STRING_ARRAY, \
		TYPE_PACKED_VECTOR2_ARRAY, TYPE_PACKED_VECTOR3_ARRAY, TYPE_PACKED_VECTOR4_ARRAY, \
		TYPE_PACKED_COLOR_ARRAY:
			return v.duplicate()
	return v


## Обратное к props_save. Типизированный массив (Array[Rect2], Array[Dictionary]…) заполняется
## новым массивом того же типа: снимок, прошедший сеть, может прийти нетипизированным.
static func props_load(o: Object, d: Dictionary) -> void:
	for n: String in d:
		var v: Variant = copy_data(d[n])
		var cur: Variant = o.get(n)
		if cur is Array and (cur as Array).is_typed():
			var a: Array = (cur as Array).duplicate()
			a.clear()
			a.assign(v)
			o.set(n, a)
		else:
			o.set(n, v)


## Имена переменных скрипта (вместе с родительскими скриптами) — для сверки «каждое поле
## класса либо в снимке, либо в списке пропущенных с причиной» (тест снимка).
static func script_vars(s: Script) -> PackedStringArray:
	var out := PackedStringArray()
	for p: Dictionary in s.get_script_property_list():
		if int(p["usage"]) & PROPERTY_USAGE_SCRIPT_VARIABLE:
			out.append(String(p["name"]))
	return out


# ── Отладка ─────────────────────────────────────────────────────────────────

## Путь к первому расхождению двух снимков (или их частей); "" — совпадают побайтно.
## Для отчёта теста и разбора рассинхрона в сети: «units/u/17/hp: 12.5 ≠ 12.25».
static func diff(a: Variant, b: Variant, path := "") -> String:
	if typeof(a) != typeof(b):
		return "%s: тип %s ≠ %s" % [path, type_string(typeof(a)), type_string(typeof(b))]
	if a is Dictionary:
		var da: Dictionary = a
		var db: Dictionary = b
		if da.keys() != db.keys():
			var only_a := da.keys().filter(func(k: Variant) -> bool: return not db.has(k))
			var only_b := db.keys().filter(func(k: Variant) -> bool: return not da.has(k))
			if only_a.is_empty() and only_b.is_empty():
				return "%s: порядок ключей %s ≠ %s" % [path, _short(da.keys()), _short(db.keys())]
			return "%s: ключи только слева %s, только справа %s" % [path, _short(only_a),
				_short(only_b)]
		for k: Variant in da:
			var sub := diff(da[k], db[k], "%s/%s" % [path, str(k)])
			if sub != "":
				return sub
		return ""
	if a is Array:
		var aa: Array = a
		var ab: Array = b
		if aa.size() != ab.size():
			return "%s: длина %d ≠ %d" % [path, aa.size(), ab.size()]
		for i in aa.size():
			var sub := diff(aa[i], ab[i], "%s/%d" % [path, i])
			if sub != "":
				return sub
		return ""
	if var_to_bytes(a) != var_to_bytes(b):
		return "%s: %s ≠ %s" % [path, _short(a), _short(b)]
	return ""


static func _short(v: Variant) -> String:
	var s := str(v)
	return s if s.length() <= 120 else s.substr(0, 117) + "..."


## Реестр ссылок одной операции save или load.
##
## Ключи (адресация — по массивам мира на границе шага; порядок массивов — часть снимка, поэтому
## после build те же ключи указывают на воссозданные объекты):
##   s:<i>  сторона sides[i]          p:<i>  поле договоров стороны i (ContractField)
##   t:<i>  штат стороны i (LegionStaff)  h:<i>  герой стороны i (LegionHero)
##   k:<side>,<id>  договор поля стороны side с Contract.id == id
##   b:<i>  постройка world.buildings[i]  r:<i>  склеп world.crypts[i]
##   u:<i>  боец world.units[i]       f:<j>  враг world.foes[j]   c:<k>  труп world._corpses[k]
##   v:<side>,<i>  внештатник Дубль-вэ hero._vassals[i] стороны side
## Объект вне этих массивов (снятый договор, освобождённый узел) даёт "" и при загрузке — null:
## код боя такие ссылки и так проверяет (is_instance_valid, contracts.has).
## Объект, у которого нет места в этих массивах, кусок регистрирует сам: add(key, obj) в build.
class Reg:
	extends RefCounted

	var world: LegionWorld = null
	## Ключи, которые resolve не нашёл, — признак, что кусок не воссоздал объект.
	var misses := PackedStringArray()
	## Несовместимость снимка и мира (версия, карта, сид) — загрузка недостоверна.
	var errors := PackedStringArray()
	var _key_of: Dictionary = {}   ## instance_id → ключ (save)
	var _obj_of: Dictionary = {}   ## ключ → объект (load; при save — тоже, для проверки)
	var _shared: Array[Dictionary] = []

	func _init(w: LegionWorld) -> void:
		world = w

	## Все адресуемые объекты мира по их текущим массивам (см. ключи в докстринге класса).
	func index_world() -> void:
		_key_of.clear()
		_obj_of.clear()
		var w := world
		for s in w.sides:
			var i := s.index
			add("s:%d" % i, s)
			add("p:%d" % i, s.contracts)
			add("t:%d" % i, s.staff)
			add("h:%d" % i, w.hero_of(i))
			if s.contracts != null:
				for c in s.contracts.contracts:
					add("k:%d,%d" % [i, c.id], c)
			var hero := w.hero_of(i)
			if hero != null:
				for j in hero._vassals.size():
					add("v:%d,%d" % [i, j], hero._vassals[j])
		for i in w.buildings.size():
			add("b:%d" % i, w.buildings[i])
		for i in w.crypts.size():
			add("r:%d" % i, w.crypts[i])
		for i in w.units.size():
			add("u:%d" % i, w.units[i])
		for i in w.foes.size():
			add("f:%d" % i, w.foes[i])
		for i in w._corpses.size():
			add("c:%d" % i, w._corpses[i])

	func add(key: String, o: Object) -> void:
		if o == null:
			return
		_obj_of[key] = o
		if not _key_of.has(o.get_instance_id()):
			_key_of[o.get_instance_id()] = key

	## Ключ объекта; "" — null, освобождён или не адресуем (вне массивов мира).
	## Параметр без типа: освобождённый объект (цель врага, павший боец в списке таймера) не
	## проходит проверку типа Object-параметра — в Godot 4.7 это SCRIPT ERROR и обрыв вызывающей
	## функции, а снимок вышел бы неполным.
	func ref_of(o: Variant) -> String:
		if o == null or not is_instance_valid(o):
			return ""
		return String(_key_of.get((o as Object).get_instance_id(), ""))

	## Объект по ключу; "" → null. Ненайденный ключ — null и запись в misses.
	func resolve(key: String) -> Object:
		if key == "":
			return null
		var o: Object = _obj_of.get(key)
		if o == null:
			misses.append(key)
		return o

	## Общий словарь (один объект у многих владельцев: залп натиска у всех бойцов выпуска, жест
	## у залпа и «Сверхурочных»): номер в общем списке снимка. Звать ДО enc() структур, где он
	## встречается, — иначе enc запишет его копией и общность потеряется.
	func share(d: Dictionary) -> int:
		for i in _shared.size():
			if is_same(_shared[i], d):
				return i
		_shared.append(d)
		return _shared.size() - 1

	## Общий словарь по номеру (при загрузке — после build; содержимое уже разрешено).
	func shared(i: int) -> Dictionary:
		if i < 0 or i >= _shared.size():
			misses.append("sh:%d" % i)
			return {}
		return _shared[i]

	## Значение → простые Variant: объект → {"@ref": ключ}, общий словарь → {"@sh": номер},
	## словари и массивы — рекурсивно (типизированный массив становится обычным). Callable не
	## переносится по сети: null и ошибка (кусок обязан сам описать отложенное действие данными).
	func enc(v: Variant) -> Variant:
		match typeof(v):
			TYPE_OBJECT:
				# неадресуемый (освобождён, вне массивов мира) — null: при загрузке он и так
				# стал бы null, а повторный снимок должен совпасть побайтно
				var key := ref_of(v)
				return {REF: key} if key != "" else null
			TYPE_CALLABLE, TYPE_SIGNAL, TYPE_RID:
				push_error("NetSnap.enc: %s не сериализуется" % type_string(typeof(v)))
				return null
			TYPE_DICTIONARY:
				for i in _shared.size():
					if is_same(_shared[i], v):
						return {SH: i}
				return _enc_dict(v)
			TYPE_ARRAY:
				var out := []
				for x: Variant in v:
					out.append(enc(x))
				return out
		return NetSnap.copy_data(v)

	## Обратное к enc (после build: объекты уже созданы, общие словари восстановлены).
	func dec(v: Variant) -> Variant:
		if v is Dictionary:
			var dv: Dictionary = v
			if dv.size() == 1 and dv.has(REF):
				return resolve(String(dv[REF]))
			if dv.size() == 1 and dv.has(SH):
				return shared(int(dv[SH]))
			var out := {}
			for k: Variant in dv:
				out[dec(k)] = dec(dv[k])
			return out
		if v is Array:
			var out := []
			for x: Variant in v:
				out.append(dec(x))
			return out
		return NetSnap.copy_data(v)

	func save_shared() -> Array:
		var out := []
		for d in _shared:
			out.append(_enc_dict(d))
		return out

	## Сначала пустые словари (ссылки «общий в общем» указывают на готовый объект), потом
	## содержимое.
	func load_shared(data: Array) -> void:
		_shared.clear()
		for i in data.size():
			_shared.append({})
		for i in data.size():
			var src: Dictionary = data[i]
			for k: Variant in src:
				_shared[i][dec(k)] = dec(src[k])

	func _enc_dict(d: Dictionary) -> Dictionary:
		var out := {}
		for k: Variant in d:
			out[enc(k)] = enc(d[k])
		return out
