class_name LegionMetaCfg
extends RefCounted
##
## Мета нового режима «По истечении договора»: пул «поправок к договору» (апгрейды между
## картами кампании) и пороги звёзд. Числа — ориентиры для баланс-серии, не финал (CONCEPT.md).
## Владелец — пакет UI (docs/legion/SLICE_SPEC.md не описывает мету, это её первый дом).
##

# ── Звёзды за карту, по доле HP Котла на конец боя (только при победе) ───────
## ≥ STAR3_RATIO — 3★, ≥ STAR2_RATIO — 2★, любая победа — минимум 1★, поражение — 0.
const STAR3_RATIO := 0.8
const STAR2_RATIO := 0.4

# ── Пул поправок к договору ───────────────────────────────────────────────────
## Каждая — id, title (шапка карточки), text (описание для игрока), effect {key, value}.
## Ключи effect суммируются Campaign.active_mods() и читает CORE-баланс (не наш пакет):
##   seg_ttl_bonus      — +с к сроку жизни участка линии
##   charge_dmg_mult     — множитель урона в фазе НАТИСК (аддитивно к базовому x1.0)
##   charge_speed_mult   — множитель скорости в фазе НАТИСК
##   production_mult     — множитель темпа пополнения Котла
##   army_cap_bonus      — +к лимиту армии
##   start_army_bonus    — +к стартовому числу бойцов
##   mana_regen_bonus    — +к регену маны, ед/с
##   mana_max_bonus       — +к максимуму маны
##   hold_armor          — доп. снижение урона по бойцам В СТРОЮ, доля (аддитивно к базовым 0,3)
##   cauldron_hp_bonus    — +к максимуму HP Котла
## Поправки 26.09 (Игорь: «апгрейдов бы побольше рандомных») пишут в ключи предметов
## (items/item_db.gd): мир читает их world.item_mult/item_add — это сумма предметов боя и
## поправок с тем же ключом (q_chain, q_stun, w_raise, e_dur, rally_cd, perfect_zone, souls,
## press_hold, elite_chance, item_luck); mana_cost_mult и start_souls — ключи Campaign.stat.
## needs — ключ открытия кампании (unlocks карт): до него поправку не предлагают (B-096:
## «Квота на бригаду» про Дубль-вэ приходила после «Пустыря», а Дубль-вэ — с «Двух отделов»).
const LEGACY_UPGRADES := {
	"overtime_clause": {
		"title": "Пункт о переработке",
		"text": "Подрядчики держат участок дольше без подрисовки. Срок участка +3 с.",
		"effect": {"key": "seg_ttl_bonus", "value": 3.0},
	},
	"aggressive_lawyers": {
		"title": "Агрессивные юристы",
		"text": "Натиск проламывает жёстче. Урон в фазе натиска +25 %.",
		"effect": {"key": "charge_dmg_mult", "value": 0.25},
	},
	"courier_bonus": {
		"title": "Курьерская надбавка",
		"text": "Отряд в натиске бежит быстрее. Скорость натиска +20 %.",
		"effect": {"key": "charge_speed_mult", "value": 0.2},
	},
	"night_shift_hr": {
		"title": "Ночная смена в отделе кадров",
		"text": "Котёл штампует подрядчиков чаще. Темп производства +20 %.",
		"effect": {"key": "production_mult", "value": 0.2},
	},
	"outstaff_partner": {
		"title": "Партнёр по аутстаффу",
		"text": "Бытовки и Котёл держат больше подрядчиков. Штат подрядчиков +15 %.",
		"effect": {"key": "army_cap_bonus", "value": 20.0},
	},
	"signing_bonus": {
		"title": "Подъёмные при найме",
		"text": "В штат подрядчиков берут больше народа. Штат подрядчиков +10 %.",
		"effect": {"key": "start_army_bonus", "value": 15.0},
	},
	"coffee_machine": {
		"title": "Кофемашина в приёмной",
		"text": "Мана восстанавливается быстрее. Реген маны +2/с.",
		"effect": {"key": "mana_regen_bonus", "value": 2.0},
	},
	"expanded_budget": {
		"title": "Расширенный бюджет",
		"text": "Больше маны про запас. Максимум маны +25.",
		"effect": {"key": "mana_max_bonus", "value": 25.0},
	},
	"union_contract": {
		"title": "Профсоюзный договор",
		"text": "Строй держит удар крепче. Снижение урона в строю ещё −10 %.",
		"effect": {"key": "hold_armor", "value": 0.1},
	},
	"cauldron_insurance": {
		"title": "Страховка Котла",
		"text": "Котёл Душ выдерживает больше. Максимум HP +30.",
		"effect": {"key": "cauldron_hp_bonus", "value": 30.0},
	},
	"hazard_pay": {
		"title": "Надбавка за вредность",
		"text": "Молния Ку бьёт на одну цель больше.",
		"effect": {"key": "q_chain", "value": 1.0},
		"needs": "ability_unlocked_q",
	},
	"silence_order": {
		"title": "Приказ о тишине",
		"text": "Ку оглушает дольше. Оглушение +30 %.",
		"effect": {"key": "q_stun", "value": 0.3},
		"needs": "ability_unlocked_q",
	},
	"brigade_quota": {
		"title": "Квота на бригаду",
		"text": "Дубль-вэ поднимает на один труп больше.",
		"effect": {"key": "w_raise", "value": 1.0},
		"needs": "ability_unlocked_w",
	},
	"rush_premium": {
		"title": "Премия за аврал",
		"text": "Аврал (Е) длится на 1,5 с дольше.",
		"effect": {"key": "e_dur", "value": 1.5},
		"needs": "ability_unlocked_e",
	},
	"loud_hailer": {
		"title": "Громкая связь",
		"text": "«Сбор» (R) перезаряжается быстрее. Откат −25 %.",
		"effect": {"key": "rally_cd", "value": -0.25},
		"needs": "control_unlocked_rally",
	},
	"sharp_pencil": {
		"title": "Заточенный карандаш",
		"text": "Зона «Точно!» глубже на 25 %.",
		"effect": {"key": "perfect_zone", "value": 0.25},
	},
	"bulk_paper": {
		"title": "Бумага оптом",
		"text": "Линии договоров дешевле. Мана линии −10 %.",
		"effect": {"key": "mana_cost_mult", "value": -0.1},
	},
	"soul_audit": {
		"title": "Ревизия душ",
		"text": "Души за убитых врагов +20 %.",
		"effect": {"key": "souls", "value": 0.2},
	},
	"armchairs": {
		"title": "Кресла с подлокотниками",
		"text": "Строй держит напор толпы крепче. +20 %.",
		"effect": {"key": "press_hold", "value": 0.2},
	},
	"charter_capital": {
		"title": "Уставной капитал",
		"text": "Объект начинается с запасом: +40 душ.",
		"effect": {"key": "start_souls", "value": 40.0},
	},
	"headhunters": {
		"title": "Хедхантеры",
		"text": "Элитные враги попадаются чаще (+2 %) — души ×4 с каждого.",
		"effect": {"key": "elite_chance", "value": 0.02},
		"needs": "loot_unlocked_items",
	},
	# артефакты v2 (D-0927-163): «чаще роняют» ломало бы «1–2 за бой, не каждый бой» — поправка
	# теперь перебрасывает только пустой бой (потолок два за бой прежний)
	"lost_property": {
		"title": "Стол находок",
		"text": "Бой без носителя артефакта выпадает реже.",
		"effect": {"key": "item_luck", "value": 1.0},
		"needs": "loot_unlocked_items",
	},
}

