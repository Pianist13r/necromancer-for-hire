extends SceneTree
## GPU-only visual acceptance fixture; no headless. CPU preparation is not a passed capture.
## -- --mute --out C:/AI/necro/batches/pvp-side-look
const DEVICE := 7
const KINDS: Array[StringName] = [&"laborer", &"guard", &"clerk"]
const CENTER := Vector2(800, 245)
var w: LegionWorld
var out := ""
var failed := false
var checks := 0
var passed := 0
var cohort: Array[WeakRef] = []


class _Mute:
	extends Node

	func _input(event: InputEvent) -> void:
		if event.device != DEVICE and (event is InputEventMouse or event is InputEventKey):
			get_viewport().set_input_as_handled()


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var argv := OS.get_cmdline_user_args()
	var pos := argv.find("--out")
	out = argv[pos + 1] if pos >= 0 and pos + 1 < argv.size() else "user://pvp-side-look"
	DirAccess.make_dir_recursive_absolute(out)
	Campaign.set_save_path("user://pvp_side_shots.cfg")
	Campaign.reset()
	root.size = Vector2i(1280, 720)
	root.content_scale_size = Vector2i(1600, 900)
	root.add_child(_Mute.new())
	w = (load("res://scenes/legion_world.tscn") as PackedScene).instantiate() as LegionWorld
	w.embedded = true
	root.add_child(w)
	await process_frame
	w.set_process(false)
	for mode in ["full", "economy"]:
		Settings.economy_override = "on" if mode == "economy" else "off"
		w._sync_gfx_layers()
		_prepare()
		await _wait_ground_ready()
		await _shot(mode + "-plain")
		_artifacts_and_haste()
		for i in 3:
			w._step(1.0 / 60.0)
			await process_frame
		await _shot(mode + "-artifacts-e")
		await _wait_after_e()
		await _shot(mode + "-after-e")
	Settings.economy_override = ""
	w.queue_free()
	await process_frame
	Campaign.reset()
	print("PVP_SIDE_CHECKS %d/%d" % [passed, checks])
	print("PVP_SIDE_SHOTS exit%d" % (1 if failed else 0))
	quit(1 if failed else 0)


## _build_ground completes asynchronously. An extra frame lets its queued overlay exit the tree.
func _wait_ground_ready() -> void:
	for i in 600:
		if not w.is_ground_loading():
			break
		await process_frame
	await process_frame


## World movement is frozen for the camera fixture. Age the same clocks used by _step, in its
## order (now, items, heroes); LegionFx and scene tweens age on render frames. Unit ticks stay
## disabled, so the 24-person group cannot wander into combat during Overtime Sheet haste.
func _wait_after_e() -> void:
	var longest := 0.0
	for side in w.sides:
		longest = maxf(longest, side.hero.e_duration())
	var end_usec := Time.get_ticks_usec() + int((longest + 2.0) * 1000000.0)
	var previous_usec := Time.get_ticks_usec()
	for frame in 3600:
		await process_frame
		var current_usec := Time.get_ticks_usec()
		var dt := maxf(0.0, float(current_usec - previous_usec) / 1000000.0)
		previous_usec = current_usec
		w.now += dt
		for side in w.sides:
			side.items.tick(dt)
		for side in w.sides:
			side.hero.tick(dt)
		if current_usec >= end_usec:
			break


func _prepare() -> void:
	seed(7140)
	cohort.clear()
	w.args.erase("pvp_bots")
	w.dev = {"pvp_nobot": "1", "no_waves": "1", "spawn_units": "0"}
	w._base_seed = 7140
	w.start_map("pvp:duel")
	w.set_process(false)
	for side in w.sides:
		side.souls = 10000
		for i in KINDS.size():
			side.staff.build(side.staff.plots[i], KINDS[i])
		# Pairs of equal professions interleaved; owner is not inferable from profession.
		for row in 3:
			for col in 4:
				var at := CENTER + Vector2((col * 2 + side.index - 3.5) * 22, (row - 1) * 36)
				var unit := w.spawn_unit(KINDS[row], at, null, side.index)
				unit.hp = 2000.0
				unit.max_hp = unit.hp
				unit.queue_redraw()
				cohort.append(weakref(unit))
		side.hero._vis_rng.seed = 7140 + side.index
	if w.gfx_fx() != null:
		w.gfx_fx().rng.seed = 7140
		w.gfx_fx().impact.rng.seed = 7140
	w.queue_redraw()


func _artifacts_and_haste() -> void:
	for side in w.sides:
		for id in ["exploding_stamp", "burning_seal", "staff_schedule", "overtime_sheet",
				"cauldron_ward", "clip_of_fate", "lightning_rod"]:
			side.items.grant(StringName(id))
		side.hero.cast(LegionHero.SLOT_E, CENTER)
		side.hero.cast(LegionHero.SLOT_Q, CENTER)
		for unit in w.units:
			if unit.side == side.index:
				unit.queue_redraw()


