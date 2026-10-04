class_name LegionImpactFx
extends Node2D
##
## Импакт способностей и натиска (slow/impact, 26.09.2026). Игорь: «у скиллов, особенно у
## молнии, нужны сильно более интересные анимации, чтобы от них импакт чувствовался, и вообще
## больше импакта надо».
##
## Живёт внутри LegionFx, то есть только в полной графике: экономная оставляет герою простую
## молнию из двух Line2D (LegionHero._bolt). Чистый вид, как весь слой: урон, откаты и цели
## считает герой, и мгновенно — задержка прыжков здесь только у картинки. Свой ГСЧ (world.rng
## не трогаем), время — реальный delta из LegionFx.tick.
##
## Почему отдельный класс: LegionFx упёрся в число публичных методов gdlint, а у импакта свои
## сущности — каналы молний (ломаные, не спрайты) и плоские «наклейки» на земле (пятна гари,
## рунный круг), которые пул частиц не рисует: у пула поворот идёт ДО сплющивания, а круг на
## земле надо сплющить ПОСЛЕ поворота. Частицы — те же LegionFxPool, слоёв четыре: земля
## (обычный и аддитив, под фигурами) и воздух (над фигурами).
##

var world: LegionWorld = null
var fx: LegionFx = null
var rng := RandomNumberGenerator.new()

var _nodes: Array[Node2D] = []              ## 0 земля, 1 земля-аддитив, 2 воздух, 3 воздух-аддитив
var _pools: Array[LegionFxPool] = []
var _p_ring: LegionFxPool                   ## кольца ударов — земля
var _p_gglow: LegionFxPool                  ## отсветы земли — земля-аддитив
var _p_dust: LegionFxPool                   ## пыль — воздух
var _p_streak: LegionFxPool                 ## искры-чёрточки и шлейфы — воздух
var _p_glow: LegionFxPool                   ## вспышки, сердцевина столба, искорки тока — аддитив
## Цветное свечение обычным смешением — воздух. Игра светлая: зелёный или оранжевый аддитив на
## дороге выгорает в белое, а цвет способности должен читаться (кадры v1: столб Дубль-вэ).
var _p_soft: LegionFxPool
var _tex_scorch: Texture2D = null
var _tex_rune: Texture2D = null

## Каналы молний: {pts, br: Array[PackedVector2Array], a, b, delay, age, life, re_t, lit,
## micro, w, foe, hit}. hit — удар по цели уже показан (в миг прихода разряда).
var _bolts: Array[Dictionary] = []
## Наклейки на земле: {tex, pos, rot, spin, s0, s1, asp, age, life, a, c}.
var _decals: Array[Dictionary] = []
## Ударные кольца дугами (волна Е, натиск): {pos, r0, r1, w, asp, age, life, c}. Текстурное
## кольцо light_03 на светлой дороге еле видно (B-066, кадры sheet_w_e_charge): у дуги свой
## тёмный кант под цветом и светлая кромка — читается на любой земле.
var _shocks: Array[Dictionary] = []
## «Под током»: {foe, left, acc, arc_t, flick_t, on}.
var _elec: Array[Dictionary] = []
var _screen_t := 0.0
var _screen_c := Color.WHITE
var _clock := 0.0
var _haste_t := 0.0
var _haste_last: Dictionary = {}            ## instance_id бойца → позиция прошлого опроса
var _haste_trails := 0
## Отлив ускоренных: instance_id вида → CharView, которому выставлен modulate (снять по концу).
var _haste_tinted: Dictionary = {}
var _charge_t := -INF


func setup(layer: LegionFx, w: LegionWorld, ground: Node2D) -> void:
	fx = layer
	world = w
	name = "Impact"
	rng.randomize()
	process_mode = Node.PROCESS_MODE_PAUSABLE
	var glow := LegionFx._vfx("circle_05", CfgFx.TEX_SMALL)
	_p_ring = LegionFxPool.new(LegionFx._vfx("light_03", CfgFx.TEX_SMALL), false, false)
	_p_gglow = LegionFxPool.new(glow, false, false)
	_p_dust = LegionFxPool.new(glow, false, false)
	# чёрточка — вытянутый мягкий диск: у trace_01 линия тоньше пикселя в 5 px (кадры v1)
	_p_streak = LegionFxPool.new(glow, true, false)
	_p_glow = LegionFxPool.new(glow, false, false)
	_p_soft = LegionFxPool.new(glow, false, false)
	_pools = [_p_ring, _p_gglow, _p_dust, _p_streak, _p_glow, _p_soft]
	_tex_scorch = LegionFx._vfx("scorch_01", CfgFx.TEX_BIG)
	_tex_rune = LegionFx._vfx("magic_01", CfgFx.TEX_BIG)
	_add_node(ground, false, 0)
	_add_node(ground, true, 1)
	_add_node(self, false, 2)
	_add_node(self, true, 3)
	w.charge_impact.connect(_on_charge_impact)


func _exit_tree() -> void:
	_untint_all()
	for n in _nodes:
		if is_instance_valid(n) and n.get_parent() != self:
			n.queue_free()


func _add_node(parent: Node2D, additive: bool, idx: int) -> void:
	var node := Node2D.new()
	node.name = "ImpactAdd%d" % idx if additive else "ImpactMix%d" % idx
	if additive:
		var mat := CanvasItemMaterial.new()
		mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
		node.material = mat
	parent.add_child(node)
	_nodes.append(node)
	node.draw.connect(_draw_node.bind(idx))


