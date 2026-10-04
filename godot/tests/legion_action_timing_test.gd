extends SceneTree
## Вид не сдвигает бой: полный след HP/снарядов/CD/позиции/RNG по настоящим сущностям.
## --record-baseline <scratch.json> снимает след до правок, --baseline сравнивает после.

const SAVE := "user://legion_action_timing_test.cfg"
const DT := 1.0 / 60.0
## Сняты до action timing (master6685dd25 + view-only directional96e09daf).
const BASELINE_HASHES := {
	"laborer": "8a80eed04aa0d79e6a32448b85f4bdef15788ec0fe6027a78275eec21074ddc1",
	"guard": "aab4612c1be51979615aaed316812d622b39379b6d5bc4c586a287aedad45c77",
	"clerk": "4d40ff1feedec86f039e92cbbabd427d53f3f8942dbf3d62288ca0c7771b0816",
	"signer": "c785a749c45b6c2938e24aab3d975b71b0eb925714ffe5d89ff514c3d483871c",
	"lawyer": "f7c3fd3070a319d4e28e5ab97e0001082ace44dd85029341e6711a97c2cea2b8",
}
var _checks := 0
var _fails := 0
var _world: LegionWorld


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, label: String) -> void:
	_checks += 1
	if not ok:
		_fails += 1
	print("  %s %s" % ["OK" if ok else "FAIL", label])


func _fresh() -> void:
	_world.dev = {"spawn_units": "0", "no_waves": "1"}
	_world._base_seed = 73
	_world.start_map("wasteland")
	_world.set_process(false)
	_world.terrain = LegionTerrain.new().setup({})
	_world.dev_invuln = false
	_world.contracts.active = true


func _trace(kind: StringName, special := "") -> Array:
	_fresh()
	var at := Vector2(500, 300)
	var unit := _world.spawn_unit(kind, at)
	unit.hp = 10000.0
	unit.max_hp = 10000.0
	var char_id := "zombie" if special == "" else special
	var foe_at := at + Vector2(20, 0) if special == "" else at + Vector2(100, 0)
	var foe := _world.spawn_foe_on_path(char_id,
		PackedVector2Array([foe_at, at]), foe_at)
	foe.hp = 10000.0
	foe.max_hp = 10000.0
	foe._skill_cd = 0.0
	if special == "lawyer":
		_world.contracts.add_contract(PackedVector2Array([
			foe_at, foe_at + Vector2(0, 150)]), 1, false, LegionCfg.KIND_LABORER)
	var trace := []
	for tick in 300:
		_world.now = tick * DT
		_world.grid.rebuild()
		unit.tick(DT)
		foe.tick(DT)
		_world.projectiles.tick(DT)
		var shots := []
		for shot: Dictionary in _world.projectiles.shots:
			shots.append([shot["pos"].x, shot["pos"].y, shot["dmg"]])
		var segments := []
		for contract: Contract in _world.contracts.contracts:
			for i in contract.seg_count():
				segments.append(contract.seg_alive(i))
		trace.append([unit.hp, foe.hp, unit._atk_cd, foe._atk_cd,
			unit.position.x, unit.position.y, foe.position.x, foe.position.y,
			unit.state, foe.state, shots, str(_world.rng.state), foe.stamp_t,
			foe.law_read_t, foe._skill_cd, segments])
	return trace


func _arg_value(flag: String) -> String:
	var args := OS.get_cmdline_user_args()
	var index := args.find(flag)
	return args[index + 1] if index >= 0 and index + 1 < args.size() else ""


func _fixture() -> Dictionary:
	var image := Image.create(224, 224, false, Image.FORMAT_RGBA8)
	image.fill(Color.WHITE)
	var texture := ImageTexture.create_from_image(image)
	var frames := SpriteFrames.new()
	var defs := {}
	for state: String in ["idle", "walk", "attack", "death"]:
		frames.add_animation(state)
		frames.set_animation_speed(state, 10.0)
		var loop := state in ["idle", "walk"]
		frames.set_animation_loop_mode(state,
			SpriteFrames.LOOP_LINEAR if loop else SpriteFrames.LOOP_NONE)
		for weight: float in [2.0, 0.5, 1.0, 0.5, 1.0, 1.0]:
			frames.add_frame(state, texture, weight)
		defs[state] = {"loop": loop, "hold": state == "death",
			"contact_frame": 3 if state == "attack" else -1}
	return {"frames": frames, "defs": defs, "tex": {}}


