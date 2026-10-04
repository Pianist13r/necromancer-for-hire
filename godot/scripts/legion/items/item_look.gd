class_name LegionItemLook
extends Node2D
##
## Постоянный вид артефактов (D-0927-163, Игорь: «чтобы менялись анимации… если он влияет на
## молнию — чтобы молния цвет меняла»). Этот слой рисует то, что не принадлежит одной вспышке:
## бомбочка на груди бойцов («Взрывная печать»), пламя у ступней бегущих натиском («Сургуч
## с огоньком»), фитиль внештатников («Срочный договор»), призрачные участки («Пролонгация»),
## парные огоньки на крышах («Штатное расписание»), пламя душ над Котлом и кольцо печати у его
## подножия. Молнию, чернила, Аврал и «Сбор» красят их собственные слои (см. item_db.gd, look).
##
## Чистый вид: читает мир, ничего в него не пишет, кроме отметки items.note_look (тест: вид лёг
## на объект). Время — часы мира (пауза замораживает пламя), без ГСЧ: дрожание — от позиции и
## часов. Импульс получения (items.pulse) — тот же вид ярче и крупнее ~1,5 с. Экономная графика —
## те же формы без слоёв свечения.
##

const GLOW_A := 0.28
const FLICKER := 11.0

var world: LegionWorld = null
var _drawn := false
## Сторона, которую рисует _draw_side сейчас (PvP: у каждой свой инвентарь; одиночка — 0).
var _items: LegionItems
var _side := 0
## «Пролонгация»: следы, уже встреченные в этом бою, и те из них, что подписаны (по порядку
## появления — первые CfgItems.GHOST_CAPTIONS). Сравнение по ссылке на словарь опасной зоны.
var _ghosts_seen: Array[Dictionary] = []
var _ghosts_captioned: Array[Dictionary] = []
var _ghost_icon: Texture2D = null
var _captions_used := 0   ## сколько раз за бой след подписан (не больше GHOST_CAPTIONS)
## Земляной слой: кольцо «Печати на Котле» лежит ПОД Котлом и бойцами (ребёнок Contracts, тот
## стоит перед Entities), а сам этот слой — над фигурами. Игорь 29.09: кольцо перечёркивало
## низ Котла.
var _ground: Node2D = null


func setup(w: LegionWorld) -> void:
	world = w
	name = "ItemLook"
	_ghost_icon = LegionIcons.tex(LegionItemDb.icon_name(&"prolongation"))
	_ground = Node2D.new()
	_ground.name = "ItemLookGround"
	_ground.draw.connect(_draw_ground)
	# ребёнок поля договоров: рисуется после рун, но до Entities — под Котлом и бойцами. Отдельным
	# ребёнком мира нельзя: порядок слоёв мира — сплошной отрезок (legion_gfx_test)
	w.contracts.add_child(_ground)
	w.items.cleared.connect(func() -> void:
		_ghosts_seen.clear()
		_ghosts_captioned.clear()
		_captions_used = 0)


func _process(_delta: float) -> void:
	if world == null or world.items == null:
		return
	var busy := false
	for side in world.sides:
		var owned := side.items
		if owned == null:
			continue
		for target: StringName in [&"unit", &"vassal", &"building", &"cauldron"]:
			busy = busy or not owned.look(target).is_empty()
		busy = busy or owned.hazard_count(&"ghost") > 0
	if busy or _drawn:
		queue_redraw()   # ещё раз после последнего — стереть
		_ground.queue_redraw()
	_drawn = busy


func _draw() -> void:
	if world == null or world.items == null or world.phase == LegionWorld.Phase.MENU:
		return
	var eco := Settings.is_economy_graphics()
	for side in world.sides:
		_items = side.items
		_side = side.index
		if _items != null:
			_draw_side(eco)


