extends RefCounted
##
## Dev-трасса свиты Прораба (B-478, механизм B-015): `--dev escort_trace=1`. Замер для разбора
## долгой стоянки боя с Прорабом: стоят ли Прораб и свита без драки, копится ли свита, пока
## Прораб в контакте со строем, или свиту просто выбивают по ходу. Причину стоянки трасса не
## доказывает: «idle» — только «стоит, не дерётся и не оглушён» (затор геометрии, давка в колонне,
## ожидание обхода выглядят одинаково); вывод о геометрии — после просмотра кадра/карты.
##
## Печатает строки «ESCORT_TRACE {json}». Префикс не начинается с «{»: парсеры итога и трассы
## (legion_series.sh, legion_balance.py, legion_trace_stats.py) эти строки пропускают.
##   ev=sample — раз в LegionCfg.TRACE_PERIOD игровых секунд, пока жив Прораб или его свита;
##   ev=final  — один раз на измерительный отрезок (seg): итог боя (victory/defeat), новый
##               start_map без итога (restart), загрузка снимка (snapshot), уход мира из дерева
##               без итога (exit — например, --quit-after серии на таймауте).
## Отрезок: seg — номер (0 — от start_map), from — чем открыт ("start" / "snapshot"). Загрузка
## снимка (откат назад, поправка клиента) закрывает отрезок и открывает новый с нулевыми
## счётчиками: история до снимка остаётся в финале прежнего отрезка, сквозной истории через
## откат трасса не обещает. base — живая свита, пришедшая со снимком (по метке META);
## alive == base + spawned − killed − leaked внутри отрезка.
## Свита — только враги, призванные Foe._summon_escort: метку META ставит эта трасса в момент
## призыва. Метку summoned ставят и другие пути (тесты, PvP-проверки), их здесь не считают;
## свиту, призванную при выключенной трассе, снимок в base не приносит (метки нет).
##
## Выключенная трасса — это null в LegionWorld.escort_trace: мир и враг проверяют только его,
## бой, RNG, stats, итог и обычная --trace не меняются. Включённая пишет только метку META на
## своих врагах (её видит снимок NetSnap, бой её не читает). Ключ — локальный: снимок его не
## переносит и по нему не перестраивает мир (SnapWorld.VIEW_DEV_KEYS).
##
## Счётчики spawned/killed/leaked/alive/peak/roars — по событиям, точные в любой момент.
## Секунды состояний — по выборкам раз в период, приближение с шагом периода.
##

const PREFIX := "ESCORT_TRACE "
## Метка свиты этой трассы на Foe (значение true). Снимается при смерти/прорыве — повторное
## событие о том же враге счётчики не двигает.
const META := &"escort_trace"
## Сдвиг за период меньше этого — враг «стоял» (px за ~1 с; шаг Прораба 22 px/с).
const STALL_PX := 4.0

var world: LegionWorld = null
## Куда уходит строка; пусто — print. Тест подменяет, чтобы читать вывод.
var sink := Callable()
var map_id := ""
## Измерительный отрезок: номер и чем открыт ("start" — start_map, "snapshot" — load_snapshot).
var segment := 0
var seg_from := "start"
var spawned := 0
var killed := 0
var leaked := 0
var alive := 0
var peak := 0
## Живая свита с меткой META в момент открытия отрезка (после снимка; от start_map — 0).
var base := 0
## Рёвы-призывы (одна волна свиты = один рёв).
var roars := 0
var samples := 0
## Секунды Прораба (по выборкам): шёл / осаждал / стоял оглушённым / стоял в контакте (драка,
## таран, бойцы рядом) / стоял без всего этого (idle — причина не установлена).
var boss_walk_s := 0.0
var boss_siege_s := 0.0
var boss_stun_s := 0.0
var boss_contact_s := 0.0
var boss_idle_s := 0.0
## Враго-секунды свиты (по выборкам): в драке / оглушена / стоит без драки и оглушения.
var esc_eng_s := 0.0
var esc_stun_s := 0.0
var esc_idle_s := 0.0
## Первая выборка отрезка, где Прораб жив (−1 — не видели), и его смерть в отрезке (−1 — нет).
var boss_seen_t := -1.0
var boss_dead_t := -1.0
var last_sample: Dictionary = {}
var final: Dictionary = {}
var _open := false
var _t := 0.0
var _last_t := 0.0
## Foe → позиция на прошлой выборке (Прорабы и свита); пересобирается каждой выборкой.
var _pos: Dictionary = {}


