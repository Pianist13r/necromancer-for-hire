class_name LegionBuilding
extends Node2D
##
## Постройка штата (DESIGN_V15 §5, §12 п.4): вид бойцов, уровень, штат и время возрождения.
## Армия = сумма штатов: погибший боец освобождает СВОЁ штатное место, и у каждого места
## свой таймер возрождения — двое, павшие с разницей 3 с, вернутся с разницей 3 с (очередь
## постройки этого бы не дала). Новые места (постройка, улучшение, захват склепа) заполняются
## по бойцу раз в STAFF_FILL_STEP — «смена выходит из двери», а не весь штат одним кадром.
##
## Три источника: Котёл (без своей отрисовки — спрайт Котла рисует мир), постройка на
## участке (спрайт art1 `assets/legion/buildings/<вид>_<уровень>.png`; нет файла — процедурный
## домик) и склеп (рисует себя сам, постройка — его ребёнок). Тикает её LegionStaff, а не
## _process: порядок шага кадра задаёт мир.
##

const SOURCE_CAULDRON := &"cauldron"
const SOURCE_PLOT := &"plot"
const SOURCE_CRYPT := &"crypt"
const ARTWORK_DEFAULT := &"default"
const ARTWORK_VIEW_SCRIPT := preload("res://scripts/legion/building_artwork_view.gd")

## Кэш спрайтов построек на весь процесс: у всех построек одного вида и уровня одна текстура.
static var _sprites: Dictionary = {}

var world: LegionWorld = null
## Сторона боя (PvpSide.index): чьих бойцов выпускает; Котёл стороны — тоже постройка.
var side := 0
var kind: StringName = LegionCfg.KIND_LABORER
var source: StringName = SOURCE_PLOT
var level := 1
## Итоговый штат и время возрождения — уже с поправками кампании.
var cap := 0
var respawn_t := 6.0
## Точка рождения (вход). entry_ring.y > 0 — рождение кольцом вокруг входа (Котёл) или веером
## перед дверью (площадка).
var entry := Vector2.ZERO
var entry_ring := Vector2.ZERO
## Склеп потерян (или оспорен): таймеры мест стоят, новых бойцов нет до возврата.
var frozen := false
## Сколько душ вложено (цена + улучшения) — база возврата при продаже.
var invested := 0
var plot_id := ""
## Перк «Бодрый выход»: вернувшийся из возрождения боец быстрее идёт в строй.
var brisk_exit := false

## Штатные места: боец (или null), остаток таймера возрождения, «новое» место (ждёт шага 0,4 с).
var slot_unit: Array[Legionnaire] = []
var slot_t := PackedFloat32Array()
var slot_fresh := PackedByteArray()
## Визуальный переключатель для A/B-кадров; игровые данные и командные акценты не меняет.
var artwork_variant: StringName = ARTWORK_DEFAULT

var _fill_cd := 0.0
var _brisk: Array[Legionnaire] = []
var _brisk_t := PackedFloat32Array()
var _drawn_alive := -1
var _artwork_view: Node2D = null


func configure(
	w: LegionWorld, new_kind: StringName, new_source: StringName, at: Vector2
) -> LegionBuilding:
	world = w
	kind = new_kind
	source = new_source
	position = at
	entry = at + (LegionCfg.BUILDING_ENTRY_OFFSET if source == SOURCE_PLOT else Vector2.ZERO)
	if source == SOURCE_PLOT:
		entry_ring = LegionCfg.BUILDING_ENTRY_RING
	return self


func _ready() -> void:
	if source != SOURCE_PLOT:
		return
	_artwork_view = ARTWORK_VIEW_SCRIPT.new()
	_artwork_view.name = "BuildingArtwork"
	add_child(_artwork_view)
	_refresh_artwork()


func set_artwork_variant(variant: StringName) -> void:
	artwork_variant = variant
	_refresh_artwork()


func refresh_artwork() -> void:
	_refresh_artwork()


