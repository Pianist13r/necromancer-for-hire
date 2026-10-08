extends SceneTree
## Контракт анимации: комплектность, независимость боя от темпа ходьбы,
## непрерывный замер скорости и прерывание подъёма смертью.

var _checks := 0
var _fails := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, label: String) -> void:
	_checks += 1
	if not ok:
		_fails += 1
	print("  %s %s" % ["OK" if ok else "FAIL", label])


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if "--inventory" in args:
		var path := args[args.find("--inventory") + 1]
		var file := FileAccess.open(path, FileAccess.WRITE)
		var registry := {}
		for id: String in CfgAnim.CHARS:
			registry[id] = CfgAnim.char_def(id)
		file.store_string(JSON.stringify(registry, "\t"))
	for id: String in CfgAnim.CHARS:
		var def := CfgAnim.char_def(id)
		var entry := CharView._entry(id)
		var frames: SpriteFrames = entry["frames"]
		var defs: Dictionary = entry["defs"]
		var required := ["idle", "cast", "ult", "flinch"] if id == "necromancer" \
			else ["idle", "walk", "attack", "death"]
		for state: String in required:
			_check(defs.has(state), id + "/" + state + " загружен")
			if id == "necromancer" or not defs.has(state):
				continue
			for direction: String in CharAnim.SOURCE_DIRECTIONS:
				var key := state + "_" + direction
				_check(defs[state]["directions"].has(direction), id + "/" + key)
				if frames.has_animation(key):
					_check(frames.get_frame_count(key) > 0, id + "/" + key + " кадры")
					if state == "walk":
						var path: String = def["clips"][state]["directions"][direction]["dir"]
						var meta: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path + "/clip.json"))
						_check(absf(CharAnim._clip_time(frames, key, frames.get_frame_count(key)) \
							- float(meta["duration"])) < 0.0001, id + "/" + key + " темп = IK")
		if id != "necromancer":
			_check(int(def.get("death_variants", 1)) >= 2, id + " два варианта смерти")
			if frames.has_animation("death_alt_e"):
				_check(frames.get_frame_texture("death_e", 0) == frames.get_frame_texture("death_alt_e", 0),
					id + " варианты делят текстуры")
				_check(is_equal_approx(CharAnim._clip_time(frames, "death_e", frames.get_frame_count("death_e")),
					CharAnim._clip_time(frames, "death_alt_e", frames.get_frame_count("death_alt_e"))),
					id + " варианты сохраняют время уборки")
	_test_tempo()
	_test_rise_death()
	_test_death_variants()
	_test_ram_continuity()
	print("LEGION ANIMATION RELEASE: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails else 0)


func _view(id: String) -> CharView:
	var view := CharView.new()
	root.add_child(view)
	view.setup(id, 44.0)
	view.set_process(false)
	view._pop_t = -1.0
	return view


func _test_tempo() -> void:
	var view := _view("skeleton")
	for i in 120:
		view.position.x += 35.0 / 60.0
		view.set_locomotion(35.0 / 60.0)
		view._tick_walk_tempo(1.0 / 60.0)
	_check(absf(view.walk_tempo() - 0.5) < 0.03,
		"повторные walk сохраняют замер фактической скорости (35/70)")
	view.play_once(&"attack")
	view.set_locomotion(1.0, 2.0)
	_check(is_equal_approx(view.clip_speed_scale(), 1.0),
		"команда ускоренной ходьбы не ускоряет заблокированный удар")
	view.play_once(&"death")
	view.set_locomotion(0.0, 0.5)
	_check(is_equal_approx(view.clip_speed_scale(), 1.0), "смерть не наследует темп ходьбы")
	view.free()


func _test_rise_death() -> void:
	var view := _view("zombie")
	view.play_once(&"rise")
	view._tick_stub(0.1)
	view.play_once(&"death")
	_check(view._stub_kind == "", "смерть отменяет незавершённый подъём")
	_check(view._body.position.is_zero_approx() and is_equal_approx(view._body.modulate.a, 1.0),
		"смерть не остаётся под землёй и полупрозрачной после rise")
	view.free()


func _test_death_variants() -> void:
	var view := _view("zombie")
	var anim := view._anim
	# Альтернативный вариант выбирается внутри CharAnim; публичное состояние всё ещё death.
	_check(anim.has_method("set_death_variant"), "вариант смерти — локальное состояние вида")
	if anim.has_method("set_death_variant"):
		anim.call("set_death_variant", 1)
		view.play_once(&"death")
		_check(anim.current_state() == "death", "вариант сохраняет контракт death")
		_check(String(anim.animation).begins_with("death_alt"), "выбран второй клип")
		anim._on_animation_finished()
		view.set_locomotion(1.0)
		_check(anim.current_state() == "death", "альтернативный труп удерживается")
	view.free()


func _test_ram_continuity() -> void:
	var view := _view("boss")
	var foe := Foe.new()
	foe.view = view
	foe.ram_t = 0.2
	foe.ram_pos = Vector2(100, 0)
	foe._tick_boss(0.1)
	var before := view._anim.cycle_phase()
	foe._tick_boss(0.15)
	_check(before > 0.0 and view._anim.cycle_phase() >= before - 0.0001,
		"предупреждение → разбег босса не сбрасывает позу замаха")
	foe.free()
	view.free()