# ── Шаг и отрисовка ─────────────────────────────────────────────────────────

func tick(dt: float) -> void:
	_clock += dt
	for p in _pools:
		p.step(dt)
	_tick_bolts(dt)
	_tick_decals(dt)
	_tick_shocks(dt)
	_tick_electric(dt)
	_tick_haste(dt)
	_screen_t = maxf(0.0, _screen_t - dt)
	# перерисовка только занятых слоёв (+ один кадр после опустения — стереть прошлый)
	var busy := [not _decals.is_empty() or not _shocks.is_empty(), false, false,
		_screen_t > 0.0]
	busy[0] = busy[0] or _p_ring.n > 0
	busy[1] = _p_gglow.n > 0
	busy[2] = _p_dust.n > 0 or _p_streak.n > 0 or _p_soft.n > 0 or not _bolts.is_empty()
	busy[3] = busy[3] or _p_glow.n > 0 or not _bolts.is_empty()
	for i in _nodes.size():
		if bool(busy[i]) or _nodes[i].has_meta(&"drawn"):
			_nodes[i].queue_redraw()
			if bool(busy[i]):
				_nodes[i].set_meta(&"drawn", true)
			else:
				_nodes[i].remove_meta(&"drawn")


func _draw_node(idx: int) -> void:
	var node := _nodes[idx]
	match idx:
		0:
			_draw_decals(node)
			_draw_shocks(node)
			_p_ring.draw(node)
		1:
			_p_gglow.draw(node)
		2:
			_p_dust.draw(node)
			_p_soft.draw(node)
			_p_streak.draw(node)
			_draw_bolts(node, false)
		3:
			_p_glow.draw(node)
			_draw_bolts(node, true)
			if _screen_t > 0.0:
				var c := _screen_c
				c.a = CfgFx.BOLT_SCREEN_A * _screen_t / CfgFx.BOLT_SCREEN_LIFE
				# вспышка на весь ВИДИМЫЙ мир (поле «Схватки» шире кадра одиночки, B-304)
				var vr := world.view_rect() if world != null \
					else Rect2(Vector2.ZERO, LegionCfg.WORLD_SIZE)
				node.draw_rect(vr.grow(40.0), c)


func clear() -> void:
	for p in _pools:
		p.clear()
	_bolts.clear()
	_decals.clear()
	_shocks.clear()
	_elec.clear()
	_haste_last.clear()
	_untint_all()
	_screen_t = 0.0


func live_count() -> int:
	var n := _decals.size() + _bolts.size() + _shocks.size()
	for p in _pools:
		n += p.n
	return n


func electrified_count() -> int:
	return _elec.size()


## Сколько чёрточек шлейфа Е выпущено за сеанс (для теста: растёт, пока ускоренные бегут).
func haste_trails() -> int:
	return _haste_trails


## Сводка живых молний (без микродуг «под током»): прыжков, видимых, точек канала первого
## прыжка, ответвлений всего.
func bolt_stats() -> Dictionary:
	var hops := 0
	var lit := 0
	var pts := 0
	var br := 0
	for b in _bolts:
		if bool(b["micro"]):
			continue
		hops += 1
		if float(b["age"]) >= float(b["delay"]):
			lit += 1
		if hops == 1:
			pts = (b["pts"] as PackedVector2Array).size()
		br += (b["br"] as Array).size()
	return {"hops": hops, "visible": lit, "points": pts, "branches": br}


## Точки канала прыжка i (пустой массив — прыжка нет).
func bolt_shape(i: int) -> PackedVector2Array:
	var k := 0
	for b in _bolts:
		if bool(b["micro"]):
			continue
		if k == i:
			return (b["pts"] as PackedVector2Array).duplicate()
		k += 1
	return PackedVector2Array()


func _add(p: LegionFxPool, at: Vector2, life: float, sa: float, sb: float, a: float,
		c: Color) -> int:
	if live_count() >= CfgFx.IMPACT_CAP:
		return -1
	return p.add(at.x, at.y, life, sa, sb, a, c)


func _rr(r: Vector2) -> float:
	return rng.randf_range(r.x, r.y)


## Ступни цели: у CharView они ниже position на ground_px() (как у теней и пыли слоя).
static func feet(f: Foe) -> Vector2:
	return f.position + Vector2(0.0, f.view.ground_px() if f.view != null else 0.0)


## Куда бьёт разряд — грудь (герой в экономной графике целится туда же).
static func chest(f: Foe) -> Vector2:
	var h := f.view.body_h if f.view != null else 40.0
	return feet(f) - Vector2(0.0, h * CfgFx.BOLT_CHEST)


# ── Ку ──────────────────────────────────────────────────────────────────────

