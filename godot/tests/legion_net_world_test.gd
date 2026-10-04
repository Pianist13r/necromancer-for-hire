extends SceneTree
##
## Мир в сетевом режиме (онлайн-«Схватка», docs/pvp/NET_LOCKSTEP.md, раздел «API мира для сети»).
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_net_world_test.gd -- --mute
##
## 1) Детерминизм двух «клиентов»: мир A (local_side 0) и мир B (local_side 1) — по очереди, не
##    одновременно (у генератора карт статическое состояние), один сид и карта (pvp:duel,
##    gen:7:3:pvp). A сочиняет команды обеих сторон по тикам (штрихи, aim, sling, click, erase,
##    площадки build/upgrade/rush/sell, cast, rally) и пишет журнал; свои штрихи стороны 0 он
##    берёт из руки (begin/extend/finish → net_out). B до матча играет чужой бой ботов (другая
##    история мира) и повторяет журнал. Команды применяются через net_apply перед net_step с
##    задержкой 12 тиков; кадры шагают по-разному (A — 3 тика за кадр, B — 1/2/5). net_digest()
##    каждые 60 тиков совпадает на всём матче; черновики человека посреди матча боя не меняют.
## 2) Сетевой режим не трогает мир вводом: настоящие события мыши и клавиш человека стороны 1
##    (штрих, Esc, Пробел, ПКМ щелчок и рогатка, Таб, Ку, «Сбор», Дэ, меню площадки, сдача,
##    потеря фокуса) — отпечаток мира между тиками тот же, в net_out — ожидаемые команды; своя
##    команда, применённая посреди штриха, черновик и выбранный вид оставляет на месте.
## Итог «LEGION NET WORLD: N/M OK»; код выхода 1, если что-то упало.
##

const SAVE := "user://legion_net_world_test.cfg"
const SEED := 4242
## Задержка команд: D = 4 хода по 3 тика (NET_LOCKSTEP.md).
const DELAY := 12
const DUEL_TICKS := 4 * 60 * 60
const GEN_TICKS := 3 * 60 * 60
const DIGEST_EVERY := 60
## Кадров на загрузку фона процедурной карты (GROUND_LOAD_TIMEOUT_SEC 20 с — с запасом).
const LOAD_FRAMES := 3000
const B_PACE := [1, 2, 5, 3, 1, 4]

