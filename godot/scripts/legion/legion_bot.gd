class_name LegionBot
extends RefCounted
##
## Бот проверки концепции (SLICE_SPEC §6). Играет теми же руками, что игрок: договоры по
## рубежам карты (bot_lines), мана списывается как у человека, решения — с задержкой реакции.
##
## Политики:
##   hold      — держать всё: подрисовывает каждый участок за BOT_REFRESH_LEAD до истечения;
##   release   — отпустить всё: ставит строй и никогда не подрисовывает, после таяния ставит снова;
##   selective — держит участки против пехоты, отпускает участки, перед которыми стоит нотариус
##               или проходит призрак; в затишье укрепляет отряды расчётом по договору.
##   button    — точная контрольная копия selective: решение сразу исполняется ПКМ;
##   melt      — прогноз по видимому движению, последняя подрисовка и ожидание срока.
##
## Слот хранит шаблон рубежа и его договоры. Набор резерва общий с LegionStaff.
const HOLD := &"hold"
const RELEASE := &"release"
const SELECTIVE := &"selective"
const BUTTON := &"button"
const MELT := &"melt"
const TACTICS := preload("res://scripts/legion/bot_tactics.gd")
## «Сбор» на Юриста — только если прибегут хотя бы столько (круг «позовёт N» виден игроку).
## Здесь, а не в LegionCfg: там упёрлись в потолок gdlint 1000 строк.
const LAWYER_RALLY_MIN := 2
## v20: Е по прогнутому участку — с этой доли прогиба до прорыва и не меньше стольких в строю.
const BOT_E_BEND := 0.5
const BOT_E_MIN_MEN := 3

var world: LegionWorld = null
var policy: StringName = SELECTIVE
## {pts, side, kind, template: Contract, contracts: Array[Contract]}
var slots: Array[Dictionary] = []

var _think_t := 0.0
var _seen: Dictionary = {}
var _velocity: Dictionary = {}
var _seen_t := 0.0
var _crypt_orders: Dictionary = {}
var _ram_units: Dictionary = {}
var _packages_seen: Dictionary = {}
var _seal_seen: Dictionary = {}
var _relays: Dictionary = {}
## B-008: на какой участок уже звали «Сбор» против этого Юриста (id → [договор, участок]).
var _lawyer_rallied: Dictionary = {}


func setup(w: LegionWorld, new_policy: StringName, map: Dictionary) -> void:
	world = w
	policy = new_policy
	slots.clear()
	_relays.clear()
	_packages_seen.clear()
	_seal_seen.clear()
	for key in ["contracts_laborer", "contracts_guard", "contracts_clerk", "relay_contracts",
			"packages", "seals", "buildings_upgraded", "casts_q", "casts_w", "casts_e"]:
		world.stats[key] = 0
	world.stats["idle_unit_seconds"] = 0.0
	world.stats["line_restores"] = 0
	world.stats["rear_ready"] = 0
	world.stats["rear_warnings"] = 0
	if not world.contract_created.is_connected(_count_contract):
		world.contract_created.connect(_count_contract)
	if not world.hero_cast.is_connected(_count_cast):
		world.hero_cast.connect(_count_cast)
	if not world.segment_released.is_connected(_count_seals):
		world.segment_released.connect(_count_seals)
	if not world.breach_warned.is_connected(_breach_warned):
		world.breach_warned.connect(_breach_warned)
	if not world.breach_opened.is_connected(_breach_opened):
		world.breach_opened.connect(_breach_opened)
	_crypt_orders.clear()
	_lawyer_rallied.clear()
	_ram_units.clear()
	for key in ["crypt_captures", "ram_dodges", "second_line", "bot_lawyer_q", "bot_lawyer_rallies"]:
		world.stats[key] = 0
	if not world.boss_rammed.is_connected(_ram_result):
		world.boss_rammed.connect(_ram_result)
	var roads: Dictionary = {}
	for bl in map.get("bot_lines", []):
		var a := Vector2(float(bl["a"][0]), float(bl["a"][1]))
		var b := Vector2(float(bl["b"][0]), float(bl["b"][1]))
		var duplicate := false
		for slot in slots:
			if slot["pts"][0] == a and slot["pts"][-1] == b:
				duplicate = true
		if duplicate:
			continue
		var pts := PackedVector2Array()
		var n := maxi(1, ceili(a.distance_to(b) / LegionCfg.BOT_POINT_STEP))
		for i in n + 1:
			pts.append(a.lerp(b, float(i) / float(n)))
		var side := int(bl.get("release", 1))
		var kind := StringName(String(bl.get("kind", LegionCfg.KIND_LABORER)))
		# шаблон — та же нарезка участков, что у настоящего договора: по нему ищем дыры
		var template := Contract.new().build(pts, side, Callable(), kind)
		var road := String(bl.get("road", ""))
		slots.append({"pts": pts, "side": side, "kind": kind, "template": template,
			"contracts": [], "reserve": roads.has(road),
			"id": String(bl.get("id", "line_%d" % slots.size())),
			"role": String(bl.get("role", "front")),
			"dir": Vector2(bl.get("dir", [template.dir.x, template.dir.y])[0],
				bl.get("dir", [template.dir.x, template.dir.y])[1]),
			"min_units": int(bl.get("min_units", LegionCfg.BOT_MIN_SQUAD)),
			"next_ids": bl.get("next_ids", []), "support_id": bl.get("support_id", "")})
		roads[road] = true
	_add_support_slots()
	_think_t = 0.0
	_seen.clear()
	_velocity.clear()
	_seen_t = 0.0


