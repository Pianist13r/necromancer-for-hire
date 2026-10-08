class_name LegionItemFx
extends Node2D
##
## Вид особых предметов в мире: взрывы печатей, молнии «Громоотвода», оглушающие круги, эхо
## договора, души, летящие в Котёл, всплывающие «+25 маны», и опасные зоны (горящие и
## оглушающие печати). Чистый вид: механика уже случилась в LegionItemEffects, сюда приходит
## только сигнал items.fx_event. Время — часы мира (пауза и стоп-кадр замораживают вспышки),
## дрожание молний и искры — свой ГСЧ. Экономная графика: те же формы без слоёв свечения.
##

const HEAL_T := 0.6
const TEXT_T := 0.9
const TEXT_FONT := 16
const ECHO_T := 0.4

var world: LegionWorld = null
var _vfx: Array[Dictionary] = []
var _rng := RandomNumberGenerator.new()
var _drawn := false
## Ограничиваем только вид; механические счётчики продолжают учитывать все события.
var _recent: Dictionary = {}


func setup(w: LegionWorld) -> void:
	world = w
	name = "ItemFx"
	_rng.randomize()
	w.items.fx_event.connect(_on_fx)
	w.items.cleared.connect(func() -> void: _vfx.clear())
	w.match_started.connect(func(_id: String) -> void: _connect_sides())


func _connect_sides() -> void:
	for side in world.sides:
		if not side.items.fx_event.is_connected(_on_fx):
			side.items.fx_event.connect(_on_fx)


func _on_fx(kind: StringName, data: Dictionary) -> void:
	if kind == &"used":
		var key := "%s:%s" % [data.get("side", 0), data.get("id", &"")]
		var previous := float(_recent.get(key, -INF))
		if world.now >= previous and world.now - previous < 0.8:
			return
		_recent[key] = world.now
	var d := data.duplicate()
	d["kind"] = kind
	d["t0"] = world.now
	d["seed"] = _rng.randi()
	_vfx.append(d)


func _life(kind: StringName) -> float:
	match kind:
		&"bolt":
			return CfgItems.FX_BOLT_T
		&"heal":
			return HEAL_T
		&"text":
			return TEXT_T
		&"echo", &"used":
			return ECHO_T if kind == &"echo" else 0.8
		&"gain":
			return CfgItems.GAIN_RING_T
	return CfgItems.FX_FLASH_T


func _process(_delta: float) -> void:
	for i in range(_vfx.size() - 1, -1, -1):
		if world.now - float(_vfx[i]["t0"]) > _life(_vfx[i]["kind"]) or world.now < float(_vfx[i]["t0"]):
			_vfx.remove_at(i)
	var busy := not _vfx.is_empty()
	for side in world.sides:
		busy = busy or (side.items != null and not side.items.hazards.is_empty())
	if busy or _drawn:
		queue_redraw()   # ещё раз после последней вспышки — стереть её
	_drawn = busy


func _draw() -> void:
	# Без вспышек сохраняем кольца, молнии, значки и границы опасных зон.
	var eco := Settings.is_economy_graphics() or not Settings.is_flashes_enabled()
	for side in world.sides:
		if side.items != null:
			for h in side.items.hazards:
				_draw_hazard(h, eco)
	for d in _vfx:
		var k := clampf((world.now - float(d["t0"])) / _life(d["kind"]), 0.0, 1.0)
		match d["kind"]:
			&"blast":
				_draw_blast(d, k, eco)
			&"stun":
				_draw_stun(d["pos"], float(d["r"]), 1.0 - k, eco,
					d.get("color", LegionItemEffects.COLOR_STUN))
			&"gain":
				_draw_gain(d, k, eco)
			&"bolt":
				_draw_bolt(d, k, eco)
			&"heal":
				var p: Vector2 = (d["from"] as Vector2).lerp(d["to"], k * k * (3.0 - 2.0 * k))
				p.y -= sin(k * PI) * 50.0
				if not eco:
					draw_circle(p, 9.0, Color(LegionItemEffects.COLOR_SOUL, 0.3 * (1.0 - k)))
				draw_circle(p, 4.5, Color(0.8, 0.92, 1.0, 1.0 - k * 0.5))
			&"echo":
				_draw_echo(d, k)
			&"text":
				var at: Vector2 = d["pos"] + Vector2(0.0, -28.0 * k)
				var c: Color = d["color"]
				LegionUi.draw_text(self, at, String(d["text"]), PvpView.fs(world, TEXT_FONT),
					Color(c, 1.0 - k * k), LegionUi.FONT_TITLE)
			&"used":
				_draw_used(d, k)


