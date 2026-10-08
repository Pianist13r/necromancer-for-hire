# gdlint: disable=max-public-methods
class_name LegionStaff
extends RefCounted
##
## Штат боя (пакет staff, DESIGN_V15 §5, §12 п.4): Котёл и постройки как источники бойцов,
## участки карты под застройку, души. Логика вынесена из legion_world.gd (он и так > 1000
## строк): мир держит только поля API (`souls`, `buildings`) и короткие вызовы сюда.
##
## Поправки кампании читаются ОДИН раз при старте карты через stat_fn (по умолчанию —
## LegionWorld.camp_stat: вне кампании (in_campaign) нейтральные значения, чтобы серия не
## зависела от сохранения владельца). Тест подменяет stat_fn до start_map.
## API штата включает срочный найм и поиск площадки по сетевому ID (21 публичный метод).
##

var world: LegionWorld = null
## Сторона боя, чей это штат (PvpSide.index; одиночка — 0): души, Котёл, площадки — её.
var side := 0
## Участки карты: {id, pos: Vector2, bot_priority, preferred_kinds: Array, serves_lines: Array,
## building: LegionBuilding или null}.
var plots: Array[Dictionary] = []
var cauldron: LegionBuilding = null
## Callable(key: StringName) -> float. Пусто — world.camp_stat.
var stat_fn: Callable = Callable()

var _cap_mult: Dictionary = {}
var _respawn_mult: Dictionary = {}
var _unlocked: Dictionary = {}
var _soul_frac := 0.0   ## дробный остаток душ за убийства (on_foe_killed)
var _kill_frac := 0.0   ## дробный остаток голов для kills_rewardable (on_foe_killed)
var _safe_share: Dictionary = {}   ## id площадки → доля безопасных рождений (plot_safe_share)


## Новая карта: души, Котёл со стартовым штатом (выдаётся целиком сразу), участки.
## start_army — штат Котла до поправок (из карты или --dev spawn_units).
func setup(w: LegionWorld, map: Dictionary, start_army: int) -> void:
	world = w
	plots.clear()
	_safe_share.clear()
	_soul_frac = 0.0
	_kill_frac = 0.0
	var stat := stat_fn if stat_fn.is_valid() else Callable(w, &"camp_stat")
	for kind: StringName in LegionCfg.KIND_ORDER:
		_cap_mult[kind] = float(stat.call(StringName("cap_mult_" + kind)))
		_respawn_mult[kind] = float(stat.call(StringName("respawn_mult_" + kind)))
		# подрядчик — базовый вид: Котёл его выпускает всегда, закрыть его нечем
		_unlocked[kind] = kind == LegionCfg.KIND_LABORER \
			or float(stat.call(StringName("kind_unlocked_" + kind))) >= 1.0
	_side().souls = LegionCfg.SOULS_START + int(stat.call(&"start_souls"))
	if side == world.local_side:
		world.souls_changed.emit(_side().souls)
	cauldron = _make(LegionCfg.KIND_LABORER, LegionBuilding.SOURCE_CAULDRON,
		world.cauldron_of(side), null)
	cauldron.entry_ring = LegionCfg.CAULDRON_ENTRY_RING
	# Поздние карты ограничивают пополнение резерва: общий интервал 6 с превращал
	# усиление волн в сотни бесплатных возрождений. Мета применяется поверх числа карты.
	cauldron.set_staff(staff_cap(LegionCfg.KIND_LABORER, start_army),
		staff_respawn(LegionCfg.KIND_LABORER,
			float(map.get("cauldron_respawn", LegionCfg.CAULDRON_RESPAWN))))
	cauldron.fill_now(_budget())
	for entry: Dictionary in map.get("plots", []):
		# PvP: площадки своей половины (поле side карты); одиночка — все
		if int(entry.get("side", 0)) != side:
			continue
		var p: Array = entry.get("pos", [0, 0])
		plots.append({
			"id": String(entry.get("id", "p%d" % plots.size())),
			"pos": Vector2(float(p[0]), float(p[1])),
			"bot_priority": float(entry.get("bot_priority", 0.0)),
			"preferred_kinds": entry.get("preferred_kinds", []),
			"serves_lines": entry.get("serves_lines", []),
			"building": null,
		})


