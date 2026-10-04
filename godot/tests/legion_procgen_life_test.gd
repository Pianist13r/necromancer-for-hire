extends SceneTree
## Scenic groups must stay deterministic, out of gameplay space, and bounded.
const SWAMP_PNG := "res://assets/legion/procgen/ground/swamp_02.png"
var checks := 0
var failures := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		print("FAIL ", label)


func _run() -> void:
	var path := "res://scripts/legion/procgen/pg_art_life.gd"
	_check(ResourceLoader.exists(path), "biome still-life implementation exists")
	_test_ground_resolver()
	if failures:
		print("LEGION PROCGEN LIFE: %d/%d OK" % [checks - failures, checks])
		quit(1)
		return
	var life_script: Script = load(path)
	var total := 0
	for id: String in ["gen:12:5", "gen:7:5", "gen:10:3", "gen:11:3", "gen:12:12"]:
		var map := LegionWorld.load_map(id)
		var digest := ProcGen.digest(map)
		var points: PackedVector2Array = life_script.positions(map)
		_check(points == life_script.positions(map), "deterministic " + id)
		_check(points.size() <= 3, "bounded groups " + id)
		var free := PgArtScatter.Free.new(map, PgArtScatter._cauldron(map))
		for p in points:
			_check(free.ok(p, 68.0), "full group clears gameplay geometry " + id)
		total += points.size()
		var baked: Node2D = life_script.new()
		baked.setup(map, false)
		_check(not baked.is_processing(), "baked layer stays static")
		baked.free()
		var live: Node2D = life_script.new()
		live.setup(map, true)
		_check(live.get_child_count() == 0, "animation does not duplicate props")
		live.free()
		_check(digest == ProcGen.digest(map), "map dictionary unchanged " + id)
	_check(total > 0, "test maps contain visible accents")
	print("LEGION PROCGEN LIFE: %d/%d OK" % [checks - failures, checks])
	quit(1 if failures else 0)


func _test_ground_resolver() -> void:
	var missing_jpg := SWAMP_PNG.trim_suffix(".png") + ".jpg"
	var map := {"biome": "swamp", "id": "life-swamp-png", "ground": missing_jpg}
	var resolved := PgArtCanvas.resolve_ground_path(map)
	_check(resolved == SWAMP_PNG, "missing swamp_02.jpg resolves to PNG sibling")
	var exists := ResourceLoader.exists(resolved, "Texture2D")
	_check(exists, "resolved swamp ground exists as Texture2D")
	if exists:
		_check(ResourceLoader.load(resolved) is Texture2D, "swamp_02.png loads")