## Молния от руки некроманта по цепи целей (порядок героя). Урон уже нанесён героем; здесь —
## картинка: прыжок i вспыхивает через i·BOLT_HOP_DELAY, удар по цели — в миг его прихода.
func bolt_chain(hand: Vector2, chain: Array[Foe]) -> void:
	# артефакты меняют саму молнию (D-0927-163): «Скрепка» — цвет и толщину канала,
	# «Громоотвод» — лишние ветки своего цвета. Каналы разные — вместе без каши.
	var lk := _bolt_look()
	var prev := hand
	for i in chain.size():
		var f := chain[i]
		var to := chest(f)
		_add_bolt(prev, to, CfgFx.BOLT_HOP_DELAY * i, CfgFx.BOLT_LIVE + CfgFx.BOLT_FADE, false,
			float(lk["w"]), f, lk)
		prev = to
	_glow(hand, CfgFx.BOLT_FLARE, CfgFx.BOLT_FLARE_A, 0.14, Color.WHITE)
	_glow(hand, CfgFx.BOLT_FLARE * 1.8, CfgFx.BOLT_FLARE_A * 0.5, 0.2, lk["c"])
	# экран: тряска растёт с числом целей, одна короткая слабая вспышка, стоп-кадр мира
	Juice.shake(world, CfgFx.BOLT_SHAKE + CfgFx.BOLT_SHAKE_PER_HOP * chain.size(),
		CfgFx.BOLT_SHAKE_DUR)
	_screen_t = CfgFx.BOLT_SCREEN_LIFE
	_screen_c = lk["c"]
	world.impact_stop(CfgFx.BOLT_HITSTOP)
	_tick_bolts(0.0)  # первый прыжок бьёт сразу, в кадре каста


## Вид молнии Ку с артефактами: c — цвет канала, w — толщина, bc — цвет веток, brx — лишние
## ветки. Без артефактов — прежние LegionCfg.Q_COLOR и ширина 1.
func _bolt_look() -> Dictionary:
	var out := {"c": LegionCfg.Q_COLOR, "w": 1.0, "bc": LegionCfg.Q_COLOR, "brx": 0}
	if world == null or world.items == null:
		return out
	var main := world.items.look_of(&"q_bolt", &"color")
	if not main.is_empty():
		out["c"] = main["color"]
		out["bc"] = main["color"]
		out["w"] = float(main.get("w", 1.0))
		world.items.note_look(&"q_bolt", &"color")
	var fork := world.items.look_of(&"q_bolt", &"fork")
	if not fork.is_empty():
		out["bc"] = fork["color"]
		out["brx"] = int(fork.get("branches", 0))
		world.items.note_look(&"q_bolt", &"fork")
	return out


func _add_bolt(a: Vector2, b: Vector2, delay: float, life: float, micro: bool, w: float,
		f: Foe, lk: Dictionary = {}) -> void:
	if _bolts.size() >= CfgFx.IMPACT_BOLTS_CAP:
		return
	var bolt := {"a": a, "b": b, "delay": delay, "age": 0.0, "life": life,
		"re_t": CfgFx.BOLT_RESHAPE,
		"lit": 1.0, "micro": micro, "w": w, "foe": f, "hit": false,
		"pts": PackedVector2Array(), "br": [],
		"c": lk.get("c", LegionCfg.Q_COLOR), "bc": lk.get("bc", LegionCfg.Q_COLOR),
		"brx": int(lk.get("brx", 0))}
	_reshape(bolt)
	_bolts.append(bolt)


## Новая форма канала: деление средней точкой + 2–3 ответвления (у микродуг — без них).
func _reshape(b: Dictionary) -> void:
	var a: Vector2 = b["a"]
	var z: Vector2 = b["b"]
	var micro := bool(b["micro"])
	var depth := 2
	if not micro:
		depth = clampi(ceili(log(maxf(a.distance_to(z), 1.0) / CfgFx.BOLT_SEG_PX) / log(2.0)),
			CfgFx.BOLT_DEPTH.x, CfgFx.BOLT_DEPTH.y)
	var pts := _jagged(a, z, depth)
	b["pts"] = pts
	var br: Array[PackedVector2Array] = []
	if not micro:
		var ln := a.distance_to(z)
		var dir := (z - a).normalized()
		for k in rng.randi_range(CfgFx.BOLT_BRANCHES.x, CfgFx.BOLT_BRANCHES.y) + int(b["brx"]):
			var from := pts[rng.randi_range(2, pts.size() - 3)]
			var side := -1.0 if rng.randf() < 0.5 else 1.0
			var d := dir.rotated(side * _rr(CfgFx.BOLT_BRANCH_ANGLE))
			var bl := minf(ln * _rr(CfgFx.BOLT_BRANCH_LEN), CfgFx.BOLT_BRANCH_MAX)
			br.append(_jagged(from, from + d * bl, CfgFx.BOLT_BRANCH_DEPTH))
	b["br"] = br


func _jagged(a: Vector2, z: Vector2, depth: int) -> PackedVector2Array:
	var pts := PackedVector2Array([a, z])
	var off := minf(a.distance_to(z) * CfgFx.BOLT_JAG, CfgFx.BOLT_JAG_MAX)
	for level in depth:
		var nxt := PackedVector2Array()
		for k in pts.size() - 1:
			var p := pts[k]
			var q := pts[k + 1]
			var normal := (q - p).orthogonal().normalized()
			nxt.append(p)
			nxt.append((p + q) * 0.5 + normal * rng.randf_range(-off, off))
		nxt.append(pts[pts.size() - 1])
		pts = nxt
		off *= 0.5
	return pts


