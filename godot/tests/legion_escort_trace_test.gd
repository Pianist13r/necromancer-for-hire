extends SceneTree
##
## Dev-трасса свиты Прораба (B-478, scripts/legion/escort_trace.gd, --dev escort_trace=1):
##
##   export APPDATA=<песочница> NECRO_NO_DEV_BRIDGE=1
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_escort_trace_test.gd -- --mute
##
## 1) выключена: объекта нет, свита без метки трассы;
## 2) счётчики по событиям: призыв, смерть, прорыв, пик; чужой summoned не считается;
##    повторное событие о том же враге счётчики не двигает;
## 3) выборка раз в период: строки только с префиксом (не «{» — парсеры итога их не читают),
##    поля Прораба и свиты, seg/from отрезка;
## 3б) оглушённые (Ку) свитник и Прораб — stun, не idle;
## 4) короткий бой: финал несёт события после последней выборки, печатается один раз;
## 5) start_map: прежний бой закрыт строкой restart, счётчики нового — с нуля; без ключа — null;
## 6) уход мира из дерева без итога (таймаут серии): финал exit;
## 7) нейтральность: бой бота с Прорабом 25 с с трассой и без — отпечатки net_digest, stats и
##    итог final_stats побайтно равны; призыв в бою с трассой действительно был;
## 8) снимки «Схватки» (pvp:duel): откат к более раннему снимку на месте — прежний отрезок
##    закрыт финалом snapshot со своей историей, новый — с нуля (без «будущего»), base = живая
##    свита снимка, дальше события и выборки нового отрезка; снимок в свежий мир; ключ локальный:
##    снимок мира с трассой в мир без неё и наоборот грузится на месте (без start_map), трасса
##    у принимающего мира остаётся своя.
## Итог «LEGION ESCORT TRACE: N/M OK»; код выхода 1, если что-то упало.
##

const SAVE := "user://legion_escort_trace_test.cfg"
const WORLD_SCENE := "res://scenes/legion_world.tscn"
const DT := 1.0 / 60.0
const TRACE := preload("res://scripts/legion/escort_trace.gd")
const DEV_ON := {"no_waves": "1", "spawn_units": "0", "escort_trace": "1"}
const DEV_OFF := {"no_waves": "1", "spawn_units": "0"}
## «Схватка» для снимков: без ботов и волн (ключ трассы добавляет _duel).
const DUEL_DEV := {"noview": "1", "pvp_nobot": "1", "no_waves": "1", "spawn_units": "0"}
## Нейтральность: секунды боя (рёв Прораба — на 14-й, LegionCfg.FOES boss roar_cd).
const NEUTRAL_STEPS := 25 * 60
const DIGEST_EVERY := 60

var _fails := 0
var _checks := 0
var _lines: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _check(cond: bool, what: String) -> void:
	_checks += 1
	if cond:
		print("  ok   ", what)
	else:
		_fails += 1
		print("  FAIL ", what)


