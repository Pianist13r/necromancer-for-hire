class_name PvpCmd
extends RefCounted
##
## API команд стороны (docs/pvp/DESIGN.md §4, §5.5): ЕДИНСТВЕННАЯ точка, через которую ввод
## игрока стороны становится действием мира — штрих договора, стрелка, рогатка, щелчок,
## площадка, способность, «Сбор», сдача. Её зовут бот PvP и (линия L3) сервер,
## получивший пакет; мышь одиночки идёт старым путём ContractField (begin/extend/finish) —
## тем же, что здесь внутри, поэтому ничего не ломается.
##
## Команда — словарь {type, …} из простых значений (числа, строки, Vector2, PackedVector2Array):
## сеть разберёт пакет в тот же словарь, не заводя своего пути. Мир ничему не верит: сторона —
## параметр вызова (у сервера — из подключения, не из пакета), договор ищется только в поле
## своей стороны, точки — только в поле мира, мана, «Точно!» и попадание считает мир сам.
## Ответ — {ok: bool, reason: String, …}; причина отказа — для подписи у игрока и для журнала.
##

const STROKE := "stroke"        ## pts: PackedVector2Array, kind: String, [arrow: Vector2]
const AIM := "aim"              ## contract: int, at: Vector2
const SLING := "sling"          ## contract: int, seg: int, pull: Vector2 (оттяжка от участка)
const CLICK := "click"          ## contract: int, seg: int
## Таб смыслом (онлайн-«Схватка»): стереть кусок линии вокруг участка — его бойцы в натиск.
const ERASE := "erase"          ## contract: int, seg: int
const PLOT := "plot"            ## plot: String, action: build|upgrade|sell|rush, [kind: String]
const CAST := "cast"            ## slot: int (0 Ку, 1 Дубль-вэ, 2 Е), at: Vector2
const RALLY := "rally"          ## at: Vector2
const SURRENDER := "surrender"

const BUILD := "build"
const UPGRADE := "upgrade"
const SELL := "sell"
## Срочный найм на павшие места постройки (LegionStaff.rush).
const RUSH := "rush"

## Пределы штриха (DESIGN §5.5): точек не больше STROKE_MAX_PTS, шаг не меньше STROKE_MIN_STEP px
## (сервер переигрывает штрих — мусор из тысяч точек стоил бы процессора).
const STROKE_MAX_PTS := 160
const STROKE_MIN_STEP := 2.0
## Онлайн-«Схватка»: кодек квантует координаты до 1/8 px — шаг черновика берём с запасом, точки
## держим на NET_EDGE px внутри поля (правая и нижняя кромки полю не принадлежат: Rect2.has_point).
const NET_STEP_PAD := 0.5
const NET_EDGE := 0.5
## Как далеко от середины штриха ставится точка стрелки (ContractField.stroke читает направление).
const NET_ARROW_REACH := 40.0


# ── Сборка команд (бот, тесты, будущий разборщик пакетов) ─────────────────────

static func stroke(pts: PackedVector2Array, kind: StringName = LegionCfg.KIND_LABORER,
		arrow := Vector2.INF) -> Dictionary:
	var cmd := {"type": STROKE, "pts": pts, "kind": String(kind)}
	if arrow != Vector2.INF:
		cmd["arrow"] = arrow
	return cmd


static func aim(contract_id: int, at: Vector2) -> Dictionary:
	return {"type": AIM, "contract": contract_id, "at": at}


static func sling(contract_id: int, seg: int, pull: Vector2) -> Dictionary:
	return {"type": SLING, "contract": contract_id, "seg": seg, "pull": pull}


static func click(contract_id: int, seg: int) -> Dictionary:
	return {"type": CLICK, "contract": contract_id, "seg": seg}


static func erase(contract_id: int, seg: int) -> Dictionary:
	return {"type": ERASE, "contract": contract_id, "seg": seg}


static func plot(plot_id: String, action: String, kind: StringName = &"") -> Dictionary:
	return {"type": PLOT, "plot": plot_id, "action": action, "kind": String(kind)}


static func cast(slot: int, at: Vector2) -> Dictionary:
	return {"type": CAST, "slot": slot, "at": at}


static func rally(at: Vector2) -> Dictionary:
	return {"type": RALLY, "at": at}


static func surrender() -> Dictionary:
	return {"type": SURRENDER}


