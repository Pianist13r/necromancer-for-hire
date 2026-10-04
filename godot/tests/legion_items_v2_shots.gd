extends SceneTree
##
## Кадры приёмки артефактов v2 (не тест гейта, D-0927-163): носитель в колонне, импульс
## находки, молния Ку до/после («Скрепка», «Громоотвод»), печати и огненный след бойцов,
## чернила, позолота и призрачные линии договоров, огоньки построек и Котёл, Аврал и «Сбор»,
## внештатники с фитилём, полоска с подсказкой, всё сразу в бою, экономная графика.
## Окном, не headless (нужен настоящий рендер):
##
##   "$GODOT" --path godot --fixed-fps 60 --script res://tests/legion_items_v2_shots.gd
##       -- --mute --out C:/AI/necro/batches/procgen/items-v2/shots
##
## Мышь и клавиатура владельца на время прогона глушатся (_Mute); сохранение — временное.
##

const DEVICE := 7

var w: LegionWorld
var _out := ""


class _Mute:
	extends Node

	func _input(event: InputEvent) -> void:
		if event.device != DEVICE and (event is InputEventMouse or event is InputEventKey):
			get_viewport().set_input_as_handled()


func _initialize() -> void:
	_run.call_deferred()


func _tick(n := 1) -> void:
	for i in n:
		await process_frame


func _shot(name: String) -> void:
	await _tick(1)
	await RenderingServer.frame_post_draw
	var img := root.get_texture().get_image()
	if img.get_size() != Vector2i(1280, 720):
		img.resize(1280, 720, Image.INTERPOLATE_LANCZOS)
	img.save_png(_out.path_join(name))
	print("кадр ", name)


func _move(p: Vector2) -> void:
	var ev := InputEventMouseMotion.new()
	ev.device = DEVICE
	ev.position = root.get_final_transform() * p
	ev.global_position = ev.position
	Input.parse_input_event(ev)
	await _tick(1)


func _wave_foe(type: String, road: String, at: float, elite := false, carrier := false) -> Foe:
	var path := w.road_remainder(road, at)
	w.dev["elite"] = "0"
	var f := w.spawn_foe_on_path(type, path, path[0], false, {"wave": 1})
	w.dev.erase("elite")
	if elite or carrier:
		f.make_elite(carrier)
	return f


func _fresh(items: Array = [], map_id := "fork") -> void:
	w.dev["no_waves"] = "1"
	w.dev.erase("items")
	if not items.is_empty():
		w.dev["items"] = ",".join(items.map(func(x: Variant) -> String: return String(x)))
	w.start_map(map_id)
	w.dev_invuln = false   # неуязвимость глушит и урон по врагам — эффектам нужен настоящий урон
	await _tick(90)   # вводный тост уходит, армия выходит из Котла


func _group(center: Vector2, n: int, hp := 400.0) -> Array[Foe]:
	var out: Array[Foe] = []
	for k in n:
		var at := center + Vector2(float(k % 3) * 34.0, float(k / 3) * 30.0)
		var f := w.spawn_foe_on_path("zombie", PackedVector2Array([at, at + Vector2(-1, 0)]), at)
		f.hp = hp
		f.max_hp = hp
		out.append(f)
	return out


func _run() -> void:
	var argv := OS.get_cmdline_user_args()
	var i := argv.find("--out")
	_out = argv[i + 1] if i >= 0 and i + 1 < argv.size() else "user://items_v2_shots"
	DirAccess.make_dir_recursive_absolute(_out)
	Campaign.set_save_path("user://legion_items_v2_shots.cfg")
	Campaign.reset()
	root.add_child(_Mute.new())
	w = (load("res://scenes/legion_world.tscn") as PackedScene).instantiate() as LegionWorld
	w.embedded = true
	root.add_child(w)
	await _tick(2)
	await _carrier_and_gain()
	await _bolts()
	await _units()
	await _contracts()
	await _buildings()
	await _haste_rally()
	await _vassals()
	await _bar_and_all()
	await _economy()
	Campaign.reset()
	quit(0)


# ── 1–2. носитель и импульс находки ─────────────────────────────────────────

func _carrier_and_gain() -> void:
	await _fresh()
	for k in 6:
		_wave_foe("zombie", "north", 360.0 + k * 34.0)
	var carrier := _wave_foe("zombie", "north", 330.0, false, true)
	_wave_foe("beetle", "south", 420.0, true)
	for k in 4:
		_wave_foe("zombie", "south", 450.0 + k * 36.0)
	await _tick(50)
	await _shot("1_carrier_in_column.png")
	w.dev_invuln = false
	var pos := carrier.position
	carrier.take_damage(carrier.hp + 1.0, pos + Vector2(20, 0))
	w.dev_invuln = true
	var marks := [[3, "2a_gain_flash.png"], [14, "2b_gain_ring.png"], [60, "2c_rest.png"],
		[118, "2d_landed_card_pulse.png"], [150, "2e_card_late.png"]]
	var t := 0
	for m in marks:
		await _tick(int(m[0]) - t)
		t = int(m[0])
		await _shot(String(m[1]))


