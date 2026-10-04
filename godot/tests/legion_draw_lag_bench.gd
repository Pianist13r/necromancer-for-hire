extends SceneTree
##
## Замер отклика штриха (slow/draw-lag, не тест гейта; Игорь 29.09: «иногда рисуется линия с
## задержкой»). Окном — чтобы кадр рисовался по-настоящему:
##
##   "$GODOT" --path godot --resolution 1280x720 --script res://tests/legion_draw_lag_bench.gd
##       -- --mute --map maze --dev spawn_foes=250 spawn_units=80 invuln=1 no_waves=1
##       [--dev probe_sec=12] [--dev probe_stops=0.25] [--dev probe_vsync=0]
##
## Штрихи — синтетической мышью через Input.parse_input_event (весь путь ввода: окно → _input →
## _unhandled_input поля), ЛКМ зажата ~0.8 с, волна поперёк арены, пауза, снова. Мана поля
## каждый кадр полная: замер отклика, а не экономики.
##
## probe_stops=S — стоп-кадр мира (world.impact_stop, как у натиска, Ку, ритуала) раз в S
## реальных секунд: в плотной драке натиск бьёт не чаще CHARGE_HITSTOP_GAP = 0.25 с.
##
## Что меряет (кадр k — номер итерации главного цикла, Engine.get_process_frames: отложенная
## перерисовка может выполниться ещё в физическом шаге итерации, до process_frame):
##   lag_frames — от кадра, в котором поле приняло точку штриха, до кадра, в котором слой
##     черновика нарисован уже с ней (0 — тот же кадр);
##   lag_ms — от приёма точки до конца отрисовки того кадра (RenderingServer.frame_post_draw);
##   frame_ms / process_ms — длительность кадра и шага _process, отдельно «рисую» и «не рисую».
## Итог — строка JSON «DRAW_LAG {…}» в stdout.
##

var w: LegionWorld
var f: ContractField
var _sec := 12.0
var _stops := 0.0
var _frame := 0
var _t := 0.0
var _stop_t := 0.0
var _last_usec := 0
var _last_size := 0
## размер черновика -> [кадр приёма, usec приёма]
var _added: Dictionary = {}
## кадр -> наибольший размер черновика, с которым слой нарисован в этом кадре
var _drawn: Dictionary = {}
## кадр -> usec конца отрисовки
var _post: Dictionary = {}
var _frame_draw: Array[float] = []
var _frame_idle: Array[float] = []
var _proc_draw: Array[float] = []
var _proc_idle: Array[float] = []
var _stroke_i := 0
var _stroke_t := 0.0
var _down := false
var _started := false
var _frame_usec := 0
## probe_count=1: не рисуем, а считаем стоп-кадры мира в настоящем бою (обычно с --bot):
## сколько кадров шаг мира стоит и самая длинная стоянка подряд.
var _count := false
## probe_cost=1: пока рисуем, раз в кадр отдельно замерить дорогие куски черновика (мкс):
## update_preview (набор бойцов), ContractShape.classify, match_refresh.
var _cost := false
var _cost_preview: Array[float] = []
var _cost_classify: Array[float] = []
var _cost_match: Array[float] = []
var _battle_frames := 0
var _stop_frames := 0
var _stop_runs := 0
var _run_start := 0
var _run_max_ms := 0.0
var _in_run := false
var _proc_usec := 0


## Узел с последним приоритетом: конец _process всех узлов — время шага _process этого кадра.
class ProcEnd:
	extends Node
	var probe: Object

	func _process(_d: float) -> void:
		probe.set("_proc_usec", Time.get_ticks_usec() - int(probe.get("_frame_usec")))


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	w = scene.instantiate() as LegionWorld
	root.add_child(w)
	await process_frame
	var dev: Dictionary = w.dev
	_sec = float(dev.get("probe_sec", "12"))
	_stops = float(dev.get("probe_stops", "0"))
	_count = dev.has("probe_count")
	_cost = dev.has("probe_cost")
	if String(dev.get("probe_vsync", "1")) == "0":
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	w.start_map(String(w.args.get("map", "maze")))
	f = w.contracts
	var end := ProcEnd.new()
	end.probe = self
	end.process_priority = 1000000
	end.process_mode = Node.PROCESS_MODE_ALWAYS
	root.add_child(end)
	f.overlay.draw.connect(_on_overlay_draw)
	RenderingServer.frame_post_draw.connect(_on_post_draw)
	process_frame.connect(_on_frame)


