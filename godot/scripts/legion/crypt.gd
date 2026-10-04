class_name LegionCrypt
extends Node2D
## Склеп требует непрерывного контроля. Вражеское владение выключает набор,
## но не создаёт бесконечную волну: свита и расписание остаются источниками врагов.
## v15 (пакет staff, DESIGN_V15 §5): захваченный склеп — постройка подрядчиков (штат
## CRYPT_STAFF, возрождение CRYPT_RESPAWN). Потерян или оспорен — места заморожены до возврата:
## живые бойцы склепа служат дальше, павшие ждут, пока склеп снова станет нашим.

enum Owner { NEUTRAL, PLAYER, ENEMY }

var world: LegionWorld
var allegiance := Owner.NEUTRAL
var capturing := Owner.NEUTRAL
var progress := 0.0
var nearby_units := 0
var contested := false
## Постройка штата склепа (ребёнок узла); создаётся в setup().
var building: LegionBuilding = null
var _ring: Node2D
## Художественный спрайт тела (28.09, slow/kimi-capture); null — файла нет, _draw() рисует
## прежний камень из LegionCfg.CRYPT_STONE/ROOF/DOOR.
var _tex: Texture2D = null
## Тонировка спрайта под землю собранной карты (D-CX-08; LegionWorld.apply_harmony).
var _tone := Color.WHITE


func setup(w: LegionWorld, at: Vector2) -> void:
	world = w
	position = at
	var path := LegionCfg.CRYPT_SPRITE_PATH_WINTER \
		if String(w.map.get("theme", "")) == "winter" else LegionCfg.CRYPT_SPRITE_PATH
	if ResourceLoader.exists(path):
		_tex = load(path) as Texture2D
	_ring = Node2D.new()
	# Кольцо не теряется за скелетами, сам камень участвует в y-sort.
	_ring.z_index = 5
	_ring.draw.connect(_draw_ring)
	add_child(_ring)
	building = w.staff.make_crypt_building(self)
	queue_redraw()


func tick(dt: float) -> void:
	if world.phase != LegionWorld.Phase.BATTLE or world.paused:
		return
	nearby_units = world.units_near(position, LegionCfg.CRYPT_RADIUS).size()
	var enemies := 0
	contested = false
	for f in world.foes_near(position, LegionCfg.CRYPT_RADIUS):
		# Спящий мимик тоже враг рядом, но сам захватить склеп во сне не может.
		contested = true
		if f.is_active():
			enemies += 1
	var candidate := Owner.NEUTRAL
	if nearby_units >= LegionCfg.CRYPT_UNITS and not contested:
		candidate = Owner.PLAYER
	elif enemies >= LegionCfg.CRYPT_ENEMIES and nearby_units == 0:
		candidate = Owner.ENEMY
	if candidate == allegiance or candidate == Owner.NEUTRAL:
		capturing = Owner.NEUTRAL
		progress = 0.0
	else:
		if capturing != candidate:
			progress = 0.0
		capturing = candidate
		progress += dt
		if progress >= LegionCfg.CRYPT_CAPTURE_TIME:
			allegiance = candidate
			if allegiance == Owner.PLAYER:
				world.stats["crypt_captures"] = int(world.stats.get("crypt_captures", 0)) + 1
			progress = 0.0
			capturing = Owner.NEUTRAL
			world.toast("Склеп: найм открыт!" if allegiance == Owner.PLAYER
				else "Склеп отбит проверяющими!", &"info")
			_redraw()
			# Время захвата не засчитывается как первый производственный такт.
			return
	# места заполняет и возрождает постройка (шаг LegionStaff); склеп только решает, наш ли он
	building.frozen = allegiance != Owner.PLAYER or contested
	_redraw()


func _redraw() -> void:
	queue_redraw()
	_ring.queue_redraw()


func _color(side: Owner) -> Color:
	match side:
		Owner.PLAYER:
			return LegionCfg.CRYPT_PLAYER
		Owner.ENEMY:
			return LegionCfg.CRYPT_ENEMY
	return LegionCfg.CRYPT_NEUTRAL


func set_tone(color: Color) -> void:
	_tone = color
	queue_redraw()


## Есть ли художественный спрайт (false — рисуется код-заглушка; регресс legion_crypt_test).
func has_artwork() -> bool:
	return _tex != null


