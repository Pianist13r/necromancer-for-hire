extends SceneTree
##
## Снимок боя «Схватки» для сетевого судьи (NetSnap, slow/net-snapshot):
##
##   export APPDATA=<песочница> NECRO_NO_DEV_BRIDGE=1
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_snapshot_test.gd -- --mute
##
## 0) общее: реестр ссылок (enc/dec, общие словари), RNG seed+state; полнота кусков — каждое
##    поле класса (Legionnaire, Foe, Contract…) либо в снимке, либо в списке пропусков с причиной;
## а) по кускам — идемпотентность: снимок мира A на 30 с → загрузка → снимок → побайтно равен
##    снимку A (отдельно по каждому куску). Загрузка — в близнеца (мир, прошедший тот же бой до
##    того же тика: готовность куска не зависит от заглушек соседей) и в свежий мир (полный путь);
## б) главное: мир A (бот против бота, шаг 1/60) на тиках K = 30/150/300 с → снимок → мир B
##    из bytes_to_var(var_to_bytes(снимок)) → оба ещё 60 с → снимки побайтно равны, HP Котлов,
##    число бойцов и исход одинаковы; печатается первый шаг расхождения и путь по кускам.
##    Плюс «близнец»: второй мир A2 шёл с A от нуля тем же сидом и на каждом K грузит снимок A
##    в себя (на месте — путь клиента): после 60 с он обязан совпасть с A целиком. Готовые
##    куски так проверяются и при заглушках остальных — их состояние в близнеце и так верное.
## К6) артефакты с непустым состоянием: «Взрывная печать» и «Сургуч» обеим сторонам, снимок в
##    момент, когда есть таймер, зоны и след; (а) по К6 и таймер до снимка срабатывает в B
##    на том же шаге, что в A.
## редкие) то, чего в моменты а)/б) не бывает: внештатники (и их откат удара), Аврал, «Бодрый
##    выход», призванные проверяющие (summoned), снаряды в полёте, общий залп,
##    «Касса»; каждое состояние застаёт хотя бы один снимок → свежий мир → куски совпадают и
##    RARE_M с вровень.
## сеть) судья и клиент через start_net_match + net_step: снимок судьи в разошедшийся клиент на
##    месте, после «конца матча» и в клиента с другой картой и сидом — клиент остаётся в сети
##    своей стороной, net_tick и снимок как у судьи, NET_M с вровень (снимок и net_digest);
##    несетевой снимок выводит мир из сети; снимок решённого матча — фаза от стороны клиента.
## Карты pvp:duel и gen:7:3:pvp. Шаг мира — вручную, но после каждого шага кадр дерева: так
## queue_free отрабатывает между шагами, как в игре (иначе снятые объекты живы вечно).
## Итог «LEGION SNAPSHOT: N/M OK» и строка готовности кусков; код выхода 1, если что-то упало
## (кусок-заглушка — тоже провал).
##

const SAVE := "user://legion_snapshot_test.cfg"
const DT := 1.0 / 60.0
const SEED := 7
const MAPS: Array[String] = ["pvp:duel", "gen:7:3:pvp"]
const KS: Array[int] = [30, 150, 300]
const M := 60
## Редкие состояния (раздел «редкие»): что должен застать хотя бы один снимок; секунды досчёта.
const RARE: Array[String] = ["vassals", "vassal_cd", "haste", "brisk", "summoned",
	"shots", "volley"]
const RARE_M := 10
## Сеть: секунды net_step до снимка и после него.
const NET_M := 10