var _fails := 0
var _checks := 0
var _sent: Array[Dictionary] = []
var _input_done := false


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
	Input.use_accumulated_input = false
	await _test_lockstep("pvp:duel", DUEL_TICKS)
	await _test_lockstep("gen:7:3:pvp", GEN_TICKS)
	await _test_input_only_commands()
	_check(_input_done, "проверка ввода дошла до конца (без ошибки скрипта посреди)")
	Campaign.reset()
	print("LEGION NET WORLD: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


func _new_world() -> LegionWorld:
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	var w := scene.instantiate() as LegionWorld
	root.add_child(w)
	await process_frame
	w.net_out = func(cmd: Dictionary) -> void: _sent.append(cmd)
	return w


func _free_world(w: LegionWorld) -> void:
	w.queue_free()
	await process_frame
	await process_frame


func _wait_ready(w: LegionWorld) -> bool:
	var n := 0
	while not w.net_can_step() and n < LOAD_FRAMES:
		await process_frame
		n += 1
	return w.net_can_step()


# ── 1. Lockstep двух клиентов ────────────────────────────────────────────────

func _test_lockstep(map_id: String, ticks: int) -> void:
	print("— lockstep %s, %d тиков" % [map_id, ticks])
	var journal: Array = []   # [тик применения, сторона, команда]
	var a := await _play(map_id, 0, ticks, journal, false)
	var b := await _play(map_id, 1, ticks, journal, true)
	var da: Array = a["digests"]
	var db: Array = b["digests"]
	var first := -1
	for i in mini(da.size(), db.size()):
		if da[i] != db[i]:
			first = i
			break
	_check(first < 0 and da.size() == db.size(),
		"%s: отпечатки A и B совпали (%d сверок, A %d / B %d тиков)%s" % [map_id, da.size(),
		a["ticks"], b["ticks"], "" if first < 0 else " — разошлись на тике %d" % ((first + 1)
		* DIGEST_EVERY)])
	_check(da.size() >= mini(ticks, int(a["end_tick"])) / DIGEST_EVERY - 1,
		"%s: сверок хватает на весь матч (%d)" % [map_id, da.size()])
	_check(a["result"] == b["result"], "%s: итог одинаковый (%s)" % [map_id, str(a["result"])])
	var by_type: Dictionary = a["ok_by_type"]
	print("  команд в журнале %d, прошло по видам: %s" % [journal.size(), str(by_type)])
	for t: String in ["stroke", "aim", "sling", "click", "erase", "plot", "cast", "rally"]:
		_check(int(by_type.get(t, 0)) > 0, "%s: команда %s хоть раз исполнилась" % [map_id, t])
	_check(a["ok_by_type"] == b["ok_by_type"], "%s: исход каждой команды у A и B один" % map_id)
	_check(int(a["human_strokes"]) > 0,
		"%s: штрихи руки A ушли через net_out и исполнились (%d)" % [map_id, a["human_strokes"]])
	if map_id != PvpMaps.DUEL:
		return
	# контроль чувствительности: журнал без одной исполненной команды — отпечаток обязан разойтись
	var cut := journal.duplicate()
	for i in cut.size():
		if String((cut[i][2] as Dictionary)["type"]) == PvpCmd.STROKE:
			cut.remove_at(i)
			break
	var c := await _play(map_id, 1, ticks, cut, true, da)
	_check(int(c["diverged"]) > 0,
		"%s: без первого штриха отпечаток расходится (тик %d)" % [map_id, c["diverged"]])


## Один клиент. replay = false — сочиняет команды и пишет журнал; true — повторяет журнал.
## ref — отпечатки другого клиента: на первом расхождении прогон останавливается (diverged — тик).
func _play(map_id: String, side: int, ticks: int, journal: Array, replay: bool,
		ref: Array = []) -> Dictionary:
	var diverged := 0
	var w := await _new_world()
	if replay:
		# другая история мира до матча: бой ботов на той же карте (номера договоров, часы вербовки)
		w.args["pvp_bots"] = true
		w.start_map(PvpMaps.DUEL)
		for i in 900:
			w._step(1.0 / 60.0)
		w.args.erase("pvp_bots")
	w.start_net_match(map_id, SEED, side)
	_check(w.net_mode and w.local_side == side and not w.sides[0].bot and not w.sides[1].bot,
		"%s сторона %d: сетевой матч без ботов" % [map_id, side])
	var ready := await _wait_ready(w)
	_check(ready, "%s сторона %d: карта догрузилась" % [map_id, side])
	var pending: Dictionary = {}
	if replay:
		for e: Array in journal:
			_queue(pending, e[0], e[1], e[2], e[3])
	var digests: Array[String] = []
	var ok_by_type: Dictionary = {}
	var human_strokes := 0
	var t := 0
	var frame := 0
	var draft_open := false
	while t < ticks and w.phase == LegionWorld.Phase.BATTLE:
		var pace: int = 3 if not replay else B_PACE[frame % B_PACE.size()]
		for _k in pace:
			if t >= ticks or w.phase != LegionWorld.Phase.BATTLE:
				break
			if not replay:
				for s in 2:
					for cmd in _script(w, s, t):
						journal.append([t + DELAY, s, cmd, false])
						_queue(pending, t + DELAY, s, cmd, false)
			_sent.clear()
			draft_open = _hand(w, side, t, draft_open)
			for cmd in _sent:
				if not replay:
					journal.append([t + DELAY, side, cmd, true])
					_queue(pending, t + DELAY, side, cmd, true)
			for s in 2:
				for e: Array in (pending.get(t, {}) as Dictionary).get(s, []):
					var cmd: Dictionary = e[0]
					var res := w.net_apply(s, cmd)
					var key := String(cmd["type"])
					if bool(res.get("ok", false)):
						ok_by_type[key] = int(ok_by_type.get(key, 0)) + 1
						if key == "stroke" and bool(e[1]):
							human_strokes += 1
			pending.erase(t)
			w.net_step()
			t += 1
			if t % DIGEST_EVERY == 0:
				digests.append(w.net_digest())
				var k := digests.size() - 1
				if k < ref.size() and ref[k] != digests[k] and diverged == 0:
					diverged = t
		if diverged > 0:
			break
		frame += 1
		await process_frame
	var res := {"digests": digests, "ticks": t, "end_tick": t, "ok_by_type": ok_by_type,
		"human_strokes": human_strokes, "diverged": diverged,
		"result": [int(w.phase), int(w.pvp_stats().get("winner", -2)), w.pvp_stats().get("t")]}
	print("  %s сторона %d: %d тиков, %d кадров, фаза %d" % [map_id, side, t, frame, int(w.phase)])
	await _free_world(w)
	return res


## Очередь применения: тик → сторона → [[команда, пришла ли из руки]] в порядке поступления.
func _queue(pending: Dictionary, at: int, side: int, cmd: Dictionary, hand: bool) -> void:
	if not pending.has(at):
		pending[at] = {}
	var by_side: Dictionary = pending[at]
	if not by_side.has(side):
		by_side[side] = []
	(by_side[side] as Array).append([cmd, hand])


## Рука человека за экраном этого клиента — прямо методами поля, как их зовёт мышь. A (сторона 0)
## раз в 1500 тиков чертит штрих до конца (команда уходит в net_out); оба клиента держат открытый
## черновик посреди боя (через тики и через применение своих команд) и снимают его — бой от этого
## не меняется.
func _hand(w: LegionWorld, side: int, t: int, open: bool) -> bool:
	var f := w.my_field()
	var c := w.cauldron_of(side)
	var d := signf(w.world_size.x * 0.5 - c.x)
	var phase := t % 1500
	if side == 0 and phase == 777:
		var x := c.x + d * 220.0
		f.begin(Vector2(x, c.y - 90.25))
		for k in range(1, 19):
			f.extend(Vector2(x + d * 4.0 * sin(k * 0.5), c.y - 90.25 + k * 10.0))
		f.finish()
		return open
	if phase == 900 + side * 50:
		f.begin(Vector2(c.x + d * 300.0, c.y + 40.0))
		for k in range(1, 8):
			f.extend(Vector2(c.x + d * (300.0 + k * 9.0), c.y + 40.0 + k * 7.0))
		return true
	if open and phase == 1100:
		f.cancel()
		return false
	return open


## Сценарий команд стороны на тик t — из состояния мира (у A и B оно одно; B берёт журнал A).
func _script(w: LegionWorld, side: int, t: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var c := w.cauldron_of(side)
	var mid := w.world_size * 0.5
	var d := signf(mid.x - c.x)
	var f := w.sides[side].contracts
	var st := w.sides[side].staff
	var last: Contract = f.contracts.back() if not f.contracts.is_empty() else null
	var ph := (t + side * 37) % 900
	if ph == 30:
		var x := c.x + d * (130.0 + float((t / 900) % 3) * 50.0)
		var pts := PackedVector2Array()
		for k in 21:
			pts.append(Vector2(x, c.y - 100.0 + k * 10.0))
		var kind: StringName = LegionCfg.KIND_ORDER[(t / 900) % LegionCfg.KIND_ORDER.size()]
		out.append(PvpCmd.stroke(pts, kind, Vector2(x + d * 60.0, c.y)))
	elif ph == 200 and last != null:
		out.append(PvpCmd.aim(last.id, Vector2(mid.x, c.y + sin(float(t)) * 150.0)))
	elif ph == 330 and last != null:
		out.append(PvpCmd.click(last.id, _live_seg(last, 0)))
	elif ph == 460 and last != null:
		out.append(PvpCmd.sling(last.id, _live_seg(last, 1), Vector2(-d * 90.0, 20.0)))
	elif ph == 600 and last != null:
		out.append(PvpCmd.erase(last.id, _live_seg(last, last.seg_count() - 1)))
	elif ph == 700:
		out.append(PvpCmd.rally(c + Vector2(d * 200.0, 0.0)))
	var pp := (t + side * 53) % 1200
	if not st.plots.is_empty() and pp in [100, 400, 700, 1000]:
		var plot: Dictionary = st.plots[(t / 1200) % st.plots.size()]
		var act: String = {100: PvpCmd.BUILD, 400: PvpCmd.UPGRADE, 700: PvpCmd.RUSH,
			1000: PvpCmd.SELL}[pp]
		if act != PvpCmd.SELL or (t / 1200) % 2 == 1:
			out.append(PvpCmd.plot(String(plot["id"]), act, LegionCfg.KIND_LABORER))
	if (t + side * 71) % 600 == 250:
		var slot := (t / 600) % 3
		var at := mid
		if slot == LegionHero.SLOT_Q:
			at = _near_foe(w, c, mid)
		elif slot == LegionHero.SLOT_E:
			at = c + Vector2(d * 160.0, 0.0)
		out.append(PvpCmd.cast(slot, at))
	return out


func _live_seg(c: Contract, want: int) -> int:
	var s := clampi(want, 0, c.seg_count() - 1)
	for k in c.seg_count():
		var i := (s + k) % c.seg_count()
		if c.seg_alive(i):
			return i
	return s


func _near_foe(w: LegionWorld, from: Vector2, fallback: Vector2) -> Vector2:
	var best := fallback
	var bd := INF
	for e in w.foes:
		if e.alive and e.position.distance_to(from) < bd:
			bd = e.position.distance_to(from)
			best = e.position
	return best


# ── 2. Ввод человека — только команды ─────────────────────────────────────────

func _win(w: LegionWorld, p: Vector2) -> Vector2:
	return root.get_final_transform() * w.world_to_screen(p)


func _move(w: LegionWorld, p: Vector2) -> void:
	var m := InputEventMouseMotion.new()
	m.position = _win(w, p)
	m.global_position = m.position
	Input.parse_input_event(m)
	await process_frame


func _btn(w: LegionWorld, p: Vector2, button: MouseButton, pressed: bool) -> void:
	var b := InputEventMouseButton.new()
	b.position = _win(w, p)
	b.global_position = b.position
	b.button_index = button
	b.pressed = pressed
	Input.parse_input_event(b)
	await process_frame


func _key(code: Key, pressed: bool) -> void:
	var k := InputEventKey.new()
	k.physical_keycode = code
	k.keycode = code
	k.pressed = pressed
	Input.parse_input_event(k)
	await process_frame


func _types() -> Array[String]:
	var out: Array[String] = []
	for c in _sent:
		out.append(String(c["type"]))
	return out


## Мир не изменился с отпечатка before, а в net_out — ровно ожидаемые команды.
func _same(w: LegionWorld, before: String, want: Array, what: String) -> void:
	_check(w.net_digest() == before and ",".join(_types()) == ",".join(PackedStringArray(want)),
		"%s: мир не тронут, в net_out %s (ждали %s)" % [what, str(_types()), str(want)])
	_sent.clear()


func _test_input_only_commands() -> void:
	print("— ввод человека стороны 1 в сети: только команды")
	Settings.scheme_override = Settings.SCHEME_SLING
	var w := await _new_world()
	w.start_net_match(PvpMaps.DUEL, SEED, 1)
	await _wait_ready(w)
	var f := w.my_field()
	_check(f == w.sides[1].contracts and f.human_input and not w.sides[0].contracts.human_input,
		"мышь — только полю стороны 1")
	var c := w.cauldron_of(1)
	var d := -1.0
	# бой до первой волны: души, мана, враги; свой договор — командой (как от сессии)
	for i in 3900:
		w.net_step()
	w.sides[1].souls += 2000   # тест: хватит на площадку (до отпечатка — не ввод)
	var base := PackedVector2Array()
	for k in 21:
		base.append(Vector2(c.x + d * 150.0, c.y - 100.0 + k * 10.0))
	_sent.clear()
	var made := w.net_apply(1, PvpCmd.stroke(base, LegionCfg.KIND_LABORER))
	_check(bool(made.get("ok", false)) and _sent.is_empty(),
		"своя команда применена и повторно в net_out не ушла")
	for i in 120:   # бойцы встали на места
		w.net_step()
	var line: Contract = f.contracts.back()
	_check(line != null and line.alive(), "договор стороны 1 на месте к проверке ввода")
	var seg := _live_seg(line, 1)
	var on_line := line.seg_center(seg)
	_sent.clear()
	var mana0 := f.mana
	var before := w.net_digest()

	# штрих ЛКМ: превью без маны, договор — командой
	var p0 := Vector2(c.x + d * 260.0, c.y - 80.0)
	await _move(w, p0)
	await _btn(w, p0, MOUSE_BUTTON_LEFT, true)
	for k in range(1, 15):
		await _move(w, p0 + Vector2(0.0, k * 11.0))
	_check(f.has_draft() and is_equal_approx(f.mana, mana0), "черновик рисуется, мана не тратится")
	await _btn(w, p0 + Vector2(0.0, 154.0), MOUSE_BUTTON_LEFT, false)
	_same(w, before, ["stroke"], "штрих ЛКМ")
	# Esc посреди черновика: ничего не возвращается и не уходит
	await _btn(w, p0, MOUSE_BUTTON_LEFT, true)
	for k in range(1, 8):
		await _move(w, p0 + Vector2(0.0, k * 11.0))
	await _key(KEY_ESCAPE, true)
	await _key(KEY_ESCAPE, false)
	await _btn(w, p0 + Vector2(0.0, 77.0), MOUSE_BUTTON_LEFT, false)
	_check(not f.has_draft(), "Esc снял черновик")
	_same(w, before, [], "Esc посреди штриха")
	# потеря фокуса посреди черновика
	await _btn(w, p0, MOUSE_BUTTON_LEFT, true)
	for k in range(1, 8):
		await _move(w, p0 + Vector2(0.0, k * 11.0))
	f.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	await _btn(w, p0 + Vector2(0.0, 77.0), MOUSE_BUTTON_LEFT, false)
	_same(w, before, [], "потеря фокуса посреди штриха")
	# Пробел над договором: стрелка — командой AIM (первая сразу, последняя на отпускание)
	await _move(w, on_line)
	await _key(KEY_SPACE, true)
	await _move(w, on_line + Vector2(d * 120.0, 30.0))
	OS.delay_msec(ContractField.NET_AIM_GAP_MS + 20)
	await _move(w, on_line + Vector2(d * 140.0, -40.0))
	await _key(KEY_SPACE, false)
	var aims := _types().count("aim")
	_check(aims >= 1 and _types().count("aim") == _types().size(),
		"Пробел над договором — только AIM (%d)" % aims)
	_same(w, before, _types(), "Пробел над договором")
	# ПКМ щелчок и рогатка
	await _move(w, on_line)
	await _btn(w, on_line, MOUSE_BUTTON_RIGHT, true)
	await _btn(w, on_line, MOUSE_BUTTON_RIGHT, false)
	_same(w, before, ["click"], "щелчок ПКМ")
	await _btn(w, on_line, MOUSE_BUTTON_RIGHT, true)
	for k in range(1, 8):
		await _move(w, on_line + Vector2(-d * k * 14.0, 0.0))
	await _btn(w, on_line + Vector2(-d * 98.0, 0.0), MOUSE_BUTTON_RIGHT, false)
	_same(w, before, ["sling"], "рогатка ПКМ")
	# Таб — стирание куска
	await _move(w, on_line)
	await _key(KEY_TAB, true)
	await _key(KEY_TAB, false)
	_same(w, before, ["erase"], "Таб над договором")
	# Е — каст командой (Ку и Дубль-вэ могли бы упереться в «нет цели» только у мира)
	var e_at := c + Vector2(d * 150.0, 0.0)
	await _move(w, e_at)
	await _key(KEY_E, true)
	await _key(KEY_E, false)
	_same(w, before, ["cast"], "Е (Аврал)")
	# «Сбор» R
	await _key(KEY_R, true)
	await _key(KEY_R, false)
	_same(w, before, ["rally"], "«Сбор» R")
	# Дэ: «Донос» убран (D-1002-09), «Касса» — только одиночка: в «Схватке» команды нет
	await _key(KEY_D, true)
	await _key(KEY_D, false)
	_same(w, before, [], "Дэ в «Схватке» — ни команды, ни изменений")
	# меню площадки: щелчок по своей площадке, кнопка «построить»
	var plot: Dictionary = w.sides[1].staff.plots[0]
	await _move(w, plot["pos"])
	await _btn(w, plot["pos"], MOUSE_BUTTON_LEFT, true)
	await _btn(w, plot["pos"], MOUSE_BUTTON_LEFT, false)
	_check(w.plot_menu.is_open(), "меню площадки стороны 1 открылось")
	if w.plot_menu.is_open():
		w.plot_menu.buttons()[0].pressed.emit()
	_same(w, before, ["plot"], "кнопка меню площадки")
	# сдача из меню Esc
	w.pvp_menu._surrender()
	_check(w.phase == LegionWorld.Phase.BATTLE, "сдача не кончила бой сама")
	_same(w, before, ["surrender"], "сдача из меню")

	# своя команда посреди штриха: черновик и вид на месте, повторно не уходит
	await _key(KEY_2, true)
	await _key(KEY_2, false)
	var kind_before := f.current_kind
	await _btn(w, p0, MOUSE_BUTTON_LEFT, true)
	for k in range(1, 9):
		await _move(w, p0 + Vector2(0.0, k * 11.0))
	var draft_before := f._draft.duplicate()
	var other := PackedVector2Array()
	for k in 21:
		other.append(Vector2(c.x + d * 330.0, c.y - 100.0 + k * 10.0))
	var n0 := f.contracts.size()
	var res := w.net_apply(1, PvpCmd.stroke(other, LegionCfg.KIND_LABORER))
	_check(bool(res.get("ok", false)) and f.contracts.size() == n0 + 1,
		"своя команда посреди штриха исполнилась (договор №%d)" % int(res.get("contract", -1)))
	_check(f.has_draft() and f._draft == draft_before and f.current_kind == kind_before
		and kind_before != LegionCfg.KIND_LABORER,
		"черновик (%d точек) и вид «%s» человека — на месте" % [f._draft.size(), kind_before])
	_check(_sent.is_empty(), "применённая команда в net_out не вернулась")
	await _btn(w, p0 + Vector2(0.0, 88.0), MOUSE_BUTTON_LEFT, false)
	_check(",".join(_types()) == "stroke" and String(_sent[0]["kind"]) == String(kind_before),
		"дорисованный штрих ушёл командой своего вида")
	if not _sent.is_empty():
		var back := w.net_apply(1, _sent[0])
		_check(bool(back.get("ok", false)), "штрих руки проходит проверки PvpCmd и ложится договором")
	Settings.scheme_override = ""
	await _free_world(w)
	_input_done = true
