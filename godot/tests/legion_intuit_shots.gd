extends SceneTree
##
## Кадры приёмки пакета «интуитивнее» (slow/intuit, не тест гейта). Окном, не headless:
##
##   "$GODOT" --path godot --resolution 1280x720 --fixed-fps 60
##       --script res://tests/legion_intuit_shots.gd -- --mute --out C:/AI/necro/batches/legion/intuit
##
## «Развилка», стена подряда поперёк северной дороги, колонна зомби (урона нет): золото, пружина,
## подсказки Ку/Е/Дубль-вэ, оглушённые, бледная стрелка короткой оттяжки, «стена», пустой край
## черновика.
##

const DT := 1.0 / 60.0

var w: LegionWorld
var _out := ""


func _initialize() -> void:
	_run.call_deferred()


func _shot(name: String) -> void:
	w.intuit.scan()
	w.intuit.queue_redraw()
	w.contracts.overlay.queue_redraw()
	await process_frame
	await process_frame
	root.get_texture().get_image().save_png(_out.path_join(name))
	print("кадр ", name)


func _map() -> void:
	w.dev["no_waves"] = "1"
	w.dev["spawn_units"] = "0"
	w.start_map("fork")
	w.dev_invuln = true


func _wall(units := 14) -> Contract:
	_map()
	for i in units:
		w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(300.0 + 8.0 * float(i % 10),
			262.0 + 6.0 * float(i / 10)))
	var pts := PackedVector2Array([Vector2(290, 230), Vector2(390, 230)])
	var c := w.contracts.add_contract(pts, w.contracts.default_side(pts), false)
	c.set_dir(Vector2.UP)
	c.ttl = 9999.0
	for step in roundi(4.0 / DT):
		w._step(DT)
	return c


func _column() -> void:
	var path := PackedVector2Array([Vector2(340, 160), Vector2(340, 290), Vector2(180, 360)])
	for i in 16:
		w.spawn_foe_on_path("zombie", path,
			Vector2(340.0 + (6.0 if i % 2 == 0 else -6.0), 150.0 - 18.0 * float(i)))


func _max_bend(c: Contract) -> float:
	var b := 0.0
	for s in c.seg_count():
		if c.seg_alive(s):
			b = maxf(b, c.bend_frac(s))
	return b


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var i := args.find("--out")
	_out = args[i + 1] if i >= 0 and i + 1 < args.size() else "user://intuit_shots"
	DirAccess.make_dir_recursive_absolute(_out)
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	w = scene.instantiate() as LegionWorld
	root.add_child(w)
	await process_frame
	w.set_process(false)
	# 1–3: золото → пружина с подсказкой Е → тревога пружины
	var c := _wall()
	_column()
	w.hero._cd[0] = 999.0   # Ку на откате — на кадре одна подсказка (Е), не две
	for step in roundi(10.0 / DT):
		w._step(DT)
		w.intuit.scan()
		if w.intuit.is_gold(c, 0) or w.intuit.is_gold(c, 1):
			for j in 10:
				w._step(DT)
			break
	await _shot("1_gold.png")
	# давку на этой ветке колонна не набирает (legion_press_shots тоже стоит на нуле) — прогиб
	# ставим руками: кадр про метку, а не про физику давки
	c.seg_bend_dir[0] = Vector2.DOWN
	c.seg_bend[0] = LegionCfg.PRESS_BREAK * 0.5
	w.intuit._last.clear()
	w.intuit._labels.clear()   # совет на поле один: снимаем «щёлкни» с кадра 1, чтобы показать Е
	await _shot("2_spring_hint_e.png")
	c.seg_bend[0] = LegionCfg.PRESS_BREAK * 0.85
	await _shot("3_spring_alarm.png")
	c.seg_bend[0] = 0.0
	# 4: Ку — Юрист зачитывает
	c = _wall()
	var law := w.spawn_foe_on_path("lawyer", PackedVector2Array([Vector2(420, 170)]), Vector2(420, 170))
	law.speed = 0.0
	law.law_read_t = 1.5
	for j in 4:
		w._step(DT)
	law.law_read_t = maxf(law.law_read_t, 1.0)
	await _shot("4_hint_q_lawyer.png")
	# 5: Дубль-вэ — свежие трупы у фронта
	c = _wall()
	for k in 3:
		var at := Vector2(320.0 + 24.0 * k, 190.0 + 6.0 * k)
		var f := w.spawn_foe_on_path("zombie", PackedVector2Array([at]), at)
		f.speed = 0.0
		w.dev_invuln = false
		f.take_damage(1e9, at + Vector2(0, 30))
		w.dev_invuln = true
	for j in 30:
		w._step(DT)
	await _shot("5_hint_w.png")
	# 6: оглушённые Ку в зоне — золото «×1,5» и звёздочки
	c = _wall()
	for k in 4:
		var at := Vector2(300.0 + 26.0 * k, 196.0 - 4.0 * k)
		var f := w.spawn_foe_on_path("zombie", PackedVector2Array([at]), at)
		f.speed = 0.0
	for j in 4:
		w._step(DT)
	w.hero.cast(0, Vector2(330, 196))
	for j in 10:
		w._step(DT)
	await _shot("6_stunned_gold.png")
	# 7: короткая оттяжка — бледная стрелка (B-071)
	c = _wall()
	var seg_at := c.seg_center(0)
	w.contracts._grab = {"contract": c, "seg": 0}
	w.contracts._grab_pos = seg_at
	w.contracts._pull = seg_at + Vector2(-10, 12)
	await _shot("7_short_pull.png")
	w.contracts.cancel_sling()
	# 8: штрих в скале — «стена»; скала ближе всего к середине экрана, чтобы вспышка не у края
	var rock := Vector2.INF
	var mid := Vector2(640, 360)
	for x in range(0, 1280, 12):
		for y in range(80, 640, 12):
			var p := Vector2(x, y)
			if w.terrain.is_rock(p) and (rock == Vector2.INF or p.distance_to(mid) < rock.distance_to(mid)):
				rock = p
	w.contracts.begin(rock)
	await _shot("8_wall.png")
	# 9: черновик длиннее, чем людей рядом, — пустой край притушен
	_map()
	for k in 4:
		w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(520.0 + 8.0 * k, 470.0))
	for j in 10:
		w._step(DT)
	var a := Vector2(540, 440)
	var b := Vector2(780, 440)
	w.contracts.begin(a)
	var n := ceili(a.distance_to(b) / 6.0)
	for k in n + 1:
		w.contracts.extend(a.lerp(b, float(k) / n))
	w.contracts.update_preview()
	await _shot("9_draft_empty.png")
	w.contracts.cancel()
	print("готово: ", _out)
	quit(0)