var _fails := 0
var _checks := 0
## кусок → всё ли совпало во всех проверках (а)/(б)
var _chunk_ok: Dictionary = {}


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
	for key in NetSnap.CHUNKS:
		_chunk_ok[key] = true
	await _test_common()
	for map_id in MAPS:
		await _test_roundtrip(map_id)
	for map_id in MAPS:
		await _test_items(map_id)
	for map_id in MAPS:
		await _test_staff_flow(map_id)
	for map_id in MAPS:
		await _test_net(map_id)
	for map_id in MAPS:
		await _test_net_end(map_id)
	for map_id in MAPS:
		await _test_resume(map_id)
	Campaign.reset()
	_report_chunks()
	print("LEGION SNAPSHOT: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


# ── Мир ─────────────────────────────────────────────────────────────────────

## Встроенный мир (сам карту не стартует), бой не шагает сам — только _steps.
func _new_world() -> LegionWorld:
	var w := (load("res://scenes/legion_world.tscn") as PackedScene).instantiate() as LegionWorld
	w.embedded = true
	root.add_child(w)
	await process_frame
	w.set_process(false)
	w.dev = {"noview": "1"}
	w.args["pvp_bots"] = true
	w._base_seed = SEED
	return w


func _free(w: LegionWorld) -> void:
	if w != null:
		w.queue_free()
		await process_frame


## n шагов каждого мира в бою, после шага — кадр дерева (уборка queue_free, как в игре).
func _steps(ws: Array, n: int) -> void:
	for i in n:
		for w: LegionWorld in ws:
			if w.phase == LegionWorld.Phase.BATTLE:
				w._step(DT)
		await process_frame


## Снимок «как по сети».
func _wire(snap: Dictionary) -> Dictionary:
	return bytes_to_var(var_to_bytes(snap))


func _brief(w: LegionWorld) -> String:
	var hp := []
	for s in w.sides:
		hp.append(snappedf(s.cauldron_hp, 0.001))
	var res := w.pvp_match.result if w.pvp_match != null else {}
	return "t %.3f Котлы %s бойцов %d врагов %d итог %s" % [w.now, str(hp), w.units.size(),
		w.foes.size(), str(res)]


## Сравнение снимков по кускам. Готовность куска (итоговая строка) решает только а): в б)
## расхождение одного куска тянет за собой остальные, и виноватого по нему не назначить.
func _compare(a: Dictionary, b: Dictionary, label: String, mark := false) -> void:
	for key in NetSnap.CHUNKS:
		var k := String(key)
		var title: String = NetSnap.CHUNK_TITLES[key]
		var same := var_to_bytes(a.get(k)) == var_to_bytes(b.get(k))
		if not NetSnap.chunk_ready(key):
			print("  --   %s: %s — заглушка, не готов" % [label, title])
			continue
		if mark and not same:
			_chunk_ok[key] = false
		_check(same, "%s: %s%s" % [label, title,
			"" if same else " — расходится: " + NetSnap.diff(a.get(k), b.get(k), k)])
	var sh := var_to_bytes(a.get(NetSnap.SHARED)) == var_to_bytes(b.get(NetSnap.SHARED))
	_check(sh, "%s: общие словари%s" % [label,
		"" if sh else " — расходятся: " + NetSnap.diff(a.get(NetSnap.SHARED),
			b.get(NetSnap.SHARED), NetSnap.SHARED)])


func _load_report(reg: NetSnap.Reg, label: String) -> void:
	_check(reg.errors.is_empty(), "%s: загрузка без несовместимостей %s" % [label,
		"" if reg.errors.is_empty() else str(reg.errors)])
	if not reg.misses.is_empty():
		var shown := reg.misses.slice(0, 8)
		print("  --   %s: неразрешённых ссылок %d (кусок не воссоздал объект): %s" % [label,
			reg.misses.size(), ", ".join(shown)])


func _report_chunks() -> void:
	var ready: Array[String] = []
	var not_ready: Array[String] = []
	for key in NetSnap.CHUNKS:
		var title: String = NetSnap.CHUNK_TITLES[key]
		if NetSnap.chunk_ready(key) and bool(_chunk_ok[key]):
			ready.append(title)
		else:
			not_ready.append(title + ("" if NetSnap.chunk_ready(key) else " (заглушка)"))
	print("КУСКИ СНИМКА: готовы %d/%d — %s" % [ready.size(), NetSnap.CHUNKS.size(),
		", ".join(ready) if not ready.is_empty() else "нет"])
	if not not_ready.is_empty():
		print("НЕ ГОТОВЫ: " + ", ".join(not_ready))
		# заглушка — тоже провал гейта: снимок без куска не восстанавливает бой
		for t in not_ready:
			_check(false, "кусок готов: " + t)


# ── 0. Общее ────────────────────────────────────────────────────────────────

func _test_common() -> void:
	print("— общее: реестр ссылок и RNG")
	var r := RandomNumberGenerator.new()
	r.seed = 12345
	for i in 17:
		r.randf()
	var saved := NetSnap.save_rng(r)
	var want := [r.randf(), r.randi(), r.randf_range(-3.0, 9.0)]
	var r2 := RandomNumberGenerator.new()
	r2.randf()
	NetSnap.load_rng(r2, _wire({"r": saved})["r"])
	_check([r2.randf(), r2.randi(), r2.randf_range(-3.0, 9.0)] == want,
		"RNG: seed+state продолжают ту же последовательность")
	var w := await _new_world()
	w.start_map("pvp:duel")
	await _steps([w], 120)
	var reg := NetSnap.Reg.new(w)
	reg.index_world()
	var u := w.units[w.units.size() - 1]
	var c: Contract = null
	for s in w.sides:
		if not s.contracts.contracts.is_empty():
			c = s.contracts.contracts[0]
	var group := {"gesture": 1}
	var volley := {"units": [u], "knocked": {u: true}, "group": group, "dir": Vector2(1, 2)}
	var gi := reg.share(group)
	var vi := reg.share(volley)
	var data := {"a": reg.enc(volley), "b": reg.enc([group, c, null]), "vi": vi, "gi": gi}
	var wire := _wire({"data": data, "shared": reg.save_shared()})
	var back := NetSnap.Reg.new(w)
	back.index_world()
	back.load_shared(wire["shared"])
	var dd: Dictionary = wire["data"]
	var v2: Dictionary = back.dec(dd["a"])
	var arr: Array = back.dec(dd["b"])
	_check(is_same(v2, back.shared(int(dd["vi"]))), "общий словарь: тот же объект у владельцев")
	_check(is_same(v2["group"], arr[0]) and is_same(arr[0], back.shared(int(dd["gi"]))),
		"общий словарь внутри общего: тот же объект")
	_check(v2["units"][0] == u and (v2["knocked"] as Dictionary).has(u),
		"ссылка на бойца (значение и ключ словаря) разрешается в тот же объект")
	_check(arr[1] == c and arr[2] == null, "ссылка на договор и null")
	_check(back.misses.is_empty(), "неразрешённых ссылок нет")
	_check(reg.ref_of(Contract.new()) == "", "объект вне массивов мира — пустой ключ")
	await _free(w)
	var covs: Array = SnapWorld.coverage() + SnapField.coverage() + SnapStaff.coverage()
	covs += SnapUnits.coverage() + SnapItems.coverage() + SnapFlow.coverage()
	for cov: Array in covs:
		var script: Script = cov[0]
		var known: Array = cov[1]
		var vars := NetSnap.script_vars(script)
		var missing: Array[String] = []
		for v in vars:
			if not known.has(v):
				missing.append(v)
		var stale: Array[String] = []
		for k: String in known:
			if not vars.has(k) and k not in ["position", "visible"]:
				stale.append(k)
		var all_known := missing.is_empty() and stale.is_empty()
		var sname := script.resource_path.get_file()
		if sname == "":
			sname = "внутренний класс (%s…)" % ", ".join(vars.slice(0, 3))
		_check(all_known, "полнота %s: %s" % [sname,
			"все поля учтены" if all_known
			else "без решения %s, лишние %s" % [str(missing), str(stale)]])


# ── а. Идемпотентность по кускам ────────────────────────────────────────────

func _test_roundtrip(map_id: String) -> void:
	print("— а) %s: снимок 30 с → свежий мир / близнец → снимок" % map_id)
	var a := await _new_world()
	a.start_map(map_id)
	var twin := await _new_world()
	twin.start_map(map_id)
	await _steps([a, twin], 30 * 60)
	var snap := a.snapshot()
	_check(_whole(snap), "а) %s: снимок записан целиком" % map_id)
	# близнец: тот же бой на том же тике, снимок грузится на месте. Объекты чужих кусков в нём
	# уже верные, поэтому готовность куска (итоговая строка) решается здесь — не зависит от
	# того, готовы ли куски, на которые он ссылается (бойцы → постройки К4 и т. п.)
	_load_report(twin.load_snapshot(_wire(snap)), "а) %s близнец" % map_id)
	_compare(snap, twin.snapshot(), "а) %s близнец" % map_id, true)
	# свежий мир: полный путь загрузки; сходится, только когда готовы все куски
	var b := await _new_world()
	_load_report(b.load_snapshot(_wire(snap)), "а) %s свежий" % map_id)
	_compare(snap, b.snapshot(), "а) %s свежий" % map_id)
	await _free(a)
	await _free(twin)
	await _free(b)


# ── б. Досчёт после снимка ──────────────────────────────────────────────────

func _test_resume(map_id: String) -> void:
	print("— б) %s: снимок на K → мир B и близнец A2 → все ещё %d с" % [map_id, M])
	var a := await _new_world()
	a.start_map(map_id)
	var twin := await _new_world()
	twin.start_map(map_id)
	var tick := 0
	for k in KS:
		await _steps([a, twin], k * 60 - tick)
		tick = k * 60
		if a.phase != LegionWorld.Phase.BATTLE:
			print("  --   матч кончился до %d с (%s) — K пропущен" % [k, _brief(a)])
			break
		var label := "б) %s K=%d" % [map_id, k]
		var label_t := label + " близнец"
		_check(var_to_bytes(a.snapshot()) == var_to_bytes(twin.snapshot()),
			label_t + ": до загрузки шёл вровень с A")
		var snap := a.snapshot()
		_check(_whole(snap), label + ": снимок записан целиком")
		var b := await _new_world()
		_load_report(b.load_snapshot(_wire(snap)), label)
		_load_report(twin.load_snapshot(_wire(snap)), label_t)
		var first := -1
		var first_diff := ""
		for i in M * 60:
			await _steps([a, b, twin], 1)
			if first < 0 and b.phase == LegionWorld.Phase.BATTLE:
				var sa := a.snapshot()
				var sb := b.snapshot()
				if var_to_bytes(sa) != var_to_bytes(sb):
					first = i + 1
					first_diff = _chunk_diffs(sa, sb)
		tick += M * 60
		var want := a.snapshot()
		print("  A: " + _brief(a))
		print("  B: " + _brief(b))
		print("  A2: " + _brief(twin))
		if first > 0:
			print("  --   %s: B разошёлся с A на %d-м шаге после загрузки:\n%s" % [label, first,
				first_diff])
		_check(_brief(b) == _brief(a), label + ": Котлы, бойцы, враги и исход как у A")
		_compare(want, b.snapshot(), label)
		_check(_brief(twin) == _brief(a), label_t + ": Котлы, бойцы, враги и исход как у A")
		_compare(want, twin.snapshot(), label_t)
		await _free(b)
	await _free(twin)
	await _free(a)


## Все расходящиеся куски (путь первого расхождения в каждом) — чтобы видеть, где причина.
func _chunk_diffs(a: Dictionary, b: Dictionary) -> String:
	var out: Array[String] = []
	for key in NetSnap.CHUNKS:
		var k := String(key)
		var d := NetSnap.diff(a.get(k), b.get(k), k)
		if d != "":
			out.append("         %s: %s" % [NetSnap.CHUNK_TITLES[key], d])
	var d2 := NetSnap.diff(a.get(NetSnap.SHARED), b.get(NetSnap.SHARED), NetSnap.SHARED)
	if d2 != "":
		out.append("         общие: " + d2)
	return "\n".join(out)


# ── К6: артефакты с непустым состоянием и таймер через снимок ───────────────

## Артефакты «Взрывная печать» (отложенный взрыв — таймер items.after) и «Сургуч с огоньком»
## (опасные зоны, state.trail) обеим сторонам; шаги до момента, когда у кого-то сразу есть
## таймер, зона и след; снимок → свежий мир → (а) К6 совпадает; таймеры, поставленные до
## снимка, срабатывают в мире B на тех же шагах, что в A.
func _test_items(map_id: String) -> void:
	print("— К6 %s: артефакты с таймером, зонами и следом" % map_id)
	var a := await _new_world()
	a.start_map(map_id)
	await _steps([a], 20 * 60)
	for s in a.sides:
		for id: StringName in [&"exploding_stamp", &"burning_seal"]:
			a.items_of(s.index).grant(id)
	var ready := false
	for i in 90 * 60:
		await _steps([a], 1)
		if a.phase != LegionWorld.Phase.BATTLE:
			break
		var timers := 0
		var hazards := 0
		var trail := 0
		for s in a.sides:
			var it := a.items_of(s.index)
			timers += it._timers.size()
			hazards += it.hazards.size()
			trail += (it.state.get(&"trail", {}) as Dictionary).size()
		if timers > 0 and hazards > 0 and trail > 0:
			ready = true
			print("  --   К6 %s: t %.3f таймеров %d зон %d следов %d" % [map_id, a.now, timers,
				hazards, trail])
			break
	_check(ready, "К6 %s: снимок с непустыми таймерами, зонами и следом" % map_id)
	if not ready:
		await _free(a)
		return
	var snap := a.snapshot()
	var b := await _new_world()
	var reg := b.load_snapshot(_wire(snap))
	_load_report(reg, "К6 " + map_id)
	var same := var_to_bytes(snap.get("items")) == var_to_bytes(b.snapshot().get("items"))
	var why := "" if same else " — расходится: " + NetSnap.diff(snap.get("items"),
		b.snapshot().get("items"), "items")
	if not same and not reg.misses.is_empty() and not NetSnap.chunk_ready(&"units"):
		# след «Сургуча» ссылается на бойцов: без К3 их в B нет — не вина К6
		print("  --   К6 %s: снимок → мир B → снимок — ждёт К3 (бойцы не воссозданы)%s" % [
			map_id, why])
	else:
		_check(same, "К6 %s: снимок → мир B → снимок совпадает%s" % [map_id, why])
		if not same:
			_chunk_ok[&"items"] = false
	# таймеры до снимка (те же словари в A; в B — воссозданные загрузкой)
	var pre_a: Array = []
	var pre_b: Array = []
	for s in a.sides:
		pre_a.append_array(a.items_of(s.index)._timers)
		pre_b.append_array(b.items_of(s.index)._timers)
	var fired_a: Array[int] = []
	var fired_b: Array[int] = []
	for step in 60:
		await _steps([a, b], 1)
		fired_a.append(_timers_gone(a, pre_a))
		fired_b.append(_timers_gone(b, pre_b))
	_check(pre_a.size() == pre_b.size() and fired_a == fired_b
			and fired_a[fired_a.size() - 1] == pre_a.size(),
		"К6 %s: %d таймер(ов) до снимка сработали в B на тех же шагах, что в A %s / %s" % [
			map_id, pre_a.size(), str(fired_a.slice(0, 12)), str(fired_b.slice(0, 12))])
	await _free(a)
	await _free(b)


## Сколько таймеров из pre уже нет в очередях мира (сработали).
func _timers_gone(w: LegionWorld, pre: Array) -> int:
	var n := 0
	for tm: Dictionary in pre:
		var alive := false
		for s in w.sides:
			for x: Dictionary in w.items_of(s.index)._timers:
				if is_same(x, tm):
					alive = true
		if not alive:
			n += 1
	return n


# ── Редкие состояния: то, чего в моменты снимков (а)/(б) не бывает ──────────

## Бот «Схватки» кастует только Ку и не знает перка «Бодрый выход», снаряды в полёте и бойцы
## общего залпа живут доли секунды, призванные проверяющие (метка summoned, свита Прораба) —
## редкость, «Касса» в «Схватке» пуста. Без этого раздела их порча снимком (verifier, порчи u_shots,
## u_volleyid, u_meta, s_vassal, w_kassa) проходила все проверки. Сценарий, а не баланс: касты
## — командами мира с доливом маны, снаряд — fire_projectile, призванный — spawn_foe_on_path
## (до D-1002-09 его давал «Донос»), залп — щелчок по участку, где стоят двое; «Бодрый выход» и
## «Касса» — полями напрямую.
##
## Мир A идёт, пока каждое состояние из RARE не застанет хотя бы один снимок: в момент, когда
## есть новое (ещё не застанное) состояние, снимок → свежий мир B → все куски совпадают, затем
## A и B ещё RARE_M с без команд → снимки побайтно равны.
func _test_staff_flow(map_id: String) -> void:
	print("— редкие %s: внештатники, Аврал, «Бодрый выход», призванные, снаряды, залп, «Касса»"
		% map_id)
	var a := await _new_world()
	a.start_map(map_id)
	for b: LegionBuilding in a.buildings:
		b.brisk_exit = true
	a.kassa.souls = 50
	a.kassa.premium = 1.25
	a.kassa.deposits = 1
	await _steps([a], 20 * 60)
	var left: Array = RARE.duplicate()
	var shots := 0
	for i in 150 * 60:
		await _steps([a], 1)
		if a.phase != LegionWorld.Phase.BATTLE:
			break
		if i % 30 == 0:
			_rare_acts(a, left)
		var have := _rare_have(a)
		var fresh := left.filter(func(k: String) -> bool: return int(have[k]) > 0)
		if fresh.is_empty():
			continue
		shots += 1
		print("  --   редкие %s #%d: t %.3f %s" % [map_id, shots, a.now, str(have)])
		await _rare_check(a, "редкие %s #%d" % [map_id, shots])
		for k: String in RARE:
			if int(have[k]) > 0:
				left.erase(k)
		if left.is_empty() or a.phase != LegionWorld.Phase.BATTLE:
			break
	_check(left.is_empty(), "редкие %s: снимки застали все состояния %s%s" % [map_id, str(RARE),
		"" if left.is_empty() else " — не застали " + str(left)])
	await _free(a)


## Снимок A сейчас → свежий B: все куски совпадают; оба ещё RARE_M с — снимки равны.
func _rare_check(a: LegionWorld, label: String) -> void:
	var snap := a.snapshot()
	_check(_whole(snap), label + ": снимок записан целиком")
	var b := await _new_world()
	_load_report(b.load_snapshot(_wire(snap)), label)
	_compare(snap, b.snapshot(), label + " свежий", true)
	await _steps([a, b], RARE_M * 60)
	var sa := a.snapshot()
	var sb := b.snapshot()
	var same := var_to_bytes(sa) == var_to_bytes(sb) and _brief(a) == _brief(b)
	_check(same, "%s: +%d с B вровень с A%s" % [label, RARE_M,
		"" if same else "\n" + _chunk_diffs(sa, sb)])
	await _free(b)


## Сколько каждого редкого состояния в мире сейчас.
func _rare_have(w: LegionWorld) -> Dictionary:
	var have := {}
	for k: String in RARE:
		have[k] = 0
	for s in w.sides:
		var h := w.hero_of(s.index)
		if h == null:
			continue
		have["vassals"] += h.vassal_count()
		for v: Variant in h.vassals():
			if is_instance_valid(v) and float(v._attack_cd) > 0.0:
				have["vassal_cd"] += 1
		have["haste"] += h.hasted().size()
	for b: LegionBuilding in w.buildings:
		have["brisk"] += b._brisk.size()
	for f in w.foes:
		if f.alive and f.has_meta(&"summoned"):
			have["summoned"] += 1
	have["shots"] = w.projectiles.shots.size()
	# бойцы, которые делят словарь залпа с другим бойцом (общность — reg.share)
	var seen: Array[Dictionary] = []
	var count: Array[int] = []
	for u in w.units:
		if u._volley.is_empty():
			continue
		var j := -1
		for k in seen.size():
			if is_same(seen[k], u._volley):
				j = k
		if j < 0:
			seen.append(u._volley)
			count.append(1)
		else:
			count[j] += 1
	for n in count:
		if n >= 2:
			have["volley"] += n
	return have


## Команды и поля сценария — только для ещё не застанных состояний.
func _rare_acts(w: LegionWorld, left: Array) -> void:
	for s in w.sides:
		var h := w.hero_of(s.index)
		if h == null:
			continue
		if h.vassal_count() == 0 or left.has("vassal_cd"):
			var pool: Array = []
			pool.append_array(w.foes)
			pool.append_array(w._corpses)
			for f: Variant in pool:
				if f is Foe and (f as Foe).is_fresh_corpse() and not f.has_meta(&"summoned") \
						and f.visible:
					s.contracts.mana = s.contracts.mana_max
					w.command(s.index, PvpCmd.cast(LegionHero.SLOT_W, f.position))
					break
		if h.hasted().is_empty():
			for u in w.units:
				if u.alive and u.side == s.index:
					s.contracts.mana = s.contracts.mana_max
					w.command(s.index, PvpCmd.cast(LegionHero.SLOT_E, u.position))
					break
		if left.has("volley"):
			_rare_click(w, s)
	if left.has("shots") and w.projectiles.shots.is_empty():
		_rare_shot(w)
	if left.has("summoned"):
		_rare_summon(w)


## Щелчок по участку своего договора, где стоят хотя бы двое: выпуск — один общий залп.
func _rare_click(w: LegionWorld, s: PvpSide) -> void:
	for c in s.contracts.contracts:
		var per_seg := {}
		for p: Dictionary in c.posts:
			var u: Variant = p.get("unit")
			if u is Legionnaire and is_instance_valid(u) and (u as Legionnaire).alive \
					and (u as Legionnaire).state == Legionnaire.State.POSTED:
				per_seg[int(p["seg"])] = int(per_seg.get(int(p["seg"]), 0)) + 1
		for seg: int in per_seg:
			if int(per_seg[seg]) >= 2 and c.seg_alive(seg):
				w.command(s.index, PvpCmd.click(c.id, seg))
				return


## Снаряд в полёте: живой боец стороны 0 «мечет печать» в самого дальнего бойца стороны 1
## (урон 1 — летит долго, на бой почти не влияет).
## Призванный проверяющий (метка summoned, как свита Прораба) в начале первой дороги PvE.
func _rare_summon(w: LegionWorld) -> void:
	for r: Dictionary in w.map.get("roads", []):
		var path := w.road_remainder(String(r.get("id", "")), 0.0)
		if path.size() >= 2:
			w.spawn_foe_on_path("zombie", path, path[0], true, {"wave": 0})
			return


func _rare_shot(w: LegionWorld) -> void:
	var from: Legionnaire = null
	for u in w.units:
		if u.alive and u.side == 0:
			from = u
			break
	if from == null:
		return
	var best: Legionnaire = null
	for u in w.units:
		if u.alive and u.side == 1 and (best == null
				or u.position.distance_to(from.position) > best.position.distance_to(from.position)):
			best = u
	if best != null:
		w.fire_projectile(from, best, 1.0)


# ── Сеть: снимок судьи в сетевой мир клиента ────────────────────────────────

## Судья и клиент — start_net_match той же карты и сида (стороны 0 и 1), шаг — net_step. Клиент
## расходится (net_tick, души) и грузит снимок судьи на месте; потом «решает», что матч кончился
## (_end), и грузит снимок идущего боя — путь подготовки (SnapWorld.prepare). В обоих случаях
## клиент остаётся в сетевом матче своей стороной (net_mode, local_side, net_out, ботов нет,
## net_step шагает), снимок совпадает с судейским и ещё NET_M с они идут вровень.
func _test_net(map_id: String) -> void:
	print("— сеть %s: снимок судьи → клиент на месте и после «конца матча»" % map_id)
	var a := await _new_world()
	a.start_net_match(map_id, SEED, 0)
	var c := await _new_world()
	c.start_net_match(map_id, SEED, 1)
	var out := func(_cmd: Dictionary) -> void: pass
	c.net_out = out
	await _net_steps([a, c], NET_M * 60)
	c.net_tick += 3
	c.sides[0].souls += 7
	_load_report(c.load_snapshot(_wire(a.snapshot())), "сеть %s на месте" % map_id)
	_net_same(a, c, out, "сеть %s на месте" % map_id)
	await _net_steps([a, c], 60)
	c._end(false)
	_load_report(c.load_snapshot(_wire(a.snapshot())), "сеть %s после конца" % map_id)
	_net_same(a, c, out, "сеть %s после конца" % map_id)
	await _net_steps([a, c], NET_M * 60)
	var same := var_to_bytes(a.snapshot()) == var_to_bytes(c.snapshot())
	_check(same and a.net_digest() == c.net_digest(),
		"сеть %s: ещё %d с клиент вровень с судьёй (снимок и net_digest)%s" % [map_id, NET_M,
			"" if same else "\n" + _chunk_diffs(a.snapshot(), c.snapshot())])
	# клиент, стартовавший на другой карте и с другим сидом: после загрузки — карта, сид и бой
	# судьи (prepare берёт их из снимка, а не из мира)
	var other := "gen:7:3:pvp" if map_id == "pvp:duel" else "pvp:duel"
	var d := await _new_world()
	d.start_net_match(other, SEED + 4, 1)
	d.net_out = out
	await _net_steps([d], 60)
	var label := "сеть %s ← клиент %s сид %d" % [map_id, other, SEED + 4]
	_load_report(d.load_snapshot(_wire(a.snapshot())), label)
	_check(d.map_id == a.map_id and d._base_seed == a._base_seed,
		"%s: карта и сид судьи (%s, %d)" % [label, d.map_id, d._base_seed])
	_net_same(a, d, out, label)
	await _net_steps([a, d], NET_M * 60)
	var same_d := var_to_bytes(a.snapshot()) == var_to_bytes(d.snapshot())
	_check(same_d and a.net_digest() == d.net_digest(),
		"%s: ещё %d с вровень с судьёй (снимок и net_digest)%s" % [label, NET_M,
			"" if same_d else "\n" + _chunk_diffs(a.snapshot(), d.snapshot())])
	await _free(d)
	# несетевой снимок в сетевой мир: мир выходит из сети и принимает бой снимка с его сидом
	var n := await _new_world()
	n.start_map(map_id)
	await _steps([n], 60)
	var e := await _new_world()
	e.start_net_match(map_id, SEED + 4, 1)
	var label_n := "сеть %s: несетевой снимок → сетевой мир" % map_id
	_load_report(e.load_snapshot(_wire(n.snapshot())), label_n)
	_check(not e.net_mode and var_to_bytes(n.snapshot()) == var_to_bytes(e.snapshot()),
		"%s: мир вне сети, снимок совпал (net_mode %s, сид %d)" % [label_n, e.net_mode,
			e._base_seed])
	await _free(n)
	await _free(e)
	await _free(a)
	await _free(c)


## Решённый матч в снимке судьи (судья — сторона 0): фаза у загрузившего — от ЕГО стороны, как
## в _check_pvp_end. Случаи: сдалась сторона 1, сдалась сторона 0, обе (ничья — поражение
## фазой у обоих). Клиенты сторон 1 и 0 с идущим боем и клиент стороны 1, уже закончивший матч
## сам тем же итогом: у всех победитель как у судьи, фаза своя, снимок равен судейскому.
func _test_net_end(map_id: String) -> void:
	print("— сеть %s: снимок решённого матча — итог от стороны клиента" % map_id)
	for losers: Array in [[1], [0], [0, 1]]:
		var a := await _new_world()
		a.start_net_match(map_id, SEED, 0)
		var c1 := await _new_world()
		c1.start_net_match(map_id, SEED, 1)
		var c0 := await _new_world()
		c0.start_net_match(map_id, SEED, 0)
		var n1 := await _new_world()
		n1.start_net_match(map_id, SEED, 1)
		await _net_steps([a, c1, c0, n1], 60)
		for i: int in losers:
			a.sides[i].surrendered = true
			n1.sides[i].surrendered = true
		await _net_steps([a, n1], 2)
		var winner := int(a.pvp_match.result.get("winner", -2)) if a.pvp_match != null else -2
		var label := "сеть %s сдались %s (победитель %d)" % [map_id, str(losers), winner]
		_check(a.phase != LegionWorld.Phase.BATTLE and n1.phase != LegionWorld.Phase.BATTLE,
			label + ": судья и клиент n1 закончили матч сами")
		var snap := _wire(a.snapshot())
		for w: LegionWorld in [c1, c0, n1]:
			var tag := "%s, клиент стороны %d%s" % [label, w.local_side,
				" (уже закончил)" if w == n1 else ""]
			_load_report(w.load_snapshot(snap), tag)
			var want := LegionWorld.Phase.VICTORY if winner == w.local_side \
				else LegionWorld.Phase.DEFEAT
			var got_w := int(w.pvp_match.result.get("winner", -2)) if w.pvp_match != null else -2
			_check(w.phase == want and got_w == winner and w.net_mode,
				"%s: фаза %d (ждём %d), победитель %d" % [tag, w.phase, want, got_w])
			_check(var_to_bytes(a.snapshot()) == var_to_bytes(w.snapshot()),
				tag + ": снимок = снимок судьи")
		for w: LegionWorld in [a, c1, c0, n1]:
			await _free(w)


func _net_steps(ws: Array, n: int) -> void:
	for i in n:
		for w: LegionWorld in ws:
			w.net_step()
		await process_frame


func _net_same(a: LegionWorld, c: LegionWorld, out: Callable, label: String) -> void:
	var bots := false
	for s in c.sides:
		bots = bots or s.bot != null
	_check(c.net_mode and c.local_side == 1 and c.net_out == out and not bots
			and c.net_can_step(),
		"%s: клиент в сетевом матче своей стороной (net_mode %s, local_side %d, net_out %s, боты %s)"
			% [label, c.net_mode, c.local_side, c.net_out == out, bots])
	_check(c.net_tick == a.net_tick, "%s: net_tick %d = %d" % [label, c.net_tick, a.net_tick])
	var sa := a.snapshot()
	var sc := c.snapshot()
	_check(var_to_bytes(sa) == var_to_bytes(sc), "%s: снимок клиента = снимок судьи%s" % [label,
		"" if var_to_bytes(sa) == var_to_bytes(sc) else "\n" + _chunk_diffs(sa, sc)])


## Снимок записан целиком: у каждого бойца и врага (и трупа) есть последний ключ, который пишет
## кусок К3. Обрыв функции сохранения на SCRIPT ERROR оставил бы словарь без хвоста, а два
## одинаково оборванных снимка ещё и совпали бы побайтно.
func _whole(snap: Dictionary) -> bool:
	var units: Dictionary = snap.get("units", {})
	for key: String in ["units", "foes", "corpses"]:
		for d: Dictionary in units.get(key, []):
			if not d.has("_volley" if d.get("cls") == "u" else "meta"):
				return false
	return true
