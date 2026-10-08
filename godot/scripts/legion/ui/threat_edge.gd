class_name LegionThreatEdge
extends Control
##
## Телеграф угрозы у края экрана и красная виньетка урона Котлу (DESIGN_V17 §1 п.6).
##
## Телеграф: за HUD_THREAT_LEAD секунд до выхода группы из ворот и пока она выходит — свечение
## у ближайшего к воротам края экрана цветом типа врага, стрелка внутрь и «×N». Игрок, занятый
## рисованием линий, замечает периферийным зрением, ОТКУДА сейчас полезут. Трещины сюда не
## входят — у них своя метка на карте (legion_world.gd, warn_breach).
##
## Окна групп считаются из расписания волны (delay/interval/count) и времени старта волны
## (сигнал wave_started + world.now): внутреннее состояние WaveRunner наружу не открыто.
##

const ARROW := 16.0
## Радиус «занятого» маркером места: шеврон + подпись не должны уходить под панели HUD.
const MARK_R := 30.0

var world: LegionWorld = null
## Экранные прямоугольники панелей HUD (плашка, превью, карточки, слоты) — LegionHud обновляет
## их в tick(). Маркер угрозы отодвигается от края внутрь по дороге, пока не выйдет из-под них.
var avoid: Array[Rect2] = []

var _wave_t0 := 0.0
var _vig := 0.0
var _vig_k := 1.0
var _threats: Array[Dictionary] = []
var _pulse := 0.0


func setup(w: LegionWorld) -> LegionThreatEdge:
	world = w
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	UiStyle.fill_rect(self)
	world.wave_started.connect(func(_i: int, _n: int) -> void: _wave_t0 = world.now)
	world.cauldron_hit.connect(_on_cauldron_hit)
	return self


func _on_cauldron_hit(amount: float) -> void:
	if not Juice.screen_flash_allowed(self, &"visual_threat", 0):
		return
	_vig = 1.0
	# мелкий укол (курьер 6) — вполсилы, прорыв Прораба (140) — во всю
	_vig_k = clampf(0.55 + amount / 25.0, 0.55, 1.0)


func _process(dt: float) -> void:
	if world == null:
		return
	_vig = maxf(0.0, _vig - dt / LegionCfg.HUD_VIGNETTE_TIME)
	_pulse += dt
	_threats.clear()
	if world.phase == LegionWorld.Phase.BATTLE:
		_collect()
	queue_redraw()


## Группы у ворот, которые выйдут в ближайшие HUD_THREAT_LEAD с или выходят сейчас.
## Одна метка на дорогу: сумма врагов, цвет — самой многочисленной группы.
func _collect() -> void:
	var wr := world.wave_runner
	if wr == null or wr.held:
		return
	var by_road := {}
	# текущая волна: группы с окнами выхода относительно её старта
	if wr.index >= 0 and wr.index < wr.waves.size():
		var elapsed := world.now - _wave_t0
		for g: Dictionary in wr.waves[wr.index].get("groups", []):
			var start := float(g.get("delay", 0.0))
			var finish := start + float(g.get("interval", 1.0)) * float(int(g.get("count", 1)) - 1)
			if elapsed < start - LegionCfg.HUD_THREAT_LEAD \
					or elapsed > finish + LegionCfg.HUD_THREAT_TAIL:
				continue
			_add(by_road, g, clampf(1.0 - (start - elapsed) / LegionCfg.HUD_THREAT_LEAD, 0.0, 1.0))
	# следующая волна: отсчёт известен (next_start_in), клир-зависимая (INF) — не телеграфируем
	var left := wr.next_start_in()
	if left >= 0.0 and is_finite(left) and wr.index + 1 < wr.waves.size():
		for g: Dictionary in wr.waves[wr.index + 1].get("groups", []):
			var until := left + float(g.get("delay", 0.0))
			if until <= LegionCfg.HUD_THREAT_LEAD:
				_add(by_road, g, clampf(1.0 - until / LegionCfg.HUD_THREAT_LEAD, 0.0, 1.0))
	for key: Vector2i in by_road:
		_threats.append(by_road[key])