func tick(dt: float) -> void:
	_measure(dt)
	if world.tutorial != null and world.tutorial.holding():
		return   # Учебный бот ведёт тот же резерв; не отбираем его у упражнения.
	_think_t -= dt
	if _think_t > 0.0:
		return
	_think_t = world.rng.randf_range(LegionCfg.BOT_REACT_MIN, LegionCfg.BOT_REACT_MAX)
	_observe()
	LegionKassa.bot_step(world)   # только с --dev bot_kassa=1; раньше срочного найма
	_build_step()
	# Юрист — до обычного героя: иначе Ку уходит на кучку пехоты, пока он рвёт договор.
	# --dev no_hero=1 — бот без Ку/Дубль-вэ/Е и без «Сбора» на Юриста: замер «можно ли пройти
	# без навыков» (Игорь 26.09: «обязательно надо было использовать скиллы»).
	if int(world.dev.get("no_hero", 0)) != 1:
		_answer_lawyers()
		_hero_step()
	_relay_step()
	_capture_crypts()
	_answer_siege()
	if policy == SELECTIVE or policy == BUTTON:
		_dodge_ram()
	var order := slots.duplicate()
	order.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.get("breach_priority", 0.0)) > float(b.get("breach_priority", 0.0)))
	for slot in order:
		_tick_slot(slot)
	if int(world.dev.get("call_early", 0)) == 1 and world.wave_runner.can_call():
		for slot in slots:
			if slot.get("role", "") == "front":
				if _line_manned(slot, true):
					world.wave_runner.call_next()
				break


func _line_manned(slot: Dictionary, full := false) -> bool:
	var count := 0
	for c: Contract in slot["contracts"]:
		for s in c.seg_count():
			count += c.seg_manned(s)
	var tpl: Contract = slot["template"]
	var minimum := tpl.posts.size() if full else int(slot.get("min_units", LegionCfg.BOT_MIN_SQUAD))
	return count >= minimum


## Только публичное предупреждение: время контакта и близость выхода к Котлу.
func _breach_warned(id: String, in_s: float, summary: Array) -> void:
	var at := world.breach_pos(id)
	var speed := LegionCfg.BOT_V16_THREAT_SPEED
	for group: Dictionary in summary:
		var spec: Dictionary = LegionCfg.FOES.get(group.get("type", ""), {})
		speed = maxf(speed, float(spec.get("speed", speed)))
	var rear_risk := 1.0
	for front in slots:
		if front.get("role", "") == "front":
			var line: Contract = front["template"]
			rear_risk = maxf(rear_risk, line.point_at(line.length * 0.5).distance_to(
				world.cauldron_pos) / maxf(at.distance_to(world.cauldron_pos), 1.0))
	for slot in slots:
		if slot.get("role", "") != "rear":
			continue
		var tpl: Contract = slot["template"]
		var eta := in_s + tpl.live_distance(at) / speed
		slot["breach_priority"] = rear_risk / maxf(eta, LegionCfg.BOT_REACT_MIN)
		var pending: Dictionary = slot.get("breach_pending", {})
		# При нахлёсте одно открытие не отменяет более позднее предупреждение того же id.
		pending[id] = int(pending.get(id, 0)) + 1
		slot["breach_pending"] = pending
		slot["rear_active"] = true
		slot.erase("melt_contract")
		world.stats["rear_warnings"] += 1


func _breach_opened(id: String) -> void:
	for slot in slots:
		var pending: Dictionary = slot.get("breach_pending", {})
		if not pending.has(id):
			continue
		if _line_manned(slot):
			world.stats["rear_ready"] += 1
		pending[id] = int(pending[id]) - 1
		if int(pending[id]) <= 0:
			pending.erase(id)



# ── Строительство (пакет staff, DESIGN_V15 §12 п.11) ────────────────────────
## Одинаково во всех политиках, без прогноза: сперва пустой участок с наибольшим bot_priority
## (вид — первый открытый из preferred_kinds, иначе подрядчик); хватает душ — строим, нет —
## копим на него. Все участки застроены — улучшаем постройку самого приоритетного участка.
## Одно действие за раздумье: как у человека, кликающего меню.
func _build_step() -> void:
	if int(world.dev.get("no_build", 0)) == 1:
		return
	var st := world.staff
	if st.plots.is_empty() or LegionStaff.bot_rush(world):   # срочный найм, D-0927-135
		return
	var order := st.plots.duplicate()
	order.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return _plot_score(a) > _plot_score(b))
	for p: Dictionary in order:
		if p["building"] != null:
			continue
		var kind := LegionCfg.KIND_LABORER
		for k in p["preferred_kinds"]:
			if st.kind_unlocked(StringName(String(k))):
				kind = StringName(String(k))
				break
		st.build(p, LegionChallenge.bot_kind(world.dev, kind))
		return
	for p: Dictionary in order:
		var b: LegionBuilding = p["building"]
		if LegionStaff.upgrade_price(b) >= 0:
			if st.upgrade(b):
				world.stats["buildings_upgraded"] += 1
			return


