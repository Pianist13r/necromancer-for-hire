class_name LegionIntuit
extends Node2D
##
## Слой «интуитивнее» (slow/intuit, Игорь 26.09: «пружинный срыв, прицеливание рогатки и абилки
## вовремя — не интуитивные; надо интуитивнее их сделать и обучать им лучше»). Только вид и
## советы: бой не читает отсюда ничего, world.rng не трогаем — скан лишь смотрит на мир.
##
## Что показывает:
##  - золотой участок: враг в зоне «Точно!» (геометрия рогатки при полной силе — поле,
##    ContractField.seg_gold) — участок светится золотом и без натяжки; щелчок ПКМ по нему даёт
##    «Точно!» (сам щелчок — в ContractField._click_release). В зоне оглушённый — «×2».
##    D-0927-53: нотариус или призрак, который может перехватить натиск участка, гасит золото
##    (ContractField.strike_clear);
##  - пружина: прогиб ≥ SPRING_MIN — метка «пружина ×N» (N — множитель урона натиска), у порога
##    прорыва — тревожная;
##  - навыки: слот на панели пульсирует и у места на поле появляется подпись, когда навык готов и
##    полезен (Ку — Юрист зачитывает, нотариус в замахе, толпа давит линию; Е — строй
##    прогибается; Дубль-вэ — свежие трупы у фронта). Подпись одного типа — не чаще HINT_CD;
##  - оглушённые враги — искры над головой;
##  - фигуры (D-1002-03): у треугольника набрана доля мест к обряду — «сорви: «Обряд!»»; линию
##    продавливают, а квадрат открыт — «квадрат «Каре» давку держит».
## Советы (подписи, пульс слотов) выключаются галочкой «Подсказки» (Settings.hints_enabled);
## золото, пружина и оглушённые — состояние боя, видны всегда.
##
## Скан — раз в SCAN_PERIOD реального времени (и явным scan() из тестов), только в бою игрока:
## при боте некому подсказывать. Враги раскладываются по своей сетке в момент скана: сетка мира
## после шага устарела (уборка трупов сдвигает индексы foes).
##

const SLOT_Q := 0
const SLOT_W := 1
const SLOT_E := 2
const TYPES: Array[StringName] = [&"q", &"w", &"e", &"gold", &"spring", &"call", &"door", &"rite",
	&"square"]

var world: LegionWorld = null

## Contract -> PackedByteArray по участкам: 1 — золото, 3 — золото и в зоне оглушённый.
var _gold: Dictionary = {}
## Contract -> PackedFloat32Array: доля прогиба пружины (0 — не пружина).
var _spring: Dictionary = {}
## Полезен ли навык сейчас (готов и есть работа) и где эта работа.
var _useful: Array[bool] = [false, false, false]
var _useful_at: Array[Vector2] = [Vector2.ZERO, Vector2.ZERO, Vector2.ZERO]
var _useful_text: Array[String] = ["", "", ""]
## Когда (world.now) последний раз показана подпись типа; сколько раз показана (тесты, замер).
var _last: Dictionary = {}
var _shown: Dictionary = {}
## Живые подписи на поле: {type, slot, pos, text, t0}.
var _labels: Array[Dictionary] = []
## Типы советов, по которым игрок уже сделал правильное действие в этом бою (on_done) — больше
## не показываются (D-0927-49, Игорь: «чтоб поменьше всего происходило»).
var _done: Dictionary = {}
var _stunned: Array[Foe] = []
## Кандидаты советов «золото» и «пружина» этого скана — предлагаются ПОСЛЕ навыков: совет навыка
## важнее, а на поле одновременно не больше HINT_MAX подписей.
var _gold_hint := Vector2.INF
var _spring_hint := Vector2.INF
## Прямоугольники уже нарисованных в этом кадре подписей — следующая не ложится поверх.
var _placed: Array[Rect2] = []
var _scan_t := 0.0
## B-078: с какого world.now длится затишье (-1 — не затишье).
var _lull_from := -1.0
## B-124: недавние гибели своих {pos, t} (окно DOOR_WINDOW).
var _door_deaths: Array[Dictionary] = []
# своя сетка врагов (голова списка на клетку + «следующий»), без аллокаций на скан
var _gw := 0
var _gh := 0
var _head := PackedInt32Array()
var _next := PackedInt32Array()
var _foes: Array[Foe] = []
## Приманки натиска этого скана (нотариусы, призраки) — для ContractField.strike_clear.
var _lures: Array[Foe] = []
var _in_zone: Array[Foe] = []   ## враги зоны проверяемого участка (_zone с collect)


