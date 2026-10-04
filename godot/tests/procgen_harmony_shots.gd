extends SceneTree
## Кадры приёмки «постройки и бойцы в земле» (сессия harmony-1003, D-CX-08): карта собирается
## PgArt, на участках строятся постройки (виды по кругу), у Котла и в поле стоят бойцы обеих
## сторон/враги разных видов, бой стоит (hold). Кадр боя — game_<имя>.png (окно --size, по
## умолчанию 1280x720); крупные кропы 1:1 режутся питоном по --size 2560x1440. Нужен настоящий
## рендер (окно), --fixed-fps 60 и --mute.
##
##   "$GODOT" --path godot --fixed-fps 60 --script res://tests/procgen_harmony_shots.gd -- --mute \
##       --out <папка> --maps gen:12:5,pvp:duel [--size 1920x1080] [--build 1] [--plain 1]
##
## --build 1 — построить на участках (по умолчанию 1); --plain 1 — не тонировать (сравнение
## «было» на той же ветке: гармонизация выключается дев-ключом harmony_off).

const ART_TIMEOUT_MSEC := 30000
const KINDS := [&"laborer", &"guard", &"laborer", &"guard"]

var _size := Vector2i(1280, 720)
var _art_done := false


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var argv := OS.get_cmdline_user_args()
	var out := _arg(argv, "--out")
	var maps := _arg(argv, "--maps")
	var size_txt := _arg(argv, "--size")
	if size_txt.contains("x"):
		_size = Vector2i(int(size_txt.get_slice("x", 0)), int(size_txt.get_slice("x", 1)))
	if out.is_empty() or maps.is_empty():
		push_error("--out and --maps required")
		quit(2)
		return
	DirAccess.make_dir_recursive_absolute(out)
	Campaign.set_save_path("user://procgen_harmony_shots.cfg")
	DisplayServer.window_set_size(_size)
	var failed := 0
	for id in maps.split(","):
		if not await _capture(id, out, _arg(argv, "--plain") == "1",
				_arg(argv, "--build") != "0"):
			failed += 1
	quit(1 if failed > 0 else 0)


func _capture(id: String, out: String, plain: bool, build: bool) -> bool:
	Campaign.reset()
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	var world := scene.instantiate() as LegionWorld
	world.embedded = true
	world.hold = true
	root.add_child(world)
	await process_frame
	if plain:
		world.dev["harmony_off"] = 1
	var started := Time.get_ticks_msec()
	world.start_map(id, {})
	var terrain := world.ground_view()
	if terrain == null or terrain._pgart_req == null:
		push_error("нет запроса PgArt: " + id)
		world.queue_free()
		return false
	_art_done = false
	terrain._pgart_req.ready.connect(func(_t: Texture2D) -> void: _art_done = true,
		CONNECT_ONE_SHOT)
	var deadline := Time.get_ticks_msec() + ART_TIMEOUT_MSEC
	while not _art_done and Time.get_ticks_msec() < deadline:
		await process_frame
	if not _art_done:
		push_error("PgArt не собрал картинку: " + id)
		world.queue_free()
		return false
	for _i in 4:
		await process_frame
	var build_ms := Time.get_ticks_msec() - started
	if (world.harmony == null) != plain:
		push_error("неверное состояние harmony_off: " + id)
		world.queue_free()
		return false
	if plain and not (terrain._map.get("contact", []) as Array).is_empty():
		push_error("harmony_off оставил контактные тени: " + id)
		world.queue_free()
		return false
	if build:
		world.staff.add_souls(2000)
		var n := 0
		for plot: Dictionary in world.staff.plots:
			if plot["building"] == null:
				world.staff.build(plot, KINDS[n % KINDS.size()])
				n += 1
	var first := world._frames
	world.hold = false
	while world._frames - first < 90:
		await process_frame
	world.hold = true
	await RenderingServer.frame_post_draw
	var img := root.get_texture().get_image()
	var name := id.replace(":", "_")
	img.save_png(out.path_join("game_%s.png" % name))
	var stat := _contrast(world)
	var info := {"map": id, "contrast": stat, "size": img.get_size(), "units": world.units.size(),
		"buildings": world.buildings.size(), "build_ms": build_ms,
		"harmony": world.harmony != null, "contact": terrain._map.get("contact", [])}
	print(JSON.stringify(info))
	for side in world.sides:
		if side.items != null and side.items.effects != null:
			side.items.effects.items = null
	world.queue_free()
	await process_frame
	return true


func _arg(args: PackedStringArray, key: String) -> String:
	var i := args.find(key)
	return args[i + 1] if i >= 0 and i + 1 < args.size() else ""


## Контраст «спрайт к земле рядом» до и после тонировки (Майкельсон |Ls−Lg|/(Ls+Lg)): после/до —
## по всем постройкам, склепам и Котлу карты. Без harmony (--plain 1) пусто.
func _contrast(world: LegionWorld) -> Dictionary:
	if world.harmony == null:
		return {}
	var pairs: Array[Array] = []
	for b: LegionBuilding in world.buildings:
		if b.source == LegionBuilding.SOURCE_PLOT:
			var art := b.get_node_or_null("BuildingArtwork/Artwork") as Sprite2D
			if art != null:
				pairs.append([art.texture, art.modulate, b.position])
	for c in world.crypts:
		pairs.append([c._tex, c._tone, c.position])
	var cauldron := world._cauldron
	if cauldron != null:
		pairs.append([cauldron.texture, cauldron.modulate, world.cauldron_view_pos])
	var before := 0.0
	var after := 0.0
	var n := 0
	for pr in pairs:
		var lum := _mean_lum(pr[0] as Texture2D)
		var tone: Color = pr[1]
		var ground := world.harmony.ground_at(pr[2] as Vector2).get_luminance()
		var l_after := lum * tone.get_luminance()
		before += absf(lum - ground) / maxf(lum + ground, 0.001)
		after += absf(l_after - ground) / maxf(l_after + ground, 0.001)
		n += 1
	if n == 0:
		return {}
	return {"n": n, "before": snappedf(before / n, 0.001), "after": snappedf(after / n, 0.001),
		"ratio": snappedf(after / maxf(before, 0.001), 0.001)}


func _mean_lum(tex: Texture2D) -> float:
	var img := tex.get_image()
	if img.is_compressed():
		img.decompress()
	img.resize(48, 48)
	var sum := 0.0
	var k := 0
	for y in 48:
		for x in 48:
			var c := img.get_pixel(x, y)
			if c.a > 0.5:
				sum += c.get_luminance()
				k += 1
	return sum / maxf(k, 1)
