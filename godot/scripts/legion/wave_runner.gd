class_name WaveRunner
extends RefCounted
## Независимые очереди сохраняют хвосты волн при нахлёсте; часы стоят вместе с обучением.

enum Phase { PAUSE, RUN, DONE }

var world: LegionWorld = null
var waves: Array = []
var index := -1
var phase := Phase.PAUSE
var timer := 0.0
var held := false
var _runs: Array[Dictionary] = []
var _clock := 0.0
var _due := INF
var _last_call := -INF
var _last_start := -INF
var _called_since_tick := false


func setup(w: LegionWorld, map: Dictionary) -> void:
	world = w
	waves = map.get("waves", [])
	index = -1
	_runs.clear()
	_clock = 0.0
	_last_call = -INF
	_last_start = -INF
	_called_since_tick = false
	held = false
	phase = Phase.PAUSE if not waves.is_empty() else Phase.DONE
	_due = float(waves[0].get("pause", LegionCfg.WAVE_PAUSE_DEFAULT)) if total() > 0 else INF
	timer = next_start_in()


func total() -> int:
	return waves.size()


func wave_no() -> int:
	return index + 1


func remaining_in_queue() -> int:
	var n := 0
	for run in _runs:
		n += (run["queue"] as Array).size() - int(run["qi"])
	return n


## INF означает: ждём клира, момент ещё неизвестен; -1 — следующих волн нет.
func next_start_in() -> float:
	if index + 1 >= total():
		return -1.0
	return maxf(0.0, _due - _clock)


func next_wave_groups() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if index + 1 >= total():
		return out
	for g: Dictionary in waves[index + 1].get("groups", []):
		out.append(_summary(g))
	return out


func can_call() -> bool:
	if held or phase == Phase.DONE or index < 0 or index + 1 >= total():
		return false
	if world.phase != LegionWorld.Phase.BATTLE or world.paused:
		return false
	if _clock - _last_call < LegionCfg.WAVE_CALL_MIN_GAP or _last_start == _clock:
		return false
	# index выставляют напрямую кадры уроков и тесты, минуя _start — тогда записи о волне нет
	if index >= _runs.size():
		return false
	var run := _runs[index]
	return int(run["qi"]) == (run["queue"] as Array).size() and next_start_in() > 0.0


func call_next() -> int:
	if not can_call():
		return -1
	# Без next_in время до клира неизвестно: ускорение возможно, выдуманной премии нет.
	var saved := next_start_in()
	var bonus := mini(LegionCfg.WAVE_CALL_SOUL_CAP,
		floori(saved * LegionCfg.WAVE_CALL_SOUL_PER_SEC)) if is_finite(saved) else 0
	_last_call = _clock
	_called_since_tick = true
	_start(index + 1)
	world.staff.add_souls(bonus)
	world.stats["waves_called"] = int(world.stats.get("waves_called", 0)) + 1
	world.stats["call_bonus"] = int(world.stats.get("call_bonus", 0)) + bonus
	world.wave_called.emit(index, bonus)
	return bonus


## Режиссёр записи (scripts/dev/legion_director.gd): сразу начать волну i (с нуля) карты — её
## настоящие группы и интервалы, как при наступлении по часам. Игра сама этого не вызывает.
func start_wave(i: int) -> void:
	if total() > 0:
		_start(clampi(i, 0, total() - 1))


func tick(dt: float) -> void:
	if held or phase == Phase.DONE:
		return
	_clock += dt
	for run in _runs:
		_tick_run(run)
	# Все три причины сходятся здесь; смена _due принадлежит только _start.
	if not _called_since_tick and index + 1 < total() and _clock >= _due and _last_start != _clock:
		_start(index + 1)
	_called_since_tick = false
	timer = next_start_in()
	if index + 1 == total() and remaining_in_queue() == 0 and world.active_foes() == 0:
		for run in _runs:
			if not bool(run["cleared"]):
				return
		phase = Phase.DONE
		world.on_all_waves_cleared()


