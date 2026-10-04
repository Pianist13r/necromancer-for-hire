class_name LegionChallenge
extends RefCounted
##
## Уровни сложности режима «По истечении договора» и кульминация карты (медленная сессия
## slow/challenge, 26.09.2026).
##
## Почему (Игорь 26.09, после свежей сборки): «можно легко пройти одним типом только линий…
## надо баланса и сложности добавить и вызова, чтобы у человека было ощущение, что он преодолел
## то, что было трудно преодолеть». Бот играет слабее Игоря, поэтому прежние числа оставлены
## «Стажёру» бит в бит, а новый обычный уровень — «Штатный» — заметно тяжелее. С D-0927-49 под
## всеми уровнями лежит темп читаемости (PACE_THIN/PACE_HP): «Стажёр» = прежние числа × темп.
##
## Где применяется (ровно две точки, обе — рождение):
## - волны карты — `apply_map()` в LegionWorld.start_map: группы с полем `"tier"` выше уровня
##   выкидываются, число врагов и плотность колонн масштабируются; все читатели карты (бегун
##   волн, превью, край угрозы, звук) видят уже итоговые волны;
## - сила врага волны — `toughen()` в LegionWorld.spawn_foe_on_path (только враг волны, не
##   свита Прораба и не спящий мимик).
## Хранение выбора — Settings (раздел "game", ключ "difficulty"): это предпочтение игрока, а
## не прогресс, — одно на кампанию и свободную игру, переключается в меню и в выборе карт.
##

const INTERN := "intern"
const NORMAL := "normal"
const HELL := "hell"
## Новый обычный уровень: по умолчанию у игрока, у бота и у серий (--dev difficulty=…).
const DEFAULT := NORMAL
const ORDER: Array[String] = [INTERN, NORMAL, HELL]

## Одна таблица всех множителей. tier — какие группы волн с полем "tier" включены (tier группы
## ≤ tier уровня); count — число врагов в группе (кроме COUNT_FIXED); hp — здоровье врага волны;
## interval — промежуток между врагами группы и её задержка (меньше — плотнее колонна);
## next_in — время до следующей волны (меньше — меньше передышки); shield_press — во сколько раз
## щитоносец давит участок ПОДРЯДА сильнее своей массы (охрану и аудит — как раньше: щит
## упирается в строй, подрядчик его не сдержит — держит вахтёр или Е); shield_charge — урон
## натиска по щитоносцу в лоб (щит принимает разбег; сбоку и сзади — полный: фланг, Ку, Дубль-вэ);
## climax_souls — души за
## отбитую кульминацию. «Стажёр» — прежние числа: всё 1.0, групп tier ≥ 1 нет, душ нет
## (множители ложатся поверх темпа читаемости PACE_*).
const TABLE := {
	INTERN: {
		"title": "Стажёр", "tier": 0, "count": 1.0, "hp": 1.0, "interval": 1.0, "next_in": 1.0,
		"shield_press": 1.0, "shield_charge": 1.0, "climax_souls": 0,
		"desc": "Самая лёгкая нагрузка: пройти можно и одним видом договора.",
	},
	NORMAL: {
		"title": "Штатный", "tier": 1, "count": 1.0, "hp": 1.0, "interval": 1.0, "next_in": 1.0,
		"shield_press": 3.0, "shield_charge": 0.25, "climax_souls": 40,
		"desc": "Щитоносцы продавливают подряд и держат натиск в лоб, призраки идут волнами."
			+ " Кульминация — с премией.",
	},
	HELL: {
		"title": "Ад", "tier": 2, "count": 1.3, "hp": 1.25, "interval": 0.8, "next_in": 0.9,
		"shield_press": 3.0, "shield_charge": 0.25, "climax_souls": 60,
		"desc": "Плотнее, толще, без передышки. Для тех, кому «Штатный» мал.",
	},
}
## Их число — сюжет карты, а не нагрузка: Прораб один, Юристов не больше двух за волну
## (legion_lawyer_test).
const COUNT_FIXED := ["boss", "lawyer"]