func _tick_slot(slot: Dictionary) -> void:
	if not TACTICS.rear_ready(slot, _seen):
		return
	var list: Array = slot["contracts"]
	for i in range(list.size() - 1, -1, -1):
		if not world.contracts.contracts.has(list[i]):
			list.remove_at(i)
	if list.is_empty():
		if world.now - float(slot.get("last_release", -INF)) < LegionCfg.BOT_PATCH_DELAY:
			return
		_prepare_flank(slot)
		var kind := _choose_kind(slot)
		var pts: PackedVector2Array = slot["pts"]
		var c := _place(pts, int(slot["side"]), kind, slot.get("dir", Vector2.RIGHT),
			int(slot.get("min_units", LegionCfg.BOT_MIN_SQUAD)))
		if c != null:
			list.append(c)
			if slot.get("placed", false):
				world.stats["line_restores"] += 1
			slot["placed"] = true
		else:
			_request_relay(slot, kind)
		return

	if slot["reserve"] and not slot.get("counted", false):
		for c: Contract in list:
			for s in c.seg_count():
				if c.seg_manned(s) >= LegionCfg.BOT_MIN_SQUAD:
					world.stats["second_line"] += 1
					slot["counted"] = true
					break
			if slot.get("counted", false):
				break
	if not slot.get("breach_pending", {}).is_empty():
		for c: Contract in list:
			_refresh_due(c, {"role": "back"})
		_patch_holes(slot)
		return
	if policy == SELECTIVE or policy == BUTTON:
		_plan_package(slot)
		_selective(slot)
	elif policy == MELT:
		_plan_melt(slot)
	if policy != RELEASE:
		for c: Contract in list:
			_refresh_due(c, slot)
	_patch_holes(slot)


func _refresh_due(c: Contract, slot: Dictionary) -> void:
	var due := PackedInt32Array()
	for s in c.seg_count():
		if slot.get("melt_contract") == c and int(slot.get("melt_seg", -1)) == s:
			continue
		if (policy == SELECTIVE or policy == BUTTON) and slot.get("role", "") != "back" \
				and _recovering(c, s):
			continue
		if c.seg_alive(s) and c.seg_left(s) < LegionCfg.BOT_REFRESH_LEAD:
			due.append(s)
	if not due.is_empty():
		world.contracts.refresh(c, due, true)


## В затишье отряд завершает уже оплаченный договор и укрепляется расчётом до потолка.
## Видим только здоровье и пустую полосу перед строем, расписание волн не читаем.
func _recovering(c: Contract, s: int) -> bool:
	if int(world.dev.get("melt_settlement", int(LegionCfg.MELT_SETTLEMENT_ENABLED))) == 0:
		return false
	if c.seg_renewed[s] == 0 or not c.seg_alive(s):
		return false
	for at: Vector2 in _seen.values():
		if at.distance_to(c.seg_center(s)) <= LegionCfg.BOT_SIGNER_RANGE:
			return false
	for p in c.posts:
		var u: Legionnaire = p["unit"]
		if int(p["seg"]) == s and u != null and u.state == Legionnaire.State.POSTED \
			and u.hp < float(u.spec["hp"]) * LegionCfg.SETTLEMENT_CAP_MULT:
			return true
	return false


## Измеряем только экранные позиции в те же моменты реакции, что selective.
## Ни расписание волн, ни путь/цель врага, ни его будущие решения не читаются.
func _observe() -> void:
	var seen: Dictionary = {}
	_velocity.clear()
	var elapsed := world.now - _seen_t
	for f in world.foes:
		if not f.is_active() or not Rect2(Vector2.ZERO, world.world_size).has_point(f.position):
			continue
		var id := f.get_instance_id()
		seen[id] = f.position
		if _seen.has(id) and elapsed > 0.0:
			_velocity[id] = (f.position - Vector2(_seen[id])) / elapsed
	_seen = seen
	_seen_t = world.now


## Один заранее назначенный выход на рубеж: остальные участки остаются стеной.
## Подрисовка обнуляет возраст, поэтому выбираем ближайший из двух доступных сроков:
## текущий или полный TTL после последнего оплаченного штриха.
func _plan_melt(slot: Dictionary) -> void:
	var pending: Contract = slot.get("melt_contract")
	if pending != null:
		var seg := int(slot["melt_seg"])
		if not pending.seg_alive(seg):
			slot["last_release"] = world.now
			slot.erase("melt_contract")
			return
		if _seen.has(int(slot["melt_target"])):
			return
		# Исчезнувшая цель отменяет план: участок снова продлевается обычным штрихом.
		slot.erase("melt_contract")
	if world.now - float(slot.get("last_release", -INF)) < LegionCfg.BOT_RELEASE_CD:
		return
	var best: Dictionary = {}
	var score := INF
	for f in world.foes:
		if not _seen.has(f.get_instance_id()) or f.type_id not in ["signer", "ghost"]:
			continue
		for c: Contract in slot["contracts"]:
			for s in c.seg_count():
				var eta := _melt_eta(c, s, f)
				if eta < 0.0 or eta > c.ttl:
					continue
				var error := minf(absf(eta - c.seg_left(s)), absf(eta - c.ttl))
				var cost := error + f.position.distance_to(c.seg_center(s)) \
						/ LegionCfg.BOT_MELT_DISTANCE_WEIGHT
				if cost < score:
					score = cost
					best = {"c": c, "s": s, "eta": eta, "target": f.get_instance_id()}
	if best.is_empty():
		return
	var c: Contract = best["c"]
	var s := int(best["s"])
	var eta := float(best["eta"])
	if absf(eta - c.ttl) + LegionCfg.BOT_REACT_MAX < absf(eta - c.seg_left(s)):
		if not world.contracts.refresh(c, PackedInt32Array([s]), true):
			return
	slot["melt_contract"] = c
	slot["melt_seg"] = s
	slot["melt_target"] = best["target"]


