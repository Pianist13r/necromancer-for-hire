extends SceneTree
## Без ассетов: проверка, что перенос веса не задерживает боевой контакт.

var contacts := 0


func _initialize() -> void:
	var anim := CharAnim.new()
	root.add_child(anim)
	var frames := SpriteFrames.new()
	var pixel := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	pixel.fill(Color.WHITE)
	var texture := ImageTexture.create_from_image(pixel)
	# Этот тест создаёт синтетические восемь кадров и не загружает арт/metadata.
	# Боевые клипы проверяются legion_action_timing_test и directional_actions_assets:
	# здесь фиксированный контакт нужен для независимой проверки walk_start.
	var attack := {"fps": 20.0, "contact_frame": 2}
	for state: String in ["idle", "walk", "walk_start", "attack"]:
		frames.add_animation(state)
		frames.set_animation_speed(state, float(attack["fps"]) if state == "attack" else 33.0)
		frames.set_animation_loop_mode(state, SpriteFrames.LOOP_LINEAR
			if state in ["idle", "walk"] else SpriteFrames.LOOP_NONE)
		for i in (8 if state == "attack" else 6):
			frames.add_frame(state, texture)
		anim._clip_defs[state] = {"loop": state in ["idle", "walk"],
			"contact_frame": int(attack["contact_frame"]) if state == "attack" else -1}
	anim.sprite_frames = frames
	anim.frame_changed.connect(anim._on_frame_changed)
	anim.animation_finished.connect(anim._on_animation_finished)
	anim.contact_frame.connect(func(_state: String) -> void: contacts += 1)
	anim.play_state("idle")
	anim.play_state("walk")
	assert(anim.current_state() == "walk_start")
	anim.frame = 1
	anim.play_state("walk")
	assert(anim.frame == 1, "Повторный walk не должен сбрасывать перенос веса")
	anim.play_state("attack")
	assert(anim.current_state() == "attack", "Старт не должен задерживать удар")
	assert(frames.get_frame_count("attack") == 8)
	assert(is_equal_approx(2.0 / frames.get_animation_speed("attack"), 0.1))
	anim.frame = 2
	anim._on_frame_changed()
	assert(contacts == 1, "Контакт ровно один раз на кадре 2")
	anim.play_state("idle")
	assert(anim.current_state() == "attack", "Удар по-прежнему блокирует локомоцию")
	anim._on_animation_finished()
	anim.play_state("walk")
	anim._on_animation_finished()
	assert(anim.current_state() == "walk", "После intro должен идти цикл")
	anim.play_state("idle")
	anim.play_state("walk")
	anim.play_state("idle")
	assert(anim.current_state() == "idle", "Остановка может прервать intro")
	anim.free()
	print("PASS: intro, interruption, attack 8@20/contact 2, single contact, stop")
	quit(0)