func setup(w: LegionWorld) -> void:
	world = w
	name = "Intuit"
	_gw = ceili((LegionCfg.WORLD_SIZE.x + 2.0 * LegionCfg.SPATIAL_MARGIN) / IntuitCfg.GRID_CELL)
	_gh = ceili((LegionCfg.WORLD_SIZE.y + 2.0 * LegionCfg.SPATIAL_MARGIN) / IntuitCfg.GRID_CELL)
	_head.resize(_gw * _gh)
	w.match_started.connect(func(_id: String) -> void: reset())
	# правильные действия игрока гасят свои советы: срыв пружиной, каст навыка по подсказке
	# («Точно!» щелчком по золоту сообщает поле — ContractField._click_release)
	# таяние прогнутого участка — не действие игрока (verify-intuit b38a391): совет остаётся
	w.spring_released.connect(func(c: Contract, s: int, _b: float) -> void:
		if world.my_field() != null and world.my_field().human_input \
				and c.release_causes.get(s, &"") != &"melt":
			on_done(&"spring"))
	w.wave_called.connect(func(_i: int, _bonus: int) -> void: on_done(&"call"))
	w.unit_died.connect(_on_unit_died)
	w.hero_cast.connect(func(slot: int, _at: Vector2) -> void:
		if slot >= 0 and slot < 3 and _useful[slot]:
			on_done(TYPES[slot]))


func reset() -> void:
	_gold.clear()
	_spring.clear()
	_useful = [false, false, false]
	_last.clear()
	_shown.clear()
	_labels.clear()
	_done.clear()
	_stunned.clear()
	_foes.clear()
	_lures.clear()
	_in_zone.clear()
	_scan_t = 0.0
	_lull_from = -1.0
	_door_deaths.clear()


func _process(delta: float) -> void:
	if world == null or world.phase != LegionWorld.Phase.BATTLE or world.paused \
			or world.my_field() == null:
		return
	# --dev intuit=1: подсказки и при боте — кадры приёмки вида «глазами игрока» (бой их не читает)
	if not world.my_field().human_input and not world.dev.has("intuit"):
		return
	_scan_t -= delta
	if _scan_t <= 0.0:
		_scan_t = IntuitCfg.SCAN_PERIOD
		scan()
	queue_redraw()


# ── Запросы (поле, панель навыков, тесты) ──────────────────────────────────────

func is_gold(c: Contract, seg: int) -> bool:
	var g: PackedByteArray = _gold.get(c, PackedByteArray())
	return seg >= 0 and seg < g.size() and g[seg] != 0 and c.seg_alive(seg)


func gold_stunned(c: Contract, seg: int) -> bool:
	var g: PackedByteArray = _gold.get(c, PackedByteArray())
	return seg >= 0 and seg < g.size() and g[seg] == 3


## Множитель урона пружины участка сейчас; 0 — участок не пружина (прогиб < SPRING_MIN).
func spring_mult(c: Contract, seg: int) -> float:
	var b := _spring_bend(c, seg)
	return 0.0 if b <= 0.0 else 1.0 + LegionCfg.SPRING_DMG * b


func spring_alarm(c: Contract, seg: int) -> bool:
	return _spring_bend(c, seg) >= IntuitCfg.SPRING_ALARM


## «пружина ×1,3» — множитель урона одной цифрой после запятой, по-русски.
func spring_text(c: Contract, seg: int) -> String:
	var m := spring_mult(c, seg)
	if m <= 0.0:
		return ""
	return "пружина ×" + ("%.1f" % m).replace(".", ",")


func useful(slot: int) -> bool:
	return slot >= 0 and slot < _useful.size() and _useful[slot]


## Где работа для навыка (подпись и то, куда целиться); Vector2.INF — работы нет.
func hint_pos(slot: int) -> Vector2:
	return _useful_at[slot] if useful(slot) else Vector2.INF


func hints_shown(type: StringName) -> int:
	return int(_shown.get(type, 0))


## Игрок сделал то, чему учит совет type: до конца боя его больше нет, висящая подпись гаснет.
func on_done(type: StringName) -> void:
	_done[type] = true
	for i in range(_labels.size() - 1, -1, -1):
		if _labels[i]["type"] == type:
			_labels.remove_at(i)


## Идёт урок (плашка на экране): советы-подписи молчат и не тратят лимит HINT_TIMES_MAX. Почему
## (verify 27.09): урок «пружина» и совет «сорви — ударит сильнее» говорили одно дважды, а
## совет «Е — строй прогибается» под уроком «пружина» противоречил ему (Е гасит прогиб, который
## урок просит набрать); «Точно!» и «золотой — щёлкни ПКМ» — две инструкции сразу. Золото,
## метка пружины, «×2», искры оглушённых и тихий пульс слота — состояние боя, видны и при уроке.
func lesson_on() -> bool:
	return world != null and world.tutorial != null and world.tutorial.active \
		and world.tutorial.step() >= 0