## Склеп: постройка подрядчиков, заморожена до захвата (места выдаются при первом захвате).
func make_crypt_building(crypt: Node2D) -> LegionBuilding:
	var b := _make(LegionCfg.KIND_LABORER, LegionBuilding.SOURCE_CRYPT, crypt.position, crypt)
	b.position = Vector2.ZERO
	b.entry = crypt.position + LegionCfg.CRYPT_SPAWN_OFFSET
	b.frozen = true
	b.set_staff(staff_cap(LegionCfg.KIND_LABORER, paced(LegionCfg.CRYPT_STAFF)),
		staff_respawn(LegionCfg.KIND_LABORER, LegionCfg.CRYPT_RESPAWN))
	return b


## Шаг кадра: таймеры мест всех построек под общим потолком армии.
func tick(dt: float) -> void:
	var budget := _budget()
	for b: LegionBuilding in world.buildings:
		if b.side == side:
			budget -= b.tick(dt, maxi(0, budget))


## Штат после темпа читаемости (LegionCfg.STAFF_PACE): к ближайшему, не меньше 1.
static func paced(base: int) -> int:
	return maxi(1, roundi(float(base) * LegionCfg.STAFF_PACE))


func staff_cap(kind: StringName, base: int) -> int:
	return int(round(float(base) * float(_cap_mult.get(kind, 1.0))))


func staff_respawn(kind: StringName, base: float) -> float:
	return base * float(_respawn_mult.get(kind, 1.0))


## Сумма штатов всех построек под жёстким потолком — «лимит армии» для HUD и тестов.
func total_cap() -> int:
	var n := 0
	for b: LegionBuilding in world.buildings:
		if not b.frozen and b.side == side:
			n += b.cap
	return mini(n, LegionCfg.ARMY_HARD_CAP)


func kind_unlocked(kind: StringName) -> bool:
	return bool(_unlocked.get(kind, false))


## B-344: ближний набор сохраняет приоритет, дальний резерв занимает остаток.
## План без побочных эффектов: бот может оценить тот же автомарш перед платным штрихом.
## Порядок бойцов/мест устойчив; ручное удержание не отменяется старой линией.
static func deployment_plan(field: ContractField, lines: Array[Contract]) -> Array[Dictionary]:
	var plan := field.assignment_plan(lines)
	plan = plan.filter(func(a: Dictionary) -> bool: return a["unit"].held_t <= 0.0)
	var chosen: Dictionary = {}
	var taken: Array[Dictionary] = []
	for a in plan:
		chosen[a["unit"]] = true
		taken.append(a["post"])
	var vacant: Array[Dictionary] = []
	for c in lines:
		if ContractField.is_stump(c):
			continue   # B-345: пенёк гаснет на ближайшем шаге — бойцов не набирает
		for p in c.posts:
			if not p["dead"] and p["unit"] == null and not taken.has(p) \
					and c.seg_alive(int(p["seg"])):
				vacant.append({"contract": c, "post": p})
	for u in field.world.units:
		if vacant.is_empty():
			break
		if chosen.has(u) or not _can_deploy(u, field):
			continue
		var best := -1
		var distance := INF
		var path := PackedVector2Array()
		for i in vacant.size():
			var c: Contract = vacant[i]["contract"]
			var p: Dictionary = vacant[i]["post"]
			if c.kind != u.kind or c.id == u.no_return_id:
				continue
			var d := u.position.distance_squared_to(p["pos"])
			if d >= distance:
				continue
			var route := field.recruit_path(u.position, p["pos"])
			if route.is_empty():
				continue
			best = i
			distance = d
			path = route
		if best >= 0:
			var a: Dictionary = vacant[best].duplicate()
			a.merge({"unit": u, "path": path, "automarch": true})
			plan.append(a)
			vacant.remove_at(best)
	return plan


static func _can_deploy(u: Legionnaire, field: ContractField) -> bool:
	if not u.alive or u.side != field.owner_side or u.state != Legionnaire.State.FREE \
			or u.is_stunned() or u.held_t > 0.0:
		return false
	var w := field.world
	if w.pvp and w.grid.enemy_cauldron(u.position, float(u.spec["reach"]), u.side) != null:
		return false   # Осаждающий Котёл занят: не бронирует пустое место в далёком тылу.
	if w.grid.nearest_hostile_in_zone(u.position, LegionCfg.ASSIGN_BUSY_R, u.side,
			u.position, LegionCfg.ASSIGN_BUSY_R) != null:
		return false
	# Резерв, уже способный перехватить врага у Котла, не уводим на дальнюю линию.
	return w.grid.nearest_hostile_in_zone(u.position, LegionCfg.HOME_GUARD_PURSUE,
		u.side, w.cauldron_of(u.side), LegionCfg.HOME_GUARD_R) == null