## Значок над местом эффекта соединяет событие с постоянным инвентарём, без текстового спама.
func _draw_used(d: Dictionary, k: float) -> void:
	var id := StringName(d["id"])
	var icon := LegionIcons.tex(LegionItemDb.icon_name(id))
	if icon == null:
		return
	var at: Vector2 = d["pos"] + Vector2(0, -38.0 - 12.0 * k)
	var c: Color = LegionItemDb.look(id).get("color", LegionUi.GOLD)
	var half := 18.0 * (1.0 + 0.15 * sin(k * PI))
	draw_circle(at, half + 5, Color(LegionUi.PAPER_HI, 0.95 * (1.0 - k)))
	draw_texture_rect(icon, Rect2(at - Vector2.ONE * half, Vector2.ONE * half * 2.0),
		false, Color(1, 1, 1, 1.0 - k))
	draw_arc(at, half + 5, -PI * 0.5, TAU * (1.0 - k) - PI * 0.5, 24,
		Color(c, 1.0 - k), 2.0, true)



func _draw_blast(d: Dictionary, k: float, eco: bool) -> void:
	var at: Vector2 = d["pos"]
	var r := float(d["r"])
	var c: Color = d["color"]
	if not eco:
		draw_circle(at, r * (0.4 + 0.6 * k), Color(c, 0.35 * (1.0 - k)))
	draw_arc(at, r * (0.5 + 0.5 * k), 0.0, TAU, 40, Color(c, 1.0 - k), 4.0 * (1.0 - k) + 1.0, true)
	# штамп печати в центре — «взорвалась печать», а не просто вспышка; цвет — артефакта,
	# темнее (vfx-clarity 29.09: красный штамп у своих читался «бьют нас»)
	draw_arc(at, r * 0.28, 0.0, TAU, 20, Color(c.darkened(0.45), 1.0 - k), 3.0, true)


## Находка: белая вспышка, кольцо цвета редкости расходится от носителя, лучи — «выпало!».
func _draw_gain(d: Dictionary, k: float, eco: bool) -> void:
	var at: Vector2 = d["pos"]
	var c: Color = d["color"]
	var e := 1.0 - pow(1.0 - k, 3.0)   # ease-out: кольцо срывается быстро и оседает
	var r := CfgItems.GAIN_RING_R * e
	if not eco and k < 0.25:
		draw_circle(at, 40.0 * (1.0 - k * 4.0) + 10.0, Color(1.0, 1.0, 1.0, 0.6 * (1.0 - k * 4.0)))
	draw_arc(at, r, 0.0, TAU, 48, Color(c, 1.0 - k), 5.0 * (1.0 - k) + 1.0, true)
	draw_arc(at, r * 0.7, 0.0, TAU, 40, Color(c.lerp(Color.WHITE, 0.5), 0.7 * (1.0 - k)), 2.0, true)
	if eco:
		return
	for i in 12:
		var dir := Vector2.from_angle(TAU * float(i) / 12.0 + float(d["seed"] % 7))
		draw_line(at + dir * r * 0.75, at + dir * (r * 0.75 + 26.0 * (1.0 - k)),
			Color(c.lerp(Color.WHITE, 0.4), 1.0 - k), 3.0, true)


func _draw_stun(at: Vector2, r: float, a: float, eco: bool,
		col: Color = LegionItemEffects.COLOR_STUN) -> void:
	draw_arc(at, r, 0.0, TAU, 40, Color(col, 0.9 * a), 3.0, true)
	if not eco:
		draw_circle(at, r, Color(col, 0.12 * a))
	for i in 5:
		var ang := TAU * float(i) / 5.0 + world.now * 3.0
		draw_circle(at + Vector2(cos(ang), sin(ang)) * r * 0.7, 3.0,
			Color(Color.WHITE.lerp(col, 0.4), a))