## Совет типа type молчит из-за урока (B-081): урок начала боя или первые ADVICE_QUIET_T секунд
## урока посреди боя — все; дальше — только спорящие с уроком (LessonsCfg.MUTES). Раньше урок,
## который игрок не делает, глушил все советы до конца боя.
func muted(type: StringName) -> bool:
	if not lesson_on():
		return false
	var tut := world.tutorial
	if bool(tut.lesson().get("start", false)) \
			or world.now - tut.entered_at < LessonsCfg.ADVICE_QUIET_T:
		return true
	return (LessonsCfg.MUTES.get(tut.step_kind(), []) as Array).has(type)


func is_done(type: StringName) -> bool:
	return _done.has(type)


func stunned_count() -> int:
	return _stunned.size()


## Пульс слота навыка на панели 0..1: подпись висит — ярко, навык просто полезен — тихо.
func slot_glow(slot: int) -> float:
	if not Settings.hints_enabled() or not useful(slot):
		return 0.0
	for l in _labels:
		if int(l.get("slot", -1)) == slot:
			return 1.0
	return IntuitCfg.SLOT_GLOW_SOFT


func _spring_bend(c: Contract, seg: int) -> float:
	var s: PackedFloat32Array = _spring.get(c, PackedFloat32Array())
	if seg < 0 or seg >= s.size() or not c.seg_alive(seg):
		return 0.0
	return s[seg]


# ── Скан ──────────────────────────────────────────────────────────────────────

func scan() -> void:
	if world == null or world.my_field() == null:
		return
	# погасшие подписи — до новых предложений: иначе они держали бы место под потолком HINT_MAX
	var t := world.now
	for i in range(_labels.size() - 1, -1, -1):
		if t - float(_labels[i]["t0"]) > IntuitCfg.HINT_SHOW or t < float(_labels[i]["t0"]) \
				or muted(_labels[i]["type"]):   # урок встал на плашку — спорящий совет уступает
			_labels.remove_at(i)
	_build_grid()
	world.my_field().pack_lures(_lures)
	_scan_contracts()
	_scan_abilities()
	if _gold_hint != Vector2.INF:
		_offer(&"gold", -1, _gold_hint, IntuitCfg.HINT_GOLD)
	if _spring_hint != Vector2.INF:
		_offer(&"spring", -1, _spring_hint, IntuitCfg.HINT_SPRING)
	_scan_lull()
	_scan_door()
	_scan_figures()
	_stunned.clear()
	for f in _foes:
		if f.is_stunned():
			_stunned.append(f)


func _build_grid() -> void:
	_head.fill(-1)
	_foes.clear()
	_lures.clear()
	for f in world.foes:
		if f.is_active():
			_foes.append(f)
			if LegionGrid.is_lure(f):
				_lures.append(f)
	_next.resize(_foes.size())
	for i in _foes.size():
		var c := _cell(_foes[i].position)
		_next[i] = _head[c]
		_head[c] = i


func _gx(x: float) -> int:
	return clampi(int((x + LegionCfg.SPATIAL_MARGIN) / IntuitCfg.GRID_CELL), 0, _gw - 1)


func _gy(y: float) -> int:
	return clampi(int((y + LegionCfg.SPATIAL_MARGIN) / IntuitCfg.GRID_CELL), 0, _gh - 1)


func _cell(p: Vector2) -> int:
	return _gy(p.y) * _gw + _gx(p.x)


## Зона удара — тот же прямоугольник и те же допуски на радиус врага, что у
## ContractField.zone_has_foe. 0 — пусто, 1 — враг, 3 — и среди них оглушённый.
## collect — сложить всех врагов зоны в _in_zone (без раннего выхода).
func _zone(center: Vector2, dir: Vector2, half_w: float, depth: float, collect := false) -> int:
	if dir.is_zero_approx():
		return 0
	var side := dir.orthogonal()
	var corners := [center + side * half_w, center - side * half_w,
		center + side * half_w + dir * depth, center - side * half_w + dir * depth]
	var box := Rect2(corners[0], Vector2.ZERO)
	for q: Vector2 in corners:
		box = box.expand(q)
	box = box.grow(IntuitCfg.GRID_PAD)
	var out := 0
	if collect:
		_in_zone.clear()
	for gy in range(_gy(box.position.y), _gy(box.end.y) + 1):
		for gx in range(_gx(box.position.x), _gx(box.end.x) + 1):
			var i := _head[gy * _gw + gx]
			while i != -1:
				var f := _foes[i]
				var v := f.position - center
				var along := v.dot(dir)
				if along >= -f.radius and along <= depth + f.radius \
						and absf(v.dot(side)) <= half_w + f.radius:
					out = maxi(out, 3 if f.is_stunned() else 1)
					if collect:
						_in_zone.append(f)
					elif out == 3:
						return out
				i = _next[i]
	return out