## Новая линия рядом — явный приказ: отменяет удержание только своего вида/стороны.
static func release_held(w: LegionWorld, c: Contract) -> void:
	var field := w.sides[c.owner_side].contracts
	var radius := float(field.recruit_r.get(c.kind, LegionCfg.RECRUIT_R))
	for u in w.units:
		if u.alive and u.side == c.owner_side and u.kind == c.kind and u.held_t > 0.0 \
				and c.live_distance(u.position) <= radius:
			u.held_t = 0.0
			if u.state == Legionnaire.State.RALLY:
				u.set_free()


## B-043: доля безопасных рождений площадки — выборка того же _plot_spawn, что при рождении, своим
## ГСЧ (просмотр меню не расходует боевой RNG). Считается раз на площадку за карту: дорога и
## рельеф не меняются, а 300 рождений на каждое открытие меню — лишняя работа.
func plot_safe_share(p: Dictionary) -> float:
	var key: String = String(p["id"])
	if _safe_share.has(key):
		return _safe_share[key]
	var b := LegionBuilding.new()
	b.world = world
	b.side = side
	b.source = LegionBuilding.SOURCE_PLOT
	b.position = p["pos"]
	b.entry = b.position + LegionCfg.BUILDING_ENTRY_OFFSET
	b.entry_ring = LegionCfg.BUILDING_ENTRY_RING
	var share := b.plot_safe_share()
	b.free()
	_safe_share[key] = share
	return share


## Больше половины пополнения (порог PLOT_SAFE_WARN) рождается у дороги, под удар.
func plot_near_road(p: Dictionary) -> bool:
	return plot_safe_share(p) < LegionCfg.PLOT_SAFE_WARN


# ── Участки и постройки ─────────────────────────────────────────────────────

## Площадка (пустая или застроенная) под точкой: попадание в видимый спрайт площадки/постройки
## или не дальше r от её центра; из нескольких — ближайшая по центру. {} — нет такой.
## Почему спрайт, а не только радиус: площадка рисуется 72 px шириной, радиус 28 px промахивался
## по её краю — игрок видел, что попал, а меню не открывалось.
func plot_at(pos: Vector2, r: float = LegionCfg.PLOT_PICK_R) -> Dictionary:
	var best: Dictionary = {}
	var best_d := INF
	for p in plots:
		var center: Vector2 = p["pos"]
		var d := center.distance_squared_to(pos)
		if d > r * r and not plot_rect(p).has_point(pos):
			continue
		if d < best_d:
			best_d = d
			best = p
	return best


## Прямоугольник видимого спрайта площадки в мире (пустая — `plot_empty`, застроенная — спрайт
## постройки её вида и уровня). Нет текстуры — пустой Rect2, выбор идёт только по радиусу.
func plot_rect(p: Dictionary) -> Rect2:
	var b: LegionBuilding = p["building"]
	var tex: Texture2D = null
	var rect := Rect2()
	if b == null:
		tex = LegionBuilding.sprite("plot_empty")
		if tex != null:
			rect = LegionBuilding.sprite_rect(
				tex, LegionCfg.PLOT_SPRITE_W, LegionCfg.PLOT_SPRITE_ANCHOR_Y)
	else:
		tex = LegionBuilding.sprite("%s_%d" % [b.kind, b.level])
		if tex != null:
			rect = LegionBuilding.sprite_rect(
				tex, LegionCfg.BUILDING_SPRITE_W, LegionCfg.BUILDING_SPRITE_ANCHOR_Y)
	if tex == null:
		return Rect2()
	rect.position += p["pos"] as Vector2
	return rect


static func build_price(kind: StringName) -> int:
	return int(LegionCfg.BUILDINGS[kind]["price"])


## Цена улучшения до следующего уровня; -1 — уровень максимальный.
static func upgrade_price(b: LegionBuilding) -> int:
	if b.level >= LegionCfg.BUILDING_MAX_LEVEL:
		return -1
	return int(LegionCfg.BUILDINGS[b.kind]["upgrade"][b.level - 1])