func _on_overlay_draw() -> void:
	if f._drawing:
		var fr := Engine.get_process_frames()
		_drawn[fr] = maxi(int(_drawn.get(fr, 0)), f._draft.size())


func _on_post_draw() -> void:
	_post[Engine.get_process_frames()] = Time.get_ticks_usec()


func _on_frame() -> void:
	var now := Time.get_ticks_usec()
	var proc := float(_proc_usec) / 1000.0   # _process прошлого кадра
	_frame_usec = now
	_frame += 1
	# точки, принятые полем в начале этого кадра (ввод разобран до process_frame)
	if f._drawing:
		var n := f._draft.size()
		if n < _last_size:
			_last_size = 0
		for s in range(_last_size + 1, n + 1):
			if s >= 2 and not _added.has(_key(s)):
				_added[_key(s)] = [Engine.get_process_frames(), now]
		_last_size = n
	else:
		_last_size = 0
	if _last_usec > 0 and _frame > 30:
		var ms := float(now - _last_usec) / 1000.0
		if ms > 30.0:
			print("SPIKE frame=%d ms=%.1f proc=%.1f stroke=%d drawing=%s pressing=%s draft=%d" % [
				_frame - 1, ms, proc, _stroke_i, f._drawing, f._pressing, f._draft.size()])
		if _down:
			_frame_draw.append(ms)
			_proc_draw.append(proc)
		else:
			_frame_idle.append(ms)
			_proc_idle.append(proc)
	_last_usec = now
	if _frame < 30:
		return
	var dt := 1.0 / 60.0
	_t += dt
	f.mana = f.mana_max
	if _stops > 0.0:
		_stop_t -= dt
		if _stop_t <= 0.0:
			_stop_t = _stops
			w.impact_stop(LegionCfg.CHARGE_HITSTOP)
	if _cost and f._drawing and f._draft.size() >= 2:
		var u0 := Time.get_ticks_usec()
		f.update_preview()
		var u1 := Time.get_ticks_usec()
		ContractShape.classify(f._draft)
		var u2 := Time.get_ticks_usec()
		f.match_refresh(f._draft)
		var u3 := Time.get_ticks_usec()
		_cost_preview.append(float(u1 - u0) / 1000.0)
		_cost_classify.append(float(u2 - u1) / 1000.0)
		_cost_match.append(float(u3 - u2) / 1000.0)
	if _count:
		_count_stops(now)
	else:
		_drive(dt)
	if _t >= _sec:
		_report()


func _count_stops(now: int) -> void:
	if w.phase != LegionWorld.Phase.BATTLE:
		return
	_battle_frames += 1
	var stopped := w._hitstop_left > 0.0
	if stopped:
		_stop_frames += 1
		if not _in_run:
			_in_run = true
			_run_start = now
			_stop_runs += 1
	elif _in_run:
		_in_run = false
		_run_max_ms = maxf(_run_max_ms, float(now - _run_start) / 1000.0)


## Ключ точки: номер штриха и размер черновика (штрихи не путаются).
func _key(s: int) -> String:
	return "%d:%d" % [_stroke_i, s]


func _drive(dt: float) -> void:
	_stroke_t += dt
	var dur := 0.8
	var gap := 0.35
	var y0 := [250.0, 360.0, 470.0][_stroke_i % 3] as float
	if not _down and _stroke_t >= gap:
		_stroke_t = 0.0
		_down = true
		_button(Vector2(420.0, y0), true)
		_started = true
		return
	if _down:
		var k := minf(1.0, _stroke_t / dur)
		var at := Vector2(420.0 + 440.0 * k, y0 + 50.0 * sin(k * TAU))
		_motion(at)
		if k >= 1.0:
			_button(at, false)
			_down = false
			_stroke_t = 0.0
			_stroke_i += 1