func _draw_side(eco: bool) -> void:
	_draw_ghosts(eco)
	var cauldron := _items.look(&"cauldron")
	if not cauldron.is_empty():
		_draw_cauldron(cauldron, eco)
	var building := _items.look_of(&"building", &"flame")
	if not building.is_empty():
		_draw_buildings(building, eco)
	var unit := _items.look(&"unit")
	if not unit.is_empty():
		_draw_units(unit, eco)
	var vassal := _items.look_of(&"vassal", &"tint")
	if not vassal.is_empty():
		_draw_vassals(vassal, eco)


func _flick(seed_x: float, rate := FLICKER) -> float:
	return 0.85 + 0.15 * sin(world.now * rate + seed_x * 0.37)


## Язык пламени: капля острием вверх (h — высота), с белёсой сердцевиной.
func _flame(at: Vector2, h: float, col: Color, eco: bool, sway: float) -> void:
	var w := h * 0.42
	var tip := at + Vector2(sway * h * 0.25, -h)
	var pts := PackedVector2Array([
		at + Vector2(-w, 0.0), at + Vector2(-w * 0.7, -h * 0.45), tip,
		at + Vector2(w * 0.7, -h * 0.45), at + Vector2(w, 0.0), at + Vector2(0.0, h * 0.22),
	])
	if not eco:
		draw_circle(at + Vector2(0.0, -h * 0.35), h * 0.85, Color(col, GLOW_A * 0.6))
	draw_colored_polygon(pts, col)
	var core := PackedVector2Array([
		at + Vector2(-w * 0.45, 0.0), tip.lerp(at, 0.45), at + Vector2(w * 0.45, 0.0),
	])
	draw_colored_polygon(core, col.lerp(Color(1.0, 0.97, 0.8), 0.65))


## Бомбочка с фитилём (r — радиус корпуса): «рванёт» — и у бойцов «Взрывной печати», и у
## внештатников «Срочного договора». Четырёхлучевую искру не берём: это знак золотого участка
## «Точно!» (LegionIntuit._sparkle), а метка артефакта не должна обещать щелчок.
func _bomb(at: Vector2, r: float, spark_col: Color, eco: bool, glow := 1.0) -> void:
	draw_circle(at, r + 1.2, Color(0.95, 0.9, 0.8, 0.85))
	draw_circle(at, r, Color(0.08, 0.06, 0.06, 0.95))
	draw_circle(at + Vector2(-r, -r) * 0.35, r * 0.28, Color(1.0, 1.0, 1.0, 0.5))
	var fuse_a := at + Vector2(r * 0.5, -r * 0.7)
	var fuse_b := at + Vector2(r * 1.15, -r * 1.65)
	draw_line(fuse_a, fuse_b, Color(0.45, 0.32, 0.18), maxf(1.5, r * 0.35), true)
	var spark := fuse_b + Vector2(r * 0.1, -r * 0.2)
	if not eco:
		draw_circle(spark, r * 1.3 * glow, Color(spark_col, GLOW_A * 1.5))
	draw_circle(spark, maxf(1.6, r * 0.5), spark_col)


# ── Бойцы ───────────────────────────────────────────────────────────────────

## Кому рисовать бомбочку «Взрывной печати» (тест vfx-clarity зовёт напрямую): пока печать
## готова — не больше CfgItems.BADGE_MAX бойцов, раненые первыми (взорвётся первый павший);
## печать перезаряжается — никому. PvP: у каждой стороны своя печать и свои бойцы.
func badge_units(side := 0) -> Array[Legionnaire]:
	var out: Array[Legionnaire] = []
	if world.now < float(world.items_of(side).state.get(&"stamp_ready", -INF)):
		return out
	for u in world.units:
		if u.side == side and u.alive and u.view != null:
			out.append(u)
	out.sort_custom(func(a: Legionnaire, b: Legionnaire) -> bool:
		return a.hp / maxf(1.0, a.max_hp) < b.hp / maxf(1.0, b.max_hp))
	if out.size() > CfgItems.BADGE_MAX:
		out.resize(CfgItems.BADGE_MAX)
	return out