## Точки черновика человека → точки команды STROKE: внутри поля, шаг не меньше STROKE_MIN_STEP с
## запасом на квантование сетевого кодека (1/8 px), не больше STROKE_MAX_PTS (равномерное
## прореживание с сохранением концов). Пусто или одна точка — штриха нет.
static func stroke_points(raw: PackedVector2Array, field: Vector2) -> PackedVector2Array:
	var hi := field - Vector2.ONE * NET_EDGE
	var out := PackedVector2Array()
	for p in raw:
		var q := p.clamp(Vector2.ZERO, hi)
		if out.is_empty() or q.distance_to(out[out.size() - 1]) >= STROKE_MIN_STEP + NET_STEP_PAD:
			out.append(q)
	if raw.size() > 1 and out.size() >= 2:
		# конец штриха важнее предпоследней точки: черновик кончается там, где отпущена кнопка
		var last := raw[raw.size() - 1].clamp(Vector2.ZERO, hi)
		if last.distance_to(out[out.size() - 2]) >= STROKE_MIN_STEP + NET_STEP_PAD:
			out[out.size() - 1] = last
	if out.size() > STROKE_MAX_PTS:
		var thin := PackedVector2Array()
		for i in STROKE_MAX_PTS:
			thin.append(out[roundi(float(i) * float(out.size() - 1) / float(STROKE_MAX_PTS - 1))])
		out = thin
	return out


## Точка стрелки для STROKE по направлению черновика dir: от середины штриха (так её читает
## ContractField.stroke) внутрь поля — у края шаг укорачивается, направление не ломается.
static func arrow_point(pts: PackedVector2Array, dir: Vector2, field: Vector2) -> Vector2:
	var total := 0.0
	for i in range(1, pts.size()):
		total += pts[i].distance_to(pts[i - 1])
	var mid := pts[0]
	var run := 0.0
	for i in range(1, pts.size()):
		var step := pts[i].distance_to(pts[i - 1])
		if run + step >= total * 0.5 and step > 0.0:
			mid = pts[i - 1].lerp(pts[i], (total * 0.5 - run) / step)
			break
		run += step
	var box := Rect2(Vector2.ZERO, field - Vector2.ONE * NET_EDGE)
	var reach := NET_ARROW_REACH
	while reach > 1.0 and not box.has_point(mid + dir * reach):
		reach *= 0.5
	return mid + dir * reach


# ── Применение ───────────────────────────────────────────────────────────────

static func apply(world: LegionWorld, side: int, cmd: Dictionary) -> Dictionary:
	if side < 0 or side >= world.sides.size():
		return _no("side")
	if world.phase != LegionWorld.Phase.BATTLE:
		return _no("not_battle")
	var s: PvpSide = world.sides[side]
	if s.surrendered:
		return _no("surrendered")
	match String(cmd.get("type", "")):
		STROKE:
			return _stroke(world, s, cmd)
		AIM:
			return _aim(world, s, cmd)
		SLING:
			return _sling(world, s, cmd)
		CLICK:
			return _click(s, cmd)
		ERASE:
			return _erase(s, cmd)
		PLOT:
			return _plot(s, cmd)
		CAST:
			return _cast(world, s, cmd)
		RALLY:
			return _rally(world, s, cmd)
		SURRENDER:
			return {"ok": world.surrender(side), "reason": ""}
		_:
			return _no("type")


static func _no(reason: String) -> Dictionary:
	return {"ok": false, "reason": reason}


static func _in_field(world: LegionWorld, p: Variant) -> bool:
	return p is Vector2 and Rect2(Vector2.ZERO, world.world_size).has_point(p)


static func _stroke(world: LegionWorld, s: PvpSide, cmd: Dictionary) -> Dictionary:
	var raw: Variant = cmd.get("pts")
	if not raw is PackedVector2Array:
		return _no("pts")
	var pts: PackedVector2Array = raw
	if pts.size() < 2 or pts.size() > STROKE_MAX_PTS:
		return _no("pts")
	var total := 0.0
	for i in pts.size():
		if not _in_field(world, pts[i]):
			return _no("out_of_field")
		if i > 0:
			var step := pts[i].distance_to(pts[i - 1])
			if step < STROKE_MIN_STEP:
				return _no("step")
			total += step
	if total > FigureCfg.FIG_LEN_MAX + LegionCfg.POINT_STEP:
		return _no("too_long")
	var kind := StringName(String(cmd.get("kind", LegionCfg.KIND_LABORER)))
	if not LegionCfg.UNIT_KINDS.has(kind):
		return _no("kind")
	var arrow: Variant = cmd.get("arrow", Vector2.INF)
	if arrow != Vector2.INF and not _in_field(world, arrow):
		return _no("out_of_field")
	var res := s.contracts.stroke(pts, kind, arrow as Vector2)
	var c: Contract = res.get("contract")
	if c == null:
		return _no(String(res.get("reason", "rejected")))
	return {"ok": true, "reason": "", "contract": c.id, "refreshed": bool(res.get("refreshed", false))}


