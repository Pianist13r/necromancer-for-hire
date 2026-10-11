extends SceneTree
##
## Стенд трека оптимизации (10.10.2026, не тест гейта): шаг мира по разделам, кадр целиком и
## подвисания (кадры дольше PERF_HITCH_MS) с разбивкой — какой раздел их дал. Разделы ставит
## сам мир (LegionWorld.prof_on, _prof_mark), в игре выключено.
##
## Без окна (цена симуляции; игровое время отвязано --fixed-fps):
##   "$GODOT" --headless --fixed-fps 60 --path godot --script res://tests/legion_perf_bench.gd
##       -- --mute --bot selective --seed 1 --map bridge
## Окном (кадр с отрисовкой; vsync и предел FPS снимает стенд): то же без --headless и
## --fixed-fps, с --resolution 1280x720. «Схватка» бот против бота: --map pvp:duel --pvp-bots.
##
## Переменные: PERF_FRAMES — предел кадров (7200), PERF_WARM — сколько первых кадров боя не
## считать (60), PERF_HITCH_MS — порог подвисания (50), PERF_VIEWS_OFF=1 — опыт: _process видов
## персонажей выключен (цена «живости» = разница кадра). Итог — строка PERF {json} и
## строка PERF_STATE {json} (состояние мира в конце — сверка «симуляция не изменилась»).
##

var w: LegionWorld
var _max_frames := 7200
var _warm := 60
var _hitch_us := 50000
var _seen_battle := false
var _n := 0
var _last_us := 0
var _wall := PackedInt32Array()
var _sim := PackedInt32Array()
var _proc := PackedFloat32Array()
var _draws := PackedInt32Array()
var _prev: Dictionary = {}
var _sec_tot: Dictionary = {}
var _sec_max: Dictionary = {}
var _hitches: Array = []
var _windowed := false
var _views_off := false
var _rcpu := PackedInt32Array()
var _rgpu := PackedInt32Array()
var _res_prev := 0
var _nodes_prev := 0
var _mem_prev := 0


func _initialize() -> void:
	_max_frames = int(OS.get_environment("PERF_FRAMES")) if OS.has_environment("PERF_FRAMES") \
		else _max_frames
	_warm = int(OS.get_environment("PERF_WARM")) if OS.has_environment("PERF_WARM") else _warm
	if OS.has_environment("PERF_HITCH_MS"):
		_hitch_us = int(float(OS.get_environment("PERF_HITCH_MS")) * 1000.0)
	_windowed = DisplayServer.get_name() != "headless"
	_views_off = OS.get_environment("PERF_VIEWS_OFF") == "1"
	if _windowed:
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		Engine.max_fps = 0
		# цена отрисовки кадра: CPU (подготовка и отправка) и GPU — отдельно от шага мира
		RenderingServer.viewport_set_measure_render_time(root.get_viewport_rid(), true)
	_run.call_deferred()


func _run() -> void:
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	w = scene.instantiate() as LegionWorld
	root.add_child(w)
	w.prof_on = true
	process_frame.connect(_on_frame)


func _on_frame() -> void:
	var now_us := Time.get_ticks_usec()
	if _views_off:
		# опыт «сколько стоит живость вида»: _process видов выключен (картинка застывает)
		for v: CharView in CharView.registry:
			if v.is_processing():
				v.set_process(false)
	var in_battle := w.phase == LegionWorld.Phase.BATTLE
	if in_battle:
		_seen_battle = true
	elif _seen_battle:
		_finish("end")
		return
	var diff := {}
	var sim := 0
	for k: StringName in w.prof:
		var v := int(w.prof[k])
		var d := v - int(_prev.get(k, 0))
		_prev[k] = v
		if d > 0:
			diff[k] = d
			sim += d
	var wall := now_us - _last_us
	_last_us = now_us
	# что прибавилось за кадр: ресурсы с диска, узлы, память — подсказка, ЧЕМ занят пик
	var res := int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT))
	var nodes := int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	var mem := int(Performance.get_monitor(Performance.MEMORY_STATIC))
	var d_res := res - _res_prev
	var d_nodes := nodes - _nodes_prev
	var d_mem := mem - _mem_prev
	_res_prev = res
	_nodes_prev = nodes
	_mem_prev = mem
	if not in_battle:
		return
	_n += 1
	if _n <= _warm:
		return
	_wall.append(wall)
	_sim.append(sim)
	_proc.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
	_draws.append(int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)))
	if _windowed:
		var vp := root.get_viewport_rid()
		_rcpu.append(int((RenderingServer.viewport_get_measured_render_time_cpu(vp)
			+ RenderingServer.get_frame_setup_time_cpu()) * 1000.0))
		_rgpu.append(int(RenderingServer.viewport_get_measured_render_time_gpu(vp) * 1000.0))
	for k: StringName in diff:
		_sec_tot[k] = int(_sec_tot.get(k, 0)) + int(diff[k])
		_sec_max[k] = maxi(int(_sec_max.get(k, 0)), int(diff[k]))
	if (wall >= _hitch_us and _windowed) or sim >= _hitch_us:
		var top := diff.keys()
		top.sort_custom(func(a: StringName, b: StringName) -> bool: return diff[a] > diff[b])
		var parts := {}
		for k: StringName in top.slice(0, 4):
			parts[k] = snappedf(diff[k] / 1000.0, 0.01)
		_hitches.append({"frame": _n, "t": snappedf(w.now, 0.01), "wall_ms": snappedf(wall / 1000.0,
			0.01), "sim_ms": snappedf(sim / 1000.0, 0.01), "foes": w.active_foes(),
			"units": w.units.size(), "wave": w.wave_runner.wave_no(), "top": parts,
			"d_res": d_res, "d_nodes": d_nodes, "d_mem_kb": d_mem / 1024})
	if _n >= _max_frames:
		_finish("frames")


