extends SceneTree
## Прямой путь (UDP/STUN) только с явного согласия игрока (B-403/B-405): сессия по умолчанию без
## него, галочка лобби запоминается в user://net.cfg. До 08.10.2026 эти проверки жили в
## legion_net_security_test.gd; вынесены отдельно — вместе с проверками ядра ретранслятора в одном
## процессе движок изредка падал на выходе (код 139, после итоговой строки; порознь — нет).

var _ok := 0
var _all := 0


func _initialize() -> void:
	_run.call_deferred()


func _process(_delta: float) -> bool:
	return false


func _check(cond: bool, what: String) -> void:
	_all += 1
	if cond:
		_ok += 1
	else:
		print("FAIL: ", what)


func _run() -> void:
	var cfg := ConfigFile.new()
	cfg.save(NetLobby.CFG)
	var session := NetSession.new()
	root.add_child(session)
	_check(not session.direct_enabled, "сессия по умолчанию без прямого пути")
	session._start_p2p("11".repeat(16))
	_check(session._p2p == null, "без согласия нет UDP/STUN")
	var lobby := NetLobby.new().setup(session)
	root.add_child(lobby)
	_check(not lobby._direct.button_pressed and not session.direct_enabled,
		"новый игрок в лобби без прямого пути")
	lobby._direct.button_pressed = true
	root.remove_child(lobby)
	lobby.free()
	lobby = NetLobby.new().setup(session)
	root.add_child(lobby)
	_check(lobby._direct.button_pressed and session.direct_enabled, "существующий выбор сохранён")
	lobby._direct.button_pressed = false
	root.remove_child(lobby)
	lobby.free()
	root.remove_child(session)
	session.free()
	await process_frame
	print("LEGION NET PRIVACY: %d/%d OK" % [_ok, _all])
	quit(0 if _ok == _all else 1)