func _add(by_road: Dictionary, g: Dictionary, k: float) -> void:
	if String(g.get("breach", "")) != "" or int(g.get("count", 1)) <= 0:
		return
	var path := world.road_path(String(g.get("road", "")))
	if path.is_empty():
		return
	# телеграф — в координатах экрана (HUD): вход дороги в ВИДИМЫЙ мир, переведённый на экран
	# (B-304; одиночка — кадр 1280×720 и тождество)
	var at := world.world_to_hud(entry_point(path, world.hud_view_rect()))
	var n := int(g.get("count", 1))
	var type := String(g.get("type", "zombie"))
	# ключ — точка входа, а не id дороги: на Мосту две дороги выходят из одних ворот
	var key := Vector2i((at / 24.0).round())
	if not by_road.has(key):
		by_road[key] = {"at": at, "n": 0, "k": 0.0, "type": type, "top": 0}
	var t: Dictionary = by_road[key]
	t["n"] = int(t["n"]) + n
	t["k"] = maxf(float(t["k"]), k)
	if n > int(t["top"]):
		t["top"] = n
		t["type"] = type


## Где дорога входит в экран: ворота лежат за краем (x 1360, y -80), а игроку важна точка, где
## враги появятся в кадре. Шаг 6 px по первому отрезку, который пересекает экран. screen —
## видимая часть мира (LegionWorld.view_rect; по умолчанию кадр одиночки), ответ — точка мира.
static func entry_point(path: PackedVector2Array,
		screen := Rect2(Vector2.ZERO, LegionCfg.WORLD_SIZE)) -> Vector2:
	if screen.has_point(path[0]):
		return path[0]
	for j in range(1, path.size()):
		var a := path[j - 1]
		var b := path[j]
		var steps := maxi(1, int(a.distance_to(b) / 6.0))
		for s in steps + 1:
			var p := a.lerp(b, float(s) / float(steps))
			if screen.has_point(p):
				return p
	return path[0].clamp(screen.position, screen.end)


static func foe_color(type: String) -> Color:
	return LegionCfg.HUD_FOE_COLORS.get(type, LegionCfg.HUD_FOE_COLOR_DEFAULT)


func _draw() -> void:
	for t in _threats:
		_draw_threat(t)
	if _vig > 0.0 and Settings.is_flashes_enabled():
		_draw_vignette(LegionCfg.HUD_VIGNETTE_ALPHA * _vig_k * _vig * _vig)


## Край, ближайший к точке ворот: 0 — лево, 1 — право, 2 — верх, 3 — низ.
static func edge_of(p: Vector2) -> int:
	var ws := LegionCfg.WORLD_SIZE
	var d := [p.x, ws.x - p.x, p.y, ws.y - p.y]
	var best := 0
	for i in 4:
		if d[i] < d[best]:
			best = i
	return best


