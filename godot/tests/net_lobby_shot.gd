extends SceneTree
##
## Кадр лобби онлайн-«Схватки» для приёмки глазами (NetLobby + NetSession против живого
## ретранслятора). Нужно ОКНО (без --headless): кадр снимается с вьюпорта.
##   godot --path godot --resolution 1280x720 --script res://tests/net_lobby_shot.gd -- --mute
##       --url ws://127.0.0.1:18799 --out C:/путь/lobby.png
## Второй «игрок» (сырой сокет, имя «Боря») открывает комнату — в списке должна быть строка с ним.
##

var _url := "ws://127.0.0.1:18799"
var _out := "user://lobby.png"
var _other := WebSocketPeer.new()


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	for i in args.size() - 1:
		if args[i] == "--url":
			_url = args[i + 1]
		elif args[i] == "--out":
			_out = args[i + 1]
	_run.call_deferred()


func _run() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("net", "name", "Игорь")
	cfg.set_value("net", "url", _url)
	cfg.save(NetLobby.CFG)
	_other.connect_to_url(_url)
	for i in 120:
		_other.poll()
		if _other.get_ready_state() == WebSocketPeer.STATE_OPEN:
			break
		await process_frame
	_other.send_text(JSON.stringify({"t": "hello", "v": 1, "build": NetSession.BUILD,
		"name": "Боря"}))
	_other.send_text(JSON.stringify({"t": "create", "map": "gen:"}))
	var session := NetSession.new()
	root.add_child(session)
	var lobby := NetLobby.new().setup(session)
	root.add_child(lobby)
	await _wait(1.0)
	await _shot(_out.replace(".png", "_before.png"))
	lobby._on_connect()
	await _wait(3.0)
	await _shot(_out)
	quit(0)


func _wait(sec: float) -> void:
	var t := 0.0
	while t < sec:
		_other.poll()
		while _other.get_available_packet_count() > 0:
			_other.get_packet()
		await process_frame
		t += 1.0 / 60.0


func _shot(path: String) -> void:
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(path)
	print("кадр: ", path)
