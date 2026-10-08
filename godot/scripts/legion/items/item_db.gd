class_name LegionItemDb
extends RefCounted
##
## Реестр артефактов и синергий — ДАННЫМИ. v2 (Игорь 27.09, D-0927-163): артефактов мало (13),
## каждый меняет, КАК играешь, и у каждого своё ПОСТОЯННОЕ изменение вида того, на что он
## действует («если он влияет на молнию — чтобы молния цвет меняла»). Артефакт уникален: второй
## раз тот же не выпадает; собранные живут весь забег (CfgItems.SAVE_KEY в разделе забега).
##
## Запись:
##   title   — название (канцелярский юмор игры), text — эффект одной строкой (≤ ~48 знаков);
##   rarity  — &"common" | &"rare" | &"legendary" (вес выпадения — CfgItems.RARITY_WEIGHT);
##   icon    — имя PNG в assets/legion/icons (нет поля — "item_<id>");
##   mods    — ЧИСЛА: {ключ: прибавка}; мир читает world.item_mult / item_add в месте применения;
##   on + fx — ПОВЕДЕНИЕ: событие боя (LegionItems.EVENTS) и обработчик
##             LegionItemEffects.fx_<fx>(n, p, args); params — его числа (правятся здесь);
##   look    — ВИД, ОБЯЗАТЕЛЕН: {target, channel, color, …}. target — на что действует
##             (CfgItems.LOOK_TARGETS), channel — какую сторону вида меняет. Читатели:
##               q_bolt   color (цвет и толщина канала) · fork (+ветки своего цвета) —
##                        LegionImpactFx.bolt_chain / LegionHero._bolt;
##               unit     badge (печать на груди) · trail (пламя у бегущих натиском) — item_look;
##               vassal   tint (окрас внештатника и фитиль) — LegionHero.raise_corpses, item_look;
##               contract ink (цвет чернил линии) · gild (золотая нить) — ContractField;
##                        ghost (призрачные участки) — item_look;
##               building flame (огонёк на крыше) · cauldron flame / ring — item_look;
##               e_haste  color (волна и шлейф Аврала) — LegionImpactFx;
##               rally    color (кольцо «Сбора» и звуковые дуги) — LegionWorld._draw_rallies.
##             Кто применил вид к объекту, отмечает это items.note_look(target, channel) — тест
##             проверяет, что у каждого артефакта вид действительно лёг на объект.
##
## Синергия — набор id (items); первым стоит «включатель» (тест сравнивает полный набор с
## набором без первого). Синергий нарочно мало: смысл — в самих артефактах.
##