## Темп читаемости (D-0927-49) — слой ПОД уровнями, для всех трёх. Почему: Игорь после
## «Штатного» 27.09: «нужно, чтоб поменьше всего происходило… чтобы успевали отслеживать, что
## происходит» — к третьей волне 30+ врагов и 40 своих на экране. Редеет только «массовка» —
## зомби и жуки (70–95 % врагов каждой карты): в группе вдвое меньше (не меньше 1), каждый
## толще (PACE_HP). Щитоносцы, призраки, нотариусы, мимики — не трогаем: их вызов считается
## головами (давка щитов — масса колонны, призрак — урон Котлу за каждого прошедшего; тесты
## legion_challenge_test «≥4 щита», «≥8 призраков»), а проредить их — вернуть «всё проходится
## одним подрядом» (B-074). Души за врага выше ровно во столько, во сколько группа поредела
## (souls_mult группы) — экономика построек прежняя. Скорость и промежутки внутри группы НЕ
## трогаем: толпа остаётся быстрой, просто короче. Возрождение своих — LegionCfg.RESPAWN_PACE.
## Замеры — docs/dev/BALANCE.md, раздел «Темп читаемости D-0927-49».
const PACE_THIN := {"zombie": 0.5, "beetle": 0.5}
## Почему 1,15, а не 2 (=1/0,5): своих тоже меньше (LegionCfg.STAFF_PACE 0,75, возрождение
## ×1,5), а щиты и призраки не поредели — толще массовку делать нельзя. Серии полного бота на
## «Штатном», 5 карт × 8 сидов (+8 сидов «Развилки»): 1,6 — «Развилка» 3→0 побед; 1,3 —
## «Архив» 8→6; 1,2 — «Развилка» 6→3 из 16; 1,1 — «Мост» 6→8 и «Развилка» 6→9 из 16 (легче);
## 1,15 — все карты в пределах ±1 из 8, «Развилка» 6→6 из 16 (BALANCE.md, D-0927-49).
const PACE_HP := 1.15
const PRESS_LABORER := &"press_laborer"
const CHARGE_FRONT := &"charge_front"
## Полуугол «лба» щита для удара с разбега, градусы (charge_mult).
const SHIELD_FRONT_DEG := 55.0


## Известный id уровня или DEFAULT.
static func valid(d: String) -> String:
	return d if TABLE.has(d) else DEFAULT


static func title(d: String) -> String:
	return String(TABLE[valid(d)]["title"])


static func value(d: String, key: String) -> float:
	return float(TABLE[valid(d)][key])


## Карта с волнами под уровень. Исходный словарь не меняется (load_map отдаёт свежий, но
## тесты и превью держат свои копии). Темп читаемости (PACE_THIN) — на всех уровнях; «Стажёр»
## сверх темпа — без пересчёта чисел (только выкидывает группы tier ≥ 1).
static func apply_map(map: Dictionary, d: String) -> Dictionary:
	if not map.has("waves"):
		return map
	var lvl := valid(d)
	var tier := int(TABLE[lvl]["tier"])
	var scale := lvl != INTERN
	var out := map.duplicate()
	var waves: Array = []
	for w: Dictionary in map["waves"]:
		var nw := w.duplicate()
		var groups: Array = []
		for g: Dictionary in w.get("groups", []):
			if int(g.get("tier", 0)) > tier:
				continue
			groups.append(_scaled_group(g, lvl))
		nw["groups"] = groups
		if scale and nw.has("next_in"):
			nw["next_in"] = float(nw["next_in"]) * value(lvl, "next_in")
		waves.append(nw)
	out["waves"] = waves
	return out


static func _scaled_group(g: Dictionary, lvl: String) -> Dictionary:
	var ng := g.duplicate()
	if String(g.get("type", "zombie")) not in COUNT_FIXED:
		var n := int(g.get("count", 1))
		# Порядок (verify 27.09): сначала темп — это группа «Штатного», потом множитель уровня
		# поверх неё, так «Ад» — ровно ×1,3 к «Штатному». Вес головы (souls_mult) — только за
		# прореживание: n / темп(n) ≤ 2, одинаковый на всех уровнях; лишние головы «Ада» платят
		# сверх, как и до темпа.
		var paced := pace_count(String(g.get("type", "zombie")), n)
		var now := _level_count(paced, lvl)
		if now != n:   # не тронутая группа остаётся словарём карты (JSON-число как было)
			ng["count"] = now
		if paced != n and paced > 0:
			ng["souls_mult"] = float(n) / float(paced)
	if lvl == INTERN:
		return ng
	var k := value(lvl, "interval")
	if g.has("interval"):
		ng["interval"] = float(g["interval"]) * k
	if g.has("delay"):
		ng["delay"] = float(g["delay"]) * k
	return ng


## Число врагов группы типа type после темпа читаемости: к ближайшему, но не меньше 1 (группа
## из одного не пропадает); пустая группа (count 0) остаётся пустой; не «массовка» — как есть.
static func pace_count(type: String, n: int) -> int:
	if n <= 0 or not PACE_THIN.has(type):
		return n
	return maxi(1, floori(n * float(PACE_THIN[type]) + 0.5))


## Число уровня поверх n: к ближайшему, но не меньше n (на «Аду» группа из 1–2 не пропадает).
static func _level_count(n: int, lvl: String) -> int:
	if lvl == INTERN:
		return n
	return maxi(n, floori(n * value(lvl, "count") + 0.5))