func _draw_units(unit: Dictionary, eco: bool) -> void:
	var badge: Dictionary = unit.get(&"badge", {})
	var trail: Dictionary = unit.get(&"trail", {})
	var k := _items.pulse(&"unit")
	var n_badge := 0
	var n_trail := 0
	if not badge.is_empty():
		# B-200 (Игорь 29.09): красный круг на груди КАЖДОГО бойца читался «моих бьют»; искра,
		# что пришла ему на смену, повторяла золото «Точно!». Бомбочка у немногих — «рванёт»
		var col: Color = badge["color"]
		for u in badge_units(_side):
			var feet := u.position + Vector2(0.0, u.view.ground_px())
			var at := feet - Vector2(0.0, u.view.body_h * CfgItems.BADGE_LIFT)
			_bomb(at, CfgItems.BADGE_R * (1.0 + 0.8 * k), col, eco, _flick(u.position.x, 11.0))
			n_badge += 1
	for u in world.units:
		if u.side != _side or not u.alive or u.view == null:
			continue
		var feet := u.position + Vector2(0.0, u.view.ground_px())
		if not trail.is_empty() and (u.state == Legionnaire.State.CHARGE or k > 0.0):
			# пламя у ступней бегущего натиском (след оставляют пятна item_fx «trail»)
			var col: Color = trail["color"]
			var h := CfgItems.TRAIL_FLAME_H * (1.0 + 0.6 * k) * _flick(u.position.x)
			_flame(feet, h, col, eco, -0.6)
			n_trail += 1
	if n_badge > 0:
		_items.note_look(&"unit", &"badge")
	if n_trail > 0:
		_items.note_look(&"unit", &"trail")


## Окрас внештатника кладёт LegionHero.raise_corpses (tint); здесь — только фитиль.
func _draw_vassals(_tint: Dictionary, eco: bool) -> void:
	if world.hero_of(_side) == null:
		return
	var n := 0
	for v: Node2D in world.hero_of(_side).vassals():
		if not is_instance_valid(v):
			continue
		# фитиль над головой: искра горит, пока внештатник жив, — видно, что в конце рванёт
		# кадр 27.09: искра 2,6 px терялась — бомбочка с фитилём над плечом
		_bomb(v.position + Vector2(12.0, -44.0), 6.0, Color(1.0, 0.85, 0.35), eco,
			_flick(v.position.x, 23.0))
		n += 1
	if n > 0:
		_items.note_look(&"vassal", &"tint")


# ── Постройки и Котёл ───────────────────────────────────────────────────────

func _draw_buildings(flame: Dictionary, eco: bool) -> void:
	var col: Color = flame["color"]
	var k := _items.pulse(&"building")
	var n := 0
	for b: Object in world.buildings:
		if not is_instance_valid(b):
			continue
		var bb := b as LegionBuilding
		if bb.side != _side:
			continue
		# парные огоньки над крышей — «рождают по двое»; у Котла — по бокам котла
		var at := bb.global_position + Vector2(0.0, -CfgItems.FLAME_LIFT)
		var gap := CfgItems.FLAME_GAP
		if bb.source == LegionBuilding.SOURCE_CAULDRON:
			gap = CfgItems.FLAME_GAP + 6.0
		var h := CfgItems.FLAME_H * (1.0 + 0.7 * k)
		for side in [-1.0, 1.0]:
			var p := at + Vector2(side * gap, 0.0)
			_flame(p, h * _flick(p.x), col, eco, 0.3 * sin(world.now * 3.0 + p.x))
		n += 1
	if n > 0:
		_items.note_look(&"building", &"flame")


