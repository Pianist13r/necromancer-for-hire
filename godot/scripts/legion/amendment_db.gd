class_name AmendmentDb
extends RefCounted
## Редакция договора живёт в забеге. Цена карточки меняет решение, а не только число.

const MAX_ACTIVE := 3
const REROLL_COST := 30
const TAGS := {
	"hr": {"title": "Кадры", "color": Color(0.95, 0.74, 0.40)},
	"law": {"title": "Договоры", "color": Color(0.47, 0.76, 0.90)},
	"magic": {"title": "Некромантия", "color": Color(0.76, 0.62, 0.95)},
}
const ORDER := ["living_queue", "temp_agency", "lean_staff", "ghost_clause", "bulk_ink",
	"paper_shield", "carbon_copy", "high_voltage", "overtime_cycle", "moving_office",
	"golden_exit", "soul_dividend"]
const CARDS := {
	"living_queue": {
		"title": "Живая очередь", "tag": "hr", "icon": "perk_fast_hire",
		"text": "Павшего штатного подменяют у его постройки. Раз в 8 с — на всю контору.",
		"tradeoff": "Штат каждой постройки −20 %.",
		"hint": "Держите небольшой фронт: очередь возвращает первую потерю.",
		"mods": {"cap_mult_laborer": -0.2, "cap_mult_guard": -0.2, "cap_mult_clerk": -0.2},
		"rule": "queue", "params": {"cd": 8.0},
	},
	"temp_agency": {
		"title": "Агентство однодневок", "tag": "hr", "icon": "item_temp_contract",
		"text": "Внештатники сами идут к ближайшему врагу в 280 шагов. Ещё 2 трупа за вызов.",
		"tradeoff": "Аврал на 2 с короче.", "needs": "ability_unlocked_w",
		"hint": "Поднимайте бригаду в тылу: теперь она догонит колонну.",
		"mods": {"w_raise": 2.0, "e_dur": -2.0},
		"rule": "vassal_march", "params": {"seek": 280.0, "speed": 55.0},
	},
	"lean_staff": {
		"title": "Текучка кадров", "tag": "hr", "icon": "shop_respawn",
		"text": "Погибшие возвращаются на 40 % быстрее: дешевле нанять, чем удержать.",
		"tradeoff": "Штат построек −25 %: длинную стену не набрать.",
		"hint": "Стройте больше источников вместо одной огромной бригады.",
		"mods": {"respawn_mult_laborer": -0.4, "respawn_mult_guard": -0.4,
			"respawn_mult_clerk": -0.4, "cap_mult_laborer": -0.25,
			"cap_mult_guard": -0.25, "cap_mult_clerk": -0.25},
	},
	"ghost_clause": {
		"title": "Договор с привидением", "tag": "law", "icon": "item_prolongation",
		"text": "Растаявший участок ещё 3 с жалит по прямой между своими концами и замедляет.",
		"tradeoff": "Живой участок тает на 2 с раньше.",
		"hint": "Отпускайте старый рубеж: призрак прикроет новый.",
		"mods": {"seg_ttl_bonus": -2.0}, "rule": "ghost",
		"params": {"t": 3.0, "dps": 12.0, "slow": 1.3},
	},
	"bulk_ink": {
		"title": "Мелкий оптовый шрифт", "tag": "law", "icon": "item_wholesale_ink",
		"text": "Рисовать договоры на 35 % дешевле.",
		"tradeoff": "Набор — на 60 шагов ближе: на длинную линию бригаду уже не позвать.",
		"hint": "Больше коротких рубежей; бойцы должны быть рядом.",
		"mods": {"mana_cost_mult": -0.35, "recruit_r_laborer": -60.0,
			"recruit_r_guard": -60.0, "recruit_r_clerk": -60.0},
	},
	"paper_shield": {
		"title": "Бумажная броня", "tag": "law", "icon": "perk_settlement_on_time",
		"text": "Спереди строй держит 0,5 вместо 0,7 урона (вахтёр — 0,3); расчёт за срок ×1,5.",
		"tradeoff": "Урон натиска −30 %. Расчёт ×1,5 гасится потолком «не выше двойного».",
		"hint": "Выстаивайте срок и обновляйте договоры; натиск — для перестановки.",
		"mods": {"hold_armor": 0.2, "settlement_mult": 0.5, "charge_dmg_mult": -0.3},
	},
	"carbon_copy": {
		"title": "Копия верна", "tag": "magic", "icon": "item_clip_of_fate",
		"text": "Если первая цель разряда жива через 0,6 с — она получает половину урона ещё раз.",
		"tradeoff": "Ку, Дубль-вэ и Аврал дороже на 25 % — «Сбор» нет.",
		"hint": "Бейте Ку по толстой цели: копия догонит её.",
		"mods": {"ability_mana_mult": 0.25}, "rule": "echo",
		"params": {"delay": 0.6, "frac": 0.5}, "needs": "ability_unlocked_q",
	},
	"high_voltage": {
		"title": "Опасное напряжение", "tag": "magic", "icon": "item_lightning_rod",
		"text": "Разряд бьёт ещё 2 цели и наносит на 40 % больше — но оглушает вдвое короче.",
		"tradeoff": "Долгой передышки от разряда не будет.",
		"hint": "Добивайте колонну; долгой передышки от молнии не будет.",
		"mods": {"q_chain": 2.0, "q_dmg": 0.4, "q_stun": -0.5},
		"needs": "ability_unlocked_q",
	},
	"overtime_cycle": {
		"title": "Ненормированный день", "tag": "magic", "icon": "item_overtime_sheet",
		"text": "Аврал дольше на 4 с и шире на 40 %.",
		"tradeoff": "Запас маны −25: меньше действий подряд.",
		"hint": "Собирайте ударную бригаду перед длинным Авралом.",
		"mods": {"e_dur": 4.0, "e_radius": 0.4, "mana_max_bonus": -25.0},
		"needs": "ability_unlocked_e",
	},
	"moving_office": {
		"title": "Выездная канцелярия", "tag": "law", "icon": "perk_far_call",
		"text": "Договор набирает бойцов на 100 шагов дальше.",
		"tradeoff": "Каждая линия на 25 % дороже.", "unlock_level": 3,
		"hint": "Бригаду можно позвать с тыла; берегите ману на длинные линии.",
		"mods": {"recruit_r_laborer": 100.0, "recruit_r_guard": 100.0,
			"recruit_r_clerk": 100.0, "mana_cost_mult": 0.25},
	},
	"golden_exit": {
		"title": "Премия за выход", "tag": "hr", "icon": "perk_brisk_exit",
		"text": "Натиск наносит на 60 % больше урона.",
		"tradeoff": "Разбег на 25 % медленнее: цель успеет сдвинуться.", "unlock_level": 5,
		"hint": "Выбирайте короткие, точные броски вместо дальней погони.",
		"mods": {"charge_dmg_mult": 0.6, "charge_speed_mult": -0.25},
	},
	"soul_dividend": {
		"title": "Душевые дивиденды", "tag": "magic", "icon": "item_soul_magnet",
		"text": "Каждый убитый враг, кроме призванных, возвращает 1 ману.",
		"tradeoff": "Штат построек −15 %.", "unlock_level": 7,
		"hint": "Тратьте ману перед массовым добиванием — оно оплатит следующий ход.",
		"mods": {"cap_mult_laborer": -0.15, "cap_mult_guard": -0.15,
			"cap_mult_clerk": -0.15}, "rule": "dividend", "params": {"mana": 1.0},
	},
}
const PREPARATIONS := {
	"souls": {"title": "Подъёмные", "icon": "souls", "cost": 35,
		"text": "+45 душ на следующем объекте. Потом выдача заканчивается.",
		"mods": {"start_souls": 45.0}},
	"mana": {"title": "Термос некроманта", "icon": "shop_mana", "cost": 35,
		"text": "+30 запаса маны на следующем объекте. Термос потом пуст.",
		"mods": {"mana_max_bonus": 30.0}},
}
const LEGACY_MAP := {
	"night_shift_hr": "lean_staff", "outstaff_partner": "living_queue",
	"signing_bonus": "living_queue", "brigade_quota": "temp_agency",
	"overtime_clause": "ghost_clause", "union_contract": "paper_shield",
	"cauldron_insurance": "paper_shield", "bulk_paper": "bulk_ink",
	"hazard_pay": "high_voltage", "silence_order": "carbon_copy",
	"rush_premium": "overtime_cycle", "aggressive_lawyers": "golden_exit",
	"courier_bonus": "golden_exit", "soul_audit": "soul_dividend",
}

static func card(id: StringName) -> Dictionary:
	return CARDS.get(String(id), {})


static func color(id: StringName) -> Color:
	return TAGS.get(String(card(id).get("tag", "law")), TAGS["law"])["color"]
