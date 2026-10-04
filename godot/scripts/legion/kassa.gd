class_name LegionKassa
extends RefCounted
##
## «Касса» — сток душ одиночного боя (B-022/B-085/B-280/B-353; решение инстанса, D-1001-01):
## к концу боя копились сотни душ при занятых и улучшенных площадках. Игрок закладывает души
## порцией (LegionCfg.KASSA_PORTION) — кнопка в HUD или клавиша Дэ; заложенное в этом бою
## недоступно (ни найм, ни постройки) и назад не выходит. Курс — душ за единицу премии — падает
## по третям волн (KASSA_RATES), премия кассы за бой — не больше KASSA_CAP. Победа: целая часть
## премии кассы идёт туда же, куда премия за бой («Контора» кампании или забега, LegionMain);
## поражение — касса сгорает. Силы в бою касса не даёт, поэтому волны (D-0930-71) не сбиваются.
##
## Нет кассы: в «Схватке» (стока душ там нет: «Донос» убран, D-1002-09) и в переигровке из
## коллекции (премии там нет, LegionWorld.kassa_allowed). Бот закладывает только с
## --dev bot_kassa=1 (замеры).
##

const REASON_TEXT := {
	"off": "Кассы здесь нет",
	"phase": "Касса работает только в бою",
	"souls": "Не хватает душ на закладку",
	"full": "Касса полна — больше премии за этот бой не будет",
}

## Заложено душ за бой.
var souls := 0
## Накопленная премия (дробная: 50 душ по 40:1 — 1,25); в итог идёт целая часть, не выше потолка.
var premium := 0.0
## Сколько закладок сделано.
var deposits := 0


func reset() -> void:
	souls = 0
	premium = 0.0
	deposits = 0


## Курс для номера начатой волны (0 — до первой) из total: первая треть волн — KASSA_RATES[0],
## вторая — [1], последняя — [2]. Карта без волн — первый курс.
static func rate_for(wave_no: int, total: int) -> int:
	var rates: Array = LegionCfg.KASSA_RATES
	if total <= 0 or wave_no <= 0:
		return int(rates[0])
	var third := clampi(((wave_no - 1) * rates.size()) / total, 0, rates.size() - 1)
	return int(rates[third])


## Курс прямо сейчас (по волнам мира).
func rate(w: LegionWorld) -> int:
	var wr := w.wave_runner
	if wr == null:
		return rate_for(0, 0)
	return rate_for(wr.wave_no(), wr.total())


## Премия кассы в итог: целая часть накопленного, не выше потолка.
func earned() -> int:
	return mini(LegionCfg.KASSA_CAP, floori(premium + 0.0001))


## Сколько душ уйдёт следующей закладкой: порция, а у потолка — ровно до потолка.
func next_amount(w: LegionWorld) -> int:
	var r := rate(w)
	var need := ceili((float(LegionCfg.KASSA_CAP) - premium) * float(r) - 0.0001)
	return clampi(need, 0, LegionCfg.KASSA_PORTION)


## "" — можно заложить сейчас; иначе причина (ключ REASON_TEXT).
func refusal(w: LegionWorld) -> String:
	if w.pvp or not w.kassa_allowed:
		return "off"
	if w.phase != LegionWorld.Phase.BATTLE:
		return "phase"
	# пока обучение держит волны, кассы нет и для клавиши Дэ, не только для кнопки: новичок
	# отдавал 50 из 60 стартовых душ, нужных на первую постройку (проверка 01.10)
	if w.tutorial != null and w.tutorial.holding():
		return "phase"
	var amount := next_amount(w)
	if amount <= 0:
		return "full"
	if w.souls < amount:
		return "souls"
	return ""


## Закладка порции. Ответ {ok, reason} или {ok, souls (сколько заложено), rate, earned}.
func deposit(w: LegionWorld) -> Dictionary:
	var why := refusal(w)
	if why != "":
		return {"ok": false, "reason": why}
	var r := rate(w)
	var amount := next_amount(w)
	w.staff.add_souls(-amount)
	souls += amount
	premium += float(amount) / float(r)
	deposits += 1
	return {"ok": true, "souls": amount, "rate": r, "earned": earned()}


## Бот (LegionBot.tick) — только с --dev bot_kassa=1 (замер стока душ): когда строить и улучшать
## нечего, излишек сверх KASSA_BOT_RESERVE — порцией в кассу. Без флага кассу не трогает: эталоны
## трасс бота (tests/data/*_bot_ref.txt) побайтно прежние. rng мира не трогает.
static func bot_step(w: LegionWorld) -> void:
	if int(w.dev.get("bot_kassa", 0)) != 1 or w.kassa.refusal(w) != "":
		return
	if w.souls < LegionCfg.KASSA_BOT_RESERVE + w.kassa.next_amount(w):
		return
	for p: Dictionary in w.staff.plots:
		var b: LegionBuilding = p["building"]
		if b == null or LegionStaff.upgrade_price(b) >= 0:
			return
	w.request_kassa()


## Итог боя для LegionMain: победа — премия кассы (ключ kassa итога) в раздел текущего scope
## Campaign, туда же, куда премия за бой; поражение — сгорела. В out — kassa (начислено) и
## kassa_souls (заложено), только если закладывали: экран итога печатает строку лишь тогда.
static func grant(victory: bool, stats: Dictionary, out: Dictionary) -> void:
	if int(stats.get("kassa_souls", 0)) <= 0:
		return
	var got := int(stats.get("kassa", 0)) if victory else 0
	Campaign.add_bounty(got)
	out["kassa"] = got
	out["kassa_souls"] = int(stats["kassa_souls"])


static func reason_text(reason: String) -> String:
	return String(REASON_TEXT.get(reason, "Касса недоступна"))