func _tick_bolts(dt: float) -> void:
	for k in range(_bolts.size() - 1, -1, -1):
		var b := _bolts[k]
		var age := float(b["age"]) + dt
		b["age"] = age
		var t := age - float(b["delay"])
		if t < 0.0:
			continue
		if not bool(b["hit"]):
			b["hit"] = true
			var tf: Variant = b["foe"]
			# цель могла уйти из дерева за время прыжков (труп убран) — тогда без удара
			if tf != null and is_instance_valid(tf):
				_zap(tf as Foe)
		if t >= float(b["life"]):
			_bolts.remove_at(k)
			continue
		var live := CfgFx.ELEC_ARC_LIFE if bool(b["micro"]) else CfgFx.BOLT_LIVE
		if t < live:
			b["re_t"] = float(b["re_t"]) - dt
			if float(b["re_t"]) <= 0.0:
				b["re_t"] = CfgFx.BOLT_RESHAPE
				if dt > 0.0:
					_reshape(b)
				b["lit"] = CfgFx.BOLT_FLICKER if float(b["lit"]) >= 1.0 else 1.0
		else:
			b["lit"] = 1.0 - (t - live) / maxf(float(b["life"]) - live, 0.001)


func _draw_bolts(ci: CanvasItem, additive: bool) -> void:
	for b in _bolts:
		if float(b["age"]) < float(b["delay"]):
			continue
		var lit := float(b["lit"])
		var w := float(b["w"])
		var lines: Array = [b["pts"]]
		lines.append_array(b["br"])
		# цвет артефакта (bolt_chain) — вместо голубого: канал c, ветки bc; без артефакта — как было
		var own: bool = b["c"] != LegionCfg.Q_COLOR or b["bc"] != LegionCfg.Q_COLOR
		for j in lines.size():
			var pts: PackedVector2Array = lines[j]
			var bw := w * (1.0 if j == 0 else CfgFx.BOLT_BRANCH_W)
			var col: Color = b["c"] if j == 0 else b["bc"]
			if additive:
				ci.draw_polyline(pts, Color(col, CfgFx.BOLT_A_GLOW * lit),
					CfgFx.BOLT_W_GLOW * bw)
			else:
				var halo := CfgFx.C_BOLT_HALO if not own else Color(col.darkened(0.35), CfgFx.C_BOLT_HALO.a)
				halo.a *= lit
				ci.draw_polyline(pts, halo, CfgFx.BOLT_W_HALO * bw)
				var mid := CfgFx.C_BOLT_MID if not own else Color(col, CfgFx.C_BOLT_MID.a)
				mid.a *= lit
				ci.draw_polyline(pts, mid, CfgFx.BOLT_W_MID * bw)
				ci.draw_polyline(pts, Color(1, 1, 1, lit), maxf(1.0, CfgFx.BOLT_W_CORE * bw), true)


## Разряд пришёл в цель: белая вспышка фигуры, сноп искр, кольцо, гарь, отсвет, «под током».
func _zap(f: Foe) -> void:
	var hit := chest(f)
	var at_feet := feet(f)
	if f.view != null:
		f.view.flash(CharView.FLASH_COLOR, CfgFx.ZAP_FLASH)
	_glow(hit, CfgFx.BOLT_FLARE, CfgFx.BOLT_FLARE_A, 0.12, Color.WHITE)
	_sparks(hit, CfgFx.ZAP_SPARKS, _bolt_color().lerp(Color.WHITE, 0.4), 1.0, at_feet.y)
	var i := _add(_p_ring, at_feet, CfgFx.ZAP_RING_LIFE, CfgFx.ZAP_RING.x, CfgFx.ZAP_RING.y, 1.0,
		CfgFx.C_ZAP_RING)
	if i >= 0:
		_p_ring.asp[i] = CfgFx.ZAP_RING_ASPECT
		_p_ring.fin[i] = 0.0
		_p_ring.fout[i] = 0.7
	i = _add(_p_gglow, at_feet, CfgFx.ZAP_GLOW_LIFE, CfgFx.ZAP_GLOW, CfgFx.ZAP_GLOW * 0.8,
		CfgFx.ZAP_GLOW_A, _bolt_color())
	if i >= 0:
		_p_gglow.asp[i] = 0.5
		_p_gglow.fin[i] = 0.0
		_p_gglow.fout[i] = 0.8
	_decal(_tex_scorch, at_feet, _rr(CfgFx.SCORCH_SIZE), CfgFx.SCORCH_ASPECT, _rr(CfgFx.SCORCH_LIFE),
		CfgFx.SCORCH_A, CfgFx.C_SCORCH, 0.0)
	# v20: Ку оглушает (Foe.stun_t) — «под током» держится, пока враг оглушён: вид = механика
	electrify(f, maxf(CfgFx.ZAP_ELECTRIFY, f.stun_t))


## Цвет молнии Ку сейчас (с «Скрепкой судьбы» — её золото) — искры, отсвет и «под током».
func _bolt_color() -> Color:
	if world == null or world.items == null:
		return LegionCfg.Q_COLOR
	return world.items.look_of(&"q_bolt", &"color").get("color", LegionCfg.Q_COLOR)


func _glow(at: Vector2, size: float, a: float, life: float, c: Color) -> void:
	var i := _add(_p_glow, at, life, size, size * 0.6, a, c)
	if i >= 0:
		_p_glow.fin[i] = 0.0
		_p_glow.fout[i] = 0.8


