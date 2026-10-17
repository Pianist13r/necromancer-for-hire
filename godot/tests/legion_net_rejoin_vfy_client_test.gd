extends SceneTree
##
## Пробы verifier 11.10 по переподключению — две NetSession и ядро через NetLinkPipe (оснастка
## legion_net_rejoin_det_test), перенесены как регресс (ветка slow/net-rejoin):
##  resync_cut — второй обрыв посреди досылки хвоста: два возврата, бой = эталону, ходов поровну;
##  busy5 — пять ответов «busy» подряд: возврат, ни одного «leave»;
##  void_race — соперник гостя повторяет «void» сразу после его возврата (таймер подогнан): матч не
##    прерван, доигран; void_nat (только --only=void_nat) — то же без подгонки.
##   "$GODOT" --headless --path godot --fixed-fps 60 \
##       --script res://tests/legion_net_rejoin_vfy_client_test.gd -- --mute [--only=имя]
## Итог «VFY REJOIN CLIENT: N/M OK», код выхода 1 при провале.
##

const SAVE := "user://zz_vfy_rejoin_client_test.cfg"
const MAP := "pvp:duel"
const TICKS := 1200
const SEED := 4242
const DELAY := 4
const FRAMES_MAX := 12000

var core: NetRelayCore
var _fails := 0
var _checks := 0
var _guest_end: NetLinkPipe
var _down_until := 0
var _cut_ms := 3000
var _fake_left := 0
var _fakes: Array = []
var _fake_log: Array = []


func _initialize() -> void:
	_run.call_deferred()


func _check(cond: bool, what: String) -> void:
	_checks += 1
	print(("  ok   " if cond else "  FAIL "), what)
	if not cond:
		_fails += 1


