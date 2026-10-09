class_name ContractRenderer
extends RefCounted
## Только рисование договоров. Симуляция и ввод остаются в ContractField.

var field: ContractField

func _init(target: ContractField) -> void:
	field = target

func _alpha(c: Contract, s: int) -> float:
	return Juice.flash_alpha(field._seg_alpha(c, s))

## «Чернила оптом»: оттенок вида не теряется целиком.
func _ink_look() -> Dictionary:
	if field.world == null or field.world.items == null:
		return {}
	var lk := field.world.items_of(field.owner_side).look_of(&"contract", &"ink")
	if not lk.is_empty() and not field.contracts.is_empty():
		field.world.items_of(field.owner_side).note_look(&"contract", &"ink")
	return lk

static func _inked(body: Color, ink: Dictionary) -> Color:
	if ink.is_empty():
		return body
	return body.lerp(ink["color"], float(ink.get("mix", 0.5)))

func _gild_look() -> Dictionary:
	if field.world == null or field.world.items == null:
		return {}
	return field.world.items_of(field.owner_side).look_of(&"contract", &"gild")

## «Золотое перо»: золотая нить вдоль живых участков со стороны натиска и бегущие блёстки —
## договор «подписан золотом», «Точно!» перезарядит Ку. Импульс получения — нить толще.
func _draw_gild(c: Contract, gild: Dictionary) -> void:
	var col: Color = gild["color"]
	var k := field.world.items_of(field.owner_side).pulse(&"contract")
	var shift := c.dir * CfgItems.GILD_OFFSET if not c.shaped() else Vector2.ZERO
	var drew := false
	for s in c.seg_count():
		if not c.seg_alive(s):
			continue
		var poly := c.seg_polys[s]
		var pts := PackedVector2Array()
		for p in poly:
			pts.append(p + shift)
		var a := Juice.flash_alpha(field._seg_alpha(c, s))
		# тёмный кант под нитью: золото на светлой дороге иначе пропадает (кадр 27.09)
		field.overlay.draw_polyline(pts, Color(0.2, 0.12, 0.02, 0.6 * a), 5.0 + 2.5 * k, true)
		field.overlay.draw_polyline(pts, Color(col, a), 2.8 + 2.5 * k, true)
		drew = true
	if not drew:
		return
	field.world.items_of(field.owner_side).note_look(&"contract", &"gild")
	# блёстки бегут по договору: шаг GILD_SPARK_STEP, фаза — часы мира (без ГСЧ)
	var run := fmod(field.now * 60.0, CfgItems.GILD_SPARK_STEP)
	var d := run
	while d < c.length:
		var seg := c.segment_at(d)
		if c.seg_alive(seg):
			var p := c.point_at(d) + shift
			field.overlay.draw_circle(p, 4.5 + 2.0 * k, Color(col, 0.35))
			field.overlay.draw_circle(p, 2.6 + 1.5 * k, Color(1.0, 0.97, 0.75, 0.95))
		d += CfgItems.GILD_SPARK_STEP

func _draw() -> void:
	var eco := Settings.is_economy_graphics()
	field._sync_vis(eco)
	field.drawn_lines = 0
	if field._drawing and field._draft.size() >= 2 and field.match_refresh(field._draft).is_empty():
		_draw_recruit_preview(field._kind_color(field.current_kind, "color"))
	var ink := _ink_look()
	for c in field.contracts:
		var body := _inked(field._kind_color(c.kind, "color"), ink)
		var core := field._kind_color(c.kind, "core")
		for p in c.posts:
			if not p["dead"] and p["unit"] == null:
				field.draw_circle(p["pos"], 1.8, Color(core, 0.35))
		field.drawn_lines += 1
		var swell := 0.0
		var breath := 1.0
		if not eco and Settings.is_flashes_enabled():
			var k := field._birth_k(c)
			swell = CfgLines.BIRTH_SWELL * (1.0 - k) * (1.0 - k)
			# своя фаза у договора: соседние линии дышат вразнобой и не сливаются в одно мигание
			breath = 1.0 - CfgLines.BREATH \
				+ CfgLines.BREATH * (0.5 + 0.5 * sin(field.now * CfgLines.BREATH_RATE + c.id * 1.7))
		var s := 0
		while s < c.seg_count():
			var e := field._run_end(c, s, false)
			if e > s:
				var pts := field._run_poly(c, s, e)
				if eco:
					_draw_glow(field, pts, body, core, _alpha(c, s))
				else:
					_draw_layers(field, pts, body, core, _alpha(c, s), swell, breath)
				s = e
			else:
				s += 1

func _draw_overlay() -> void:
	var eco := Settings.is_economy_graphics()
	field.drawn_flow = 0
	_draw_package_marks()
	_draw_pick_halo()
	if eco:
		field._fading.clear()
	else:
		_draw_fading()
	var ink := _ink_look()
	var gild := _gild_look()
	for c in field.contracts:
		var body := _inked(field._kind_color(c.kind, "color"), ink)
		var core := field._kind_color(c.kind, "core")
		# 1) контур руны: прогонами одного возраста (обычно весь договор одной ломаной),
		# прогнутый давкой участок — отдельно
		var r := 0
		while r < c.seg_count():
			var e := field._run_end(c, r, true)
			if e == r:
				r += 1
			elif e == r + 1 and c.seg_bend[r] > 0.0:
				_draw_seg_contour(c, r, body, core)
				r = e
			else:
				_draw_rune_contour(field._run_poly(c, r, e), _alpha(c, r), body, core)
				r = e
		if not gild.is_empty():
			_draw_gild(c, gild)
		# 2) течение, вспышка продления и голова рождения — поверх контура, под кольцами срока:
		# штрихи течения «входят» в кольцо-печать и пропадают под ним
		if not eco:
			_draw_flow(c, core)
			_draw_renew(c, core)
			_draw_birth(c, body, core)
		# 3) часы, печать и стрелка каждого участка
		for s in c.seg_count():
			if not c.seg_alive(s):
				continue
			var a := _alpha(c, s)
			_draw_ttl_ring(c.seg_center(s), c.seg_left(s) / c.ttl, a, body, core)
			if not Settings.is_flashes_enabled() and c.seg_left(s) <= LegionCfg.SEG_BLINK:
				_draw_expiry_mark(c, s)
			if field.seal_ready(c, s):
				field.overlay.draw_circle(c.seg_center(s) + Vector2(0, -LegionCfg.RUNE_TTL_R),
					LegionCfg.CORE_WAX_R, LegionCfg.CORE_WAX_COLOR)
			# фигура на натяжке: мелкие стрелки участков не рисуем — их ведёт _draw_fig_sling по общей оси
			if field.is_slinging() and field._grab["contract"] == c \
					and (c.figure != &"" or int(field._grab["seg"]) == s):
				continue
			var col := field.ARROW_COLOR if c.seg_left(s) > LegionCfg.SEG_BLINK else field.ARROW_WARN
			_draw_arrow(c.seg_center(s), c.seg_dir(s), Color(col, 0.9 * a))
	_draw_figures()
	if field._drawing and field._draft.size() >= 2:
		if field._draft_ring and field.match_refresh(field._draft).is_empty():
			_draw_ring_draft()
		elif field._draft_fig != &"" and field.match_refresh(field._draft).is_empty():
			_draw_fig_draft()
		else:
			_draw_draft()
			_draw_over_limit()
	if field.is_slinging() and not field._aim.is_empty():
		var sc := field._grab["contract"] as Contract
		if sc.ring:
			_draw_ring_sling()
		elif sc.figure != &"":
			_draw_fig_sling()
		else:
			_draw_sling()
	elif field.sling_pending():
		_draw_sling_pending()
	_draw_wall_fx()
	_draw_hits()
	_draw_ring_fx()
	_draw_rite_fx()
	_draw_cross_fx()
	_draw_popups()

