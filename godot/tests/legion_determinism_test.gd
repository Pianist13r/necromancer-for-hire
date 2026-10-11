extends SceneTree
##
## Детерминизм боя для lockstep «Схватки» (B-457, 10.10.2026):
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_determinism_test.gd -- --mute
##
## Один и тот же бой (карта, сид, боты) гоняется дважды на свежем мире: «спокойно» — шаг мира
## своим кадром (LegionWorld._process, --fixed-fps 60 — шаг 1/60), и «под нагрузкой» — кадр
## стоит лишние настенные миллисекунды (OS.delay_msec, неровно), каждые несколько кадров —
## тряска экрана и вспышка (Juice.shake/flash: окно Juice.permit — по FxClock, а он вне записи —
## настенные часы, так что число эффектов зависит от нагрузки). Отпечаток мира
## LegionWorld.net_digest() (тот, что сверяют клиенты сетевого матча) снимается каждые 60 шагов
## мира и должен совпасть на всём отрезке: вид (тряска, вспышки, часы эффектов) бой не пишет.
##   1) одиночка: бот selective, карта fork, сид 2;
##   2) «Схватка» бот против бота (pvp:duel, сид 7): под нагрузкой мир шагает как сетевая сессия
##      при догоне — по 1/2/5/3/1/4 шага NET_DT за кадр (NetSession._tick_playing), а не по одному.
## Миры встроенные (embedded): корневой мир сам стартует бой из аргументов, и часы вербовки
## (_assign_t) того боя переходят в следующий start_map — это история мира, а не нагрузка (см.
## BACKLOG, 10.10); сетевой матч их сбрасывает (start_net_match).
## Итог «LEGION DETERMINISM: N/M OK»; код выхода 1, если что-то упало.
##

const SAVE := "user://legion_determinism_test.cfg"
const WORLD_SCENE := "res://scenes/legion_world.tscn"
const STEPS := 60 * 40
const DIGEST_EVERY := 60
## Неровная «нагрузка»: лишние мс кадра по кругу.
const LOAD_MS := [0, 23, 2, 0, 31, 9, 0, 5]
## Догон сетевой сессии: шагов мира за кадр по кругу (как B_PACE в legion_net_world_test).
const CATCHUP := [1, 2, 5, 3, 1, 4]
const FX_EVERY := 5

var _fails := 0
var _checks := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(cond: bool, what: String) -> void:
	_checks += 1
	if cond:
		print("  ok   ", what)
	else:
		_fails += 1
		print("  FAIL ", what)


func _run() -> void:
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	_check(Settings.is_screen_shake_enabled() and Settings.is_flashes_enabled(),
		"тряска и вспышки включены (настройки по умолчанию)")
	_check(not FxClock.frames_mode(), "часы эффектов — настенные (как в живой игре)")
	await _pair("одиночка: бот selective, fork s2", "fork", 2, false)
	await _pair("«Схватка»: бот против бота, pvp:duel s7", "pvp:duel", 7, true)
	Campaign.reset()
	print("LEGION DETERMINISM: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


func _pair(label: String, map_id: String, seed_value: int, duel: bool) -> void:
	print("— ", label)
	var calm := await _battle(map_id, seed_value, duel, false)
	var busy := await _battle(map_id, seed_value, duel, true)
	for r: Dictionary in [calm, busy]:
		print("    %s: отпечатков %d, эффектов %d, кадров %d, %d мс" % [r["name"],
			(r["digests"] as Array).size(), int(r["fx"]), int(r["frames"]), int(r["ms"])])
	var a: Array = calm["digests"]
	var b: Array = busy["digests"]
	_check(a.size() == STEPS / DIGEST_EVERY, "бой шёл весь отрезок: отпечатков %d" % a.size())
	_check(int(calm["events"]) > 0, "в бою были договоры и убитые (%d)" % int(calm["events"]))
	_check(int(busy["fx"]) > 0,
		"под нагрузкой тряска и вспышки прошли окно permit (%d)" % int(busy["fx"]))
	var first := -1
	for i in mini(a.size(), b.size()):
		if a[i] != b[i]:
			first = i
			break
	if first >= 0:
		print("    первое расхождение на шаге %d: %s / %s" % [(first + 1) * DIGEST_EVERY,
			String(a[first]).substr(0, 12), String(b[first]).substr(0, 12)])
	_check(first < 0 and a.size() == b.size(),
		"отпечатки мира совпали на всём отрезке (%d / %d)" % [a.size(), b.size()])


## Один бой на свежем встроенном мире. loaded — кадр медленнее по настенным часам, с тряской и
## вспышкой; у «Схватки» ещё и шаги мира пачками за кадр (догон сети).
func _battle(map_id: String, seed_value: int, duel: bool, loaded: bool) -> Dictionary:
	var w := load(WORLD_SCENE).instantiate() as LegionWorld
	w.embedded = true
	root.add_child(w)
	await process_frame
	w.dev = {"difficulty": "intern"}
	w.dev_invuln = false
	if duel:
		w.args["pvp_bots"] = true
	else:
		w.args["bot"] = "selective"
	w._base_seed = seed_value
	w.start_map(map_id)
	var catchup := duel and loaded
	if catchup:
		w.set_process(false)
	var t0 := Time.get_ticks_msec()
	var digests: Array[String] = []
	var last_now := w.now
	var n := 0
	var frames := 0
	var fx := 0
	var events := 0
	while w.phase == LegionWorld.Phase.BATTLE and n < STEPS and frames < STEPS * 4:
		frames += 1
		if loaded:
			OS.delay_msec(LOAD_MS[frames % LOAD_MS.size()])
			if frames % FX_EVERY == 0:
				fx += _fx(w)
		if catchup:
			var todo := 0 if w.is_ground_loading() else mini(CATCHUP[frames % CATCHUP.size()], STEPS - n)
			for k in todo:
				w._step(LegionWorld.NET_DT)
				n += 1
				events = maxi(events, _events(w))
				if n % DIGEST_EVERY == 0:
					digests.append(w.net_digest())
			await process_frame
			continue
		await process_frame
		if w.now == last_now:
			continue   # мир стоял (фон карты грузится) — шаг не засчитан
		last_now = w.now
		n += 1
		events = maxi(events, _events(w))
		if n % DIGEST_EVERY == 0:
			digests.append(w.net_digest())
	var out := {"name": "нагрузка" if loaded else "спокойно", "digests": digests, "fx": fx,
		"frames": frames, "events": events, "ms": Time.get_ticks_msec() - t0}
	w.queue_free()
	await process_frame
	Campaign.reset()
	return out


## Тряска и вспышка через обёртку, как в бою; 1 — если хоть одна прошла окно Juice.permit.
func _fx(w: LegionWorld) -> int:
	var vp := w.get_viewport()
	var before := int(vp.get_meta(&"visual_shake", -1)) + int(vp.get_meta(&"visual_flash", -1))
	Juice.shake(w, 6.0, 0.18)
	if Juice.screen_flash_allowed(w):
		Juice.flash(w, Color.WHITE, 0.15)
	var after := int(vp.get_meta(&"visual_shake", -1)) + int(vp.get_meta(&"visual_flash", -1))
	return 1 if after != before else 0


static func _events(w: LegionWorld) -> int:
	var made := 0
	for s in w.sides:
		made += s.contracts.contracts.size()
	return made + int(w.stats.get("kills", 0))