## Сколько прежних голов весит враг (темп читаемости): souls_mult его группы, иначе 1.
## Всё, что считается «за голову» — души, опыт кампании (kills_rewardable), счётчики и выплаты
## предметов, шанс элитного, — умножается на вес: поредевшая массовка не беднит бой (verify
## 27.09: с «Сдельной премией» души за бой просели на 7–14 %).
static func heads(f: Foe) -> float:
	return float(f.origin.get("souls_mult", 1.0))


## Души за врага волны: по типу, умноженные на вес головы (heads).
static func foe_souls(f: Foe) -> float:
	return float(LegionCfg.SOULS_PER_FOE.get(f.type_id, 0)) * heads(f)


## Уровень, которым пойдёт бой кампании на карте map_id: обучение «Пустыря» — всегда «Стажёр»
## (LegionWorld.start_tutorial), остальное — выбор игрока. Брифинг показывает волны этим уровнем.
static func campaign_level(map_id: String) -> String:
	if map_id == LegionTutorial.WASTELAND_MAP_ID and not Campaign.tutorial_done():
		return INTERN
	return Settings.difficulty()


## Сила врага волны (здоровье): темп читаемости PACE_HP (только «массовка» PACE_THIN) на всех
## уровнях × множитель уровня.
static func toughen(f: Foe, d: String) -> void:
	var lvl := valid(d)
	if f == null:
		return
	f.max_hp *= (PACE_HP if PACE_THIN.has(f.type_id) else 1.0) * value(lvl, "hp")
	f.hp = f.max_hp
	if lvl == INTERN:
		return
	if f.type_id == "shield_inspector":
		f.set_meta(PRESS_LABORER, value(lvl, "shield_press"))
		f.set_meta(CHARGE_FRONT, value(lvl, "shield_charge"))


## Урон удара С РАЗБЕГА (первый удар натиска, Legionnaire._tick_charge) по f из точки from:
## щит «Штатного» принимает разбег в лоб (метка toughen()). Удары после натиска — полные.
## Лоб — конус SHIELD_FRONT_DEG вокруг хода щитоносца. Почему 55°: линия поперёк дороги бьёт
## колонну в лоб (0–30°), фланговая вдоль дороги — около 90°; всё, что шире 55°, игрок видит
## как «сбоку» и должен получать полный удар — иначе обход щита не вознаграждается. 55° чуть
## уже давки (PRESS_FACING 0,5 = 60°): что давка не считает «идущим на участок», щит не прикрывает.
## Без метки — 1.0.
static func charge_mult(f: Foe, from: Vector2) -> float:
	if not f.has_meta(CHARGE_FRONT):
		return 1.0
	var to := from - f.position
	if to.is_zero_approx() or f.heading().dot(to.normalized()) < cos(deg_to_rad(SHIELD_FRONT_DEG)):
		return 1.0
	return float(f.get_meta(CHARGE_FRONT))


## Множитель давки врага f на участок вида kind (LegionGrid.press_scan). Метку ставит toughen()
## при рождении; без метки (враг «Стажёра», вне волны) — 1.0, давка прежняя.
static func press_mult(f: Foe, kind: StringName) -> float:
	if kind != LegionCfg.KIND_LABORER or not f.has_meta(PRESS_LABORER):
		return 1.0
	return float(f.get_meta(PRESS_LABORER))


## Вид, который бот вправе поставить (линия или постройка): --dev kinds=laborer[,guard…] —
## только эти, подряд есть всегда. Замер «пройти одним подрядом» (Игорь 26.09: «можно легко
## пройти одним типом только линий»). Флага нет — вид как есть: бой бота прежний бит в бит.
static func bot_kind(dev: Dictionary, kind: StringName) -> StringName:
	var only := String(dev.get("kinds", ""))
	if only == "" or kind == LegionCfg.KIND_LABORER or String(kind) in only.split(","):
		return kind
	return LegionCfg.KIND_LABORER


## Кульминация — волна с полем "climax": true в JSON карты (предпоследняя: после неё есть
## финальная волна, на которую награда и тратится).
static func is_climax(wave: Dictionary) -> bool:
	return bool(wave.get("climax", false))


## Подсказка превью кульминации: чем отвечать — по составу волны (вызов виден заранее).
static func answer_hint(groups: Array) -> String:
	var tips := PackedStringArray()
	var seen := {}
	for g: Dictionary in groups:
		seen[String(g.get("type", ""))] = true
	if seen.has("shield_inspector"):
		tips.append("щиты — охрана или Е")
	if seen.has("ghost"):
		tips.append("призраки — аудит или Ку")
	if seen.has("signer"):
		tips.append("нотариусы — натиск")
	if seen.has("boss"):
		tips.append("Прораб — выпуск перед тараном")
	return " · ".join(tips)