## Искры-чёрточки веером вверх и в стороны, падают и гаснут у земли (gy — уровень ступней).
func _sparks(at: Vector2, n: int, c: Color, scale: float, ground_y: float) -> void:
	for k in n:
		var ang := -PI * 0.5 + rng.randf_range(-1.35, 1.35)
		var v := Vector2.from_angle(ang) * _rr(CfgFx.ZAP_SPARK_SPEED) * scale
		var i := _add(_p_streak, at, _rr(CfgFx.ZAP_SPARK_LIFE), CfgFx.ZAP_SPARK_W * scale,
			CfgFx.ZAP_SPARK_W * scale * 0.6, 1.0, c)
		if i < 0:
			return
		_p_streak.vx[i] = v.x
		_p_streak.vy[i] = v.y
		_p_streak.grav[i] = CfgFx.ZAP_SPARK_GRAV
		_p_streak.gy[i] = ground_y
		_p_streak.asp[i] = CfgFx.ZAP_SPARK_ASPECT
		# текстура-чёрточка вертикальна: ось Y — вдоль полёта
		_p_streak.rot[i] = ang - PI * 0.5
		_p_streak.fin[i] = 0.0
		_p_streak.fout[i] = 0.5


# ── «Под током» ─────────────────────────────────────────────────────────────

## Чисто визуальное «под током» на seconds: искорки ползут по фигуре, микродуги, мигание.
## Крючок для оглушения Ку (другая ветка зовёт это на время стана). Повтор продлевает.
func electrify(foe: Foe, seconds: float) -> void:
	if not is_instance_valid(foe) or seconds <= 0.0:
		return
	for e in _elec:
		if e["foe"] == foe:
			e["left"] = maxf(float(e["left"]), seconds)
			return
	_elec.append({"foe": foe, "left": seconds, "acc": 0.0, "arc_t": 0.0, "flick_t": 0.0})


func _tick_electric(dt: float) -> void:
	for k in range(_elec.size() - 1, -1, -1):
		var e := _elec[k]
		var f = e["foe"]
		e["left"] = float(e["left"]) - dt
		if float(e["left"]) <= 0.0 or not is_instance_valid(f) or (f as Foe).view == null:
			_elec.remove_at(k)
			continue
		var foe := f as Foe
		var base := feet(foe)
		var h := foe.view.body_h
		var acc := float(e["acc"]) + CfgFx.ELEC_DOT_RATE * dt
		while acc >= 1.0:
			acc -= 1.0
			var p := base + Vector2(rng.randf_range(-0.22, 0.22) * h,
				-rng.randf_range(0.1, 0.9) * h)
			var sz := _rr(CfgFx.ELEC_DOT_SIZE)
			var c := Color.WHITE if rng.randf() < 0.4 else _bolt_color()
			var i := _add(_p_glow, p, _rr(CfgFx.ELEC_DOT_LIFE), sz, sz * 0.4, 1.0, c)
			if i >= 0:
				_p_glow.fin[i] = 0.0
				_p_glow.fout[i] = 0.6
		e["acc"] = acc
		e["arc_t"] = float(e["arc_t"]) - dt
		if float(e["arc_t"]) <= 0.0:
			e["arc_t"] = CfgFx.ELEC_ARC_EVERY
			var a := base + Vector2(rng.randf_range(-0.2, 0.2) * h,
				-rng.randf_range(0.15, 0.85) * h)
			var z := a + Vector2.from_angle(rng.randf() * TAU) * _rr(CfgFx.ELEC_ARC_LEN) * h
			_add_bolt(a, z, 0.0, CfgFx.ELEC_ARC_LIFE, true, 0.45, null)
		e["flick_t"] = float(e["flick_t"]) - dt
		if float(e["flick_t"]) <= 0.0:
			e["flick_t"] = CfgFx.ELEC_FLICK
			foe.view.flash(CfgFx.C_ELEC_FLASH, CfgFx.ELEC_FLICK * 0.5)


# ── Наклейки на земле ───────────────────────────────────────────────────────

func _decal(tex: Texture2D, at: Vector2, size: float, asp: float, life: float, a: float,
		c: Color, spin: float, size_end := -1.0) -> void:
	if _decals.size() >= CfgFx.IMPACT_DECALS_CAP:
		_decals.remove_at(0)  # старое пятно уступает новому удару
	_decals.append({"tex": tex, "pos": at, "rot": rng.randf() * TAU, "spin": spin,
		"s0": size, "s1": size if size_end < 0.0 else size_end, "asp": asp, "age": 0.0,
		"life": life, "a": a, "c": c})


func _tick_decals(dt: float) -> void:
	for k in range(_decals.size() - 1, -1, -1):
		var d := _decals[k]
		d["age"] = float(d["age"]) + dt
		d["rot"] = float(d["rot"]) + float(d["spin"]) * dt
		if float(d["age"]) >= float(d["life"]):
			_decals.remove_at(k)


func _shock(at: Vector2, r0: float, r1: float, w: float, asp: float, life: float,
		c: Color) -> void:
	if _shocks.size() >= CfgFx.SHOCK_CAP:
		_shocks.remove_at(0)
	_shocks.append({"pos": at, "r0": r0, "r1": r1, "w": w, "asp": asp, "age": 0.0,
		"life": life, "c": c})


func _tick_shocks(dt: float) -> void:
	for k in range(_shocks.size() - 1, -1, -1):
		var d := _shocks[k]
		d["age"] = float(d["age"]) + dt
		if float(d["age"]) >= float(d["life"]):
			_shocks.remove_at(k)


