extends SceneTree
##
## Ретранслятор онлайн-«Схватки» отдельным процессом: слушатели WebSocket + ядро NetRelayCore
## (протокол, комнаты, судьи, защита — там; здесь только сокеты и ключи запуска). С 08.10.2026 ядро
## вынесено, чтобы хозяин Steam-игры мог держать его у себя в процессе (SteamNet) — сервер при этом
## не нужен.
##
## Запуск (с 04.10.2026 — отдельная машина за HTTPS-прокси Caddy, который пускает только WebSocket):
##   Godot_console --headless --path godot --script res://scripts/legion/net/net_relay.gd -- \
##       [--port 18765] [--bind 127.0.0.1] [--judges N] [--judge-port P] [--lobby-idle МС]
##       [--ready-timeout МС] [--stats-grace МС] [--judge-snap-limit N]
## По умолчанию слушает только loopback: снаружи до него доходит лишь туннель. `--bind 0.0.0.0`
## — для проверки по домашней сети. Судьи входят на отдельный loopback-порт (по умолчанию порт
## игроков + 1): Caddy виден как 127.0.0.1, поэтому IP не доказывает роль судьи — на этом входе всё
## равно обязателен случайный ключ комнаты; публичный вход judge не принимает. `--judges 0`
## выключает внутренний listener.
##

var core := NetRelayCore.new()
var _server := TCPServer.new()
var _judge_server := TCPServer.new()


func _initialize() -> void:
	var port := 18765
	var bind := "127.0.0.1"
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == "--port" and i + 1 < args.size():
			port = int(args[i + 1])
		elif args[i] == "--stats-grace" and i + 1 < args.size():
			core.stats_grace = int(args[i + 1])
		elif args[i] == "--ready-timeout" and i + 1 < args.size():
			core.ready_timeout = int(args[i + 1])
		elif args[i] == "--judges" and i + 1 < args.size():
			core.judge_max = clampi(int(args[i + 1]), 0, NetRelayCore.JUDGE_MAX)
		elif args[i] == "--judge-port" and i + 1 < args.size():
			core.judge_port = int(args[i + 1])
		elif args[i] == "--lobby-idle" and i + 1 < args.size():
			core.lobby_idle = maxi(1, int(args[i + 1]))
		elif args[i] == "--judge-snap-limit" and i + 1 < args.size():
			core.judge_snap_limit = int(args[i + 1])
		elif args[i] == "--bind" and i + 1 < args.size():
			bind = args[i + 1]
	var err := _server.listen(port, bind)
	if err != OK:
		core._log("не удалось слушать %s:%d (ошибка %d)" % [bind, port, err])
		quit(1)
		return
	if core.judge_max > 0:
		if core.judge_port == 0:
			core.judge_port = port + 1
		var judge_err := _judge_server.listen(core.judge_port, "127.0.0.1")
		if judge_err != OK:
			core._log("не удалось открыть внутренний порт судьи %d (ошибка %d)" % [
				core.judge_port, judge_err])
			quit(1)
			return
	core._log("ретранслятор слушает %s:%d, протокол %d" % [bind, port, NetRelayCore.PROTO])


func _process(_delta: float) -> bool:
	_accept_from(_server, false)
	_accept_from(_judge_server, true)
	core.process()
	return false


## Место проверяется до рукопожатия: лишнего не принимаем вовсе (как и до вынесения ядра).
func _accept_from(server: TCPServer, judge_only: bool) -> void:
	while server.is_connection_available():
		var stream := server.take_connection()
		if stream == null:
			return
		if not core.has_capacity(judge_only):
			stream.disconnect_from_host()
			continue
		var link := NetLinkWs.accept(stream)
		if link == null:
			stream.disconnect_from_host()
			continue
		if core.add_link(link, judge_only) == 0:
			link.close(1000, "мест нет")