const ITEMS := {
	"clip_of_fate": {
		"trigger": "Каждое успешное применение молнии {key:cast_q}.",
		"result": "Цепь длиннее на 2 цели; оглушение длится на 50 % дольше.",
		"play_hint": "Цельтесь в плотную группу: дополнительные звенья находят соседние цели.",
		"styles": [&"warlock"],
		"cue": "Золотая молния с дополнительными звеньями.", "passive": true,
		"title": "Скрепка судьбы", "text": "Молния {key:cast_q} бьёт ещё 2 цели и оглушает ×1,5",
		"rarity": &"rare", "mods": {"q_chain": 2.0, "q_stun": 0.5},
		"look": {"target": &"q_bolt", "channel": &"color", "color": Color(1.0, 0.8, 0.28),
			"w": 1.4},
	},
	"lightning_rod": {
		"trigger": "Молния {key:cast_q} убила цель, рядом есть следующая живая цель.",
		"result": "До двух прыжков: каждый наносит 80 % урона исходного удара.",
		"play_hint": "Добивайте слабого проверяющего рядом с сильными.", "styles": [&"warlock"],
		"cue": "Фиолетовые ответвления от убитой цели.", "passive": false,
		"title": "Громоотвод", "text": "С убитой цели молния {key:cast_q} прыгает дальше (×2)",
		"rarity": &"rare", "on": &"q_hit", "fx": &"lightning_rod",
		"params": {"r": 170.0, "frac": 0.8, "hops": 2},
		"look": {"target": &"q_bolt", "channel": &"fork", "color": Color(0.78, 0.45, 1.0),
			"branches": 3},
	},
	"exploding_stamp": {
		"trigger": "Штатный боец погиб; печать готова (откат 5 с).",
		"result": "Через 0,12 с взрыв: 12 урона и оглушение на 0,3 с в радиусе 58.",
		"play_hint": "Держите бойцов у вражеской толпы: взрыв происходит на месте гибели.",
		"styles": [&"hr"],
		"cue": "Оранжевая печать на груди, затем кольцо взрыва.", "passive": false,
		"title": "Взрывная печать", "text": "Павший боец взрывается печатью (раз в 5 с)",
		"rarity": &"rare", "on": &"unit_died", "fx": &"unit_blast",
		# серия fork «Штатный» 27.09 (без артефактов 1/6): взрыв на каждого павшего (~200 за
		# бой) — 6/6 и при уроне 26, и при 9; печать с откатом 4 с и уроном 22 — всё ещё 6/6
		# (урон 0 — 1/6: дело в уроне); 12 урона, 0,3 с, откат 5 с — 3/6, Котёл не в 200
		"params": {"r": 58.0, "dmg": 12.0, "stun": 0.3, "cd": 5.0},
		"look": {"target": &"unit", "channel": &"badge", "color": Color(1.0, 0.62, 0.2)},
	},
	"burning_seal": {
		"trigger": "Боец в натиске пробежал ещё 26 пикселей.",
		"result": "Пятно горит 2,2 с и наносит 12 урона в секунду.",
		"play_hint": "Направляйте натиск через толпу: движение прокладывает огненный коридор.",
		"styles": [&"warlock"],
		"cue": "Огонь у ног и горящие пятна на земле.", "passive": false,
		"title": "Сургуч с огоньком",
		"text": "Огненный след оставляет любой натиск: рогатка, ПКМ, таяние",
		"rarity": &"rare", "on": &"tick", "fx": &"charge_trail",
		"params": {"step": 26.0, "r": 22.0, "t": 2.2, "dps": 12.0},
		"look": {"target": &"unit", "channel": &"trail", "color": Color(1.0, 0.56, 0.1)},
	},
	"staff_schedule": {
		"trigger": "Павший штатный возвращается из постройки или Котла.",
		"result": "При свободном лимите сразу возвращается ещё один ожидающий боец. Первое " +
			"заполнение штата обычное.",
		"play_hint": "Нужны два ожидающих места: стройте и восстанавливайте штат после потерь.",
		"styles": [&"hr"],
		"cue": "Парные огоньки у источника найма и знак над выходящими бойцами.", "passive": true,
		"title": "Штатное расписание", "text": "Вернувшийся штатный досрочно подтягивает ещё одного",
		"rarity": &"legendary", "mods": {"twin_spawn": 1.0},
		"look": {"target": &"building", "channel": &"flame", "color": Color(1.0, 0.62, 0.2)},
	},
	"temp_contract": {
		"trigger": "{key:cast_w} поднимает трупы; срок внештатника истёк.",
		"result": "Можно поднять ещё 2 трупа. В конце срока внештатник взрывается: 34 урона в " +
			"радиусе 74.",
		"play_hint": "Поднимайте трупы возле врагов: последний взрыв достанет их.",
		"styles": [&"warlock"],
		"cue": "Золотой внештатник с горящим фитилём.", "passive": false,
		"title": "Срочный договор",
		"text": "{key:cast_w}: +2 трупа. В конце срока внештатник взрывается: 34 в 74",
		"rarity": &"common", "mods": {"w_raise": 2.0}, "on": &"vassal_expired",
		"fx": &"vassal_blast", "params": {"r": 74.0, "dmg": 34.0},
		"look": {"target": &"vassal", "channel": &"tint", "color": Color(1.3, 1.0, 0.35)},
	},
	"prolongation": {
		"trigger": "Участок договора сам растаял по сроку.",
		"result": "Призрачная полоса держится 3 с: замедляет и наносит 10 урона в секунду. " +
			"Линия идёт по прямой между концами участка (изгиб не повторяет).",
		"play_hint": "Положите рубеж на пути врагов и дайте ему дожить до конца срока.",
		"styles": [&"law"],
		"cue": "Фиолетовая призрачная линия с подписью.", "passive": false,
		"title": "Пролонгация", "text": "Растаявший участок 3 с держит призрачную линию",
		"rarity": &"rare", "on": &"seg_released", "fx": &"ghost_line",
		"params": {"t": 3.0, "dps": 10.0, "slow": 1.2},
		"look": {"target": &"contract", "channel": &"ghost", "color": Color(0.7, 0.62, 1.0)},
	},
	"golden_pen": {
		"trigger": "Натиск попал «Точно!», а молния {key:cast_q} была на откате.",
		"result": "{key:cast_q} сразу готова снова.",
		"play_hint": "Сначала примените {key:cast_q}, затем точно запустите бойцов в противника.",
		"styles": [&"law"],
		"cue": "Золотая нить договора и «{key:cast_q} готова!» на попадании.", "passive": false,
		"title": "Золотое перо", "text": "«Точно!» сразу перезаряжает {key:cast_q}",
		"rarity": &"legendary", "on": &"charge_impact", "fx": &"golden_pen",
		"look": {"target": &"contract", "channel": &"gild", "color": Color(1.0, 0.84, 0.32)},
	},
	"wholesale_ink": {
		"trigger": "При рисовании и восстановлении маны.",
		"result": "Линии стоят на 35 % меньше; скорость восстановления маны на 25 % выше.",
		"play_hint": "Сэкономленную ману тратьте на новые рубежи и способности.", "styles": [&"law"],
		"cue": "Синие чернила линии и знак чернильницы на новом договоре.", "passive": true,
		"title": "Чернила оптом", "text": "Линии на 35 % дешевле, восстановление маны +25 %",
		"rarity": &"common", "mods": {"line_cost": -0.35, "mana_regen": 0.25},
		"look": {"target": &"contract", "channel": &"ink", "color": Color(0.3, 0.22, 1.0),
			"mix": 0.78},
	},
	"overtime_sheet": {
		"trigger": "Успешный Аврал ({key:cast_e}) нашёл бойцов.",
		"result": "Усиление на 3 с дольше; радиус захвата на 40 % больше.",
		"play_hint": "Включайте Аврал перед массовым натиском или прорывом врага.", "styles": [&"hr"],
		"cue": "Оранжевая волна Аврала и знак табеля над усиленной группой.", "passive": true,
		"title": "Табель сверхурочных", "text": "Аврал ({key:cast_e}) на 3 с дольше и шире ×1,4",
		"rarity": &"common", "mods": {"e_dur": 3.0, "e_radius": 0.4},
		"look": {"target": &"e_haste", "channel": &"color", "color": Color(1.0, 0.42, 0.14)},
	},
	"megaphone": {
		"trigger": "Использование «Сбора» рядом с врагами.",
		"result": "Откат «Сбора» вдвое короче; враги в радиусе 95 оглушены на 1,4 с.",
		"play_hint": "Собирайте резерв у вражеской толпы, чтобы выиграть время.", "styles": [&"hr"],
		"cue": "Золотое кольцо Сбора и светлый круг оглушения.", "passive": false,
		"title": "Рупор завхоза",
		"text": "«Сбор» ({cap:rally}) откатывается вдвое быстрее и глушит врагов — за настоящий сбор",
		"rarity": &"common", "mods": {"rally_cd": -0.5}, "on": &"rally_used",
		"fx": &"roll_call", "params": {"r": 95.0, "stun": 1.4},
		"look": {"target": &"rally", "channel": &"color", "color": Color(1.0, 0.86, 0.25)},
	},
	"soul_magnet": {
		"trigger": "Убит обычный проверяющий; Котёл повреждён.",
		"result": "Восстанавливает 0,3 здоровья за прежнюю голову проверяющего; призванные не лечат.",
		"play_hint": "Уничтожайте волну до прорыва: каждое убийство понемногу чинит Котёл.",
		"styles": [&"warlock"],
		"cue": "Голубая душа летит от погибшего к Котлу.", "passive": false,
		"title": "Душеприказчик", "text": "Души убитых летят в Котёл и лечат его",
		# серия fork 27.09: лечение 1 за голову — 4/6 побед против 0–1/6 без него, 0,5 — тоже 4/6;
		# в бою стоит 0,3 (params) — комментарий держит историю замеров, а не текущее число
		"rarity": &"rare", "on": &"foe_killed", "fx": &"soul_heal", "params": {"heal": 0.3},
		"look": {"target": &"cauldron", "channel": &"flame", "color": Color(0.45, 0.78, 1.0)},
	},
	"cauldron_ward": {
		"trigger": "Котёл получил удар; печать готова (откат 10 с).",
		"result": "Взрыв вокруг Котла: 15 урона и оглушение на 1 с в радиусе 110.",
		"play_hint": "Это страховка прорыва: используйте оглушение, чтобы вернуть оборону.",
		"styles": [&"law"],
		"cue": "Синее кольцо у Котла вспыхивает печатью.", "passive": false,
		"title": "Печать на Котле", "text": "Удар по Котлу: печать бьёт и глушит — не чаще раза в 10 с",
		"rarity": &"common", "on": &"cauldron_hit", "fx": &"cauldron_ward",
		# серия fork 27.09: откат 6 с, урон 30 — 5/6 побед; в бою реже и слабее: cd 10, урон 15
		"params": {"r": 110.0, "stun": 1.0, "dmg": 15.0, "cd": 10.0},
		"look": {"target": &"cauldron", "channel": &"ring", "color": Color(0.5, 0.6, 1.0)},
	},
}