## Статичные засечки на самом участке заменяют мигание, в том числе у замкнутых фигур.
func _draw_expiry_mark(c: Contract, s: int) -> void:
	var pts := c.bent_poly(s)
	field.overlay.draw_polyline(pts, Color(0.12, 0.03, 0.05, 0.9), 5.0, true)
	for i in range(1, pts.size()):
		field.overlay.draw_dashed_line(pts[i - 1], pts[i], field.ARROW_WARN, 2.5, 5.0, true)

func _draw_seg_contour(c: Contract, s: int, body: Color, core: Color) -> void:
	var a := _alpha(c, s)
	var bend := c.bend_frac(s)
	if bend <= 0.0:
		_draw_rune_contour(c.seg_polys[s], a, body, core)
		return
	# v18 «Давка»: контур гнётся вместе со строем и краснеет к прорыву; к концу —
	# пульс, чтобы было видно, какой участок пора отпускать пружиной
	var pulse := Juice.flash_alpha(0.5 + 0.5 * sin(field.now * 14.0)) if bend > 0.6 else 1.0
	var warn := Color(LegionCfg.PRESS_COLOR, 1.0)
	_draw_rune_contour(c.bent_poly(s), a, body.lerp(warn, bend * pulse),
		core.lerp(Color(1.0, 0.85, 0.7), bend * pulse))
	_draw_press_gauge(c.seg_center(s), bend, pulse)

## Слои линии под бойцами: тень-подложка (только в своём слое — поверх бойцов она бы их
## пачкала), дышащий ореол, свечение, тело, сердцевина. swell — вспышка рождения.
func _draw_layers(
	ci: CanvasItem, pts: PackedVector2Array, body: Color, core: Color, a: float, swell: float,
	breath: float
) -> void:
	if pts.size() < 2:
		return
	if ci == field:
		ci.draw_polyline(pts, Color(CfgLines.SHADOW, CfgLines.SHADOW.a * a), CfgLines.SHADOW_W, true)
	ci.draw_polyline(pts, Color(body, CfgLines.HALO_A * a * breath * (1.0 + swell)),
		CfgLines.HALO_W * (1.0 + swell), true)
	ci.draw_polyline(pts, Color(body, CfgLines.GLOW_A * a), CfgLines.GLOW_W * (1.0 + swell * 0.5),
		true)
	ci.draw_polyline(pts, Color(body, CfgLines.BODY_A * a), CfgLines.BODY_W, true)
	ci.draw_polyline(pts, Color(core.lerp(Color.WHITE, minf(1.0, swell)), CfgLines.CORE_A * a),
		CfgLines.CORE_W, true)


## Течение: светлые штрихи бегут от краёв каждого участка к его середине (к кольцу срока и
## стрелке выпуска). Путь — две полухорды «край → середина»: у участка 64 px ломаная мыши от
## них почти не отходит, а считать точку по длине ломаной на каждый штрих дорого. Все штрихи
## договора — одной командой draw_multiline. Мигающий и прогнутый участок не течёт.
func _draw_flow(c: Contract, core: Color) -> void:
	field._strokes.clear()
	var shift := fposmod(field.now * CfgLines.FLOW_SPEED + c.id * 5.3, CfgLines.FLOW_GAP)
	for s in c.seg_count():
		if c.seg_dead[s] != 0 or c.seg_bend[s] > 0.0 or c.ttl - c.seg_age[s] <= LegionCfg.SEG_BLINK:
			continue
		var poly := c.seg_polys[s]
		var mid := c.seg_center(s)
		_flow_half(poly[0], mid, shift)
		_flow_half(poly[poly.size() - 1], mid, shift)
	if field._strokes.is_empty():
		return
	field.drawn_flow += field._strokes.size() / 2
	var col := Color(core.lerp(Color.WHITE, CfgLines.FLOW_WHITE), CfgLines.FLOW_A)
	field.overlay.draw_multiline(field._strokes, col, CfgLines.FLOW_W)

func _flow_half(from: Vector2, to: Vector2, shift: float) -> void:
	var half := from.distance_to(to)
	if half < CfgLines.FLOW_LEN:
		return
	var d := shift
	while d < half:
		field._strokes.append(from.lerp(to, d / half))
		field._strokes.append(from.lerp(to, minf(1.0, (d + CfgLines.FLOW_LEN) / half)))
		d += CfgLines.FLOW_GAP

## Рождение: раскалённая голова пробегает по новой линии от начала штриха к концу (ease-out) —
## договор «скрепляется»; одновременно ореол вспыхивает и оседает (swell в _draw).
func _draw_birth(c: Contract, body: Color, core: Color) -> void:
	if not Settings.is_flashes_enabled():
		return
	var k := field._birth_k(c)
	if k >= 1.0:
		return
	var run := 1.0 - pow(1.0 - k, 3.0)
	var at := c.point_at(run * c.length)
	var fade := 1.0 - k
	field.overlay.draw_circle(at, CfgLines.BIRTH_HALO_R * (0.6 + 0.4 * fade),
		Color(body, CfgLines.BIRTH_HALO_A * fade))
	field.overlay.draw_circle(at, CfgLines.BIRTH_HEAD_R, Color(core.lerp(Color.WHITE, 0.6), fade))

func _draw_renew(c: Contract, core: Color) -> void:
	if not Settings.is_flashes_enabled():
		return
	var v: Dictionary = field._vis.get(c, {})
	if v.is_empty() or field.now >= float(v["renew_until"]):
		return
	var renew: PackedFloat32Array = v["renew"]
	var col := core.lerp(Color.WHITE, 0.4)
	for s in mini(renew.size(), c.seg_count()):
		var k := (field.now - renew[s]) / CfgLines.RENEW_T
		if k < 0.0 or k >= 1.0 or c.seg_dead[s] != 0:
			continue
		field.overlay.draw_polyline(c.bent_poly(s), Color(col, CfgLines.RENEW_A * (1.0 - k) * (1.0 - k)),
			CfgLines.RENEW_W * (1.0 - 0.4 * k), true)


## Растворение: участок бледнеет, расплывается и всплывает, а вдоль него поднимаются искры.
## Вместо мгновенного исчезновения — видно, ЧТО именно ушло (растаял/выпущен/снят).
func _draw_fading() -> void:
	var i := field._fading.size() - 1
	while i >= 0:
		var f := field._fading[i]
		var k := (field.now - float(f["t0"])) / CfgLines.FADE_T
		if k >= 1.0 or k < 0.0:
			field._fading.remove_at(i)
		else:
			_draw_fade(f, k)
		i -= 1