## Кольцо разлетается с ease-out и тоньшает к концу; слои: тёмный кант, цвет, светлая кромка.
## Сплющенное (asp < 1) лежит на земле — рисуется в масштабе по высоте (дуга сверху и снизу
## тоньше — так и выглядит кольцо, лежащее на земле).
func _draw_shocks(ci: CanvasItem) -> void:
	for d in _shocks:
		var t := float(d["age"]) / float(d["life"])
		var e := 1.0 - pow(1.0 - t, 3.0)
		var r := lerpf(float(d["r0"]), float(d["r1"]), e)
		var a := 1.0 - t * t
		var w := float(d["w"]) * (1.0 - 0.55 * t)
		ci.draw_set_transform(d["pos"], 0.0, Vector2(1.0, float(d["asp"])))
		var c: Color = d["c"]
		ci.draw_arc(Vector2.ZERO, r, 0.0, TAU, CfgFx.SHOCK_POINTS,
			Color(CfgFx.C_SHOCK_KANT, CfgFx.SHOCK_KANT_A * a), w + CfgFx.SHOCK_KANT_W)
		ci.draw_arc(Vector2.ZERO, r, 0.0, TAU, CfgFx.SHOCK_POINTS, Color(c, a), w)
		ci.draw_arc(Vector2.ZERO, r - w * 0.2, 0.0, TAU, CfgFx.SHOCK_POINTS,
			Color(c.lerp(Color.WHITE, 0.6), a * 0.9), maxf(1.0, w * 0.3))
	ci.draw_set_transform(Vector2.ZERO)


## Плоско на земле: сперва поворот, ПОТОМ сплющивание по высоте — круг лежит, а не крутится
## сплюснутым эллипсом.
func _draw_decals(ci: CanvasItem) -> void:
	for d in _decals:
		var t := float(d["age"]) / float(d["life"])
		var a := float(d["a"]) * minf(1.0, t / 0.08) * minf(1.0, (1.0 - t) / 0.45)
		var s := lerpf(float(d["s0"]), float(d["s1"]), 1.0 - (1.0 - t) * (1.0 - t))
		var c: Color = d["c"]
		c.a *= a
		var m := Transform2D(0.0, Vector2(1.0, float(d["asp"])), 0.0, d["pos"]) \
			* Transform2D(float(d["rot"]), Vector2.ZERO)
		ci.draw_set_transform_matrix(m)
		ci.draw_texture_rect(d["tex"], Rect2(Vector2(-s, -s) * 0.5, Vector2(s, s)), false, c)
	ci.draw_set_transform_matrix(Transform2D.IDENTITY)


# ── Дубль-вэ ────────────────────────────────────────────────────────────────

## Подъём внештатника: рунный круг на земле, столб душ снизу вверх, огоньки, зелёный отсвет,
## рывок фигуры (сплющен → вытянут → норма).
func raise(at: Vector2, body_h: float, who: Node2D) -> void:
	var c := LegionCfg.W_COLOR
	_decal(_tex_rune, at, CfgFx.RAISE_RUNE.x, CfgFx.RAISE_RUNE_ASPECT, CfgFx.RAISE_RUNE_LIFE, 1.0,
		c, CfgFx.RAISE_RUNE_SPIN, CfgFx.RAISE_RUNE.y)
	var i := _add(_p_gglow, at, CfgFx.RAISE_COLUMN_LIFE, CfgFx.RAISE_GLOW * 0.6, CfgFx.RAISE_GLOW,
		CfgFx.RAISE_GLOW_A, c)
	if i >= 0:
		_p_gglow.asp[i] = 0.5
		_p_gglow.fin[i] = 0.05
	# столб стоит на рунном круге и обнимает фигуру; сердцевина уходит вверх — души вверх
	var col_w := _rr(CfgFx.RAISE_COLUMN)
	var mid := at - Vector2(0.0, col_w * CfgFx.RAISE_COLUMN_ASPECT * 0.45)
	for layer in 2:
		var core := layer == 1
		var w := col_w * (0.35 if core else 1.0)
		var pool := _p_glow if core else _p_soft
		i = _add(pool, mid, CfgFx.RAISE_COLUMN_LIFE, w * 0.6, w,
			1.0 if core else CfgFx.RAISE_COLUMN_A, Color.WHITE if core else c)
		if i >= 0:
			pool.asp[i] = CfgFx.RAISE_COLUMN_ASPECT * (1.6 if core else 1.0)
			pool.vy[i] = -CfgFx.RAISE_CORE_RISE if core else 0.0
			pool.fin[i] = 0.12
			pool.fout[i] = 0.6
	for k in CfgFx.RAISE_MOTES:
		var p := at + Vector2(rng.randf_range(-1.0, 1.0) * CfgFx.RAISE_RUNE.y * 0.4,
			rng.randf_range(-4.0, 4.0))
		var sz := _rr(CfgFx.RAISE_MOTE_SIZE)
		# огоньки попеременно: зелёные обычным смешением (цвет) и белые аддитивом (искра)
		var pool := _p_soft if k % 2 == 0 else _p_glow
		i = _add(pool, p, _rr(CfgFx.RAISE_MOTE_LIFE), sz, sz * 0.5, 0.95,
			c if k % 2 == 0 else c.lerp(Color.WHITE, 0.6))
		if i < 0:
			break
		pool.vy[i] = -_rr(CfgFx.RAISE_MOTE_RISE)
		pool.drag[i] = 1.2
		pool.wax[i] = 4.0
		pool.wf[i] = rng.randf_range(5.0, 9.0)
		pool.wph[i] = rng.randf() * TAU
		pool.fin[i] = 0.1
		pool.fout[i] = 0.5
	fx.emit_dust(at, 4, 1.1)
	if who != null and body_h > 0.0:
		who.scale = CfgFx.RAISE_SQUASH
		var tw := who.create_tween()
		tw.tween_property(who, "scale", CfgFx.RAISE_STRETCH, CfgFx.RAISE_SQUASH_T) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		tw.tween_property(who, "scale", Vector2.ONE, CfgFx.RAISE_SETTLE_T) \
			.set_trans(Tween.TRANS_ELASTIC).set_ease(Tween.EASE_OUT)