func _scan_contracts() -> void:
	var field := world.my_field()
	var press := world.press_on()
	var seen: Dictionary = {}
	_gold_hint = Vector2.INF
	_spring_hint = Vector2.INF
	for c in field.contracts:
		seen[c] = true
		var n := c.seg_count()
		var g := PackedByteArray()
		g.resize(n)
		var sp := PackedFloat32Array()
		sp.resize(n)
		var best := 0
		for s in n:
			if not c.seg_alive(s):
				continue
			var z := _seg_zone(field, c, s)
			g[s] = z
			best = maxi(best, z)
			if press:
				var b := c.bend_frac(s)
				if b >= LegionCfg.SPRING_MIN:
					sp[s] = b
					if _spring_hint == Vector2.INF:
						_spring_hint = c.seg_center(s)
		if c.shaped() and best > 0:
			# кольцо и фигуры срываются целиком: враг у любого участка — золотая вся фигура
			# (ContractField.ring_aim — то же правило у натяжки)
			for s in n:
				if c.seg_alive(s):
					g[s] = best
		if best > 0 and _gold_hint == Vector2.INF:
			for s in n:
				if g[s] != 0:
					# фигура и кольцо золотые целиком — совет над строем, не на верхнем участке
					_gold_hint = fig_hint_pos(c, IntuitCfg.HINT_GOLD) if c.shaped() else c.seg_center(s)
					break
		_gold[c] = g
		_spring[c] = sp
	for c in _gold.keys():
		if not seen.has(c):
			_gold.erase(c)
			_spring.erase(c)


## Зона «Точно!» участка при полной силе — числа ContractField.sling_aim/ring_aim.
## Зона — по реальному удару участка при полной силе (ContractField.seg_strike): нет стоящих
## бойцов или треугольник — золота нет; восьмёрка — к центру другой петли; кольцо — по ring_out.
func _seg_zone(field: ContractField, c: Contract, s: int) -> int:
	var hit := field.seg_strike(c, s, 1.0)
	if hit.is_empty():
		return 0
	var center := c.seg_center(s)
	var half_w := field.seg_half_len(c, s)
	# D-0927-53: приманка может перехватить натиск — золота нет (то же правило, что у seg_gold);
	# B-086: и без приманок — золото, только если врага зоны возьмёт хоть один стоящий боец
	var z := _zone(center, hit["dir"], half_w, hit["depth"], true)
	if z != 0 and not field.strike_clear(c, s, center, hit["dir"], half_w, hit["depth"],
			_in_zone):
		return 0
	return z


## B-124: печати выкашивают бойцов у двери постройки («Два отдела»: средние Бытовки 0/11) —
## за DOOR_WINDOW секунд у входа постройки легло DOOR_DEATHS бойцов, а нотариус стоит в
## DOOR_SIGNER_R от неё: совет у постройки — сорвать строй на нотариуса (снимает 3–4 за раз).
func _scan_door() -> void:
	var t := world.now
	while not _door_deaths.is_empty() and t - float(_door_deaths[0]["t"]) > IntuitCfg.DOOR_WINDOW:
		_door_deaths.pop_front()
	if _door_deaths.size() < IntuitCfg.DOOR_DEATHS:
		return
	for b in world.buildings:
		if b.source != LegionBuilding.SOURCE_PLOT or b.frozen:
			continue
		var n := 0
		for d in _door_deaths:
			if (d["pos"] as Vector2).distance_to(b.entry) <= IntuitCfg.DOOR_R:
				n += 1
		if n < IntuitCfg.DOOR_DEATHS:
			continue
		for f in _foes:
			if f.type_id == "signer" and not f.ghost \
					and f.position.distance_to(b.entry) <= IntuitCfg.DOOR_SIGNER_R:
				_offer(&"door", -1, b.position, IntuitCfg.HINT_DOOR)
				return


## Советы фигур (D-1002-03). Сделал своё — совет гаснет до конца боя: обряд случился, квадрат
## начерчен.
func _scan_figures() -> void:
	var field := world.my_field()
	if int(world.stats.get("rites", 0)) > 0:
		on_done(&"rite")
	var square_open := bool(field.shapes.get(ContractShape.SQUARE, true))
	var pressed := Vector2.INF
	for c in field.contracts:
		if c.figure == ContractShape.SQUARE:
			on_done(&"square")
		elif c.figure == ContractShape.TRIANGLE and c.alive() and _rite_ready(c) \
				and not field.fig_popup_alive(c):   # B-390 (2): «Обряд начат» ещё не погасла
			_offer(&"rite", -1, fig_hint_pos(c), IntuitCfg.HINT_RITE)
		elif not c.shaped() and pressed == Vector2.INF:
			for s in c.seg_count():
				if spring_alarm(c, s):
					pressed = c.seg_center(s)
					break
	if square_open and pressed != Vector2.INF:
		_offer(&"square", -1, pressed, IntuitCfg.HINT_SQUARE)


