extends SceneTree
##
## Кадры приёмки линий-договоров (не тест гейта). Окном, в игровом масштабе:
##
##   "$GODOT" --path godot --resolution 1280x720 --fixed-fps 60
##       --script res://tests/legion_lines_shots.gd -- --mute --out C:/AI/necro/batches/legion/lines
##       [--gfx economy] [--maps fork,maze]
##
## На каждой карте — по договору каждого вида и набранные бойцы рядом (ровное состояние). На
## первых двух картах ещё: черчение (перо), рождение, продление, давка, мигание перед таянием,
## растворение выпущенного участка. Рядом пишется shots.json {файл, что, карта}.
##

const DT := 1.0 / 60.0
const MAPS := ["fork", "maze", "swamp", "boss", "wasteland", "bridge"]
## Три линии одна под другой; бойцы вида ставятся у своей линии и набираются по-настоящему.
const LINE_X := Vector2(420.0, 760.0)
const LINE_Y: Array[float] = [250.0, 380.0, 510.0]

var w: LegionWorld
var out := "user://"
var rows: Array = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var argv := OS.get_cmdline_user_args()
	out = _arg(argv, "--out", "user://")
	var gfx := _arg(argv, "--gfx", "full")
	var maps := _arg(argv, "--maps", ",".join(MAPS)).split(",")
	Settings.economy_override = "on" if gfx == "economy" else "off"
	DirAccess.make_dir_recursive_absolute(out)
	Campaign.set_save_path("user://legion_lines_shots.cfg")
	Campaign.reset()
	w = load("res://scenes/legion_world.tscn").instantiate() as LegionWorld
	root.add_child(w)
	await process_frame
	w.set_process(false)
	for i in maps.size():
		await _map_shots(maps[i], gfx, i < 2)
	var f := FileAccess.open(out + "/shots_%s.json" % gfx, FileAccess.WRITE)
	f.store_string(JSON.stringify(rows, "  "))
	f.close()
	Campaign.reset()
	quit(0)


func _arg(argv: PackedStringArray, key: String, def: String) -> String:
	var i := argv.find(key)
	return argv[i + 1] if i >= 0 and i + 1 < argv.size() else def


func _map_shots(map_id: String, gfx: String, story: bool) -> void:
	w.dev["no_waves"] = "1"
	w.dev["spawn_units"] = "0"
	w.dev_invuln = true
	w.start_map(map_id)
	var f := w.contracts
	var lines: Array[Contract] = []
	for i in LegionCfg.KIND_ORDER.size():
		var kind: StringName = LegionCfg.KIND_ORDER[i]
		var pts := PackedVector2Array()
		for j in 18:
			var x := lerpf(LINE_X.x, LINE_X.y, j / 17.0)
			pts.append(Vector2(x, LINE_Y[i] + sin(j * 0.45 + i) * 14.0))
		var c := f.add_contract(pts, 1, false, kind)
		lines.append(c)
		for k in 12:
			w.spawn_unit(kind, Vector2(LINE_X.x - 60.0 + (k % 6) * 22.0, LINE_Y[i] + 40.0 + (k / 6) * 20.0))
	# набор: бойцы доходят до мест (сим без кадров — быстро), затем пара настоящих кадров
	for k in roundi(8.0 / DT):
		w._step(DT)
	await _frames(20, true)
	var posted := 0
	for u in w.units:
		if u.alive and u.state == Legionnaire.State.POSTED:
			posted += 1
	print("%s: бойцов в строю %d из %d" % [map_id, posted, w.units.size()])
	await _shot("%s_%s_steady" % [map_id, gfx], "ровно: три вида с набранными бойцами", map_id)
	if not story:
		_clear(f)
		return
	# черчение: перо на конце черновика и превью набора
	f.set_kind(LegionCfg.KIND_LABORER)
	f.mana = f.mana_max
	f.begin(Vector2(820.0, 600.0))
	for j in 14:
		f.extend(Vector2(820.0 + j * 22.0, 600.0 - sin(j * 0.4) * 18.0))
		await _frames(1, true)
	print("%s: черновик %d точек" % [map_id, f._draft.size()])
	await _shot("%s_%s_draft" % [map_id, gfx], "черчение: перо и черновик", map_id)
	f.finish()
	await _frames(4, true)
	await _shot("%s_%s_birth" % [map_id, gfx], "рождение: голова бежит, ореол вспыхнул", map_id)
	await _frames(12, true)
	await _shot("%s_%s_birth2" % [map_id, gfx], "рождение: голова в конце, свечение оседает", map_id)
	# продление участков вахтёра
	f.refresh(lines[1], PackedInt32Array([1, 2, 3]), false)
	await _frames(4, true)
	await _shot("%s_%s_renew" % [map_id, gfx], "продление: вспышка по участкам 1–3", map_id)
	# давка на участке подрядчика: прогиб — вид (seg_bend трогаем только в съёмке)
	lines[0].seg_bend[2] = LegionCfg.PRESS_BREAK * 0.75
	lines[0].seg_bend_dir[2] = Vector2(-1, 0)
	lines[0].seg_bend[3] = LegionCfg.PRESS_BREAK * 0.4
	lines[0].seg_bend_dir[3] = Vector2(-1, 0)
	# мигание: у счетовода осталось 1,5 с
	lines[2].seg_age.fill(lines[2].ttl - 2.0)
	for k in 8:
		await _frames(3, true)
		await _shot("%s_%s_blink_%d" % [map_id, gfx, k], "давка (подряд) и мигание (аудит), кадр %d" % k,
			map_id)
	lines[0].seg_bend.fill(0.0)
	# растворение: выпуск трёх участков вахтёра и таяние счетовода
	for s in [0, 1, 2]:
		f.release(lines[1], s)
	for k in [2, 8, 16, 28]:
		await _frames(k - (0 if k == 2 else 0), true)
		await _shot("%s_%s_fade_%02d" % [map_id, gfx, k], "растворение: выпущены участки вахтёра", map_id)
	_clear(f)


func _clear(f: ContractField) -> void:
	for c in f.contracts.duplicate():
		f.dismiss(c)
	for u in w.units:
		if u.alive:
			u.queue_free()
	w.units.clear()


## Кадры; step — мир тоже шагает (время линий идёт), иначе только отрисовка.
func _frames(n: int, step := false) -> void:
	for i in n:
		if step:
			w._step(DT)
		await process_frame


func _shot(name: String, what: String, map_id: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_root().get_viewport().get_texture().get_image()
	var path := out + "/" + name + ".png"
	img.save_png(path)
	rows.append({"file": name + ".png", "what": what, "map": map_id})
	print("shot ", path)
