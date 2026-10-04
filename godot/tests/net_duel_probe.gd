extends SceneTree
##
## Сквозная проба онлайн-«Схватки» (docs/pvp/NET_LOCKSTEP.md): ОДИН клиент — настоящий мир,
## настоящая NetSession, настоящий сокет к ретранслятору; за локальную сторону играет PvpBot, чьи
## команды уходят не в мир, а в сессию (PvpBot.sink = world.net_out) — ровно как ввод человека.
## Два таких процесса (host и guest) против одного ретранслятора должны пройти матч с одинаковыми
## отпечатками на каждом 60-м тике и одинаковым итогом. Гоняет tools/net_duel.sh.
##
##   godot --headless --path godot --fixed-fps 60 --script res://tests/net_duel_probe.gd -- --mute
##       --url ws://127.0.0.1:18799 --role host|guest [--map pvp:duel] [--limit 240]
## --limit — игровые секунды до остановки (оба клиента встают на одном тике); 0 — весь матч.
## Прямое соединение (tools/net_p2p_duel.sh): --direct 0|1 (галочка лобби, по умолчанию 0),
## --stun 0|1 (спрашивать STUN, по умолчанию 0 — пробы на одной машине без интернета),
## --udp-off (UDP глушится — запасной путь), --udp-loss N (терять N % входящих UDP),
## --forge K (с хода K один ход напрямую подменён — проба сверки путей),
## --freeze-ms N (раз в 6 с боя замереть на N мс — заминки медленной машины),
## --vhold K --vhold-ms N (с хода K копия своих ходов на сервер уходит на N мс позже — «лагающий»
## или придерживающий ходы клиент), --loopback (кандидат 127.0.0.1; без него — частные адреса).
## Итог — строка «NET_DUEL {json}» и код выхода 0 (дошёл до конца без рассинхрона) / 1.
##

const DT := 1.0 / 60.0
const TIMEOUT_MS := 30 * 60 * 1000

var w: LegionWorld
var session: NetSession
var bot: PvpBot
var role := "host"
var url := "ws://127.0.0.1:18799"
var map := "pvp:duel"
var limit_s := 240
## --corrupt N: на тике N этот клиент сам портит свой бой (Котёл −1) — проверка, что судья
## укажет именно на него (и подтянет его снимком, tools/net_heal.sh).
var corrupt_at := -1
## --corrupt-every N: портить ещё и каждые N тиков после первого (расходится снова и снова —
## подтяжки кончаются, HEAL_MAX ретранслятора).
var corrupt_every := 0
## --surrender-at N: на тике N сторона этого клиента сдаётся (командой, как человек) — матч
## кончается итогом, без ожидания всего боя.
var surrender_at := -1
var direct := false
var stun := false
var udp_off := false
var udp_loss := 0
var forge_at := -1
var hold_from := -1
var hold_ms := 0
var loopback := false
## --freeze-ms N: раз в 6 с боя процесс замирает на N мс (заминки медленной машины, verifier №3)
var freeze_ms := 0
## Пробы verifier №4: задержка/заминка приёма с сервера, гонка сброса придержанных копий.
var down_lat := 0
var down_stall_tick := -1
var down_stall_ms := 0
var race_ms := 0
var _freeze_at := 0
var verdict: Dictionary = {}
var _bot_tick := 0
var _born := 0
var _done := false
var _cmds_sent := 0
var _max_stall := 0.0
var _max_hold := 0.0
## Сколько раз мир показал итог (match_ended): экран итога должен быть один (B-377).
var _ends := 0
## --after-s N: сколько секунд ждать после итога (вердикт судьи, запоздавший снимок); было 1,5.
var after_s := 1.5


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	for i in args.size() - 1:
		match args[i]:
			"--role":
				role = args[i + 1]
			"--url":
				url = args[i + 1]
			"--map":
				map = args[i + 1]
			"--limit":
				limit_s = int(args[i + 1])
			"--corrupt":
				corrupt_at = int(args[i + 1])
			"--corrupt-every":
				corrupt_every = int(args[i + 1])
			"--surrender-at":
				surrender_at = int(args[i + 1])
			"--after-s":
				after_s = float(args[i + 1])
			"--direct":
				direct = args[i + 1] != "0"
			"--stun":
				stun = args[i + 1] != "0"
			"--udp-loss":
				udp_loss = int(args[i + 1])
			"--forge":
				forge_at = int(args[i + 1])
			"--vhold":
				hold_from = int(args[i + 1])
			"--vhold-ms":
				hold_ms = int(args[i + 1])
			"--freeze-ms":
				freeze_ms = int(args[i + 1])
			"--down-lat":
				down_lat = int(args[i + 1])
			"--down-stall-tick":
				down_stall_tick = int(args[i + 1])
			"--down-stall-ms":
				down_stall_ms = int(args[i + 1])
			"--race-ms":
				race_ms = int(args[i + 1])
	udp_off = "--udp-off" in args
	loopback = "--loopback" in args
	_born = Time.get_ticks_msec()
	_run.call_deferred()


