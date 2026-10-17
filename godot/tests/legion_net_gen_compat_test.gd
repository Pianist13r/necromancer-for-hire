extends SceneTree
## B-532: generated PvP cannot start across v3/v4 clients, relay or judge. Uses real
## NetSession packet handlers and NetRelayCore admission with in-process links; no server process.

var _ok := 0
var _all := 0
var _starts := 0
var _failures: Array[String] = []
var _links: Array[NetLink] = []


func _initialize() -> void:
	_run.call_deferred()


func _check(cond: bool, label: String) -> void:
	_all += 1
	if cond:
		_ok += 1
	else:
		print("FAIL: ", label)


func _pair(core: NetRelayCore, version: Variant, build := NetSession.BUILD,
		judge_only := false, omit := false, can_rejoin := false) -> Dictionary:
	var ends := NetLinkPipe.pair()
	_links.append(ends[0])
	_links.append(ends[1])
	var id := core.add_link(ends[0], judge_only)
	if not judge_only:
		var hello := {"t": "hello", "v": NetSession.PROTO, "build": build, "name": "P%d" % id}
		if not omit:
			hello["gen_version"] = version
		if can_rejoin:
			hello["caps"] = ["rejoin"]
		core._hello(id, hello)
	return {"id": id, "link": ends[1]}


func _take(link: NetLinkPipe, kind: String) -> Dictionary:
	while link.available() > 0:
		var parsed: Variant = JSON.parse_string(link.take_text())
		if parsed is Dictionary and String((parsed as Dictionary).get("t", "")) == kind:
			return parsed as Dictionary
	return {}


func _run() -> void:
	_check(ProcGen.VERSION == 4 and NetSession.BUILD != "net-2026-10-13-b494",
		"v4 has a distinct network BUILD")
	_check(NetSession._wire_gen_version(4) == 4 and NetSession._wire_gen_version(4.0) == 4,
		"client accepts only integral JSON numeric version")
	for bad: Variant in [null, 3, true, 4.5, "4", {}, []]:
		_check(NetSession._wire_gen_version(bad) != 4,
			"client rejects malformed or incompatible version %s" % str(bad))
	_client_packets()
	_client_reconnect_welcome()
	_server_packets()
	for link: NetLink in _links:
		link.close(1000, "test done")
	await process_frame
	await process_frame
	print("net_gen_compat_test: %d/%d OK" % [_ok, _all])
	quit(0 if _ok == _all else 1)


func _client_packets() -> void:
	var s := NetSession.new()
	root.add_child(s)
	s.set_process(false)
	var hello := s._hello("Тест", true)
	_check(hello.get("gen_version") == 4 and "rejoin" in hello.get("caps", []),
		"initial and reconnect hello retain generator version and rejoin capability")
	var fixed_hello := s._hello("Тест", false)
	_check(fixed_hello.get("gen_version") == 4 and not fixed_hello.has("caps"),
		"non-reconnecting link still advertises generator version")
	s.match_start.connect(func(_seed: int, _map: String, _side: int) -> void: _starts += 1)
	s.failed.connect(func(message: String) -> void: _failures.append(message))
	var start := {"t": "start", "map": "gen:7:3:pvp", "seed": 17, "side": 0,
		"gen_version": 4}
	var before := _starts
	s._handle({"t": "welcome", "name": "Тест"})
	s.create_room("gen:")
	_check(_failures.size() == 1 and s.room_code == "", "old relay blocks gen creation")
	s._handle(start)
	_check(_starts == before and s.stage == NetSession.Stage.LOBBY and s.verdict.is_empty(),
		"old relay gen start cannot emit match_start or outcome")
	for bad: Variant in [3, true, 4.5, "4", {}, []]:
		s._handle({"t": "welcome", "name": "Тест", "gen_version": bad})
		before = _starts
		s._handle(start)
		_check(_starts == before and s.stage == NetSession.Stage.LOBBY,
			"bad welcome %s cannot start gen world" % str(bad))
	s._handle({"t": "welcome", "name": "Тест", "gen_version": 4})
	for bad: Variant in [null, 3, true, 4.5, "4", {}, []]:
		var packet := start.duplicate()
		if bad == null:
			packet.erase("gen_version")
		else:
			packet["gen_version"] = bad
		before = _starts
		s._handle(packet)
		_check(_starts == before and s.verdict.is_empty(),
			"bad start %s cannot emit match_start" % str(bad))
	s._handle(start)
	_check(_starts == before + 1 and s.map_id == "gen:7:3:pvp", "v4/v4 gen start accepted")
	var fails_before := _failures.size()
	s._handle({"t": "error", "code": "build", "why": "gen_version"})
	_check(_failures.size() == fails_before + 1 and _failures.back().find("Дуэль") >= 0,
		"new client explains relay gen refusal without disconnect")
	s._handle({"t": "welcome", "name": "Тест"})
	before = _starts
	s._handle({"t": "start", "map": "pvp:duel", "seed": 17, "side": 0})
	_check(_starts == before + 1, "fixed duel remains compatible with old relay")
	_check(not _failures.is_empty() and _failures[0].find("Дуэль") >= 0,
		"rejection explains ordinary field alternative")
	s.close()
	s.queue_free()


