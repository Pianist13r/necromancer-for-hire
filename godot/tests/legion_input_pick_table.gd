extends SceneTree
##
## Приёмка площади захвата «неуклюжим игроком» (пакет «ввод», 26.09.2026) — не тест, а таблица.
## Настоящий ввод (Input.parse_input_event в координатах окна) при окне 1280/1920/2560 (×1/×1,5/×2):
## курсор в 0…50 px ЭКРАНА от линии, Пробел, увод мыши, отпускание — взял ли прицел договор
## (стрелка повернулась к курсору). Работает и на старом коде (только ввод и Contract), поэтому
## «до/после» — один и тот же скрипт: git stash правок игры → прогон → git stash pop.
##
##   "$GODOT" --headless --path godot --script res://tests/legion_input_pick_table.gd -- --mute
##
## Строки: «пустая, под» — курсор ниже пустой линии; «строй, над» — выше линии со строем (там
## фигуры бойцов); «строй, под» — ниже линии со строем. «Две линии» — пустые линии в 36 px мира
## одна над другой, курсор на доле пути от верхней; верно, если взята ближайшая.
##

const SAVE := "user://legion_input_pick_table.cfg"
const WORLD := Vector2(1280.0, 720.0)
const OFFSETS := [0, 10, 20, 30, 40, 50]
const SCALES := [1.0, 1.5, 2.0]
const GAP := 36.0
const FRACS := [0.2, 0.35, 0.65, 0.8]

var w: LegionWorld
var f: ContractField


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	Input.use_accumulated_input = false
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	w = scene.instantiate() as LegionWorld
	root.add_child(w)
	await process_frame
	w.set_process(false)
	f = w.contracts
	for s: float in SCALES:
		root.size = Vector2i(roundi(WORLD.x * s), roundi(WORLD.y * s))
		await process_frame
		for row: Array in [["пустая, под", false, 1.0], ["строй, над", true, -1.0], ["строй, под", true, 1.0]]:
			var cells: Array[String] = []
			for off: int in OFFSETS:
				_fresh()
				var c := _hline(400)
				if row[1]:
					_man(c)
				var at := c.seg_center(2) + Vector2(0, float(row[2]) * off / s)
				cells.append("да" if await _grabs(c, at) else "—")
			print("TABLE ×%.1f | %s | %s" % [s, row[0], " | ".join(cells)])
		var right := 0
		var picks: Array[String] = []
		for fr: float in FRACS:
			_fresh()
			var a := _hline(380)
			var b := _hline(380 + GAP)
			var at := Vector2(600, 380 + GAP * fr)
			await _grabs(a, at)
			var got_a := not a.dir.is_equal_approx(Vector2.UP)
			var got_b := not b.dir.is_equal_approx(Vector2.UP)
			var want_a := fr < 0.5
			var ok := (got_a and not got_b) if want_a else (got_b and not got_a)
			if ok:
				right += 1
			picks.append("%.2f→%s" % [fr, "верх" if got_a else ("низ" if got_b else "ничего")])
		print("TABLE ×%.1f | две линии | %d/%d верно | %s" % [s, right, FRACS.size(), ", ".join(picks)])
	Campaign.reset()
	quit(0)


func _fresh() -> void:
	w.dev["spawn_units"] = "0"
	w.dev["no_waves"] = "1"
	w.start_map("wasteland")
	w.set_process(false)
	w.terrain = LegionTerrain.new().setup({})
	w.grid.rebuild()
	f.active = true
	f.human_input = true
	f.mana = f.mana_max


func _hline(y: float) -> Contract:
	var pts := PackedVector2Array()
	var x := 440.0
	while x < 760.0:
		pts.append(Vector2(x, y))
		x += LegionCfg.POINT_STEP
	pts.append(Vector2(760.0, y))
	var c := f.add_contract(pts, 1, false)
	c.set_dir(Vector2.UP)
	return c


func _man(c: Contract) -> void:
	for p in c.posts:
		var u := w.spawn_unit(c.kind, p["pos"])
		u.assign(c, p)
		u._arrive()


func _send(e: InputEvent) -> void:
	Input.parse_input_event(e)
	await process_frame


func _move(p: Vector2) -> void:
	var m := InputEventMouseMotion.new()
	m.position = root.get_final_transform() * p
	m.global_position = m.position
	await _send(m)


func _space(pressed: bool) -> void:
	var k := InputEventKey.new()
	k.physical_keycode = KEY_SPACE
	k.keycode = KEY_SPACE
	k.pressed = pressed
	await _send(k)


## Пробел в at, мышь вниз-вправо от середины договора c, отпустить: взял ли прицел c.
func _grabs(c: Contract, at: Vector2) -> bool:
	await _move(at)
	await _space(true)
	await _move(c.point_at(c.length * 0.5) + Vector2(90, 90))
	await _space(false)
	return c.dir.dot(Vector2(1, 1).normalized()) > 0.99
