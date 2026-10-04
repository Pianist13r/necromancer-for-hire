extends SceneTree
## Полная задержка build → ready, включая диагностику, чтение GPU и создание текстуры.
## Нужен Vulkan, --fixed-fps 60 и --mute. Headless намеренно не годится.
const MAPS := ["gen:10:3", "gen:11:3", "gen:12:11", "gen:12:12", "gen:12:5",
	"gen:12:9", "gen:4:12", "gen:7:5", "gen:9:7"]
const BUDGET_MS := 1500


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("PgArt benchmark requires a real renderer")
		quit(1)
		return
	var failed := 0
	for id: String in MAPS:
		var map := LegionWorld.load_map(id)
		var started := Time.get_ticks_msec()
		var req := PgArt.build(map, root)
		var texture: Texture2D = await req.ready
		var elapsed := Time.get_ticks_msec() - started
		var ok := texture != null and elapsed <= BUDGET_MS
		if not ok:
			failed += 1
		print("ART4 BENCH %s %d ms %s" % [id, elapsed, "OK" if ok else "FAIL"])
		await process_frame
	print("ART4 BENCH: %d/%d OK" % [MAPS.size() - failed, MAPS.size()])
	quit(1 if failed else 0)