func _draw() -> void:
	# Пока идёт захват, красимся в цвет захватчика: «кто берёт» видно сразу, не после 4 с.
	var side := capturing if capturing != Owner.NEUTRAL else allegiance
	var color := _color(side)
	# Ореол владения на земле: площадь склепа читается цветом ещё до кольца и подписи.
	for step in range(3, 0, -1):
		draw_circle(Vector2(0, 8), LegionCfg.CRYPT_GLOW_RADIUS * float(step) / 3.0,
			Color(color, LegionCfg.CRYPT_GLOW_ALPHA * float(step) / 3.0
				* (0.4 if side == Owner.NEUTRAL else 1.0)))
	var top := LegionCfg.CRYPT_ROOF[1].y
	if _tex != null:
		var rect := LegionBuilding.sprite_rect(
			_tex, LegionCfg.CRYPT_SPRITE_W, LegionCfg.CRYPT_SPRITE_ANCHOR_Y)
		draw_texture_rect(_tex, rect, false, _tone)
		top = rect.position.y
		# Свет из двери — «чей» склеп виден и у самой постройки, не только у кольца.
		if side != Owner.NEUTRAL:
			draw_circle(Vector2(0, 26), 9.0, Color(color, 0.30))
	else:
		draw_rect(LegionCfg.CRYPT_STONE, Color("424b49"))
		draw_rect(LegionCfg.CRYPT_STONE, _color(allegiance), false, 2.0)
		draw_colored_polygon(PackedVector2Array(LegionCfg.CRYPT_ROOF), Color("78817a"))
		draw_rect(LegionCfg.CRYPT_DOOR, Color("182328"))
	# Флажок владельца на коньке крыши: у нейтрального приспущен (бледный, короткий).
	var pole_base := top + 6.0
	var pennant_w := LegionCfg.CRYPT_PENNANT_W * (0.6 if side == Owner.NEUTRAL else 1.0)
	var flag_color := Color(color, 0.55) if side == Owner.NEUTRAL else color
	draw_line(Vector2(0, pole_base), Vector2(0, pole_base - LegionCfg.CRYPT_PENNANT_POLE),
		Color("2c2f33"), 2.0, true)
	draw_colored_polygon(PackedVector2Array([
		Vector2(0, pole_base - LegionCfg.CRYPT_PENNANT_POLE),
		Vector2(pennant_w, pole_base - LegionCfg.CRYPT_PENNANT_POLE + LegionCfg.CRYPT_PENNANT_H * 0.5),
		Vector2(0, pole_base - LegionCfg.CRYPT_PENNANT_POLE + LegionCfg.CRYPT_PENNANT_H),
	]), flag_color)


## Подпись под склепом простыми словами (corr 29.09: «0/8 · 4 с» и «АД · 8 / 4 с» ничего не
## говорили новичку). Что делать — в самой подписи; правило целиком объясняет разовая подсказка
## LegionMapHints (crypt_intro). Регресс — legion_crypt_test.
func label_text() -> String:
	if capturing != Owner.NEUTRAL and progress > 0.0:
		var left := ceilf(maxf(0.0, LegionCfg.CRYPT_CAPTURE_TIME - progress))
		if capturing == Owner.PLAYER:
			return "Захватываем · %d с" % int(left)
		return "Ад захватывает · %d с" % int(left)
	match allegiance:
		Owner.PLAYER:
			if contested:
				return "Враги рядом · набор стоит"
			return "Склеп ваш · штат %d/%d" % [building.alive_count(), building.cap]
		Owner.ENEMY:
			return "Склеп у Ада · займите %d бойцами" % LegionCfg.CRYPT_UNITS
	return "Ничей склеп" if nearby_units == 0 and not _teaches() \
		else "Ничей склеп · займите %d бойцами (рядом %d)" % [LegionCfg.CRYPT_UNITS, nearby_units]


## «Что делать» у ничейного склепа без бойцов рядом пишет только ближайший к Котлу ничейный:
## на «Болоте» две одинаковые длинные таблички висели разом, нижняя — на панели «Подряд»
## (кадр swamp_square, 02.10). Подошли бойцы — у этого склепа полная подпись со счётом.
func _teaches() -> bool:
	if world == null:
		return true
	# Котёл человека за этим экраном (B-390 (3)): в «Схватке» человек может стоять справа
	var home := world.cauldron_of(world.local_side)
	var mine := position.distance_squared_to(home)
	for c in world.crypts:
		if c != self and c.allegiance == Owner.NEUTRAL \
				and c.position.distance_squared_to(home) < mine:
			return false
	return true