func _motion(at: Vector2) -> void:
	var m := InputEventMouseMotion.new()
	m.position = at
	m.global_position = at
	m.button_mask = MOUSE_BUTTON_MASK_LEFT
	Input.parse_input_event(m)


func _button(at: Vector2, pressed: bool) -> void:
	var b := InputEventMouseButton.new()
	b.position = at
	b.global_position = at
	b.button_index = MOUSE_BUTTON_LEFT
	b.pressed = pressed
	Input.parse_input_event(b)


static func _pct(a: Array[float], q: float) -> float:
	if a.is_empty():
		return -1.0
	var s := a.duplicate()
	s.sort()
	return snappedf(float(s[mini(s.size() - 1, int(q * s.size()))]), 0.01)


func _report() -> void:
	var lag_f: Array[float] = []
	var lag_ms: Array[float] = []
	var hist := {}
	var lost := 0
	var frames := _drawn.keys()
	frames.sort()
	for key: String in _added:
		var s := int(key.split(":")[1])
		var fa := int(_added[key][0])
		var ua := int(_added[key][1])
		var fd := -1
		for fr: int in frames:
			if fr >= fa and int(_drawn[fr]) >= s:
				fd = fr
				break
		if fd < 0 or not _post.has(fd):
			lost += 1
			continue
		lag_f.append(float(fd - fa))
		lag_ms.append(float(int(_post[fd]) - ua) / 1000.0)
		hist[fd - fa] = int(hist.get(fd - fa, 0)) + 1
	if _count:
		print("DRAW_LAG_STOPS ", JSON.stringify({"map": String(w.args.get("map", "")),
			"battle_frames": _battle_frames, "stop_frames": _stop_frames, "stop_runs": _stop_runs,
			"stop_runs_per_min": snappedf(_stop_runs * 60.0 / _t, 0.1),
			"stop_frac": snappedf(float(_stop_frames) / maxf(1.0, _battle_frames), 0.001),
			"longest_ms": snappedf(_run_max_ms, 0.1),
			"foes": w.foes.size()}))
		quit(0)
		return
	var out := {
		"map": String(w.args.get("map", "")), "foes": w.foes.size(), "units": w.units.size(),
		"stops": _stops, "points": lag_f.size(), "lost": lost, "strokes": _stroke_i,
		"lag_frames_hist": hist,
		"lag_frames_p50": _pct(lag_f, 0.5), "lag_frames_p95": _pct(lag_f, 0.95),
		"lag_frames_max": _pct(lag_f, 1.0),
		"lag_ms_p50": _pct(lag_ms, 0.5), "lag_ms_p95": _pct(lag_ms, 0.95),
		"lag_ms_max": _pct(lag_ms, 1.0),
		"frame_ms_draw_p50": _pct(_frame_draw, 0.5), "frame_ms_draw_p95": _pct(_frame_draw, 0.95),
		"frame_ms_draw_max": _pct(_frame_draw, 1.0),
		"frame_ms_idle_p50": _pct(_frame_idle, 0.5), "frame_ms_idle_p95": _pct(_frame_idle, 0.95),
		"frame_ms_idle_max": _pct(_frame_idle, 1.0),
		"proc_ms_draw_p50": _pct(_proc_draw, 0.5), "proc_ms_draw_p95": _pct(_proc_draw, 0.95),
		"proc_ms_draw_max": _pct(_proc_draw, 1.0),
		"proc_ms_idle_p50": _pct(_proc_idle, 0.5), "proc_ms_idle_p95": _pct(_proc_idle, 0.95),
		"proc_ms_idle_max": _pct(_proc_idle, 1.0),
		"contracts": f.contracts.size(),
	}
	if _cost:
		out["preview_ms_p50"] = _pct(_cost_preview, 0.5)
		out["preview_ms_max"] = _pct(_cost_preview, 1.0)
		out["classify_ms_p50"] = _pct(_cost_classify, 0.5)
		out["classify_ms_max"] = _pct(_cost_classify, 1.0)
		out["match_ms_p50"] = _pct(_cost_match, 0.5)
		out["match_ms_max"] = _pct(_cost_match, 1.0)
	print("DRAW_LAG ", JSON.stringify(out))
	process_frame.disconnect(_on_frame)
	quit(0)