func _draw_fade(f: Dictionary, k: float) -> void:
	var poly: PackedVector2Array = f["poly"]
	if poly.size() < 2:
		return
	var body: Color = f["body"]
	var core: Color = f["core"]
	var e := 1.0 - k
	field.overlay.draw_set_transform(Vector2(0.0, -CfgLines.FADE_RISE * k))
	field.overlay.draw_polyline(poly, Color(body, CfgLines.GLOW_A * 1.6 * e * e),
		CfgLines.GLOW_W * (1.0 + CfgLines.FADE_SPREAD * k), true)
	field.overlay.draw_polyline(poly, Color(core.lerp(body, k), CfgLines.CORE_A * e * e * e),
		CfgLines.BODY_W * (1.0 - 0.6 * k), true)
	field.overlay.draw_set_transform(Vector2.ZERO)
	field._strokes.clear()
	var a := poly[0]
	var b := poly[poly.size() - 1]
	var seed := float(f["seed"])
	var lift := 1.0 - e * e
	for j in CfgLines.FADE_EMBERS:
		var h1 := field._hash01(seed + j * 1.37)
		var h2 := field._hash01(seed * 1.91 + j * 7.13)
		var p := a.lerp(b, (j + 0.2 + 0.6 * h1) / CfgLines.FADE_EMBERS)
		p += Vector2(sin(k * 7.0 + h1 * TAU) * CfgLines.FADE_EMBER_SWAY,
			-lerpf(CfgLines.FADE_EMBER_RISE.x, CfgLines.FADE_EMBER_RISE.y, h2) * lift)
		field._strokes.append(p)
		field._strokes.append(p + Vector2(0.0, CfgLines.FADE_EMBER_LEN * e + 1.0))
	field.overlay.draw_multiline(field._strokes, Color(core, e), CfgLines.FADE_EMBER_W)


## Превью рогатки: зона удара (контур видно всегда — куда ждать врага; золотая, когда он там),
## тетива — участок, натянутый до упора, толстая стрелка натиска полной длины (сила всегда полная),
## подпись у курсора — что делать: «Жди врага в зоне» / «Срывай!».
func _draw_sling() -> void:
	var c: Contract = field._grab["contract"]
	var seg := int(field._grab["seg"])
	var dir: Vector2 = field._aim["dir"]
	var gold := bool(field._aim["perfect"])
	var col := LegionCfg.PERFECT_COLOR if gold else LegionCfg.SLING_WAIT_COLOR
	var center: Vector2 = field._aim["center"]
	var side := dir.orthogonal() * float(field._aim["half_w"])
	var depth := dir * float(field._aim["depth"])
	var zone := PackedVector2Array([center + side, center + side + depth,
		center - side + depth, center - side])
	var pulse := Juice.flash_alpha(0.5 + 0.5 * sin(FxClock.ms() * 0.02))
	field.overlay.draw_colored_polygon(zone, Color(col, 0.22 + 0.12 * pulse if gold else 0.12))
	zone.append(zone[0])
	# вне золота контур ярче прежнего (0.35 → 0.6): теперь это единственное, на что смотреть
	field.overlay.draw_polyline(zone, Color(col, 0.85 if gold else 0.6), 2.0 if gold else 1.5, true)
	# тетива: концы участка → точка, оттянутая назад до упора (не на долю оттяжки — сила полная)
	var poly := c.seg_polys[seg]
	var bend := center - dir * LegionCfg.SLING_BOW_BEND
	var body := field._kind_color(c.kind, "color")
	var string_pts := PackedVector2Array([poly[0], bend, poly[poly.size() - 1]])
	field.overlay.draw_polyline(string_pts, Color(0, 0, 0, 0.55), 6.0, true)
	field.overlay.draw_polyline(string_pts, Color(body, 0.95), 3.0, true)
	field.overlay.draw_dashed_line(bend, field._pull, Color(col, 0.6), 2.0, 6.0, true)
	field.overlay.draw_circle(field._pull, 5.0, Color(col, 0.9))
	# стрелка натиска — полной длины и толщины с первого кадра натяжки
	var base := center + dir * field.ARROW_OFFSET * 0.6
	var tip := base + dir * LegionCfg.SLING_ARROW_LEN
	var wing := dir.orthogonal() * 14.0
	var back := tip - dir * 20.0
	var width := 10.0
	var head := PackedVector2Array([back + wing, tip, back - wing])
	field.overlay.draw_line(base, back, Color(0, 0, 0, 0.6), width + 3.0, true)
	field.overlay.draw_colored_polygon(head, Color(0, 0, 0, 0.6))
	field.overlay.draw_line(base, back, col, width, true)
	field.overlay.draw_colored_polygon(PackedVector2Array([back + wing * 0.8, tip - dir * 2.0,
		back - wing * 0.8]), col)
	# подпись — сбоку от курсора (вправо), поперёк оттяжки: за курсором висит шкала Отсрочки
	var across := dir.orthogonal()
	if across.x < 0.0:
		across = -across
	_draw_sling_hint(field._pull + across * 22.0 + Vector2(0.0, 6.0), col, gold)


## Подпись натяжки: «Жди врага в зоне» спокойно, «Срывай!» — крупнее и пульсирует. Один слот у
## курсора (прежняя «Сила N%»), нового слоя текста поверх драки нет.
## align_right — подпись кончается в at (растёт влево), а не начинается.
func _draw_sling_hint(at: Vector2, col: Color, gold: bool, align_right := false) -> void:
	var font: Font = UiStyle.FONT_TITLE
	var pulse := Juice.flash_alpha(0.5 + 0.5 * sin(FxClock.ms() * 0.02))
	var size := field._fsz(roundi(22.0 + 3.0 * pulse) if gold else 17)
	var label := field.sling_hint()
	var label_w := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	if align_right:
		at.x -= label_w
	# у края окна курсор упирается в край (см. _sling_armed) — подпись не уходит за экран и под
	# верхнюю полосу HUD
	var view := field.get_viewport().get_visible_rect()
	at.x = clampf(at.x, view.position.x + field.SLING_HINT_MARGIN.x,
		view.end.x - label_w - field.SLING_HINT_MARGIN.x)
	at.y = clampf(at.y, view.position.y + field.SLING_HINT_MARGIN.y,
		view.end.y - field.SLING_HINT_MARGIN.x)
	field.overlay.draw_string_outline(font, at, label, HORIZONTAL_ALIGNMENT_LEFT, -1, size, 5,
		Color(0, 0, 0, 0.8))
	field.overlay.draw_string(font, at, label, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)


## Подсветка того, что возьмут Пробел, колесо или ПКМ (hover_pick): мягкое свечение цветом
## сердцевины вида под контуром руны — весь договор (его стрелку крутит Пробел) и ярче участок
## под курсором (его срывает ПКМ). Идёт прицел — светится прицельный договор целиком.
func _draw_pick_halo() -> void:
	var h := field.hover_pick()
	if h.is_empty():
		return
	var c: Contract = h["contract"]
	var seg := int(h["seg"])
	var col := field._kind_color(c.kind, "core").lerp(Color.WHITE, LegionCfg.PICK_HALO_WHITE)
	# Фигура выбирается ЦЕЛИКОМ (D-1002 §5): подсвечивается весь её контур, а не участок под
	# курсором, — игрок видит, что рогатка возьмёт именно эту группу, а соседняя не уйдёт.
	var shaped := c.shaped()
	var whole := LegionCfg.PICK_HALO_AIM_ALPHA if seg < 0 or shaped else LegionCfg.PICK_HALO_ALPHA
	for s in c.seg_count():
		if not c.seg_alive(s):
			continue
		var poly := c.bent_poly(s)
		field.overlay.draw_polyline(poly, Color(col, whole), LegionCfg.PICK_HALO_W, true)
		if s == seg and not shaped:
			field.overlay.draw_polyline(poly, Color(col, LegionCfg.PICK_HALO_SEG_ALPHA),
				LegionCfg.PICK_HALO_W, true)
			field.overlay.draw_arc(c.seg_center(s), LegionCfg.RUNE_TTL_R + LegionCfg.PICK_RING_GAP, 0.0, TAU,
				LegionCfg.RUNE_TTL_POINTS, Color(col, LegionCfg.PICK_RING_ALPHA), LegionCfg.PICK_RING_W, true)
	if shaped and c.corners_only:
		# места угловой фигуры — заметные кружки над строем: по ним и берут группу
		for p in c.posts:
			if not p["dead"]:
				field.overlay.draw_arc(p["pos"], LegionCfg.RUNE_TTL_R, 0.0, TAU, 24,
					Color(col, whole), LegionCfg.PICK_HALO_W, true)