func _refresh_artwork() -> void:
	if not is_instance_valid(_artwork_view):
		return
	_artwork_view.call(
		"configure",
		sprite("%s_%d" % [String(kind), level]),
		LegionCfg.BUILDING_SPRITE_W,
		LegionCfg.BUILDING_SPRITE_ANCHOR_Y
	)
	_artwork_view.call("set_variant", _resolved_artwork_variant(artwork_variant))
	if world != null and world.harmony != null:
		set_tone(world.harmony.tone(position))


## Тонировка рисунка под землю собранной карты (D-CX-08; LegionWorld.apply_harmony). Подпись
## штата и акцент вида — отдельно, их цвет не трогаем.
func set_tone(color: Color) -> void:
	if is_instance_valid(_artwork_view):
		_artwork_view.call("set_tint", color)
		if world != null and world.harmony != null:
			_artwork_view.call("set_ground_shadow", world.harmony.contact_tint(position))


func _resolved_artwork_variant(requested: StringName) -> StringName:
	if requested != ARTWORK_DEFAULT:
		return requested
	if kind == LegionCfg.KIND_LABORER and level == 1:
		return &"painterly"
	return &"original"


## Задать штат и возрождение (постройка, улучшение). Штат только растёт: добавленные места —
## «новые» и ждут шага заполнения; идущие таймеры павших не пересчитываются.
func set_staff(new_cap: int, new_respawn: float) -> void:
	respawn_t = new_respawn
	while slot_unit.size() < new_cap:
		slot_unit.append(null)
		slot_t.append(0.0)
		slot_fresh.append(1)
	cap = slot_unit.size()
	queue_redraw()


## Стартовый штат (§12 п.4): выдать все пустые места сразу, до первой волны. Возвращает,
## сколько родилось (потолок армии соблюдается через budget).
func fill_now(budget: int) -> int:
	var n := 0
	for i in slot_unit.size():
		if n >= budget:
			break
		if slot_unit[i] == null:
			_spawn_into(i, false)
			n += 1
	return n


## Шаг постройки; budget — сколько ещё бойцов можно родить до ARMY_HARD_CAP. Возвращает число
## родившихся.
func tick(dt: float, budget: int) -> int:
	_tick_brisk(dt)
	if frozen:
		return 0
	_fill_cd -= dt
	var n := 0
	for i in slot_unit.size():
		if slot_unit[i] != null:
			continue
		if slot_fresh[i] != 0:
			if _fill_cd > 0.0 or n >= budget:
				continue
			_fill_cd = LegionCfg.STAFF_FILL_STEP
			_spawn_into(i, false)
			n += 1
			continue
		slot_t[i] -= dt
		# место ждёт потолка армии с нулевым таймером: освободится запас — родится сразу
		if slot_t[i] <= 0.0 and n < budget:
			_spawn_into(i, true)
			n += 1
			# «Штатное расписание»: возрождённый приводит напарника — ещё одно ждущее место
			# заполняется сразу, не дожидаясь своего таймера (в пределах потолка армии)
			if world.item_add(&"twin_spawn", side) > 0.0 and n < budget:
				var j := _waiting_slot()
				if j >= 0:
					_spawn_into(j, true)
					n += 1
					world.stats["item_twins"] = int(world.stats.get("item_twins", 0)) + 1
	return n


## Место павшего, ждущее возрождения (-1 — нет): напарник «Штатного расписания» занимает его.
func _waiting_slot() -> int:
	for i in slot_unit.size():
		if slot_unit[i] == null and slot_fresh[i] == 0 and slot_t[i] > 0.0:
			return i
	return -1


## Боец этой постройки пал: его место ждёт respawn_t (свой таймер у каждого места).
func on_unit_lost(u: Legionnaire) -> void:
	var i := slot_unit.find(u)
	if i < 0:
		return
	slot_unit[i] = null
	slot_t[i] = respawn_t
	slot_fresh[i] = 0
	queue_redraw()


## Продажа: бойцы постройки гибнут без возрождения, места исчезают.
func dismiss_all() -> void:
	var staff := slot_unit.duplicate()
	slot_unit.clear()
	slot_t.clear()
	slot_fresh.clear()
	cap = 0
	for u: Legionnaire in staff:
		if u != null and u.alive:
			u.home = null
			u._die()