# ── Е ───────────────────────────────────────────────────────────────────────

## Аврал: ударная волна по земле до radius, пыль поднимается там, где она прошла, отсвет.
func rush(at: Vector2, radius: float, side := 0) -> void:
	var c := haste_color(side)
	# фронт — дуга с кантом (читается на светлой земле), следом вторая тоньше и мягкая волна
	_shock(at, radius * 0.1, radius, CfgFx.RUSH_WAVE_W, 1.0, CfgFx.RUSH_WAVE_LIFE, c)
	_shock(at, radius * 0.05, radius * 0.72, CfgFx.RUSH_WAVE_W * 0.55, 1.0,
		CfgFx.RUSH_WAVE_LIFE * 0.8, c.lerp(Color.WHITE, 0.3))
	var w := _add(_p_ring, at, CfgFx.RUSH_WAVE2_LIFE, radius * 0.2, radius * 1.8,
		CfgFx.RUSH_WAVE2_A, c)
	if w >= 0:
		_p_ring.fin[w] = 0.0
		_p_ring.fout[w] = 0.55
	# удар в точке каста: цветная вспышка обычным смешением + белая аддитивная
	var up := at - Vector2(0.0, 10.0)
	var f := _add(_p_soft, up, CfgFx.RUSH_FLASH_LIFE, CfgFx.RUSH_FLASH * 0.6, CfgFx.RUSH_FLASH,
		CfgFx.RUSH_FLASH_A, c)
	if f >= 0:
		_p_soft.asp[f] = 0.6
		_p_soft.fin[f] = 0.0
		_p_soft.fout[f] = 0.8
	_glow(up, CfgFx.RUSH_FLASH * 0.5, 0.8, CfgFx.RUSH_FLASH_LIFE, Color.WHITE)
	var g := _add(_p_gglow, at, 0.3, CfgFx.RUSH_GLOW * 0.7, CfgFx.RUSH_GLOW, CfgFx.RUSH_GLOW_A, c)
	if g >= 0:
		_p_gglow.fin[g] = 0.0
	var dust_c := fx._dust_color(at)  # тот же цвет земли, что у остальной пыли слоя
	for ring in 2:
		var rim := ring == 0
		var n := CfgFx.RUSH_DUST_RIM if rim else CfgFx.RUSH_DUST_MID
		var r := radius * (0.92 if rim else 0.5)
		for k in n:
			var ang := TAU * float(k) / float(n) + rng.randf_range(-0.15, 0.15)
			var dir := Vector2.from_angle(ang)
			var i := _add(_p_dust, at + dir * r, _rr(CfgFx.DUST_LIFE) * 1.5,
				CfgFx.DUST_SIZE.x * CfgFx.RUSH_DUST_SCALE, CfgFx.DUST_SIZE.y * CfgFx.RUSH_DUST_SCALE,
				CfgFx.RUSH_DUST_A, dust_c)
			if i < 0:
				return
			_p_dust.vx[i] = dir.x * CfgFx.RUSH_DUST_OUT
			_p_dust.vy[i] = dir.y * CfgFx.RUSH_DUST_OUT * 0.5 - CfgFx.DUST_RISE
			_p_dust.drag[i] = CfgFx.DUST_DRAG
			_p_dust.asp[i] = CfgFx.DUST_ASPECT
			# появляется, когда до этого места дошла волна (ease-out кольца: быстро у центра)
			_p_dust.fin[i] = 0.35 if rim else 0.15
			_p_dust.fout[i] = 0.55


## Цвет Аврала: «Табель сверхурочных» красит волну и шлейф в рыжий огонь (вид = механика: шире
## и дольше). Отметка вида — на каждый опрос.
func haste_color(side := 0) -> Color:
	if world == null or world.items == null:
		return LegionCfg.E_COLOR
	var lk := world.items_of(side).look_of(&"e_haste", &"color")
	if lk.is_empty():
		return LegionCfg.E_COLOR
	world.items_of(side).note_look(&"e_haste", &"color")
	return lk["color"]


