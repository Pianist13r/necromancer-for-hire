class_name MetaMods
extends RefCounted
##
## E-1005: ЕДИНОЕ правило сведения модификаторов (поправки, артефакты, подготовка «Конторы») —
## и подписи ключей для игрока. Источники одного ключа независимы:
##   • ключ-множитель (база 1.0) — перемножение: ∏(1+v), возврат как ∏ − 1;
##   • прибавочный ключ (база 0) — сумма: Σv.
## Складывать проценты было нельзя: «Текучка» + «Живая очередь» + «Дивиденды» сходились в −60 %
## штата, «Опасное напряжение» и «Скрепка судьбы» гасили друг друга в q_stun ровно в базовое
## оглушение (артефакт молчал), «Мелкий шрифт» с «Выездной канцелярией» — в −10 % цены линии.
##
## Вид ключа — по имени (`_mult`/`_mult_`) ИЛИ по списку MULT_KEYS: q_stun, q_dmg, e_radius,
## line_cost, mana_regen, rally_cd и подобные читаются как множители (LegionWorld.mod_mult /
## item_mult), хотя имя этого не выдаёт. `hold_armor` сюда НЕ входит: он прибавка к броне
## (unit.gd: front_armor − hold_armor), а не множитель.
##

## Ключи с базой 1.0, которых не выдаёт имя. Часть сейчас с одним источником — список держит вид
## ключа верным, чтобы второй источник не превратил множитель в слагаемое молча.
const MULT_KEYS := ["q_stun", "q_dmg", "e_radius", "line_cost", "mana_regen", "rally_cd",
	"perfect_zone", "press_hold", "souls", "charge_dmg"]

## Подписи ключей для игрока (экран выбора поправок). Ключ без подписи покажется сам собой — это
## сигнал добавить строку, а не молча показать код.
const KEY_LABELS := {
	"q_stun": "оглушение молнии", "q_dmg": "урон молнии", "q_chain": "цели молнии",
	"e_radius": "радиус Аврала", "e_dur": "длительность Аврала", "w_raise": "бойцов за подъём",
	"charge_dmg_mult": "урон натиска", "charge_speed_mult": "скорость разбега",
	"charge_dmg": "урон удара с разбега", "mana_cost_mult": "цена договора",
	"ability_mana_mult": "цена способностей", "settlement_mult": "расчёт за срок",
	"hold_armor": "броня строя",
	"line_cost": "цена линии", "mana_regen": "реген маны", "rally_cd": "откат «Сбора»",
	"perfect_zone": "зона «Точно!»", "press_hold": "стойкость строя", "souls": "души за голову",
	"seg_ttl_bonus": "срок участка", "mana_max_bonus": "запас маны", "start_souls": "стартовые души",
	"recruit_r": "дальность набора",
}
## Единица прибавочного ключа в чипе: «−2 с срок участка», а не голое «−2».
const KEY_UNITS := {"seg_ttl_bonus": " с", "e_dur": " с"}


static func is_mult_key(key: StringName) -> bool:
	var k := String(key)
	return k.ends_with("_mult") or k.contains("_mult_") or MULT_KEYS.has(k)


## Свод значений источников в ПРИБАВОЧНОЙ форме: множитель ключа-множителя = 1 + результат
## (так его и читает LegionWorld.mod_mult). parts — значения в карточном виде (−0.2 = «минус 20 %»),
## каждый источник отдельно: поправка, артефакт, подготовка.
static func combine(key: StringName, parts: Array) -> float:
	if is_mult_key(key):
		var mult := 1.0
		for v: Variant in parts:
			mult *= 1.0 + float(v)
		return mult - 1.0
	var add := 0.0
	for v: Variant in parts:
		add += float(v)
	return add


## Подпись ключа для игрока. Штат и возрождение — по семейству, а не по виду: карточка бьёт все три
## вида разом, и три одинаковые строки «штат подряда/охраны/аудита ×…» были бы простынёй (п.6).
static func key_label(key: StringName) -> String:
	var k := String(key)
	if k.begins_with("cap_mult_"):
		return "штат построек"
	if k.begins_with("respawn_mult_"):
		return "время возврата в строй"
	if k.begins_with("recruit_r_"):
		return "дальность набора"
	return String(KEY_LABELS.get(k, k))