func alive_count() -> int:
	var n := 0
	for u in slot_unit:
		if u != null:
			n += 1
	return n


## Мест павших, ждущих возрождения. Новые места (после постройки и улучшения) не считаются:
## они и так заполняются сами по бойцу в STAFF_FILL_STEP — платить за них было бы обманом.
func waiting_count() -> int:
	var n := 0
	for i in slot_unit.size():
		if slot_unit[i] == null and slot_fresh[i] == 0:
			n += 1
	return n


## Срочный найм (D-0927-135): места павших занимаются сразу, без таймера возрождения.
## budget — потолок армии. Возвращает, сколько родилось.
func rush_fill(budget: int) -> int:
	var n := 0
	for i in slot_unit.size():
		if n >= budget:
			break
		if slot_unit[i] == null and slot_fresh[i] == 0:
			_spawn_into(i, true)
			n += 1
	return n


## Сколько секунд до ближайшего возрождения (для подсказок/HUD); INF — ждать некого.
func next_respawn() -> float:
	var best := INF
	for i in slot_unit.size():
		if slot_unit[i] == null and slot_fresh[i] == 0:
			best = minf(best, maxf(0.0, slot_t[i]))
	return best


func _spawn_into(i: int, respawned: bool) -> void:
	var u := world.spawn_unit(kind, _spawn_point(), self)
	slot_unit[i] = u
	slot_t[i] = 0.0
	slot_fresh[i] = 0
	if respawned and brisk_exit:
		# своя копия чисел вида на 3 с: общий словарь LegionCfg.UNIT_KINDS трогать нельзя
		var fast := u.spec.duplicate()
		fast["speed"] = float(fast["speed"]) * LegionCfg.BRISK_EXIT_MULT
		u.spec = fast
		_brisk.append(u)
		_brisk_t.append(LegionCfg.BRISK_EXIT_TIME)
	queue_redraw()


func _tick_brisk(dt: float) -> void:
	for j in range(_brisk.size() - 1, -1, -1):
		_brisk_t[j] -= dt
		if _brisk_t[j] > 0.0:
			continue
		var u := _brisk[j]
		if is_instance_valid(u):
			u.spec = LegionCfg.UNIT_KINDS[u.kind]
		_brisk.remove_at(j)
		_brisk_t.remove_at(j)


func _spawn_point() -> Vector2:
	if entry_ring.y <= 0.0:
		return entry if world.terrain.walkable(entry) else position
	if source == SOURCE_PLOT:
		return _plot_spawn()
	# Котёл и склеп — кругом (кольцо у Котла — резерв, D-0927-90)
	for attempt in 12:
		var p := (
			entry
			+ _mx(
				Vector2.from_angle(world.rng.randf() * TAU)
				* world.rng.randf_range(entry_ring.x, entry_ring.y)
			)
		)
		if world.terrain.walkable(p) and _off_road(p):
			return p
	return entry + _mx(Vector2(entry_ring.x, 0.0))


## B-365: смещение рождения от входа — зеркально у стороны на правой половине поля «Схватки».
## Тот же ГСЧ давал бы стороне справа те же смещения, что слева (не отражённые), и зеркальная
## позиция расходилась бы с первого шага. Одиночка (pvp = false) — смещение как есть.
func _mx(v: Vector2) -> Vector2:
	return world.side_dx(v, side)