## Новый отрезок на текущем состоянии мира: часы — с now, живая свита с меткой — в base.
func _init(w: LegionWorld, seg := 0, from := "start") -> void:
	world = w
	map_id = w.map_id
	segment = seg
	seg_from = from
	_last_t = w.now
	for f in w.foes:
		if f.alive and f.has_meta(META):
			base += 1
	alive = base
	peak = base
	_open = w.phase == LegionWorld.Phase.BATTLE


## Шаг мира (LegionWorld._step): выборка раз в период, как у --trace (первая — на первом шаге).
func tick(dt: float) -> void:
	if not _open:
		return
	_t -= dt
	if _t > 0.0:
		return
	_t = LegionCfg.TRACE_PERIOD
	_sample()


## Foe._summon_escort: начало призыва.
func on_roar(_boss: Foe) -> void:
	if _open:
		roars += 1


## Foe._summon_escort: призван f (null — не встал, не считаем).
func on_summon(_boss: Foe, f: Foe) -> void:
	if f == null or not _open:
		return
	f.set_meta(META, true)
	spawned += 1
	alive += 1
	peak = maxi(peak, alive)


## Враг ушёл из боя: убит (LegionWorld.on_foe_died) или дошёл до Котла (foe_reached_cauldron).
## Не свита этой трассы — ничего; Прораб — запоминаем время смерти.
func on_gone(f: Foe, is_leak: bool) -> void:
	if not _open:
		return
	if f.type_id == "boss":
		if not is_leak and boss_dead_t < 0.0:
			boss_dead_t = snappedf(world.now, 0.01)
		return
	if not f.has_meta(META):
		return
	f.remove_meta(META)
	alive -= 1
	if is_leak:
		leaked += 1
	else:
		killed += 1
	_pos.erase(f)


## Финальная строка отрезка; повторный вызов (итог, затем выход движка) ничего не печатает.
func finish(end: StringName) -> void:
	if not _open:
		return
	_open = false
	var bosses: Array = []
	for f in world.foes:
		if f.alive and f.type_id == "boss":
			bosses.append(_boss_view(f))
	final = _head("final")
	final["end"] = String(end)
	final["samples"] = samples
	final["roars"] = roars
	final["esc"] = _esc_counts().merged({"eng_s": snappedf(esc_eng_s, 0.1),
		"stun_s": snappedf(esc_stun_s, 0.1), "idle_s": snappedf(esc_idle_s, 0.1)})
	final["boss"] = {"alive": bosses.size(), "killed": int(world.stats.get("boss_killed", 0)),
		"seen_t": boss_seen_t, "dead_t": boss_dead_t,
		"walk_s": snappedf(boss_walk_s, 0.1), "siege_s": snappedf(boss_siege_s, 0.1),
		"stun_s": snappedf(boss_stun_s, 0.1), "contact_s": snappedf(boss_contact_s, 0.1),
		"idle_s": snappedf(boss_idle_s, 0.1), "last": bosses}
	_emit(final)


# ── Выборка ─────────────────────────────────────────────────────────────────