## Точка совета о фигуре (кольце): подпись встаёт над строем, выше голов верхнего ряда
## (ContractField.fig_top), как у квадрата; нет места до полосы HUD — под нижним рядом. Было —
## у центра треугольника, поперёк бойцов (кадр 6_tri_posted, 02.10).
func fig_hint_pos(c: Contract, text := IntuitCfg.HINT_RITE) -> Vector2:
	var size := float(PvpView.fs(world, IntuitCfg.HINT_SIZE))
	var top := ContractField.fig_top(c)
	var w := UiStyle.FONT_TITLE.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1,
		int(size)).x
	# место сверху — по настоящим панелям HUD, а не полосой 64 px (B-390 (1))
	if ContractField.room_above(world, top, size, w, IntuitCfg.HINT_RISE):
		return top + Vector2(0.0, IntuitCfg.HINT_UP)
	return Vector2(c.center.x,
		ContractField.fig_bottom(c) + size + IntuitCfg.HINT_RISE + IntuitCfg.HINT_UP)


## Совет «сорви: «Обряд!»» — только у ЗАРЯЖЕННОГО треугольника (D-1002 §1): ранний срыв ульты
## не даёт, и совет звал бы не туда.
static func _rite_ready(c: Contract) -> bool:
	return c.fill() >= FigureCfg.RITE_FILL - 0.0001 and c.charge_ready()


func _on_unit_died(u: Legionnaire) -> void:
	_door_deaths.append({"pos": u.position, "t": world.now})


## B-078: затишье — волну можно звать (F), а ни один враг не ближе LULL_R к бойцам и Котлу уже
## LULL_T секунд боя (на «Развилке» до первого контакта ~50 с без дела). Совет — у панели волн.
func _scan_lull() -> void:
	var wr := world.wave_runner
	# «Схватка» (P7, B-341): волны общие по часам, F там не работает (call_wave) — совет лгал бы
	if world.pvp or wr == null or not wr.can_call() or _contact():
		_lull_from = -1.0
		return
	if _lull_from < 0.0 or world.now < _lull_from:
		_lull_from = world.now
	if world.now - _lull_from >= IntuitCfg.LULL_T:
		# под панелью волн (её высота зависит от числа строк): подпись встаёт на HINT_UP выше точки
		var at := IntuitCfg.CALL_HINT_AT
		var panel: Rect2 = world.hud.preview_rect() if world.hud != null else Rect2()
		if panel.has_area():
			at = Vector2(panel.get_center().x, panel.end.y + IntuitCfg.HINT_UP + IntuitCfg.CALL_HINT_GAP)
		_offer(&"call", -1, at, IntuitCfg.HINT_CALL)


## Враг ближе LULL_R к бойцу или Котлу — бой идёт, звать волну советовать незачем.
func _contact() -> bool:
	for f in _foes:
		if f.position.distance_to(world.cauldron_pos) <= IntuitCfg.LULL_R \
				or world.grid.nearest_unit(f.position, IntuitCfg.LULL_R) != null:
			return true
	return false


func _scan_abilities() -> void:
	var hero := world.my_hero()
	for i in 3:
		_useful[i] = false
	if hero == null:
		return
	if _slot_ready(hero, SLOT_Q):
		_find_q()
	if _slot_ready(hero, SLOT_E):
		_find_e()
	if _slot_ready(hero, SLOT_W):
		_find_w(hero)
	for i in 3:
		if _useful[i]:
			_offer(TYPES[i], i, _useful_at[i], _useful_text[i])


func _slot_ready(hero: LegionHero, slot: int) -> bool:
	# D-0927-140: без маны навык не зовём — подсказка звала бы на отказ
	return hero.is_unlocked(slot) and hero.cd_left(slot) <= 0.0 \
		and world.can_pay_ability(slot, world.local_side)


func _mark(slot: int, at: Vector2, text: String) -> void:
	_useful[slot] = true
	_useful_at[slot] = at
	_useful_text[slot] = text