## B-083 («Проходная»: будка у дороги, протёкшие шли мимо двери и убивали вахтёров при
## рождении): веер у двери — той стороной, что дальше от дороги. Из SPAWN_TRIES точек веера,
## проходимых и вне проезжей части, берётся случайная из тех, что не ближе SPAWN_ROAD_SAFE к оси
## дороги; таких нет — самая далёкая от дороги. Случайная, а не одна «лучшая»: стопку в одной
## точке накрывала одна печать нотариуса (B-037). Веер — нижней полуокружностью: перед дверью,
## не на крыше.
func _plot_spawn() -> Vector2:
	var safe: Array[Vector2] = []
	var best := Vector2.INF
	var best_d := -1.0
	for attempt in LegionCfg.SPAWN_TRIES:
		var p := (
			entry
			+ _mx(
				Vector2.from_angle(world.rng.randf() * PI)
				* world.rng.randf_range(entry_ring.x, entry_ring.y + LegionCfg.SPAWN_FAN_EXTRA)
			)
		)
		if not _door_reach(p) or not _off_road(p):
			continue
		var d := world.road_dist(p)
		if d >= LegionCfg.SPAWN_ROAD_SAFE:
			safe.append(p)
		if d > best_d:
			best_d = d
			best = p
	if not safe.is_empty():
		return safe[world.rng.randi() % safe.size()]
	if best != Vector2.INF:
		return best
	return _plot_fallback()


## Проверка verifier (B-083): веер 46 px и выбор «дальше от дороги» клали ~6 % рождений
## «Проходной» p4 за скальную полосу у нижнего края — 45 px по прямой, ~1019 px пешком, боец
## 40 с не вставал на линию. Точка рождения годна, только если она на карте (не за краем, где
## рельеф «проходим» ради ворот) и от двери до неё прямой отрезок по проходимой земле без
## препятствий (шаг — полклетки): тогда пешком до неё не дальше, чем по прямой.
func _door_reach(p: Vector2) -> bool:
	# край — по размеру мира карты (PvP 1600×900; одиночка — 1280×720), не по кадру одиночки
	var field := Rect2(Vector2.ZERO, world.world_size).grow(-LegionCfg.UNIT_RADIUS)
	if not field.has_point(p) or not world.terrain.walkable(p):
		return false
	var from := entry if world.terrain.walkable(entry) else position
	if world.terrain.segment_clear(from, p) != p:
		return false
	var steps := maxi(1, ceili(from.distance_to(p) / (LegionCfg.CELL * 0.5)))
	for k in range(1, steps):
		if not world.terrain.walkable(from.lerp(p, float(k) / float(steps))):
			return false
	return true


## v18 (Игорь 26.09: «здания у дороги вываливают бойцов на дорогу и блокируют»): площадка
## не рождает на проезжей части. Котёл и склеп — как раньше: они стоят у дорог по замыслу.
func _off_road(p: Vector2) -> bool:
	return source != SOURCE_PLOT or world.road_dist(p) >= LegionCfg.SPAWN_ROAD_CLEAR


## Веер у двери не нашёл места вне дороги (дверь в 26 px от оси — «Лабиринт», p1): обходим
## вход по кругу шире веера. Проходимых точек вне дороги несколько — берём случайную: одна
## «самая далёкая» рождала всех стопкой, и её накрывала одна печать нотариуса (B-037, урок B-018).
## Вне дороги ни одной — самая далёкая от дороги; совсем некуда — прежний запасной выход с
## проверкой проходимости (verifier 26.09).
func _plot_fallback() -> Vector2:
	var best := Vector2.INF
	var best_d := -1.0
	var clear: Array[Vector2] = []
	for k in 16:
		for r: float in [entry_ring.y, entry_ring.y + 16.0]:
			var p := entry + _mx(Vector2.from_angle(TAU * float(k) / 16.0) * r)
			if not _door_reach(p):
				continue
			var d := world.road_dist(p)
			if d >= LegionCfg.SPAWN_ROAD_CLEAR:
				clear.append(p)
			if d > best_d:
				best_d = d
				best = p
	if not clear.is_empty():
		return clear[world.rng.randi() % clear.size()]
	if best != Vector2.INF:
		return best
	return entry if world.terrain.walkable(entry) else position


# ── Отрисовка (только постройка на участке) ─────────────────────────────────


## Спрайт `<name>.png` из assets/legion/buildings; null — файла нет (рисуем заглушку).
static func sprite(sprite_name: String) -> Texture2D:
	if not _sprites.has(sprite_name):
		var path := LegionCfg.BUILDING_SPRITE_DIR + sprite_name + ".png"
		_sprites[sprite_name] = load(path) as Texture2D if ResourceLoader.exists(path) else null
	return _sprites[sprite_name]