static func _contract(s: PvpSide, cmd: Dictionary) -> Contract:
	return s.contracts.by_id(int(cmd.get("contract", -1)))


static func _aim(world: LegionWorld, s: PvpSide, cmd: Dictionary) -> Dictionary:
	var c := _contract(s, cmd)
	if c == null or not c.alive():
		return _no("contract")
	if not _in_field(world, cmd.get("at")):
		return _no("out_of_field")
	s.contracts.aim_contract(c, cmd["at"])
	return {"ok": true, "reason": ""}


static func _sling(world: LegionWorld, s: PvpSide, cmd: Dictionary) -> Dictionary:
	var c := _contract(s, cmd)
	var seg := int(cmd.get("seg", -1))
	if c == null or seg < 0 or seg >= c.seg_count() or not c.seg_alive(seg):
		return _no("contract")
	var pull: Variant = cmd.get("pull")
	if not pull is Vector2 or (pull as Vector2).is_zero_approx() \
			or (pull as Vector2).length() > world.world_size.length():
		return _no("pull")
	return {"ok": s.contracts.sling_release(c, seg, pull), "reason": ""}


static func _click(s: PvpSide, cmd: Dictionary) -> Dictionary:
	var c := _contract(s, cmd)
	var seg := int(cmd.get("seg", -1))
	if c == null or seg < 0 or seg >= c.seg_count() or not c.seg_alive(seg):
		return _no("contract")
	s.contracts.click(c, seg)
	return {"ok": true, "reason": ""}


static func _erase(s: PvpSide, cmd: Dictionary) -> Dictionary:
	var c := _contract(s, cmd)
	var seg := int(cmd.get("seg", -1))
	if c == null or seg < 0 or seg >= c.seg_count() or not c.seg_alive(seg):
		return _no("contract")
	var n := s.contracts.erase(c, seg)
	return {"ok": n > 0, "reason": "" if n > 0 else "erase", "n": n}


static func _plot(s: PvpSide, cmd: Dictionary) -> Dictionary:
	var p := s.staff.plot_by_id(String(cmd.get("plot", "")))
	if p.is_empty():
		return _no("plot")
	match String(cmd.get("action", "")):
		BUILD:
			var b := s.staff.build(p, StringName(String(cmd.get("kind", ""))))
			return {"ok": b != null, "reason": "" if b != null else "souls"}
		UPGRADE:
			var b: LegionBuilding = p["building"]
			var ok := b != null and s.staff.upgrade(b)
			return {"ok": ok, "reason": "" if ok else "souls"}
		SELL:
			var b: LegionBuilding = p["building"]
			if b == null:
				return _no("empty")
			return {"ok": true, "reason": "", "souls": s.staff.sell(b)}
		RUSH:
			var b: LegionBuilding = p["building"]
			if b == null:
				return _no("empty")
			if s.staff.rush_price(b) <= 0:
				return _no("full")
			var n := s.staff.rush(b)
			return {"ok": n > 0, "reason": "" if n > 0 else "souls", "n": n}
		_:
			return _no("action")


static func _cast(world: LegionWorld, s: PvpSide, cmd: Dictionary) -> Dictionary:
	var slot := int(cmd.get("slot", -1))
	if s.hero == null or slot < LegionHero.SLOT_Q or slot > LegionHero.SLOT_E:
		return _no("slot")
	if not _in_field(world, cmd.get("at")):
		return _no("out_of_field")
	if not world.can_pay_ability(slot, s.index):   # своя мана и свой запас (P2b)
		return _no("no_mana")
	var ok := s.hero.cast(slot, cmd["at"])
	return {"ok": ok, "reason": "" if ok else "cast"}


static func _rally(world: LegionWorld, s: PvpSide, cmd: Dictionary) -> Dictionary:
	if not _in_field(world, cmd.get("at")):
		return _no("out_of_field")
	if not world.can_pay_ability(LegionCfg.RALLY_SLOT, s.index):
		return _no("no_mana")
	var n := world.rally(cmd["at"], s.index)
	return {"ok": n > 0, "reason": "" if n > 0 else "rally", "n": n}