func _tick_run(run: Dictionary) -> void:
	var elapsed := _clock - float(run["start"])
	for warning: Dictionary in run["warnings"]:
		var left := float(warning["t"]) - elapsed
		if not warning["warned"] and left <= LegionCfg.BREACH_WARN_TIME:
			warning["warned"] = true
			world.warn_breach(String(warning["id"]), maxf(0.0, left), warning["summary"])
		if not warning["opened"] and left <= 0.0:
			warning["opened"] = true
			world.breach_opened.emit(String(warning["id"]))
	var queue: Array = run["queue"]
	while int(run["qi"]) < queue.size() and float(queue[int(run["qi"])]["t"]) <= elapsed:
		var e: Dictionary = queue[int(run["qi"])]
		var path := world.road_remainder(String(e["road"]), float(e["at"]))
		if not path.is_empty():
			var origin := {"wave": int(run["i"]) + 1, "breach": String(e["breach"]),
					"elite": bool(e.get("elite", false)),
					"souls_mult": float(e.get("souls_mult", 1.0))}
			if not world.pvp:
				origin["road"] = String(e["road"])
			world.spawn_foe_on_path(String(e["type"]), path, path[0], false, origin)
		run["qi"] = int(run["qi"]) + 1
	if bool(run["cleared"]) or int(run["qi"]) < queue.size():
		return
	for f in world.foes:
		if f.alive and int(f.origin.get("wave", 0)) == int(run["i"]) + 1:
			return
	run["cleared"] = true
	if is_climax(int(run["i"])):
		_climax_cleared()
	if int(run["i"]) == index and index + 1 < total():
		_due = minf(_due, _clock + float(waves[index + 1].get("pause", LegionCfg.WAVE_PAUSE_DEFAULT)))
		phase = Phase.PAUSE
	world.on_wave_cleared(int(run["i"]))


## Кульминация карты (LegionChallenge.is_climax): превью и тост её называют заранее.
func is_climax(i: int) -> bool:
	return i >= 0 and i < total() and LegionChallenge.is_climax(waves[i])


## Отбили кульминацию — премия душами по уровню сложности и тост (на «Стажёре» только тост:
## души сдвинули бы стройку бота, а «Стажёр» — прежние числа).
func _climax_cleared() -> void:
	var souls := int(LegionChallenge.value(world.difficulty, "climax_souls"))
	world.staff.add_souls(souls)
	world.stats["climax_cleared"] = 1
	world.toast("Кульминация отбита!" + (" +%d душ" % souls if souls > 0 else ""), &"wave")


func _summary(g: Dictionary) -> Dictionary:
	var breach := String(g.get("breach", ""))
	return {"type": String(g.get("type", "zombie")), "count": int(g.get("count", 1)),
		"from": "breach:" + breach if breach != "" else "gate:" + String(g.get("road", ""))}


func _start(i: int) -> void:
	index = i
	phase = Phase.RUN
	_last_start = _clock
	_due = _clock + float(waves[i]["next_in"]) if waves[i].has("next_in") else INF
	var queue: Array[Dictionary] = []
	var warnings: Array[Dictionary] = []
	for g: Dictionary in waves[i].get("groups", []):
		var breach := String(g.get("breach", ""))
		var road := String(g.get("road", ""))
		var at := float(g.get("at", 0.0))
		if breach != "":
			var entry := world.breach_data(breach)
			road = String(entry.get("road", road))
			at = float(entry.get("at", at))
			_add_warning(warnings, breach, g)
		# `elite`: сколько первых врагов группы гарантированно элитные (урок «элитный и первый
		# предмет», карта «Архив»); остальные бросают обычный шанс
		var elite := int(g.get("elite", 0))
		# души за врага поредевшей группы (темп читаемости D-0927-49, LegionChallenge.apply_map)
		var souls_mult := float(g.get("souls_mult", 1.0))
		for k in int(g.get("count", 1)):
			queue.append({"t": float(g.get("delay", 0.0)) + float(g.get("interval", 1.0)) * k,
				"type": String(g.get("type", "zombie")), "road": road, "at": at, "breach": breach,
				"elite": k < elite, "souls_mult": souls_mult})
	queue.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["t"] < b["t"])
	_runs.append({"i": i, "start": _clock, "queue": queue, "qi": 0,
		"cleared": false, "warnings": warnings})
	timer = next_start_in()
	world.on_wave_started(i, total())
	# Короткая задержка предупреждает на старте, спавн остаётся на шаге мира.
	for warning in warnings:
		if float(warning["t"]) <= LegionCfg.BREACH_WARN_TIME:
			warning["warned"] = true
			world.warn_breach(String(warning["id"]), float(warning["t"]), warning["summary"])


func _add_warning(warnings: Array[Dictionary], id: String, g: Dictionary) -> void:
	if int(g.get("count", 1)) <= 0:
		return
	for warning in warnings:
		if warning["id"] == id:
			warning["t"] = minf(float(warning["t"]), float(g.get("delay", 0.0)))
			(warning["summary"] as Array).append(_summary(g))
			return
	warnings.append({"id": id, "t": float(g.get("delay", 0.0)),
		"summary": [_summary(g)], "warned": false, "opened": false})