func _client_reconnect_welcome() -> void:
	for bad: Variant in [null, 3, true, 4.5, "4", {}, []]:
		var s := NetSession.new()
		root.add_child(s)
		s.set_process(false)
		s.map_id = "gen:7:3:pvp"
		s.room_code = "ABCD"
		s.side = 0
		s._rejoin.reset_match("a".repeat(32), "ABCD", 0)
		s._rejoin.begin(Time.get_ticks_msec())
		var ends := NetLinkPipe.pair()
		_links.append_array(ends)
		s._chan = ends[0]
		s.stage = NetSession.Stage.RECONNECTING
		var aborted: Array[String] = []
		s.aborted.connect(func(message: String) -> void: aborted.append(message))
		var welcome := {"t": "welcome"}
		if bad != null:
			welcome["gen_version"] = bad
		s._on_reconnect_msg(welcome)
		_check(aborted.size() == 1 and aborted[0].find("Дуэль") >= 0
			and s.stage != NetSession.Stage.RECONNECTING
			and _take(ends[1], "rejoin").is_empty(),
			"bad reconnect welcome %s aborts before rejoin" % str(bad))
		s.close()
		s.queue_free()
	var s := NetSession.new()
	root.add_child(s)
	s.set_process(false)
	s.map_id = "gen:7:3:pvp"
	s._rejoin.reset_match("a".repeat(32), "ABCD", 0)
	s._rejoin.begin(Time.get_ticks_msec())
	var ends := NetLinkPipe.pair()
	_links.append_array(ends)
	s._chan = ends[0]
	s.stage = NetSession.Stage.RECONNECTING
	s._on_reconnect_msg({"t": "welcome", "gen_version": 4})
	var packet := _take(ends[1], "rejoin")
	_check(packet.get("code") == "ABCD" and packet.get("rj") == "a".repeat(32)
		and s.stage == NetSession.Stage.RECONNECTING,
		"v4 reconnect welcome sends authenticated rejoin")
	s.close()
	s.queue_free()


