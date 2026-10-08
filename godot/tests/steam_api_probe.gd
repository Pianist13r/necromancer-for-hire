extends SceneTree
##
## Проба настоящего GodotSteam без клиента Steam: грузит расширение из NECRO_STEAM_EXT (или из
## папки рядом с exe, как SteamNet), берёт синглтон «Steam» и сверяет, что все методы и сигналы,
## которые зовёт SteamApi/SteamNet, у него есть. steamInitEx НЕ зовётся: это проба имён, не
## запуск под аккаунтом владельца (инициализация показала бы друзьям «играет в Spacewar»).
##
##   NECRO_STEAM_EXT=<…>/godotsteam/godotsteam.gdextension "$GODOT" --headless --path godot \
##       --script res://tests/steam_api_probe.gd -- --mute
## Без NECRO_STEAM_EXT и без папки рядом с exe — «skip», код 0 (в гейт не входит: имя не legion_*).
## Итог «STEAM API PROBE: N/M OK», код выхода 1 при провале.
##

const METHODS := ["steamInitEx", "run_callbacks", "isSteamRunning", "steamShutdown", "getSteamID",
	"getPersonaName", "getFriendPersonaName", "initRelayNetworkAccess", "createLobby", "joinLobby",
	"leaveLobby", "setLobbyData", "getLobbyData", "setLobbyJoinable", "getLobbyOwner",
	"getNumLobbyMembers", "getLobbyMemberByIndex", "addRequestLobbyListStringFilter",
	"addRequestLobbyListDistanceFilter", "addRequestLobbyListResultCountFilter", "requestLobbyList",
	"setRichPresence", "clearRichPresence", "activateGameOverlayInviteDialog",
	"createListenSocketP2P", "connectP2P", "acceptConnection", "closeConnection",
	"closeListenSocket", "sendMessageToConnection", "receiveMessagesOnConnection",
	"getConnectionRealTimeStatus"]
const SIGNALS := ["lobby_created", "lobby_joined", "lobby_match_list",
	"network_connection_status_changed", "join_requested", "join_game_requested"]

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
	var path := OS.get_environment(SteamNet.ENV_EXT)
	if path == "":
		path = OS.get_executable_path().get_base_dir().path_join(SteamNet.EXT_REL)
	if not FileAccess.file_exists(path):
		print("STEAM API PROBE: skip — нет расширения (%s)" % path)
		quit(0)
		return
	if not Engine.has_singleton(SteamApi.SINGLETON):
		var st := GDExtensionManager.load_extension(path)
		_check(st == GDExtensionManager.LOAD_STATUS_OK, "load_extension(%s) → %d" % [path, st])
	var steam := SteamApi.find()
	_check(steam != null, "синглтон «Steam» зарегистрирован")
	if steam != null:
		for m: String in METHODS:
			_check(steam.has_method(m), "метод %s" % m)
		for s: String in SIGNALS:
			_check(steam.has_signal(s), "сигнал %s" % s)
		# сигнатуры сигналов — порядок и число аргументов, как в SteamApi/SteamNet
		var want := {"lobby_created": 2, "lobby_joined": 4, "lobby_match_list": 1,
			"network_connection_status_changed": 3, "join_requested": 2, "join_game_requested": 2}
		for sig: Dictionary in steam.get_signal_list():
			var n := String(sig.get("name", ""))
			if want.has(n):
				var args: Array = sig.get("args", [])
				var names: Array = []
				for a: Dictionary in args:
					names.append(String(a.get("name", "")))
				_check(args.size() == int(want[n]), "сигнал %s: аргументов %d — %s" % [n, args.size(),
					str(names)])
		_check(not steam.has_method(&"addIdentity") or true,
			"справочно: addIdentity %s (Networking Types снят в 4.8)" % str(steam.has_method(&"addIdentity")))
	print("STEAM API PROBE: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)
