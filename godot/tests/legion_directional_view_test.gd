extends SceneTree
## Ракурс — только вид: фаза шага, контакт и замок атаки сохраняются.

const VECTORS := [Vector2.RIGHT, Vector2(1, 1), Vector2.DOWN, Vector2(-1, 1),
	Vector2.LEFT, Vector2(-1, -1), Vector2.UP, Vector2(1, -1)]
const KEYS := ["e", "se", "s", "se", "e", "ne", "n", "ne"]

var _checks := 0
var _fails := 0
var _contacts := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, label: String) -> void:
	_checks += 1
	if not ok:
		_fails += 1
	print("  %s %s" % ["OK" if ok else "FAIL", label])


func _fixture() -> Dictionary:
	var image := Image.create(256, 256, false, Image.FORMAT_RGBA8)
	image.fill(Color.WHITE)
	var texture := ImageTexture.create_from_image(image)
	var frames := SpriteFrames.new()
	var defs := {}
	for state: String in ["idle", "walk", "attack", "death"]:
		var variants := {}
		for key: String in ["", "e", "se", "s", "ne", "n"]:
			var name := state if key == "" else state + "_" + key
			var loop := state in ["idle", "walk"]
			frames.add_animation(name)
			frames.set_animation_speed(name, 20.0 if state == "attack" else 8.0)
			frames.set_animation_loop_mode(name,
				SpriteFrames.LOOP_LINEAR if loop else SpriteFrames.LOOP_NONE)
			for i in 4:
				# Разная длина кадра проверяет именно время, а не номер кадра.
				frames.add_frame(name, texture, 2.0 if key == "se" and i == 0 else 1.0)
			defs[name] = {"loop": loop, "contact_frame": 2 if state == "attack" else -1,
				"hold": state == "death", "pivot_px": [128, 224], "figure_fill": 0.75}
			if key != "":
				variants[key] = name
		defs[state]["directions"] = variants
	return {"frames": frames, "defs": defs}


func _actor(data: Dictionary) -> CharAnim:
	var anim := CharAnim.new()
	root.add_child(anim)
	anim.setup_frames(data["frames"], data["defs"])
	return anim


## Проверяем настоящий loader на PNG/JSON в своём user://, без импорта и боевых ресурсов.
func _load_contract() -> void:
	var base := ProjectSettings.globalize_path("user://directional-fixture")
	var image := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	image.fill(Color.WHITE)
	for folder: String in ["base", "good", "bad"]:
		var path := base.path_join(folder)
		DirAccess.make_dir_recursive_absolute(path)
		for i in 4:
			image.save_png(path.path_join("spr_%02d.png" % i))
		var metadata := {"pivot_px": [128, 224], "figure_fill": 0.75,
			"durations": [2, 1, 1, 1] if folder == "bad" else [1, 1, 1, 1]}
		var file := FileAccess.open(path.path_join("clip.json"), FileAccess.WRITE)
		file.store_string(JSON.stringify(metadata))
		file.close()
	var clips := {"attack": {"dir": base.path_join("base"),
		"fps": 20.0, "loop": false, "contact_frame": 2, "interruptible": true,
		"directions": {
			"e": {"dir": base.path_join("good"),
				"fps": 999.0, "contact_frame": 0, "hold": true},
			"se": {"dir": base.path_join("bad")}}}}
	var built := CharAnim.load_clips(clips)
	var defs: Dictionary = built["defs"]
	var frames: SpriteFrames = built["frames"]
	_check(defs["attack"]["directions"] == {"e": "attack_e"},
		"loader публикует только ракурс с прежним таймингом и контактом")
	_check(frames.get_animation_speed("attack_e") == 20.0
		and defs["attack_e"]["contact_frame"] == 2 and not defs["attack_e"]["hold"],
		"override ракурса не меняет fps/contact/hold одноразового клипа")
	var pivot: Array = defs["attack_e"]["pivot_px"]
	_check(float(pivot[0]) == 128.0 and float(pivot[1]) == 224.0
		and defs["attack_e"]["figure_fill"] == 0.75, "loader читает pivot и figure_fill из clip.json")