func _melt_eta(c: Contract, s: int, f: Foe) -> float:
	if not c.seg_alive(s) or c.seg_manned(s) < LegionCfg.BOT_MIN_SQUAD:
		return -1.0
	var center := c.seg_center(s)
	var normal := c.normal_at(s)
	var offset := f.position - center
	var along := offset.dot(normal)
	var velocity: Vector2 = _velocity.get(f.get_instance_id(), Vector2.ZERO)
	var closing := -velocity.dot(normal)
	var range_to_target := LegionCfg.BOT_SIGNER_RANGE if f.type_id == "signer" else 0.0
	if along < -LegionCfg.BOT_GHOST_BEHIND or (f.type_id == "signer" and along <= 0.0):
		return -1.0
	if along > range_to_target and closing < LegionCfg.BOT_MELT_MIN_SPEED:
		return -1.0
	var eta := maxf(0.0, (along - range_to_target) / maxf(closing, LegionCfg.BOT_MELT_MIN_SPEED))
	var predicted := offset + velocity * eta
	if absf(predicted.cross(normal)) > LegionCfg.BOT_MELT_LATERAL:
		return -1.0
	if world.grid.count_foes_near(center, LegionCfg.BOT_PRESSURE_R) > LegionCfg.BOT_PRESSURE_MAX:
		return -1.0
	return eta


## Выборочно: держим строй, но выпускаем ОДИН участок-вылазку на нотариуса перед рубежом
## (ближайший к нему, в который пехота ещё не упёрлась — иначе натиск встанет о первого зомби)
## и занятый участок на призрака. Нотариус — не чаще BOT_RELEASE_CD на рубеж: без паузы
## один нотариус раздевал весь рубеж, и пехота шла в пустоту (итерация баланса 1).
func _selective(slot: Dictionary) -> void:
	# Призрака перехватываем ДО прохода сквозь стену. Старый поиск выпускал
	# первый геометрически подходящий, даже пустой участок и тратил 4 с отката.
	if _intercept_ghost(slot):
		return
	# v18: участок вот-вот прорвут — пружина в толпу (прогиб виден на экране: контур гнётся и
	# краснеет). Откат выпуска не ждём: через секунду участок и так рассыплется.
	if _spring(slot):
		return
	if world.now - float(slot.get("last_release", -INF)) < LegionCfg.BOT_RELEASE_CD:
		return
	if TACTICS.release_flank(world, slot, _seen, _velocity):
		return
	var list: Array = slot["contracts"]
	for f in world.foes:
		if not _seen.has(f.get_instance_id()) or f.type_id not in ["signer", "shield_inspector"]:
			continue
		if f.type_id == "shield_inspector" and slot.get("role", "") != "flank":
			continue
		var best: Contract = null
		var best_s := -1
		var best_d := INF
		for c: Contract in list:
			if c.kind == LegionCfg.KIND_CLERK:
				continue
			for s in c.seg_count():
				if slot.get("melt_contract") == c and int(slot.get("melt_seg", -1)) == s:
					continue
				if world.contracts.in_package(c, s):
					continue
				if not c.seg_alive(s) or c.seg_manned(s) < LegionCfg.BOT_MIN_SQUAD:
					continue
				var center := c.seg_center(s)
				var d := f.position - center
				var along := d.dot(c.normal_at(s))
				if along <= 0.0 or along > LegionCfg.BOT_SIGNER_RANGE:
					continue
				if world.grid.count_foes_near(center, LegionCfg.BOT_PRESSURE_R) \
						> LegionCfg.BOT_PRESSURE_MAX:
					continue
				if d.length() < best_d:
					best_d = d.length()
					best = c
					best_s = s
		if best != null:
			_sortie(slot, best, best_s)
			return


## v18 «Пружина»: самый прогнутый участок рубежа (не меньше BOT_SPRING_AT) — рогаткой против
## давки. true — выпустил.
func _spring(slot: Dictionary) -> bool:
	if not world.press_on():
		return false
	var best: Contract = null
	var best_s := -1
	var best_b := LegionCfg.BOT_SPRING_AT
	for c: Contract in slot["contracts"]:
		for s in c.seg_count():
			if not c.seg_alive(s) or c.seg_manned(s) < LegionCfg.BOT_MIN_SQUAD:
				continue
			var b := c.bend_frac(s)
			if b >= best_b:
				best_b = b
				best = c
				best_s = s
	if best == null:
		return false
	var dir := -best.seg_bend_dir[best_s]
	if dir.is_zero_approx():
		dir = best.dir
	world.contracts.release_aimed(best, best_s, dir, LegionCfg.BOT_SPRING_POWER, false)
	slot["last_release"] = world.now
	world.stats["bot_springs"] = int(world.stats.get("bot_springs", 0)) + 1
	return true


func _sortie(slot: Dictionary, c: Contract, s: int) -> void:
	world.contracts.release(c, s)
	slot["last_release"] = world.now


## Участки рубежа, которые ничем не закрыты, латаем заплаткой, если угроза ушла.
func _patch_holes(slot: Dictionary) -> void:
	var tpl: Contract = slot["template"]
	var list: Array = slot["contracts"]
	for s in tpl.seg_count():
		var center := tpl.seg_center(s)
		if _covered(list, center):
			continue
		# дыру от вылазки не латаем сразу: отряд должен успеть выбежать, а не встать обратно
		if world.now - float(slot.get("last_release", -INF)) < LegionCfg.BOT_PATCH_DELAY:
			continue
		var d1 := minf(tpl.length, (s + 1) * LegionCfg.SEG_LEN)
		var d0 := minf(s * LegionCfg.SEG_LEN, d1 - LegionCfg.LINE_MIN - 1.0)
		var pts := PackedVector2Array()
		var steps := 4
		for k in steps + 1:
			pts.append(tpl.point_at(lerpf(maxf(0.0, d0), d1, float(k) / steps)))
		var c := _place(pts, int(slot["side"]), _choose_kind(slot),
			slot.get("dir", Vector2.RIGHT), LegionCfg.BOT_MIN_SQUAD)
		if c != null:
			list.append(c)
		return   # одна заплатка за раздумье — мана и реакция как у человека