const LEGACY_UPGRADE_ORDER := [
	"overtime_clause", "aggressive_lawyers", "courier_bonus", "night_shift_hr",
	"outstaff_partner", "signing_bonus", "coffee_machine", "expanded_budget",
	"union_contract", "cauldron_insurance",
	"hazard_pay", "silence_order", "brigade_quota", "rush_premium", "loud_hailer",
	"sharp_pencil", "bulk_paper", "soul_audit", "armchairs", "charter_capital",
	"headhunters", "lost_property",
]

const UPGRADE_POOL := AmendmentDb.CARDS
const UPGRADE_ORDER := AmendmentDb.ORDER


# ── Пакет meta (v15): премия, «Контора», герой (DESIGN_V15 §6, §7, §11, §12 п.8–9) ────────────
## Почему секция здесь, а не в LegionCfg: у меты уже есть свой дом (UPGRADE_POOL выше) — новые
## пулы продолжают тот же файл, а не заводят второй источник истины для мета-данных.
## Все const этого файла — до методов (gdlint class-definitions-order); static func перенесены
## в конец файла.

## «Контора» — покупки за премию, открыты по видам (DESIGN_V15 §7, §12 п.9: покупки «Срок
## договора» нет — заменена на «Расчёт»). Каждая запись: title, desc (что даёт, понятным
## текстом), per_kind (по видам бойцов — по одной покупке на КАЖДЫЙ вид из LegionCfg.KIND_ORDER,
## иначе одна общая), stat_keys/per_level — параллельные массивы (несколько ключей — как у
## «Маны», которая двигает и потолок, и реген разом), costs — премия за переход на уровень
## i+1 (индекс i = costs[текущий_уровень]); длина costs = число уровней покупки.
const LEGACY_OFFICE_SHOP := {
	"range": {
		"title": "Дальность", "per_kind": true, "unit": "px",
		"desc": "Договор набирает бойцов своего вида дальше от линии.",
		"stat_keys": ["recruit_r_%s"], "per_level": [40.0], "costs": [40, 70, 110],
	},
	"staff": {
		"title": "Штат", "per_kind": true, "unit": "%",
		"desc": "Больше штатных мест на постройках этого вида.",
		"stat_keys": ["cap_mult_%s"], "per_level": [0.2], "costs": [50, 80, 120],
	},
	"respawn": {
		"title": "Возрождение", "per_kind": true, "unit": "%",
		"desc": "Освободившееся штатное место заполняется новым бойцом быстрее.",
		"stat_keys": ["respawn_mult_%s"], "per_level": [-0.15], "costs": [40, 70, 110],
	},
	"mana": {
		"title": "Мана", "per_kind": false, "unit": "",
		"desc": "Больше маны про запас (+20) и быстрее восстановление (+2/с) за уровень.",
		"stat_keys": ["mana_max_bonus", "mana_regen_bonus"], "per_level": [20.0, 2.0],
		"costs": [60, 90, 130],
	},
	"souls": {
		"title": "Стартовые души", "per_kind": false, "unit": "душ",
		"desc": "Объект начинается с бо́льшим запасом душ (+30 за уровень).",
		"stat_keys": ["start_souls"], "per_level": [30.0], "costs": [40, 70, 110],
	},
	"settlement": {
		"title": "Расчёт", "per_kind": false, "unit": "%",
		"desc": "Расчёт — прибавка здоровья бойцам, отстоявшим подновлённый участок до "
			+ "конца срока. Больше на 25 % за уровень.",
		"stat_keys": ["settlement_mult"], "per_level": [0.25], "costs": [60, 100],
	},
}
const LEGACY_OFFICE_SHOP_ORDER := ["range", "staff", "respawn", "mana", "souls", "settlement"]
## Старый API доступен для чтения архива; новый экран покупает разовые услуги RunProgression.
const OFFICE_SHOP := LEGACY_OFFICE_SHOP
const OFFICE_SHOP_ORDER := LEGACY_OFFICE_SHOP_ORDER

