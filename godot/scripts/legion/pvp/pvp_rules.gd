class_name PvpRules
extends RefCounted
##
## Числа «Схватки» (онлайн-PvP 1 на 1, docs/pvp/DESIGN.md §2). Всё здесь — стартовые значения
## (решено инстансом, D-0927-181…): подбирать серией «бот против бота» (tools/pvp_series.sh), а
## не на глаз. Одиночный бой этих чисел не читает — у него своя LegionCfg.
##

## Котёл стороны в PvP (DESIGN §2.3). Считать вместе с «Печатями» (ниже): до 2,5 минуты урон
## ×0,25 — Котёл держит как 1200 HP; к 5-й минуте ×6 — как 50 HP. Было 600 без печатей: серия
## P3 — 33 из 42 матчей до предела 12 мин, 5 из 9 разрушений — быстрее 3 минут (BALANCE.md 30.09).
const CAULDRON_HP := 300.0
## Экономика PvP независима от подбора одиночки B-402: сохраняем проверенный сетевой бой.
## В нём мана поддерживает перебежки двух армий; менять только отдельной парной серией.
const MANA_REGEN := 12.0
const ABILITY_MANA: Array[float] = [25.0, 30.0, 20.0]
## Души за чужого бойца (§2.4): дешевле проверяющего, иначе выгодно «кормиться» соперником.
const SOULS_PER_UNIT := 2
## Предел матча, с (§2.7): по истечении побеждает больший процент HP Котла; разница меньше
## DRAW_MARGIN — ничья.
const MATCH_LIMIT := 720.0
const DRAW_MARGIN := 0.05
## «Печати Котла» (P3, D-0929-51): любой урон Котлу (чужие бойцы, проверяющие) умножается на
## множитель времени матча — до SEALS_FROM секунды SEALS_START (Котёл крепок: первый прорыв не
## решает матч за 2–3 минуты), дальше растёт по прямой до SEALS_END к SEALS_TO (затяжной матч
## дожимается разрушением Котла, а не пределом). Серии бот-бот — docs/dev/BALANCE.md 30.09.
const SEALS_FROM := 150.0
const SEALS_TO := 300.0
const SEALS_START := 0.25
const SEALS_END := 6.0
## Волны по часам (§2.6): первая на 60-й секунде, дальше каждые 45 с — одинаково обеим сторонам.
const FIRST_WAVE := 60.0
const WAVE_EVERY := 45.0
## Отдельный темп артефактов короткого PvP: гарантируется носитель, не его убийство.
const ITEM_HOME_AT := 12.0
const ITEM_CONTESTED_AT := 35.0
const ITEM_HOME_MIN_DISTANCE := 260.0
const ITEM_SEAM_OFFSET := 48.0

## Уровень волн PvP — «Стажёр» (прежние числа), слабые волны — давление и души, не угроза.
const DIFFICULTY := "intern"
## Карты PvP живут не в каталоге кампании: Campaign.maps() вставил бы их в кампанию.
const MAP_PREFIX := "pvp:"
## Поле матча (§3.1, масштаб 0,8): половина 800×900, поле 1600×900.
const FIELD := Vector2(1600.0, 900.0)
## Оттенок бойцов стороны — различить армии, пока нет своих спрайтов (линия L4 заменит).
const SIDE_TINT: Array[Color] = [Color(1.0, 1.0, 1.0), Color(1.0, 0.62, 0.55)]
## Сервер (DESIGN §6.6): боец, вокруг которого пусто, ищет цель раз в IDLE_SCAN_SKIP + 1 шагов.
const IDLE_SCAN_SKIP := 2
## Маркер стороны под бойцом — на столько ниже линии ступней (тело спрайта его не закрывает).
const MARKER_DY := 3.0
## Больше стольких сторон движок не ждёт (двойка не зашита — D-0927-83; предел — размер таблиц).
const MAX_SIDES := 4


## Множитель урона Котлу в момент матча t («Печати Котла»).
static func cauldron_mult(t: float) -> float:
	return lerpf(SEALS_START, SEALS_END, clampf((t - SEALS_FROM) / (SEALS_TO - SEALS_FROM), 0.0, 1.0))


## Оттенок бойцов стороны i (за пределами таблицы — последний).
static func tint(i: int) -> Color:
	return SIDE_TINT[clampi(i, 0, SIDE_TINT.size() - 1)]


## Цвет + форма: различимость сохраняется без цветового зрения и поверх предметного tint.
static func marker_points(at: Vector2, side: int, radius: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	var count := 16 if side % 2 == 0 else 4
	for i in count + 1:
		var a := TAU * float(i) / float(count)
		out.append(at + Vector2(cos(a) * radius, sin(a) * radius * 0.5))
	return out


## Цвет маркера — смысл «чей» из таблицы CfgFx.MEANING_COLOR (legion_vfx_clarity_test).
static func marker_color(side: int) -> Color:
	return CfgFx.C_SIDE_0 if side % 2 == 0 else CfgFx.C_SIDE_1


static func draw_marker(ci: CanvasItem, at: Vector2, side: int, radius: float) -> void:
	var pts := marker_points(at, side, radius)
	ci.draw_polyline(pts, Color(0.045, 0.035, 0.065, 0.95), 4.0, true)
	ci.draw_polyline(pts, marker_color(side), 1.7, true)
