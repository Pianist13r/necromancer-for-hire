extends SceneTree
##
## Кадры приёмки слоя эффектов LegionFx (не тест гейта). Окном, не headless:
##
##   "$GODOT" --path godot --resolution 1920x1080 --fixed-fps 60
##       --script res://tests/legion_fx_shots.gd -- --mute --out C:/AI/necro/batches/legion/art/fx
##
## Каждый эффект вызывается настоящим путём (убийство, смерть бойца, рождение, удар, Котёл,
## волна, конец боя) и снимается несколькими кадрами по ходу; рядом пишется shots.json —
## {файл, эффект, точка мира}, по нему tools-скрипт режет кадры в листы в игровом масштабе.
##

const AMB := "user://legion_fx_shots_ambient.json"

var w: LegionWorld
var fx: LegionFx
var out := "user://"
var log_rows: Array = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var argv := OS.get_cmdline_user_args()
	var i := argv.find("--out")
	out = argv[i + 1] if i >= 0 and i + 1 < argv.size() else "user://"
	DirAccess.make_dir_recursive_absolute(out)
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	w = scene.instantiate() as LegionWorld
	root.add_child(w)
	await process_frame
	w.start_map("fork")
	fx = w.get_node("LegionFx") as LegionFx
	_write_ambient()
	fx.load_ambient(AMB)
	await _frames(20)
	# 1. смерть врагов (и босса) настоящим уроном
	var foes: Array[Foe] = []
	for p: Vector2 in [Vector2(560, 470), Vector2(610, 490), Vector2(660, 470)]:
		foes.append(w.spawn_foe_on_path("zombie", PackedVector2Array([p, p + Vector2(-2, 0)]), p))
	await _frames(20)
	for f in foes:
		f.take_damage(1000.0, f.position + Vector2(20, 0))
	await _series("foe_death", Vector2(610, 440), [3, 12, 24, 45])
	# босс отдельно: его гибель даёт вспышку всего мира (LegionAudio), она забила бы кадры выше
	var bp := Vector2(1000, 560)
	var boss := w.spawn_foe_on_path("boss", PackedVector2Array([bp, bp + Vector2(-2, 0)]), bp)
	await _frames(20)
	if boss != null:
		boss.take_damage(100000.0, bp + Vector2(30, 0))
	await _series("boss_death", bp - Vector2(0, 30), [4, 20, 45])
	await _frames(40)
	# 2. смерть бойцов-скелетов
	var us: Array[Legionnaire] = []
	for p: Vector2 in [Vector2(420, 560), Vector2(460, 580)]:
		us.append(w.spawn_unit(LegionCfg.KIND_LABORER, p))
	await _frames(30)
	for u in us:
		u.take_damage(1000.0, u.position + Vector2(20, 0))
	await _series("unit_death", Vector2(440, 550), [3, 10, 20, 34, 50])
	# 3. рождение бойца
	for p: Vector2 in [Vector2(520, 640), Vector2(560, 650)]:
		w.spawn_unit(LegionCfg.KIND_LABORER, p)
	await _series("spawn", Vector2(540, 630), [2, 8, 14])
	# 4. удары по персонажам
	var near := w.units_near(w.cauldron_pos, 200.0)
	for k in mini(4, near.size()):
		near[k].view.react_hit()
	await _series("hit", w.cauldron_pos + Vector2(60, -20), [1, 4, 8])
	# 5. Котёл: удар и бульканье
	w.damage_cauldron(1.0)
	await _series("cauldron", w.cauldron_pos + Vector2(0, -40), [2, 8, 16, 30])
	# 6. прорыв (на Развилке трещин нет — вызов эффекта напрямую)
	fx.emit_breach(Vector2(900, 400))
	await _series("breach", Vector2(900, 400), [3, 12, 24])
	# 7. начало волны: отсвет у ворот
	# первая волна Развилки к этому кадру давно стартовала — сигнал ещё раз, как его шлёт мир
	w.wave_started.emit(0, w.wave_runner.total())
	var gates := fx.gate_points(0)
	print("ворота волны 1: ", gates)
	await _series("gate", gates[0] if not gates.is_empty() else Vector2(1180, 360), [8, 30, 60])
	# 8. фон карты (тестовые данные): каждый вид — своей вырезкой
	await _frames(60)
	await _series("amb_glow", Vector2(680, 260), [0])
	await _series("amb_ember", Vector2(910, 360), [0])
	await _series("amb_water", Vector2(425, 355), [0])
	await _series("amb_wisp", Vector2(190, 600), [0, 40])
	await _series("amb_fog", Vector2(100, 380), [0])
	# 9. победа
	w.force_end(true)
	await _series("victory", Vector2(640, 360), [30, 100])
	# 10. поражение
	w.restart()
	await _frames(30)
	w.force_end(false)
	await _series("defeat", w.cauldron_pos + Vector2(0, -60), [40, 110])
	var fa := FileAccess.open(out.path_join("shots.json"), FileAccess.WRITE)
	fa.store_string(JSON.stringify(log_rows))
	fa.close()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(AMB))
	quit(0)


## Тестовые данные фона для Развилки: свечи у плит, угли, туман по краю, огоньки, «вода».
func _write_ambient() -> void:
	var data := {
		"glows": [{"pos": [606, 222], "r": 22, "color": "ffb060", "flicker": 0.3},
			{"pos": [720, 208], "r": 20, "color": "ffb060", "flicker": 0.3},
			{"pos": [745, 326], "r": 22, "color": "ffb060", "flicker": 0.25}],
		"embers": [{"rect": [880, 380, 60, 20], "rate": 2.0, "color": "ff7a30"}],
		"fog": [{"rect": [0, 120, 200, 520], "count": 4, "color": "c8d2e8", "alpha": 0.12,
			"drift": [6, 0]}],
		"wisps": [{"rect": [80, 560, 220, 120], "count": 3, "color": "7fffd8"}],
		"water": [{"poly": [[380, 330], [470, 330], [470, 380], [380, 380]], "rate": 4,
			"color": "e0f6ff"}],
	}
	var fa := FileAccess.open(AMB, FileAccess.WRITE)
	fa.store_string(JSON.stringify(data))
	fa.close()


func _frames(n: int) -> void:
	for k in n:
		await process_frame


## Кадры эффекта через offs кадров от вызова (по возрастанию).
func _series(tag: String, focus: Vector2, offs: Array) -> void:
	var done := 0
	for o: int in offs:
		await _frames(o - done)
		done = o
		await RenderingServer.frame_post_draw
		var file := "%s_f%02d.png" % [tag, o]
		root.get_texture().get_image().save_png(out.path_join(file))
		log_rows.append({"file": file, "tag": tag, "x": focus.x, "y": focus.y,
			"live": fx.live_count(), "amb": fx.ambient_count()})