func _sample() -> void:
	var span := world.now - _last_t
	_last_t = world.now
	var bosses: Array[Foe] = []
	var escorts: Array[Foe] = []
	for f in world.foes:
		if not f.alive:
			continue
		if f.type_id == "boss":
			bosses.append(f)
		elif f.has_meta(META):
			escorts.append(f)
	var rows: Array = []
	for b in bosses:
		rows.append(_boss_row(b, span))
	var near := 0
	var eng := 0
	var stun := 0
	var idle := 0
	var r2 := LegionCfg.BOSS_RAM_RANGE * LegionCfg.BOSS_RAM_RANGE
	for f in escorts:
		if f.is_stunned():
			stun += 1
		elif f._trace_engaged():
			eng += 1
		else:
			var moved := _moved(f)
			if moved >= 0.0 and moved < STALL_PX:
				idle += 1
		for b in bosses:
			if f.position.distance_squared_to(b.position) <= r2:
				near += 1
				break
	esc_eng_s += float(eng) * span
	esc_stun_s += float(stun) * span
	esc_idle_s += float(idle) * span
	_pos.clear()
	for f in bosses + escorts:
		_pos[f] = f.position
	if bosses.is_empty() and escorts.is_empty():
		return
	if boss_seen_t < 0.0 and not bosses.is_empty():
		boss_seen_t = snappedf(world.now, 0.01)
	samples += 1
	last_sample = _head("sample")
	last_sample["esc"] = _esc_counts().merged({"near": near, "eng": eng, "stun": stun,
		"idle": idle})
	last_sample["boss"] = rows
	_emit(last_sample)


## Строка Прораба для выборки + учёт интервала. Порядок: осада, шёл, оглушён, контакт (драка,
## таран или бойцы ближе BOSS_RAM_RANGE), иначе idle — стоял без всего этого.
func _boss_row(b: Foe, span: float) -> Dictionary:
	var row := _boss_view(b)
	var moved := _moved(b)
	row["moved"] = snappedf(moved, 0.1)
	if moved < 0.0:
		return row   # первая выборка с этим Прорабом: интервала ещё нет
	if String(row["state"]) == "siege":
		boss_siege_s += span
	elif moved >= STALL_PX:
		boss_walk_s += span
	elif float(row["stun"]) > 0.0:
		boss_stun_s += span
	elif bool(row["eng"]) or String(row["ram"]) != "" or int(row["units"]) > 0:
		boss_contact_s += span
	else:
		boss_idle_s += span
	return row


## Состояние Прораба без учёта интервала (и для финальной строки).
func _boss_view(b: Foe) -> Dictionary:
	var near := 0
	var posted := 0
	var r2 := LegionCfg.BOSS_RAM_RANGE * LegionCfg.BOSS_RAM_RANGE
	for u in world.units:
		if u.alive and u.position.distance_squared_to(b.position) <= r2:
			near += 1
			if u.state == Legionnaire.State.POSTED:
				posted += 1
	var row := {
		"hp": snappedf(b.hp, 0.1), "max": snappedf(b.max_hp, 0.1),
		"pos": [snappedf(b.position.x, 0.1), snappedf(b.position.y, 0.1)],
		"d": snappedf(b.position.distance_to(world.cauldron_of(b.goal_side)), 0.1),
		"units": near, "posted": posted,
	}
	if world.pvp:
		row["side"] = b.goal_side
	row.merge(b._trace_state())
	return row


## Сдвиг с прошлой выборки; −1 — на прошлой выборке этого врага не было.
func _moved(f: Foe) -> float:
	if not _pos.has(f):
		return -1.0
	return f.position.distance_to(_pos[f])


func _head(ev: String) -> Dictionary:
	return {"ev": ev, "seg": segment, "from": seg_from, "t": snappedf(world.now, 0.01),
		"map": map_id}


func _esc_counts() -> Dictionary:
	return {"spawned": spawned, "alive": alive, "killed": killed, "leaked": leaked,
		"peak": peak, "base": base}


func _emit(d: Dictionary) -> void:
	var line := PREFIX + JSON.stringify(d)
	if sink.is_valid():
		sink.call(line)
	else:
		print(line)