## Русские имена видов бойцов для экрана «Контора» (LegionCfg — владелец самих видов).
const KIND_LABELS := {
	&"laborer": "Подрядчик", &"guard": "Вахтёр", &"clerk": "Счетовод",
}


# ── Герой: опыт и разряд (DESIGN_V15 §6; переработка 06.10.2026) ───────────────────────────────
## Пороги — НАКОПЛЕННЫЙ опыт, нужный для разряда N (индекс 0 → разряд 2, ..., индекс 8 →
## разряд 10). Разряд 1 — старт; каждый пройденный порог открывает карточку колоды.
const HERO_LEVEL_THRESHOLDS: Array[int] = [100, 250, 450, 700, 1000, 1400, 1900, 2500, 3200]
const HERO_MAX_LEVEL := 10
## Ранги способностей и перки героя удалены в переработке 06.10.2026 (D-1006-11): покупку не
## предлагал ни один экран с 05.10, а в бой они не шли (читались через мёртвый _hero_mods).
## Разряд (HERO_LEVEL_THRESHOLDS выше) остался — он открывает варианты колоды поправок.


## Число звёзд по доле HP Котла на конец боя; вызывать только при победе (иначе 0 — Campaign
## сам не пускает сюда поражение).
static func stars_for_ratio(ratio: float) -> int:
	if ratio >= STAR3_RATIO:
		return 3
	if ratio >= STAR2_RATIO:
		return 2
	return 1


## За победу: 30 + 15×звёзды; за поражение: 10 + убийства/10 (целочисленно). Опыт героя:
## убийства + (50 + 20×звёзды при победе, иначе 0). kills — kills_rewardable статистики боя
## (пакет staff), если ключа ещё нет — обычный kills (задание meta, п.1 и п.3).
static func bounty_for_result(victory: bool, stars: int, kills: int) -> int:
	if victory:
		return 30 + 15 * stars
	return 10 + int(kills / 10.0)


static func hero_xp_for_result(victory: bool, stars: int, kills: int) -> int:
	return kills + (50 + 20 * stars if victory else 0)