func _covered(list: Array, p: Vector2) -> bool:
	for c: Contract in list:
		var pr := c.project(p)
		if pr.x < 6.0 and c.seg_alive(c.segment_at(pr.y)):
			return true
	return false


func _free_count() -> int:
	var count := 0
	for u in world.units:
		if u.alive and u.state == Legionnaire.State.FREE:
			count += 1
	return count


func _intercept_ghost(slot: Dictionary) -> bool:
	if world.now - float(slot.get("last_release", -INF)) < LegionCfg.BOT_GHOST_RETRY:
		return false
	for f in world.foes:
		if not f.ghost or not _seen.has(f.get_instance_id()):
			continue
		var guards := 0
		for u in world.units_near(f.position, LegionCfg.FREE_AGGRO):
			if u.state == Legionnaire.State.FREE or u.state == Legionnaire.State.CHARGE:
				guards += 1
		if guards >= LegionCfg.BOT_MIN_SQUAD:
			continue
		var best: Contract = null
		var seg := -1
		var distance := LegionCfg.BOT_GHOST_INTERCEPT
		for c: Contract in slot["contracts"]:
			if c.kind == LegionCfg.KIND_CLERK:
				continue
			for s in c.seg_count():
				if not c.seg_alive(s) or c.seg_manned(s) < LegionCfg.BOT_MIN_SQUAD:
					continue
				if (f.position - c.seg_center(s)).dot(c.normal_at(s)) > LegionCfg.UNIT_REACH:
					continue
				var d := c.seg_center(s).distance_to(f.position)
				if d < distance:
					distance = d
					best = c
					seg = s
		if best != null:
			_sortie(slot, best, seg)
			return true
	return false


func _capture_crypts() -> void:
	for crypt in world.crypts:
		var c: Contract = _crypt_orders.get(crypt)
		if crypt.allegiance == LegionCrypt.Owner.PLAYER:
			if c != null:
				for s in c.seg_count():
					if c.seg_alive(s):
						world.contracts.release(c, s)
				_crypt_orders.erase(crypt)
			continue
		if c != null and world.contracts.contracts.has(c):
			_refresh_due(c, {})
			continue
		if _free_count() < LegionCfg.CRYPT_UNITS or crypt.contested:
			continue
		var half := Vector2(0, LegionCfg.POST_STEP * LegionCfg.CRYPT_UNITS / 4.0)
		c = _place(PackedVector2Array([crypt.position - half, crypt.position + half]),
			1, LegionCfg.KIND_LABORER, Vector2.RIGHT, LegionCfg.CRYPT_UNITS)
		if c != null:
			_crypt_orders[crypt] = c
		return


func _dodge_ram() -> void:
	for f in world.foes:
		if f.type_id != "boss" or f.ram_t < 0.0 or not _seen.has(f.get_instance_id()):
			continue
		var escaping: Array = _ram_units.get(f.get_instance_id(), [])
		for slot in slots:
			for c: Contract in slot["contracts"]:
				var segments := PackedInt32Array()
				for p in c.posts:
					var u: Legionnaire = p["unit"]
					if u == null or u.state != Legionnaire.State.POSTED:
						continue
					if u.position.distance_to(f.ram_pos) <= float(f.def["ram_r"]):
						if not segments.has(p["seg"]):
							segments.append(p["seg"])
						escaping.append({"unit": weakref(u), "hp": u.hp})
				for s in segments:
					_sortie(slot, c, s)
		_ram_units[f.get_instance_id()] = escaping


## B-008: ответ на Юриста — как у человека, по тому, что на экране. Выбрав участок, Юрист
## показывает телеграф: пунктир к точке, «!» над ней, подсвеченный участок, кольцо зачитки.
## v20: строй его не трогает, а целится он в самый людный участок — отвечаем всегда (раньше —
## только за пустой участок: стоящие били его сами). Ответ: Ку в него (45 HP, Ку — 24: один не
## убивает, но оглушение срывает зачитку) и «Сбор» свободных к точке зачитки — добьют.
## «Сбор» — один раз на участок и только если никто из зовущихся не в драке: первая версия звала
## по откату (8 раз за бой), выдёргивала бойцов из боя и проиграла «Лабиринт» 5/12 против 9/12.
## Выпуск участка не помогает: в пустом выпускать некого. Ку и «Сбор» договоры не трогают —
## ответ одинаков для всех политик.
func _answer_lawyers() -> void:
	for f in world.foes:
		# v20: строй Юриста не бьёт (Foe.is_law_immune) — отвечаем на любой его участок, а не
		# только на пустой, как было в B-008
		if f.type_id != "lawyer" or not f.is_active() or f.law_c == null \
				or not _seen.has(f.get_instance_id()):
			continue
		if world.hero != null and world.hero.is_unlocked(LegionHero.SLOT_Q) \
				and world.hero.cd_left(LegionHero.SLOT_Q) <= 0.0 \
				and world.hero.cast(LegionHero.SLOT_Q, f.position):
			world.stats["bot_lawyer_q"] += 1
		# Ку мог добить — тогда телеграфа уже нет
		if not f.alive or f.law_c == null or world.rally_cd > 0.0:
			continue
		var key := [f.law_c, f.law_seg]
		if _lawyer_rallied.get(f.get_instance_id(), []) == key:
			continue
		var reach: Array = world.rally_preview(f.law_pos)["reach"]
		if reach.size() < LAWYER_RALLY_MIN or _any_fighting(reach):
			continue
		if world.rally(f.law_pos) > 0:
			_lawyer_rallied[f.get_instance_id()] = key
			world.stats["bot_lawyer_rallies"] += 1