## Ку: Юрист зачитывает → нотариус в замахе → толпа давит линию (первое найденное — важнее).
func _find_q() -> void:
	var signer: Foe = null
	for f in _foes:
		if f.is_stunned():
			continue
		if f.type_id == "lawyer" and f.law_read_t >= 0.0:
			_mark(SLOT_Q, f.position, IntuitCfg.HINT_Q_LAWYER)
			return
		if signer == null and f.type_id == "signer" and f.stamp_t >= 0.0:
			signer = f
	if signer != null:
		_mark(SLOT_Q, signer.position, IntuitCfg.HINT_Q_SIGNER)
		return
	if not world.press_on():
		return
	for c in world.my_field().contracts:
		for s in mini(c.seg_count(), c.press_mass.size()):
			if c.seg_alive(s) and c.press_mass[s] >= IntuitCfg.Q_CROWD_MASS \
					and c.bend_frac(s) >= IntuitCfg.Q_CROWD_BEND:
				_mark(SLOT_Q, c.press_sum[s] / c.press_mass[s], IntuitCfg.HINT_Q_CROWD)
				return


## Е: самый прогнутый участок со строем, прогиб ≥ E_BEND.
func _find_e() -> void:
	if not world.press_on():
		return
	var best := IntuitCfg.E_BEND
	var at := Vector2.INF
	for c in world.my_field().contracts:
		for s in c.seg_count():
			if not c.seg_alive(s) or c.bend_frac(s) < best or c.seg_manned(s) <= 0:
				continue
			best = c.bend_frac(s)
			at = c.seg_center(s)
	if at != Vector2.INF:
		_mark(SLOT_E, at, IntuitCfg.HINT_E)


## Дубль-вэ: точка, где поднимется бригада из ≥ W_MIN_CORPSES свежих трупов, и рядом свой боец.
func _find_w(hero: LegionHero) -> void:
	var best := IntuitCfg.W_MIN_CORPSES - 1
	var at := Vector2.INF
	var seen := 0
	for list: Array in [world.foes, world._corpses]:
		for node in list:
			var f := node as Foe
			if f == null or not f.is_fresh_corpse() or f.has_meta(&"summoned") or not f.visible:
				continue
			seen += 1
			var n := hero.w_corpses(f.position).size()
			if n > best and world.grid != null and _unit_near(f.position):
				best = n
				at = f.position
	if seen >= IntuitCfg.W_MIN_CORPSES and at != Vector2.INF:
		_mark(SLOT_W, at, IntuitCfg.HINT_W)


func _unit_near(p: Vector2) -> bool:
	var r2 := IntuitCfg.W_FRONT_R * IntuitCfg.W_FRONT_R
	for u in world.units:
		if u.alive and u.position.distance_squared_to(p) <= r2:
			return true
	return false


## Совет типа type — подпись на поле, если советы включены и тип молчал HINT_CD секунд боя.
func _offer(type: StringName, slot: int, at: Vector2, text: String) -> void:
	if not Settings.hints_enabled() or muted(type):
		return   # плашка урока говорит сама — совет молчит и не тратит лимит (см. muted)
	if _done.has(type) or hints_shown(type) >= IntuitCfg.HINT_TIMES_MAX:
		return   # уже умеет или трижды сказали — дальше не надоедаем
	var t := world.now
	if _last.has(type) and t - float(_last[type]) < IntuitCfg.HINT_CD:
		return
	if _labels.size() >= IntuitCfg.HINT_MAX:
		return   # один совет на поле; тип не «сгорает» — предложится на следующем скане
	_last[type] = t
	_shown[type] = hints_shown(type) + 1
	_labels.append({"type": type, "slot": slot, "pos": at, "text": Controls.text(text), "t0": t})


# ── Отрисовка ─────────────────────────────────────────────────────────────────

func _draw() -> void:
	if world == null or world.phase != LegionWorld.Phase.BATTLE or world.my_field() == null:
		return
	var field := world.my_field()
	var ms := float(FxClock.ms()) * 0.001
	_placed.clear()
	for c: Contract in _gold.keys():
		if not field.contracts.has(c):
			continue
		for s in c.seg_count():
			if is_gold(c, s) and not field.is_grabbed(c, s):
				_draw_gold(c, s, ms)
			if spring_mult(c, s) > 0.0:
				_draw_spring(c, s, ms)
	for f in _stunned:
		if is_instance_valid(f) and f.alive:
			_draw_stun(f, ms)
	if Settings.hints_enabled():
		for l in _labels:
			_draw_label(l)