func _directions(data: Dictionary) -> void:
	var anim := _actor(data)
	anim.play_state("walk")
	anim.set_frame_and_progress(1, 0.25)
	var phase := anim.cycle_phase()
	for i in VECTORS.size():
		anim.set_direction(VECTORS[i])
		_check(String(anim.animation) == "walk_" + KEYS[i] and anim.current_state() == "walk",
			"сектор %d: кадры %s, состояние walk" % [i, anim.animation])
		_check(anim.facing_sign() == (-1.0 if i in [3, 4, 5] else 1.0),
			"сектор %d: зеркало только W/SW/NW" % i)
		_check(absf(anim.cycle_phase() - phase) < 0.0001, "сектор %d: фаза шага сохранена" % i)
	anim.set_direction(Vector2.ZERO)
	_check(String(anim.animation) == "walk_ne", "нулевой вектор сохраняет направление")
	anim.pause()
	anim.set_direction(Vector2.DOWN)
	_check(not anim.is_playing() and String(anim.animation) == "walk_s", "поворот не снимает pause")
	anim.play_state("idle")
	_check(String(anim.animation) == "idle_s", "остановка сохраняет ракурс")
	var twin := _actor(data)
	_check(twin.sprite_frames == anim.sprite_frames, "экземпляры делят кэш кадров")
	twin.set_direction(Vector2.LEFT)
	twin.play_state("walk")
	_check(String(anim.animation) == "idle_s", "выбор ракурса одного не меняет другого")
	anim.free()
	twin.free()


func _combat(data: Dictionary) -> void:
	var anim := _actor(data)
	anim.contact_frame.connect(func(state: String) -> void:
		if state == "attack":
			_contacts += 1)
	anim.play_state("attack")
	anim.frame = 2
	anim._on_frame_changed()
	_check(_contacts == 1, "контакт атаки ровно один раз, семантическое имя attack")
	anim.set_direction(Vector2(-1, 1))
	anim.play_state("walk")
	_check(String(anim.animation) == "attack_e" and anim.frame == 2,
		"смена направления и walk не перебивают заблокированный удар")
	_check(anim.facing_sign() == 1.0, "во время удара зеркало текущего ракурса сохраняется")
	anim.play_state("attack")
	_check(String(anim.animation) == "attack_se" and anim.frame == 0,
		"следующий удар получает новый ракурс и начинается с нуля")
	anim.frame = 2
	anim._on_frame_changed()
	_check(_contacts == 2, "повторный удар имеет отдельный контакт")
	anim.play_state("death")
	_check(anim.current_state() == "death" and String(anim.animation) == "death_se",
		"death/hold перебивает удар")
	anim._on_animation_finished()
	anim.set_direction(Vector2.UP)
	anim.play_state("walk")
	_check(anim.current_state() == "death" and String(anim.animation) == "death_se",
		"труп сохраняет ракурс и замок")
	_check(CharAnim._same_timing(data["frames"], data["defs"], "attack", "attack_e"),
		"равный тайминг directional attack принят")
	_check(not CharAnim._same_timing(data["frames"], data["defs"], "attack", "attack_se"),
		"ракурс с иной длительностью отвергается при загрузке")
	anim.free()


func _view(data: Dictionary) -> void:
	var holder := Node2D.new()
	root.add_child(holder)
	var view := CharView.new()
	holder.add_child(view)
	view.setup("clerk", 48.0)
	view.set_process(false)
	view._anim.setup_frames(data["frames"], data["defs"])
	view.set_locomotion(1.0)
	view.set_direction(Vector2.DOWN)
	view._face_cur = view._facing
	view._apply_pivot()
	var feet := view._anim.transform * Vector2(0.0, 96.0)
	_check(feet.distance_to(Vector2(0.0, view.ground_px())) < 0.001,
		"pivot PNG [128,224] лежит на прежней земле, независимо от canvas256")
	_check(is_equal_approx(view._anim_local.x.length(), 0.25), "body48 / figure192 = масштаб .25")
	view._tick_direction()
	view.set_direction(Vector2(1, 1))
	holder.position.y -= 2.0
	view._tick_direction()
	_check(String(view._anim.animation) == "walk_n", "фактический вертикальный шаг важнее цели SE")
	view._anim.set_frame_and_progress(1, 0.3)
	var phase := view._anim.cycle_phase()
	view.set_direction(Vector2.LEFT)
	_check(absf(view._anim.cycle_phase() - phase) < 0.0001, "CharView поворот сохраняет фазу")
	view._anim._clip_defs["walk"]["directions"] = {}
	view.set_direction(Vector2.LEFT)
	_check(String(view._anim.animation) == "walk" and view._facing == -1.0,
		"legacy clip без directions сохраняет горизонтальный разворот")
	view.set_direction(Vector2.UP)
	_check(view._facing == -1.0, "legacy вертикальный шаг не сбрасывает предыдущий разворот")
	holder.free()


func _run() -> void:
	CharView.economy_motion = true
	var data := _fixture()
	_load_contract()
	_directions(data)
	_combat(data)
	_view(data)
	CharView.economy_motion = false
	print("LEGION DIRECTIONAL VIEW: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails else 0)