func _run() -> void:
	Campaign.set_save_path("user://net_duel_%s.cfg" % role)
	Campaign.reset()
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	w = scene.instantiate() as LegionWorld
	root.add_child(w)
	w.match_ended.connect(func(_v: bool, _s: Dictionary) -> void: _ends += 1)
	await process_frame
	await process_frame
	session = NetSession.new()
	root.add_child(session)
	session.failed.connect(func(t: String) -> void: _finish("failed: " + t))
	session.aborted.connect(func(t: String) -> void: _finish("aborted: " + t))
	session.lobby.connect(_on_lobby)
	session.match_start.connect(_on_start)
	session.direct_enabled = direct
	session.use_stun = stun
	session.dbg_udp_off = udp_off
	session.dbg_udp_loss = udp_loss
	session.dbg_forge_at = forge_at
	session.dbg_hold_from = hold_from
	session.dbg_hold_ms = hold_ms
	session.dbg_loopback = loopback
	session.dbg_down_lat = down_lat
	session.dbg_down_stall_tick = down_stall_tick
	session.dbg_down_stall_ms = down_stall_ms
	session.dbg_race_ms = race_ms
	session.connect_lobby(url, "probe-" + role)


func _on_lobby(rooms: Array, _players: Array, _in_game: int) -> void:
	if session.stage != NetSession.Stage.LOBBY or session.side >= 0:
		return
	if role == "host":
		if session.room_code == "":
			session.room_code = "…"
			session.create_room(map)
		return
	for r: Variant in rooms:
		if r is Dictionary and String((r as Dictionary).get("host", "")) == "probe-host":
			session.join_room(String((r as Dictionary)["code"]))
			return


func _on_start(seed_value: int, map_id: String, side: int) -> void:
	w.start_net_match(map_id, seed_value, side)
	session.attach(w)
	if limit_s > 0:
		session.stop_at_tick = limit_s * 60
	bot = PvpBot.new()
	bot.setup(w, side)
	var out: Callable = w.net_out
	bot.sink = func(cmd: Dictionary) -> void:
		_cmds_sent += 1
		out.call(cmd)


func _process(_delta: float) -> bool:
	if _done:
		return false
	if Time.get_ticks_msec() - _born > TIMEOUT_MS:
		_finish("timeout")
		return false
	if session == null or session.stage != NetSession.Stage.PLAYING and \
			session.stage != NetSession.Stage.OVER:
		return false
	_max_stall = maxf(_max_stall, session._stall)
	_max_hold = maxf(_max_hold, session._hold_stall)
	if freeze_ms > 0 and session.stage == NetSession.Stage.PLAYING:
		if _freeze_at == 0:
			_freeze_at = Time.get_ticks_msec() + 6000
		elif Time.get_ticks_msec() >= _freeze_at:
			OS.delay_msec(freeze_ms)
			_freeze_at = Time.get_ticks_msec() + 6000
	# бот думает по тикам мира, которые прошли с прошлого кадра (мир шагает сессия)
	while _bot_tick < w.net_tick:
		_bot_tick += 1
		if _bot_tick == corrupt_at or (corrupt_at >= 0 and corrupt_every > 0
				and _bot_tick > corrupt_at and (_bot_tick - corrupt_at) % corrupt_every == 0):
			w.sides[0].cauldron_hp -= 1.0
		if w.phase == LegionWorld.Phase.BATTLE:
			if _bot_tick == surrender_at:
				w.net_out.call(PvpCmd.surrender())
			bot.tick(DT)
	var stopped := session.stop_at_tick >= 0 and w.net_tick >= session.stop_at_tick
	if stopped or w.phase != LegionWorld.Phase.BATTLE or session.stage == NetSession.Stage.OVER:
		_finish("ok")
	return false


func _finish(why: String) -> void:
	if _done:
		return
	_done = true
	var res := {"role": role, "why": why, "tick": w.net_tick if w != null else -1,
		"digest": w.net_digest() if w != null and session.side >= 0 else "",
		"side": session.side, "map": session.map_id, "seed": session.seed_value,
		"phase": int(w.phase) if w != null else -1, "desync": session._desync_tick,
		"cmds_sent": _cmds_sent, "max_stall_s": snappedf(_max_stall, 0.01),
		"max_hold_s": snappedf(_max_hold, 0.01), "aborted_text": session.last_error, "ws_close": session.last_close,
		"rtt_ms": session.rtt_ms, "verdict": session.verdict,
		"path": session.path_mode, "delay": session.delay, "link": session.link_text(),
		"mismatch": session.p2p_mismatch, "first_via": session.first_via,
		"forge_cheater": session.forge_cheater, "remote_left": session._remote_left,
		"p2p": session._p2p.stats if session._p2p != null else {},
		"p2p_state": NetP2P.State.keys()[session._p2p.state] if session._p2p != null else "none",
		"wall_s": (Time.get_ticks_msec() - _born) / 1000.0, "heals": _sv("heals"),
		"desync_first": _sv("_desync_first"), "ends": _ends,
		"result": NetMatchStats.end_result(w, session.side) if w != null else ""}
	if w != null and w.pvp and w.sides.size() == 2:
		res["hp"] = [w.sides[0].cauldron_hp, w.sides[1].cauldron_hp]
	print("NET_DUEL ", JSON.stringify(res))
	session.send_stats("stop")   # сводка матча в relay.log (бой остановлен пробой на тике)
	# отпечаток последнего тика уходит соперникам до закрытия — дать ретранслятору сверить пару
	await create_timer(after_s).timeout
	# после итога ещё могли прийти снимок судьи и его вердикт — экран итога обязан остаться одним
	print("NET_DUEL_AFTER ", JSON.stringify({"role": role, "ends": _ends, "heals": _sv("heals"),
		"verdict": session.verdict, "phase": int(w.phase) if w != null else -1}))
	var ok := why == "ok" and session._desync_tick < 0
	session.close()
	quit(0 if ok else 1)


## Поле сессии, которого в старой сборке нет (проба гоняется и на коде до подтяжки): -1.
func _sv(field: String) -> int:
	var v: Variant = session.get(field)
	return int(v) if v != null else -1