## Срочный найм бота (D-0927-135; здесь, а не в legion_bot.gd — тот упёрся в 1000 строк gdlint):
## самая выбитая постройка (ждут ≥ BOT_RUSH_FRAC штата и ≥ BOT_RUSH_MIN мест), если после
## найма останется на любую плановую покупку — самую дорогую из постройки на пустой площадке
## (любого открытого вида) и улучшения. Почему самую дорогую: с резервом «на самую дешёвую»
## бот середины кампании на «Двух отделах» проедал души наймом и не достраивался (стройка
## 1170 → 560 душ, побед 9 → 4 из 10, серия economy/after). Найм — после стройки, не вместо.
## Как человек: пару павших не выкупаешь, выбитый строй — да, но не в ущерб стройке.
## --dev no_rush=1 — без найма (замер на одном коде). true — нанял (действие раздумья занято).
static func bot_rush(w: LegionWorld) -> bool:
	if int(w.dev.get("no_rush", 0)) == 1:
		return false
	var best: LegionBuilding = null
	var reserve := 0
	for p: Dictionary in w.staff.plots:
		var b: LegionBuilding = p["building"]
		if b == null:
			for kind: StringName in LegionCfg.KIND_ORDER:
				if w.staff.kind_unlocked(kind):
					reserve = maxi(reserve, build_price(kind))
			continue
		reserve = maxi(reserve, upgrade_price(b))
		var waiting := b.waiting_count()
		if waiting >= maxi(LegionCfg.BOT_RUSH_MIN, ceili(b.cap * LegionCfg.BOT_RUSH_FRAC)) \
				and (best == null or waiting > best.waiting_count()):
			best = b
	if best == null or w.souls - w.staff.rush_price(best) < reserve:
		return false
	return w.staff.rush(best) > 0


## Цена срочного найма одного бойца постройки (по виду).
static func rush_each(b: LegionBuilding) -> int:
	return int(LegionCfg.RUSH_HIRE_PRICE[b.kind])


static func sell_value(b: LegionBuilding) -> int:
	return int(floor(float(b.invested) * LegionCfg.BUILDING_SELL_FRAC))


func can_build(plot: Dictionary, kind: StringName) -> bool:
	return not plot.is_empty() and plot["building"] == null and LegionCfg.BUILDINGS.has(kind) \
		and kind_unlocked(kind) and _side().souls >= build_price(kind)


func build(plot: Dictionary, kind: StringName) -> LegionBuilding:
	if not can_build(plot, kind):
		return null
	var price := build_price(kind)
	add_souls(-price)
	var b := _make(kind, LegionBuilding.SOURCE_PLOT, plot["pos"], null)
	b.plot_id = plot["id"]
	b.invested = price
	_apply_level(b)
	plot["building"] = b
	world.stats["buildings_built"] = int(world.stats.get("buildings_built", 0)) + 1
	world.building_changed.emit(b)
	return b


func can_upgrade(b: LegionBuilding) -> bool:
	var price := upgrade_price(b)
	return b.source == LegionBuilding.SOURCE_PLOT and price >= 0 and _side().souls >= price


func upgrade(b: LegionBuilding) -> bool:
	if not can_upgrade(b):
		return false
	var price := upgrade_price(b)
	add_souls(-price)
	b.invested += price
	b.level += 1
	b.refresh_artwork()
	_apply_level(b)
	world.building_changed.emit(b)
	return true


## Срочный найм (D-0927-135, B-085): души в бою после того, как площадки застроены, тратить
## было не на что (новичок 180f1168: 726–874 непотраченных к концу карты). Найм — повторяемая
## трата «здесь и сейчас»: после потерь под печатями вернуть строй постройки сразу, а не через
## таймеры возрождения. Цена — за каждое место павшего, по виду (LegionCfg.RUSH_HIRE_PRICE).
## Найм — расход, а не вложение: invested не растёт, продажа его не возвращает.
## Цена найма сейчас; 0 — нанимать некого (или упёрлись в потолок армии).
func rush_price(b: LegionBuilding) -> int:
	return _rush_count(b) * rush_each(b)


## Нанять; 0 — не вышло (некого или не хватает душ). Возвращает число нанятых.
func rush(b: LegionBuilding) -> int:
	var count := _rush_count(b)
	if count <= 0 or _side().souls < count * rush_each(b):
		return 0
	var n := b.rush_fill(count)
	var price := n * rush_each(b)
	add_souls(-price)
	world.stats["rush_hires"] = int(world.stats.get("rush_hires", 0)) + 1
	world.stats["rush_units"] = int(world.stats.get("rush_units", 0)) + n
	world.stats["rush_souls"] = int(world.stats.get("rush_souls", 0)) + price
	world.building_changed.emit(b)
	return n


