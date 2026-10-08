class_name LegionEndless
extends RefCounted
##
## Логика режима «Бесконечный подряд» / «Вызов дня» (mode line, BOOK docs/procgen/BOOK.md §1,
## §13 вопрос 1; docs/procgen/STAGE2.md §5). Чистая логика без сохранения (хранение — Campaign,
## как LegionChallenge не хранит выбор сложности сам, а читает/пишет Settings). Этот файл не
## трогает генератор (procgen/*.gd — чужая линия): id объекта — либо строка "gen:<сид>:<k>" для
## настоящего генератора layout (после слияния координатор подключает её в LegionWorld.load_map),
## либо, в этой ветке для разработки и тестов, кампанийная карта по кругу
## (--dev endless_stub=1).
##

## Сохранение флоу «Дальше»/«Контора»/следующий объект (Campaign.pending_reward()) для забега:
## в кампании там лежит id следующей карты, в забеге — этот же смысл несёт неймспейс объекта,
## а фактический следующий id вычисляется заново из LegionRunStore.endless_k() (объект мог
## смениться, пока висела ожидающая награда). Сентинел просто отличает «это забег» от id карты.
const PENDING_SENTINEL := "endless:next"

## D-0927-96: выход в «Меню» ПОСРЕДИ объекта «Вызова дня» (подтверждённый — LegionPause) —
## не поражение от врага, а самовольное прекращение попытки; засчитывается тем же путём, что
## обычная смерть Котла (LegionMain._on_pause_menu_pressed подставляет этот тип в
## stats["last_hit_foe_type"] и зовёт world.force_end(false)), поэтому у него тоже есть
## «причина» в этом же словаре, а не отдельная ветка кода.
const ABANDON_TYPE := "abandoned"

## Причина смерти в некрологе — сатира по виду врага, нанёсшего последний удар по Котлу
## (BOOK §1: «Причина берётся из того, кто нанёс последний удар по Котлу»).
const DEATH_REASONS := {
	"zombie": "рутинная проверка не прошла — задавили массой",
	"beetle": "курьер доставил не туда и не то",
	"signer": "нотариальное заверение",
	"shield_inspector": "щитовой аудит: строй продавили в лоб",
	"ghost": "призрак прошёл сквозь все инстанции и печати",
	"lawyer": "юрист расторг договор в одностороннем порядке",
	"mimic": "надгробие оказалось не бутафорским",
	"boss": "личный визит Прораба Ада",
	ABANDON_TYPE: "самовольный уход с объекта — прогул смены без уважительной причины",
}
const DEFAULT_DEATH_REASON := "истёк договор — продлить не успели"
## Имя оставлено для старой оснастки кадров; сид уже привязан к реальному генератору.
const STUB_VERSION := ProcGen.VERSION


## Причина в некрологе по типу врага, нанёсшего последний удар (LegionWorld.damage_cauldron
## теперь помнит его в stats["last_hit_foe_type"], see legion_world.gd). Тип неизвестен
## (карта пала без единого удара по Котлу — теоретически, тест не встречал) — общая фраза.
static func death_reason(foe_type: String) -> String:
	return String(DEATH_REASONS.get(foe_type, DEFAULT_DEATH_REASON))


## id карты объекта k (k ≥ 1) забега run_seed. stub=true — кампанийная карта по кругу
## (--dev endless_stub=1, разработка и тесты этой ветки, генератора ProcGen здесь нет);
## stub=false — id настоящего генератора, "gen:<сид>:<k>" (ProcGen.map_from_id разбирает его
## после слияния линии layout, docs/procgen/STAGE2.md §2). Пустой каталог карт — "" (нечего
## показать, вызывающий (LegionMain.show_endless_briefing) обязан свести это к show_menu()).
static func object_map_id(run_seed: int, k: int, stub: bool) -> String:
	if not stub:
		return "gen:%d:%d" % [run_seed, k]
	var camp := Campaign.maps()
	if camp.is_empty():
		return ""
	var idx := (maxi(k, 1) - 1) % camp.size()
	return String(camp[idx].get("id", ""))


## Дата «Вызова дня» — ГГГГ-ММ-ДД, локальная (BOOK §1: «дата — локальная»).
static func today_date() -> String:
	return Time.get_date_string_from_system(false)


## Сид «Вызова дня»: одинаковый у всех игроков в одну дату и версию генератора. String.hash()
## детерминирован для одной и той же строки в рамках одной версии движка — этого хватает для
## «одна дата → один сид», проверено тестом legion_procgen_mode_test.gd.
static func daily_seed(date: String) -> int:
	return ("daily|%s|%d" % [date, ProcGen.VERSION]).hash()


## Случайный сид обычного (не дневного) забега.
static func random_seed() -> int:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	return rng.randi()