## Кто-то из них уже дерётся (враг ближе FREE_AGGRO) — это видно на экране.
func _any_fighting(units: Array) -> bool:
	for u: Legionnaire in units:
		if world.grid.nearest_foe(u.position, LegionCfg.FREE_AGGRO, true) != null:
			return true
	return false


## Считаем спасённых бойцов, а не нажатия ПКМ: таран уже применил урон.
func _ram_result(boss: Foe, at: Vector2) -> void:
	for entry: Dictionary in _ram_units.get(boss.get_instance_id(), []):
		var u: Legionnaire = entry["unit"].get_ref()
		if u != null and u.alive and u.hp >= float(entry["hp"]) \
				and u.position.distance_to(at) > float(boss.def["ram_r"]):
			world.stats["ram_dodges"] += 1
	_ram_units.erase(boss.get_instance_id())


## Только видимая осада: всем политикам доступен одинаковый рубеж у босса.
## Его набор, доставка и оплата проходят обычным путём _tick_slot.
func _answer_siege() -> bool:
	for f in world.foes:
		if f.state != Foe.State.SIEGE or not _seen.has(f.get_instance_id()):
			continue
		for slot in slots:
			if slot.get("id", "") == "siege":
				return true
		var at := f.position + LegionCfg.BOT_SIEGE_OFFSET
		var pts := PackedVector2Array([
			at - LegionCfg.BOT_SIEGE_HALF, at + LegionCfg.BOT_SIEGE_HALF])
		slots.push_front({"pts": pts, "side": 1, "kind": LegionCfg.KIND_LABORER,
			"dir": (f.position - at).normalized(), "role": "flank", "id": "siege",
			"min_units": LegionCfg.BOT_MIN_SQUAD, "reserve": false, "contracts": [],
			"template": Contract.new().build(pts, 1)})
		return true
	return false


## Счётчики подписаны на фактические события: отказ по мане/откату не считается.
func _count_contract(c: Contract) -> void:
	var key := "contracts_" + String(c.kind)
	world.stats[key] = int(world.stats.get(key, 0)) + 1


func _count_cast(slot: int, _at: Vector2) -> void:
	world.stats[["casts_q", "casts_w", "casts_e"][slot]] += 1


## Сигнал приходит до удара выпущенного отряда: печать, потраченная в том же кадре,
## не исчезает из статистики. _seal_seen сбрасывается при окончании действия печати.
func _count_seals(_c: Contract, _seg: int, _count: int) -> void:
	for u in world.units:
		var uid := u.get_instance_id()
		if u._seal_t > 0.0 and not _seal_seen.get(uid, false):
			world.stats["seals"] += 1
		_seal_seen[uid] = u._seal_t > 0.0


func _measure(dt: float) -> void:
	for u in world.units:
		if not u.alive:
			continue
		if u.state == Legionnaire.State.FREE \
				and world.grid.nearest_foe(u.position, float(u.spec["reach"]), true) == null:
			world.stats["idle_unit_seconds"] += dt
		# grant_seal может отказать из-за отката: считаем реально выданные печати.
		var uid := u.get_instance_id()
		if u._seal_t > 0.0 and not _seal_seen.get(uid, false):
			world.stats["seals"] += 1
		_seal_seen[uid] = u._seal_t > 0.0
	for pair: Dictionary in world.contracts._package_pairs:
		var a: Contract = pair["a"]
		var b: Contract = pair["b"]
		var key := Vector4i(a.id, pair["sa"], b.id, pair["sb"])
		if not _packages_seen.has(key):
			_packages_seen[key] = true
			world.stats["packages"] += 1


func _plot_score(p: Dictionary) -> float:
	var score := float(p["bot_priority"])
	for slot in slots:
		if p["serves_lines"].has(slot.get("id", "")):
			var tpl: Contract = slot["template"]
			if tpl.live_distance(p["pos"]) <= LegionCfg.RECRUIT_R:
				score += LegionCfg.BOT_PLOT_NEAR_BONUS
	return score


func _choose_kind(slot: Dictionary) -> StringName:
	var desired := StringName(String(slot["kind"]))
	var role := String(slot.get("role", "front"))
	if role == "back":
		desired = LegionCfg.KIND_CLERK
	elif role == "rear":
		if desired == LegionCfg.KIND_CLERK:
			desired = LegionCfg.KIND_LABORER
	elif role == "flank" or role == "relay":
		desired = LegionCfg.KIND_LABORER
	else:
		var tpl: Contract = slot["template"]
		for f in world.foes:
			if _seen.has(f.get_instance_id()) \
					and tpl.live_distance(f.position) <= LegionCfg.BOT_THREAT_R:
				# щит «Штатного» ломает подряд (метка давки) — на него тоже охрана
				if not f.ghost and (f.type_id not in ["signer", "boss", "shield_inspector"]
						or LegionChallenge.press_mult(f, LegionCfg.KIND_LABORER) > 1.0):
					desired = LegionCfg.KIND_GUARD
					break
	desired = LegionChallenge.bot_kind(world.dev, desired)
	return desired if world.staff.kind_unlocked(desired) else LegionCfg.KIND_LABORER