## Земляной слой (узел ItemLookGround под Contracts): кольцо «Печати на Котле».
func _draw_ground() -> void:
	if world == null or world.items == null or world.phase == LegionWorld.Phase.MENU:
		return
	for side in world.sides:   # PvP: кольцо у Котла каждой стороны, чья печать
		if side.items == null:
			continue
		var ring := side.items.look_of(&"cauldron", &"ring")
		if not ring.is_empty():
			_draw_ward(_ground, ring, Settings.is_economy_graphics(), side.index)


## Кольцо печати у подножия: сплющенный круг с зубцами; готово к удару — ярче. Центр — точка
## ног Котла (cauldron_view_of уже со сдвигом картинки cauldron_art): Котёл стоит В кольце, его
## верхняя дуга уходит за котёл, нижняя светится из-под него.
func _draw_ward(ci: CanvasItem, ring: Dictionary, eco: bool, side := 0) -> void:
	var owned := world.items_of(side)
	var at := world.cauldron_view_of(side) + Vector2(0.0, CfgItems.WARD_DY)
	var k := owned.pulse(&"cauldron")
	var ready := world.now >= float(owned.state.get(&"ward_ready", -INF))
	var col: Color = ring["color"]
	var base := CfgItems.WARD_A_READY if ready else CfgItems.WARD_A_WAIT
	var a := base * (0.85 + 0.15 * _flick(at.x, 4.0)) + 0.1 * k
	var rr := CfgItems.WARD_R * (1.0 + 0.25 * k)
	ci.draw_set_transform(at, 0.0, Vector2(1.0, rr.y / rr.x))
	if not eco:
		ci.draw_circle(Vector2.ZERO, rr.x, Color(col, 0.16 * a))
	ci.draw_arc(Vector2.ZERO, rr.x + 2.0, 0.0, TAU, 48, Color(0.05, 0.04, 0.1, 0.7 * a), 7.0, true)
	ci.draw_arc(Vector2.ZERO, rr.x, 0.0, TAU, 48, Color(col, a), 4.5, true)
	ci.draw_arc(Vector2.ZERO, rr.x * 0.78, 0.0, TAU, 40, Color(col, a * 0.7), 2.0, true)
	var spin := 0.0 if eco else world.now * 0.6
	for i in 12:
		var d := Vector2.from_angle(TAU * float(i) / 12.0 + spin)
		ci.draw_line(d * rr.x * 0.78, d * rr.x, Color(col, a), 3.0, true)
	ci.draw_set_transform(Vector2.ZERO)
	owned.note_look(&"cauldron", &"ring")


func _draw_cauldron(look: Dictionary, eco: bool) -> void:
	var at := world.cauldron_view_of(_side)
	var k := _items.pulse(&"cauldron")
	# кольцо печати — на земляном слое (_draw_ground), под Котлом; здесь — то, что над ним
	var flame: Dictionary = look.get(&"flame", {})
	if not flame.is_empty():
		# пламя душ над Котлом — туда летят души «Душеприказчика»
		var col: Color = flame["color"]
		var base := at + Vector2(0.0, -CfgItems.SOUL_FLAME_LIFT)
		var h := CfgItems.SOUL_FLAME_H * (1.0 + 0.6 * k) * _flick(at.x, 7.0)
		_flame(base, h, col, eco, 0.4 * sin(world.now * 2.2))
		_flame(base + Vector2(-9.0, 4.0), h * 0.6, col, eco, -0.5)
		_flame(base + Vector2(9.0, 4.0), h * 0.6, col, eco, 0.5)
		_items.note_look(&"cauldron", &"flame")


# ── Призрачные линии («Пролонгация») ────────────────────────────────────────

## Подпись следа «Пролонгация: … ещё N с» — не больше CfgItems.GHOST_CAPTIONS раз за бой и одна
## на поле: следы, растаявшие вместе с подписанным, молчат (кадр items-v2: две одинаковые строки
## одна под другой). У остальных — только значок. Тест vfx-clarity зовёт напрямую.
func ghost_caption(h: Dictionary) -> String:
	_meet_ghosts()
	for x in _ghosts_captioned:
		if is_same(x, h):
			return CfgItems.GHOST_CAPTION % ceili(float(h["t"]))
	return ""


