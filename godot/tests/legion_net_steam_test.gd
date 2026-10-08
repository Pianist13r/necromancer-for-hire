extends SceneTree
##
## Онлайн-«Схватка» через Steam без клиента Steam (ветка slow/steam-net, docs/dev/ONLINE.md):
## заглушка синглтона GodotSteam (tests/steam_fake.gd) вместо настоящего — два «клиента» в одном
## процессе, общее «облако» лобби, соединения P2P парами дескрипторов.
##
##   export APPDATA=<песочница> NECRO_NO_DEV_BRIDGE=1
##   "$GODOT" --headless --path godot --fixed-fps 60 --script res://tests/legion_net_steam_test.gd -- --mute
##
## 1) NetLinkPipe: порядок и размеры, закрытие с кодом и причиной доходит до второго конца,
##    непарный конец — CONNECTING, отправка не проходит;
## 2) NetLinkSteam: контрольная сумма (FNV-1a), кадр «hex8:текст», испорченный байт закрывает
##    канал кодом 1007 у получателя и доносит причину отправителю; сообщения в обе стороны;
## 3) SteamNet без Steam: boot() → null вне Steam-сборки; клиент «не запущен» → ok = false;
## 4) сквозной матч: хозяин (ядро ретранслятора в процессе + NetLinkPipe) и гость (NetLinkSteam)
##    — лобби Steam с данными сборки, список игр гостя, вход, «start» у обоих с одним сидом,
##    настоящие миры с PvpBot по 10 с боя: отпечатки сходятся, рассинхрона нет, UDP нет, путь
##    «через Steam»; выход гостя → хозяин снова открывает комнату (лобби open=1), реванш через
##    комнату ретранслятора; уход обоих освобождает лобби, сокеты и дескрипторы.
## Итог «LEGION NET STEAM: N/M OK», код выхода 1 при провале.
##

