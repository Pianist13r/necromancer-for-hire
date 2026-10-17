extends SceneTree
## V2 regression: original three cases plus outside/no-focus and owned-action edges.

class RecordingLink extends NetLink:
	var sent: Array[Dictionary] = []
	var opened: bool = true
	func state() -> int:
		return State.OPEN if opened else State.CLOSED
	func send_text(text: String) -> Error:
		var msg: Variant = JSON.parse_string(text)
		if msg is Dictionary:
			sent.append(msg.duplicate(true))
		return OK
	func close(_code: int, _reason: String) -> void:
		opened = false

const A := {"code": "AAAA", "host": "Host A", "map": "pvp:duel", "mine": false}
const B := {"code": "BBBB", "host": "Host B", "map": "pvp:duel", "mine": false}
var results: Array[Dictionary] = []


func _initialize() -> void:
	_run.call_deferred()


func _frames(n: int = 3) -> void:
	for i: int in n:
		await process_frame


func _enter() -> void:
	for down: bool in [true, false]:
		var event := InputEventKey.new()
		event.keycode = KEY_ENTER
		event.physical_keycode = KEY_ENTER
		event.pressed = down
		Input.parse_input_event(event)
		await _frames(2)


func _focused(lobby: NetLobby) -> Dictionary:
	var owner: Control = root.gui_get_focus_owner()
	if owner == null:
		return {"present": false}
	return {"present": true, "path": String(owner.get_path()),
		"text": owner.text if owner is Button else "", "instance": owner.get_instance_id(),
		"inside_lobby": lobby.is_ancestor_of(owner), "visible": owner.is_visible_in_tree(),
		"queued": owner.is_queued_for_deletion()}


func _row_button(lobby: NetLobby, host: String) -> Button:
	for row: Node in lobby._rooms_box.get_children():
		if row.is_queued_for_deletion():
			continue
		var label: Label = row.get_child(0) as Label
		if label != null and label.text.contains(host):
			return row.get_child(1) as Button
	return null


func _case(label: String, updated: Array, retain_a: bool) -> void:
	var session := NetSession.new()
	root.add_child(session)
	session.set_process(false) # No polling/connect/timeout; UI signals are explicit.
	var link := RecordingLink.new()
	session._chan = link
	session.stage = NetSession.Stage.LOBBY
	var lobby := NetLobby.new().setup(session)
	root.add_child(lobby)
	await _frames()
	session.lobby.emit([A.duplicate(true), B.duplicate(true)], ["Tester"], 0)
	await _frames()
	var button := _row_button(lobby, "Host A")
	var result: Dictionary = {"case": label, "pass": false, "retain_a": retain_a}
	if button == null:
		result["error"] = "fixture_A_button_missing"
	else:
		button.grab_focus()
		await _frames()
		result["before"] = _focused(lobby)
		result["fixture_valid"] = root.gui_get_focus_owner() == button
		session.lobby.emit(updated.duplicate(true), ["Tester", "Other"], 0)
		await _frames() # Wait for queued old rows to be removed and layout to settle.
		result["after_refresh"] = _focused(lobby)
		var new_a: Button = _row_button(lobby, "Host A")
		result["focus_on_A"] = new_a != null and root.gui_get_focus_owner() == new_a
		link.sent.clear()
		await _enter()
		result["sent"] = link.sent.duplicate(true)
		var joins: Array = link.sent.filter(func(msg: Dictionary) -> bool: return msg.get("t") == "join")
		if retain_a:
			result["pass"] = result["fixture_valid"] and result["focus_on_A"] \
				and link.sent == [{"t": "join", "code": "AAAA"}]
		else:
			var focus: Dictionary = result["after_refresh"]
			result["pass"] = result["fixture_valid"] and bool(focus.get("present", false)) \
				and bool(focus.get("inside_lobby", false)) and bool(focus.get("visible", false)) \
				and not bool(focus.get("queued", true)) and joins.is_empty()
	results.append(result)
	lobby.queue_free()
	await _frames()
	session.close()
	session.queue_free()
	await _frames()


func _run() -> void:
	AudioServer.set_bus_mute(0, true)
	await _case("retain_A_same_order", [A, B], true)
	await _case("retain_A_reordered", [B, A], true)
	await _case("remove_A", [B], false)
	await _edge("outside_back", "outside")
	await _edge("no_focus", "none")
	await _edge("owned_cancel_retained", "owned")
	await _edge("owned_becomes_foreign", "changed_action")
	var passed: bool = results.size() == 7
	for result: Dictionary in results:
		passed = passed and bool(result["pass"])
	var report: Dictionary = {"completed": true, "pass": passed, "cases": results,
		"actual_network": false, "main_or_world_instantiated": false,
		"input": "Input.parse_input_event Enter down/up", "scope": "room refresh focus only"}
	if OS.get_environment("QA_OUT") != "":
		var file := FileAccess.open(OS.get_environment("QA_OUT").path_join("outcome.json"),
			FileAccess.WRITE)
		file.store_string(JSON.stringify(report))
		file.close()
	print("LOBBY REFRESH FOCUS: ", "PASS" if passed else "FAIL", " cases=", results.size())
	quit(0 if passed else 1)



func _edge(label: String, mode: String) -> void:
	var session := NetSession.new()
	root.add_child(session)
	session.set_process(false)
	var link := RecordingLink.new()
	session._chan = link
	session.stage = NetSession.Stage.LOBBY
	var lobby := NetLobby.new().setup(session)
	root.add_child(lobby)
	var backs: Array[int] = [0]
	lobby.back.connect(func() -> void: backs[0] += 1)
	await _frames()
	var own: Dictionary = A.duplicate(true)
	own["mine"] = true
	var owned: bool = mode in ["owned", "changed_action"]
	session.lobby.emit([own if owned else A.duplicate(true), B.duplicate(true)], ["Tester"], 0)
	await _frames()
	var back_button: Button = lobby.find_child("NavBack", true, false) as Button
	if owned:
		(lobby._rooms_box.get_child(0).get_child(1) as Button).grab_focus()
	elif mode == "outside":
		back_button.grab_focus()
	elif root.gui_get_focus_owner() != null:
		root.gui_get_focus_owner().release_focus()
	await _frames()
	var before: Dictionary = _focused(lobby)
	var rows: Array = [B.duplicate(true), own if mode == "owned" else A.duplicate(true)]
	session.lobby.emit(rows, ["Tester", "Other"], 0)
	await _frames()
	var after: Dictionary = _focused(lobby)
	var correct_focus: bool = false
	if mode == "none":
		correct_focus = not before["present"] and root.gui_get_focus_owner() == null
	elif mode in ["outside", "changed_action"]:
		correct_focus = root.gui_get_focus_owner() == back_button
	else:
		var own_button := lobby._rooms_box.get_child(1).get_child(1) as Button
		correct_focus = root.gui_get_focus_owner() == own_button
	link.sent.clear()
	await _enter()
	var expected: Array = [{"t": "cancel"}] if mode == "owned" else []
	var expected_backs: int = 1 if mode in ["outside", "changed_action"] else 0
	results.append({"case": label, "before": before, "after_refresh": after,
		"sent": link.sent.duplicate(true), "back_count": backs[0],
		"pass": correct_focus and link.sent == expected and backs[0] == expected_backs})
	lobby.queue_free()
	await _frames()
	session.close()
	session.queue_free()
	await _frames()

