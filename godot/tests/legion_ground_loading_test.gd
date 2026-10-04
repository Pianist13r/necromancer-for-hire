extends SceneTree
## Регресс ожидания PgArt: успех, отказ, перезапуск и защита игрового ввода.

const SAVE := "user://legion_ground_loading_integration_test.cfg"
const DEVICE := 16

var _checks := 0
var _fails := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_test_delayed_ready_releases_world()
	_test_restart_ignores_stale_ready_then_falls_back()
	_test_timeout_and_stale_generation()
	await _test_scene_tree_integration()
	print("LEGION GROUND LOADING: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


func _test_delayed_ready_releases_world() -> void:
	var source := TerrainView.new()
	source.setup(_map(), false, true)
	var request := PgArt.new()
	source.call("_watch_pgart_request", request, source.get("_request_generation"))
	var world := LegionWorld.new()
	var generation := 7
	world.set("_ground", source)
	world.set("_depth_generation", generation)
	world.set("_ground_loading", true)
	source.background_build_finished.connect(
		world._on_ground_build_finished.bind(source, generation), CONNECT_ONE_SHOT
	)
	_check(source.background_build_pending(), "async request holds background pending")
	request.ready.emit(_texture())
	_check(not source.background_build_pending(), "delayed texture completes request")
	_check(not world.is_ground_loading(), "successful texture releases the world")
	_check(source.background_texture() != null, "successful texture replaces fallback ground")
	world.free()
	source.free()


func _test_restart_ignores_stale_ready_then_falls_back() -> void:
	var source := TerrainView.new()
	var world := LegionWorld.new()
	var generation := 11
	world.set("_ground", source)
	world.set("_depth_generation", generation)
	world.set("_ground_loading", true)
	source.setup(_map(), false, true)
	var stale_request := PgArt.new()
	source.call("_watch_pgart_request", stale_request, source.get("_request_generation"))
	source.background_build_finished.connect(
		world._on_ground_build_finished.bind(source, generation), CONNECT_ONE_SHOT
	)
	var next_generation: int = source.get("_request_generation") + 1
	source.setup(_map(), false, true)
	var current_request := PgArt.new()
	source.call("_watch_pgart_request", current_request, source.get("_request_generation"))
	stale_request.ready.emit(_texture())
	_check(source.background_build_pending(), "restarted request ignores stale ready")
	_check(world.is_ground_loading(), "stale completion cannot release restarted world")
	current_request.ready.emit(null)
	_check(not source.background_build_pending(), "failed request resolves instead of hanging")
	_check(not world.is_ground_loading(), "failed request releases fallback world")
	_check(source.background_texture() == null, "failure retains procedural fallback")
	_check(
		int(source.get("_request_generation")) == next_generation,
		"restart advances the TerrainView request generation"
	)
	world.free()
	source.free()


func _test_timeout_and_stale_generation() -> void:
	var world := LegionWorld.new()
	var source := TerrainView.new()
	var generation := 15
	world.set("_ground", source)
	world.set("_depth_generation", generation)
	world.set("_ground_loading", true)
	source.setup(_map(), false, true)
	var request := PgArt.new()
	source.call("_watch_pgart_request", request, source.get("_request_generation"))
	world.call("_on_ground_build_timeout", source, generation - 1)
	_check(world.is_ground_loading(), "old-map timeout cannot release current map")
	world.call("_on_ground_build_timeout", source, generation)
	_check(not world.is_ground_loading(), "active-map timeout releases fallback")
	_check(not source.background_build_pending(), "timeout invalidates pending PgArt request")
	request.ready.emit(_texture())
	_check(
		source.background_texture() == null,
		"late ready after timeout cannot replace fallback or create depth props"
	)
	world.free()
	source.free()


func _test_scene_tree_integration() -> void:
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	Input.use_accumulated_input = false
	root.size = Vector2i(1280, 720)
	var scene := load("res://scenes/legion_world.tscn") as PackedScene
	var world := scene.instantiate() as LegionWorld
	world.embedded = true
	world.in_campaign = true
	root.add_child(world)
	await process_frame
	await process_frame
	world.dev["gray"] = "1"  # не запускаем PgArt в сценарии приёмки
	world.dev["no_waves"] = "1"
	world.start_map("wasteland")
	_check(world.phase == LegionWorld.Phase.BATTLE, "реальный embedded-мир начал Пустырь")
	_check(not world.is_ground_loading(), "обычная карта готовится синхронно до тестового ожидания")

	var pending := _install_pending_ground(world)
	var request: PgArt = pending["request"]
	world.start_lessons(true)
	_check(world.tutorial == null, "урок не начинается поверх настоящей плашки загрузки")
	var now_before := world.now
	for _frame in 3:
		await process_frame
	_check(
		is_equal_approx(world.now, now_before),
		"реальный _process не двигает время боя при загрузке"
	)

	var cooldown_before := world.hero.cd_left(LegionHero.SLOT_Q)
	await _key(KEY_Q, true)
	await _key(KEY_Q, false)
	_check(world.ability_aim.slot == -1, "реальный ввод Q не запускает способность под загрузкой")
	_check(
		is_equal_approx(world.hero.cd_left(LegionHero.SLOT_Q), cooldown_before),
		"Q не расходует откат способности под загрузкой"
	)
	var contracts_before := world.contracts.contracts.size()
	await _mouse_button(Vector2(240, 290), MOUSE_BUTTON_LEFT, true)
	await _mouse_motion(Vector2(300, 290))
	await _mouse_button(Vector2(340, 290), MOUSE_BUTTON_LEFT, false)
	_check(
		world.contracts.contracts.size() == contracts_before,
		"настоящий drag мышью не создаёт договор под blocker-слоем"
	)
	await _key(KEY_ESCAPE, true)
	_check(world.paused, "реальная Escape ставит загрузку на паузу")
	await _key(KEY_ESCAPE, false)
	await _key(KEY_ESCAPE, true)
	_check(not world.paused, "реальная Escape снимает паузу и возвращает загрузку")
	await _key(KEY_ESCAPE, false)

	request.ready.emit(_texture())
	_check(not world.is_ground_loading(), "готовность фона снимает настоящий loading state")
	_check(
		world.tutorial != null and world.tutorial.active,
		"после готовности создаётся настоящий LegionTutorial"
	)
	_check(
		world.tutorial != null and world.tutorial.step_id() == &"draw",
		"настоящий tutorial начинает с первого урока Пустыря"
	)
	_check(not bool(world.get("_pending_ground_lessons")), "завершённая заявка урока очищена")

	# Esc → «Заново»: сохранённый pending request повторно ставит принудительный урок.
	world.start_map("wasteland")
	var restart_case := _install_pending_ground(world)
	var restart_request: PgArt = restart_case["request"]
	world.start_lessons(true)
	_check(
		world.tutorial == null and bool(world.get("_pending_ground_lessons")),
		"до restart урок кампании действительно ждёт фон"
	)
	Campaign.record_result("wasteland", true, 1.0)
	world.restart()
	_check(
		world.tutorial != null and world.tutorial.step_id() == &"draw",
		"restart переносит ожидавший урок на новое поколение карты"
	)
	restart_request.ready.emit(_texture())
	_check(
		world.tutorial != null and world.tutorial.step_id() == &"draw",
		"готовность старого поколения не меняет tutorial после restart"
	)

	# Выход в меню отменяет и загрузку, и ожидавший старт урока.
	world.start_map("wasteland")
	var menu_case := _install_pending_ground(world)
	var menu_request: PgArt = menu_case["request"]
	world.start_lessons(true)
	world.go_to_menu()
	_check(
		world.phase == LegionWorld.Phase.MENU and world.tutorial == null,
		"go_to_menu отменяет активный бой и tutorial"
	)
	_check(
		not world.is_ground_loading() and not bool(world.get("_pending_ground_lessons")),
		"go_to_menu сбрасывает ожидание фона и урока"
	)
	menu_request.ready.emit(_texture())
	_check(world.tutorial == null, "готовность старого фона после меню не запускает урок")

	# Проверяем continuation настоящего async timeout: источник освобождается, пока корутина ждёт.
	world.start_map("wasteland")
	var freed_case := _install_pending_ground(world)
	var freed_source: TerrainView = freed_case["source"]
	world.call("_wait_for_ground_build_timeout", freed_source, world.get("_depth_generation"))
	world.call("_cancel_ground_loading")
	freed_source.free()
	await create_timer(LegionWorld.GROUND_LOAD_TIMEOUT_SEC + 0.25, true, false, true).timeout
	_check(
		not world.is_ground_loading() and world.tutorial == null,
		"таймаут после free-source выходит до вызова typed timeout callback"
	)

	world.queue_free()
	await process_frame
	Campaign.reset()


func _install_pending_ground(world: LegionWorld) -> Dictionary:
	var source := TerrainView.new()
	source.setup(world.map, true, true)
	source.set("_pending_pgart", false)
	var request := PgArt.new()
	source.call("_watch_pgart_request", request, source.get("_request_generation"))
	world.add_child(source)
	world.set("_ground", source)
	world.call("_begin_ground_loading", source, world.get("_depth_generation"))
	return {"source": source, "request": request}


func _key(code: Key, pressed: bool) -> void:
	var event := InputEventKey.new()
	event.device = DEVICE
	event.physical_keycode = code
	event.keycode = code
	event.pressed = pressed
	Input.parse_input_event(event)
	await process_frame


func _mouse_button(at: Vector2, button: MouseButton, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.device = DEVICE
	event.position = root.get_final_transform() * at
	event.global_position = event.position
	event.button_index = button
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	event.pressed = pressed
	Input.parse_input_event(event)
	await process_frame


func _mouse_motion(at: Vector2) -> void:
	var event := InputEventMouseMotion.new()
	event.device = DEVICE
	event.position = root.get_final_transform() * at
	event.global_position = event.position
	Input.parse_input_event(event)
	await process_frame


func _texture() -> Texture2D:
	var image := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	image.fill(Color.WHITE)
	return ImageTexture.create_from_image(image)


func _map() -> Dictionary:
	return {
		"id": "loading-test",
		"biome": "grave",
		"procgen": {"version": 1},
		"roads": [],
		"walls": [],
		"rocks": [],
		"props": [],
		"water": [],
		"swamp": [],
		"bridges": [],
		"decor": [],
		"plots": [],
		"ambient": {"glows": []}
	}


func _check(condition: bool, label: String) -> void:
	_checks += 1
	if condition:
		print("  ok   ", label)
	else:
		_fails += 1
		print("  FAIL ", label)
