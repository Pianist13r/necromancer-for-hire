extends SceneTree
##
## Кадры приёмки импакта способностей (slow/impact, не тест гейта). Окном, в игровом масштабе:
##
##   "$GODOT" --path godot --resolution 1280x720 --fixed-fps 60
##       --script res://tests/legion_impact_shots.gd -- --mute --out C:/AI/necro/batches/legion/impact
##
## Касты — настоящим путём героя (world.hero.cast по точке: курсор ОС мостом не двигается),
## удар натиска — world._charge_feedback (как у бойца залпа) плюс надпись «Точно!» поля договоров.
## Кадр при 60 к/с — 16,7 мс: смещения 0/3/6/9/15/60 кадров ≈ 0/50/100/150/250/1000 мс.
##

var w: LegionWorld
var out := "user://"


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var argv := OS.get_cmdline_user_args()
	var i := argv.find("--out")
	out = argv[i + 1] if i >= 0 and i + 1 < argv.size() else "user://"
	DirAccess.make_dir_recursive_absolute(out)
	Settings.economy_override = "off"
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	w = scene.instantiate() as LegionWorld
	root.add_child(w)
	await process_frame
	w.dev["no_waves"] = "1"
	w.start_map("fork")
	await _frames(30)
	# 1. Ку по цепи из 4 целей
	var foes := _foes([Vector2(520, 470), Vector2(600, 520), Vector2(690, 470), Vector2(770, 540),
		Vector2(900, 420)])
	await _frames(30)
	w.hero.cast(LegionHero.SLOT_Q, foes[0].position)
	await _series("q_full", [0, 3, 6, 9, 15, 60])
	_clear_foes(foes)
	await _frames(200)
	# 2. Ку в экономной графике — для сравнения
	Settings.economy_override = "on"
	await _frames(3)
	foes = _foes([Vector2(520, 470), Vector2(600, 520), Vector2(690, 470), Vector2(770, 540)])
	await _frames(30)
	w.hero.reset()
	w.hero.cast(LegionHero.SLOT_Q, foes[0].position)
	await _series("q_economy", [0, 3, 9])
	_clear_foes(foes)
	Settings.economy_override = "off"
	await _frames(60)
	# 3. Дубль-вэ: труп поднимается внештатником
	var f := _foes([Vector2(640, 500)])[0]
	await _frames(20)
	f.take_damage(100000.0, f.position + Vector2(20, 0))
	await _frames(40)
	w.hero.cast(LegionHero.SLOT_W, f.position)
	await _series("w_raise", [1, 4, 8, 14, 24, 40])
	await _frames(120)
	# 4. Е: волна по строю, потом бойцы бегут со шлейфом
	var us: Array[Legionnaire] = []
	for k in 6:
		us.append(w.spawn_unit(LegionCfg.KIND_LABORER, Vector2(560 + 36 * (k % 3), 560 + 30 * (k / 3))))
	await _frames(40)
	w.hero.cast(LegionHero.SLOT_E, Vector2(600, 575))
	await _series("e_rush", [1, 6, 12, 20])
	# бег ускоренных: без врагов строй стоит — ведём бойцов руками, шлейф смотрит на движение
	for k in 20:
		for u in us:
			u.position += Vector2(4.0, -1.0)
		await process_frame
	await _series("e_haste_run", [0])
	await _frames(200)
	# 5. натиск: обычный и «Точно!»
	var at := Vector2(560, 520)
	w._charge_feedback(at, false)
	await _series("charge", [1, 4, 10])
	await _frames(40)
	at = Vector2(760, 520)
	w._charge_feedback(at, true)
	w.contracts.get("_popups").append({"pos": at, "t": 0.0})
	await _series("perfect", [1, 4, 10, 18])
	Settings.economy_override = ""
	quit(0)


func _foes(pts: Array) -> Array[Foe]:
	var out_f: Array[Foe] = []
	for p: Vector2 in pts:
		out_f.append(w.spawn_foe_on_path("zombie", PackedVector2Array([p, p + Vector2(-2, 0)]), p))
	return out_f


func _clear_foes(foes: Array[Foe]) -> void:
	for f in foes:
		if is_instance_valid(f) and f.alive:
			f.take_damage(100000.0, f.position + Vector2(20, 0))


func _frames(n: int) -> void:
	for k in n:
		await process_frame


func _series(tag: String, offs: Array) -> void:
	var done := 0
	for o: int in offs:
		await _frames(o - done)
		done = o
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(out.path_join("%s_f%02d.png" % [tag, o]))