func _view_cases() -> void:
	var old: Dictionary = CharView._cache["skeleton"]
	CharView._cache["skeleton"] = _fixture()
	var view := CharView.new()
	root.add_child(view)
	view.setup("skeleton", 46.0)
	view.set_locomotion(1.0)
	var contacts := [0]
	view.contact.connect(func(_state: StringName) -> void: contacts[0] += 1)
	view.begin_action_tick()
	view.prepare_attack(0.2)
	_check(not view._anim.is_preparing_attack(), "до последних100ms подготовка не начинается")
	view.prepare_attack(0.05)
	view.end_action_tick()
	_check(view._anim.is_preparing_attack() and not view._anim._locked,
		"подготовка не держит замок анимации")
	_check(view._anim.frame == 0 and absf(view._anim.frame_progress - 0.875) < 0.001,
		"ползамаха ищется по весам кадров, не по их числу")
	_check(contacts[0] == 0 and not view._anim.is_playing(),
		"подготовка не вызывает контакт и не убегает реальными часами")
	view.begin_action_tick()
	view.end_action_tick()
	_check(view.current_state() == &"walk" and not view._anim.is_preparing_attack(),
		"нет новой заявки валидной цели — подготовка отменена")
	view.prepare_attack(0.01)
	view.set_locomotion(1.0)
	_check(view.current_state() == &"walk" and view._anim.is_playing(),
		"ходьба перебивает подготовку и не остаётся на pause")
	view.attack_impact()
	_check(view._anim.frame == 3 and contacts[0] == 1,
		"первый удар немедленно показывает контактную позу")
	view.set_locomotion(0.0)
	_check(view.current_state() == &"attack", "остановка в этот же tick не отрезает impact")
	view._anim.set_frame_and_progress(4, 0.5)
	view.attack_impact()
	_check(view._anim.frame == 3 and contacts[0] == 2,
		"новый strike во время recovery перезапускает контакт ровно раз")
	view._anim._on_frame_changed()
	_check(contacts[0] == 2, "контактный сигнал не дублируется на удерживаемой позе")
	view.set_locomotion(1.0)
	_check(view.current_state() == &"walk", "ходьба не ждёт длинного recovery")
	view.prepare_special(2.0, 2.2)
	_check(view._anim.frame == 2 and contacts[0] == 2,
		"спецдействие удерживает последнюю позу до касания без контакта")
	view.cancel_action()
	_check(not view._anim.is_preparing_attack() and view.current_state() != &"attack",
		"stun/cancel сбрасывает только visual action")
	view.prepare_attack(0.05)
	view.play_once(&"death")
	view.attack_impact()
	view.prepare_attack(0.01)
	view.set_locomotion(1.0)
	_check(view.current_state() == &"death" and contacts[0] == 2,
		"смерть перебивает подготовку; удар и шаг не поднимают труп")
	view.free()
	_fresh()
	var unit := _world.spawn_unit(LegionCfg.KIND_LABORER, Vector2(500, 300))
	unit.view.rotation = 0.25
	unit._die()
	unit._tick_dead(0.4)
	_check(unit.view.current_state() == &"death" and unit.view.rotation == 0.0
		and unit.view.position.y == 0.0, "новый death hold не получает старый rigid rotate/drop")
	unit.view._anim.set_frame_and_progress(5, 1.0)
	unit.view._anim._on_animation_finished()
	unit._tick_dead(0.3)
	_check(unit.view.current_state() == &"death" and not unit.is_corpse_done(),
		"death hold остаётся трупом до прежнего TTL1.2s")
	unit._tick_dead(0.6)
	_check(unit.is_corpse_done(), "новый клип не меняет игровой TTL трупа")
	CharView._cache["skeleton"] = old
	_entity_cancellation()
	_special_events()
	_metadata_contact()


func _entity_cancellation() -> void:
	_fresh()
	var unit := _world.spawn_unit(LegionCfg.KIND_LABORER, Vector2(500, 300))
	var foe := _world.spawn_foe_on_path("zombie", PackedVector2Array([
		Vector2(520, 300), Vector2(500, 300)]), Vector2(520, 300))
	_world.grid.rebuild()
	unit._atk_cd = 0.08
	unit.tick(DT)
	_check(unit.view._anim.is_preparing_attack(), "unit tick готовит удар по доступной цели")
	foe.position.x = 1000.0
	_world.grid.rebuild()
	unit.tick(DT)
	_check(not unit.view._anim.is_preparing_attack(), "unit tick отменяет подготовку после loss")
	foe.position = unit.position + Vector2(20, 0)
	_world.grid.rebuild()
	unit._atk_cd = 0.08
	unit.tick(DT)
	unit._stun_t = 0.2
	unit.tick(DT)
	_check(not unit.view._anim.is_preparing_attack(), "unit stun отменяет visual preparation")
	foe._atk_cd = 0.08
	foe._target = unit
	foe.tick(DT)
	_check(foe.view._anim.is_preparing_attack(), "foe tick готовит удар по прежней цели")
	foe.stun_t = 0.2
	foe.tick(DT)
	_check(not foe.view._anim.is_preparing_attack(), "foe stun отменяет visual preparation")
	foe.stun_t = 0.0
	foe._atk_cd = 0.08
	foe.tick(DT)
	foe.take_damage(10000.0, unit.position)
	_check(foe.view.current_state() == &"death" and not foe.view._anim.is_preparing_attack(),
		"foe death перебивает подготовку в том же действующем событии")