## Новые следы — во «встреченные» по порядку списка опасных зон; ушедшие — вон. PvP: следы
## обеих сторон (сторона 0 первой), подпись одна на поле, как в одиночке.
func _meet_ghosts() -> void:
	var alive: Array[Dictionary] = []
	var all: Array[Dictionary] = []
	for side in world.sides:
		if side.items != null:
			all.append_array(side.items.hazards)
	for h in all:
		if h["kind"] != &"ghost":
			continue
		alive.append(h)
		if _ghosts_seen.any(func(x: Dictionary) -> bool: return is_same(x, h)):
			continue
		_ghosts_seen.append(h)
		if _ghosts_captioned.is_empty() and _captions_used < CfgItems.GHOST_CAPTIONS:
			_captions_used += 1
			_ghosts_captioned.append(h)
	var still := func(x: Dictionary) -> bool:
		return alive.any(func(y: Dictionary) -> bool: return is_same(x, y))
	_ghosts_seen = _ghosts_seen.filter(still)
	_ghosts_captioned = _ghosts_captioned.filter(still)


func _draw_ghosts(eco: bool) -> void:
	var lk := _items.look_of(&"contract", &"ghost")
	var col: Color = lk.get("color", Color(0.7, 0.62, 1.0))
	var fire := Color(1.0, 0.5, 0.15)
	_meet_ghosts()
	var n := 0
	for h in _items.hazards:
		if h["kind"] != &"ghost":
			continue
		var a: Vector2 = h["a"]
		var b: Vector2 = h["b"]
		var life := clampf(float(h["t"]) / 0.5, 0.0, 1.0)   # последние полсекунды гаснет
		var c := col.lerp(fire, 0.55) if bool(h.get("hot", false)) else col
		var side := (b - a).orthogonal().normalized() * float(h["r"])
		# тихая полоса с кантом — «здесь жалит»; бегущего пунктира по оси больше нет: он делал
		# след похожим на живой договор (vfx-clarity 29.09)
		if not eco:
			draw_colored_polygon(PackedVector2Array([a - side, b - side, b + side, a + side]),
				Color(c, CfgItems.GHOST_BAND_A * life))
		var edge := Color(c, CfgItems.GHOST_EDGE_A * life)
		draw_line(a - side * 0.9, b - side * 0.9, edge, 2.0, true)
		draw_line(a + side * 0.9, b + side * 0.9, edge, 2.0, true)
		_draw_ghost_badge(h, (a + b) * 0.5, c, life)
		n += 1
	if n > 0:
		_items.note_look(&"contract", &"ghost")


## Значок артефакта (тот же, что в полоске) в кольце-таймере посреди следа; подпись — у первых.
func _draw_ghost_badge(h: Dictionary, mid: Vector2, c: Color, life: float) -> void:
	var r := CfgItems.GHOST_ICON * 0.5
	var frac := clampf(float(h["t"]) / maxf(0.01, float(h.get("t0", h["t"]))), 0.0, 1.0)
	draw_circle(mid, r + 3.0, Color(0.06, 0.04, 0.1, 0.8 * life))
	draw_arc(mid, r + 3.0, -PI * 0.5, -PI * 0.5 + TAU * frac, 28, Color(c, life), 2.5, true)
	if _ghost_icon != null:
		draw_texture_rect(_ghost_icon, Rect2(mid - Vector2(r, r), Vector2(r, r) * 2.0), false,
			Color(1.0, 1.0, 1.0, life))
	var cap := ghost_caption(h)
	if cap != "":
		LegionUi.draw_text(self, mid + Vector2(r + 8.0, 5.0), cap,
			PvpView.fs(world, CfgItems.GHOST_CAPTION_FONT),
			Color(c.lerp(Color.WHITE, 0.55), life), LegionUi.FONT_TITLE)