func _run() -> void:
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	var which: String = "all"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--only="):
			which = a.substr(7)
	var ref := await _match("ref", {})
	_check(ref["ticks"] == [TICKS, TICKS] and ref["digests"][0] == ref["digests"][1], "ref ok")
	if which in ["all", "resync_cut"]:
		var rc := await _match("resync_cut", {"hold_from": 60, "resync_cut": true})
		_same(ref, rc, "resync_cut")
		_check(rc["rejoins"] == 2 and rc["aborted"].is_empty() and not rc["remote_left"],
			"resync_cut: 2 returns, no abort/left: %s" % str(rc["aborted"]))
	if which in ["all", "busy5"]:
		var b := await _match("busy5", {"cut_at": 600, "busy": 5})
		_same(ref, b, "busy5")
		_check(b["rejoins"] == 1 and b["aborted"].is_empty() and not b["remote_left"],
			"busy5: returned after 5 busy, no abort: %s" % str(b["aborted"]))
		_check(not _fake_log.has("leave"), "busy5: no leave sent on any attempt: %s" % str(_fake_log))
	if which in ["all", "void_race"]:
		var v := await _match("void_race", {"hold_from": 60, "cut_ms": 48000, "grace": 85000, "force_void": true})
		print("  void_race result: ", v["summary"])
		_check(v["outage_elapsed"] and v["rejoins"] > 0 and v["forced"],
			"void_race: outage ended, guest actually rejoined, forced void window reached")
		_check(v["aborted"].is_empty(), "void_race: honest returning guest not voided: %s" % str(v["aborted"]))
		_check(v["ticks"] == [TICKS, TICKS], "void_race: match played to the end %s" % str(v["ticks"]))
	if which in ["void_nat"]:
		var v2 := await _match("void_nat", {"hold_from": 60, "cut_ms": 48000, "grace": 85000})
		print("  void_nat result: ", v2["summary"])
		_check(v2["outage_elapsed"] and v2["rejoins"] > 0 and v2["ticks"] == [TICKS, TICKS],
			"void_nat: guest rejoined and both worlds finished: %s" % str(v2["ticks"]))
		_check(v2["aborted"].is_empty(), "void_nat: not voided: %s" % str(v2["aborted"]))
	core = null
	print("VFY REJOIN CLIENT: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


func _same(ref: Dictionary, run: Dictionary, name: String) -> void:
	_check(run["ticks"] == [TICKS, TICKS], "%s: both worlds reached %d (%s)" % [name, TICKS, str(run["ticks"])])
	var diff := []
	for s in 2:
		for t: int in (ref["digests"][s] as Dictionary):
			if String((ref["digests"][s] as Dictionary)[t]) != String((run["digests"][s] as Dictionary).get(t, "")):
				diff.append([s, t])
	_check(diff.is_empty(), "%s: digests every 60 ticks == ref %s" % [name, str(diff.slice(0, 6))])
	_check(run["desync"] == [-1, -1], "%s: no desync" % name)
	_check(run["applied"] == ref["applied"] and int(run["applied"][0]) == int(run["applied"][1]),
		"%s: applied turns equal both sides and == ref %s / ref %s" % [name, str(run["applied"]), str(ref["applied"])])


func _noop_judge(_code: String) -> void:
	pass


func _core_send(link: NetLink, text: String) -> bool:
	if link.state() != NetLink.State.OPEN:
		return false
	var buffered := link.buffered_out()
	if buffered > 0 and buffered + text.length() > NetRelayCore.PEER_BUF:
		return false
	return link.send_text(text) == OK


func _guest_attempt() -> NetLink:
	if Time.get_ticks_msec() < _down_until:
		return null
	var pair := NetLinkPipe.pair()
	if _fake_left > 0:
		_fake_left -= 1
		_fakes.append(pair[1])
		_guest_end = pair[0]
		return pair[0]
	core.add_link(pair[1], false)
	_guest_end = pair[0]
	return _guest_end


func _service_fakes() -> void:
	for f: NetLinkPipe in _fakes:
		if f.state() != NetLink.State.OPEN:
			continue
		while f.available() > 0:
			var m: Variant = JSON.parse_string(f.take_text())
			if not (m is Dictionary):
				continue
			var t := String((m as Dictionary).get("t", ""))
			_fake_log.append(t)
			if t == "hello":
				f.send_text(JSON.stringify({"t": "welcome", "id": 99, "name": "x"}))
			elif t == "rejoin":
				f.send_text(JSON.stringify({"t": "rejoin_denied", "why": "busy"}))
				f.close(1000, "busy")


func _no_link() -> NetLink:
	return null


func _match(name: String, opt: Dictionary) -> Dictionary:
	print("-- run ", name)
	core = NetRelayCore.new()
	core.judge_max = 0
	core.dbg_spawn_judge = _noop_judge
	core.dbg_send = _core_send
	core._rng.seed = SEED
	if opt.has("grace"):
		core.rejoin_grace = int(opt["grace"])
	_down_until = 0
	_cut_ms = int(opt.get("cut_ms", 3000))
	_fake_left = int(opt.get("busy", 0))
	_fakes.clear()
	_fake_log.clear()
	var holder := Node.new()
	root.add_child(holder)
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	var worlds: Array[LegionWorld] = []
	var bots: Array[PvpBot] = []
	for i in 2:
		var w := scene.instantiate() as LegionWorld
		holder.add_child(w)
		worlds.append(w)
		bots.append(PvpBot.new())
	await process_frame
	var sessions: Array[NetSession] = [NetSession.new(), NetSession.new()]
	var aborted: Array = []
	for i in 2:
		var s := sessions[i]
		holder.add_child(s)
		s.dbg_fixed_delay = DELAY
		s.aborted.connect(func(t: String) -> void: aborted.append("%d: %s" % [i, t]))
		s.failed.connect(func(t: String) -> void: aborted.append("%d failed: %s" % [i, t]))
		s.rejoin_link = _no_link if i == 0 else _guest_attempt
		var pair := NetLinkPipe.pair()
		core.add_link(pair[1], false)
		if i == 1:
			_guest_end = pair[0]
		s.connect_link(pair[0], "det%d" % i)
	var started := [false, false]
	for i in 2:
		var s := sessions[i]
		var w := worlds[i]
		var bot := bots[i]
		s.match_start.connect(func(seed_value: int, map_id: String, side: int) -> void:
			w.start_net_match(map_id, seed_value, side)
			s.attach(w)
			s.stop_at_tick = 0
			bot.setup(w, side)
			var out: Callable = w.net_out
			bot.sink = func(cmd: Dictionary) -> void: out.call(cmd)
			started[i] = true)
	sessions[0].room_created.connect(func(code: String) -> void: sessions[1].join_room(code))
	for f in 20:
		await process_frame
		core.process()
		if sessions[0].stage == NetSession.Stage.LOBBY and sessions[1].stage == NetSession.Stage.LOBBY:
			break
	sessions[0].create_room(MAP)
	var digests := [{}, {}]
	var bot_ticks := [0, 0]
	var cut := false
	var cut2 := false
	var forced := false
	var forwarded := 0
	var events: Array = []
	if opt.has("hold_from"):
		sessions[1].dbg_hold_from = int(opt["hold_from"])
		sessions[1].dbg_hold_ms = 600000
	var t0 := -1
	var frames := 0
	var cut_timeout_ms := 0
	var stuck_frames := 0
	var last_stage := -1
	while frames < FRAMES_MAX or (cut and _cut_ms >= 48000
			and Time.get_ticks_msec() < cut_timeout_ms):
		frames += 1
		await process_frame
		_service_fakes()
		core.process()
		if not (started[0] and started[1]):
			continue
		if t0 < 0:
			t0 = Time.get_ticks_msec()
		var ahead := int(float(worlds[0].net_tick) * 1000.0 / 60.0) - (Time.get_ticks_msec() - t0)
		if ahead > 0:
			OS.delay_msec(mini(ahead, 50))
		for i in 2:
			var w := worlds[i]
			var s := sessions[i]
			while bot_ticks[i] < w.net_tick:
				bot_ticks[i] += 1
				if w.phase == LegionWorld.Phase.BATTLE:
					bots[i].tick(NetSession.DT)
			if w.net_tick % 60 == 0 and w.net_tick > 0 and not (digests[i] as Dictionary).has(w.net_tick):
				digests[i][w.net_tick] = w.net_digest()
			s.stop_at_tick = mini(w.net_tick + 1, TICKS)
		var host := sessions[0]
		var guest := sessions[1]
		if guest.stage != last_stage:
			events.append("f%d guest stage %s (host hold %.1f, next_out %d)" % [frames,
				NetSession.Stage.keys()[guest.stage], host._hold_stall, guest._next_out])
			last_stage = guest.stage
		if opt.has("hold_from") and not cut:
			while forwarded < guest._hold_q.size():
				var raw := String(guest._hold_q[forwarded][1])
				host._on_remote_turn(JSON.parse_string(raw) as Dictionary, raw, "udp")
				forwarded += 1
		var cut_now := false
		if opt.has("cut_at") and not cut and worlds[1].net_tick >= int(opt["cut_at"]):
			cut_now = true
		if opt.has("hold_from") and not cut and host._hold_stall > 1.0:
			cut_now = true
			guest.dbg_hold_from = -1
		if cut_now:
			cut = true
			_down_until = Time.get_ticks_msec() + _cut_ms
			cut_timeout_ms = _down_until + 30000
			events.append("f%d CUT (host hold %.1f, guest next_out %d)" % [frames, host._hold_stall, guest._next_out])
			_guest_end.close(1006, "cut")
		# second cut in the middle of RESYNC (after first batch of 40 went out)
		if opt.has("resync_cut") and cut and not cut2 and guest.stage == NetSession.Stage.RESYNC \
				and guest._rejoin.resend_k >= 100:
			cut2 = true
			_down_until = Time.get_ticks_msec() + 500
			events.append("f%d CUT2 in RESYNC resend_k %d next_out %d" % [frames, guest._rejoin.resend_k, guest._next_out])
			_guest_end.close(1006, "cut2")
		# simulate host void retry timer expiring right after the core rebound the guest
		if opt.has("force_void") and not forced and core._rooms.size() > 0:
			var room: Dictionary = core._rooms.values()[0]
			if int((room["rejoins"] as Array)[1]) > 0:
				forced = true
				events.append("f%d guest rebound on core (next_k %s); host hold %.1f req_wait %.2f -> host void timer due" % [
					frames, str(room["next_k"]), host._hold_stall, host._req_wait])
				host._void_next_ms = 0
		if guest.stage == NetSession.Stage.PLAYING and host.stage != NetSession.Stage.PLAYING:
			stuck_frames += 1
		var done := worlds[0].net_tick >= TICKS and worlds[1].net_tick >= TICKS
		if done or stuck_frames > 600:
			break
	var res := {"ticks": [worlds[0].net_tick, worlds[1].net_tick], "digests": digests,
		"rejoins": sessions[1]._rejoin.count, "forced": forced,
		"outage_elapsed": Time.get_ticks_msec() >= _down_until,
		"remote_left": sessions[0]._remote_left,
		"aborted": aborted, "desync": [sessions[0]._desync_tick, sessions[1]._desync_tick],
		"applied": [sessions[0]._applied_turn + 1, sessions[1]._applied_turn + 1]}
	res["summary"] = {"ticks": res["ticks"], "rejoins": res["rejoins"], "aborted": aborted,
		"host_stage": NetSession.Stage.keys()[sessions[0].stage],
		"guest_stage": NetSession.Stage.keys()[sessions[1].stage], "frames": frames,
		"guest_label": sessions[1]._label.text, "rooms_left": core._rooms.size()}
	print("  run %s: %s" % [name, str(res["summary"])])
	for e: String in events:
		print("    ", e)
	for s: NetSession in sessions:
		s.close()
	if _guest_end != null:
		_guest_end.close(1000, "end")
	core.process()
	holder.queue_free()
	await process_frame
	await process_frame
	return res
