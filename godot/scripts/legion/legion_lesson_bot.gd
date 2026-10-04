class_name LegionLessonBot
extends RefCounted
##
## Бот проходит уроки карты (LegionTutorial) теми же действиями, что игрок, — через API мира,
## а не таймером, зачитывающим урок за него (правило v16). Отдельный файл: движок уроков у
## потолка gdlint. Зачёт — те же сигналы мира, что у человека.
##

## Бот поворачивает стрелку на столько — с запасом над LegionTutorial.AIM_TURN_DEG.
const AIM_TURN_DEG := 45.0


static func act(t: LegionTutorial) -> void:
	var world := t.world
	match t.step_kind():
		&"draw":
			if not t.bot_done:
				t.bot_done = true
				var pts := t.ghost_points()
				if pts.size() < 2:
					pts = _line_near_foe(t)
				world.contracts.set_kind(t._draw_kind())
				if pts.size() >= 2:
					world.contracts.add_contract(pts, world.contracts.default_side(pts))
		&"aim":
			# как Пробел + мышь вбок: стрелка договора на точку в стороне, сигнал — тот же
			var c := t.line_target()
			if c != null and not t.bot_done:
				t.bot_done = true
				c.set_dir(c.dir.rotated(deg_to_rad(AIM_TURN_DEG)))
				world.contracts.aimed.emit(c)
		&"refresh":
			var c := t.line_target()
			if c != null and not t.bot_done:
				t.bot_done = true
				var segs := PackedInt32Array()
				for s in c.seg_count():
					if c.seg_alive(s):
						segs.append(s)
				world.contracts.refresh(c, segs)
		&"release":
			_release_busiest(t)
		&"erase":
			_erase_busiest(t)
		&"perfect":
			_release_perfect(t)
		&"spring", &"stun_hit":
			_release_pressed(t)
		&"rally":
			var at := t.rally_target()
			if at != Vector2.INF and world.rally_cd <= 0.0:
				world.rally(at)
		&"build":
			var plot := t.target_plot()
			if not plot.is_empty():
				world.staff.build(plot, t._build_kind())
		&"hero_q", &"item":
			var f := t.target_foe()
			if f != null and world.hero != null and world.hero.cd_left(LegionHero.SLOT_Q) <= 0.0:
				world.hero.cast(LegionHero.SLOT_Q, f.position)
		&"hero_w":
			var corpse := t.target_corpse()
			if corpse != null and world.hero != null:
				world.hero.cast(LegionHero.SLOT_W, corpse.position)
		&"hero_e":
			var at := t.aura_target()
			if at != Vector2.INF and world.hero != null:
				world.hero.cast(LegionHero.SLOT_E, at)
		&"figure":
			# фигура — настоящим штрихом через поле: распознавание то же, что у мыши
			if not t.bot_done:
				t.bot_done = true
				var pts := t.figure_points()
				world.contracts.set_kind(LegionCfg.KIND_LABORER)
				world.contracts.begin(pts[0])
				for i in range(1, pts.size()):
					world.contracts.extend(pts[i])
				world.contracts.finish()


## Как человек: ждёт, пока строй встанет, и отпускает самый людный участок.
static func _release_busiest(t: LegionTutorial) -> void:
	if t.bot_done:
		return
	for c in t.world.contracts.contracts:
		if t.manned(c) < LegionCfg.TUTORIAL_MIN_MANNED:
			continue
		var best := -1
		for s in c.seg_count():
			if c.seg_alive(s) and (best < 0 or c.seg_manned(s) > c.seg_manned(best)):
				best = s
		if best >= 0:
			t.bot_done = true
			t.world.contracts.release(c, best)
			return


## Урок Таба: настоящий Таб над самым людным участком линии со строем (через поле, как у мыши).
static func _erase_busiest(t: LegionTutorial) -> void:
	if t.bot_done:
		return
	var hit := t.release_target()
	if hit.is_empty() or t.manned(hit["contract"]) < LegionCfg.TUTORIAL_MIN_MANNED:
		return
	t.bot_done = true
	t.world.contracts.erase(hit["contract"], int(hit["seg"]))