func _shot(name: String) -> void:
	await process_frame
	await RenderingServer.frame_post_draw
	var picture := root.get_texture().get_image()
	if picture == null or picture.is_empty():
		failed = true
		push_error("PVP_SIDE_SHOTS empty GPU frame")
		return
	failed = picture.save_png(out.path_join(name + ".png")) != OK or failed
	var crop_rect := Rect2i(470, 95, 340, 210)
	if name.ends_with("-plain"):
		_check(not w.is_ground_loading(), "%s ground is ready" % name)
		var group := _cohort_bounds()
		var markers := _mixed_marker_bounds(picture, group.grow(56))
		var bounds: Rect2i = markers.bounds
		_check(cohort.size() == 24 and group.has_area() and markers.cyan >= 100 \
			and markers.pink >= 100 and crop_rect.grow(-12).encloses(bounds),
			"%s 24-unit group=%s marker=%s cyan=%d pink=%d crop=%s" % [
				name, group, bounds, markers.cyan, markers.pink, crop_rect])
	if name == "full-after-e":
		var impact := w.gfx_fx().impact if w.gfx_fx() != null else null
		var live := -1
		var bolts := -1
		var shocks := -1
		var electric := -1
		var flash := -1.0
		if impact != null:
			live = 0
			for pool: LegionFxPool in impact.get("_pools"):
				live += pool.n
			bolts = (impact.get("_bolts") as Array).size()
			shocks = (impact.get("_shocks") as Array).size()
			electric = impact.electrified_count()
			flash = float(impact.get("_screen_t"))
		_check(impact != null and live == 0 and bolts == 0 and shocks == 0 \
			and electric == 0 and flash <= 0.0,
			"after-e has no transient Impact FX (pools=%d bolts=%d shocks=%d electric=%d flash=%.3f)" % [
				live, bolts, shocks, electric, flash])
	if name.ends_with("-after-e"):
		var item_fx := w.get_node_or_null("ItemFx") as LegionItemFx
		var item_visuals := (item_fx.get("_vfx") as Array).size() if item_fx != null else -1
		var hazards := 0
		var hasted := 0
		var haste_left := 0.0
		for side in w.sides:
			hazards += side.items.hazards.size()
			hasted += side.hero.hasted().size()
			haste_left = maxf(haste_left, float(side.hero.get("_haste_left")))
		_check(item_fx != null and item_visuals == 0 and hazards == 0 \
			and hasted == 0 and haste_left <= 0.0,
			"%s item/hero effects settled (hazards=%d item_vfx=%d hasted=%d haste_left=%.3f now=%.3f)" % [
				name, hazards, item_visuals, hasted, haste_left, w.now])
	var crop := picture.get_region(crop_rect)
	failed = crop.save_png(out.path_join(name + "-mixed-crop.png")) != OK or failed
	picture.convert(Image.FORMAT_L8)
	failed = picture.save_png(out.path_join(name + "-gray.png")) != OK or failed
	print("PVP_SIDE_SHOT " + name)


## Позиции только 24 бойцов этого снимка: маркеры построек не относятся к группе.
func _cohort_bounds() -> Rect2i:
	var lo := Vector2i(100000, 100000)
	var hi := Vector2i(-100000, -100000)
	for ref in cohort:
		var unit := ref.get_ref() as Legionnaire
		if not is_instance_valid(unit):
			continue
		var p := Vector2i(w.world_to_screen(unit.position).round())
		lo = Vector2i(mini(lo.x, p.x), mini(lo.y, p.y))
		hi = Vector2i(maxi(hi.x, p.x), maxi(hi.y, p.y))
	return Rect2i(lo, hi - lo + Vector2i.ONE) if hi.x >= lo.x else Rect2i()


## Ищем реальные цветные пиксели внутри области группы, отсекая боковые постройки.
func _mixed_marker_bounds(picture: Image, area: Rect2i) -> Dictionary:
	var size := picture.get_size()
	var left := maxi(0, area.position.x)
	var right := mini(size.x, area.end.x)
	var top := maxi(0, area.position.y)
	var bottom := mini(size.y, area.end.y)
	var lo := Vector2i(right, bottom)
	var hi := Vector2i(left, top)
	var cyan_n := 0
	var pink_n := 0
	for y in range(top, bottom):
		for x in range(left, right):
			var c := picture.get_pixel(x, y)
			var cyan := c.g > 0.51 and c.g > c.r * 1.4 and c.g > c.b * 1.15
			var pink := c.r > 0.51 and c.b > 0.39 and c.g < c.r * 0.7 \
				and c.b > c.g * 1.15
			if cyan or pink:
				cyan_n += int(cyan)
				pink_n += int(pink)
				lo.x = mini(lo.x, x)
				lo.y = mini(lo.y, y)
				hi.x = maxi(hi.x, x)
				hi.y = maxi(hi.y, y)
	return {"bounds": Rect2i(lo, hi - lo + Vector2i.ONE) if cyan_n + pink_n >= 200 \
		else Rect2i(), "cyan": cyan_n, "pink": pink_n}


func _check(ok: bool, detail: String) -> void:
	checks += 1
	passed += int(ok)
	failed = failed or not ok
	print("PVP_SIDE_CHECK %s %s" % ["PASS" if ok else "FAIL", detail])