## Кольцо удара натиска: быстро расходится и гаснет; у точного срыва — золотое и шире.
func _draw_hits() -> void:
	for h in field._hits:
		var k := clampf(float(h["t"]) / 0.3, 0.0, 1.0)
		if k >= 1.0:
			continue
		var perfect := bool(h["perfect"])
		var col := LegionCfg.PERFECT_COLOR if perfect else Color(1.0, 0.9, 0.8)
		var r := lerpf(6.0, 34.0 if perfect else 22.0, 1.0 - pow(1.0 - k, 3.0))
		field.overlay.draw_arc(h["pos"], r, 0.0, TAU, 28, Color(col, 0.9 * (1.0 - k)),
			4.0 if perfect else 2.5, true)


## «Точно!» над участком: выпрыгивает с перелётом масштаба, всплывает и гаснет.
func _draw_popups() -> void:
	var font: Font = UiStyle.FONT_TITLE
	for p in field._popups:
		var k := float(p["t"]) / LegionCfg.PERFECT_POPUP_TIME
		var pop := 1.0 + (field.POPUP_POP - 1.0) * maxf(0.0, 1.0 - k * 6.0)
		var size := field._fsz(roundi(float(p.get("size", 30.0)) * pop))
		var a := 1.0 if k < 0.6 else 1.0 - (k - 0.6) / 0.4
		var text := String(p.get("text", "Точно!"))
		var col: Color = p.get("color", LegionCfg.PERFECT_COLOR)
		var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
		var at: Vector2 = p["pos"] + Vector2(-w * 0.5, -field.POPUP_LIFT - field.POPUP_RISE * k)
		at.x = field._clamp_label_x(at.x, w)
		field.overlay.draw_string_outline(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, 7,
			Color(0.1, 0.02, 0.0, 0.85 * a))
		field.overlay.draw_string(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color(col, a))


## Тонкий полупрозрачный контур руны поверх строя (RUNE): земляная линия под ногами
## бойцов не видна, а без неё игрок не понимает, где проходит договор и что ещё держит.
## Ширина и альфа — LegionCfg.RUNE_OVERLAY_*, подобраны так, чтобы бойцы оставались видны.
func _draw_rune_contour(pts: PackedVector2Array, a: float, body: Color, core: Color) -> void:
	if pts.size() < 2:
		return
	field.overlay.draw_polyline(
		pts, Color(body, LegionCfg.RUNE_OVERLAY_ALPHA * a), LegionCfg.RUNE_OVERLAY_W, true
	)
	field.overlay.draw_polyline(
		pts, Color(core, LegionCfg.RUNE_OVERLAY_ALPHA * 0.7 * a), LegionCfg.RUNE_OVERLAY_CORE_W,
		true
	)


## Кольцо-«часы» у центра участка: дуга «съедается» по мере таяния, тусклый фоновый круг
## держит форму кольца видимой даже когда участок почти истёк. Мигание — через тот же `a`,
## что и у контура/стрелки (LegionCfg.SEG_BLINK), поэтому все три читаются как один сигнал.
func _draw_ttl_ring(at: Vector2, frac: float, a: float, body: Color, core: Color) -> void:
	var backing := LegionCfg.RUNE_TTL_OUTLINE_COLOR
	backing.a *= a
	field.overlay.draw_arc(at, LegionCfg.RUNE_TTL_R, 0.0, TAU, LegionCfg.RUNE_TTL_POINTS,
		backing, LegionCfg.RUNE_TTL_OUTLINE_W, true)
	field.overlay.draw_arc(
		at, LegionCfg.RUNE_TTL_R, 0.0, TAU, LegionCfg.RUNE_TTL_POINTS,
		Color(core, LegionCfg.RUNE_TTL_BG_ALPHA * a), LegionCfg.RUNE_TTL_W, true
	)
	if frac <= 0.0:
		return
	field.overlay.draw_arc(
		at, LegionCfg.RUNE_TTL_R, -PI * 0.5, -PI * 0.5 + TAU * frac, LegionCfg.RUNE_TTL_POINTS,
		Color(body, 0.95 * a), LegionCfg.RUNE_TTL_W, true
	)


func _draw_glow(
	ci: CanvasItem, pts: PackedVector2Array, body: Color, core: Color, a: float
) -> void:
	if pts.size() < 2:
		return
	ci.draw_polyline(pts, Color(body, a * 0.22), field.GLOW_W, true)
	ci.draw_polyline(pts, Color(body, a * 0.6), field.MID_W, true)
	ci.draw_polyline(pts, Color(core, a * 0.95), field.CORE_W, true)


## v18 «Давка»: шкала напора вокруг кольца срока — красная дуга растёт к прорыву, после 0,6
## пульсирует. Контур линии под толпой не виден (кадры приёмки 26.09), кольцо над строем — видно.
func _draw_press_gauge(at: Vector2, bend: float, pulse: float) -> void:
	var r := LegionCfg.RUNE_TTL_R + 7.0
	var from := -PI * 0.5
	field.overlay.draw_arc(at, r, 0.0, TAU, 32, Color(0.05, 0.02, 0.02, 0.55), 6.0, true)
	field.overlay.draw_arc(at, r, from, from + TAU * bend, 32,
		Color(LegionCfg.PRESS_COLOR, 0.55 + 0.45 * pulse), 4.0 + 2.0 * bend, true)


## Шеврон по стрелке выпуска — туда побежит отряд участка, когда договор истечёт.
func _draw_arrow(at: Vector2, n: Vector2, col: Color) -> void:
	var base := at + n * field.ARROW_OFFSET
	var tip := base + n * field.ARROW_LEN
	var side := Vector2(-n.y, n.x) * field.ARROW_WING
	var back := tip - n * (field.ARROW_LEN * 0.55)
	field.overlay.draw_line(base, tip, Color(0, 0, 0, col.a * 0.6), 4.5, true)
	field.overlay.draw_polyline(
		PackedVector2Array([back + side, tip, back - side]), Color(0, 0, 0, col.a * 0.6), 4.5, true
	)
	field.overlay.draw_line(base, tip, col, 2.2, true)
	field.overlay.draw_polyline(PackedVector2Array([back + side, tip, back - side]), col, 2.2, true)


func _draw_draft() -> void:
	var refresh_like := not field.match_refresh(
		field._truncate(field._draft, LegionCfg.LINE_MAX)).is_empty()
	var body := field.draft_color(refresh_like, "color")
	var core := field.draft_color(refresh_like, "core")
	if Settings.is_economy_graphics():
		_draw_glow(field.overlay, field._draft, body, core, 0.9)
	else:
		_draw_layers(field.overlay, field._draft, body, core, 0.9, 0.0, 1.0)
		_draw_pen(body, core)
	if refresh_like:
		return
	_draw_draft_empty(body)
	_draw_preview_labels(body)
	# стрелка черновика — одна на весь договор: видно, куда пойдёт отряд, до отпускания кнопки
	var n := field.stroke_dir(field._draft) if field._draft_dir == Vector2.ZERO else field._draft_dir
	var steps := maxi(1, int(field._draft_len / LegionCfg.SEG_LEN))
	for i in steps:
		var at := field._poly_point(field._draft, (i + 0.5) * field._draft_len / steps)
		_draw_arrow(at, n, Color(field.ARROW_COLOR, 0.9))
	# B-028: подпись — ПОСЛЕ стрелок, поверх них: стрелка первого участка ложилась на
	# «наберёт N / мест M» и перечёркивала буквы.
	_draw_preview_caption()