func _draw_bolt(d: Dictionary, k: float, eco: bool) -> void:
	var a: Vector2 = d["from"]
	var b: Vector2 = d["to"] + Vector2(0.0, -18.0)
	var rng := RandomNumberGenerator.new()
	rng.seed = int(d["seed"])
	var pts := PackedVector2Array()
	var n := 7
	var normal := (b - a).orthogonal().normalized()
	for i in n + 1:
		var p := a.lerp(b, float(i) / n)
		if i > 0 and i < n:
			p += normal * rng.randf_range(-10.0, 10.0)
		pts.append(p)
	var col: Color = d.get("color", LegionItemEffects.COLOR_BOLT)
	if not eco:
		draw_polyline(pts, Color(col, 0.5 * (1.0 - k)), 8.0, true)
	draw_polyline(pts, Color(col.lerp(Color.WHITE, 0.7), 1.0 - k), 2.5, true)


func _draw_echo(d: Dictionary, k: float) -> void:
	var at: Vector2 = d["pos"]
	var dir: Vector2 = d["dir"]
	var side := dir.orthogonal() * float(d["half"])
	var far := dir * float(d["depth"]) * (0.3 + 0.7 * k)
	var poly := PackedVector2Array([at - side, at + side, at + side + far, at - side + far])
	if Settings.is_flashes_enabled():
		draw_colored_polygon(poly, Color(0.75, 0.6, 1.0, 0.28 * (1.0 - k)))
	else:
		poly.append(poly[0])
		draw_polyline(poly, Color(0.75, 0.6, 1.0, 1.0 - k), 2.0, true)
	draw_line(at - side + far, at + side + far, Color(0.9, 0.8, 1.0, 1.0 - k), 3.0, true)


func _draw_hazard(h: Dictionary, eco: bool) -> void:
	var at: Vector2 = h["pos"]
	var r := float(h["r"])
	var a := clampf(float(h["t"]) / 0.4, 0.0, 1.0)   # последние доли секунды — гаснет
	if h["kind"] == &"trail":
		# огненный след натиска: плоское тлеющее пятно и два язычка, без кольца печати —
		# цепочка таких пятен читается следом, а не россыпью печатей (кадр 27.09)
		var life := clampf(float(h["t"]) / float(h["t0"]), 0.0, 1.0)
		var flick := 1.0 if eco else 0.8 + 0.2 * sin(world.now * 19.0 + at.x * 0.3)
		draw_set_transform(at, 0.0, Vector2(1.0, 0.45))
		draw_circle(Vector2.ZERO, r * (0.6 + 0.4 * life), Color(LegionItemEffects.COLOR_FIRE, 0.28 * a))
		draw_set_transform(Vector2.ZERO)
		for side in [-0.35, 0.3]:
			var base := at + Vector2(side * r, 0.0)
			var fh := r * 0.9 * life * flick
			draw_colored_polygon(PackedVector2Array([base + Vector2(-4.0, 0.0),
				base + Vector2(0.0, -fh), base + Vector2(4.0, 0.0)]),
				Color(1.0, 0.55 + 0.3 * life, 0.15, 0.9 * a))
		return
	if h["kind"] == &"burn":
		var flick := 1.0 if eco else 0.85 + 0.15 * sin(world.now * 17.0 + at.x)
		draw_circle(at, r * flick, Color(LegionItemEffects.COLOR_FIRE, 0.22 * a))
		draw_arc(at, r, 0.0, TAU, 36, Color(1.0, 0.35, 0.1, 0.9 * a), 3.0, true)
		draw_arc(at, r * 0.45, 0.0, TAU, 20, Color(0.75, 0.12, 0.1, 0.9 * a), 3.0, true)
		if not eco:
			var rng := RandomNumberGenerator.new()
			rng.seed = int(at.x * 7.0 + at.y * 13.0) + int(world.now * 12.0)
			for i in 4:
				var p := at + Vector2(rng.randf_range(-r, r) * 0.7, rng.randf_range(-r, r) * 0.5)
				draw_circle(p, rng.randf_range(2.0, 4.0), Color(1.0, 0.75, 0.3, 0.8 * a))
	elif h["kind"] == &"stun":
		_draw_stun(at, r, a * 0.8, eco)
	# призрачные линии рисует постоянный вид «Пролонгации» (LegionItemLook)