static func _pct(a: PackedInt32Array, q: float) -> float:
	if a.is_empty():
		return 0.0
	var s := a.duplicate()
	s.sort()
	return float(s[mini(s.size() - 1, int(float(s.size()) * q))])


func _finish(why: String) -> void:
	process_frame.disconnect(_on_frame)
	var m := _sim.size()
	var secs := {}
	for k: StringName in _sec_tot:
		secs[k] = {"mean_ms": snappedf(float(_sec_tot[k]) / float(maxi(1, m)) / 1000.0, 0.001),
			"max_ms": snappedf(float(_sec_max[k]) / 1000.0, 0.01)}
	var proc := PackedInt32Array()
	for p in _proc:
		proc.append(int(p * 1000.0))
	var long_frames := 0
	for x in _wall:
		if x >= _hitch_us:
			long_frames += 1
	var out := {
		"why": why, "frames": m, "windowed": _windowed, "map": w.map_id,
		"sim_p50_ms": snappedf(_pct(_sim, 0.5) / 1000.0, 0.001),
		"sim_mean_ms": snappedf(float(_sum(_sim)) / float(maxi(1, m)) / 1000.0, 0.001),
		"sim_p99_ms": snappedf(_pct(_sim, 0.99) / 1000.0, 0.01),
		"sim_max_ms": snappedf(_pct(_sim, 1.0) / 1000.0, 0.01),
		"wall_p50_ms": snappedf(_pct(_wall, 0.5) / 1000.0, 0.01),
		"wall_p99_ms": snappedf(_pct(_wall, 0.99) / 1000.0, 0.01),
		"wall_max_ms": snappedf(_pct(_wall, 1.0) / 1000.0, 0.01),
		"wall_ge_hitch": long_frames,
		"process_p50_ms": snappedf(_pct(proc, 0.5) / 1000.0, 0.01),
		"process_p99_ms": snappedf(_pct(proc, 0.99) / 1000.0, 0.01),
		"draw_calls_p50": _pct(_draws, 0.5), "draw_calls_max": _pct(_draws, 1.0),
		"render_cpu_p50_ms": snappedf(_pct(_rcpu, 0.5) / 1000.0, 0.01),
		"render_cpu_p99_ms": snappedf(_pct(_rcpu, 0.99) / 1000.0, 0.01),
		"render_gpu_p50_ms": snappedf(_pct(_rgpu, 0.5) / 1000.0, 0.01),
		"render_gpu_p99_ms": snappedf(_pct(_rgpu, 0.99) / 1000.0, 0.01),
		"sections": secs, "hitches": _hitches.slice(0, 20), "hitch_count": _hitches.size(),
	}
	print("PERF " + JSON.stringify(out))
	print("PERF_STATE " + JSON.stringify(_state()))
	quit(0)


static func _sum(a: PackedInt32Array) -> int:
	var s := 0
	for x in a:
		s += x
	return s


## Отпечаток мира в конце: на одном коде и сиде совпадает, если симуляция не изменилась.
func _state() -> Dictionary:
	var fx := 0.0
	var fy := 0.0
	for f in w.foes:
		fx += f.position.x
		fy += f.position.y
	var ux := 0.0
	var uy := 0.0
	for u in w.units:
		ux += u.position.x
		uy += u.position.y
	return {"now": snappedf(w.now, 0.001), "phase": w.phase, "hp": w.cauldron_hp,
		"kills": w.stats.get("kills", 0), "lost": w.stats.get("lost", 0),
		"press_breaks": w.stats.get("press_breaks", 0), "foes": w.foes.size(),
		"units": w.units.size(), "fx": fx, "fy": fy, "ux": ux, "uy": uy,
		"souls": w.souls, "mana": w.contracts.mana}