## Пустая часть черновика — притушена тёмной полосой и прочерчена пунктиром: «сюда не встанут».
func _draw_draft_empty(body: Color) -> void:
	var runs := field.draft_empty_runs()
	if runs.is_empty():
		return
	var line := field._truncate(field._draft, LegionCfg.LINE_MAX)
	for r in runs:
		var part := LegionIntuit.sub_poly(line, r.x, r.y)
		if part.size() < 2:
			continue
		field.overlay.draw_polyline(part, IntuitCfg.DRAFT_EMPTY_SHADE, IntuitCfg.DRAFT_EMPTY_W, true)
		for i in range(1, part.size()):
			field.overlay.draw_dashed_line(part[i - 1], part[i], Color(body, 0.55), 2.0,
				IntuitCfg.DRAFT_EMPTY_DASH, true)


## B-071: бледная стрелка, пока оттяжка между щелчком и взводом — куда пошёл бы натиск.
func _draw_sling_pending() -> void:
	var c: Contract = field._grab["contract"]
	var seg := int(field._grab["seg"])
	var dir := -(field._pull - field._grab_pos).normalized()
	if dir.is_zero_approx():
		return
	var col := Color(LegionCfg.SLING_WAIT_COLOR, IntuitCfg.PENDING_ALPHA)
	var base := c.seg_center(seg) + dir * field.ARROW_OFFSET * 0.6
	var tip := base + dir * IntuitCfg.PENDING_ARROW_LEN
	var back := tip - dir * 14.0
	var wing := dir.orthogonal() * 9.0
	var head := PackedVector2Array([back + wing, tip, back - wing])
	# тонкая тёмная обводка: на светлой дороге одна бледная стрелка терялась (кадр 7_short_pull)
	var shade := Color(0, 0, 0, IntuitCfg.PENDING_ALPHA * 0.6)
	field.overlay.draw_line(base, back, shade, 8.0, true)
	head.append(head[0])
	field.overlay.draw_polyline(head, shade, 3.0, true)
	head.remove_at(3)
	field.overlay.draw_line(base, back, col, 5.0, true)
	field.overlay.draw_colored_polygon(head, col)


## «Стена»: красное кольцо расходится от точки и гаснет, слово — над ним.
func _draw_wall_fx() -> void:
	var ms := FxClock.ms()
	for i in range(field._wall_fx.size() - 1, -1, -1):
		var fx := field._wall_fx[i]
		var label := String(fx.get("label", IntuitCfg.WALL_LABEL))
		var k := float(ms - int(fx["ms"])) / (float(fx.get("life", IntuitCfg.WALL_FX)) * 1000.0)
		if k >= 1.0:
			field._wall_fx.remove_at(i)
			continue
		var at: Vector2 = fx["pos"]
		var a := 1.0 - k
		var col := Color(IntuitCfg.WALL_COLOR, a)
		field.overlay.draw_arc(at, lerpf(6.0, IntuitCfg.WALL_R, 1.0 - pow(1.0 - k, 3.0)), 0.0, TAU, 24,
			col, 3.0, true)
		field.overlay.draw_line(at + Vector2(-5, -5), at + Vector2(5, 5), col, 3.0, true)
		field.overlay.draw_line(at + Vector2(-5, 5), at + Vector2(5, -5), col, 3.0, true)
		var font: Font = UiStyle.FONT_TITLE
		var w := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, field._fsz(18)).x
		var t := at + Vector2(-w * 0.5, -IntuitCfg.WALL_R - 8.0)
		t.x = field._clamp_label_x(t.x, w)   # скала у края окна — слово не уходит за экран
		field.overlay.draw_string_outline(font, t, label, HORIZONTAL_ALIGNMENT_LEFT, -1,
			field._fsz(18), 5, Color(0, 0, 0, 0.85 * a))
		field.overlay.draw_string(font, t, label, HORIZONTAL_ALIGNMENT_LEFT, -1, field._fsz(18), col)


## Перо на конце черновика: пульсирующая светлая точка — «чернила» текут прямо сейчас.
func _draw_pen(body: Color, core: Color) -> void:
	var end := field._draft[field._draft.size() - 1]
	var pulse := Juice.flash_alpha(0.5 + 0.5 * sin(field.now * CfgLines.PEN_PULSE_RATE))
	field.overlay.draw_circle(end, CfgLines.PEN_HALO_R * (0.85 + 0.15 * pulse),
		Color(body, CfgLines.PEN_HALO_A))
	field.overlay.draw_circle(end, CfgLines.PEN_R, core.lerp(Color.WHITE, 0.5))


func _draw_package_marks() -> void:
	for pair in field._package_pairs:
		if not field._pair_alive(pair):
			continue
		var a: Vector2 = pair["a"].seg_center(pair["sa"])
		var b: Vector2 = pair["b"].seg_center(pair["sb"])
		var mid := a.lerp(b, 0.5) + LegionCfg.CORE_CLIP_OFFSET
		var size := LegionCfg.CORE_CLIP_SIZE
		field.overlay.draw_polyline(PackedVector2Array([a, mid, b]),
			Color(LegionCfg.CORE_CLIP_COLOR, 0.35), 1.0, true)
		field.overlay.draw_polyline(PackedVector2Array([
			mid + Vector2(-size.x, 0), mid + Vector2(-size.x, -size.y),
			mid + Vector2(size.x, -size.y), mid + Vector2(size.x, size.y),
			mid + Vector2(-size.x, size.y), mid + Vector2(-size.x, 0), mid,
		]), LegionCfg.CORE_CLIP_COLOR, 2.0, true)


func _draw_recruit_preview(body: Color) -> void:
	var radius := float(field.recruit_r.get(field.current_kind, LegionCfg.RECRUIT_R))
	var zone := Color(body, LegionCfg.DRAFT_ZONE_ALPHA)
	# Полоса на нижнем слое: широкая линия не закрывает персонажей и подсказки.
	field.draw_polyline(field._draft, zone, radius * 2.0, true)
	field.draw_circle(field._draft[0], radius, zone)
	field.draw_circle(field._draft[field._draft.size() - 1], radius, zone)


func _draw_preview_labels(body: Color) -> void:
	for assignment in field._preview_plan:
		var u: Legionnaire = assignment["unit"]
		if is_instance_valid(u) and u.alive:
			field.overlay.draw_arc(u.position, LegionCfg.DRAFT_RING_R, 0, TAU, 24, body, 2.0, true)
	var end := field._draft[field._draft.size() - 1]
	if field._pen_wait or field._space:
		var radius := LegionCfg.PEN_RETURN_R * (0.75 + 0.25 * sin(field.now * LegionCfg.PEN_PULSE_RATE))
		field.overlay.draw_arc(end, radius, 0, TAU, 32, Color.WHITE, 2.0, true)