func _draw_gold(c: Contract, s: int, ms: float) -> void:
	var pulse := 0.5 + 0.5 * sin(ms * IntuitCfg.GOLD_PULSE_RATE)
	var col := LegionCfg.PERFECT_COLOR
	var poly := c.bent_poly(s)
	draw_polyline(poly, Color(col, 0.18 + 0.14 * pulse), IntuitCfg.GOLD_GLOW_W, true)
	draw_polyline(poly, Color(col, 0.75 + 0.25 * pulse), IntuitCfg.GOLD_W, true)
	# значок — за острием стрелки участка: туда и ударит «Точно!»
	var at := c.seg_center(s) + c.seg_dir(s) * IntuitCfg.GOLD_ICON_GAP
	var r := IntuitCfg.GOLD_ICON_R * (0.85 + 0.3 * pulse)
	_sparkle(at, r, col)
	# подпись совета не ложится на значок (кадр 1_gold: «щёлкни» закрывало искру)
	_placed.append(Rect2(at - Vector2(r, r), Vector2(r, r) * 2.0).grow(3.0))
	if gold_stunned(c, s):
		var mult := "×" + ("%.1f" % LegionCfg.STUNNED_CHARGE_MULT).replace(".", ",")
		_text(at + Vector2(r + 4.0, 6.0), mult, IntuitCfg.GOLD_STUN_SIZE, col, false)


## Четырёхлучевая искра: читается как «блеск» и на траве, и на камне (тёмная обводка).
func _sparkle(at: Vector2, r: float, col: Color) -> void:
	var pts := PackedVector2Array()
	for k in 8:
		var a := PI * 0.25 * k - PI * 0.5
		pts.append(at + Vector2.from_angle(a) * (r if k % 2 == 0 else r * 0.32))
	var ring := pts.duplicate()
	ring.append(pts[0])
	draw_polyline(ring, Color(0, 0, 0, 0.7), 3.0, true)
	draw_colored_polygon(pts, col)
	draw_circle(at, r * 0.22, Color(1, 1, 1, 0.9))


func _draw_spring(c: Contract, s: int, ms: float) -> void:
	var alarm := spring_alarm(c, s)
	var rate := IntuitCfg.SPRING_ALARM_RATE if alarm else IntuitCfg.SPRING_PULSE_RATE
	var pulse := 0.5 + 0.5 * sin(ms * rate)
	var col := LegionCfg.PRESS_COLOR if alarm else LegionCfg.SPRING_COLOR
	var bend := _spring_bend(c, s)
	var center := c.seg_center(s)
	# дуга пружины — снаружи красной шкалы давки, цветом пружины: «сжата — сорви»
	var r := LegionCfg.RUNE_TTL_R + IntuitCfg.SPRING_ARC_GAP
	var from := -PI * 0.5
	draw_arc(center, r, from, from + TAU * bend, 32, Color(0, 0, 0, 0.55),
		IntuitCfg.SPRING_ARC_W + 3.0, true)
	draw_arc(center, r, from, from + TAU * bend, 32, Color(col, 0.6 + 0.4 * pulse),
		IntuitCfg.SPRING_ARC_W + (2.0 * pulse if alarm else 0.0), true)
	var size := IntuitCfg.SPRING_ALARM_SIZE if alarm else IntuitCfg.SPRING_LABEL_SIZE
	size = roundi(size * (1.0 + 0.08 * pulse))
	if _tip_near(center):
		# над отрядом уже висит совет — не третья строка сверху, а коротко «×1,3» сбоку у дуги
		# (D-0927-49: над одной дракой не больше одной надписи)
		var short := spring_text(c, s).trim_prefix("пружина ")
		_text(center + Vector2(r + 6.0, size * 0.35), short, size, col, false)
		return
	_text(center + Vector2(0.0, -IntuitCfg.SPRING_LABEL_UP), spring_text(c, s), size, col, true)


## Совет висит рядом с точкой (над тем же отрядом).
func _tip_near(at: Vector2) -> bool:
	if not Settings.hints_enabled():
		return false
	var r2 := IntuitCfg.HINT_NEAR * IntuitCfg.HINT_NEAR
	for l in _labels:
		if (l["pos"] as Vector2).distance_squared_to(at) <= r2:
			return true
	return false


func _draw_stun(f: Foe, ms: float) -> void:
	var h := f.view.body_h if f.view != null else 40.0
	var head := LegionImpactFx.feet(f) - Vector2(0.0, h + IntuitCfg.STUN_UP)
	# орбита над головой цветом Ку (оглушает только Ку) — не путается с золотой искрой участка
	var rx := IntuitCfg.STUN_ICON_R
	var ry := rx * 0.4
	var orbit := PackedVector2Array()
	for k in 17:
		var a := TAU * k / 16.0
		orbit.append(head + Vector2(cos(a) * rx, sin(a) * ry))
	draw_polyline(orbit, Color(0, 0, 0, 0.6), 3.0, true)
	draw_polyline(orbit, Color(IntuitCfg.STUN_COLOR, 0.8), 1.5, true)
	for k in 3:
		var a := ms * IntuitCfg.STUN_SPIN + TAU * k / 3.0
		var p := head + Vector2(cos(a) * rx, sin(a) * ry)
		draw_circle(p, IntuitCfg.STUN_STAR_R + 1.2, Color(0, 0, 0, 0.6))
		draw_circle(p, IntuitCfg.STUN_STAR_R, Color.WHITE.lerp(IntuitCfg.STUN_COLOR, 0.5))