func _server_packets() -> void:
	var core := NetRelayCore.new()
	core.judge_max = 0
	for bad: Variant in [null, 3, true, 4.5, "4", {}, []]:
		var peer := _pair(core, bad, NetSession.BUILD, false, bad == null)
		var id := int(peer["id"])
		var link := peer["link"] as NetLinkPipe
		_check(_take(link, "welcome").get("gen_version") == 4,
			"new relay advertises v4 to all clients")
		core._create_room(id, "gen:")
		var refusal := _take(link, "error")
		_check(refusal.get("code") == "build" and refusal.get("why") == "gen_version"
			and String(core._peers[id]["room"]) == "",
			"relay softly rejects gen creator %s" % str(bad))
	var host := _pair(core, 4, NetSession.BUILD, false, false, true)
	var hid := int(host["id"])
	var hlink := host["link"] as NetLinkPipe
	_take(hlink, "welcome")
	core._create_room(hid, "gen:")
	var code := String(_take(hlink, "room").get("code", ""))
	_check(code != "", "v4 host creates generated room")
	for bad: Variant in [null, 3, true, 4.5, "4", {}, []]:
		var peer := _pair(core, bad, NetSession.BUILD, false, bad == null)
		var id := int(peer["id"])
		var link := peer["link"] as NetLinkPipe
		_take(link, "welcome")
		core._join_room(id, code)
		var refusal := _take(link, "error")
		_check(refusal.get("code") == "build" and refusal.get("why") == "gen_version"
			and not bool(core._rooms[code]["started"]),
			"relay softly rejects gen joiner %s before room start" % str(bad))
	var old_build := _pair(core, 4, "net-2026-10-13-b494")
	var old_link := old_build["link"] as NetLinkPipe
	_take(old_link, "welcome")
	core._join_room(int(old_build["id"]), code)
	_check(_take(old_link, "error").get("code") == "build", "old BUILD cannot join v4")
	var guest := _pair(core, 4.0, NetSession.BUILD, false, false, true)
	var glink := guest["link"] as NetLinkPipe
	_take(glink, "welcome")
	core._join_room(int(guest["id"]), code)
	var hs := _take(hlink, "start")
	var gs := _take(glink, "start")
	_check(hs.get("gen_version") == 4 and gs.get("gen_version") == 4
		and String(hs.get("map", "")).begins_with("gen:"), "v4 pair gets versioned start")
	var room: Dictionary = core._rooms[code]
	_check(bool(room["rejoin"]) and String(hs.get("rj", "")) != ""
		and String(gs.get("rj", "")) != "" and hs["rj"] != gs["rj"],
		"versioned generated start retains distinct private rejoin tokens")
	room["key"] = "test-secret"
	core.judge_max = 1
	var bad_versions: Array = [null, 3, true, 4.5, "4", {}, []]
	for i in bad_versions.size():
		var bad: Variant = bad_versions[i]
		# Каждый отказ начинает с чистого ожидания судьи; предыдущее judge_dead не помогает.
		room["judge_dead"] = false
		var judge := _pair(core, null, NetSession.BUILD, true)
		var jmsg := {"t": "judge", "v": NetSession.PROTO, "room": code,
			"key": "test-secret"}
		if bad != null:
			jmsg["gen_version"] = bad
		core._judge_hello(int(judge["id"]), jmsg)
		_check(int(room["judge"]) == 0 and not bool(core._peers[int(judge["id"])]["hello"])
			and core._peers[int(judge["id"])].has("kick_at")
			and bool(room.get("judge_dead", false)),
			"relay refuses gen judge %s before attachment" % str(bad))
		var attack := {"t": "hash", "k": 60 + i, "h": "stale"}
		if i % 2 != 0:
			attack = {"t": "verdict", "why": "fake", "winner": 0}
		core._handle(int(judge["id"]), attack, JSON.stringify(attack))
		_check(not core._peers.has(int(judge["id"])) and (room["hashes"] as Dictionary).is_empty()
			and _take(hlink, "verdict").is_empty() and _take(glink, "verdict").is_empty(),
			"rejected judge %s cannot send hash or verdict" % str(bad))
		var pair_hash := {"k": 60 + i, "h": "same"}
		core._hash(hid, pair_hash)
		core._hash(int(guest["id"]), pair_hash)
		_check(bool(room["started"]) and (room["hashes"] as Dictionary).is_empty()
			and int(room["judge"]) == 0, "compatible pair keeps pair-only hash path")
	room["judge_dead"] = false
	var judge_good := _pair(core, null, NetSession.BUILD, true)
	var jlink := judge_good["link"] as NetLinkPipe
	core._judge_hello(int(judge_good["id"]), {"t": "judge", "v": NetSession.PROTO,
		"room": code, "key": "test-secret", "gen_version": 4})
	_check(int(room["judge"]) == int(judge_good["id"])
		and _take(jlink, "start").get("gen_version") == 4, "v4 judge admitted with versioned start")
	core.judge_max = 0
	var fixed_host := _pair(core, null, NetSession.BUILD, false, true)
	var flink := fixed_host["link"] as NetLinkPipe
	_take(flink, "welcome")
	core._create_room(int(fixed_host["id"]), "pvp:duel")
	var fixed_code := String(_take(flink, "room").get("code", ""))
	var fixed_guest := _pair(core, null, NetSession.BUILD, false, true)
	var fguest := fixed_guest["link"] as NetLinkPipe
	_take(fguest, "welcome")
	core._join_room(int(fixed_guest["id"]), fixed_code)
	_check(_take(flink, "start").get("map") == "pvp:duel"
		and _take(fguest, "start").get("map") == "pvp:duel",
		"legacy clients can still play fixed duel on new relay")
	room["go_ms"] = Time.get_ticks_msec()
	(room["bind_at"] as Array)[0] = Time.get_ticks_msec() - NetRelayCore.REJOIN_GAP_MS - 1
	var owner_before := int((room["peers"] as Array)[0])
	var gen_before := int((room["gen"] as Array)[0])
	var bind_before := int((room["bind_at"] as Array)[0])
	var budget_before := int((room["away_total"] as Array)[0])
	var rejoins_before := int((room["rejoins"] as Array)[0])
	for bad: Variant in [null, 3, true, 4.5, "4", {}, []]:
		var peer := _pair(core, bad, NetSession.BUILD, false, bad == null, true)
		var id := int(peer["id"])
		var link := peer["link"] as NetLinkPipe
		_take(link, "welcome")
		var packet := {"t": "rejoin", "code": code, "side": 0,
			"rj": hs["rj"], "have": -1, "rid": "compat"}
		core._handle(id, packet, JSON.stringify(packet))
		_check(_take(link, "rejoin_denied").get("why") == "gen_version"
			and int((room["peers"] as Array)[0]) == owner_before
			and int((room["gen"] as Array)[0]) == gen_before
			and int((room["bind_at"] as Array)[0]) == bind_before
			and int((room["away_total"] as Array)[0]) == budget_before
			and int((room["rejoins"] as Array)[0]) == rejoins_before,
			"bad gen rejoin %s leaves owner and budgets untouched" % str(bad))
	var returning := _pair(core, 4, NetSession.BUILD, false, false, true)
	var returning_link := returning["link"] as NetLinkPipe
	_take(returning_link, "welcome")
	var rejoin := {"t": "rejoin", "code": code, "side": 0,
		"rj": hs["rj"], "have": -1, "rid": "compat-v4"}
	core._handle(int(returning["id"]), rejoin, JSON.stringify(rejoin))
	_check(not _take(returning_link, "rejoined").is_empty()
		and int((room["peers"] as Array)[0]) == int(returning["id"])
		and int((room["gen"] as Array)[0]) == gen_before + 1,
		"v4 gen rejoin replaces owner after version guard")
	core.shutdown("test done")