# ── 3. молния Ку до и после ─────────────────────────────────────────────────

func _bolts() -> void:
	var sets := [[[], "3a_bolt_plain.png"], [[&"clip_of_fate"], "3b_bolt_clip.png"],
		[[&"clip_of_fate", &"lightning_rod"], "3c_bolt_clip_rod.png"]]
	for s: Array in sets:
		await _fresh(s[0])
		var foes := _group(Vector2(700, 300), 9, 30.0 if (s[0] as Array).has(&"lightning_rod") else 400.0)
		await _tick(2)
		w.hero.cast(LegionHero.SLOT_Q, foes[0].position)
		await _tick(3)
		await _shot(String(s[1]))


# ── 4. бойцы: печати и огненный след натиска ────────────────────────────────

func _units() -> void:
	await _fresh([&"exploding_stamp", &"burning_seal"])
	var c := w.contracts.add_contract(PackedVector2Array([Vector2(300, 280), Vector2(300, 460)]), 1,
		false)
	await _tick(200)   # бойцы встали в строй
	await _shot("4z_units_posted_seals.png")
	for s in c.seg_count():
		w.release_segment(c, s, &"manual")
	await _tick(22)
	await _shot("4a_units_seal_fire_trail.png")
	await _tick(40)
	await _shot("4b_fire_trail_after.png")


# ── 5. договоры: чернила, позолота, призрачная линия ────────────────────────

func _contracts() -> void:
	await _fresh([&"wholesale_ink", &"golden_pen", &"prolongation"])
	w.contracts.add_contract(PackedVector2Array([Vector2(300, 280), Vector2(330, 370),
		Vector2(300, 460)]), 1, false)
	var c2 := w.contracts.add_contract(PackedVector2Array([Vector2(820, 200), Vector2(820, 500)]), 1,
		false)
	await _tick(40)
	w.release_segment(c2, 0, &"melt")
	w.release_segment(c2, 1, &"melt")
	await _tick(12)
	await _shot("5_contract_ink_gild_ghost.png")
	await _fresh([])
	w.contracts.add_contract(PackedVector2Array([Vector2(300, 280), Vector2(330, 370),
		Vector2(300, 460)]), 1, false)
	await _tick(40)
	await _shot("5z_contract_plain.png")


# ── 6. постройки и Котёл ────────────────────────────────────────────────────

func _buildings() -> void:
	await _fresh([&"staff_schedule", &"soul_magnet", &"cauldron_ward"])
	w.staff.add_souls(500)
	for p in w.staff.plots.slice(0, 2):
		w.staff.build(p, LegionCfg.KIND_LABORER)
	await _tick(30)
	await _shot("6_buildings_cauldron.png")


# ── 7. Аврал и «Сбор» ───────────────────────────────────────────────────────

func _haste_rally() -> void:
	await _fresh([&"overtime_sheet", &"megaphone"])
	_group(Vector2(620, 260), 4)
	w.hero.cast(LegionHero.SLOT_E, w.cauldron_pos + Vector2(80, 0))
	await _tick(8)
	await _shot("7a_rush_orange.png")
	await _tick(30)
	await _shot("7b_haste_trail.png")
	w.rally_cd = 0.0
	w.rally(Vector2(560, 300))
	await _tick(6)
	await _shot("7c_rally_horn.png")


# ── 8. внештатники с фитилём ────────────────────────────────────────────────

func _vassals() -> void:
	await _fresh([&"temp_contract"])
	var foes := _group(Vector2(640, 300), 5, 1.0)
	for f in foes:
		f.take_damage(5.0, f.position)
	await _tick(4)
	w.hero.cast(LegionHero.SLOT_W, Vector2(660, 320))
	await _tick(20)
	await _shot("8_vassals_fuse.png")


# ── 9. полоска и всё сразу в бою ────────────────────────────────────────────

func _bar_and_all() -> void:
	var all: Array = []
	for id in LegionItemDb.ids():
		all.append(id)
	w.dev.erase("no_waves")
	w.dev["items"] = ",".join(all.map(func(x: Variant) -> String: return String(x)))
	w.args["bot"] = "selective"
	w.start_map("fork")
	w.dev_invuln = true
	await _tick(60 * 40)   # 40 с боя бота: волны, линии, натиск, навыки
	await _shot("9a_battle_all_items.png")
	var bar := w.hud.get_node("ItemBar") as LegionItemBar
	await _move(bar.slot_rect(0).get_center())
	await _tick(4)
	await _shot("9b_bar_tooltip.png")
	await _move(Vector2(640, 360))
	w.args.erase("bot")
	w.dev.erase("items")


func _economy() -> void:
	Settings.economy_override = "on"
	await _fresh([&"clip_of_fate", &"exploding_stamp", &"staff_schedule", &"soul_magnet"])
	var foes := _group(Vector2(700, 300), 6)
	w.hero.cast(LegionHero.SLOT_Q, foes[0].position)
	await _tick(3)
	await _shot("10_economy.png")
	Settings.economy_override = ""
