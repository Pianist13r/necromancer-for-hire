class_name PvpSide
extends RefCounted
##
## Всё «своё» одной стороны боя (docs/pvp/DESIGN.md §4): договоры, штат и души, герой, Котёл,
## бот, откат «Сбора», вид для игрока этой стороны. Одиночный бой — частный случай: сторона одна
## (индекс 0), и мир держит её поля под прежними именами (LegionWorld.souls, cauldron_hp… —
## свойства, читающие сторону 0), поэтому пакеты, писавшие по старым именам, не тронуты.
##
## Почему не булево «я / соперник»: D-0927-83 — сначала 1 на 1, но двойку не зашивать.
##

var index := 0
## Артефакты только этого матча и этой стороны.
var items: LegionItems = null
## Поле договоров стороны (свой ContractField: мана, договоры, черновик).
var contracts: ContractField = null
var staff: LegionStaff = null
var hero: LegionHero = null
## Бот этой стороны (LegionBot в одиночке, PvpBot в PvP) или null — играет человек/сеть.
var bot: RefCounted = null
var cauldron_pos := Vector2(180, 360)
var cauldron_hp := LegionCfg.CAULDRON_HP
var cauldron_max := LegionCfg.CAULDRON_HP
## Где рисуется Котёл стороны: cauldron_pos + map["cauldron_art"] у стороны 0 (одиночка, B-199);
## у остальных сторон — сама игровая точка (сдвиг картинки — свойство фона одиночной карты).
var cauldron_view_pos := Vector2(180, 360)
var souls := 0
var rally_cd := 0.0
## D-0927-140: запас маны, который способности стороны обязаны оставить на линии: у человека 0,
## у бота (LegionBot одиночки, PvpBot) — LegionCfg.BOT_MANA_RESERVE.
var ability_mana_reserve := 0.0
## Преобразование вида (DESIGN §3.2): тождество у стороны 0, отражение x' = W − x у стороны 1.
## Сервер о виде не знает; клиент (линия L3/L4) применяет его к карте, снимкам и своим командам.
var view_xf := Transform2D.IDENTITY
var surrendered := false
## Волны, дошедшие до Котла этой стороны (номер волны → true): душ за «отбитую» не дают.
var leaked_waves: Dictionary = {}
## Урон, который получил Котёл стороны, по источникам (после «Печатей»): units — чужие бойцы,
## waves — проверяющие волн. Для серий и отчёта.
var cauldron_dmg := {"units": 0.0, "waves": 0.0}
## Вид Котла и некроманта стороны ≥ 1 (у стороны 0 их держит мир, как раньше).
var cauldron_sprite: Sprite2D = null
var necro: CharView = null


func _init(i: int = 0) -> void:
	index = i


## Котёл жив.
func alive() -> bool:
	return cauldron_hp > 0.0 and not surrendered


## Доля HP Котла 0..1 — для предела матча и HUD.
func hp_frac() -> float:
	return clampf(cauldron_hp / maxf(1.0, cauldron_max), 0.0, 1.0)
