extends SceneTree
## External candidates are loaded as Dictionaries, without copying into res://maps or changing
## LegionWorld.load_map. Pass --candidate-dir ABSOLUTE_PATH to validate all eight frozen JSONs.

const IDS := ["wasteland", "gatehouse", "fork", "archive", "bridge", "maze", "swamp", "boss"]
const SAVE := "user://legion_campaign_candidate_test.cfg"

var _checks := 0
var _fails := 0
var _world: LegionWorld


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	Campaign.unlock_all()
	root.size = Vector2i(1280, 720)
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	_world = scene.instantiate() as LegionWorld
	_world.embedded = true
	_world.in_campaign = true
	root.add_child(_world)
	await _frames(2)

	var candidate_dir := _arg_value("--candidate-dir")
	if candidate_dir.is_empty():
		var fixture: Variant = JSON.parse_string(FileAccess.get_file_as_string(
			"res://assets/legion/maps/archive.json"))
		_check(fixture is Dictionary, "canonical Archive fixture parses")
		if fixture is Dictionary:
			var sentinel: Dictionary = fixture.duplicate(true)
			sentinel["title"] = "Candidate seam title sentinel"
			sentinel["cauldron"] = [600, 360]
			sentinel["lessons"][0]["text"] = "Candidate seam lesson sentinel"
			sentinel["lessons"][0]["mark"]["at"] = [456, 321]
			_check_candidate("archive", sentinel, true)
	else:
		for id: String in IDS:
			var path := candidate_dir.path_join(id + ".json")
			var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path)) \
				if FileAccess.file_exists(path) else null
			_check(parsed is Dictionary, "%s candidate JSON parses" % id)
			if parsed is Dictionary:
				_check_candidate(id, parsed)

	_world.start_map("archive")
	_check(_world.map.get("id", "") == "archive", "normal start_map loads canonical map")
	_world.start_map("archive", {})
	_check(_world.map.get("id", "") == "archive", "empty Dictionary uses normal map fallback")
	_world.start_map("__campaign_candidate_missing__", {})
	_check(_world.map.is_empty(), "missing map remains rejected after empty fallback")

	print("LEGION CAMPAIGN CANDIDATES: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


func _check_candidate(id: String, candidate: Dictionary, check_sentinel := false) -> void:
	_check(String(candidate.get("id", "")) == id, "%s candidate id matches filename" % id)
	var before := JSON.stringify(candidate)
	_world.start_map(id, candidate)
	_check(not _world.map.is_empty(), "%s injected Dictionary starts" % id)
	if check_sentinel:
		_check(_world.map.get("title", "") == "Candidate seam title sentinel",
			"injected title reaches active map")
		_check(_world.cauldron_pos == Vector2(600, 360),
			"injected cauldron coordinate reaches active world")
	_check(JSON.stringify(candidate) == before, "%s input Dictionary stays unchanged" % id)
	if _world.map.is_empty():
		return
	_world.start_lessons(true)
	var expected: Array = candidate.get("lessons", [])
	var actual: Array[Dictionary] = []
	if _world.tutorial != null:
		actual = _world.tutorial.lessons
	_check(actual.size() == expected.size(), "%s tutorial reads candidate lessons" % id)
	if check_sentinel and not actual.is_empty():
		_check(actual[0].get("text", "") == "Candidate seam lesson sentinel",
			"injected lesson text reaches active tutorial")
		_check(actual[0].get("mark", {}).get("at", []) == [456, 321],
			"injected lesson mark reaches active tutorial")
	_check(JSON.stringify(candidate) == before, "%s input stays unchanged after tutorial setup" % id)


func _arg_value(key: String) -> String:
	var args := OS.get_cmdline_user_args()
	var index := args.find(key)
	return String(args[index + 1]) if index >= 0 and index + 1 < args.size() else ""


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if cond:
		print("  ok   ", label)
	else:
		_fails += 1
		print("  FAIL ", label)