func _run() -> void:
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	await _test_off()
	await _test_counts()
	await _test_samples()
	await _test_stunned()
	await _test_final_short()
	await _test_restart()
	await _test_exit()
	await _test_neutral()
	await _test_snapshot_rollback()
	await _test_snapshot_rejected()
	await _test_snapshot_fresh()
	await _test_snapshot_local_key()
	Campaign.reset()
	print("LEGION ESCORT TRACE: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


# ── Мир ─────────────────────────────────────────────────────────────────────

func _world() -> LegionWorld:
	var w := load(WORLD_SCENE).instantiate() as LegionWorld
	w.embedded = true
	root.add_child(w)
	await process_frame
	w.set_process(false)   # шагает тест (_step)
	return w


func _free(w: LegionWorld) -> void:
	w.queue_free()
	await process_frame
	Campaign.reset()


func _start(w: LegionWorld, dev: Dictionary, map_id := "fork") -> void:
	w.dev = dev.duplicate()
	w.dev_invuln = false
	w.args.erase("bot")
	w.args.erase("pvp_bots")
	w._base_seed = 3
	w.start_map(map_id)
	_capture(w)


## Строки трассы этого боя — в _lines (вместо stdout).
func _capture(w: LegionWorld) -> void:
	_lines.clear()
	if w.escort_trace != null:
		w.escort_trace.sink = func(line: String) -> void: _lines.append(line)


func _boss(w: LegionWorld) -> Foe:
	var path := PackedVector2Array([Vector2(340, 100), w.cauldron_pos])
	return w.spawn_foe_on_path("boss", path, path[0])


func _escorts(w: LegionWorld) -> Array[Foe]:
	var out: Array[Foe] = []
	for f in w.foes:
		if f.alive and f.has_meta(TRACE.META):
			out.append(f)
	return out


func _parsed(ev: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for line in _lines:
		if not line.begins_with(TRACE.PREFIX):
			continue
		var d: Variant = JSON.parse_string(line.substr(TRACE.PREFIX.length()))
		if d is Dictionary and String((d as Dictionary).get("ev", "")) == ev:
			out.append(d)
	return out


func _invariant(t: TRACE) -> bool:
	return t.alive == t.base + t.spawned - t.killed - t.leaked


func _kill(f: Foe) -> void:
	f.take_damage(1.0e6, f.position)


# ── 1. Выключена ────────────────────────────────────────────────────────────

func _test_off() -> void:
	print("— 1) без ключа: трассы нет, свита без её метки")
	var w := await _world()
	_start(w, DEV_OFF)
	_check(w.escort_trace == null, "escort_trace == null")
	var boss := _boss(w)
	var before := w.foes.size()
	boss._summon_escort()
	var summoned := 0
	var marked := 0
	for f in w.foes:
		summoned += 1 if f.has_meta(&"summoned") else 0
		marked += 1 if f.has_meta(TRACE.META) else 0
	_check(w.foes.size() - before == 3 and summoned == 3,
		"призыв прежний: +%d врагов, summoned %d (3)" % [w.foes.size() - before, summoned])
	_check(marked == 0, "метки трассы нет (%d)" % marked)
	for i in 5:
		w._step(DT)
	_check(w.escort_trace == null and _lines.is_empty(), "шаги без трассы: строк нет")
	await _free(w)


# ── 2. Счётчики ─────────────────────────────────────────────────────────────

func _test_counts() -> void:
	print("— 2) счётчики по событиям")
	var w := await _world()
	_start(w, DEV_ON)
	var t := w.escort_trace
	_check(t != null and t.spawned == 0 and t.alive == 0 and t.peak == 0, "трасса создана с нуля")
	var boss := _boss(w)
	boss._summon_escort()
	_check(t.roars == 1 and t.spawned == 3 and t.alive == 3 and t.peak == 3,
		"рёв 1: spawned %d alive %d peak %d (3/3/3)" % [t.spawned, t.alive, t.peak])
	var esc := _escorts(w)
	_check(esc.size() == 3, "метка трассы на троих (%d)" % esc.size())
	# чужой summoned (не Foe._summon_escort) — не свита этой трассы
	var other := w.spawn_foe_on_path("zombie", PackedVector2Array([Vector2(360, 120)]),
		Vector2(360, 120), true)
	_kill(other)
	_check(t.spawned == 3 and t.killed == 0 and t.alive == 3,
		"чужой summoned и его смерть не считаются (spawned %d killed %d)" % [t.spawned, t.killed])
	_kill(esc[0])
	_check(t.killed == 1 and t.alive == 2, "смерть: killed %d alive %d (1/2)" % [t.killed, t.alive])
	t.on_gone(esc[0], false)
	_check(t.killed == 1 and t.alive == 2, "повторное событие о том же враге — без счёта")
	w.foe_reached_cauldron(esc[1])
	_check(t.leaked == 1 and t.alive == 1 and not esc[1].alive,
		"прорыв к Котлу: leaked %d alive %d (1/1)" % [t.leaked, t.alive])
	boss._summon_escort()
	_check(t.roars == 2 and t.spawned == 6 and t.alive == 4 and t.peak == 4,
		"рёв 2: spawned %d alive %d peak %d (6/4/4)" % [t.spawned, t.alive, t.peak])
	for f in _escorts(w):
		_kill(f)
	_check(t.alive == 0 and t.peak == 4 and t.killed == 5,
		"все убиты: alive %d peak %d killed %d (0/4/5)" % [t.alive, t.peak, t.killed])
	_check(_invariant(t) and t.base == 0, "alive = spawned − killed − leaked")
	_check(not w.stats.has("escort_trace") and not w.final_stats(false).has("escort_trace"),
		"stats и итог боя без полей трассы")
	await _free(w)


# ── 3. Выборка ──────────────────────────────────────────────────────────────

func _test_samples() -> void:
	print("— 3) выборка раз в период")
	var w := await _world()
	_start(w, DEV_ON)
	for i in 30:
		w._step(DT)
	_check(_parsed("sample").is_empty(), "ни Прораба, ни свиты — выборок нет")
	var boss := _boss(w)
	boss._summon_escort()
	# выборки на шагах 61 и 121 от старта (t ≈ 1,02 и 2,02 с): Прораб и свита есть в обеих
	for i in 121:
		w._step(DT)
	var rows := _parsed("sample")
	_check(rows.size() == 2, "за ~2 с — 2 выборки (%d)" % rows.size())
	var all_prefixed := true
	for line in _lines:
		all_prefixed = all_prefixed and line.begins_with(TRACE.PREFIX) and not line.begins_with("{")
	_check(all_prefixed and not _lines.is_empty(), "все строки с префиксом ESCORT_TRACE")
	if rows.is_empty():
		await _free(w)
		return
	var last: Dictionary = rows[rows.size() - 1]
	var esc: Dictionary = last.get("esc", {})
	_check(int(esc.get("alive", -1)) == 3 and int(esc.get("spawned", -1)) == 3
		and int(esc.get("peak", -1)) == 3 and int(esc.get("base", -1)) == 0 and esc.has("near")
		and esc.has("eng") and esc.has("stun") and esc.has("idle") and not esc.has("jam"),
		"свита в выборке: %s" % str(esc))
	_check(int(last.get("seg", -1)) == 0 and String(last.get("from", "")) == "start",
		"отрезок от start_map: seg 0, from start")
	var bosses: Array = last.get("boss", [])
	var keys := ["hp", "max", "pos", "d", "units", "posted", "moved", "state", "wp", "wp_n", "eng",
		"ram", "stun", "roar_in"]
	var row: Dictionary = bosses[0] if bosses.size() == 1 else {}
	var has_all := true
	for k: String in keys:
		has_all = has_all and row.has(k)
	_check(bosses.size() == 1 and has_all and not row.has("side"),
		"строка Прораба: %s" % str(row))
	_check(is_equal_approx(float(row.get("hp", -1.0)), boss.hp)
		and String(row.get("state", "")) == "walk", "HP и состояние Прораба из боя")
	# вторая выборка видит сдвиг: Прораб шёл (22 px/с) — интервал в walk_s
	if rows.size() == 2:
		_check(float(row.get("moved", -1.0)) >= TRACE.STALL_PX and w.escort_trace.boss_walk_s > 0.5,
			"Прораб шёл: moved %.1f, walk_s %.2f" % [float(row.get("moved", -1.0)),
				w.escort_trace.boss_walk_s])
	_check(w.escort_trace.boss_seen_t >= 0.0, "seen_t Прораба записан")
	await _free(w)


## Оглушённый Ку стоит без драки, но это не idle (не «затор»): отдельный счёт stun.
func _test_stunned() -> void:
	print("— 3б) оглушённые свитники и Прораб — stun, не idle")
	var w := await _world()
	_start(w, DEV_ON)
	var boss := _boss(w)
	boss._summon_escort()
	w._step(DT)   # первая выборка: позиции запомнены
	var esc := _escorts(w)
	# Оглушение не очищает прежнюю цель: она не означает продолжающийся удар.
	var target := w.spawn_unit(&"laborer", esc[0].position + Vector2(0, 10))
	esc[0]._target = target
	for f in esc:
		f.stun(10.0)
	boss.stun(10.0)   # Прорабу — доля Q_STUN_BOSS_MULT: 3 с, дольше периода
	_check(esc.size() == 3 and esc[0].is_stunned() and esc[2].is_stunned() and boss.is_stunned(),
		"свита и Прораб оглушены")
	_check(esc[0]._trace_engaged(), "оглушённый свитник сохраняет прежнюю цель")
	for i in 61:
		w._step(DT)
	var rows := _parsed("sample")
	var last: Dictionary = rows[rows.size() - 1] if rows.size() == 2 else {}
	var e: Dictionary = last.get("esc", {})
	_check(int(e.get("stun", -1)) == 3 and int(e.get("idle", -1)) == 0
		and int(e.get("eng", -1)) == 0, "выборка: stun 3, idle 0 (%s)" % str(e))
	var t := w.escort_trace
	_check(t.esc_idle_s == 0.0 and t.esc_stun_s > 2.0,
		"секунды свиты: stun_s %.2f, idle_s %.2f" % [t.esc_stun_s, t.esc_idle_s])
	var row: Dictionary = (last.get("boss", [{}]) as Array)[0] if not last.is_empty() else {}
	_check(float(row.get("stun", 0.0)) > 0.0 and t.boss_idle_s == 0.0,
		"Прораб оглушён — не idle: stun %.2f, stun_s %.2f, walk_s %.2f, idle_s %.2f" % [
			float(row.get("stun", 0.0)), t.boss_stun_s, t.boss_walk_s, t.boss_idle_s])
	await _free(w)


# ── 4. Короткий бой ─────────────────────────────────────────────────────────

func _test_final_short() -> void:
	print("— 4) бой кончился между выборками: финал с последними событиями")
	var w := await _world()
	_start(w, DEV_ON)
	var boss := _boss(w)
	boss._summon_escort()
	w._step(DT)   # первая выборка: alive 3
	var esc := _escorts(w)
	_kill(esc[0])
	_kill(esc[1])
	w._end(false)
	var finals := _parsed("final")
	_check(finals.size() == 1, "финал один (%d)" % finals.size())
	var fin: Dictionary = finals[0] if finals.size() == 1 else {}
	var fe: Dictionary = fin.get("esc", {})
	_check(String(fin.get("end", "")) == "defeat" and int(fe.get("killed", -1)) == 2
		and int(fe.get("alive", -1)) == 1 and int(fe.get("spawned", -1)) == 3
		and int(fe.get("peak", -1)) == 3, "финал: %s" % str(fin))
	var fb: Dictionary = fin.get("boss", {})
	_check(int(fb.get("alive", -1)) == 1 and (fb.get("last", []) as Array).size() == 1
		and fb.has("idle_s") and fb.has("stun_s") and fb.has("contact_s") and fb.has("walk_s")
		and fb.has("siege_s") and (fin.get("esc", {}) as Dictionary).has("idle_s"),
		"финал Прораба: %s" % str(fb))
	var samples := _parsed("sample")
	_check(samples.size() == 1 and int(samples[0]["esc"]["alive"]) == 3,
		"единственная выборка — до смертей, видела alive 3")
	w.start_map("fork")   # трасса уже закрыта итогом — restart не печатается
	_check(_parsed("final").size() == 1, "после итога повторного финала нет")
	await _free(w)


# ── 5. Перезапуск ───────────────────────────────────────────────────────────

func _test_restart() -> void:
	print("— 5) start_map: restart и сброс")
	var w := await _world()
	_start(w, DEV_ON)
	var boss := _boss(w)
	boss._summon_escort()
	_kill(_escorts(w)[0])
	w._step(DT)
	var old := w.escort_trace
	w.start_map("fork")
	var finals := _parsed("final")   # строка ушла в sink прежней трассы
	_check(finals.size() == 1 and String(finals[0].get("end", "")) == "restart"
		and int(finals[0]["esc"]["spawned"]) == 3 and int(finals[0]["esc"]["killed"]) == 1,
		"прежний бой закрыт restart: %s" % (str(finals[0]) if finals.size() == 1 else "нет"))
	var t := w.escort_trace
	_check(t != null and t != old and t.spawned == 0 and t.killed == 0 and t.leaked == 0
		and t.alive == 0 and t.peak == 0 and t.roars == 0 and t.samples == 0
		and t.final.is_empty() and t.boss_seen_t < 0.0, "новая трасса с нуля")
	_check(_escorts(w).is_empty(), "враги прежнего боя убраны")
	_start(w, DEV_OFF)
	_check(w.escort_trace == null, "следующий бой без ключа — трассы нет")
	await _free(w)


# ── 6. Выход без итога ──────────────────────────────────────────────────────

func _test_exit() -> void:
	print("— 6) мир ушёл из дерева без итога: финал exit")
	var w := await _world()
	_start(w, DEV_ON)
	_boss(w)._summon_escort()
	w._step(DT)
	w.queue_free()
	await process_frame
	var finals := _parsed("final")
	_check(finals.size() == 1 and String(finals[0].get("end", "")) == "exit"
		and int(finals[0]["esc"]["alive"]) == 3, "финал exit: %s" % str(finals))
	Campaign.reset()


# ── 7. Нейтральность ────────────────────────────────────────────────────────

func _test_neutral() -> void:
	print("— 7) нейтральность: бой бота с Прорабом 25 с с трассой и без")
	var off := await _play(false)
	var on := await _play(true)
	var first := -1
	var a: Array = off["digests"]
	var b: Array = on["digests"]
	for i in mini(a.size(), b.size()):
		if a[i] != b[i]:
			first = i
			break
	_check(first < 0 and a.size() == b.size() and a.size() == NEUTRAL_STEPS / DIGEST_EVERY,
		"net_digest совпал (%d отпечатков%s)" % [a.size(),
			"" if first < 0 else ", первое расхождение на шаге %d" % ((first + 1) * DIGEST_EVERY)])
	_check(off["stats"] == on["stats"], "stats побайтно равны")
	_check(off["final"] == on["final"], "итог final_stats равен")
	_check(int(on["roars"]) >= 1 and int(on["spawned"]) >= 3 and int(on["samples"]) > 0,
		"с трассой призыв был и виден: рёвов %d, свиты %d, выборок %d" % [int(on["roars"]),
			int(on["spawned"]), int(on["samples"])])


## Бой бота selective на «Развилке» с Прорабом на первой дороге; сид и ключи одинаковые.
func _play(trace_on: bool) -> Dictionary:
	var w := await _world()
	w.dev = {"difficulty": "intern"}
	if trace_on:
		w.dev["escort_trace"] = "1"
	w.dev_invuln = false
	w.args.erase("pvp_bots")
	w.args["bot"] = "selective"
	w._base_seed = 5
	w.start_map("fork")
	_capture(w)
	var road := String((w.map["roads"] as Array)[0]["id"])
	var path := w.road_remainder(road, 0.0)
	w.spawn_foe_on_path("boss", path, path[0])
	var digests: Array[String] = []
	for n in range(1, NEUTRAL_STEPS + 1):
		if w.phase != LegionWorld.Phase.BATTLE:
			break
		w._step(DT)
		if n % DIGEST_EVERY == 0:
			digests.append(w.net_digest())
	var out := {"digests": digests, "stats": var_to_bytes(w.stats),
		"final": JSON.stringify(w.final_stats(false)), "roars": 0, "spawned": 0, "samples": 0}
	if w.escort_trace != null:
		out["roars"] = w.escort_trace.roars
		out["spawned"] = w.escort_trace.spawned
		out["samples"] = w.escort_trace.samples
	w.args.erase("bot")
	await _free(w)
	return out


# ── 8. Снимок «Схватки» ─────────────────────────────────────────────────────

## Мир «Схватки» без ботов и волн, сид 7; trace_on — локальный ключ трассы этого мира.
func _duel(trace_on: bool) -> LegionWorld:
	var w := await _world()
	w.dev = DUEL_DEV.duplicate()
	if trace_on:
		w.dev["escort_trace"] = "1"
	w.args.erase("pvp_bots")
	w.args.erase("bot")
	w._base_seed = 7
	w.start_map("pvp:duel")
	_capture(w)
	return w


func _duel_boss(w: LegionWorld) -> Foe:
	var path := PackedVector2Array()
	for r: Dictionary in w.map.get("roads", []):
		path = w.road_remainder(String(r.get("id", "")), 0.0)
		if path.size() >= 2:
			break
	return w.spawn_foe_on_path("boss", path, path[0])


func _live_boss(w: LegionWorld) -> Foe:
	for f in w.foes:
		if f.alive and f.type_id == "boss":
			return f
	return null


## Снимок «как по сети».
func _wire(snap: Dictionary) -> Dictionary:
	return bytes_to_var(var_to_bytes(snap))


func _test_snapshot_rollback() -> void:
	print("— 8а) откат к более раннему снимку на месте: новый отрезок без «будущего»")
	var a := await _duel(true)
	var boss := _duel_boss(a)
	boss._summon_escort()
	a._step(DT)
	await process_frame
	var early := _wire(a.snapshot())   # 3 живых свитника, рёв 1
	var early_now := a.now
	# «будущее», которое откат должен отбросить: смерть, второй рёв, полторы секунды выборок
	_kill(_escorts(a)[0])
	boss._summon_escort()
	for i in 90:
		a._step(DT)
	await process_frame
	var old := a.escort_trace
	_check(old.spawned == 6 and old.killed == 1 and old.roars == 2 and old.samples == 2,
		"до отката: spawned %d killed %d roars %d samples %d (6/1/2/2)" % [old.spawned,
			old.killed, old.roars, old.samples])
	var terrain := a.terrain
	var reg := a.load_snapshot(early)
	_check(reg.errors.is_empty() and reg.misses.is_empty() and a.terrain == terrain
		and is_equal_approx(a.now, early_now), "снимок принят на месте, часы откатились")
	var finals := _parsed("final")
	var fin: Dictionary = finals[0] if finals.size() == 1 else {}
	var fe: Dictionary = fin.get("esc", {})
	_check(String(fin.get("end", "")) == "snapshot" and int(fin.get("seg", -1)) == 0
		and String(fin.get("from", "")) == "start" and int(fe.get("spawned", -1)) == 6
		and int(fe.get("killed", -1)) == 1 and int(fin.get("roars", -1)) == 2,
		"прежний отрезок закрыт финалом snapshot со своей историей: %s" % str(fin))
	var t := a.escort_trace
	_check(t != null and t != old and t.segment == 1 and t.seg_from == "snapshot",
		"новый отрезок: seg 1, from snapshot")
	if t == null:
		await _free(a)
		return
	_check(t.base == 3 and t.alive == 3 and t.peak == 3 and t.spawned == 0 and t.killed == 0
		and t.leaked == 0 and t.roars == 0 and t.samples == 0 and _invariant(t),
		"счётчики нового отрезка с нуля, base 3 (alive %d peak %d spawned %d roars %d)" % [
			t.alive, t.peak, t.spawned, t.roars])
	var secs := [t.boss_walk_s, t.boss_siege_s, t.boss_stun_s, t.boss_contact_s, t.boss_idle_s,
		t.esc_eng_s, t.esc_stun_s, t.esc_idle_s]
	_check(secs.max() == 0.0 and t.boss_seen_t < 0.0 and t.boss_dead_t < 0.0,
		"секунды и отметки времени без «будущего»: %s" % str(secs))
	# события нового отрезка
	_capture(a)
	var esc := _escorts(a)
	_check(esc.size() == 3, "метка свиты пришла со снимком (%d)" % esc.size())
	_kill(esc[0])
	var b2 := _live_boss(a)
	if b2 != null:
		b2._summon_escort()
	_check(t.killed == 1 and t.spawned == 3 and t.roars == 1 and t.alive == 5 and t.peak == 5
		and _invariant(t), "после отката: killed %d spawned %d roars %d alive %d peak %d" % [
			t.killed, t.spawned, t.roars, t.alive, t.peak])
	for i in 61:
		a._step(DT)
	var rows := _parsed("sample")
	var last: Dictionary = rows[rows.size() - 1] if not rows.is_empty() else {}
	var le: Dictionary = last.get("esc", {})
	_check(rows.size() == 2 and int(last.get("seg", -1)) == 1
		and String(last.get("from", "")) == "snapshot" and int(le.get("base", -1)) == 3
		and int(le.get("spawned", -1)) == 3 and int(le.get("killed", -1)) == 1
		and int(le.get("alive", -1)) == 5, "выборки нового отрезка (%d): %s" % [rows.size(),
			str(le)])
	_check(t.boss_seen_t >= early_now - 0.01, "seen_t — время нового отрезка (%.2f)" % t.boss_seen_t)
	await _free(a)


func _test_snapshot_rejected() -> void:
	print("— 8г) отвергнутый снимок не разрывает отрезок трассы")
	var w := await _duel(true)
	_duel_boss(w)._summon_escort()
	w._step(DT)
	var old := w.escort_trace
	var old_now := w.now
	var old_samples := old.samples
	var old_lines := _lines.size()
	var rejected := _wire(w.snapshot())
	rejected["v"] = NetSnap.VERSION + 1
	var reg := w.load_snapshot(rejected)
	_check(not reg.errors.is_empty() and is_equal_approx(w.now, old_now),
		"неверная версия отвергнута без изменения мира")
	_check(w.escort_trace == old and old.samples == old_samples and old.spawned == 3
		and old.roars == 1 and _lines.size() == old_lines and _parsed("final").is_empty(),
		"при отказе сохранены объект, история и вывод трассы")
	await _free(w)


func _test_snapshot_fresh() -> void:
	print("— 8б) снимок в свежий мир: метка свиты едет в снимке, отрезок from snapshot")
	var a := await _duel(true)
	_duel_boss(a)._summon_escort()
	_kill(_escorts(a)[0])
	a._step(DT)
	await process_frame
	var rows := _parsed("sample")
	_check(not rows.is_empty() and (rows[0]["boss"] as Array).size() == 1
		and (rows[0]["boss"][0] as Dictionary).has("side"), "PvP: у Прораба в выборке есть side")
	var b := await _world()
	b.dev = {"noview": "1", "escort_trace": "1"}   # боевые ключи придут из снимка
	b.args.erase("pvp_bots")
	b.args.erase("bot")
	var reg := b.load_snapshot(_wire(a.snapshot()))
	_check(reg.errors.is_empty() and reg.misses.is_empty(),
		"загрузка в свежий мир без ошибок (%s %s)" % [str(reg.errors), str(reg.misses)])
	var tb := b.escort_trace
	_check(tb != null and _escorts(b).size() == 2 and b.dev.has("pvp_nobot")
		and b.dev.has("escort_trace"), "свежий мир: метка свиты приехала, ключ трассы свой")
	if tb != null:
		_check(tb.segment == 0 and tb.seg_from == "snapshot" and tb.alive == 2 and tb.base == 2
			and tb.spawned == 0 and _invariant(tb),
			"свежий мир: seg %d from %s alive %d base %d" % [tb.segment, tb.seg_from, tb.alive,
				tb.base])
	await _free(a)
	await _free(b)


## Ключ трассы — локальный (SnapWorld.VIEW_DEV_KEYS): снимок мира с трассой и без неё грузится
## в совместимый мир на месте (тот же terrain — без start_map), включение остаётся своим.
func _test_snapshot_local_key() -> void:
	print("— 8в) ключ трассы локальный: снимок on → off и off → on на месте")
	var a := await _duel(true)
	_duel_boss(a)._summon_escort()
	a._step(DT)
	await process_frame
	var c := await _duel(false)
	var terrain_c := c.terrain
	var n := _lines.size()
	var reg := c.load_snapshot(_wire(a.snapshot()))
	_check(reg.errors.is_empty() and c.terrain == terrain_c,
		"on → off: снимок принят на месте (без start_map)")
	_check(c.escort_trace == null and not c.dev.has("escort_trace") and _lines.size() == n,
		"on → off: трассы нет, ключ из снимка не перенесён, вывода нет")
	var d := await _duel(false)
	_duel_boss(d)._summon_escort()   # без трассы — свита без её метки
	d._step(DT)
	await process_frame
	var e := await _duel(true)
	var terrain_e := e.terrain
	var old_e := e.escort_trace
	reg = e.load_snapshot(_wire(d.snapshot()))
	_check(reg.errors.is_empty() and e.terrain == terrain_e,
		"off → on: снимок принят на месте (без start_map)")
	var te := e.escort_trace
	_check(te != null and te != old_e and e.dev.has("escort_trace") and te.segment == 1
		and te.seg_from == "snapshot", "off → on: трасса осталась, открыт отрезок 1 from snapshot")
	if te != null:
		_check(te.base == 0 and te.alive == 0 and _escorts(e).is_empty(),
			"off → on: свита, призванная без трассы, в base не видна (base %d)" % te.base)
	var finals := _parsed("final")
	_check(not finals.is_empty() and String(finals[finals.size() - 1].get("end", "")) == "snapshot",
		"off → on: прежний отрезок мира E закрыт финалом snapshot")
	await _free(a)
	await _free(c)
	await _free(d)
	await _free(e)