func _special_events() -> void:
	_fresh()
	var at := Vector2(500, 300)
	var unit := _world.spawn_unit(LegionCfg.KIND_LABORER, at)
	var signer := _world.spawn_foe_on_path("signer", PackedVector2Array([
		at + Vector2(100, 0), at]), at + Vector2(100, 0))
	signer._skill_cd = 0.0
	_world.grid.rebuild()
	var contacts := [0]
	signer.view.contact.connect(func(_state: StringName) -> void: contacts[0] += 1)
	signer._tick_stamp(DT)
	signer._tick_stamp(0.1)
	_check(signer.view._anim.is_preparing_attack() and contacts[0] == 0,
		"stamp держит поднятую позу до действующего события1s")
	var hp := unit.hp
	signer._tick_stamp(1.0)
	_check(contacts[0] == 1 and unit.hp < hp,
		"stamp impact и прежний stamp_hit происходят в одном tick")
	_fresh()
	var point := Vector2(600, 300)
	var contract := _world.contracts.add_contract(PackedVector2Array([
		point, point + Vector2(0, 150)]), 1, false, LegionCfg.KIND_LABORER)
	var lawyer := _world.spawn_foe_on_path("lawyer", PackedVector2Array([
		point, point + Vector2.LEFT * 100]), point)
	lawyer.law_c = contract
	lawyer.law_seg = 0
	lawyer.law_pos = point
	contacts[0] = 0
	lawyer.view.contact.connect(func(_state: StringName) -> void: contacts[0] += 1)
	lawyer._tick_lawyer(DT)
	lawyer._tick_lawyer(0.1)
	_check(lawyer.view._anim.is_preparing_attack() and contacts[0] == 0 and contract.seg_alive(0),
		"read держит подготовку; визуальный контакт не рвёт договор раньше2.2s")
	lawyer._tick_lawyer(2.2)
	_check(contacts[0] == 1 and not contract.seg_alive(0),
		"read impact и прежний tear_segment происходят в одном tick")


func _metadata_contact() -> void:
	var folder := ProjectSettings.globalize_path("user://action-contact-fixture")
	DirAccess.make_dir_recursive_absolute(folder)
	var image := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	image.fill(Color.WHITE)
	for i in 4:
		image.save_png(folder.path_join("spr_%02d.png" % i))
	var file := FileAccess.open(folder.path_join("clip.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify({"contact_frame": 1, "src_index": [0, 2, 3],
		"durations": [1.0, 0.5, 0.5, 1.0]}))
	file.close()
	var loaded := CharAnim.load_clips({"attack": {"dir": folder,
		"fps": 20.0, "loop": false, "contact_frame": 2}})
	_check(loaded["defs"]["attack"]["contact_frame"] == 1,
		"clip metadata contact — финальный PNG индекс, не повторный src_index remap")


func _run() -> void:
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	_world = (load("res://scenes/legion_world.tscn") as PackedScene).instantiate() as LegionWorld
	_world.embedded = true
	root.add_child(_world)
	await process_frame
	var traces := {}
	for kind: StringName in [LegionCfg.KIND_LABORER, LegionCfg.KIND_GUARD, LegionCfg.KIND_CLERK]:
		traces[String(kind)] = _trace(kind)
	for special: String in ["signer", "lawyer"]:
		traces[special] = _trace(LegionCfg.KIND_LABORER, special)
	var record := _arg_value("--record-baseline")
	if record != "":
		var file := FileAccess.open(record, FileAccess.WRITE)
		file.store_string(JSON.stringify(traces))
		file.close()
		print("BASELINE recorded: ", record)
	var baseline := _arg_value("--baseline")
	if baseline != "":
		var previous: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(baseline))
		for label: String in traces:
			# JSON читает числа как float: одинаковый roundtrip для обеих сторон.
			var current: Array = JSON.parse_string(JSON.stringify(traces[label]))
			var same := JSON.stringify(current) == JSON.stringify(previous.get(label, []))
			_check(same, label + ": 300 ticks damage/projectiles/CD/position/RNG unchanged")
			if not same:
				var old: Array = previous.get(label, [])
				for i in mini(old.size(), current.size()):
					if JSON.stringify(old[i]) != JSON.stringify(current[i]):
						print("FIRST DIFF tick ", i, " old=", old[i], " new=", current[i])
						break
	for label: String in traces:
		var digest := JSON.stringify(traces[label]).sha256_text()
		print("TRACE ", label, " ", digest)
		_check(digest == BASELINE_HASHES[label], label + ": golden300-tick baseline unchanged")
	if record == "":
		_view_cases()
	_world.queue_free()
	await process_frame
	Campaign.reset()
	print("LEGION ACTION TIMING: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails else 0)