func _draw_label(l: Dictionary) -> void:
	var k := clampf((world.now - float(l["t0"])) / IntuitCfg.HINT_SHOW, 0.0, 1.0)
	var a := 1.0 if k < 0.7 else 1.0 - (k - 0.7) / 0.3
	var slot := int(l["slot"])
	var col := LegionUi.TEXT
	if slot >= 0:
		var cols: Array[Color] = [LegionCfg.Q_COLOR, LegionCfg.W_COLOR, LegionCfg.E_COLOR]
		col = cols[slot]
	elif l["type"] == &"gold":
		col = LegionCfg.PERFECT_COLOR
	elif l["type"] == &"spring":
		col = LegionCfg.SPRING_COLOR
	var up := IntuitCfg.HINT_UP + IntuitCfg.HINT_RISE * k
	_text(l["pos"] + Vector2(0.0, -up), String(l["text"]), IntuitCfg.HINT_SIZE, Color(col, a), true,
		true)


## Где висит подпись совета type (мировые координаты, без подъёма «строкой выше» от соседних
## подписей); пустой — подписи нет. Для тестов: подпись не ложится на строй.
func label_rect(type: StringName) -> Rect2:
	for l in _labels:
		if l["type"] == type:
			var k := clampf((world.now - float(l["t0"])) / IntuitCfg.HINT_SHOW, 0.0, 1.0)
			var at: Vector2 = l["pos"] + Vector2(0.0, -IntuitCfg.HINT_UP - IntuitCfg.HINT_RISE * k)
			return _text_rect(at, String(l["text"]), PvpView.fs(world, IntuitCfg.HINT_SIZE), true)
	return Rect2()


## Прямоугольник строки (at — базовая линия; centered — по центру x), прижатый внутрь экрана
## и ниже полосы HUD — как её нарисует _text.
func _text_rect(at: Vector2, text: String, size: int, centered: bool) -> Rect2:
	var font: Font = UiStyle.FONT_TITLE
	var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	if centered:
		at.x -= w * 0.5
	# у краёв экрана не обрезать: сдвигаем внутрь (и ниже полосы HUD)
	var view := world.view_rect()   # видимый мир: в «Схватке» 1600×900 (P5a)
	at.x = clampf(at.x, view.position.x + 6.0, view.end.x - w - 6.0)
	at.y = clampf(at.y, view.position.y + IntuitCfg.HUD_TOP_H, view.end.y - 8.0)
	return Rect2(at.x, at.y - size, w, size + 4.0)


## avoid — подпись не ложится на уже нарисованные в этом кадре: поднимается строкой выше.
func _text(at: Vector2, text: String, size: int, col: Color, centered: bool,
		avoid := false) -> void:
	size = PvpView.fs(world, size)   # B-303: на экране прежний размер
	var font: Font = UiStyle.FONT_TITLE
	var rect := _text_rect(at, text, size, centered)
	at = Vector2(rect.position.x, rect.position.y + size)
	if avoid:
		var tries := 0
		while tries < 6 and _placed.any(func(r: Rect2) -> bool: return r.intersects(rect)):
			rect.position.y -= size + 4.0
			tries += 1
		if rect.position.y < IntuitCfg.HUD_TOP_H - size:
			rect.position.y = at.y - size   # выше некуда — лучше поверх, чем за полосой HUD
		at.y = rect.position.y + size
	_placed.append(rect)
	draw_string_outline(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, 5,
		Color(0, 0, 0, 0.85 * col.a))
	draw_string(font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)


## Отрезок ломаной между длинами from и to вдоль неё (пустая часть черновика).
static func sub_poly(pts: PackedVector2Array, from: float, to: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	var run := 0.0
	for i in range(1, pts.size()):
		var a := pts[i - 1]
		var b := pts[i]
		var seg := a.distance_to(b)
		if seg <= 0.0:
			continue
		var s0 := run
		var s1 := run + seg
		run = s1
		if s1 < from or s0 > to:
			continue
		if out.is_empty():
			out.append(a.lerp(b, clampf((from - s0) / seg, 0.0, 1.0)))
		if s1 >= to:
			out.append(a.lerp(b, clampf((to - s0) / seg, 0.0, 1.0)))
			break
		out.append(b)
	return out
