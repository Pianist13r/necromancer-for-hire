extends SceneTree
##
## Кадры приёмки предметов (не тест гейта): элитный в волне, выпадение по кадрам, карточка
## «Новый предмет», полоска с предметами, синергией и подсказкой, вспышки особых предметов.
## Окном, не headless (нужен настоящий рендер):
##
##   "$GODOT" --path godot --fixed-fps 60 --script res://tests/legion_items_shots.gd
##       -- --mute --out C:/AI/necro/batches/legion/items
##
## Настоящая мышь и клавиатура владельца на время прогона глушатся (_Mute); сохранение —
## временное (user://legion_items_shots.cfg).
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


func _wave_foe(type: String, road: String, at: float, elite: bool) -> Foe:
	if elite:
		w.dev["elite"] = "1"
	else:
		w.dev["elite"] = "0"
	var path := w.road_remainder(road, at)
	var f := w.spawn_foe_on_path(type, path, path[0], false, {"wave": 1})
	w.dev.erase("elite")
	return f


func _run() -> void:
	var argv := OS.get_cmdline_user_args()
	var i := argv.find("--out")
	_out = argv[i + 1] if i >= 0 and i + 1 < argv.size() else "user://items_shots"
	DirAccess.make_dir_recursive_absolute(_out)
	Campaign.set_save_path("user://legion_items_shots.cfg")
	Campaign.reset()
	root.add_child(_Mute.new())
	w = (load("res://scenes/legion_world.tscn") as PackedScene).instantiate() as LegionWorld
	w.embedded = true
	root.add_child(w)
	await _tick(2)
	w.dev["no_waves"] = "1"
	w.start_map("fork")
	await _tick(150)   # вводный тост карты уходит, армия у Котла
	w.dev_invuln = true
	# ── 1. элитный в волне: колонна обычных и двое элитных (зомби и курьер)
	for k in 6:
		_wave_foe("zombie", "north", 360.0 + k * 34.0, false)
	var elite := _wave_foe("zombie", "north", 330.0, true)
	_wave_foe("beetle", "south", 420.0, true)
	for k in 4:
		_wave_foe("signer" if k == 2 else "zombie", "south", 450.0 + k * 36.0, false)
	await _tick(50)
	await _shot("1_elite_wave.png")
	# ── 2. выпадение: элитного добивают, предмет вылетает, лежит, летит в полоску
	w.dev_invuln = false
	w.dev["drop"] = "1"
	var hold_pos := elite.position
	elite.take_damage(elite.hp + 1.0, hold_pos + Vector2(20, 0))
	w.dev.erase("drop")
	w.dev_invuln = true
	var marks := [[8, "2a_drop_arc.png"], [18, "2b_drop_arc_top.png"], [55, "2c_drop_rest.png"],
		[110, "2d_drop_fly.png"], [138, "2e_landed_card.png"], [200, "3_card.png"]]
	var t := 0
	for m in marks:
		await _tick(int(m[0]) - t)
		t = int(m[0])
		await _shot(String(m[1]))
	# ── 4. полоска: ещё предметы (без выпадения) + синергия, подсказка по наведению
	for id in [&"wholesale_ink", &"megaphone", &"lightning_rod", &"clip_of_fate"]:
		w.items.grant(id)
	await _tick(260)   # карточки доиграли
	var bar := w.hud.get_node("ItemBar") as LegionItemBar
	await _move(bar.slot_rect(1).get_center())
	await _tick(4)
	await _shot("4_bar_tooltip.png")
	var syn_slot := bar.shown.size()
	await _move(bar.slot_rect(syn_slot).get_center())
	await _tick(4)
	await _shot("4b_bar_synergy_tip.png")
	await _move(Vector2(640, 360))
	# ── 5. карточка синергии при сборе набора с выпадения
	w.items.grant(&"burning_seal", Vector2(600, 330))
	w.items.grant(&"prolongation", Vector2(640, 330))
	await _tick(150)
	for k in 700:
		if String(bar.current_card().get("title", "")).begins_with("Синергия"):
			break
		await _tick(1)
	await _tick(12)
	await _shot("5_synergy_card.png")
	# ── 6. вспышки особых предметов: горящая печать, взрыв, молния, оглушение
	w.items.effects.blast(Vector2(760, 250), 60.0, 0.0)
	w.items.add_hazard({"pos": Vector2(620, 420), "kind": &"burn", "r": 88.0, "t": 3.0, "dps": 0.0})
	w.items.add_hazard({"pos": Vector2(900, 470), "kind": &"stun", "r": 40.0, "t": 3.0, "stun": 0.0})
	w.items.fx_event.emit(&"bolt", {"from": Vector2(700, 150), "to": Vector2(820, 300)})
	w.items.effects.stun_area(Vector2(1000, 300), 90.0, 0.0)
	w.items.fx_event.emit(&"text", {"pos": Vector2(760, 220), "text": "+25 маны",
		"color": LegionItemEffects.COLOR_MANA})
	await _tick(6)
	await _shot("6_item_fx.png")
	# ── 7. экономная графика: тот же элитный и выпадение, упрощённый вид
	Settings.economy_override = "on"
	w.items.hazards.clear()
	var e2 := _wave_foe("zombie", "north", 500.0, true)
	await _tick(30)
	w.dev_invuln = false
	w.dev["drop"] = "1"
	e2.take_damage(e2.hp + 1.0, e2.position)
	w.dev.erase("drop")
	await _tick(30)
	await _shot("7_economy_drop.png")
	Settings.economy_override = ""
	# ── 8. шпаргалка паузы и «Как играть» → «Предметы»
	var layer := CanvasLayer.new()
	layer.layer = 20
	root.add_child(layer)
	layer.add_child(LegionPause.new())
	await _tick(4)
	await _shot("8_pause_cheatsheet.png")
	layer.queue_free()
	var layer2 := CanvasLayer.new()
	layer2.layer = 20
	root.add_child(layer2)
	var howto := HowtoLegion.new()
	layer2.add_child(howto)
	await _tick(4)
	for n in howto.find_children("*", "ScrollContainer", true, false):
		var sc := n as ScrollContainer
		for m in howto.find_children("*", "Label", true, false):
			var l := m as Label
			if l.text.begins_with("Элитный враг"):
				sc.scroll_vertical = int(l.get_global_rect().position.y - sc.get_global_rect().position.y) - 60
	await _tick(4)
	await _shot("9_howto_items.png")
	Campaign.reset()
	quit(0)