## Подпись превью «наберёт N / мест M» — последним слоем черновика (поверх стрелок, B-028).
func _draw_preview_caption() -> void:
	var places := field._preview.posts.size() if field._preview != null else 0
	var label := field.preview_caption(places)
	var at := field._draft[0] + LegionCfg.CORE_LABEL_OFFSET
	var font: Font = ThemeDB.fallback_font
	# B-028: бойцы, дерущиеся у линии, закрывали белую подпись без подложки — тёмная обводка,
	# как у «Точно!» (_draw_popups) и подписи силы натяжки (_draw_sling).
	field.overlay.draw_string_outline(font, at, label, HORIZONTAL_ALIGNMENT_LEFT, -1,
		field._core_fs(), LegionCfg.CORE_LABEL_OUTLINE_W, LegionCfg.CORE_LABEL_OUTLINE_COLOR)
	field.overlay.draw_string(font, at, label, HORIZONTAL_ALIGNMENT_LEFT,
		-1, field._core_fs(), Color.WHITE)


## Черновик-кольцо: штрих цвета фигуры, пунктир замыкания, стрелки к центру по всему кругу и
## подпись «Оцепление» у курсора — ДО отпускания видно, что выйдет кольцо, а не линия.
func _draw_ring_draft() -> void:
	var body := field.RING_COLOR
	_draw_glow(field.overlay, field._draft, field._kind_color(field.current_kind, "color"), body, 0.95)
	var first := field._draft[0]
	var last := field._draft[field._draft.size() - 1]
	field.overlay.draw_dashed_line(last, first, Color(body, 0.9), 2.5, 6.0, true)
	var center := ContractShape.centroid(field._draft)
	var pulse := Juice.flash_alpha(0.5 + 0.5 * sin(field.now * 8.0))
	field.overlay.draw_circle(center, 3.0 + 2.0 * pulse, Color(body, 0.8))
	var steps := maxi(3, int(field._draft_len / field.RING_DRAFT_ARROW_STEP))
	for i in steps:
		var at := field._poly_point(field._draft, (i + 0.5) * field._draft_len / steps)
		var n := (center - at).normalized()
		if n != Vector2.ZERO:
			_draw_arrow(at, n, Color(body, 0.9))
	_draw_preview_labels(body)
	# подпись — у курсора, но ОТ кольца наружу: курсор у замыкания, над ним и сам штрих, и
	# подпись превью «наберёт N / мест M» (та уезжает под кольцо, см. ниже)
	var font: Font = UiStyle.FONT_TITLE
	var size := field._fsz(roundi(field.RING_LABEL_SIZE * (1.0 + 0.08 * pulse)))
	var out := (field._pointer - center).normalized()
	var label_w := font.get_string_size(field.RING_LABEL, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	var label_at := field._pointer + out * field.RING_LABEL_OFFSET.x + Vector2(0.0, size * 0.35)
	if out.x < 0.0:
		label_at.x -= label_w
	field.overlay.draw_string_outline(font, label_at, field.RING_LABEL,
		HORIZONTAL_ALIGNMENT_LEFT, -1, size, 5, Color(0, 0, 0, 0.85))
	field.overlay.draw_string(font, label_at, field.RING_LABEL,
		HORIZONTAL_ALIGNMENT_LEFT, -1, size, body)
	# превью набора — под кольцом по центру (у линии оно у начала штриха, а у кольца начало —
	# это и есть курсор)
	var bottom := center.y
	for p in field._draft:
		bottom = maxf(bottom, p.y)
	var places := field._preview.posts.size() if field._preview != null else 0
	var caption := field.preview_caption(places)
	var small: Font = ThemeDB.fallback_font
	var cw := small.get_string_size(caption, HORIZONTAL_ALIGNMENT_LEFT, -1,
		field._core_fs()).x
	var cap_at := Vector2(center.x - cw * 0.5, bottom - field.RING_LABEL_OFFSET.y + field.ARROW_OFFSET)
	field.overlay.draw_string_outline(small, cap_at, caption, HORIZONTAL_ALIGNMENT_LEFT, -1,
		field._core_fs(), LegionCfg.CORE_LABEL_OUTLINE_W, LegionCfg.CORE_LABEL_OUTLINE_COLOR)
	field.overlay.draw_string(small, cap_at, caption, HORIZONTAL_ALIGNMENT_LEFT, -1,
		field._core_fs(), Color.WHITE)


## Натяжка по кольцу: толстые стрелки на КАЖДОМ живом участке — сорвётся весь круг; цвет и
## длина полная (сила всегда полная, 26.09), золото — «Точно!». Подпись у курсора.
func _draw_ring_sling() -> void:
	var c: Contract = field._grab["contract"]
	var t := float(field._aim["power"])
	var gold := bool(field._aim["perfect"])
	var col := LegionCfg.PERFECT_COLOR if gold else LegionCfg.SLING_WAIT_COLOR
	field.overlay.draw_dashed_line(field._grab_pos, field._pull, Color(col, 0.6), 2.0, 6.0, true)
	field.overlay.draw_circle(field._pull, 5.0, Color(col, 0.9))
	var length := LegionCfg.SLING_ARROW_LEN * 0.6
	for s in c.seg_count():
		if not c.seg_alive(s):
			continue
		var dir := c.seg_dir(s)
		var base := c.seg_center(s) + dir * field.ARROW_OFFSET * 0.5
		# к центру — острия не дальше центра: иначе стрелки встречных участков сливаются в звезду
		var run := length if c.ring_out or not c.ring \
			else minf(length, maxf(12.0, base.distance_to(c.center) - field.ARROW_WING * 2.0))
		var tip := base + dir * run
		var wing := dir.orthogonal() * (6.0 + 4.0 * t)
		var back := tip - dir * (10.0 + 4.0 * t)
		var width := 3.0 + 3.0 * t
		field.overlay.draw_line(base, back, Color(0, 0, 0, 0.6), width + 3.0, true)
		field.overlay.draw_line(base, back, col, width, true)
		field.overlay.draw_colored_polygon(PackedVector2Array([back + wing, tip, back - wing]), col)
	# за шкалой Отсрочки, наружу от кольца: шкала висит у курсора наружу (DelayGauge.AWAY) и
	# закрывала подпись, стоявшую просто справа (кадр 26.09); внутрь — строй кольца. Внизу круга
	# дальше: под шкалой её собственная подпись «Отсрочка».
	var back := -c.seg_dir(int(field._grab["seg"]))
	var reach := DelayGauge.AWAY + DelayGauge.R + 14.0 + maxf(0.0, back.y) * 26.0
	_draw_sling_hint(field._pull + back * reach + Vector2(0.0, 6.0), col, gold, back.x < 0.0)


## Натяжка по ФИГУРЕ (не кольцу): стрелка и зона «Точно!» — по ОБЩЕЙ оси оттяжки, туда же летит
## строй (LegionFigures.charge_for при axis != ZERO), а не по внутренней геометрии фигуры
## (к центру/наружу/крест-накрест — только щелчок и таяние). Геометрия — из field._aim (тот же
## dir, что уходит в бой), поэтому превью и бой не расходятся.
func _draw_fig_sling() -> void:
	var dir: Vector2 = field._aim["dir"]
	var gold := bool(field._aim["perfect"])
	var col := LegionCfg.PERFECT_COLOR if gold else LegionCfg.SLING_WAIT_COLOR
	var center: Vector2 = field._aim["center"]
	var side := dir.orthogonal() * float(field._aim["half_w"])
	var deep := dir * float(field._aim["depth"])
	var zone := PackedVector2Array([center + side, center + side + deep,
		center - side + deep, center - side])
	field.overlay.draw_colored_polygon(zone, Color(col, 0.22 if gold else 0.12))
	zone.append(zone[0])
	field.overlay.draw_polyline(zone, Color(col, 0.85 if gold else 0.6), 2.0 if gold else 1.5, true)
	field.overlay.draw_dashed_line(center, field._pull, Color(col, 0.6), 2.0, 6.0, true)
	field.overlay.draw_circle(field._pull, 5.0, Color(col, 0.9))
	var base := center + dir * field.ARROW_OFFSET * 0.6
	var tip := base + dir * LegionCfg.SLING_ARROW_LEN
	var wing := dir.orthogonal() * 12.0
	var tail := tip - dir * 18.0
	field.overlay.draw_line(base, tail, Color(0, 0, 0, 0.6), 12.0, true)
	field.overlay.draw_line(base, tail, col, 9.0, true)
	field.overlay.draw_colored_polygon(PackedVector2Array([tail + wing, tip, tail - wing]), col)
	var across := dir.orthogonal()
	if across.x < 0.0:
		across = -across
	_draw_sling_hint(field._pull + across * 22.0 + Vector2(0.0, 6.0), col, gold)


## Обод кольца схлопывается к центру за RING_FX_MS — «клещи» видны даже в свалке.
func _draw_ring_fx() -> void:
	var ms := FxClock.ms()
	for i in range(field._ring_fx.size() - 1, -1, -1):
		var fx := field._ring_fx[i]
		var k := float(ms - int(fx["ms"])) / field.RING_FX_MS
		if k >= 1.0:
			field._ring_fx.remove_at(i)
			continue
		var e := 1.0 - pow(1.0 - k, 3.0)
		var r := lerpf(float(fx["r"]), 6.0, e)
		field.overlay.draw_arc(fx["center"], r, 0.0, TAU, 48, Color(field.RING_COLOR, 0.9 * (1.0 - k)),
			3.0 + 3.0 * (1.0 - k), true)


## Живые фигуры: у треугольника и квадрата — сам ровный контур по вершинам поверх строя (фигура
## читается, даже когда строй закрыл линию), у восьмёрки — точки центров петель; счёт строя
## к награде у центра (у квадрата награды нет — просто число в строю).
func _draw_figures() -> void:
	var font: Font = ThemeDB.fallback_font
	for c in field.contracts:
		if c.figure == &"" or not c.alive():
			continue
		var col := field.fig_color(c.figure)
		var pulse := Juice.flash_alpha(0.5 + 0.5 * sin(field.now * 5.0))
		# контур фигуры поверх строя: плотный строй закрывает линию под ногами целиком (кадр 26.09)
		var outline := c.points
		if c.tips.size() >= 3:
			outline = c.tips.duplicate()
			outline.append(c.tips[0])
		field.overlay.draw_polyline(outline, Color(0.05, 0.02, 0.1, 0.35), 6.0, true)
		field.overlay.draw_polyline(outline, Color(col, 0.45 + 0.2 * pulse), 3.0, true)
		if c.figure == ContractShape.EIGHT:
			for lc in c.lobes:
				field.overlay.draw_circle(lc, 3.0 + 1.5 * pulse, Color(col, 0.9))
		var have := c.posted_posts()
		var need := c.charge_need()
		if need <= 0:
			need = field.fig_need(c)
		var ready := need > 0 and have >= need
		var charged := c.charge_ready()
		var text := ContractField.fig_progress_text(field.fig_label(c.figure), have, need)
		var size := field._core_fs()
		var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
		var at := c.center + Vector2(-w * 0.5, size * 0.35)
		at.x = field._clamp_label_x(at.x, w)
		field.overlay.draw_string_outline(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size,
			LegionCfg.CORE_LABEL_OUTLINE_W, LegionCfg.CORE_LABEL_OUTLINE_COLOR)
		field.overlay.draw_string(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size,
			LegionCfg.PERFECT_COLOR if charged else Color(col.lerp(Color.WHITE, 0.4), 0.95))
		if c.charge_need() > 0:
			# обод заряда (D-1002 §1): доля CHARGE_TIME видна игроку до срыва. Готов — обод
			# замкнут и пульсирует; сорванный раньше уходит обычным натиском, без ульты.
			var frac := clampf(c.charge_t / FigureCfg.CHARGE_TIME, 0.0, 1.0) if ready else 0.0
			_draw_charge_ring(c.center, frac, col, charged, pulse)


## Обод заряда фигуры вокруг её центра: серые «часы» по числу мест (сколько бойцов нужно) и
## заполненная дуга по charge_t/CHARGE_TIME. Замкнулся — ульта готова.
func _draw_charge_ring(at: Vector2, frac: float, col: Color, charged: bool, pulse: float) -> void:
	var r := LegionCfg.RUNE_TTL_R + LegionCfg.PICK_RING_GAP * 2.0
	var col_a := Color(col.lerp(Color.WHITE, 0.35), 0.35 if not charged else 0.5 + 0.3 * pulse)
	field.overlay.draw_arc(at, r, 0.0, TAU, 32, Color(0, 0, 0, 0.35), 5.0, true)
	field.overlay.draw_arc(at, r, -PI * 0.5, -PI * 0.5 + TAU * frac, 32, col_a, 3.5, true)
	if frac >= 1.0:
		field.overlay.draw_arc(at, r + 3.0, 0.0, TAU, 32, Color(col, 0.25 + 0.2 * pulse), 2.0, true)


## Черновик-фигура: штрих цвета фигуры, пунктир замыкания, стрелки мест (восьмёрка — к центру
## чужой петли, треугольник — к центру, квадрат — наружу) и подпись у курсора с именем и сутью.
func _draw_fig_draft() -> void:
	var col := field.fig_color(field._draft_fig)
	_draw_glow(field.overlay, field._draft, field._kind_color(field.current_kind, "color"), col, 0.95)
	var first := field._draft[0]
	var last := field._draft[field._draft.size() - 1]
	field.overlay.draw_dashed_line(last, first, Color(col, 0.9), 2.5, 6.0, true)
	var pulse := Juice.flash_alpha(0.5 + 0.5 * sin(field.now * 8.0))
	var probe := Contract.new().build_figure(field._draft, field._draft_fig) \
		if field._preview == null or field._preview.figure != field._draft_fig else field._preview
	if probe.figure == ContractShape.EIGHT:
		for lc in probe.lobes:
			field.overlay.draw_circle(lc, 3.0 + 2.0 * pulse, Color(col, 0.85))
	elif probe.tips.size() >= 2:
		field.overlay.draw_circle(probe.center, 3.0 + 2.0 * pulse, Color(col, 0.85))
	for s in probe.seg_count():
		_draw_arrow(probe.seg_center(s), probe.seg_dir(s), Color(col, 0.9))
	_draw_preview_labels(col)
	var center := probe.center
	var font: Font = UiStyle.FONT_TITLE
	var size := field._fsz(roundi(field.RING_LABEL_SIZE * (1.0 + 0.08 * pulse)))
	var label := field.fig_label(field._draft_fig)
	var out := (field._pointer - center).normalized()
	var label_w := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	var label_at := field._pointer + out * field.RING_LABEL_OFFSET.x + Vector2(0.0, size * 0.35)
	var small: Font = ThemeDB.fallback_font
	var hint := field.fig_hint(field._draft_fig)
	var hs := field._core_fs()
	var hint_w := small.get_string_size(hint, HORIZONTAL_ALIGNMENT_LEFT, -1, hs).x
	# у правого края подпись уходила за экран (кадр 26.09) — тогда она слева от курсора
	var block_w := maxf(label_w, hint_w)
	if out.x < 0.0 or label_at.x + block_w > field._screen_w() - 8.0:
		label_at.x = field._pointer.x - field.RING_LABEL_OFFSET.x - block_w
		if out.x >= 0.0:
			# прижата к правому краю — поднять над курсором: внизу слева висит «наберёт N / мест M»
			label_at.y -= size + hs + 16.0
	label_at.x = field._clamp_label_x(label_at.x, block_w)
	field.overlay.draw_string_outline(font, label_at, label, HORIZONTAL_ALIGNMENT_LEFT, -1, size, 5,
		Color(0, 0, 0, 0.85))
	field.overlay.draw_string(font, label_at, label, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)
	var hint_at := label_at + Vector2(0.0, hs + 4.0)
	field.overlay.draw_string_outline(small, hint_at, hint, HORIZONTAL_ALIGNMENT_LEFT, -1, hs,
		LegionCfg.CORE_LABEL_OUTLINE_W, LegionCfg.CORE_LABEL_OUTLINE_COLOR)
	field.overlay.draw_string(small, hint_at, hint, HORIZONTAL_ALIGNMENT_LEFT, -1, hs, Color.WHITE)
	# превью набора — под фигурой по центру (как у кольца)
	var bottom := center.y
	for p in field._draft:
		bottom = maxf(bottom, p.y)
	var places := field._preview.posts.size() if field._preview != null else 0
	var need := field._preview.charge_need() if field._preview != null else 0
	if need <= 0:
		need = ceili(places * field.fig_need_frac(field._draft_fig) - 0.001)
	var caption := field.preview_caption(places)
	if need > 0:
		caption += " · заряд с %d" % need
	var cw := small.get_string_size(caption, HORIZONTAL_ALIGNMENT_LEFT, -1, hs).x
	var cap_at := Vector2(center.x - cw * 0.5, bottom - field.RING_LABEL_OFFSET.y + field.ARROW_OFFSET)
	cap_at.x = field._clamp_label_x(cap_at.x, cw)
	field.overlay.draw_string_outline(small, cap_at, caption, HORIZONTAL_ALIGNMENT_LEFT, -1, hs,
		LegionCfg.CORE_LABEL_OUTLINE_W, LegionCfg.CORE_LABEL_OUTLINE_COLOR)
	field.overlay.draw_string(small, cap_at, caption, HORIZONTAL_ALIGNMENT_LEFT, -1, hs, Color.WHITE)


## Линия длиннее LINE_MAX (ещё не фигура): хвост сверх предела притушен пунктиром и подписан —
## отпустишь так, он отрежется; дальше рисовать дают только ради фигуры.
func _draw_over_limit() -> void:
	if field._draft_len <= LegionCfg.LINE_MAX \
			or not field.match_refresh(field._truncate(field._draft, LegionCfg.LINE_MAX)).is_empty():
		return
	var tail := PackedVector2Array([field._poly_point(field._draft, LegionCfg.LINE_MAX)])
	var run := 0.0
	for i in range(1, field._draft.size()):
		run += field._draft[i].distance_to(field._draft[i - 1])
		if run > LegionCfg.LINE_MAX:
			tail.append(field._draft[i])
	field.overlay.draw_polyline(tail, Color(0.05, 0.03, 0.08, 0.75), field.GLOW_W * 0.8, true)
	for i in range(1, tail.size()):
		field.overlay.draw_dashed_line(tail[i - 1], tail[i], Color(1, 1, 1, 0.55), 2.0, 5.0, true)
	var small: Font = ThemeDB.fallback_font
	var text := "дальше — только фигура"
	var at := field._pointer + Vector2(14.0, -12.0)
	field.overlay.draw_string_outline(small, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1,
		field._core_fs(), LegionCfg.CORE_LABEL_OUTLINE_W, LegionCfg.CORE_LABEL_OUTLINE_COLOR)
	field.overlay.draw_string(small, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, field._core_fs(),
		Color(1, 1, 1, 0.8))


## Обряд: треугольник вспыхивает белым и гаснет в фиолет, круг-вспышка и волна до края удара.
## Реальное время (стоп-кадр мира её не тормозит).
func _draw_rite_fx() -> void:
	var ms := FxClock.ms()
	for i in range(field._rite_fx.size() - 1, -1, -1):
		var fx := field._rite_fx[i]
		var k := float(ms - int(fx["ms"])) / FigureCfg.RITE_FX_MS
		if k >= 1.0:
			field._rite_fx.remove_at(i)
			continue
		var center: Vector2 = fx["center"]
		var r := float(fx["r"])
		var col := FigureCfg.TRI_COLOR
		# вспышка: первые 15 % — белый диск, дальше гаснет
		var flash := clampf(1.0 - k / 0.25, 0.0, 1.0) if Settings.is_flashes_enabled() else 0.0
		if flash > 0.0:
			field.overlay.draw_circle(center, r * (0.6 + 0.4 * flash), Color(1, 0.95, 1, 0.35 * flash))
		# волна: разлетается до 1.25 r с ease-out
		var e := 1.0 - pow(1.0 - minf(1.0, k / 0.55), 3.0)
		field.overlay.draw_arc(center, lerpf(r * 0.2, r * 1.25, e), 0.0, TAU, 64,
			Color(col.lerp(Color.WHITE, 0.5), 0.9 * (1.0 - e)), 3.0 + 9.0 * (1.0 - e), true)
		# треугольник: толстая белая → тонкая фиолетовая, чуть раздувается от центра
		var tips: PackedVector2Array = fx["tips"]
		if tips.size() >= 3:
			var grow := 1.0 + 0.12 * e
			var outline := PackedVector2Array()
			for t in tips:
				outline.append(center + (t - center) * grow)
			outline.append(outline[0])
			var a := 1.0 - k
			field.overlay.draw_polyline(outline, Color(col, 0.5 * a), 18.0 * a + 4.0, true)
			field.overlay.draw_polyline(outline, Color(col.lerp(Color.WHITE, flash), a), 5.0 * a + 2.0,
				true)


## «Крест-накрест»: две толстые стрелки от центра петли к центру другой, чуть разведённые, —
## видно, что петли пробегают сквозь перетяжку навстречу. 600 мс реального времени.
func _draw_cross_fx() -> void:
	var ms := FxClock.ms()
	for i in range(field._cross_fx.size() - 1, -1, -1):
		var fx := field._cross_fx[i]
		var k := float(ms - int(fx["ms"])) / 600.0
		if k >= 1.0:
			field._cross_fx.remove_at(i)
			continue
		var e := 1.0 - pow(1.0 - minf(1.0, k / 0.5), 3.0)
		var col := Color(FigureCfg.EIGHT_COLOR.lerp(Color.WHITE, 0.3), 1.0 - k)
		for pair: Array in [[fx["a"], fx["b"]], [fx["b"], fx["a"]]]:
			var a: Vector2 = pair[0]
			var b: Vector2 = pair[1]
			var side := (b - a).orthogonal().normalized() * 9.0
			var tip := a.lerp(b, 0.15 + 0.85 * e) + side
			var base := a + side
			var d := (tip - base).normalized()
			field.overlay.draw_line(base, tip - d * 10.0, Color(0, 0, 0, 0.5 * (1.0 - k)), 8.0, true)
			field.overlay.draw_line(base, tip - d * 10.0, col, 5.0, true)
			field.overlay.draw_colored_polygon(PackedVector2Array([tip - d * 14.0 + d.orthogonal() * 9.0,
				tip, tip - d * 14.0 - d.orthogonal() * 9.0]), col)