## Шлейф и отлив у ускоренных Е, пока Аврал идёт: чёрточка вдоль бега и пятно света.
func _tick_haste(dt: float) -> void:
	_haste_t += dt
	if _haste_t < CfgFx.HASTE_SCAN or world == null or world.hero == null:
		return
	_haste_t = 0.0
	var units: Array[Legionnaire] = []
	for side in world.sides:
		if side.hero != null:
			units.append_array(side.hero.hasted())
	if units.is_empty():
		_haste_last.clear()
		_untint_all()
		return
	var seen := {}
	for u in units:
		if not is_instance_valid(u) or not u.alive:
			continue
		var hc := haste_color(u.side)
		var id := u.get_instance_id()
		var h := u.view.body_h if u.view != null else 36.0
		var gp := u.view.ground_px() if u.view != null else 0.0
		var body := u.position + Vector2(0.0, gp - h * 0.45)
		if u.view != null:
			# отлив — modulate вида бойца (у бойцов он свободен: тинт и вспышка — self_modulate)
			var vid := u.view.get_instance_id()
			seen[vid] = true
			if not _haste_tinted.has(vid):
				_haste_tinted[vid] = u.view
				u.view.set_meta(&"pre_haste_tint", u.view.modulate)
				u.view.modulate *= CfgFx.HASTE_MODULATE
		var last: Vector2 = _haste_last.get(id, u.position)
		_haste_last[id] = u.position
		var mv := u.position - last
		if mv.length() < CfgFx.HASTE_MIN_MOVE:
			continue
		var at := body - mv.normalized() * h * CfgFx.HASTE_STREAK_BACK
		var i := _add(_p_streak, at, CfgFx.HASTE_STREAK_LIFE, CfgFx.HASTE_STREAK_W,
			CfgFx.HASTE_STREAK_W * 0.7, CfgFx.HASTE_STREAK_A, hc)
		if i >= 0:
			_haste_trails += 1
			_p_streak.asp[i] = CfgFx.HASTE_STREAK_ASPECT
			_p_streak.rot[i] = mv.angle() - PI * 0.5
			_p_streak.fin[i] = 0.1
			_p_streak.fout[i] = 0.7
	# выбывшие из Аврала (погибли) — отлив снять
	for vid: int in _haste_tinted.keys():
		if not seen.has(vid):
			_untint(vid)


func _untint(vid: int) -> void:
	var v: Variant = _haste_tinted.get(vid)
	_haste_tinted.erase(vid)
	if v != null and is_instance_valid(v):
		(v as CharView).modulate = v.get_meta(&"pre_haste_tint", Color.WHITE)
		v.remove_meta(&"pre_haste_tint")


func _untint_all() -> void:
	for vid: int in _haste_tinted.keys():
		_untint(vid)


# ── Натиск и «Точно!» ───────────────────────────────────────────────────────

## Удар натиска: кольцо, пыль, искры; «Точно!» — золотое кольцо шире, вспышка и толчок тряски.
## Чаще CHARGE_FX_CD — только кольцо: в массовой драке не каша.
func _on_charge_impact(at: Vector2, perfect: bool) -> void:
	var ring := CfgFx.PERFECT_RING if perfect else CfgFx.CHARGE_RING
	var c := LegionCfg.PERFECT_COLOR if perfect else CfgFx.C_CHARGE
	_shock(at, ring.x * 0.5, ring.y * 0.5,
		CfgFx.PERFECT_RING_W if perfect else CfgFx.CHARGE_RING_W, CfgFx.ZAP_RING_ASPECT,
		CfgFx.CHARGE_RING_LIFE, c)
	if _clock - _charge_t < CfgFx.CHARGE_FX_CD and not perfect:
		return
	_charge_t = _clock
	var up := at - Vector2(0.0, 18.0)
	# «удар»: сигнал шлётся только на первое касание залпа — вспышка одна на залп, не на бойца
	var i := _add(_p_soft, up, CfgFx.CHARGE_FLASH_LIFE, CfgFx.CHARGE_FLASH * 0.5,
		CfgFx.CHARGE_FLASH, CfgFx.CHARGE_FLASH_A, c)
	if i >= 0:
		_p_soft.fin[i] = 0.0
		_p_soft.fout[i] = 0.85
	_glow(up, CfgFx.CHARGE_FLASH * 0.55, 0.9, CfgFx.CHARGE_FLASH_LIFE, Color.WHITE)
	_sparks(up, CfgFx.PERFECT_SPARKS if perfect else CfgFx.CHARGE_SPARKS,
		c.lerp(Color.WHITE, 0.3), 0.8, at.y + 4.0)
	fx.emit_dust(at, CfgFx.PERFECT_DUST if perfect else CfgFx.CHARGE_DUST,
		CfgFx.CHARGE_HIT_DUST_SCALE)
	if perfect:
		_glow(up, CfgFx.PERFECT_FLASH, CfgFx.PERFECT_FLASH_A, CfgFx.PERFECT_FLASH_LIFE, c)
		i = _add(_p_soft, up, CfgFx.PERFECT_FLASH_LIFE, CfgFx.PERFECT_FLASH * 0.9,
			CfgFx.PERFECT_FLASH * 0.5, CfgFx.PERFECT_FLASH_A * 0.6, c)
		if i >= 0:
			_p_soft.fin[i] = 0.0
			_p_soft.fout[i] = 0.8
		_shock(at, ring.x * 0.5, ring.y * 0.7, CfgFx.PERFECT_RING_W * 0.6,
			CfgFx.ZAP_RING_ASPECT, CfgFx.CHARGE_RING_LIFE * 1.5, c.lerp(Color.WHITE, 0.4))
		Juice.shake(world, CfgFx.PERFECT_EXTRA_SHAKE, CfgFx.PERFECT_EXTRA_SHAKE_T)