## Чипы дельт для строки экрана («−20 % штат построек», «+40 % урон разряда»): ключ-множитель
## показывается процентом со знаком, прибавочный — числом со знаком. Одинаковые подпись+значение
## схлопываются (штат/возврат/набор трёх видов — один чип), порядок — по ключам карточки.
static func delta_chips(mods: Dictionary) -> Array[String]:
	var out: Array[String] = []
	var seen := {}
	for k: String in mods:
		var key := StringName(k)
		var v := float(mods[k])
		if is_zero_approx(v):
			continue
		var chip := "%s %s" % [_signed(key, v), key_label(key)]
		if seen.has(chip):
			continue
		seen[chip] = true
		out.append(chip)
	return out


## Цвет отражает пользу, а не арифметический знак: короткий возврат в строй выгоден.
static func delta_entries(mods: Dictionary) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var seen := {}
	for key: String in mods:
		var value := float(mods[key])
		if is_zero_approx(value):
			continue
		var lower_is_better := key.begins_with("respawn_mult_") or key in [
			"mana_cost_mult", "ability_mana_mult", "line_cost", "rally_cd"]
		var benefit := value < 0.0 if lower_is_better else value > 0.0
		var caption := ("Польза: " if benefit else "Цена: ") + "%s %s" % [
			_signed(StringName(key), value), key_label(StringName(key))]
		if not seen.has(caption):
			seen[caption] = true
			out.append({"text": caption, "benefit": benefit})
	return out


static func _signed(key: StringName, v: float) -> String:
	var out := ""
	if is_mult_key(key):
		out = "%+d %%" % roundi(v * 100.0)
	else:
		out = ("%+d" % roundi(v)) if is_equal_approx(v, roundf(v)) \
			else ("%+.2f" % v).rstrip("0").rstrip(".").replace(".", ",")
		out += String(KEY_UNITS.get(String(key), ""))
	# Типографский минус, как в текстах карточек («−20 %»), а не дефис.
	return out.replace("-", "−")


## E-1005 п.6: экрану выбора — с какими УЖЕ ДЕЙСТВУЮЩИМИ источниками карточка делит ключ-множитель
## и что из дележа выйдет. Считает ровно тем же правилом (combine), что и бой, — строка не соврёт.
## Прибавочные ключи молчат: там делить нечего, сумма читается из чисел самих карточек.
static func together_notes(id: StringName) -> Array[String]:
	var card_mods: Dictionary = AmendmentDb.card(id).get("mods", {})
	var out: Array[String] = []
	if card_mods.is_empty():
		return out
	var others := _other_sources(id)
	var seen := {}
	for k: String in card_mods:
		var key := StringName(k)
		if not is_mult_key(key):
			continue
		var names: Array[String] = []
		var parts: Array = [float(card_mods[k])]
		for src: Dictionary in others:
			var v := float((src["mods"] as Dictionary).get(k, 0.0))
			if v == 0.0:
				continue
			names.append("„%s“" % String(src["title"]))
			parts.append(v)
		if names.is_empty():
			continue
		var who := ", ".join(names)
		var total := _num(1.0 + combine(key, parts))
		var dedup := "%s|%s" % [who, total]   # штат/возврат трёх видов — один дележ, одна строка
		if seen.has(dedup):
			continue
		seen[dedup] = true
		out.append("Вместе с %s: %s ×%s" % [who, key_label(key), total])
	return out


## Действующие источники модификаторов, кроме самой карточки id: взятые поправки и артефакты
## забега (они живут между боями кампании — Campaign.run_items()).
static func _other_sources(id: StringName) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for other in Campaign.upgrades():
		if other != id:
			out.append({"title": String(AmendmentDb.card(other).get("title", other)),
				"mods": AmendmentDb.card(other).get("mods", {})})
	for item_id in Campaign.run_items():
		var e := LegionItemDb.item(item_id)
		var mods: Dictionary = e.get("mods", {})
		if not mods.is_empty():
			out.append({"title": String(e.get("title", item_id)), "mods": mods})
	return out


## Число для игрока: запятая, без хвостовых нулей (0.75 → «0,75», 1.4 → «1,4»).
static func _num(x: float) -> String:
	var s := "%.2f" % x
	if s.contains("."):
		s = s.rstrip("0").rstrip(".")
	return s.replace(".", ",")