const SteamFake := preload("res://tests/steam_fake.gd")
const SAVE := "user://legion_net_steam_test.cfg"
const MAP := "pvp:duel"
const BATTLE_TICKS := 600
const ID_A := 76561198000000001
const ID_B := 76561198000000002

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
	_pipe_checks()
	_steam_link_checks()
	await _boot_checks()
	await _match_checks()
	await _lifecycle_checks()
	print("LEGION NET STEAM: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


func _frames(n: int) -> void:
	for i in n:
		await process_frame


# ── 1. NetLinkPipe ──────────────────────────────────────────────────────────

func _pipe_checks() -> void:
	var ends := NetLinkPipe.pair()
	var a: NetLinkPipe = ends[0]
	var b: NetLinkPipe = ends[1]
	_check(a.state() == NetLink.State.OPEN and b.state() == NetLink.State.OPEN
		and a.kind() == "pipe" and not a.direct_allowed(), "пара открыта, прямого UDP-пути нет")
	_check(a.send_text("раз") == OK and a.send_text("два") == OK and b.available() == 2,
		"два сообщения ждут на другом конце")
	var first := b.take_text()
	_check(first == "раз" and b.last_size() == "раз".to_utf8_buffer().size()
		and b.take_text() == "два" and b.available() == 0, "порядок и размер в байтах")
	b.send_text("ответ")
	a.close(1001, "ушёл")
	_check(a.state() == NetLink.State.CLOSED and b.state() == NetLink.State.CLOSED
		and b.close_code() == 1001 and b.close_reason() == "ушёл",
		"закрытие доходит до второго конца с кодом и причиной")
	_check(a.available() == 1 and a.take_text() == "ответ", "принятое до закрытия читается")
	_check(b.send_text("x") == ERR_UNAVAILABLE, "в закрытый канал не отправить")
	var lone := NetLinkPipe.new()
	_check(lone.state() == NetLink.State.CONNECTING and lone.send_text("x") == ERR_UNAVAILABLE,
		"непарный конец — CONNECTING, отправка не проходит")


# ── 2. NetLinkSteam ─────────────────────────────────────────────────────────

func _steam_link_checks() -> void:
	_check(NetLinkSteam.checksum("") == "811c9dc5" and NetLinkSteam.checksum("a") == "e40c292c",
		"FNV-1a 32: эталонные значения")
	SteamFake.reset_cloud()
	var fa: RefCounted = SteamFake.new(ID_A, "A")
	var fb: RefCounted = SteamFake.new(ID_B, "B")
	var api_a := SteamApi.new(fa)
	var api_b := SteamApi.new(fb)
	var events: Array = []
	api_a.on(&"network_connection_status_changed", func(h: int, c: Dictionary, _o: int) -> void:
		events.append(["a", h, c]))
	api_b.on(&"network_connection_status_changed", func(h: int, c: Dictionary, _o: int) -> void:
		events.append(["b", h, c]))
	_check(not api_a.on(&"no_such_signal", func() -> void: pass), "чужой сигнал — false, без ошибки")
	var ls := api_a.listen_p2p(0)
	var hb := api_b.connect_p2p(ID_A, 0)
	_pump([fa, fb])
	_check(events.size() == 1 and events[0][0] == "a"
		and int(events[0][2]["connection_state"]) == SteamApi.STATE_CONNECTING
		and int(events[0][2]["listen_socket"]) == ls, "хозяину — входящее CONNECTING на его сокете")
	var ha := int(events[0][1])
	_check(api_a.accept(ha) == SteamApi.RESULT_OK, "принято")
	events.clear()
	_pump([fa, fb])
	_check(events.size() == 2 and int(events[0][2]["connection_state"]) == SteamApi.STATE_CONNECTED
		and int(events[1][2]["connection_state"]) == SteamApi.STATE_CONNECTED, "CONNECTED у обоих")
	var la := NetLinkSteam.new(api_a, ha, true)
	var lb := NetLinkSteam.new(api_b, hb)
	_check(lb.state() == NetLink.State.CONNECTING, "гость ждёт CONNECTED")
	lb.set_open()
	_check(la.send_text("привет, гость") == OK and lb.send_text("привет, хозяин") == OK, "отправка")
	la.poll()
	lb.poll()
	_check(la.take_text() == "привет, хозяин" and lb.take_text() == "привет, гость"
		and la.last_size() == "привет, хозяин".to_utf8_buffer().size(), "текст и размер дошли")
	_check(la.kind() == "steam" and not la.direct_allowed() and la.connect_timeout() > 10.0,
		"канал Steam: без UDP, ждёт соединения дольше WebSocket")
	# порча: байт следующего входящего у A меняется — A закрывает канал, B узнаёт причину
	fa.corrupt_next = true
	lb.send_text("испорчено")
	la.poll()
	_check(la.violation() != "" and la.state() == NetLink.State.CLOSED
		and la.close_code() == NetLinkSteam.CLOSE_CORRUPT, "повреждённое сообщение закрывает канал")
	events.clear()
	_pump([fa, fb])
	_check(events.size() == 1 and events[0][0] == "b"
		and int(events[0][2]["connection_state"]) == SteamApi.STATE_CLOSED_BY_PEER
		and int(events[0][2]["end_reason"]) == SteamApi.END_APP_MIN + 7
		and String(events[0][2]["end_debug"]) == "повреждено", "второй стороне — CLOSED_BY_PEER")
	lb.set_closed(int(events[0][2]["end_reason"]), String(events[0][2]["end_debug"]))
	_check(lb.state() == NetLink.State.CLOSED and lb.close_code() == 1007
		and lb.close_reason() == "повреждено", "код и причина восстановлены из причины Steam")
	api_b.close_connection(hb, 0, "", false)
	_check(fa.open_connections() == 0 and fb.open_connections() == 0, "дескрипторы освобождены")
	api_a.close_listen(ls)


func _pump(fakes: Array) -> void:
	for f: RefCounted in fakes:
		f.run_callbacks()


# ── 3. Без Steam ────────────────────────────────────────────────────────────

func _boot_checks() -> void:
	var holder := Node.new()
	root.add_child(holder)
	if OS.get_environment(SteamNet.ENV_FORCE) == "1":
		print("  skip NECRO_STEAM=1 в окружении — проверку «вне Steam-сборки» пропускаем")
	else:
		_check(SteamNet.boot(holder, null) == null and SteamNet.find(holder) == null,
			"вне Steam-сборки SteamNet не поднимается")
	var dead: RefCounted = SteamFake.new(ID_A, "X")
	dead.running = false
	var sn := SteamNet.boot(holder, dead)
	_check(sn != null and not sn.active() and sn.why_not.begins_with("Steam не запущен")
		and SteamNet.find(holder) == sn, "клиент не запущен — узел есть, но не активен")
	var main_like := LegionMain.new()
	_check(not PvpFlow.steam_active(main_like), "без узла «По сети» ведёт в прежнее лобби")
	main_like.free()
	holder.queue_free()
	await process_frame


# ── 4. Сквозной матч ────────────────────────────────────────────────────────

func _match_checks() -> void:
	SteamFake.reset_cloud()
	var fa: RefCounted = SteamFake.new(ID_A, "Хозяин")
	var fb: RefCounted = SteamFake.new(ID_B, "Гость")
	var ha := Node.new()
	var hb := Node.new()
	root.add_child(ha)
	root.add_child(hb)
	var sa := SteamNet.boot(ha, fa)
	var sb := SteamNet.boot(hb, fb)
	_check(sa.active() and sb.active() and sa.my_name == "Хозяин" and sb.my_id == ID_B,
		"оба клиента Steam подняты")
	var sess_a := NetSession.new()
	var sess_b := NetSession.new()
	ha.add_child(sess_a)
	hb.add_child(sess_b)
	var errors: Array = []
	for pair: Array in [[sa, "sa"], [sb, "sb"], [sess_a, "sess_a"], [sess_b, "sess_b"]]:
		var who: String = pair[1]
		(pair[0] as Object).connect(&"failed", func(t: String) -> void: errors.append(who + ": " + t))
	sess_a.aborted.connect(func(t: String) -> void: errors.append("sess_a aborted: " + t))
	sess_b.aborted.connect(func(t: String) -> void: errors.append("sess_b aborted: " + t))
	# хозяин
	sa.host(sess_a, MAP, sa.my_name)
	await _frames(12)
	var lobby := sa.lobby_id
	_check(lobby != 0 and sa.mode == "host" and sess_a.stage == NetSession.Stage.LOBBY
		and sess_a.room_code != "" and sess_a.side == 0, "хозяин: лобби Steam, комната у себя")
	var data: Dictionary = SteamFake.lobbies[lobby]["data"] if SteamFake.lobbies.has(lobby) else {}
	_check(String(data.get("game", "")) == SteamNet.GAME_KEY
		and String(data.get("build", "")) == NetSession.BUILD
		and String(data.get("room", "")) == sess_a.room_code and String(data.get("open", "")) == "1"
		and String(data.get("name", "")) == "Хозяин" and String(data.get("map", "")) == MAP,
		"данные лобби: сборка, комната, карта, имя, open")
	_check(String(fa.rich.get("connect", "")) == "%s %d" % [SteamNet.CONNECT_PREFIX, lobby],
		"Rich Presence connect — для «Присоединиться» у друзей")
	# гость видит игру (лямбда меняет массив на месте: присваивание в замыкании не видно снаружи)
	var rows: Array = []
	sb.lobbies.connect(func(r: Array) -> void: rows.assign(r))
	sb.refresh()
	await _frames(3)
	_check(rows.size() == 1 and int(rows[0]["id"]) == lobby and String(rows[0]["name"]) == "Хозяин"
		and String(rows[0]["map"]) == MAP, "гость: игра хозяина в списке: %s" % str(rows))
	# миры — заранее; на «start» мир стартует и сессия подключается сразу, как у PvpFlow (иначе
	# «ready» соперника, пришедший до attach(), пропадает — attach сбрасывает _ready_remote)
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	var worlds: Array[LegionWorld] = []
	var bots: Array[PvpBot] = []
	var sessions: Array[NetSession] = [sess_a, sess_b]
	for i in 2:
		var w := scene.instantiate() as LegionWorld
		root.add_child(w)
		worlds.append(w)
		bots.append(PvpBot.new())
	await _frames(2)
	# вход
	var starts: Dictionary = {}
	for i in 2:
		var w: LegionWorld = worlds[i]
		var s: NetSession = sessions[i]
		var bot: PvpBot = bots[i]
		var key := "a" if i == 0 else "b"
		s.match_start.connect(func(seed_value: int, map_id: String, side: int) -> void:
			starts[key] = [seed_value, map_id, side]
			w.start_net_match(map_id, seed_value, side)
			s.attach(w)
			s.stop_at_tick = BATTLE_TICKS
			bot.setup(w, side)
			var out: Callable = w.net_out
			bot.sink = func(cmd: Dictionary) -> void: out.call(cmd))
	sb.join(sess_b, lobby, sb.my_name)
	await _frames(30)
	_check(sb.mode == "guest" and sb.lobby_id == lobby and errors.is_empty(), "гость вошёл")
	_check(starts.has("a") and starts.has("b") and starts["a"][0] == starts["b"][0]
		and starts["a"][1] == MAP and starts["b"][1] == MAP
		and starts["a"][2] == 0 and starts["b"][2] == 1, "start у обоих: один сид, стороны 0/1")
	_check(String(SteamFake.lobbies[lobby]["data"].get("open", "")) == "0"
		and not bool(SteamFake.lobbies[lobby]["joinable"]), "на время матча лобби закрыто")
	_check(sess_b._chan != null and sess_b._chan.kind() == "steam"
		and sess_a._chan != null and sess_a._chan.kind() == "pipe", "каналы: гость Steam, хозяин pipe")
	if not starts.has("a") or not starts.has("b"):
		print("  стоп: матч не начался — ", errors)
		return
	var bot_ticks := [0, 0]
	var frames := 0
	# Ретранслятор хозяина (в этом же процессе) сверяет ходы с настенными часами — защита от
	# разгона клиента («ход N раньше времени»). На свободной машине headless-кадры идут быстрее
	# реального времени, и хозяина выкидывало на ~170-м ходу (B-459, 09.10.2026); под нагрузкой
	# гейта кадры медленнее реального времени, и тест проходил. Держим темп не выше 60 ходов/с.
	var t0 := Time.get_ticks_msec()
	while frames < 4000:
		frames += 1
		await process_frame
		var ahead := int(float(worlds[0].net_tick) * 1000.0 / 60.0) - (Time.get_ticks_msec() - t0)
		if ahead > 0:
			OS.delay_msec(mini(ahead, 50))
		for i in 2:
			while bot_ticks[i] < worlds[i].net_tick:
				bot_ticks[i] += 1
				if worlds[i].phase == LegionWorld.Phase.BATTLE:
					bots[i].tick(NetSession.DT)
		if worlds[0].net_tick >= BATTLE_TICKS and worlds[1].net_tick >= BATTLE_TICKS:
			break
	_check(worlds[0].net_tick == BATTLE_TICKS and worlds[1].net_tick == BATTLE_TICKS,
		"оба мира дошли до тика %d за %d кадров (тики %d/%d, стадии %d/%d)" % [BATTLE_TICKS,
		frames, worlds[0].net_tick, worlds[1].net_tick, sess_a.stage, sess_b.stage])
	_check(worlds[0].net_digest() == worlds[1].net_digest(), "отпечатки миров совпали")
	_check(sess_a._desync_tick < 0 and sess_b._desync_tick < 0 and errors.is_empty(),
		"ретранслятор хозяина не нашёл расхождения, ошибок нет: %s" % str(errors))
	_check(sess_a._p2p == null and sess_b._p2p == null and sess_a.path_mode == "relay"
		and sess_b.path_mode == "relay", "прямого UDP-пути нет — путь «через сервер» = Steam")
	_check(sess_a.link_text().contains("через Steam") and sess_b.link_text().contains("через Steam"),
		"строка связи — «через Steam» у обоих")
	# гость выходит из матча → хозяину «left», оба в лобби; хозяин открывает комнату заново
	sess_b.leave_match()
	await _frames(6)
	_check(sess_a._remote_left and worlds[0].phase != LegionWorld.Phase.BATTLE,
		"хозяину — уход соперника, его бой закончен")
	# реванш: гость в лобби ретранслятора хозяина видит новую комнату (слушать — до её открытия)
	var rooms_seen: Array = []
	sess_b.lobby.connect(func(rooms: Array, _p: Array, _g: int) -> void: rooms_seen.assign(rooms))
	sess_a.leave_match()
	await _frames(6)
	_check(sess_a.stage == NetSession.Stage.LOBBY and sess_a.room_code != ""
		and String(SteamFake.lobbies[lobby]["data"].get("room", "")) == sess_a.room_code
		and String(SteamFake.lobbies[lobby]["data"].get("open", "")) == "1",
		"хозяин снова ждёт соперника, лобби Steam открыто")
	await _frames(3)
	var rematch_code := ""
	for r: Variant in rooms_seen:
		if r is Dictionary and not bool((r as Dictionary).get("mine", false)):
			rematch_code = String((r as Dictionary).get("code", ""))
	_check(rematch_code != "" and rematch_code == sess_a.room_code, "гость видит новую комнату хозяина")
	var first_seed: int = starts["a"][0]
	starts.clear()
	sess_b.join_room(rematch_code)
	await _frames(12)
	_check(starts.has("a") and starts.has("b") and starts["a"][0] == starts["b"][0]
		and starts["a"][0] != first_seed, "реванш: новый start у обоих, другой сид")
	# уход гостя совсем: соединение закрыто, хозяин жив и ждёт
	sess_a.leave_match()
	sess_b.close()
	sb.leave()
	await _frames(8)
	_check(sb.mode == "" and sb.lobby_id == 0 and fb.open_connections() == 0
		and fa.open_connections() == 0 and sa.mode == "host" and sa._links.is_empty()
		and sess_a.stage == NetSession.Stage.LOBBY and sess_a.room_code != "",
		"гость ушёл: дескрипторы свободны, хозяин ждёт следующего")
	# уход хозяина: лобби пропало, сокет закрыт
	sess_a.close()
	sa.leave()
	await _frames(3)
	_check(not SteamFake.lobbies.has(lobby) and SteamFake.listeners.is_empty() and sa.relay == null
		and sa.mode == "" and fa.rich.is_empty(), "хозяин ушёл: лобби, сокет, ядро, Rich Presence сняты")
	for w: LegionWorld in worlds:
		w.queue_free()
	ha.queue_free()
	hb.queue_free()
	await process_frame


# ── 5. Жизненный цикл лобби (verifier 08.10, п. 3a–3e) ─────────────────────

func _lifecycle_checks() -> void:
	SteamFake.reset_cloud()
	var fa: RefCounted = SteamFake.new(ID_A, "Хозяин")
	var fb: RefCounted = SteamFake.new(ID_B, "Гость")
	var fc: RefCounted = SteamFake.new(ID_B + 1, "Чужой")
	var ha := Node.new()
	var hb := Node.new()
	root.add_child(ha)
	root.add_child(hb)
	var sa := SteamNet.boot(ha, fa)
	var sb := SteamNet.boot(hb, fb)
	var sess_a := NetSession.new()
	var sess_b := NetSession.new()
	ha.add_child(sess_a)
	hb.add_child(sess_b)
	# 3c: host → leave → host до ответов Steam — ровно одно лобби на наше имя
	sa.host(sess_a, MAP, sa.my_name)
	sess_a.close()
	sa.leave()
	sa.host(sess_a, MAP, sa.my_name)
	await _frames(12)
	var mine := 0
	for id: int in SteamFake.lobbies:
		mine += int(int(SteamFake.lobbies[id]["owner"]) == ID_A)
	var lobby := sa.lobby_id
	_check(mine == 1 and lobby != 0 and SteamFake.lobbies.has(lobby) and sess_a.room_code != "",
		"host→leave→host: одно лобби на имя хозяина, без сирот (%d)" % mine)
	# 3a: вход отменён до ответа lobby_joined — гость не остаётся участником
	sb.join(sess_b, lobby, sb.my_name)
	sess_b.close()
	sb.leave()
	await _frames(6)
	var members: Array = SteamFake.lobbies[lobby]["members"]
	_check(members == [ID_A] and sb.mode == "" and sb.lobby_id == 0,
		"отменённый вход не оставляет гостя в лобби: %s" % str(members))
	# чужой SteamID подключается к сокету хозяина напрямую, минуя лобби: ждёт срок и получает отказ
	sa.accept_grace_s = 0.5
	var hc: int = fc.connectP2P(ID_A, 0, {})
	await _frames(4)
	_check(sa._links.is_empty() and sa._pending_accepts.size() == 1
		and int(sa._pending_accepts.values()[0]["identity"]) == ID_B + 1,
		"не участник лобби — ждёт в очереди")
	await _frames(40)
	_check(sa._links.is_empty() and sa._pending_accepts.is_empty() and fa.open_connections() == 0,
		"срок вышел — отказ, дескриптор у хозяина свободен")
	fc.closeConnection(hc, 0, "", false)
	# соединение пришло раньше, чем участник появился в списке лобби: принимается, когда появился
	var hc2: int = fc.connectP2P(ID_A, 0, {})
	await _frames(4)
	fc.joinLobby(lobby)
	fc.run_callbacks()   # у «чужого» нет своего SteamNet — обратные вызовы гоним руками
	await _frames(30)
	_check(sa._links.size() == 1 and sa._pending_accepts.is_empty() and fa.open_connections() == 1,
		"участник, появившийся в списке позже соединения, принят")
	fc.closeConnection(hc2, 0, "", false)
	fc.leaveLobby(lobby)
	await _frames(4)
	# 3b: приглашение → экран лобби с join_on_start забирает отложенный вход
	var requested: Array = []
	sb.join_request.connect(func(l: int) -> void: requested.append(l))
	fb.simulate_invite(lobby, ID_A)
	await _frames(3)
	_check(requested == [lobby] and sb._pending_join == lobby, "приглашение → join_request и отложенный вход")
	var screen := SteamLobby.new().setup(sess_b, sb, lobby)
	root.add_child(screen)
	await _frames(20)
	_check(sb._pending_join == 0 and sb.mode == "guest" and sb.lobby_id == lobby,
		"экран лобби забрал отложенный вход и вошёл (pending=%d, mode=%s)" % [sb._pending_join, sb.mode])
	screen.free()
	await _frames(2)
	var starts := 0
	sess_b.match_start.connect(func(_s: int, _m: String, _i: int) -> void: starts += 1)
	await _frames(10)
	_check(sb.mode == "guest" and sess_b.stage != NetSession.Stage.IDLE and sess_b._chan != null,
		"после закрытия экрана соединение гостя живо (стадия %d)" % sess_b.stage)
	# 3e: хозяин ушёл, гость ещё в лобби Steam — владение перешло гостю, он выходит сам
	sess_a.close()
	sa.leave()
	await _frames(40)
	_check(not SteamFake.lobbies.has(lobby) and sb.mode == "" and sb.lobby_id == 0,
		"хозяин ушёл: гость не остался «хозяином» пустого лобби (mode=%s)" % sb.mode)
	# 3d: пара каналов не держит друг друга после закрытия
	var ends := NetLinkPipe.pair()
	(ends[0] as NetLinkPipe).close(1000, "x")
	_check((ends[0] as NetLinkPipe)._peer == null and (ends[1] as NetLinkPipe)._peer == null,
		"закрытая пара NetLinkPipe рвёт цикл ссылок")
	ha.queue_free()
	hb.queue_free()
	await process_frame