## Продажа: 50 % вложенного назад, бойцы постройки гибнут без возрождения.
func sell(b: LegionBuilding) -> int:
	if b.source != LegionBuilding.SOURCE_PLOT:
		return 0
	var back := sell_value(b)
	b.dismiss_all()
	for p in plots:
		if p["building"] == b:
			p["building"] = null
	world.buildings.erase(b)
	b.queue_free()
	add_souls(back)
	world.building_changed.emit(b)
	return back


# ── События боя ─────────────────────────────────────────────────────────────

func add_souls(n: int) -> void:
	if n == 0:
		return
	var s := _side()
	s.souls = maxi(0, s.souls + n)
	if side == world.local_side:
		world.souls_changed.emit(s.souls)


func on_unit_died(u: Legionnaire) -> void:
	if u.home is LegionBuilding:
		(u.home as LegionBuilding).on_unit_lost(u)


## Убийство: души по типу врага; призванные (свита Прораба) не дают ни душ, ни счёта для
## опыта/премии — stats.kills_rewardable читает пакет meta. Возвращает начисленные души.
func on_foe_killed(f: Foe) -> int:
	if f.has_meta(&"summoned"):
		return 0
	# опыт кампании — за прежние головы: поредевший враг весит souls_mult (LegionChallenge.heads),
	# дробь копится, счёт остаётся целым
	_kill_frac += LegionChallenge.heads(f)
	var heads := maxi(0, roundi(_kill_frac))
	_kill_frac -= float(heads)
	world.stats["kills_rewardable"] = int(world.stats.get("kills_rewardable", 0)) + heads
	var n := LegionChallenge.foe_souls(f)
	if f.elite:
		# премия элитного — сверх веса головы, не ×вес: шанс элитного у поредевшего уже ×вес
		# (LegionItems.roll_elite), иначе души элитных на бой выросли бы вдвое
		n += float(LegionCfg.SOULS_PER_FOE.get(f.type_id, 0)) * (CfgItems.ELITE_SOULS_MULT - 1.0)
	# Темп D-0927-49: у поредевшей группы душа за врага дробная (3 × 5/3) — дробь копится,
	# иначе округление каждой смерти сдвигало бы души волны.
	# Округление к ближайшему, остаток (±) переносится на следующее убийство: одиночное
	# убийство платит как прежде round(), а сумма за волну не плывёт.
	_soul_frac += n * world.item_mult(&"souls", side)   # «Премия квартала»
	var got := maxi(0, roundi(_soul_frac))
	_soul_frac -= float(got)
	add_souls(got)
	return got


func on_wave_cleared() -> void:
	add_souls(LegionCfg.SOULS_WAVE)


func _apply_level(b: LegionBuilding) -> void:
	var data: Dictionary = LegionCfg.BUILDINGS[b.kind]
	var i := b.level - 1
	b.set_staff(staff_cap(b.kind, paced(int(data["cap"][i]))),
		staff_respawn(b.kind, float(data["respawn"][i])))


func _make(kind: StringName, source: StringName, at: Vector2, parent: Node) -> LegionBuilding:
	var b := LegionBuilding.new().configure(world, kind, source, at)
	b.side = side
	# «Бодрый выход» (перк) удалён вместе с перками героя (D-1006-11): brisk_exit остаётся на
	# постройке выключенным, механизм в building.gd/snap_staff.gd сохранён для будущего источника.
	if parent != null:
		parent.add_child(b)
	else:
		world.entities.add_child(b)
	world.buildings.append(b)
	world.building_changed.emit(b)
	return b


func _budget() -> int:
	return maxi(0, LegionCfg.ARMY_HARD_CAP - world.army_alive(side))


func _side() -> PvpSide:
	return world.sides[side]


## Площадка своей стороны по id (API команд PLOT); {} — нет такой у этой стороны.
func plot_by_id(id: String) -> Dictionary:
	for p in plots:
		if String(p["id"]) == id:
			return p
	return {}


## Сколько мест павших можно занять срочным наймом сейчас (Котёл и склеп не нанимают — у них
## нет меню площадки).
func _rush_count(b: LegionBuilding) -> int:
	if b == null or b.source != LegionBuilding.SOURCE_PLOT:
		return 0
	return mini(b.waiting_count(), _budget())