## Табличка под склепом (в координатах склепа): по центру под камнем, а если там её закрыла бы
## панель HUD (карточки «Подряд/Охрана/Аудит», навыки, плашки сверху) — прижата к краю панели
## с зазором CRYPT_LABEL_HUD_GAP; и не за краем экрана.
func label_rect() -> Rect2:
	var font := ThemeDB.fallback_font
	var fs := PvpView.fs(world, LegionCfg.CRYPT_FONT_SIZE)
	var ts := font.get_string_size(label_text(), HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
	var chip := Rect2(
		Vector2(-ts.x * 0.5, LegionCfg.CRYPT_LABEL_Y) - LegionCfg.CRYPT_LABEL_PAD,
		ts + LegionCfg.CRYPT_LABEL_PAD * 2.0)
	if world == null:
		return chip
	chip.position += position   # дальше — в мировых координатах
	var gap := LegionCfg.CRYPT_LABEL_HUD_GAP
	var view := world.view_rect()
	chip.position.x = clampf(chip.position.x, view.position.x + gap,
		view.end.x - chip.size.x - gap)
	chip.position.y = clampf(chip.position.y, view.position.y + gap,
		view.end.y - chip.size.y - gap)
	# панель нижней половины экрана — табличка над ней, верхней — под ней; несколько проходов:
	# уйдя с карточек вида, табличка может лечь на соседнюю панель (слоты навыков)
	var mid := view.get_center().y
	var hud := world.hud_world_rects()
	for pass_i in hud.size():
		var moved := false
		for r in hud:
			var g := r.grow(gap)
			if g.intersects(chip):
				chip.position.y = g.position.y - chip.size.y if g.get_center().y >= mid \
					else g.end.y
				moved = true
		if not moved:
			break
	chip.position = _clear_of_plots(chip, hud, view, gap)
	chip.position -= position
	return chip


## B-390 (4): длинная табличка верхнего склепа «Болота» лежала на площадке под постройку. Если
## табличка задела площадку, пробуем встать над ней или под ней — тем из мест, что ближе, в
## экране, мимо панелей HUD и других площадок; места нет — остаётся где была. Мировые координаты.
func _clear_of_plots(chip: Rect2, hud: Array[Rect2], view: Rect2, gap: float) -> Vector2:
	var plots := world.plot_rects()
	for _pass in plots.size():
		var hit := Rect2()
		for r in plots:
			if r.intersects(chip):
				hit = r
				break
		if not hit.has_area():
			break
		var best := Vector2.INF
		for y: float in [hit.position.y - chip.size.y - LegionCfg.CRYPT_LABEL_PLOT_GAP,
				hit.end.y + LegionCfg.CRYPT_LABEL_PLOT_GAP]:
			var cand := Rect2(Vector2(chip.position.x, y), chip.size)
			if y < view.position.y + gap or cand.end.y > view.end.y - gap:
				continue
			var blocked := false
			for r in plots:
				blocked = blocked or r.intersects(cand)
			for r in hud:
				blocked = blocked or r.grow(gap).intersects(cand)
			if not blocked and (best == Vector2.INF
					or absf(y - chip.position.y) < absf(best.y - chip.position.y)):
				best = cand.position
		if best == Vector2.INF:
			break
		chip.position = best
	return chip.position


func _draw_ring() -> void:
	var color := _color(allegiance)
	var r := LegionCfg.CRYPT_RADIUS
	_ring.draw_circle(Vector2.ZERO, r, Color(color, LegionCfg.CRYPT_RING_FILL_A))
	_ring.draw_arc(Vector2.ZERO, r, 0, TAU, LegionCfg.CRYPT_RING_STEPS,
		Color(color, 0.45), LegionCfg.CRYPT_RING_WIDTH, true)
	if progress > 0.0:
		_ring.draw_arc(Vector2.ZERO, r, -PI / 2, -PI / 2 + TAU *
			progress / LegionCfg.CRYPT_CAPTURE_TIME, LegionCfg.CRYPT_RING_STEPS,
			_color(capturing), LegionCfg.CRYPT_RING_WIDTH * 2, true)
	var label := label_text()
	# Подпись — табличка на тёмной плашке с кантом цвета владельца, а не голый текст на поле.
	var font := ThemeDB.fallback_font
	var fs := PvpView.fs(world, LegionCfg.CRYPT_FONT_SIZE)
	var chip := label_rect()
	_ring.draw_rect(chip, LegionCfg.CRYPT_LABEL_BG)
	_ring.draw_rect(chip, Color(color, 0.8), false, 1.0)
	_ring.draw_string(font, chip.position + LegionCfg.CRYPT_LABEL_PAD
		+ Vector2(0.0, font.get_ascent(fs)), label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, color)