## Прямоугольник спрайта шириной width, чья точка (0.5, anchor_y) ложится в начало координат:
## изометрическое основание постройки/участка — на точке участка из карты.
static func sprite_rect(tex: Texture2D, width: float, anchor_y: float) -> Rect2:
	var sz := tex.get_size() * (width / float(tex.get_width()))
	return Rect2(Vector2(-sz.x * 0.5, -sz.y * anchor_y), sz)


func _process(_dt: float) -> void:
	if source != SOURCE_PLOT:
		return
	var n := alive_count()
	if n != _drawn_alive:
		_drawn_alive = n
		queue_redraw()


func _draw() -> void:
	if world != null and world.pvp:
		PvpView.draw_marker(self, world, Vector2(0, 14), side, 14.0, 1.0)
	if source != SOURCE_PLOT:
		return
	var sz := LegionCfg.BUILDING_SIZE
	var top := -sz.y - 16.0
	var tex := sprite("%s_%d" % [String(kind), level])
	if tex != null:
		var rect := sprite_rect(
			tex, LegionCfg.BUILDING_SPRITE_W, LegionCfg.BUILDING_SPRITE_ANCHOR_Y
		)
		top = rect.position.y
	else:
		_draw_stub()
	var label := "%d/%d" % [alive_count(), cap]
	# подпись штата над крышей: у двери толпится свой же штат и закрывает всё, что ниже;
	# цвет вида — только акцентом, полоской под подписью
	var at := Vector2(-LegionCfg.BUILDING_SPRITE_W * 0.5, top - 4.0)
	var col: Color = LegionCfg.UNIT_KINDS[kind]["color"]
	draw_line(
		at + Vector2(LegionCfg.BUILDING_SPRITE_W * 0.35, 3.0),
		at + Vector2(LegionCfg.BUILDING_SPRITE_W * 0.65, 3.0),
		col,
		2.0
	)
	draw_string_outline(
		UiStyle.FONT_TEXT,
		at,
		label,
		HORIZONTAL_ALIGNMENT_CENTER,
		LegionCfg.BUILDING_SPRITE_W,
		PvpView.fs(world, LegionCfg.BUILDING_FONT_SIZE),
		3,
		Color(0, 0, 0, 0.85)
	)
	draw_string(
		UiStyle.FONT_TEXT,
		at,
		label,
		HORIZONTAL_ALIGNMENT_CENTER,
		LegionCfg.BUILDING_SPRITE_W,
		PvpView.fs(world, LegionCfg.BUILDING_FONT_SIZE),
		UiStyle.TEXT
	)


## Процедурный домик — только если спрайта art1 нет (сборка без ассетов).
func _draw_stub() -> void:
	var spec: Dictionary = LegionCfg.UNIT_KINDS[kind]
	var col: Color = spec["color"]
	var sz := LegionCfg.BUILDING_SIZE
	var body := Rect2(Vector2(-sz.x * 0.5, -sz.y), sz)
	draw_rect(Rect2(body.position + Vector2(3, 4), sz), Color(0, 0, 0, 0.35))
	draw_rect(body, Color(0.16, 0.14, 0.18))
	draw_rect(body, col, false, 2.0)
	var roof := PackedVector2Array(
		[
			Vector2(-sz.x * 0.5 - 5.0, -sz.y),
			Vector2(0.0, -sz.y - 16.0),
			Vector2(sz.x * 0.5 + 5.0, -sz.y),
		]
	)
	draw_colored_polygon(roof, col.darkened(0.35))
	draw_polyline(roof, col, 2.0, true)
	draw_rect(Rect2(Vector2(-6, -16), Vector2(12, 16)), Color(0.05, 0.04, 0.07))
	for k in level:
		draw_circle(Vector2(-sz.x * 0.5 + 6.0 + k * 8.0, -sz.y + 6.0), 2.6, UiStyle.GOLD)