func _draw_threat(t: Dictionary) -> void:
	var ws := LegionCfg.WORLD_SIZE
	var p: Vector2 = t["at"]
	var side := edge_of(p)
	var col := foe_color(String(t["type"]))
	var k := float(t["k"])
	# пульс ускоряется к выходу: сначала медленное «дыхание», в момент выхода — частое мигание
	var beat := Juice.flash_alpha(0.6 + 0.4 * sin(_pulse * lerpf(4.0, 10.0, k)))
	var a := (0.25 + 0.55 * k) * beat
	var half := LegionCfg.HUD_THREAT_LEN * 0.5
	var depth := LegionCfg.HUD_THREAT_DEPTH
	# ось вдоль края (u) и нормаль внутрь (n); e — точка на краю
	var vertical := side <= 1
	var u := Vector2.DOWN if vertical else Vector2.RIGHT
	var n: Vector2 = [Vector2.RIGHT, Vector2.LEFT, Vector2.DOWN, Vector2.UP][side]
	var e := Vector2(0.0 if side == 0 else ws.x, clampf(p.y, half, ws.y - half))
	if not vertical:
		e = Vector2(clampf(p.x, half, ws.x - half), 0.0 if side == 2 else ws.y)
	# подложка-тень под свечением: светлая земля (Пустырь) иначе съедает мятный/жёлтый цвет
	var shade := Color(0.0, 0.0, 0.0, 0.35 * minf(1.0, a + 0.3))
	var sp := PackedVector2Array([e - u * half * 0.6, e + u * half * 0.6,
		e + n * depth * 0.8 + u * half * 0.3, e + n * depth * 0.8 - u * half * 0.3])
	draw_polygon(sp, PackedColorArray([shade, shade, Color(shade, 0.0), Color(shade, 0.0)]))
	var edge_col := Color(col, a)
	var clear := Color(col, 0.0)
	# свечение: трапеция, яркая у края и прозрачная внутрь; концы вдоль края гаснут
	var pts := PackedVector2Array([e - u * half, e - u * half * 0.45, e + n * depth - u * half * 0.35,
		e + n * depth - u * half * 0.7])
	draw_polygon(pts, PackedColorArray([clear, edge_col, clear, clear]))
	pts = PackedVector2Array([e - u * half * 0.45, e + u * half * 0.45,
		e + n * depth + u * half * 0.35, e + n * depth - u * half * 0.35])
	draw_polygon(pts, PackedColorArray([edge_col, edge_col, clear, clear]))
	pts = PackedVector2Array([e + u * half * 0.45, e + u * half, e + n * depth + u * half * 0.7,
		e + n * depth + u * half * 0.35])
	draw_polygon(pts, PackedColorArray([edge_col, clear, clear, clear]))
	draw_line(e - u * half * 0.5 + n * 3.0, e + u * half * 0.5 + n * 3.0,
		Color(col, minf(1.0, a * 1.5)), 6.0)
	# шеврон внутрь + «×N»; сверху — ниже плашки статов, чтобы не прятался под ней
	# маркер-печать на оси входа дороги (не на зажатом e); под панелью HUD — дальше внутрь
	var axis := Vector2(e.x, p.y) if vertical else Vector2(p.x, e.y)
	var inset := MARK_R
	while inset < 260.0 and _covered(axis + n * inset):
		inset += 12.0
	var m := axis + n * (inset + 3.0 * sin(_pulse * 6.0))
	var mark_a := minf(1.0, a + 0.5)
	# тёмная печать с кольцом цвета врага: контраст на светлом Пустыре и на тёмной траве
	draw_circle(m, MARK_R - 8.0, Color(0.05, 0.03, 0.05, 0.72 * mark_a))
	draw_arc(m, MARK_R - 8.0, 0.0, TAU, 32, Color(col, mark_a), 3.0, true)
	draw_arc(m, MARK_R - 3.0, 0.0, TAU, 32, Color(col, 0.35 * mark_a * beat), 2.0, true)
	# двойной шеврон внутрь экрана — куда пойдут
	for step in [-5.0, 4.0]:
		var cc: Vector2 = m + n * step
		var line := PackedVector2Array([cc - u * ARROW * 0.6 - n * 5.0, cc + n * 3.0,
			cc + u * ARROW * 0.6 - n * 5.0])
		draw_polyline(line, Color(col.lightened(0.2), mark_a), 3.5, true)
	# «×N» рядом с печатью, вдоль края — не на пути шеврона
	var label := "×%d" % int(t["n"])
	var lw := LegionUi.num_font().get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 18).x
	var side_sign := -1.0 if (u.dot(m) > u.dot(ws * 0.5)) else 1.0
	var lc := m + u * side_sign * (MARK_R - 4.0 + lw * 0.5 + 2.0)
	LegionUi.draw_number(self, lc + Vector2(-lw * 0.5, 7.0), label, 18,
		Color(col.lightened(0.35), mark_a))


func _covered(p: Vector2) -> bool:
	for r in avoid:
		if r.grow(MARK_R * 0.6).has_point(p):
			return true
	return false


## Красная виньетка: четыре полосы от краёв внутрь, по вершинам — прозрачность.
func _draw_vignette(alpha: float) -> void:
	var ws := LegionCfg.WORLD_SIZE
	var w := LegionCfg.HUD_VIGNETTE_W
	var c := Color(0.85, 0.05, 0.04, alpha)
	var z := Color(0.85, 0.05, 0.04, 0.0)
	var o := [Vector2.ZERO, Vector2(ws.x, 0.0), ws, Vector2(0.0, ws.y)]
	var i := [Vector2(w, w), Vector2(ws.x - w, w), ws - Vector2(w, w), Vector2(w, ws.y - w)]
	for s in 4:
		var s2 := (s + 1) % 4
		draw_polygon(PackedVector2Array([o[s], o[s2], i[s2], i[s]]),
			PackedColorArray([c, c, z, z]))
