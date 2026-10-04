extends SceneTree
##
## Замер цены кадра импакта (slow/impact, не тест гейта): густая драка и касты по кругу.
## Окном (рисование — главная цена), vsync выключает сам мир по --bench:
##
##   "$GODOT" --path godot --resolution 1280x720 --script res://tests/legion_impact_bench.gd
##       -- --mute --bench 15 --dev spawn_foes=60 spawn_units=60 invuln=1 no_waves=1
##
## Ку — каждые Q_EVERY с (жёстче настоящего отката: худший случай для слоя импакта), Е — раз
## в E_EVERY с, по точкам, выбранным от состояния мира; с `real` в аргументах после `--` —
## по настоящему откату. Итог печатает мир (--bench): JSON
## с realFps/frameMs/tickMs. Работает и на master (зовёт только hero.cast/hero.reset).
##

const Q_EVERY := 0.5
const E_EVERY := 3.0

## `real` — касты по настоящему откату (без reset): цена в обычной игре.
var _real := false

var w: LegionWorld
var _q_t := 0.0
var _e_t := 1.0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	w = scene.instantiate() as LegionWorld
	root.add_child(w)
	await process_frame
	w.start_map(String(w.args.get("map", "fork")))
	_real = OS.get_cmdline_user_args().has("real")
	process_frame.connect(_on_frame)


func _on_frame() -> void:
	if w.hero == null or w.phase != LegionWorld.Phase.BATTLE:
		return
	var dt := 1.0 / maxf(Engine.get_frames_per_second(), 30.0)
	_q_t -= dt
	_e_t -= dt
	if _real:
		_cast_ready()
		return
	if _q_t <= 0.0:
		_q_t = Q_EVERY
		w.hero.reset()
		var best: Foe = null
		for f in w.foes:
			if f.alive and (best == null or f.position.x < best.position.x):
				best = f
		if best != null:
			w.hero.cast(LegionHero.SLOT_Q, best.position)
	if _e_t <= 0.0:
		_e_t = E_EVERY
		w.hero.reset()
		for u in w.units:
			if u.alive:
				w.hero.cast(LegionHero.SLOT_E, u.position)
				break


func _cast_ready() -> void:
	var h := w.hero
	if h.cd_left(LegionHero.SLOT_Q) <= 0.0:
		for f in w.foes:
			if f.alive:
				h.cast(LegionHero.SLOT_Q, f.position)
				break
	if h.cd_left(LegionHero.SLOT_E) <= 0.0:
		for u in w.units:
			if u.alive:
				h.cast(LegionHero.SLOT_E, u.position)
				break