## Синергии: собран набор items — работает эффект (mods и/или on+fx), в полоске — значок-связка.
const SYNERGIES := {
	"thunder_office": {
		"title": "Громовая канцелярия", "items": ["lightning_rod", "clip_of_fate"],
		"text": "Каждый удар молнии оставляет оглушающую печать",
		"on": &"q_hit", "fx": &"stun_seal", "params": {"r": 40.0, "t": 2.0, "stun": 0.6},
	},
	"kamikaze_brigade": {
		"title": "Бригада смертников", "items": ["exploding_stamp", "temp_contract"],
		"text": "Взрывы бойцов и внештатников ×1,5", "mods": {"blast_mult": 0.5},
	},
	"hot_line": {
		"title": "Горячая линия", "items": ["burning_seal", "prolongation"],
		"text": "Призрачные линии горят втрое жарче", "mods": {"ghost_burn": 2.0},
	},
}


static func item(id: StringName) -> Dictionary:
	return ITEMS.get(String(id), {})


static func synergy(id: StringName) -> Dictionary:
	return SYNERGIES.get(String(id), {})


static func ids() -> Array[StringName]:
	var out: Array[StringName] = []
	for k: String in ITEMS:
		out.append(StringName(k))
	return out


static func synergy_ids() -> Array[StringName]:
	var out: Array[StringName] = []
	for k: String in SYNERGIES:
		out.append(StringName(k))
	return out


static func icon_name(id: StringName) -> String:
	return String(item(id).get("icon", "item_" + String(id)))


static func rarity(id: StringName) -> StringName:
	return StringName(item(id).get("rarity", &"common"))


static func look(id: StringName) -> Dictionary:
	return item(id).get("look", {})


## Какой артефакт выпал: взвешенный по редкости бросок rng среди ещё не взятых (owned).
## Все взяты — пустое имя.
static func pick(rng: RandomNumberGenerator, owned: Dictionary = {}) -> StringName:
	var total := 0.0
	for k: String in ITEMS:
		if not owned.has(StringName(k)):
			total += float(CfgItems.RARITY_WEIGHT.get(rarity(StringName(k)), 1.0))
	if total <= 0.0:
		return &""
	var roll := rng.randf() * total
	var last: StringName = &""
	for k: String in ITEMS:
		if owned.has(StringName(k)):
			continue
		last = StringName(k)
		roll -= float(CfgItems.RARITY_WEIGHT.get(rarity(last), 1.0))
		if roll <= 0.0:
			return last
	return last
