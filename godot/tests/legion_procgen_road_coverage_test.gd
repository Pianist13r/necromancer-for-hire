extends SceneTree
## Every road that carries a nonempty wave group has its own front bot line.
## Fixed regression set includes the debrief map gen:3341246352:6.

const SEEDS := [3341246352, 7, 11, 41]
var checks := 0
var failures := 0


func _initialize() -> void:
	var archetypes := {}
	for seed: int in SEEDS:
		for k in range(1, 17):
			var map := ProcGen.generate(seed, k)
			_check(not map.is_empty(), "gen:%d:%d exists" % [seed, k])
			if map.is_empty():
				continue
			var active := {}
			for wave: Dictionary in map["waves"]:
				for group: Dictionary in wave["groups"]:
					if int(group.get("count", 0)) > 0:
						active[String(group["road"])] = true
			var fronts := {}
			for line: Dictionary in map["bot_lines"]:
				if String(line.get("role", "")) == "front":
					fronts[String(line["road"])] = true
			for road: Dictionary in map["roads"]:
				var id := String(road["id"])
				if active.has(id):
					_check(fronts.has(id), "gen:%d:%d road %s has front" % [seed, k, id])
			var pg: Dictionary = map["procgen"]
			archetypes[String(pg["card"]["archetype"])] = true
	_check(archetypes.size() == PgTables.ARCH_ORDER.size(),
		"fixed set retains all %d archetypes" % PgTables.ARCH_ORDER.size())
	print("PROCGEN ROAD COVERAGE: %d/%d OK" % [checks - failures, checks])
	quit(1 if failures else 0)


func _check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		print("FAIL ", label)