## «Точно!»: срыв участка со строем, у которого враг уже в зоне удара (рогатка в золото).
static func _release_perfect(t: LegionTutorial) -> void:
	for c in t.world.contracts.contracts:
		for s in c.seg_count():
			if not c.seg_alive(s) or c.seg_manned(s) <= 0:
				continue
			var mid := c.seg_center(s)
			if t.world.foes_near(mid, LessonsCfg.BOT_PERFECT_R).is_empty():
				continue
			t.world.release_segment_aimed(c, s, c.dir, 1.0, true)
			return


## «Пружина» и срыв по оглушённым: выпуск самого прогнутого участка (или ближайшего к
## оглушённому врагу). Нечего срывать — для урока «по оглушённым» сперва Ку по врагу у строя.
static func _release_pressed(t: LegionTutorial) -> void:
	var world := t.world
	if t.step_kind() == &"stun_hit":
		var f := t.stunned_foe()
		if f == null:
			var near := t.target_foe()
			if near != null and world.hero != null and world.hero.cd_left(LegionHero.SLOT_Q) <= 0.0:
				world.hero.cast(LegionHero.SLOT_Q, near.position)
			return
		var best: Contract = null
		var best_s := -1
		var best_d := INF
		for c in world.contracts.contracts:
			for s in c.seg_count():
				if c.seg_alive(s) and c.seg_manned(s) > 0:
					var d := c.seg_center(s).distance_to(f.position)
					if d < best_d:
						best_d = d
						best = c
						best_s = s
		if best != null:
			world.release_segment_aimed(best, best_s, (f.position - best.seg_center(best_s)).normalized(),
				1.0, false)
		return
	var hit := t.spring_target()
	if not hit.is_empty():
		world.contracts.release(hit["contract"], int(hit["seg"]))


## Урок линии без дорожки (вахтёр/счетовод): короткий штрих поперёк пути ближайшего врага.
static func _line_near_foe(t: LegionTutorial) -> PackedVector2Array:
	var f := t.target_foe()
	var at := t.world.cauldron_pos + Vector2(140.0, 0.0)
	if f != null:
		at = t.world.cauldron_pos.lerp(f.position, 0.5)
	var n := (at - t.world.cauldron_pos).normalized().orthogonal()
	return PackedVector2Array([at - n * 70.0, at + n * 70.0])


## Штрих фигуры «рукой, но ровно»: кольцо, восьмёрка (лемниската Жероно), треугольник
## (вершиной вверх) или квадрат (стороны по осям), r — радиус вершин; многоугольник — одним
## проходом по вершинам до начала. Те же формы признают корпуса legion_runes_test и
## legion_figures_test.
static func template(fig: String, c: Vector2, r: float) -> PackedVector2Array:
	var corners := PackedVector2Array()
	match fig:
		"ring":
			var n := ceili(TAU * r / LessonsCfg.FIG_STEP)
			for i in n + 1:
				var a := -PI * 0.5 + (TAU - LessonsCfg.RING_GAP) * float(i) / n
				corners.append(c + Vector2(cos(a), sin(a)) * r)
			return corners
		"eight":
			var a := r * LessonsCfg.EIGHT_WIDTH
			var n := ceili((a + r) * 4.0 / LessonsCfg.FIG_STEP)
			for i in n + 1:
				var t := PI * 0.5 + TAU * float(i) / n
				corners.append(c + Vector2(a * sin(t), r * sin(t) * cos(t)).rotated(PI * 0.5))
			return corners
		"triangle", "square":
			var n := 3 if fig == "triangle" else 4
			var a0 := -PI * 0.5 if n == 3 else -PI * 0.75
			for k in n + 1:
				var a := a0 + TAU * float(k % n) / n
				corners.append(c + Vector2(cos(a), sin(a)) * r)
	var out := PackedVector2Array()
	if corners.is_empty():
		return out
	out.append(corners[0])
	for i in range(1, corners.size()):
		var n := maxi(1, ceili(corners[i - 1].distance_to(corners[i]) / LessonsCfg.FIG_STEP))
		for k in range(1, n + 1):
			out.append(corners[i - 1].lerp(corners[i], float(k) / n))
	return out