## Фланговый карман следует видимой угрозе лишь в окрестности своего рубежа.
## Стрелка остаётся из данных; щит атакуем сбоку относительно измеренного движения.
func _prepare_flank(slot: Dictionary) -> void:
	if slot.get("role", "") != "flank":
		return
	var tpl: Contract = slot["template"]
	var direction: Vector2 = slot.get("dir", Vector2.RIGHT)
	for f in world.foes:
		if f.type_id not in ["shield_inspector", "signer"] or not _seen.has(f.get_instance_id()):
			continue
		var velocity: Vector2 = _velocity.get(f.get_instance_id(), Vector2.ZERO)
		if velocity.length() < LegionCfg.BOT_MELT_MIN_SPEED \
				or absf(velocity.normalized().dot(direction)) > LegionCfg.BOT_FLANK_DOT:
			continue
		if tpl.live_distance(f.position) > LegionCfg.BOT_THREAT_R:
			continue
		var at := f.position - direction * LegionCfg.BOT_FLANK_DISTANCE
		var half := Vector2(-direction.y, direction.x) * LegionCfg.BOT_RELAY_HALF
		if not world.terrain.segment_clear(at - half, at + half).is_equal_approx(at + half):
			continue
		var pts := PackedVector2Array([at - half, at + half])
		slot["pts"] = pts
		slot["template"] = Contract.new().build(pts, int(slot["side"]),
			world.terrain.walkable, LegionCfg.KIND_LABORER)
		return


## Прогноз учитывает конкурирующие договоры: нельзя обещать одного бойца двум линиям.
func _recruits(candidate: Contract) -> int:
	var lines: Array[Contract] = world.contracts.contracts.duplicate()
	lines.append(candidate)
	var count := 0
	for entry in LegionStaff.deployment_plan(world.contracts, lines, candidate):
		if entry["contract"] == candidate:
			count += 1
	return count


func _place(pts: PackedVector2Array, side: int, kind: StringName,
		direction: Vector2, minimum: int) -> Contract:
	kind = LegionChallenge.bot_kind(world.dev, kind)
	var preview := Contract.new().build(pts, side, world.terrain.walkable, kind)
	preview.set_dir(direction)
	if _recruits(preview) < minimum:
		return null
	var c := world.contracts.add_contract(pts, side, true, kind)
	if c != null:
		c.set_dir(direction)
		# Иначе второй рубеж того же раздумья посчитает уже обещанных бойцов свободными.
		world._assign_free()
	return c


## Поддержка строится тем же платным штрихом; существующая геометрия карты не меняется.
func _add_support_slots() -> void:
	if not world.staff.kind_unlocked(LegionCfg.KIND_CLERK):
		return
	var primary := slots.duplicate()
	for slot in primary:
		if slot.get("role", "front") != "front":
			continue
		var supported := false
		for hint in primary:
			if hint.get("id", "") != slot.get("support_id", ""):
				continue
			var tpl: Contract = hint["template"]
			var front: Contract = slot["template"]
			supported = hint["kind"] != slot["kind"] and tpl.live_distance(
				front.point_at(front.length * 0.5)) <= LegionCfg.PACKAGE_R
		if supported:
			continue
		var pts: PackedVector2Array = slot["pts"].duplicate()
		var direction: Vector2 = slot["dir"]
		for i in pts.size():
			pts[i] -= direction * LegionCfg.BOT_SUPPORT_OFFSET
		slots.append({"pts": pts, "side": slot["side"], "kind": LegionCfg.KIND_CLERK,
			"dir": direction, "role": "back", "id": String(slot["id"]) + "_support",
			"support_id": slot["id"], "next_ids": slot["next_ids"],
			"min_units": LegionCfg.BOT_MIN_SQUAD, "reserve": false, "contracts": [],
			"template": Contract.new().build(pts, slot["side"], Callable(), LegionCfg.KIND_CLERK)})


func _request_relay(slot: Dictionary, kind: StringName) -> void:
	var key := String(slot.get("id", "")) + String(kind)
	if _relays.has(key):
		return
	var tpl: Contract = slot["template"]
	var target := tpl.point_at(tpl.length * 0.5)
	var best: Legionnaire = null
	var distance := INF
	for u in world.units:
		if u.alive and u.kind == kind and u.state == Legionnaire.State.FREE:
			var d := u.position.distance_to(target)
			if d < distance:
				distance = d
				best = u
	if best == null:
		return
	var waypoint := _relay_waypoint(slot, best.position, target)
	var path := world.contracts.recruit_path(best.position, waypoint)
	if path.is_empty():
		return
	var at := best.position
	var remaining := LegionCfg.BOT_RELAY_STEP
	for point in path:
		var length := at.distance_to(point)
		if length >= remaining:
			at = at.move_toward(point, remaining)
			break
		remaining -= length
		at = point
	var direction := (target - at).normalized()
	var half := Vector2(-direction.y, direction.x) * LegionCfg.BOT_RELAY_HALF
	var c := _place(PackedVector2Array([at - half, at + half]), 1, kind,
		direction, int(slot.get("min_units", LegionCfg.BOT_MIN_SQUAD)))
	if c != null:
		_relays[key] = {"c": c, "slot": slot, "started": world.now}
		world.stats["relay_contracts"] += 1


## Граф подсказок задаёт перевалочные рубежи; A* проверяет каждый переход через рельеф.
func _relay_waypoint(slot: Dictionary, origin: Vector2, target: Vector2) -> Vector2:
	var nearest := origin.distance_to(target)
	var result := target
	for hint in slots:
		if not hint.get("next_ids", []).has(slot.get("id", "")):
			continue
		var tpl: Contract = hint["template"]
		var at := tpl.point_at(tpl.length * 0.5)
		var distance := origin.distance_to(at)
		if distance > LegionCfg.BOT_RELAY_STEP and distance < nearest \
				and at.distance_to(target) < origin.distance_to(target):
			if not world.contracts.recruit_path(origin, at).is_empty():
				nearest = distance
				result = at
	return result


## Доставка одинакова для всех политик: по прибытии промежуточный приказ завершён.
## Натиск — настоящий выпуск, затем свободных бойцов набирает следующий шаг цепочки.
func _relay_step() -> void:
	for key in _relays.keys():
		var c: Contract = _relays[key]["c"]
		if not world.contracts.contracts.has(c):
			_relays.erase(key)
			continue
		var marching := false
		var posted := 0
		for post in c.posts:
			var u: Legionnaire = post["unit"]
			if u != null:
				marching = marching or u.state == Legionnaire.State.MARCH
				posted += int(u.state == Legionnaire.State.POSTED)
		if (not marching and posted > 0) or world.now - float(
				_relays[key]["started"]) >= LegionCfg.BOT_V16_RELAY_TIMEOUT:
			for seg in c.seg_count():
				world.contracts.release(c, seg)
			_relays.erase(key)
		elif not marching and posted == 0:
			# Потерянный резерв не удерживает пустой приказ и его назначение навсегда.
			for seg in c.seg_count():
				world.contracts.release(c, seg)
			_relays.erase(key)
		else:
			for seg in c.seg_count():
				if c.seg_alive(seg) and c.seg_left(seg) < LegionCfg.BOT_REFRESH_LEAD:
					world.contracts.refresh(c, PackedInt32Array([seg]), true)


func _hero_step() -> void:
	if world.hero == null:
		return
	var corpse: Foe = null
	var strength := -INF
	var corpses: Array = []
	corpses.append_array(world.foes)
	corpses.append_array(world._corpses)
	for candidate in corpses:
		if not candidate is Foe:
			continue
		var f := candidate as Foe
		if f.is_fresh_corpse() and f.visible and not f.has_meta(&"summoned") \
				and _near_front(f.position):
			var value := float(f.def["hp"]) * float(f.def["dmg"])
			if value > strength:
				strength = value
				corpse = f
	if corpse != null and world.hero.cd_left(LegionHero.SLOT_W) <= 0.0:
		world.hero.cast(LegionHero.SLOT_W, corpse.position)
	_brace_bent_line()
	for f in world.foes:
		if not _seen.has(f.get_instance_id()) or not f.is_active():
			continue
		if f.type_id == "signer" or world.grid.count_foes_near(f.position,
				LegionCfg.BOT_Q_CLUSTER_R) >= LegionCfg.BOT_Q_CLUSTER:
			world.hero.cast(LegionHero.SLOT_Q, f.position)
		if f.type_id == "boss":
			world.hero.cast(LegionHero.SLOT_E, f.position)
	for c in world.contracts.contracts:
		for seg in c.seg_count():
			if world.contracts.in_package(c, seg) \
					and c.seg_left(seg) <= LegionCfg.BOT_PACKAGE_RELEASE_LEAD:
				world.hero.cast(LegionHero.SLOT_E, c.seg_center(seg))


## v20 (D-0926-39): Е — по самому прогнутому занятому участку, пока «Прорыв!» не случился: под
## «Авралом» строй держит напор вдвое. Прогиб — красная дуга у кольца срока, её видит и человек.
func _brace_bent_line() -> void:
	if world.hero.cd_left(LegionHero.SLOT_E) > 0.0 or not world.press_on():
		return
	var best_c: Contract = null
	var best_s := -1
	var best := BOT_E_BEND
	for c in world.contracts.contracts:
		for s in c.seg_count():
			if c.seg_alive(s) and c.bend_frac(s) >= best and c.seg_manned(s) >= BOT_E_MIN_MEN:
				best = c.bend_frac(s)
				best_c = c
				best_s = s
	if best_c != null and world.hero.cast(LegionHero.SLOT_E, best_c.seg_center(best_s)):
		world.stats["bot_e_brace"] = int(world.stats.get("bot_e_brace", 0)) + 1


func _near_front(at: Vector2) -> bool:
	for u in world.units:
		if u.alive and u.position.distance_to(at) <= LegionCfg.BOT_CORPSE_FRONT_R:
			return true
	return false


## В пакете выпускаем только передний вид: тыл остаётся занят ради печати расчёта.
func _plan_package(slot: Dictionary) -> void:
	if slot.get("role", "") == "back":
		return
	for c: Contract in slot["contracts"]:
		for seg in c.seg_count():
			if not world.contracts.seal_ready(c, seg):
				continue
			if world.grid.count_foes_near(c.seg_center(seg), LegionCfg.BOT_THREAT_R) == 0:
				slot["melt_contract"] = c
				slot["melt_seg"] = seg
				return
			for f in world.foes:
				if not _seen.has(f.get_instance_id()):
					continue
				var eta := _melt_eta(c, seg, f)
				if eta >= 0.0 and eta <= c.seg_left(seg) + LegionCfg.BOT_PACKAGE_RELEASE_LEAD:
					slot["melt_contract"] = c
					slot["melt_seg"] = seg
					slot["melt_target"] = f.get_instance_id()
					return
