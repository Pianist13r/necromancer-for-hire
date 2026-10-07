# gdlint: disable=max-public-methods,max-file-lines
class_name LegionWorld
extends Node2D
##
## Мир режима «По истечении договора» — корень scenes/legion_world.tscn, собирает всё кодом.
## Контракт — docs/legion/SLICE_SPEC.md §3; числа — LegionCfg. Раньше был прямым корнем
## scenes/legion.tscn; с пакета flow (v13) legion.tscn — LegionMain (экраны меню/кампании),
## который встраивает этот мир как ребёнка через legion_world.tscn (см. `embedded`, `mods`).
##
## Аргументы после `--`: --mute --autostart --map ID --bot hold|release|selective|off
## --seed N --trace --quit-on-end --bench N --shot ПУТЬ --shot-frame N --dev КЛЮЧ=ЗНАЧ.
## Ключи --dev пакета CORE: spawn_units=N (армия на старте), spawn_foes=N (враги на дорогах
## на старте), invuln=1 (урона нет ни у кого — замер кадра на постоянной массе), no_waves=1.
## Пакет f0: spawn_kind=ВИД:N[,ВИД:N] — сверх армии у Котла ещё N бойцов вида (кадр видов),
## например --dev spawn_kind=guard:10,clerk:10.
## Пакет tutorial: tutorial=1 (обучение поверх боя), tutorial_step=N (1..9 — кадр шага),
## tutorial_play=good|clumsy|pause (прохождение настоящим вводом, tools/tutorial_play.sh).
##
## Шаг кадра (порядок важен и задан спекой): штат построек (staff.gd) → волны → бот → таяние
## участков → раздача свободных → враги → бойцы → расталкивание → уборка → итог → HUD.
## Сетка поиска соседей пересобирается раз в кадр: поиск без аллокаций, словарей и физики.
##

signal match_started(map_id: String)
signal match_ended(victory: bool, stats: Dictionary)
signal wave_started(i: int, total: int)
signal wave_cleared(i: int)
signal wave_called(i: int, bonus: int)
signal breach_warned(id: String, in_s: float, summary: Array)
signal breach_opened(id: String)
signal foe_died(foe: Foe)
signal unit_died(unit: Legionnaire)
signal unit_spawned(unit: Legionnaire)
signal cauldron_hit(amount: float)
signal contract_created(c: Contract)
signal contract_refreshed(c: Contract, segs: PackedInt32Array)
signal segment_released(c: Contract, seg: int, n_units: int)
## Таб стёр линию или фигуру (ContractField.erase): сорвано участков и ушло в натиск бойцов.
signal tab_erased(c: Contract, n_segs: int, n_units: int)
## Угловая фигура выпущена ЗАРЯЖЕННОЙ (ульта/специальный выпуск) — зачёт урока фигуры
## (LegionTutorial: «сорви заряженную»).
signal figure_ult(c: Contract)
## Фигура выпущена рогаткой по ОБЩЕЙ оси оттяжки — зачёт урока «выпусти одну группу».
signal figure_slung(c: Contract)
## v17 LAW: Юрист расторг участок (tear_segment) — натиска нет, n_units бойцов стали свободны.
signal segment_torn(c: Contract, seg: int, n_units: int)
signal contract_removed(c: Contract)
signal toast_posted(text: String, kind: StringName)
signal boss_roared(foe: Foe, target: Vector2)
signal boss_rammed(foe: Foe, target: Vector2)
## Пакет flow: LegionMain показывает/прячет экран паузы по этому сигналу (не опрашивает paused
## каждый кадр). Эмитится из set_paused() при каждом вызове, даже если значение не изменилось —
## обработчик идемпотентен.
signal paused_changed(p: bool)
## tutfix (item 6): выход в меню (go_to_menu) — сигнал для систем, которым нужно знать момент
## возврата в меню отдельно от match_ended (тот стреляет только при исходе боя). Сейчас слушает
## LegionAudio (legion_audio.gd), чтобы остановить боевую/боссовую музыку.
signal menu_entered
## P6: «В меню» на итоге «Схватки» в мире, встроенном в LegionMain, — показать главное меню.
signal pvp_menu_requested
## v15 (DESIGN_V15 §11), пакет f0 объявляет — логику душ, построек и героя дают staff/hero.
## foe_killed — только настоящая гибель врага (не прорыв к Котлу); pos — где он пал.
signal foe_killed(foe: Foe, pos: Vector2)
signal souls_changed(value: int)
signal building_changed(b: Object)
signal hero_cast(slot: int, at: Vector2)
## integrate1: игрок нажал покупку/улучшение, на которые не хватает душ (меню участка).
signal souls_short
## v17 CTL: комбо натисков изменилось (0 — сброс); mult — множитель урона и душ.
signal combo_changed(combo: int, mult: float)
## v17 CTL: первое касание залпа натиска с врагом (точка удара; точный срыв — perfect).
signal charge_impact(at: Vector2, perfect: bool)
## v18 «Давка»: толпа прорвала участок (бойцы раскиданы и оглушены).
signal segment_broken(c: Contract, seg: int, n_units: int)
## v18 «Пружина»: выпущен прогнутый участок; bend — доля прогиба 0..1.
signal spring_released(c: Contract, seg: int, bend: float)

## v18 «Сбор» (R): n — скольких позвали (0 — некого; откат тогда не тратится).
signal rally_used(at: Vector2, n: int)
## D-0927-140: способности не хватило маны (slot 0–2 — Ку/Дубль-вэ/Е, LegionCfg.RALLY_SLOT —
## «Сбор»): слот мигает, звук отказа; каст не прошёл, откат не тратится.
signal mana_short(slot: int)
## Удар с разбега пришёлся по оглушённому врагу (×STUNNED_CHARGE_MULT) — зачёт урока связки Ку
## и натиска. Сигнал, а не счётчик в stats: stats входит в свёртку трассы бота.
signal stunned_charge_hit(foe: Foe)

enum Phase { MENU, BATTLE, VICTORY, DEFEAT }
const GROUND_LOAD_TIMEOUT_SEC := 20.0
## Онлайн-«Схватка» (docs/pvp/NET_LOCKSTEP.md): шаг сетевого матча — ровно 1/60 с у обоих клиентов.
const NET_DT := 1.0 / 60.0
## Ключи --dev, которые сетевой матч оставляет: только вид. Остальные (spawn_units, items, invuln,
## no_waves, pvp_swap…) меняют бой — у соперника их нет, и lockstep разошёлся бы с первого тика.
const NET_DEV_KEEP := ["gfx", "noview", "intuit", "fx", "save"]

const TEX_CAULDRON := preload("res://assets/img/cauldron.png")
const ALL_CHARS := [
	"skeleton", "necromancer", "zombie", "beetle", "signer", "ghost", "mimic", "boss",
]
## Серые цвета отладочной земли (пока нет TerrainView пакета MAPS).
const C_GROUND := Color(0.20, 0.21, 0.19)
const C_ROAD := Color(0.30, 0.28, 0.24)
const C_WATER := Color(0.12, 0.20, 0.30)
const C_BRIDGE := Color(0.36, 0.30, 0.22)
const C_SWAMP := Color(0.18, 0.25, 0.16)
const C_ROCK := Color(0.38, 0.38, 0.40)
const ROAD_W := 30.0
const STAMP_COLOR := CfgFx.C_DANGER
## Водитель ввода для приёмки обучения (--dev tutorial_play); грузится только по этому ключу.
const TUTORIAL_DRIVER := "res://scripts/dev/legion_tutorial_driver.gd"
## Игра по переписке (--dev corr=папка); грузится только по этому ключу.
const CORR_PLAY := "res://scripts/dev/corr_play.gd"

## Пакет flow: true — мир встроен в LegionMain и сам не стартует карту в _ready() (интегратор
## сам решает, когда и какую карту начать через start_map()). false (по умолчанию) — старое
## поведение: мир как корень сцены сам разбирает CLI-аргументы и стартует бой немедленно
## (на этом стоят гейт/боты/серии/тесты — режим не трогаем).
var embedded := false
## Пакет flow: сумма поправок кампании (Campaign.active_mods()), которые применяет ЭТОТ мир —
## ключи описаны в legion_meta_cfg.gd. Пусто по умолчанию — поведение мира не меняется, пока
## интегратор явно не выставит mods перед start_map().
var mods: Dictionary = {}
## Уровень сложности боя (LegionChallenge): --dev difficulty=intern|normal|hell, иначе Settings.
## Выставляется в start_map и держится до конца боя.
var difficulty := LegionChallenge.DEFAULT
## v15 (integrate1): бой идёт внутри кампании — открытия видов/способностей и прокачка берутся
## из сохранения (Campaign.stat). Ставит LegionMain; тест, которому нужна мета, ставит сам.
## false (гейт, серии бота, тесты, --autostart без кампании) — всё открыто, прокачка нейтральна.
## Отдельно от `embedded`: тесты встраивают мир ради ручного старта карты, а не ради меты.
var in_campaign := false
var phase := Phase.MENU
var now := 0.0
var paused := false
## Игра по переписке (--dev corr=папка, scripts/dev/corr_play.gd): мир стоит, пока игрок-агент
## думает над ходом. В отличие от paused, ввод и интерфейс продолжают работать — ход вводится
## настоящими событиями в стоящий мир.
var hold := false
var units: Array[Legionnaire] = []
var foes: Array[Foe] = []
var crypts: Array[LegionCrypt] = []
var terrain: LegionTerrain = null
var contracts: ContractField = null
var map: Dictionary = {}
var map_id := ""
var rng := RandomNumberGenerator.new()
## Стороны боя (docs/pvp/DESIGN.md §4): одиночка — одна сторона (_s0), «Схватка» — две и более.
## Поля ниже (cauldron_hp, cauldron_max, cauldron_pos, souls, rally_cd) — свойства стороны 0:
## пакеты и тесты, писавшие по этим именам, работают как раньше.
var sides: Array[PvpSide] = []
## Бой нескольких сторон: включает бой боец↔боец, правила PvP (нет паузы, Отсрочки, вызова
## волн; волны по часам; конец матча — PvpMatch).
var pvp := false
var pvp_match: PvpMatch = null
## «Касса» (D-1001-01): сток душ одиночного боя в премию «Конторы»; сбрасывается с каждым боем.
var kassa := LegionKassa.new()
## false — кассы в этом бою нет (переигровка из коллекции: премии там нет). Ставит поток боя
## (LegionMain._ensure_world — true, LegionCollectionFlow.start_battle — false).
var kassa_allowed := true
## Меню «Схватки» по Esc (паузы в PvP нет) — создаётся на первом матче PvP.
var pvp_menu: PvpMenu = null
## Онлайн-«Схватка» (docs/pvp/NET_LOCKSTEP.md): оба клиента гоняют этот мир с одним сидом и картой,
## ввод людей — только команды PvpCmd. Мир сам не шагает (шагает сессия через net_step), ботов нет,
## ни одно действие человека не меняет мир напрямую — всё уходит в net_out и возвращается net_apply.
var net_mode := false
## Сторона человека за этим экраном: ввод, интерфейс, итог. Логика боя её не читает — оба клиента
## считают одинаково. Вне сети 0: интерфейс и ввод прежние.
var local_side := 0
## Мир зовёт net_out.call(cmd) на каждое действие локального игрока сетевого матча.
var net_out: Callable = Callable()
## Сколько раз вызван net_step() в этом матче.
var net_tick := 0
## Идёт net_apply: поле исполняет команду, а не рисует превью человека (ContractField).
var net_applying := false
## Размер мира этой карты (map.size; одиночка — 1280×720, DESIGN §3.3).
var world_size := LegionCfg.WORLD_SIZE
## P5a: вид поля — мир → логический экран (LegionCfg.WORLD_SIZE, stretch canvas_items + keep).
## Поле вписано целиком и по центру (PvP 1600×900 → ×0,8); одиночка — ровно IDENTITY. Камера
## ставится по нему же (_apply_view), мышь переводится обратным (screen_to_world) — одно место.
## Тряска камеры (Juicee, смещение position) сюда не входит: прицел не дрожит вместе с кадром.
var view_xf := Transform2D.IDENTITY
## Мир без вида (сервер «Схватки», DESIGN §6.6; --dev noview=1): виды персонажей не
## анимируются и не рисуются, линии и эффекты не перерисовываются — считается только бой.
var no_view := false
var cauldron_hp: float:
	get:
		return _s0.cauldron_hp
	set(v):
		_s0.cauldron_hp = v
## Пакет flow: максимум HP Котла ЭТОЙ карты с учётом cauldron_hp_bonus — считается один раз
## в start_map(). Нужен снаружи для процента на экране итога (звёзды, полоска HP).
var cauldron_max: float:
	get:
		return _s0.cauldron_max
	set(v):
		_s0.cauldron_max = v
var cauldron_pos: Vector2:
	get:
		return _s0.cauldron_pos
	set(v):
		_s0.cauldron_pos = v
## Где РИСУЕТСЯ Котёл: cauldron_pos + map["cauldron_art"] (сдвиг [dx, dy], по умолчанию 0).
## 29.09 (Игорь, B-199): подложка Котла впечатана в фон карты и на «Архиве»/«Проходной» легла
## мимо игровой точки; саму точку двигать нельзя — к ней ведут дороги и трассы карты
## (legion_maps_test), поэтому двигаем только картинку, HP-полоску и эффекты зелья.
## Вид Котла — у каждой стороны (PvpSide.cauldron_view_pos); здесь — сторона 0 / одиночка.
var cauldron_view_pos: Vector2:
	get:
		return _s0.cauldron_view_pos
	set(v):
		_s0.cauldron_view_pos = v
var wave_runner: WaveRunner = null
## Пакет tutorial: не null, пока идёт обучение на wasteland (docs/legion/TUTORIAL_SPEC.md).
## Тикается явно из _step(), тем же паттерном, что wave_runner и bot.
var tutorial: LegionTutorial = null
var bot: LegionBot = null
var hud: LegionHud = null
var entities: Node2D = null
var stats: Dictionary = {}
var args: Dictionary = {}
var dev: Dictionary = {}
var dev_invuln := false
var grid: LegionGrid = null
## v15: внутрибоевая валюта (пакет staff меняет её и шлёт souls_changed). Души стороны 0.
var souls: int:
	get:
		return _s0.souls
	set(v):
		_s0.souls = v
## v15: постройки боя (LegionBuilding): Котёл, постройки на участках, склепы.
var buildings: Array = []
## v15 (пакет staff): штат, возрождение, участки и души — логика в staff.gd.
var staff := LegionStaff.new()
## v15 (пакет staff): меню участка (tap по участку/постройке).
var plot_menu: PlotMenu = null
## Снаряды дальних бойцов (печати счетовода).
var projectiles := LegionProjectiles.new()
## Фигуры договора: восьмёрка «Двойная смена», треугольник «Обряд», квадрат «Каре»
## (contract_figures.gd).
var figures := LegionFigures.new()
## Пакет hero: способности некроманта у Котла (Ку/Дубль-вэ/Е). Создаётся вместе с Котлом
## каждый start_map, откаты и внештатники не переживают перезапуск карты.
var hero: LegionHero = null
## Звук/сочность (legion_audio.gd) — узел этого боя. polish1: если мир встроен в LegionMain,
## это тот же узел, что уже озвучивал экраны кампании до боя (см. `injected_audio` и
## `_build()`) — не второй, отдельно созданный. Доступен снаружи: шаги обучения зовут voice().
var audio: LegionAudio = null
## polish1: `LegionMain` выставляет ДО `add_child(world)` (значит, до `_ready()`/`_build()`),
## когда у неё уже есть свой узел озвучки кампании — `_build()` тогда переиспользует его вместо
## создания нового. null (по умолчанию) — старое поведение: мир как корень (гейт/бот/тесты)
## заводит собственный узел, как раньше.
var injected_audio: LegionAudio = null
## v17 CTL: комбо натисков (DESIGN_V17 §2.4); 0 — нет комбо. Менять — через _set_combo().
var combo := 0
## Сколько из stats["perfect_releases"] дал Таб (release_run). Уроки «Точно!» учат щелчку и
## рогатке и вычитают их (verifier slow/tab-erase). Не в stats: stats входит в свёртку трассы бота.
var tab_perfect_releases := 0
## v18 «Сбор» (R): откат, игровые секунды (стороны 0; у каждой стороны свой).
var rally_cd: float:
	get:
		return _s0.rally_cd
	set(v):
		_s0.rally_cd = v
## D-0927-140: запас маны, который способности обязаны оставить на линии. У человека 0; бот —
## LegionCfg.BOT_MANA_RESERVE (ставится при старте боя с ботом). Запас — у каждой стороны
## (PvpSide.ability_mana_reserve); здесь — сторона 0 / одиночка.
var ability_mana_reserve: float:
	get:
		return _s0.ability_mana_reserve
	set(v):
		_s0.ability_mana_reserve = v
## v19 (B-038): R зажата — у курсора круг «Сбора» и отметки, кого позовёт (сбор — на отпускание).
var rally_aiming := false
## clarity (26.09): прицел Ку/Дубль-вэ/Е — зажал клавишу, видно цели; отпустил — каст.
var ability_aim: LegionAbilityAim = null
## v19: подсветка препятствий — пока чертишь или тянешь рогатку и в начале боя.
var obstacle_hint: ObstacleHint = null
## Артефакты (Игорь 26.09 «как в Айзеке», v2 — D-0927-163): редкие носители посреди боя,
## живут весь забег. Числа читаются item_mult/item_add, особые — обработчики items/item_effects.gd.
var items: LegionItems = null
## Артефакты переживают бой: LegionMain ставит true для боя кампании и забега (раздел забега
## текущего scope Campaign). false — одиночный бой (--map), бот, тесты, переигровка вне забега:
## артефакты только этого боя, в сохранение не пишутся.
var carry_items := false
## slow/intuit: золотой участок, метка пружины, оглушённые и советы «когда жать навык» — только
## вид, бой из него ничего не читает (legion_intuit.gd).
var intuit: LegionIntuit = null
## Постройки, склепы, Котёл и тени бойцов собранной карты встают в землю (D-CX-08): проба итоговой
## картинки PgArt; null — карта с нарисованным фоном (кампания) или картинка ещё не готова.
var harmony: PgArtHarmony = null
## Поправки-правила забега (A1): AmendmentRuntime висит на сигналах боя и ведёт queue/echo/ghost/
## vassal_march/dividend. Создаётся в _build(), переставляется на каждую карту в start_map();
## helper сам отсекает standalone/PvP (setup без подписок, tick нейтрален), поэтому PvP как раньше.
var amendment_runtime: AmendmentRuntime = null
## Подготовка «Конторы» на следующий объект (start_souls / mana_max_bonus): копия
## RunProgression.preparation_mods() ДО старта боя. Эти моды НЕ в active_mods; складываются сюда же,
## в camp_stat(), чтобы выживать последующие пересчёты маны (артефакты не убирают купленную ману).
var battle_preparation: Dictionary = {}

## Сторона 0: хранит поля одиночки (cauldron_hp, souls… — свойства выше читают её).
var _pvp_item_stage := 0
var _pvp_carrier_serial := 0
var _pvp_carrier_hits: Dictionary = {}
var _resolving_carrier: Foe = null
var _s0 := PvpSide.new(0)
## PvP: удары бойцов по чужим бойцам этого шага — [цель, урон, откуда, сторона]; наносятся
## после хода всех бойцов (_flush_pvp_hits), чтобы порядок списка units не давал преимущества.
var _pvp_hits: Array = []
## PvP: этот шаг идёт в обратном порядке сторон и бойцов (чередование, B-296).
var _pvp_flip := false
## «Оборона дома»: по стороне — есть ли в зоне дома (HOME_GUARD_R у её Котла) враждебная цель
## на этот шаг; 1 — есть. Считается до хода бойцов (_scan_home_threats).
var _home_threat := PackedByteArray()
## Уроки запущены принудительно (кнопка «Обучение», --dev): «Заново» повторяет их так же.
var _lessons_force := false
var _corpses: Array[Node2D] = []
var _ground: Node2D = null
## Бой и игровой ввод ждут, пока PgArt не вернёт фон или ошибку.
var _ground_loading := false
var _ground_loading_layer: CanvasLayer = null
var _pending_ground_lessons := false
var _pending_ground_lessons_force := false
var _pending_ground_lessons_generation := -1
var _depth_decor: Node = null
var _depth_generation := 0
var _plot_view: LegionPlotView = null
var _fx: Node2D = null
## «Графика: экономная» (B-053/B-054) — тени и слой эффектов; создаёт/освобождает
## _sync_gfx_layers() по Settings.is_economy_graphics(), не только _build().
var _shadows_node: CharShadows = null
var _gfx_fx: LegionFx = null
var _cauldron: Sprite2D = null
var _necro: CharView = null
var _assign_t := 0.0
var _trace_t := 0.0
## Метрика читаемости (D-0927-49, «чтоб успевали отслеживать»): пик и среднее по времени боя
## живых врагов и своих бойцов. Отдельно от stats: stats входит в эталон трассы бота, а замер
## не должен его двигать. В итог боя — final_stats (серии legion_series.sh).
var _pace := {"peak_foes": 0, "peak_army": 0, "foe_s": 0.0, "army_s": 0.0, "t": 0.0}
var _breach_marks: Array[Dictionary] = []
var _damage_hp: Dictionary = {}
var _impacts: Array[Vector3] = []     ## x, y — центр; z — оставшееся время вспышки
var _impact_r := PackedFloat32Array()
## v17 LAW: вспышки разрыва участка Юристом — {poly, t}.
var _tears: Array[Dictionary] = []
## v18 «Сбор»: вспышки точек сбора {pos, t, n}.
var _rallies: Array[Dictionary] = []
# служебные режимы
var _frames := 0
var _bench_s := 0.0
var _bench_el := 0.0
var _bench_n := 0
var _bench_tick_us := 0
## Замер PvP-сервера (DESIGN §6.6): тик каждого кадра (перцентили) и стенные часы — при
## --fixed-fps кадр мира всегда 1/60 с, реальная цена кадра видна только по стенным часам.
var _bench_ticks := PackedInt32Array()
var _bench_wall0 := 0
var _shot_path := ""
var _shot_frame := 90
var _base_seed := 1
## start_net_match зовёт start_map: сетевые поля не сбрасывать (иной старт карты — сбросить).
var _net_starting := false
## Пакет hero: --dev hero_cast=SLOT:FRAME:X,Y — единоразовый каст способности для приёмочного
## кадра (`--shot`), чтобы не гонять MCP-мост ради скриншота. Slot — 0/1/2 (Ку/Дубль-вэ/Е).
var _dev_hero_cast_done := false
## Последняя позиция мыши ИЗ СОБЫТИЯ — в ЭКРАННЫХ координатах вьюпорта (в мир — aim_pos(),
## через view_xf). Способности целятся сюда:
## get_global_mouse_position() корневого окна спрашивает курсор ОС, а он не двигается от событий,
## присланных Input.parse_input_event (водитель приёмки, MCP-мост) — Ку летела бы мимо.
var _mouse_pos := Vector2.ZERO
var _mouse_seen := false
## v17 CTL: удар натиска (§2.5) и окно комбо.
var _combo_hit_t := -INF
var _combo_soul_frac := 0.0
var _hitstop_left := 0.0
var _hitstop_gap := 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	args = parse_args()
	dev = args["dev"]
	dev_invuln = dev.has("invuln")
	no_view = dev.has("noview")
	# --dev gfx=economy|full — замер кадра A/B без правки user://settings.cfg владельца
	# (Settings.economy_override, тот же приём, что scheme_override).
	if dev.has("gfx"):
		Settings.economy_override = "on" if String(dev["gfx"]) == "economy" else "off"
	CharView.economy_motion = Settings.is_economy_graphics()
	if args.has("mute"):
		AudioServer.set_bus_mute(0, true)
	_bench_s = float(args.get("bench", 0.0))
	if _bench_s > 0.0:
		# без этого замер упирается в vsync и меряет монитор, а не наш кадр (world_dev.gd)
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		Engine.max_fps = 0
	_shot_path = String(args.get("shot", ""))
	_shot_frame = int(args.get("shot_frame", 90))
	_base_seed = int(args.get("seed", 1))
	if not embedded and Campaign.uses_real_save():
		# Мир без кампании (гейт, бот, demo.bat, замеры) писал разовые подсказки и прочие отметки
		# в настоящий user://legion.cfg владельца — у него потом не показывались обучение и
		# подсказки. Такие прогоны пишут в свой файл, каждый раз с чистого листа.
		# Суффикс test отличает одноразовые прогоны от сохранений игрока.
		Campaign.set_save_path(Campaign.STANDALONE_PATH.replace(".cfg", "_test.cfg"))
		Campaign.reset()
	CharView.warm(ALL_CHARS)
	_build()
	if not embedded:
		start_map(String(args.get("map", LegionCfg.DEFAULT_MAP)))
		# автотест обучения (compat-путь): --dev tutorial=1 [tutorial_step=N] — TUTORIAL_SPEC.md
		if dev.has("tutorial"):
			start_tutorial()
			if dev.has("tutorial_step") and tutorial != null:
				tutorial.force_step(int(dev["tutorial_step"]) - 1)
			# приёмка обучения настоящим вводом: --dev tutorial_play=good|clumsy|pause
			# (tools/tutorial_play.sh, scripts/dev/legion_tutorial_driver.gd)
			if dev.has("tutorial_play"):
				var drv: Node = (load(TUTORIAL_DRIVER) as GDScript).new()
				drv.call("setup", self, String(dev["tutorial_play"]))
				add_child(drv)
		# уроки любой карты вне кампании (кадры приёмки): --dev lessons=1 [lesson=<id>]
		if dev.has("lessons"):
			start_lessons(true)
			if dev.has("lesson") and tutorial != null:
				tutorial.force_lesson(StringName(String(dev["lesson"])))
		# игра по переписке: --dev corr=папка (только отладочная сборка)
		if dev.has("corr") and OS.is_debug_build():
			var corr: Node = (load(CORR_PLAY) as GDScript).new()
			corr.call("setup", self, String(dev["corr"]))
			add_child(corr)


## Аргументы после `--` (докстринг файла).
static func parse_args() -> Dictionary:
	var out := {}
	var dev_kv := {}
	var argv := OS.get_cmdline_user_args()
	var i := 0
	while i < argv.size():
		var a: String = argv[i]
		var next: String = argv[i + 1] if i + 1 < argv.size() else ""
		match a:
			"--mute", "--autostart", "--trace", "--fast":
				out[a.trim_prefix("--")] = true
			"--quit-on-end":
				out["quit_on_end"] = true
			"--pvp-bots":
				# «Схватка» бот против бота (обе стороны — PvpBot): серии и замер без людей
				out["pvp_bots"] = true
			"--seed":
				out["seed"] = next.to_int()
				i += 1
			"--bench":
				out["bench"] = next.to_float()
				i += 1
			"--map", "--bot", "--shot":
				out[a.trim_prefix("--")] = next
				i += 1
			"--shot-frame":
				out["shot_frame"] = next.to_int()
				i += 1
			"--dev":
				var kv := next.split("=", true, 1)
				dev_kv[kv[0]] = kv[1] if kv.size() > 1 else "1"
				i += 1
		i += 1
	out["dev"] = dev_kv
	return out


## Пакет flow: множитель поправок по ключу (1.0 + свод active_mods()); нет поправки — 1.0. Свод для
## ключа-множителя — уже произведение источников (MetaMods.combine), а не сумма процентов.
## Читают системы, которые применяют бонус САМИ (contract.gd/contract_field.gd не трогаем —
## их владеют параллельные пакеты, поэтому применение — здесь и в unit.gd минимально).
func mod_mult(key: String) -> float:
	return 1.0 + float(mods.get(key, 0.0))


## Пакет flow: сумма поправок-абсолютных бонусов; нет поправки — 0.0.
func mod_add(key: String) -> float:
	return float(mods.get(key, 0.0))


## Предметы: множитель по ключу реестра (item_db.gd) — 1 + свод артефактов и синергий боя с
## поправками кампании (item_add). Ключ-множитель перемножает источники, прибавочный складывает.
func item_mult(key: StringName, side := 0) -> float:
	return 1.0 + item_add(key, side)


## Предметы: прибавка по ключу (сумма предметов, синергий и поправок с тем же ключом).
func items_of(side: int) -> LegionItems:
	return items if side == 0 else sides[side].items


## Поправки и артефакты — РАЗНЫЕ источники одного ключа, сводятся тем же правилом, что и всё
## остальное (MetaMods.combine, E-1005): ключ-множитель перемножается, прибавочный складывается.
## Раньше сумма в одном числе давала взаимное гашение («Опасное напряжение» −0,5 с «Скрепкой» +0,5
## в q_stun превращались в ровно базовое оглушение — артефакт молчал).
func item_add(key: StringName, side := 0) -> float:
	var owned := items_of(side)
	var artifact := 0.0 if owned == null else owned.value(key)
	return MetaMods.combine(key, [mod_add(String(key)), artifact])


## Числа предметов, которые мир держит в полях (реген и цена линии), — пересчёт при каждом
## новом предмете и на старте карты (предмет приходит посреди боя, поле уже настроено).
func apply_items() -> void:
	for s in sides:
		var field := s.contracts
		if field == null:
			continue
		configure_contract_mana(field)
		var cost := field.base_cost_mult * maxf(CfgItems.LINE_COST_MIN_MULT,
			item_mult(&"line_cost", s.index))
		field.mana_cost_mult = cost
		for c in field.contracts:
			c.mana_cost_mult = cost


## Глубина зоны «Точно!» (доля дальности натиска) с «Линейкой точности».
func perfect_zone_frac(side := 0) -> float:
	return minf(LegionCfg.PERFECT_ZONE_FRAC * item_mult(&"perfect_zone", side),
		CfgItems.PERFECT_ZONE_MAX_FRAC)


## Откат «Сбора» с «Рупором завхоза».
func rally_cd_total(side := 0) -> float:
	return LegionCfg.RALLY_CD * maxf(CfgItems.RALLY_CD_MIN_MULT, item_mult(&"rally_cd", side))


## D-0927-140: цена способности в мане (0–2 — Ку/Дубль-вэ/Е, LegionCfg.RALLY_SLOT — «Сбор»).
## A1: поправка ability_mana_mult («Копия верна») удорожает способности, но только в кампании/
## забеге — в «Схватке» цены прежние (там поправки забега не читаются).
func ability_mana(slot: int) -> float:
	if slot == LegionCfg.RALLY_SLOT:
		return LegionCfg.RALLY_MANA
	var base := PvpRules.ABILITY_MANA[slot] if pvp else LegionCfg.ABILITY_MANA[slot]
	if in_campaign:
		base *= camp_stat(&"ability_mana_mult")
	return base


## Хватает ли маны на способность (с запасом бота на линии; у человека запас 0).
## side — чья способность (PvP, P2b): мана — из поля договоров этой стороны, запас — её.
func can_pay_ability(slot: int, side := 0) -> bool:
	var s := _side_or_s0(side)
	return s.contracts != null \
		and s.contracts.mana >= ability_mana(slot) + s.ability_mana_reserve


func pay_ability(slot: int, side := 0) -> void:
	_side_or_s0(side).contracts.pay(ability_mana(slot))


## Сторона side; до _build (sides ещё пуст) и в одиночке — сторона 0 (её поле — contracts).
func _side_or_s0(side: int) -> PvpSide:
	return sides[side] if side > 0 and side < sides.size() else _s0


## v15: лимита армии больше нет — потолок это сумма штатов построек (не больше ARMY_HARD_CAP).
func effective_army_cap() -> int:
	return staff.total_cap()


## v15: ЕДИНСТВЕННЫЙ путь боя к параметрам кампании (Campaign.stat) — штат, герой, договоры,
## карточки видов читают только его. В кампании (in_campaign) — сохранение: открытия по порядку
## карт, поправки-карточки, подготовка «Конторы». Вне кампании всё открыто, прокачка нейтральна
## (множитель 1, бонус 0): серия и гейт не должны зависеть от сохранения владельца.
## Campaign кэширует сумму, поэтому звать можно и в кадре (панель способностей так и делает).
func camp_stat(key: StringName) -> float:
	if in_campaign:
		# подготовка «Конторы» (start_souls / mana_max_bonus) — отдельный источник сверх поправок;
		# сводится тем же правилом ключа, что и всё (MetaMods.combine внутри stat: множитель
		# умножается, прибавочный складывается).
		var prep := float(battle_preparation.get(String(key), 0.0))
		return Campaign.stat(key) if prep == 0.0 else Campaign.stat(key, [prep])
	if Campaign.is_mult_key(key) or String(key).contains("_unlocked_"):
		return 1.0
	return 0.0


## Поле владеет регеном и возвратом маны; мир задаёт эффективные параметры один раз.
func configure_contract_mana(field: ContractField) -> void:
	field.mana_max = LegionCfg.MANA_MAX + _bonus(&"mana_max_bonus")
	var base := PvpRules.MANA_REGEN if pvp else LegionCfg.MANA_REGEN
	field.mana_regen = (base + _bonus(&"mana_regen_bonus")) * item_mult(&"mana_regen",
		field.owner_side)


## Бонус, который бывает и поправкой к договору (mods), и покупкой «Конторы»: в кампании
## Campaign.stat уже суммирует оба источника (mods = те же active_mods), вне — только mods,
## которые тест выставил руками.
func _bonus(key: StringName) -> float:
	return camp_stat(key) if in_campaign else mod_add(String(key))


func _build() -> void:
	grid = LegionGrid.new().setup(self)
	items = LegionItems.new().setup(self)
	figures.setup(self)
	# v19: тени персонажей — под рунами и под всеми фигурами (CharShadows, чисто вид)
	contracts = ContractField.new()
	contracts.name = "Contracts"
	add_child(contracts)
	_s0.contracts = contracts
	_s0.staff = staff
	sides = [_s0]
	entities = Node2D.new()
	entities.name = "Entities"
	entities.y_sort_enabled = true
	# персонажи замирают на паузе, мир (ввод Esc/R) — нет
	entities.process_mode = Node.PROCESS_MODE_PAUSABLE
	add_child(entities)
	add_child(contracts.make_overlay())
	_fx = Node2D.new()
	_fx.name = "Fx"
	_fx.draw.connect(_draw_fx)
	add_child(_fx)
	ability_aim = LegionAbilityAim.new()
	ability_aim.setup(self)
	# тени и слой эффектов — сразу за Fx, до HUD: LegionFx.setup() подписывается на сигналы мира
	# в том же порядке, что на master (раньше HUD, звука и подсказок)
	_sync_gfx_layers()
	hud = LegionHud.new()
	add_child(hud)
	hud.setup(self)
	_build_ctl_widgets()
	# предметы: вспышки особых эффектов — в мире над фигурами, полоска и карточка — в HUD
	var item_fx := LegionItemFx.new()
	add_child(item_fx)
	move_child(item_fx, _fx.get_index() + 1)
	item_fx.setup(self)
	# постоянный вид артефактов (печати на бойцах, огоньки на крышах, пламя Котла, призрачные
	# линии) — над фигурами, под подсказками
	var item_look := LegionItemLook.new()
	add_child(item_look)
	move_child(item_look, item_fx.get_index() + 1)
	item_look.setup(self)
	# подсказки (slow/intuit) — поверх рун, персонажей, эффектов и вспышек предметов: совет,
	# закрытый искрами, бесполезен
	intuit = LegionIntuit.new()
	add_child(intuit)
	move_child(intuit, item_look.get_index() + 1)
	intuit.setup(self)
	# поправки-правила (A1): призрачные линии, эхо-разряды и вспышки — над полем, под подсказками
	# intuit и под HUD; подписки ставит start_map() (setup), узел живёт весь сеанс как и intuit.
	amendment_runtime = AmendmentRuntime.new()
	amendment_runtime.name = "AmendmentRuntime"
	add_child(amendment_runtime)
	move_child(amendment_runtime, intuit.get_index() + 1)
	var bar := LegionItemBar.new()
	bar.name = "ItemBar"
	hud.add_child(bar)
	bar.setup(self)
	plot_menu = PlotMenu.new()
	add_child(plot_menu)
	plot_menu.setup(self)
	# звук/сочность — пакет audio (PACKETS_V13.md); polish1: если LegionMain уже создала свой
	# узел для экранов кампании вне боя, переиспользуем его (один узел на сеанс), иначе — как
	# раньше, свой (гейт/бот/тесты встраивают legion_world.tscn напрямую, без LegionMain).
	if injected_audio != null:
		audio = injected_audio
		if audio.get_parent() != self:
			if audio.get_parent() != null:
				audio.get_parent().remove_child(audio)
			add_child(audio)
		audio.attach_world(self)
	else:
		audio = LegionAudio.new()
		add_child(audio)
		audio.setup(self)
	var hints := LegionMapHints.new()  # пакет tutorial: разовые подсказки карт 2-6
	add_child(hints)
	hints.setup(self)


## «Графика: экономная» (B-053/B-054) — создаёт/освобождает CharShadows и LegionFx по
## Settings.is_economy_graphics(); зовётся из _build() (первая сборка) и каждый кадр из
## _process() (тот же LegionWorld живёт весь сеанс — LegionMain создаёт его один раз, а не на
## каждый бой, verifier 26.09). Сравнение дешёвое — тяжёлая часть (создание/queue_free) только
## при реальной смене настройки.
##
## Место в дереве решает порядок отрисовки (у всех z_index 0) — и оно то же, что на master
## 2c36dc6: CharShadows сразу перед Contracts (под рунами, участками и рельефом — над ними),
## LegionFx сразу перед Fx (пыль и искры под предупреждениями печати/тарана/Юриста, снарядами
## и полоской HP Котла, которые рисует _draw_fx). Ставим «перед соседом», а не на число:
## verifier 26.09 поймал оба числовых варианта — `hud.get_index()` (HUD — CanvasLayer, это
## ставило слой ПОСЛЕ Fx) и индекс 0 (тени под рельефом и участками после смены посреди боя).
## Соседи-якоря живут весь сеанс (_build), а рельеф, участки и подсветку _build_ground()
## вставляет в начало — порядок «якорь и его сосед» от этого не меняется.
func _sync_gfx_layers() -> void:
	var want_shadows := not Settings.is_economy_graphics()
	var want_fx: bool = want_shadows and dev.get("fx", "1") != "0"  # --dev fx=0 — без FX и в полной
	if want_shadows == (_shadows_node != null) and want_fx == (_gfx_fx != null):
		return
	if want_shadows and _shadows_node == null:
		_shadows_node = CharShadows.new()
		_shadows_node.name = "CharShadows"
		_shadows_node.harmony = harmony
		add_child(_shadows_node)
		move_child(_shadows_node, contracts.get_index())
	elif not want_shadows and _shadows_node != null:
		_shadows_node.queue_free()
		_shadows_node = null
	if want_fx and _gfx_fx == null:
		_gfx_fx = LegionFx.new()
		add_child(_gfx_fx)
		move_child(_gfx_fx, _fx.get_index())
		_gfx_fx.setup(self)
		# Слой родился посреди уже идущего боя или на экране его итога (переключение из паузы,
		# не с _build()) — сигнал match_started он пропустил, фон и жизнь карты догоняем сами.
		# В меню — нет: вход в меню (menu_entered → clear_all) фоновую жизнь снимает, и
		# переключение там не должно её возвращать (verifier 26.09, пункт D).
		if not map.is_empty() and phase != Phase.MENU:
			_gfx_fx._on_match_started(map_id)
	elif not want_fx and _gfx_fx != null:
		_gfx_fx.queue_free()
		_gfx_fx = null


# ── Матч ────────────────────────────────────────────────────────────────────

func start_map(id: String, map_data: Dictionary = {}) -> void:
	if net_mode and not _net_starting:
		# обычный бой после сетевого матча: сид из --seed, интерфейс и ввод — стороны 0
		net_mode = false
		local_side = 0
		_base_seed = int(args.get("seed", 1))
	_clear()
	map_id = id
	difficulty = LegionChallenge.valid(String(dev.get("difficulty", Settings.difficulty())))
	if id.begins_with(PvpRules.MAP_PREFIX):
		difficulty = PvpRules.DIFFICULTY   # слабые волны «Схватки» — «Стажёр» (DESIGN §2.6)
	# The optional dictionary is a test/preview injection seam for frozen campaign candidates.
	# Deep-copy before applying difficulty: downstream systems may freely adjust their map copy.
	var source_map := map_data.duplicate(true) if not map_data.is_empty() else load_map(id)
	# B-230: поле «Схватки» узнаётся по сторонам, а не по имени — gen:N:K:pvp тоже «Стажёр»
	if (source_map.get("sides", []) as Array).size() > 1:
		difficulty = PvpRules.DIFFICULTY
		if dev.has("pvp_swap"):   # серия со сменой сторон: сторона 0 — на правой половине (P3)
			source_map = PvpMaps.swap_sides(source_map)
	map = LegionChallenge.apply_map(source_map, difficulty)
	if map.is_empty():
		push_error("LegionWorld: карта '%s' не найдена" % id)
		return
	rng.seed = _base_seed
	_pvp_flip = false
	world_size = LegionTerrain.map_size(map)
	visible = true   # go_to_menu прячет мир «Схватки» под экранами меню
	_apply_view()
	var cp: Array = map.get("cauldron", [180, 360])
	cauldron_pos = Vector2(float(cp[0]), float(cp[1]))
	var art: Array = map.get("cauldron_art", [0, 0])
	cauldron_view_pos = cauldron_pos + Vector2(float(art[0]), float(art[1]))
	# cauldron_insurance (mods): +HP к максимуму Котла ЭТОЙ карты, не к базовой константе.
	cauldron_hp = float(map.get("cauldron_hp", LegionCfg.CAULDRON_HP)) + mod_add("cauldron_hp_bonus")
	cauldron_max = cauldron_hp
	_setup_sides()
	terrain = LegionTerrain.new().setup(map)
	_build_ground()
	contracts.setup(self)
	for s in _others():
		s.contracts.setup(self)
	apply_items()
	_reset_ctl()
	stats = {
		"kills": 0, "lost": 0, "charges": 0, "refreshes": 0, "releases": 0,
		"releases_melt": 0, "releases_manual": 0, "lines": 0, "mana_spent": 0.0,
		"mana_abilities": 0.0, "cauldron_dmg": 0.0, "spawned": 0, "stamp_hits": 0, "signers_killed": 0,
		"kills_rewardable": 0, "buildings_built": 0,
		"breach_leaks": 0, "waves_called": 0, "call_bonus": 0,
		"has_breaches": not (map.get("breaches", []) as Array).is_empty(),
		"first_contact_t": -1.0, "no_dmg_s": 0.0,
		"press_breaks": 0, "spring_releases": 0,
	}
	_pace = {"peak_foes": 0, "peak_army": 0, "foe_s": 0.0, "army_s": 0.0, "t": 0.0}
	_build_cauldron()
	for s in _others():
		_build_side_cauldron(s)
	# v15 (пакет staff): Котёл — постройка подрядчиков со штатом start_army карты; стартовый штат
	# выдаётся целиком сразу. Поправки кампании (бывшие start_army_bonus/army_cap_bonus/
	# production_mult) приходят через Campaign.stat как cap_mult_/respawn_mult_laborer (пакет
	# meta). --dev spawn_units=N — точный штат Котла для замеров и тестов (без темпа); штат карты
	# — с темпом читаемости LegionCfg.STAFF_PACE (D-0927-49).
	var army := int(dev.get("spawn_units",
		LegionStaff.paced(int(map.get("start_army", LegionCfg.START_ARMY)))))
	staff.setup(self, map, army)
	for s in _others():
		s.staff.setup(self, map, army)
	for entry: Dictionary in map.get("crypts", []):
		var crypt := LegionCrypt.new()
		crypt.setup(self, Vector2(entry["pos"][0], entry["pos"][1]))
		entities.add_child(crypt)
		crypts.append(crypt)
	_spawn_dev_kinds(String(dev.get("spawn_kind", "")))
	_spawn_dev_foes(String(dev.get("hero_foe", "")))
	for s in map.get("sleepers", []):
		var at := Vector2(float(s["pos"][0]), float(s["pos"][1]))
		_add_foe("mimic", PackedVector2Array(), {"pos": at, "sleep": true})
	for i in int(dev.get("spawn_foes", 0)):
		_spawn_bench_foe(i)
	# артефакты забега (D-0927-163): кампания и «Бесконечный подряд» — из раздела забега
	# ТЕКУЩЕГО scope Campaign; одиночный бой (--map), бот, тест, переигровка вне забега — нет
	if carry_items and not pvp:
		items.load_run(Campaign.run_items())
	# --dev items=id,id — артефакты с начала боя (кадры приёмки, серии «с артефактами»)
	for item_id in String(dev.get("items", "")).split(",", false):
		items.grant(StringName(item_id))
	# поправки-правила (A1): после staff/hero/items — подписки уже видят итоговое поле, но враги
	# из этой карты спавнятся выше, поэтому «kill» на старте в них не считается; reset() внутри
	# снимает прошлую карту без двойных подписок. Helper сам уходит на standalone/PvP.
	amendment_runtime.setup(self)
	wave_runner = WaveRunner.new()
	wave_runner.setup(self, {} if dev.has("no_waves") else map)
	items.plan_battle(wave_runner.total())
	var bot_policy := String(args.get("bot", "off"))
	bot = null
	contracts.human_input = true
	for s in sides:
		s.ability_mana_reserve = 0.0
	if pvp:
		_setup_pvp_bots()
	elif bot_policy != "off":
		bot = LegionBot.new()
		bot.setup(self, StringName(bot_policy), map)
		contracts.human_input = false
		ability_mana_reserve = LegionCfg.BOT_MANA_RESERVE
	if not pvp:
		_s0.bot = bot
	pvp_match = PvpMatch.new() if pvp else null
	if pvp and pvp_menu == null:
		pvp_menu = PvpMenu.new()
		add_child(pvp_menu)
		pvp_menu.setup(self)
	if pvp_menu != null:
		pvp_menu.close()
	now = 0.0
	phase = Phase.BATTLE
	contracts.active = true
	for s in _others():
		s.contracts.active = true
	hud.hide_result()
	# tutfix (item 6): go_to_menu() прячет весь боевой HUD (hud.visible = false) — новый матч
	# должен вернуть его, иначе после захода в меню и обратно HUD остаётся невидимым.
	hud.visible = true
	queue_redraw()
	match_started.emit(map_id)
	# tutfix (item 1): на wasteland без пройденного обучения следом стартует LegionTutorial
	# (legion_main.gd/dev-путь) — его плашка (legion_tutorial.gd _Banner) перекрывает этот toast
	# первые ~2.5 с (кадр tutorial_overlap.png). Обучение само объясняет карту шаг за шагом —
	# вводный toast здесь лишний, а не источник истины; повторный проход wasteland (обучение уже
	# пройдено) получает toast как раньше. `dev.has("tutorial")` — тот же compat-путь ниже в
	# _ready(), что форсирует обучение поверх уже стоящего флага «пройдено» (приёмка/QA): без
	# этого условия toast не гасился бы на --dev tutorial=1 при уже пройденном обучении.
	var tutorial_about_to_start := id == LegionTutorial.WASTELAND_MAP_ID \
		and (not Campaign.tutorial_done() or dev.has("tutorial"))
	if not tutorial_about_to_start:
		var title := String(map.get("title", map_id))
		toast(title + (": " + String(map["hint"]) if map.has("hint") else ""), &"info")


# ── Стороны боя (docs/pvp/DESIGN.md §4) ─────────────────────────────────────

## Стороны по карте: поле `sides` ([{cauldron}] — Котлы по порядку) — «Схватка», иначе одна
## сторона. Сторона 0 — прежние поля мира; остальные получают своё поле договоров (узел-сосед
## поля стороны 0, тот же порядок отрисовки), свой штат и свой Котёл. Узлы полей переживают
## перезапуск карты PvP и снимаются, когда следующая карта — одиночная.
func _setup_sides() -> void:
	var defs: Array = map.get("sides", [])
	pvp = defs.size() > 1
	var n := clampi(defs.size(), 1, PvpRules.MAX_SIDES)
	while sides.size() > n:
		var gone: PvpSide = sides.pop_back()
		# queue_free снимает узел в конце кадра, а отложенная перерисовка успевает в этом же
		# кадре — и лезет в уже удалённую сторону (items_of, P7 B-342); скрытый узел не рисуется
		gone.contracts.hide()
		gone.contracts.queue_free()
		if gone.contracts.overlay != null:
			gone.contracts.overlay.hide()
			gone.contracts.overlay.queue_free()
	while sides.size() < n:
		var s := PvpSide.new(sides.size())
		s.contracts = ContractField.new()
		s.contracts.name = "Contracts%d" % s.index
		s.contracts.owner_side = s.index
		s.contracts.human_input = false
		add_child(s.contracts)
		move_child(s.contracts, contracts.get_index() + s.index)
		var ov := s.contracts.make_overlay()
		add_child(ov)
		move_child(ov, contracts.overlay.get_index() + s.index)
		sides.append(s)
	for s in sides:
		if s.index == 0:
			s.items = items
		elif s.items == null:
			s.items = LegionItems.new().setup(self, s.index)
		s.items.reset()
		s.surrendered = false
		s.leaked_waves.clear()
		s.cauldron_dmg = {"units": 0.0, "waves": 0.0}
		s.rally_cd = 0.0
		s.contracts.delay_enabled = not pvp
		if s.index == 0:
			continue
		s.staff = LegionStaff.new()
		s.staff.side = s.index
		var cp: Array = (defs[s.index] as Dictionary).get("cauldron", [0, 0])
		s.cauldron_pos = Vector2(float(cp[0]), float(cp[1]))
		s.cauldron_view_pos = s.cauldron_pos   # cauldron_art — сдвиг картинки стороны 0
		s.cauldron_hp = float(map.get("cauldron_hp", LegionCfg.CAULDRON_HP))
		s.cauldron_max = s.cauldron_hp
		# вид игрока стороны: отражение по x (двойка; 3–4 стороны — поворот сектора, L3/L4)
		s.view_xf = Transform2D(Vector2(-1, 0), Vector2(0, 1), Vector2(world_size.x, 0))


## Стороны, кроме стороны 0 (в одиночке — пусто: все циклы по ним ничего не делают).
func _others() -> Array[PvpSide]:
	return sides.slice(1) if sides.size() > 1 else [] as Array[PvpSide]


## Котёл, некромант и герой стороны ≥ 1 (у стороны 0 — _build_cauldron, как раньше).
func _build_side_cauldron(s: PvpSide) -> void:
	var spr := Sprite2D.new()
	spr.texture = TEX_CAULDRON
	var k := LegionCfg.CAULDRON_DRAW_H \
		/ (LegionCfg.CAULDRON_MASTER_PX * LegionCfg.CAULDRON_CONTENT_FRAC)
	spr.scale = Vector2(k, k)
	spr.position = s.cauldron_view_pos
	spr.offset = Vector2(0.0, -LegionCfg.CAULDRON_MASTER_PX * 0.25)
	spr.modulate = PvpRules.tint(s.index)
	entities.add_child(spr)
	s.cauldron_sprite = spr
	s.necro = CharView.new()
	entities.add_child(s.necro)
	s.necro.setup("necromancer", LegionCfg.NECRO_BODY_H)
	# некромант — с внешней стороны Котла (у стороны 1 зеркально)
	var off := LegionCfg.NECRO_OFFSET
	if s.cauldron_pos.x > world_size.x * 0.5:
		off.x = -off.x
	s.necro.position = s.cauldron_pos + off
	s.hero = LegionHero.new()
	s.hero.side = s.index
	add_child(s.hero)
	s.hero.setup(self, s.necro)


## Боты «Схватки»: --pvp-bots (или --bot) — все стороны; иначе сторона 0 — человек, остальные —
## PvpBot. --dev pvp_nobot=1 — ботов нет вовсе (тесты; сервер L3 решает сам).
func _setup_pvp_bots() -> void:
	if net_mode:   # сеть: люди с обеих сторон, ботов нет; мышь этого экрана — только своему полю
		for s in sides:
			s.bot = null
			s.contracts.human_input = s.index == local_side
		return
	var all := args.has("pvp_bots") or String(args.get("bot", "off")) != "off"
	for s in sides:
		s.bot = null
		s.contracts.human_input = s.index == 0
		if dev.has("pvp_nobot") or (s.index == 0 and not all):
			continue
		var b := PvpBot.new()
		b.setup(self, s.index)
		s.bot = b
		s.contracts.human_input = false
		s.ability_mana_reserve = LegionCfg.BOT_MANA_RESERVE   # как у бота одиночки


## Поле договоров, которому принадлежит договор c.
func field_of(c: Contract) -> ContractField:
	return sides[c.owner_side].contracts if c.owner_side < sides.size() else contracts


func hero_of(side: int) -> LegionHero:
	return sides[side].hero if side < sides.size() else hero


## Котёл стороны side (одиночка — всегда cauldron_pos).
func cauldron_of(side: int) -> Vector2:
	return sides[side].cauldron_pos if side < sides.size() else cauldron_pos


## «Оборона дома»: есть ли на этом шаге враждебная цель в зоне дома стороны side
## (Legionnaire._guard_home ищет цель сам, только когда флаг поднят).
func home_threat(side: int) -> bool:
	return side < _home_threat.size() and _home_threat[side] != 0


## Флаги «враг в зоне дома» по сторонам: один запрос сетки у каждого Котла за шаг вместо
## поиска радиусом HOME_GUARD_PURSUE у каждого свободного бойца.
func _scan_home_threats() -> void:
	_home_threat.resize(sides.size())
	for s in sides.size():
		_home_threat[s] = int(grid.hostile_in_zone(cauldron_of(s), LegionCfg.HOME_GUARD_R, s))


## Где нарисован Котёл стороны side (со сдвигом картинки cauldron_art у стороны 0 / одиночки):
## к нему летят души «Душеприказчика», под ним кольцо «Печати на Котле».
func cauldron_view_of(side: int) -> Vector2:
	return sides[side].cauldron_view_pos if side < sides.size() else cauldron_view_pos


## Чья половина у точки p: сторона ближайшего Котла (одиночка — 0 без счёта).
func side_at(p: Vector2) -> int:
	if sides.size() <= 1:
		return 0
	var best := 0
	for s in sides:
		if p.distance_squared_to(s.cauldron_pos) < p.distance_squared_to(sides[best].cauldron_pos):
			best = s.index
	return best


## B-365: сторона «Схватки» на правой половине поля — её «свои» смещения (рождение, подсолнух
## «Сбора») отражаются по x, чтобы зеркальная позиция давала зеркальный бой. Одиночка — false.
func side_mirrored(side: int) -> bool:
	return pvp and side >= 0 and side < sides.size() \
		and sides[side].cauldron_pos.x > world_size.x * 0.5


## Смещение v «для стороны side»: у стороны на правой половине — отражённое по x.
func side_dx(v: Vector2, side: int) -> Vector2:
	return Vector2(-v.x, v.y) if side_mirrored(side) else v


## Все договоры боя: в одиночке — прежний список поля (без копии и того же порядка).
func all_contracts() -> Array[Contract]:
	if sides.size() <= 1:
		return contracts.contracts
	var out: Array[Contract] = []
	for s in sides:
		out.append_array(s.contracts.contracts)
	return out


## API команд стороны (PvpCmd): единственная точка, где смысловой ввод стороны — штрих,
## стрелка, рогатка, щелчок, площадка, способность, «Сбор», сдача — становится действием мира.
## Бот PvP и сеть (L3) зовут только её. Ответ {ok, reason, …}.
func command(side: int, cmd: Dictionary) -> Dictionary:
	return PvpCmd.apply(self, side, cmd)


## Снимок боя для сетевого судьи (NetSnap): только простые Variant, снимать между шагами.
func snapshot() -> Dictionary:
	return NetSnap.save(self)


## Загрузить снимок судьи: дальше бой идёт побитово как у снявшего. Ответ — реестр загрузки
## (misses — неразрешённые ссылки, errors — несовместимость снимка и мира).
func load_snapshot(d: Dictionary) -> NetSnap.Reg:
	return NetSnap.load(self, d)


## «Касса» (D-1001-01; клавиша Дэ и кнопка HUD в одиночке, бот с --dev bot_kassa=1): порция
## душ в кассу. Отказ — тост с причиной, успех — тост с курсом и премией кассы.
func request_kassa() -> Dictionary:
	var res := kassa.deposit(self)
	if not bool(res.get("ok", false)):
		toast(LegionKassa.reason_text(String(res.get("reason", ""))), &"warn")
		return res
	toast("В кассу %d душ (курс %d:1) · премия +%d из %d" % [int(res["souls"]), int(res["rate"]),
		int(res["earned"]), LegionCfg.KASSA_CAP])
	return res


## Открыто меню «Схватки» по Esc (бой под ним идёт, паузы нет).
func pvp_menu_open() -> bool:
	return pvp_menu != null and pvp_menu.visible


## Сдача стороны (PvP): засчитывается сразу. false — не PvP или бой уже кончен.
func surrender(side: int) -> bool:
	if not pvp or phase != Phase.BATTLE or side < 0 or side >= sides.size():
		return false
	sides[side].surrendered = true
	_check_pvp_end()
	return true


## Конец матча по PvpMatch: итог — от лица стороны 0 (победа / поражение; ничья — поражение
## фазой, "draw" в итоге).
func _check_pvp_end() -> void:
	if pvp_match == null or phase != Phase.BATTLE:
		return
	var res := pvp_match.check(sides, now)
	if res.is_empty():
		return
	_end(int(res["winner"]) == local_side)


# ── Онлайн-«Схватка»: API мира для сетевой сессии (docs/pvp/NET_LOCKSTEP.md) ───────────

## Сетевой матч: как PvpFlow.start (без поправок кампании, «Конторы» и артефактов забега), сид
## боя — seed_value, ботов нет, мышь этого экрана — полю стороны side. Ключи --dev, меняющие бой,
## снимаются: у соперника их нет.
func start_net_match(map_id: String, seed_value: int, side: int) -> void:
	for k: Variant in dev.keys():
		if not NET_DEV_KEEP.has(String(k)):
			dev.erase(k)
	dev_invuln = false
	mods = {}
	in_campaign = false
	carry_items = false
	battle_preparation = {}   # сетевой матч — без поправок забега и подготовки «Конторы»
	net_mode = true
	local_side = side
	net_tick = 0
	net_applying = false
	_base_seed = seed_value
	_assign_t = 0.0   # часы вербовки переживают бой — у клиентов с разной историей они разные
	_net_starting = true
	start_map(map_id)
	_net_starting = false
	# номера договоров — с 1 у обоих клиентов, какая бы история ни была у мира (B-363; ветка
	# slow/small-1001 сбрасывает их в ContractField.setup — здесь страховка до её вливания)
	for s in sides:
		s.contracts._next_id = 1
	# камера не зеркалится: человек стороны 1 просто играет правой половиной поля
	toast("Вы — справа" if side == 1 else "Вы — слева", &"info")


## Сессии можно делать тик: бой идёт и фон карты догружен (у клиентов фон строится разное время).
func net_can_step() -> bool:
	return net_mode and phase == Phase.BATTLE and not _ground_loading


## Ровно один тик сетевого матча; конец матча проверяет сам _step (PvP — _check_pvp_end).
func net_step() -> void:
	if not net_can_step():
		return
	_step(NET_DT)
	net_tick += 1


## Применить команду стороны side на границе тика (до net_step этого тика). Черновик штриха и
## выбранный вид человека переживают команду своей стороны: поле исполняет её на чистом листе и
## возвращает жест руке. Повторно в net_out команда не уходит (net_applying).
func net_apply(side: int, cmd: Dictionary) -> Dictionary:
	if side < 0 or side >= sides.size():
		return {"ok": false, "reason": "side"}
	var field := sides[side].contracts
	var keep := field.net_stash()
	net_applying = true
	var res := command(side, cmd)
	net_applying = false
	field.net_restore(keep)
	return res


## Отпечаток состояния боя (сверяется у обоих клиентов раз в 60 тиков): сырые байты чисел, не
## строки. stats не входит — это счёт игрока стороны 0, не состояние боя.
func net_digest() -> String:
	var n := PackedInt64Array([rng.state, net_tick, units.size(), foes.size()])
	var f := PackedFloat64Array([now])
	for s in sides:
		n.append_array([s.index, s.souls, s.contracts.contracts.size()])
		f.append_array([s.cauldron_hp, s.contracts.mana, s.rally_cd])
		if s.hero != null:
			for slot in 3:
				f.append(s.hero.cd_left(slot))
		for c in s.contracts.contracts:
			n.append_array([c.id, ContractErase.live_count(c)])
			f.append_array([c.dir.x, c.dir.y])
	for u in units:
		n.append_array([u.side, LegionCfg.KIND_ORDER.find(u.kind), u.state, 1 if u.alive else 0])
		f.append_array([u.position.x, u.position.y, u.hp])
	for e in foes:
		n.append_array([e.type_id.hash(), e.state, 1 if e.alive else 0])
		f.append_array([e.position.x, e.position.y, e.hp])
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(n.to_byte_array())
	ctx.update(f.to_byte_array())
	return ctx.finish().hex_encode()


## Сторона человека за этим экраном (вне сети — сторона 0).
func my_side() -> PvpSide:
	return sides[local_side] if local_side < sides.size() else _s0


## Поле договоров человека за этим экраном (вне сети — contracts).
func my_field() -> ContractField:
	return my_side().contracts


## Герой человека за этим экраном (вне сети — hero).
func my_hero() -> LegionHero:
	return my_side().hero


## Действие человека за этим экраном: вне сети — сразу командой своей стороны; в сети — в net_out
## (мир не меняется, команда вернётся через net_apply у обоих клиентов).
func local_cmd(cmd: Dictionary) -> Dictionary:
	if not net_mode:
		return command(local_side, cmd)
	var out := cmd.duplicate()
	if out.get("at") is Vector2:   # курсор за краем поля (полосы окна) — команду мир бы отверг
		out["at"] = (out["at"] as Vector2).clamp(Vector2.ZERO,
			world_size - Vector2.ONE * PvpCmd.NET_EDGE)
	if net_out.is_valid():
		net_out.call(out)
	return {"ok": true, "reason": "", "sent": true}


func restart() -> void:
	set_paused(false)
	# tutfix (item 7): «Заново» на незачтённом обучении раньше запускало карту без него —
	# волны шли как в обычном бою, хотя обучение не считалось пройденным (находка ревью
	# 24.09.2026). start_map() ниже сам снесёт текущее обучение через _clear(), поэтому
	# флаг снимаем ДО вызова, а не после.
	var had_unfinished_tutorial := tutorial != null and tutorial.active
	var had_pending_ground_lessons := _pending_ground_lessons
	var pending_ground_lessons_force := _pending_ground_lessons_force
	start_map(map_id)
	if had_unfinished_tutorial:
		start_lessons(_lessons_force)
	elif had_pending_ground_lessons:
		start_lessons(pending_ground_lessons_force)


## Пакет flow: остановить мир и уйти в MENU, не переигрывая карту (LegionMain показывает своё
## меню поверх; мир просто перестаёт тикать — _step() идёт только в Phase.BATTLE). Снимает
## паузу дерева безусловно, иначе игра осталась бы замороженной после выхода через Esc-паузу.
func go_to_menu() -> void:
	set_paused(false)
	_depth_generation += 1
	_cancel_ground_loading()
	phase = Phase.MENU
	plot_menu.close()
	for s in sides:
		s.contracts.active = false
	if pvp_menu != null:
		pvp_menu.close()
	# tutfix (item 6): выход в меню посреди обучения раньше оставлял его плашку (CanvasLayer)
	# и боевой HUD поверх меню — обучение недооконченным не считается «пройденным» (как и на
	# restart/новую карту, см. _clear()), просто снимаем оснастку боя (находка ревью 24.09.2026).
	if tutorial != null:
		tutorial.teardown()
		tutorial = null
	if hud != null:
		hud.visible = false
	# вид «Схватки» (×0,8 вокруг центра поля 1600×900) сжимал бы и экраны меню (Control на
	# холсте 0), а застывшее поле торчало бы из-под них: возвращаем ×1 и прячем мир.
	# start_map включает мир и ставит вид по своей карте.
	view_xf = Transform2D.IDENTITY
	var cam := get_viewport().get_camera_2d() if is_inside_tree() else null
	if cam != null:
		cam.position = LegionCfg.WORLD_SIZE * 0.5
		cam.zoom = Vector2.ONE
	if pvp:
		visible = false
	_release_corpses()
	menu_entered.emit()


## B-049: пока идёт бой (и в паузе, и в hold), трупы врагов ведут часы мира (Foe.tick →
## set_corpse_age). Бой кончился — мир больше не шагает, и трупы дотаивают по своим часам под
## экраном итога или меню: отпускаем их одним вызовом (CharView.release_corpse_clock).
func _release_corpses() -> void:
	# убитые в последнем шаге ещё в foes (в _corpses их переносит следующий _cleanup)
	for f in foes:
		if f.view != null:
			f.view.release_corpse_clock()
	for c in _corpses:
		if c is Foe and (c as Foe).view != null:
			(c as Foe).view.release_corpse_clock()


## Пакет flow: принудительно завершить бой публичным API — для автотеста экранов итога/кампании
## (легитимнее подделки боя: реально считает финальную статистику через тот же путь _end()).
func force_end(victory: bool) -> void:
	_end(victory)


## «Сбор» (R) открыт: в кампании — с «Проходной» (D-0926-46), вне кампании всегда.
func rally_unlocked() -> bool:
	return camp_stat(&"control_unlocked_rally") > 0.5


## Пакет tutorial: запустить обучение «Пустыря» поверх уже идущего боя — все его уроки заново,
## даже пройденные (кнопка «Обучение», --dev tutorial=1). Не-op, если уроки уже идут.
func start_tutorial() -> void:
	start_lessons(true)


## Кампания v20: уроки карты (поле `lessons` её JSON, LegionTutorial) поверх уже идущего боя —
## ещё не пройденные (force — все). Зовёт LegionMain в кампании; вне её уроков нет, бой бота
## от них не зависит. Не-op, если уроки уже идут или учить нечему.
func start_lessons(force := false) -> void:
	if _ground_loading:
		_pending_ground_lessons = true
		_pending_ground_lessons_force = force
		_pending_ground_lessons_generation = _depth_generation
		return
	_start_lessons_now(force)


func _start_lessons_now(force: bool) -> void:
	if tutorial != null:
		return
	_lessons_force = force
	var list := LegionTutorial.pending(map_id, map, force)
	if list.is_empty():
		return
	# Обучение «Пустыря» — всегда «Стажёр»: первая встреча с механикой не должна идти под
	# «Адом», выбранным заранее (verifier 26.09). Волны раскладываются заново до того, как
	# уроки их придержат.
	if map_id == LegionTutorial.WASTELAND_MAP_ID and difficulty != LegionChallenge.INTERN:
		difficulty = LegionChallenge.INTERN
		map = LegionChallenge.apply_map(load_map(map_id), difficulty)
		wave_runner.setup(self, {} if dev.has("no_waves") else map)
	tutorial = LegionTutorial.new()
	tutorial.finished.connect(func() -> void: tutorial = null)
	tutorial.setup(self, list)


static func load_map(id: String) -> Dictionary:
	# карты «Схватки» — не в каталоге кампании (Campaign.maps() вставил бы их в кампанию)
	if id.begins_with(PvpRules.MAP_PREFIX):
		return PvpMaps.load_map(id)
	# процедурная карта «Бесконечного подряда»: gen:<сид>:<объект> (STAGE2 §2) — файла нет,
	# словарь собирает генератор (кэш по id — второй раз за бой не генерирует)
	if id.begins_with(ProcGen.ID_PREFIX):
		return PvpMaps.adapt_generated(ProcGen.map_from_id(id))
	var path := LegionCfg.MAPS_DIR + id + ".json"
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}


func _clear() -> void:
	_depth_generation += 1
	_cancel_ground_loading()
	if is_instance_valid(_depth_decor):
		_depth_decor.call("clear")
		_depth_decor.queue_free()
	_depth_decor = null
	# пакет tutorial: карту переигрывают (restart/новая карта) — обучение неоконченным не
	# считается «пройденным», просто снимает плашку и подписки
	if tutorial != null:
		tutorial.teardown()
		tutorial = null
	for crypt in crypts:
		crypt.queue_free()
	crypts.clear()
	for u in units:
		u.queue_free()
	for f in foes:
		f.queue_free()
	for c in _corpses:
		c.queue_free()
	units.clear()
	_pvp_hits.clear()
	foes.clear()
	_corpses.clear()
	_breach_marks.clear()
	_damage_hp.clear()
	_impacts.clear()
	_impact_r.clear()
	_tears.clear()
	_rallies.clear()
	rally_cd = 0.0
	rally_aiming = false
	if ability_aim != null:
		ability_aim.clear()
	projectiles.clear()
	items.reset()
	# поправки-правила (A1): снять подписки прошлой карты, пока герой/враги ещё в дереве или уже
	# удаляются — чтобы не висели на удалённых объектах до следующего setup().
	if amendment_runtime != null:
		amendment_runtime.reset()
	_pvp_item_stage = 0
	_pvp_carrier_serial = 0
	_pvp_carrier_hits.clear()
	figures.reset()
	souls = 0
	kassa.reset()
	for b: Object in buildings:
		# постройки склепов уходят вместе со своим склепом (они его дети, склеп мог уже уйти)
		if is_instance_valid(b) and (b as LegionBuilding).source != LegionBuilding.SOURCE_CRYPT:
			(b as LegionBuilding).queue_free()
	buildings.clear()
	if plot_menu != null:
		plot_menu.close()
	if _cauldron != null:
		_cauldron.queue_free()
		_cauldron = null
	if _necro != null:
		_necro.queue_free()
		_necro = null
	if hero != null:
		hero.queue_free()
		hero = null
	for i in range(1, sides.size()):
		var s := sides[i]
		for n: Node in [s.cauldron_sprite, s.necro, s.hero]:
			if n != null:
				n.queue_free()
		s.cauldron_sprite = null
		s.necro = null
		s.hero = null
		s.bot = null


## Земля карты — TerrainView пакета MAPS. Серая подложка (_draw_ground) осталась как
## отладочная: `--dev gray=1` показывает, как рельеф видит логика (клетки A* и полигоны).
func _build_ground() -> void:
	_depth_generation += 1
	var generation := _depth_generation
	harmony = null
	if is_instance_valid(_shadows_node):
		_shadows_node.harmony = null
	if is_instance_valid(_depth_decor):
		_depth_decor.call("clear")
		_depth_decor.queue_free()
	_depth_decor = null
	if _ground != null:
		_ground.queue_free()
		_ground = null
	if not dev.has("gray"):
		var tv := TerrainView.new()
		# Склеп теперь живой узел; декоративный дубль под ним не нужен.
		var ground_map := map.duplicate()
		ground_map["crypts"] = []
		# integrate1: участки рисует LegionPlotView (спрайт пустого участка, под постройкой —
		# ничего), процедурная метка TerrainView поверх спрайтов была бы второй отрисовкой.
		ground_map["plots"] = []
		# --dev pgart=1 (B-109): собрать даже кампанийную карту через PgArt из её геометрии,
		# игнорируя нарисованный bg — кадр сборки рядом со знакомой раскладкой для приёмки.
		var pgart := TerrainView.wants_pgart(ground_map, dev.has("pgart"))
		var depth_split := pgart and is_instance_valid(entities)
		var want_harmony := pgart and not dev.has("harmony_off")
		ground_map["contact"] = []
		if want_harmony:
			# участки и склепы из карты стёрты выше — точки контактной тени идут отдельным ключом
			ground_map["contact"] = PgArtHarmony.contact_points(map)
		tv.setup(ground_map, dev.has("pgart"), depth_split)
		if depth_split:
			tv.background_ready.connect(_on_depth_ground_ready.bind(tv, generation))
		if want_harmony:
			tv.background_ready.connect(_on_harmony_ground_ready.bind(tv, generation))
		_ground = tv
		if tv.background_build_pending():
			_begin_ground_loading(tv, generation)
		add_child(tv)
		move_child(tv, 0)
	if _plot_view == null:
		_plot_view = LegionPlotView.new()
		add_child(_plot_view)
		_plot_view.setup(self)
	move_child(_plot_view, 1 if _ground != null else 0)
	_plot_view.queue_redraw()
	# рельеф новой карты — новая подсветка; старая уходит вместе с прежним рельефом
	if obstacle_hint != null:
		obstacle_hint.queue_free()
	obstacle_hint = ObstacleHint.new()
	obstacle_hint.name = "ObstacleHint"
	add_child(obstacle_hint)
	move_child(obstacle_hint, _plot_view.get_index() + 1)
	obstacle_hint.setup(self)


func _on_harmony_ground_ready(texture: Texture2D, source: TerrainView, generation: int) -> void:
	if generation != _depth_generation or source != _ground:
		return
	var h := PgArtHarmony.new()
	if h.setup(texture, map):
		harmony = h
		apply_harmony()


## Тонировка спрайтов построек, склепов и Котла и цвет теней бойцов — по земле рядом. Цвет Котла
## «Схватки» несёт сторону (PvpRules.tint) — его не трогаем; бойцам и врагам красится только тень.
func apply_harmony() -> void:
	if harmony == null:
		return
	if _cauldron != null and not pvp:
		_cauldron.modulate = harmony.tone(cauldron_view_pos)
	for crypt in crypts:
		crypt.set_tone(harmony.tone(crypt.position))
	for b: LegionBuilding in buildings:
		if is_instance_valid(b) and b.source == LegionBuilding.SOURCE_PLOT:
			b.set_tone(harmony.tone(b.position))
	if _shadows_node != null:
		_shadows_node.harmony = harmony


## Вертикальные предметы появляются только вместе с успешной текстурой PgArt: при ошибке GPU
## TerrainView остаётся на обычной геометрической подложке и не теряет декор. Generation+owner
## защищают restart и поздний ready старой карты от утечки в новое поле.
func _on_depth_ground_ready(_texture: Texture2D, source: TerrainView, generation: int) -> void:
	if generation != _depth_generation or source != _ground or not is_instance_valid(entities):
		return
	if is_instance_valid(_depth_decor):
		_depth_decor.queue_free()
	var depth_script := load("res://scripts/legion/procgen/pg_art_depth.gd") as GDScript
	if depth_script == null:
		return
	_depth_decor = depth_script.new() as Node
	_depth_decor.name = "ProcgenDepth"
	add_child(_depth_decor)
	_depth_decor.call("setup", self, map, source.depth_entries(), entities)


func _begin_ground_loading(source: TerrainView, generation: int) -> void:
	_ground_loading = true
	_show_ground_loading()
	source.background_build_finished.connect(
		_on_ground_build_finished.bind(source, generation), CONNECT_ONE_SHOT
	)
	_wait_for_ground_build_timeout(source, generation)


func _on_ground_build_finished(success: bool, source: TerrainView, generation: int) -> void:
	if not _is_current_ground_build(source, generation):
		return
	_ground_loading = false
	_hide_ground_loading()
	if not success:
		print("PgArt background failed; continuing on procedural fallback")
	_start_pending_ground_lessons(generation)


func _start_pending_ground_lessons(generation: int) -> void:
	if not _pending_ground_lessons:
		return
	var force := _pending_ground_lessons_force
	var pending_generation := _pending_ground_lessons_generation
	_pending_ground_lessons = false
	_pending_ground_lessons_force = false
	_pending_ground_lessons_generation = -1
	if (
		pending_generation == generation
		and generation == _depth_generation
		and phase == Phase.BATTLE
		and not _ground_loading
	):
		_start_lessons_now(force)


func _wait_for_ground_build_timeout(source: TerrainView, generation: int) -> void:
	await get_tree().create_timer(GROUND_LOAD_TIMEOUT_SEC, true, false, true).timeout
	if generation != _depth_generation or not is_instance_valid(source):
		return
	if not _is_current_ground_build(source, generation):
		return
	_on_ground_build_timeout(source, generation)


func _on_ground_build_timeout(source: TerrainView, generation: int) -> void:
	if not _is_current_ground_build(source, generation):
		return
	push_warning("PgArt background timed out; continuing on procedural fallback")
	source.cancel_background_build()
	_on_ground_build_finished(false, source, generation)


func _is_current_ground_build(source: TerrainView, generation: int) -> bool:
	return (
		generation == _depth_generation
		and is_instance_valid(source)
		and source == _ground
		and _ground_loading
	)


func _cancel_ground_loading() -> void:
	if _ground_loading and is_instance_valid(_ground):
		(_ground as TerrainView).cancel_background_build()
	_ground_loading = false
	_hide_ground_loading()
	_pending_ground_lessons = false
	_pending_ground_lessons_force = false
	_pending_ground_lessons_generation = -1


func _show_ground_loading() -> void:
	if is_instance_valid(_ground_loading_layer):
		_ground_loading_layer.visible = not paused
		return
	_ground_loading_layer = CanvasLayer.new()
	_ground_loading_layer.name = "GroundLoading"
	_ground_loading_layer.layer = 8
	_ground_loading_layer.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(_ground_loading_layer)
	var blocker := Control.new()
	blocker.name = "InputBlocker"
	blocker.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	blocker.mouse_filter = Control.MOUSE_FILTER_STOP
	blocker.process_mode = Node.PROCESS_MODE_ALWAYS
	_ground_loading_layer.add_child(blocker)
	var shade := ColorRect.new()
	shade.color = Color(0.015, 0.012, 0.025, 0.2)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	blocker.add_child(shade)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	blocker.add_child(center)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(420.0, 72.0)
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.045, 0.035, 0.06, 0.96)
	panel_style.border_color = Color(LegionUi.GOLD, 0.7)
	panel_style.set_border_width_all(2)
	panel_style.set_corner_radius_all(8)
	panel.add_theme_stylebox_override("panel", panel_style)
	center.add_child(panel)
	var label := LegionUi.label("Готовим карту…", 28, LegionUi.FONT_TITLE, LegionUi.TEXT)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.add_child(label)
	_ground_loading_layer.visible = not paused


func _hide_ground_loading() -> void:
	if is_instance_valid(_ground_loading_layer):
		_ground_loading_layer.queue_free()
	_ground_loading_layer = null


func is_ground_loading() -> bool:
	return _ground_loading


func _battle_simulation_enabled() -> bool:
	return phase == Phase.BATTLE and not paused and not hold and not _ground_loading


func _blocks_ground_gameplay_input(event: InputEvent) -> bool:
	return _ground_loading and not event.is_action_pressed(&"pause")


## LegionFx._load_ground (B-107): цвет пыли для процедурной карты — из собранной PgArt
## текстуры TerrainView, не из файла (у процедурной карты map.bg пуст).
func ground_view() -> TerrainView:
	return _ground


func _build_cauldron() -> void:
	_cauldron = Sprite2D.new()
	_cauldron.texture = TEX_CAULDRON
	var content := LegionCfg.CAULDRON_MASTER_PX * LegionCfg.CAULDRON_CONTENT_FRAC
	var s := LegionCfg.CAULDRON_DRAW_H / content
	_cauldron.scale = Vector2(s, s)
	_cauldron.position = cauldron_view_pos
	# спрайт центрирован, а y-sort сортирует по position: сдвигаем картинку вверх на полкотла,
	# чтобы «земля» котла совпала с его точкой и бойцы за котлом рисовались позади
	_cauldron.offset = Vector2(0.0, -LegionCfg.CAULDRON_MASTER_PX * 0.25)
	entities.add_child(_cauldron)
	_necro = CharView.new()
	entities.add_child(_necro)
	_necro.setup("necromancer", LegionCfg.NECRO_BODY_H)
	# с внешней стороны Котла: со сменой сторон (pvp_swap) сторона 0 справа — зеркально, как у
	# стороны 1 в _build_side_cauldron (B-365: молния Ку бьёт от некроманта)
	var off := LegionCfg.NECRO_OFFSET
	if pvp and cauldron_pos.x > world_size.x * 0.5:
		off.x = -off.x
	_necro.position = cauldron_pos + off
	if hero != null:
		hero.queue_free()
	hero = LegionHero.new()
	add_child(hero)
	hero.setup(self, _necro)
	_s0.hero = hero


func _near_cauldron() -> Vector2:
	for attempt in 12:
		var p := cauldron_pos + Vector2.from_angle(rng.randf() * TAU) * rng.randf_range(40.0, 110.0)
		if terrain.walkable(p):
			return p
	return cauldron_pos + Vector2(40.0, 0.0)


# ── Кадр ────────────────────────────────────────────────────────────────────

func _process(delta: float) -> void:
	_frames += 1
	var t0 := Time.get_ticks_usec()
	# verifier 26.09: LegionMain создаёт LegionWorld один раз на сессию (не на бой) — «со
	# следующего боя» без пересинхронизации здесь было неправдой, тот же мир возвращался в
	# меню и в новый бой со старыми узлами. Проверка каждый кадр дешёвая (два сравнения),
	# зато переключение из паузы или меню применяется сразу же, а не только на start_map().
	_sync_gfx_layers()
	if _battle_simulation_enabled():
		# v17: Отсрочка (натяжка рогатки) — масштаб dt мира, НЕ Engine.time_scale: меню, звук и
		# интерфейс идут в реальном времени. Hit-stop удара натиска — пропуск шага мира на
		# CHARGE_HITSTOP реальных секунд (симуляция просто стоит, числа боя не меняются).
		var scale := contracts.real_tick(delta)
		for i in range(1, sides.size()):
			sides[i].contracts.real_tick(delta)
		if not net_mode:   # сетевой матч шагает сессия (net_step), а не кадр
			_hitstop_gap -= delta
			if _hitstop_left > 0.0:
				_hitstop_left -= delta
			else:
				_step(delta * scale)
	# подписи «что сделал навык» гаснут в реальном времени, но замирают на паузе вместе с боем
	if ability_aim != null and not paused:
		ability_aim.tick(delta)
	if not no_view:
		_fx.queue_redraw()
		hud.tick(delta)
	if _bench_s > 0.0:
		_bench_tick(delta, Time.get_ticks_usec() - t0)
	if _shot_path != "" and _frames >= _shot_frame and _shot_due():
		_take_shot()


func _step(dt: float) -> void:
	now += dt
	staff.tick(dt)
	for i in range(1, sides.size()):
		sides[i].staff.tick(dt)
	for s in sides:
		s.items.tick(dt)
	_tick_breach_marks(dt)
	wave_runner.tick(dt)
	if pvp:
		_tick_pvp_carriers()
	if tutorial != null:
		tutorial.tick(dt)
	# поправки-правила (A1): раньше hero.tick — эхо-разряд должен сработать до хода героя в этом
	# же шаге (а не отстать на кадр); helper без подписок (standalone/PvP) возвращается сразу.
	if amendment_runtime != null:
		amendment_runtime.tick(dt)
	if hero != null:
		hero.tick(dt)
		if dev.has("hero_cast"):
			_try_dev_hero_cast()
	for i in range(1, sides.size()):
		if sides[i].hero != null:
			sides[i].hero.tick(dt)
	# сетку — до бота: бот спрашивает её о давлении пехоты, а прошлокадровые индексы уже
	# указывают мимо массива после уборки мёртвых
	grid.rebuild()
	if bot != null:
		bot.tick(dt)
	# PvP: кто ходит в шаге позже, видит ход другого в том же шаге (боец замечает вошедшего в
	# досягаемость и бьёт первым, бот отвечает на свежий штрих) — порядок сторон и бойцов
	# чередуется через шаг (B-296: без этого в зеркальных поединках первой била всегда сторона 1,
	# 18 : 0, а в серии бот-бот сторона 1 брала 111 из 195 решённых матчей)
	var flip := pvp and _pvp_flip
	_pvp_flip = not _pvp_flip
	if pvp:
		for k in sides.size():
			var s := sides[sides.size() - 1 - k] if flip else sides[k]
			if s.bot is PvpBot:
				(s.bot as PvpBot).tick(dt)
	contracts.tick(dt, now)
	for i in range(1, sides.size()):
		sides[i].contracts.tick(dt, now)
	_assign_t -= dt
	if _assign_t <= 0.0:
		_assign_t = LegionCfg.ASSIGN_INTERVAL
		_assign_free()
		for i in range(1, sides.size()):
			_assign_free(sides[i].contracts)
	var n := foes.size()
	for i in n:
		foes[i].tick(dt)
	_tick_press(dt)
	# после хода врагов (они уже сделали шаг к Котлу) и до хода бойцов, которые флаг читают
	_scan_home_threats()
	if flip:
		for i in range(units.size() - 1, -1, -1):
			units[i].tick(dt)
	else:
		for u in units:
			u.tick(dt)
	if not _pvp_hits.is_empty():
		_flush_pvp_hits()
	# после бойцов: «Сверхурочные» и усиление обряда
	figures.tick(dt)
	grid.separate()
	projectiles.tick(dt)
	if pvp:
		_flush_carrier_hits()
	for crypt in crypts:
		crypt.tick(dt)
	_track_damage(_damage_hp, dt)
	_cleanup(dt)
	_track_pace(dt)
	_tick_impacts(dt)
	if combo > 0 and now - _combo_hit_t > LegionCfg.COMBO_WINDOW:
		_set_combo(0)
	if args.has("trace"):
		_trace_t -= dt
		if _trace_t <= 0.0:
			_trace_t = LegionCfg.TRACE_PERIOD
			print_trace()
	if pvp:
		_check_pvp_end()
	elif cauldron_hp <= 0.0 and phase == Phase.BATTLE:
		_end(false)


func _input(event: InputEvent) -> void:
	var m := event as InputEventMouse
	if m != null:
		_mouse_pos = m.position
		_mouse_seen = true
	# Remapped Tab/Enter/arrows must reach battle actions before GUI navigation.
	# Modal screens own these keys while paused or in the PvP menu.
	if event is InputEventKey and phase == Phase.BATTLE and not paused \
			and not is_ground_loading() and not pvp_menu_open():
		for ui_action: StringName in [&"ui_accept", &"ui_focus_next", &"ui_focus_prev",
				&"ui_up", &"ui_down", &"ui_left", &"ui_right"]:
			if event.is_action(ui_action):
				my_field()._unhandled_input(event)
				if not get_viewport().is_input_handled():
					_unhandled_input(event)
				break


## Точка прицела способностей В МИРЕ: последняя позиция мыши из события (см. _mouse_pos),
## переведённая видом поля. Без событий — курсор ОС (get_global_mouse_position уже в мире).
func aim_pos() -> Vector2:
	return screen_to_world(_mouse_pos) if _mouse_seen else get_global_mouse_position()


## Мышь в экранных координатах (интерфейс: панели, слоты, CanvasLayer).
func mouse_screen() -> Vector2:
	return _mouse_pos if _mouse_seen else get_viewport().get_mouse_position()


# ── Вид поля (P5a): одна трансформация экран ↔ мир ─────────────────────────

## Панели HUD, закрывающие арену (LegionHud.panel_rects), в мировых координатах: подписи у
## мировых объектов меряют «есть ли место» этими прямоугольниками, а не полосой 64 px сверху
## (B-390 (1): под правой панелью «Вызвать» полоса не доставала).
func hud_world_rects() -> Array[Rect2]:
	var out: Array[Rect2] = []
	if hud == null or not hud.is_inside_tree():
		return out
	for r in hud.panel_rects():
		var a := screen_to_world(r.position)
		out.append(Rect2(a, screen_to_world(r.end) - a))
	return out


## Занятое площадками под постройку место (мировые координаты, как рисует LegionPlotView): подписи
## склепов не ложатся на площадки (B-390 (4)).
func plot_rects() -> Array[Rect2]:
	var out: Array[Rect2] = []
	var tex := LegionBuilding.sprite("plot_empty")
	for plot: Dictionary in staff.plots:
		var rect := Rect2(-Vector2.ONE * LegionCfg.PLOT_SPRITE_W * 0.5,
			Vector2.ONE * LegionCfg.PLOT_SPRITE_W)
		if tex != null:
			rect = LegionBuilding.sprite_rect(tex, LegionCfg.PLOT_SPRITE_W,
				LegionCfg.PLOT_SPRITE_ANCHOR_Y)
		rect.position += plot["pos"] as Vector2
		out.append(rect)
	return out


## Экранная точка вьюпорта (позиция InputEventMouse) → точка мира. Одиночка — та же точка.
func screen_to_world(p: Vector2) -> Vector2:
	return view_xf.affine_inverse() * p


## Точка мира → экран вьюпорта (якоря интерфейса у мировых объектов).
func world_to_screen(p: Vector2) -> Vector2:
	return view_xf * p


## Сколько экранных px в пикселе мира (без растяжения окна): одиночка 1, «Дуэль» 0,8.
func view_scale() -> float:
	return view_xf.x.x


## Видимая часть мира (для подписей «не уходить за край экрана»): одиночка — 1280×720.
func view_rect() -> Rect2:
	return Rect2(screen_to_world(Vector2.ZERO), LegionCfg.WORLD_SIZE / view_scale())


## Вписать поле в экран: view_xf и камера. Одиночка (поле = экран) — тождество, камеру не
## заводим (её ставит LegionAudio ради тряски, в той же точке и ×1); LegionMain держит мир один
## на сеанс — после «Схватки» одиночка возвращает камеру к ×1.
func _apply_view() -> void:
	var s := minf(LegionCfg.WORLD_SIZE.x / world_size.x, LegionCfg.WORLD_SIZE.y / world_size.y)
	if world_size == LegionCfg.WORLD_SIZE:
		view_xf = Transform2D.IDENTITY
	else:
		view_xf = Transform2D(0.0, Vector2(s, s), 0.0,
			LegionCfg.WORLD_SIZE * 0.5 - world_size * 0.5 * s)
	var cam := get_viewport().get_camera_2d() if is_inside_tree() else null
	if cam == null and view_xf != Transform2D.IDENTITY and is_inside_tree():
		cam = Camera2D.new()
		cam.name = "LegionViewCam"
		cam.enabled = true
		add_child(cam)
	if cam != null:
		# центр камеры — центр поля (DRAG_CENTER): canvas transform = view_xf
		cam.position = world_size * 0.5
		cam.zoom = Vector2(view_scale(), view_scale())


# gdlint: disable=max-returns
func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"mute"):
		Settings.set_muted(not Settings.is_muted())
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed(&"pause"):
		# clarity: Esc посреди прицела Ку/Дубль-вэ/Е — «передумал», как отмена черновика
		if ability_aim.is_aiming() and phase == Phase.BATTLE:
			ability_aim.cancel()
		elif my_field().has_draft():
			my_field().cancel()
		elif pvp and phase == Phase.BATTLE:
			pvp_menu.toggle()   # паузы нет: мир общий, бой идёт под меню (DESIGN §2.1)
		elif phase == Phase.BATTLE:
			set_paused(not paused)
		get_viewport().set_input_as_handled()
		return
	if _blocks_ground_gameplay_input(event):
		get_viewport().set_input_as_handled()
		return
	# B-361: меню Esc «Схватки» — то же, что пауза одиночки (паузы там нет, бой идёт под меню):
	# боевые клавиши под ним не срабатывают — ни Ку/Дубль-вэ/Е, ни Эр, ни F
	if pvp_menu_open() and event is InputEventKey and (event as InputEventKey).pressed:
		return
	if event is InputEventKey:
		var k := event as InputEventKey
		# v18: F — вызвать волну (левая рука не уходит с Q W E R); N — как раньше
		if event.is_action_pressed(&"call_wave"):
			if call_wave() >= 0:
				get_viewport().set_input_as_handled()
			return
		# одиночка: Дэ — «Касса» (D-1001-01), сток душ; в «Схватке» Дэ ничего не делает
		if not pvp and event.is_action_pressed(&"kassa") \
				and phase == Phase.BATTLE and not paused:
			request_kassa()
			get_viewport().set_input_as_handled()
			return
		# v18: R — «Сбор» по курсору. Прежний перезапуск боя по R (рядом с Е: промах стирал
		# партию) убран — «Заново» есть в паузе.
		# v19 (B-038): R зажата — круг «Сбора» и отметки, кого позовёт; отпустил — «Сбор».
		# Быстрое нажатие работает, как раньше: нажал-отпустил — побежали.
		if event.is_action(&"rally") and not k.echo and rally_unlocked():
			if k.pressed and phase == Phase.BATTLE and not paused:
				rally_aiming = true
				ability_aim.cancel()   # прицел один: «Сбор» перебивает Ку/Дубль-вэ/Е
				get_viewport().set_input_as_handled()
				return
			if not k.pressed and rally_aiming:
				rally_aiming = false
				if phase == Phase.BATTLE and not paused and net_mode:
					local_cmd(PvpCmd.rally(aim_pos()))
				elif phase == Phase.BATTLE and not paused:
					rally(aim_pos())
				get_viewport().set_input_as_handled()
				return
	# clarity (26.09, Игорь: «чтобы понятнее было, что обилки делают»): Q/W/E как R — зажата —
	# прицел с целями и подписью, отпущена — каст в точку отпускания. Быстрое нажатие кастует,
	# как раньше. Другая клавиша способности посреди прицела переключает его без каста.
	if phase == Phase.BATTLE and not paused and my_hero() != null:
		for pair in [[&"cast_q", LegionHero.SLOT_Q], [&"cast_w", LegionHero.SLOT_W],
				[&"cast_e", LegionHero.SLOT_E]]:
			if event.is_action_pressed(pair[0]):   # автоповтор зажатой клавиши сюда не проходит
				rally_aiming = false
				ability_aim.start(pair[1])
				get_viewport().set_input_as_handled()
				return
			if event.is_action_released(pair[0]) and ability_aim.slot == pair[1]:
				ability_aim.release(pair[1], aim_pos())
				get_viewport().set_input_as_handled()
				return

# gdlint: enable=max-returns


func set_paused(p: bool) -> void:
	paused = p
	if is_instance_valid(_ground_loading_layer):
		_ground_loading_layer.visible = _ground_loading and not p
	if p:
		cancel_human_gestures()
	get_tree().paused = p
	paused_changed.emit(p)


## Меню Esc «Схватки» открылось (паузы в PvP нет): отменить всё боевое действие, начатое человеком
## до него, — как set_paused(true) в одиночке (B-370, B-371). Поле — человека за этим экраном
## (my_field: в сети за правую сторону это не `contracts`), чужое не трогаем. Отмена локальна;
## единственное, что может уйти в сеть, — уже придержанный AIM при снятии прицела Пробела (штатный
## путь contract_field.set_aiming, безопасный для lockstep). Новых команд (Сбор, каст, штрих)
## отпускание под меню уже не родит.
func cancel_human_gestures() -> void:
	rally_aiming = false
	if ability_aim != null:
		ability_aim.cancel()
	var f := my_field()
	if f != null:
		f.cancel_gestures()


func is_paused() -> bool:
	return paused


# ── Сущности ────────────────────────────────────────────────────────────────

## Единая точка рождения бойца (DESIGN_V15 §11): Котёл, склепы, постройки, тесты — все сюда.
## Неизвестный вид — подрядчик. home — постройка-хозяин (null — Котёл/без хозяина).
## side — сторона бойца (PvP); −1 — сторона постройки-хозяина, без хозяина — 0.
func spawn_unit(kind: StringName, pos: Vector2, home: Object = null, side := -1) -> Legionnaire:
	var u := Legionnaire.new()
	u.setup(self, pos, kind)
	u.home = home
	if no_view:
		_mute_view(u.view)
	if side < 0:
		side = (home as LegionBuilding).side if home is LegionBuilding else 0
	if side != 0:
		u.side = side
		u.field = sides[side].contracts
	if pvp:
		# цвет стороны — материал (PvpSideLook), а не modulate: modulate красит Е и предметы,
		# а прежний розоватый tint стороны 1 ещё и сдвигал бы оттенок каски (B-346)
		PvpSideLook.apply(u.view, side)
	entities.add_child(u)
	units.append(u)
	stats["spawned"] = int(stats["spawned"]) + 1
	unit_spawned.emit(u)
	return u


func spawn_foe(type: String, road_id: String, opts := {}) -> Foe:
	var path := road_path(road_id)
	if path.is_empty():
		push_warning("LegionWorld: дорога '%s' не найдена" % road_id)
		return null
	return _add_foe(type, path, opts)


## Свита босса и прочие появления посреди дороги: путь уже обрезан до остатка.
## summoned — призванный враг (свита Прораба): душ, опыта и премии не даёт (§12 п.4).
func spawn_foe_on_path(type: String, path: PackedVector2Array, at: Vector2,
		summoned := false, origin: Dictionary = {}) -> Foe:
	var f := _add_foe(type, path, {"pos": at, "origin": origin})
	if f != null and summoned:
		f.set_meta(&"summoned", true)
	elif f != null and int(origin.get("wave", 0)) > 0:
		# враг волны (не свита, не обучение, не расставленные тестом): сначала сила уровня
		# сложности (LegionChallenge — одна точка), потом бросок на элитного (×3 поверх уровня;
		# поле волны «elite» — гарантированный элитный для урока, slow/map-archive);
		# учёт урона — с итоговым HP
		LegionChallenge.toughen(f, difficulty)
		if not pvp:   # предметы — пока вещь одиночки (в PvP их получил бы только игрок стороны 0)
			items.roll_elite(f, bool(origin.get("elite", false)))
		_damage_hp[f] = f.hp
	# Отметка «Закрыл трещину» на итоге нуждается в факте, что трещина вообще открывалась:
	# verifier 25.09 получил отметку на поражении в нулевой волне.
	if f != null and String(origin.get("breach", "")) != "":
		stats["breach_spawned"] = int(stats.get("breach_spawned", 0)) + 1
	return f


## План PvP не использует бюджет/частоту кампании. Носители — нейтральные враги,
## награда принадлежит фактическому убийце, а не стороне, чей Котёл выбран целью.
func _tick_pvp_carriers() -> void:
	if dev.has("no_waves"):
		return
	if _pvp_item_stage == 0 and now >= PvpRules.ITEM_HOME_AT:
		_pvp_item_stage = 1
		for s in sides:
			_spawn_pvp_carrier(s.index, false)
	if _pvp_item_stage == 1 and now >= PvpRules.ITEM_CONTESTED_AT:
		_pvp_item_stage = 2
		for s in sides:
			_spawn_pvp_carrier(s.index, true)


func _spawn_pvp_carrier(side: int, contested: bool) -> Foe:
	var cp := cauldron_of(side)
	var at := Vector2.INF
	if contested:
		var passages: Array = map.get("pvp", {}).get("passages", [])
		if not passages.is_empty():
			var span: Array = passages[0]
			var seam := float(map.get("pvp", {}).get("seam_x", world_size.x * 0.5))
			# со своей стороны стыка — по половине Котла, а не по номеру стороны: со сменой
			# сторон (pvp_swap) сторона 0 справа, и её носитель рождался у соперника (B-365)
			var dx := -PvpRules.ITEM_SEAM_OFFSET if cp.x < seam else PvpRules.ITEM_SEAM_OFFSET
			at = Vector2(seam + dx, (float(span[0]) + float(span[1])) * 0.5)
	else:
		for road: Dictionary in map.get("roads", []):
			var path := road_path(String(road.get("id", "")))
			if path.is_empty() or side_at(path[path.size() - 1]) != side:
				continue
			for p in path:
				if terrain.walkable(p) and terrain.connected(p, cp) \
						and p.distance_to(cp) >= PvpRules.ITEM_HOME_MIN_DISTANCE:
					at = p
					break
			if at != Vector2.INF:
				break
		# дорога стыка начинается на самой оси x = W/2: точка оси — ничья (клетка у неё одна, и
		# путь к левому Котлу шёл из правой клетки, к правому — из неё же), носители сторон шли
		# разными первыми шагами (B-365) — полклетки к своему Котлу
		if at != Vector2.INF and absf(at.x - world_size.x * 0.5) < 0.5:
			at.x += signf(cp.x - at.x) * LegionCfg.CELL * 0.5
	if at == Vector2.INF or not terrain.walkable(at) or not terrain.connected(at, cp):
		stats["pvp_carrier_geometry_fail"] = int(stats.get("pvp_carrier_geometry_fail", 0)) + 1
		return null
	var route := terrain.find_path(at, cp)
	if route.is_empty():
		return null
	var f := _add_foe("zombie", route, {"pos": at,
		"origin": {"wave": 0, "pvp_carrier": true, "contested": contested}})
	if f != null:
		f.make_elite(true)
		f.set_meta(&"pvp_carrier_serial", _pvp_carrier_serial)
		_pvp_carrier_serial += 1
		stats["carriers"] = int(stats.get("carriers", 0)) + 1
		stats["elites"] = int(stats.get("elites", 0)) + 1
	return f


## Носитель получает суммарный урон тика один раз, независимо от обхода units.
## Точный tie определяется seed/номером носителя/тиком, а не приоритетом стороны 0.
func defer_carrier_hit(f: Foe, damage: float, from: Vector2) -> bool:
	if not pvp or not f.carrier or _resolving_carrier == f:
		return false
	if not _pvp_carrier_hits.has(f):
		_pvp_carrier_hits[f] = {"damage": 0.0, "sides": {}, "from": from}
	var batch: Dictionary = _pvp_carrier_hits[f]
	batch["damage"] = float(batch["damage"]) + maxf(0.0, damage)
	var credit: Dictionary = batch["sides"]
	if f.last_hit_side >= 0 and f.last_hit_side < sides.size():
		credit[f.last_hit_side] = float(credit.get(f.last_hit_side, 0.0)) + maxf(0.0, damage)
	return true


func note_carrier_q(f: Foe, side: int, damage: float, chain_index: int) -> void:
	if _pvp_carrier_hits.has(f):
		var batch: Dictionary = _pvp_carrier_hits[f]
		if not batch.has("q"):
			batch["q"] = {}
		batch["q"][side] = [damage, chain_index]


func _flush_carrier_hits() -> void:
	var queued := _pvp_carrier_hits
	_pvp_carrier_hits = {}
	for f: Foe in queued:
		if not is_instance_valid(f) or not f.alive:
			continue
		var batch: Dictionary = queued[f]
		var credit: Dictionary = batch["sides"]
		var best := -1.0
		var tied: Array[int] = []
		for side: int in credit:
			var amount := float(credit[side])
			if amount > best and not is_equal_approx(amount, best):
				best = amount
				tied.assign([side])
			elif is_equal_approx(amount, best):
				tied.append(side)
		tied.sort()
		f.last_hit_side = -1
		if not tied.is_empty():
			var key := "%d|%d|%d" % [_base_seed,
				int(f.get_meta(&"pvp_carrier_serial", 0)), roundi(now * 60.0)]
			f.last_hit_side = tied[posmod(hash(key), tied.size())]
		_resolving_carrier = f
		f.take_damage(float(batch["damage"]), batch["from"])
		_resolving_carrier = null
		var q: Dictionary = batch.get("q", {})
		if not f.alive and q.has(f.last_hit_side):
			items_of(f.last_hit_side).on_q_death(f, q[f.last_hit_side])
	if not _pvp_carrier_hits.is_empty():
		_flush_carrier_hits()


func _add_foe(type: String, path: PackedVector2Array, opts: Dictionary) -> Foe:
	if not LegionCfg.FOES.has(type):
		push_warning("LegionWorld: неизвестный враг '%s'" % type)
		return null
	var f := Foe.new()
	f.setup(self, type, path, opts)
	if no_view:
		_mute_view(f.view)
	entities.add_child(f)
	foes.append(f)
	_damage_hp[f] = f.hp
	return f


## PvP: удар бойца стороны side по чужому бойцу t — отложен до конца шага бойцов.
func pvp_hit(t: Legionnaire, dmg: float, from: Vector2, side: int) -> void:
	_pvp_hits.append([t, dmg, from, side])


func _flush_pvp_hits() -> void:
	for h: Array in _pvp_hits:
		var t: Legionnaire = h[0]
		if t.alive:
			t.last_hit_side = int(h[3])
			t.take_damage(float(h[1]), h[2])
	_pvp_hits.clear()


## Вид персонажа на сервере: не анимируется (_process вида и его клипа — самая дорогая часть
## кадра после боя) и не рисуется. Бой вид не читает.
static func _mute_view(v: CharView) -> void:
	v.process_mode = Node.PROCESS_MODE_DISABLED
	v.visible = false


## v18: расстояние от точки до оси ближайшей дороги карты (INF — дорог нет). Для рождения
## бойцов постройки не на проезжей части; зовётся редко (рождение), кэш не нужен.
func road_dist(p: Vector2) -> float:
	var best := INF
	for r in map.get("roads", []):
		var path: Array = r.get("path", [])
		for i in range(1, path.size()):
			var a := Vector2(float(path[i - 1][0]), float(path[i - 1][1]))
			var b := Vector2(float(path[i][0]), float(path[i][1]))
			best = minf(best, p.distance_to(Geometry2D.get_closest_point_to_segment(p, a, b)))
	return best


## Карта «Архив» (26.09): `flights` — воздушные трассы призраков, срезающие путь сквозь стены.
## Это не дороги: рельеф их не прорезает (стеллажи остаются целыми), на фоне их нет, бот по
## ним не строит рубежей. Волна ссылается на трассу тем же полем `road` (тест карт пускает на
## трассу только призраков).
func road_path(road_id: String) -> PackedVector2Array:
	for r in map.get("roads", []) + map.get("flights", []):
		if String(r.get("id", "")) == road_id:
			var out := PackedVector2Array()
			for p in r["path"]:
				out.append(Vector2(float(p[0]), float(p[1])))
			return out
	return PackedVector2Array()


## Замер: враги сразу на экране — вдоль дорог, от ворот к середине пути.
func _spawn_bench_foe(i: int) -> void:
	var roads: Array = map.get("roads", [])
	if roads.is_empty():
		return
	var path := road_path(String(roads[i % roads.size()]["id"]))
	var k := rng.randf_range(0.15, 0.55)
	var total := 0.0
	for j in range(1, path.size()):
		total += path[j].distance_to(path[j - 1])
	var d := total * k
	var at := path[0]
	var wp := 1
	for j in range(1, path.size()):
		var seg := path[j].distance_to(path[j - 1])
		if d <= seg:
			at = path[j - 1].lerp(path[j], d / seg)
			wp = j
			break
		d -= seg
	var types := ["zombie", "zombie", "beetle", "signer", "ghost"]
	var rest := path.slice(wp)
	var jitter := Vector2(rng.randf_range(-12, 12), rng.randf_range(-12, 12))
	_add_foe(types[i % types.size()], rest, {"pos": at + jitter})


## --dev spawn_kind=guard:10,clerk:10 — бойцы видов у Котла сверх армии (кадр и замеры).
func _spawn_dev_kinds(spec_str: String) -> void:
	for part in spec_str.split(",", false):
		var kv := part.split(":")
		var kind := StringName(kv[0])
		if not LegionCfg.UNIT_KINDS.has(kind):
			push_warning("LegionWorld: --dev spawn_kind — неизвестный вид '%s'" % kv[0])
			continue
		for i in (int(kv[1]) if kv.size() > 1 else 1):
			spawn_unit(kind, _near_cauldron())


## --dev hero_foe=TYPE:X:Y[:dead][,TYPE:X:Y...] — неподвижные враги в точных точках (кадры
## приёмки Ку/Дубль-вэ: дорожные враги --dev spawn_foes не гарантируют позицию у Котла).
## Четвёртый токен `dead` — сразу свежий труп (кадр приёмки Дубль-вэ без боя за кадром).
func _spawn_dev_foes(spec_str: String) -> void:
	for part in spec_str.split(",", false):
		var kv := part.split(":")
		if kv.size() < 3 or not LegionCfg.FOES.has(kv[0]):
			continue
		var at := Vector2(float(kv[1]), float(kv[2]))
		var f := spawn_foe_on_path(kv[0], PackedVector2Array([at]), at)
		f.speed = 0.0
		if kv.size() >= 4 and kv[3] == "dead":
			f.take_damage(100000.0, at + Vector2.RIGHT)


## --dev hero_cast=SLOT:FRAME:X,Y (докстринг у _dev_hero_cast_done).
func _try_dev_hero_cast() -> void:
	if _dev_hero_cast_done:
		return
	var parts := String(dev["hero_cast"]).split(":")
	if parts.size() < 3 or _frames < int(parts[1]):
		return
	_dev_hero_cast_done = true
	var xy := parts[2].split(",")
	if xy.size() >= 2:
		hero.cast(int(parts[0]), Vector2(float(xy[0]), float(xy[1])))


## Снаряд дальнего бойца: летит к цели самонаведением, урон — по попаданию.
func fire_projectile(from: Legionnaire, target: Node2D, dmg: float) -> void:
	projectiles.fire(from, target, dmg)


## Бойцы в радиусе (SLICE_SPEC §3). Аллоцирует массив — для редких вызовов, не для кадра.
func units_near(p: Vector2, r: float) -> Array[Legionnaire]:
	var out: Array[Legionnaire] = []
	for u in units:
		if u.alive and u.position.distance_squared_to(p) <= r * r:
			out.append(u)
	return out


func foes_near(p: Vector2, r: float) -> Array[Foe]:
	var out: Array[Foe] = []
	for f in foes:
		if f.alive and f.position.distance_squared_to(p) <= r * r:
			out.append(f)
	return out


func _track_pace(dt: float) -> void:
	var nf := active_foes()
	var na := army_alive()
	_pace["peak_foes"] = maxi(int(_pace["peak_foes"]), nf)
	_pace["peak_army"] = maxi(int(_pace["peak_army"]), na)
	_pace["foe_s"] = float(_pace["foe_s"]) + nf * dt
	_pace["army_s"] = float(_pace["army_s"]) + na * dt
	_pace["t"] = float(_pace["t"]) + dt


## Итог метрики читаемости: пики и средние за бой.
func pace_stats() -> Dictionary:
	var t := maxf(float(_pace["t"]), 0.001)
	return {
		"peak_foes": int(_pace["peak_foes"]), "peak_army": int(_pace["peak_army"]),
		"avg_foes": snappedf(float(_pace["foe_s"]) / t, 0.1),
		"avg_army": snappedf(float(_pace["army_s"]) / t, 0.1),
	}


## Живые бойцы стороны side (−1 — всех сторон; одиночка — у всех сторона 0).
func army_alive(side := 0) -> int:
	var n := 0
	for u in units:
		if u.alive and (side < 0 or u.side == side):
			n += 1
	return n


func active_foes() -> int:
	var n := 0
	for f in foes:
		if f.is_active():
			n += 1
	return n


# ── Договоры ↔ бойцы ────────────────────────────────────────────────────────

## Таяние или расторжение участка: бойцы этого участка уходят в натиск по стрелке договора.
## Прежний API (бот, тесты, щелчок ПКМ): сила 1.0 — ровно прежние числа натиска.
func release_segment(c: Contract, seg: int, cause: StringName = &"manual") -> void:
	_release(c, seg, cause, _ring_cap(c, seg, _volley(c.seg_dir(seg), -1.0, false,
		cause == &"manual")))


## v17 рогатка: расторжение с прицелом — стрелка dir, сила power 0..1, точный срыв perfect.
func release_segment_aimed(c: Contract, seg: int, dir: Vector2, power: float,
		perfect: bool) -> void:
	if not c.seg_alive(seg) or dir.is_zero_approx():
		return
	stats["sling_releases"] = int(stats.get("sling_releases", 0)) + 1
	if perfect:
		stats["perfect_releases"] = int(stats.get("perfect_releases", 0)) + 1
	_release(c, seg, &"manual", _volley(dir.normalized(), clampf(power, 0.0, 1.0), perfect, true))


## «Оцепление»: ПКМ или рогатка по любому участку кольца — «Сжать кольцо!»: все живые участки
## срываются разом, каждый к центру по своей стрелке. power < 0 — щелчок (множители 1.0), иначе
## сила рогатки — общая. Залпы участков связаны общей группой: комбо растёт ОДИН раз за сжатие
## (иначе шесть участков давали бы +6 комбо одним жестом) и сбрасывается, только если не попал
## ни один. Возвращает, сколько участков сорвано.
func release_ring(c: Contract, power: float, perfect: bool) -> int:
	if not c.ring:
		return 0
	var group := {"hit": false, "units": 0}
	var n := 0
	for s in c.seg_count():
		if not c.seg_alive(s):
			continue
		var v := _ring_cap(c, s, _volley(c.seg_dir(s), power, perfect, true))
		v["group"] = group
		_release(c, s, &"manual", v)
		group["units"] = int(group["units"]) + int(v["units"])
		n += 1
	if n > 0:
		stats["ring_squeezes"] = int(stats.get("ring_squeezes", 0)) + 1
		# «Удавка», «Молния-оцепление» — про СЖАТИЕ к центру; «Круговой удар» наружу их не будит
		# (verify-items: молния била в пустой центр, души платились за удар наружу)
		if not c.ring_out:
			items_of(c.owner_side).on(&"ring_squeezed", [c, int(group["units"])])
		if power >= 0.0:
			stats["sling_releases"] = int(stats.get("sling_releases", 0)) + 1
			if perfect:
				stats["perfect_releases"] = int(stats.get("perfect_releases", 0)) + 1
	return n


## Таб (slow/tab-erase): кусок линии стёрт одним жестом — каждый живой участок из segs уходит в
## натиск, как от щелчка ПКМ: по стрелке своего участка, золотой (gold[i] != 0) — «Точно!» с
## полной силой, остальные — множители 1.0. Залпы связаны общей группой, как у сжатия кольца:
## комбо растёт один раз за жест, а не на число участков. Возвращает, сколько участков сорвано.
func release_run(c: Contract, segs: PackedInt32Array, gold: PackedByteArray) -> int:
	var group := {"hit": false, "units": 0}
	var n := 0
	for i in segs.size():
		var s := segs[i]
		if not c.seg_alive(s):
			continue
		var perfect := i < gold.size() and gold[i] != 0
		var v := _volley(c.seg_dir(s), 1.0 if perfect else -1.0, perfect, true)
		if perfect:
			stats["sling_releases"] = int(stats.get("sling_releases", 0)) + 1
			stats["perfect_releases"] = int(stats.get("perfect_releases", 0)) + 1
			tab_perfect_releases += 1
		v["group"] = group
		_release(c, s, &"manual", v)
		group["units"] = int(group["units"]) + int(v["units"])
		n += 1
	return n


## Натиск кольца к центру не бежит дальше центра (+ ContractShape.RING_OVERRUN): иначе бойцы
## встречных участков проскакивают друг сквозь друга и рассыпаются за кольцом с другой стороны —
## клещи превращаются в разбегание. Наружу («круговая оборона») и у линий — без ограничения.
func _ring_cap(c: Contract, seg: int, volley: Dictionary) -> Dictionary:
	if c.ring and not c.ring_out:
		volley["cap"] = c.seg_center(seg).distance_to(c.center) + ContractShape.RING_OVERRUN
	return volley


## Залп — словарь, общий для бойцов одного выпуска. power < 0 — щелчок/таяние: множители 1.0.
## manual — выпуск игроком (щелчок или рогатка): только он растит и сбрасывает комбо.
func _volley(dir: Vector2, power: float, perfect: bool, manual: bool) -> Dictionary:
	var t := clampf(power, 0.0, 1.0)
	var sling := power >= 0.0
	return {
		"dir": dir, "power": t if sling else 1.0, "perfect": perfect, "manual": manual,
		"range": lerpf(LegionCfg.SLING_RANGE.x, LegionCfg.SLING_RANGE.y, t) if sling else 1.0,
		"dmg": lerpf(LegionCfg.SLING_DMG.x, LegionCfg.SLING_DMG.y, t) if sling else 1.0,
		"speed": lerpf(LegionCfg.SLING_SPEED.x, LegionCfg.SLING_SPEED.y, t) if sling else 1.0,
		"units": 0, "hit": false, "combo_mult": 1.0, "knocked": {},
	}


func _release(c: Contract, seg: int, cause: StringName, volley: Dictionary) -> void:
	if not c.seg_alive(seg):
		return
	var field := field_of(c)
	var sealed := cause == &"melt" and field.seal_ready(c, seg)
	var bend := c.bend_frac(seg) if press_on() else 0.0
	# причина — до сигнала пружины: слушатели (урок «пружина») отличают срыв от таяния
	c.release_causes[seg] = cause
	if bend >= LegionCfg.SPRING_MIN:
		# v18 «Пружина»: прогнутый участок распрямляется — сильнее удар и отброс
		volley["dmg"] = float(volley["dmg"]) * (1.0 + LegionCfg.SPRING_DMG * bend)
		volley["spring"] = bend
		stats["spring_releases"] = int(stats.get("spring_releases", 0)) + 1
		spring_released.emit(c, seg, bend)
	c.seg_bend[seg] = 0.0
	c.seg_dead[seg] = 1
	var n := 0
	for p in c.posts:
		if int(p["seg"]) != seg:
			continue
		p["dead"] = true
		var u: Legionnaire = p["unit"]
		p["unit"] = null
		if u == null or not u.alive:
			continue
		if u.side != c.owner_side:
			# защита в глубину: чужой боец на месте линии не выполняет её команд
			u.set_free()
			continue
		if u.state == Legionnaire.State.POSTED:
			if cause == &"melt" and c.seg_renewed[seg] != 0 and int(dev.get("melt_settlement",
					int(LegionCfg.MELT_SETTLEMENT_ENABLED))) != 0:
				# Выплата только отстоявшим бойцам: пустые места и марш не дают бонуса.
				u.settle(field.settlement_mult)
			if sealed:
				u.grant_seal()
			if c.figure != &"":
				# восьмёрка и треугольник: у каждого бойца своя цель; рогатка задаёт общую ось
				# оттяжки (LegionFigures.charge_for)
				var aim := figures.charge_for(c, p, u, volley.get("axis", Vector2.ZERO))
				u.start_charge(aim[0], volley, aim[1])
			else:
				u.start_charge(volley["dir"], volley)
			n += 1
		else:
			u.set_free()
	stats["releases"] = int(stats["releases"]) + 1
	var key := "releases_melt" if cause == &"melt" else "releases_manual"
	stats[key] = int(stats[key]) + 1
	stats["charges"] = int(stats["charges"]) + n
	segment_released.emit(c, seg, n)


# ── v17 CTL: комбо и удар натиска ─────────────────────────────────────────────

## Первое касание бойца залпа с врагом (unit.gd, удар с разбега). Первое касание залпа —
## комбо (только выпуск игроком) и отклик; каждый задетый враг — отброс по стрелке, один раз
## на залп. --dev ctl_off=1 выключает комбо и отброс (сверка баланса с прежним натиском).
## PvP: комбо — общий счётчик мира, у двух сторон он нечестен — выключено; цель натиска может
## быть чужим бойцом или Котлом — отброс только врагов PvE.
func on_charge_contact(u: Legionnaire, foe: Node2D, volley: Dictionary) -> void:
	var off := dev.has("ctl_off") or pvp
	var perfect := bool(volley["perfect"])
	if not bool(volley["hit"]):
		volley["hit"] = true
		# «Оцепление»: у залпов одного сжатия общая группа — комбо растёт один раз на сжатие
		var group: Dictionary = volley.get("group", {})
		var group_first := group.is_empty() or not bool(group["hit"])
		if not group.is_empty():
			group["hit"] = true
		# ульты «первым касанием» решаются ДО отсечки (ctl_off и PvP глушат только комбо и
		# отброс): «Комиссия» метит цель, «Неустойка» замедляет врагов вокруг удара
		if group_first:
			_ult_contact(foe, volley, u.side)
		if bool(volley["manual"]) and not off:
			if group_first:
				_set_combo(combo + 1 if combo > 0 and now - _combo_hit_t <= LegionCfg.COMBO_WINDOW else 1)
				_combo_hit_t = now
			volley["combo_mult"] = combo_mult()
		_charge_feedback(foe.position.lerp(u.position, 0.5), perfect, u.side)
	var knocked: Dictionary = volley["knocked"]
	if off or knocked.has(foe) or not foe is Foe:
		return
	knocked[foe] = true
	var knock := LegionCfg.PERFECT_KNOCK if perfect else LegionCfg.CHARGE_KNOCK
	var spring := float(volley.get("spring", 0.0))
	_knock(foe as Foe, volley["dir"], knock * (1.0 + LegionCfg.SPRING_KNOCK * spring))


## Ульты фигур «первым касанием готовой группы» (D-1002 §4): «Комиссия» помечает цель, и её
## участники бьют помеченную сильнее; «Неустойка» замедляет врагов в D_SLOW_R px вокруг удара.
## Оба — один раз на ГРУППУ залпа (group_first), боссу замедление идёт по общей политике резистов.
## В «Схватке» (J6) обе ульты действуют и на АРМИЮ СОПЕРНИКА: цель метки — чужой боец, замедление
## ловит чужих бойцов теми же числами, что врагов PvE. Обход — списки мира в их порядке, а не
## порядок касаний: состояние у обоих клиентов одинаково (lockstep).
func _ult_contact(foe: Node2D, volley: Dictionary, side: int) -> void:
	if volley.has("mark_group"):
		var group_id := int(volley["mark_group"])
		if foe is Foe:
			var f := foe as Foe
			f.mark_group_id = group_id
			f.mark_t = FigureCfg.PENTA_MARK_T
		elif foe is Legionnaire:
			var t := foe as Legionnaire
			t.mark_hit_group = group_id
			t.mark_hit_t = FigureCfg.PENTA_MARK_T
	if volley.has("slow"):
		_ult_slow(foe.position, volley["slow"], side)


## Замедление «Неустойки» вокруг первого касания залпа: враги PvE и — в «Схватке» — чужие бойцы.
## side — сторона залпа: замедляем всех бойцов, кто не с ней. В одиночке бойцов-противников нет,
## список не смотрим вовсе.
func _ult_slow(at: Vector2, spec: Dictionary, side: int) -> void:
	var r := float(spec["r"])
	var mult := float(spec["mult"])
	var t := float(spec["t"])
	for other in foes:
		if other.is_active() and other.position.distance_to(at) <= r + other.radius:
			other.slow_mult = mult
			other.slow_t = maxf(other.slow_t, t)
	if not pvp:
		return
	for u in units:
		if not u.alive or u.side == side:
			continue
		if u.position.distance_to(at) <= r + LegionCfg.UNIT_RADIUS:
			u.ult_slow_mult = mult
			u.ult_slow_t = maxf(u.ult_slow_t, t)


## Боец залпа перестал бежать. Залп игрока, кончившийся без касания, — натиск впустую: сброс комбо.
func on_charge_unit_done(volley: Dictionary) -> void:
	volley["units"] = int(volley["units"]) - 1
	var group: Dictionary = volley.get("group", {})
	if not group.is_empty():
		# сжатие кольца: впустую — только если не попал ни один участок
		group["units"] = int(group["units"]) - 1
		if int(group["units"]) <= 0 and not bool(group["hit"]) and combo > 0:
			_set_combo(0)
		return
	if int(volley["units"]) <= 0 and not bool(volley["hit"]) and bool(volley["manual"]) and combo > 0:
		_set_combo(0)


## Убийство ударом с разбега (или в окне после него): души сверх обычных по множителю комбо.
## Дробная часть копится — у слабых врагов 2–3 души, +10 % иначе терялись бы в округлении.
func on_charge_kill(f: Foe) -> void:
	items_of(maxi(0, f.last_hit_side)).on(&"charge_kill", [f])
	var mult := combo_mult()
	if combo <= 1 or f.has_meta(&"summoned"):
		return
	_combo_soul_frac += LegionChallenge.foe_souls(f) * (mult - 1.0)
	var extra := int(_combo_soul_frac)
	if extra > 0:
		_combo_soul_frac -= float(extra)
		stats["combo_souls"] = int(stats.get("combo_souls", 0)) + extra
		staff.add_souls(extra)


## Множитель комбо: 1 + 0.1·(комбо − 1), не выше COMBO_CAP.
func combo_mult() -> float:
	if combo <= 1:
		return 1.0
	return minf(LegionCfg.COMBO_CAP, 1.0 + LegionCfg.COMBO_STEP * float(combo - 1))


## Сколько секунд боя осталось окну комбо (0 — комбо нет).
func combo_left() -> float:
	if combo <= 0:
		return 0.0
	return maxf(0.0, LegionCfg.COMBO_WINDOW - (now - _combo_hit_t))


func _set_combo(n: int) -> void:
	if n == combo:
		return
	combo = n
	stats["combo_max"] = maxi(int(stats.get("combo_max", 0)), n)
	combo_changed.emit(combo, combo_mult())


## Отброс по стрелке шагами по рельефу: в воду и скалу не выталкиваем. Босса и спящих не двигаем.
func _knock(foe: Foe, dir: Vector2, dist: float) -> void:
	var moving := foe.state == Foe.State.WALK or foe.state == Foe.State.FIGHT
	if not foe.alive or foe.type_id == "boss" or not moving:
		return
	var step := 4.0
	var left := dist
	while left > 0.0:
		var nxt := foe.position + dir * minf(step, left)
		if not foe.ghost and not terrain.walkable(nxt):
			break
		foe.position = nxt
		left -= step


## Hit-stop (не чаще CHARGE_HITSTOP_GAP реальных секунд) и лёгкая тряска через обёртку Juice.
func _charge_feedback(at: Vector2, perfect: bool, side := 0) -> void:
	if pvp:
		items_of(side).on(&"charge_impact", [at, perfect])
	charge_impact.emit(at, perfect)
	# PvP: hit-stop — остановка общего мира, её не делают ни сервер, ни клиент (DESIGN §2.5)
	if _hitstop_gap > 0.0 or pvp:
		return
	_hitstop_gap = LegionCfg.CHARGE_HITSTOP_GAP
	_hitstop_left = LegionCfg.CHARGE_HITSTOP * (1.6 if perfect else 1.0)
	Juice.shake(self, LegionCfg.PERFECT_SHAKE if perfect else LegionCfg.CHARGE_SHAKE,
		LegionCfg.CHARGE_SHAKE_TIME)


## Стоп-кадр чистого вида (удар Ку в полной графике, LegionImpactFx): тот же пропуск шагов
## мира, что у натиска, — симуляция просто стоит sec реальных секунд, последовательность шагов и
## числа боя те же (legion_impact_test, п.5). Окно натиска (_hitstop_gap) не трогаем.
func impact_stop(sec: float) -> void:
	if pvp:
		return
	_hitstop_left = maxf(_hitstop_left, sec)


## Слой эффектов (null в экономной графике и при --dev fx=0).
func gfx_fx() -> LegionFx:
	return _gfx_fx


func _reset_ctl() -> void:
	combo = 0
	tab_perfect_releases = 0
	_combo_hit_t = -INF
	_combo_soul_frac = 0.0
	_hitstop_left = 0.0
	_hitstop_gap = 0.0
	combo_changed.emit(0, 1.0)


## Шкала «Отсрочка» и счётчик комбо — на CanvasLayer боевого HUD (legion_hud.gd не правим).
func _build_ctl_widgets() -> void:
	var meter := ComboMeter.new()
	meter.name = "ComboMeter"
	hud.add_child(meter)
	meter.setup(self)
	var gauge := DelayGauge.new()
	gauge.name = "DelayGauge"
	hud.add_child(gauge)
	gauge.setup(self)


# ── v18 «Давка»: толпа прогибает и прорывает участок ────────────────────────────

## Давка включена (выключатель серий --dev press_off=1).
func press_on() -> bool:
	return LegionCfg.PRESS_ENABLED and not dev.has("press_off")


## Шаг давки: после хода врагов (они уже упёрлись), до хода бойцов (те бьют с новых мест).
func _tick_press(dt: float) -> void:
	if not press_on():
		return
	for c in all_contracts():
		grid.press_scan(c, LegionCfg.PRESS_BAND)
		if c.figure == ContractShape.SQUARE:
			continue   # «Каре» (D-1002-03): давка строй квадрата не прогибает и не прорывает
		for s in c.seg_count():
			if c.seg_alive(s):
				_press_segment(c, s, dt)


func _press_segment(c: Contract, s: int, dt: float) -> void:
	var hold := 0.0
	for p in c.posts:
		if int(p["seg"]) != s or p["dead"] or p["unit"] == null:
			continue
		var u: Legionnaire = p["unit"]
		if u.alive and u.state == Legionnaire.State.POSTED:
			# v20 (D-0926-39): под «Авралом» (Е) строй держит напор с множителем
			var e := LegionCfg.E_PRESS_HOLD_MULT if u.haste_speed_mult > 1.0 else 1.0
			hold += float(LegionCfg.PRESS_HOLD.get(u.kind, 1.0)) * e
	hold *= item_mult(&"press_hold", c.owner_side)   # «Несгораемый шкаф»
	var was := c.seg_bend[s]
	var bend := was
	var mass := c.press_mass[s]
	var excess := mass - hold
	if hold > 0.0 and excess > 0.0:
		var ratio := minf(excess / hold, LegionCfg.PRESS_RATIO_CAP)
		bend += LegionCfg.PRESS_RATE * ratio * dt
		var d := (c.seg_center(s) - c.press_sum[s] / mass).normalized()
		if d.is_zero_approx():
			d = -c.seg_dir(s)
		# направление держится, пока прогиб есть: толпа не «крутит» строй от кадра к кадру
		var cur := c.seg_bend_dir[s]
		c.seg_bend_dir[s] = d if cur.is_zero_approx() else cur.lerp(d, 0.08).normalized()
	else:
		bend = maxf(0.0, bend - LegionCfg.PRESS_RECOVER * dt)
	c.seg_bend[s] = bend
	if bend >= LegionCfg.PRESS_BREAK:
		_press_break(c, s)
		return
	if bend > 0.0 or was > 0.0:
		for p in c.posts:
			if int(p["seg"]) != s or p["dead"] or p["unit"] == null:
				continue
			var u: Legionnaire = p["unit"]
			if not u.alive or u.state != Legionnaire.State.POSTED:
				continue
			var at := c.bent_pos(p)
			if terrain.walkable(at):
				u.position = at
	if bend <= 0.0:
		c.seg_bend_dir[s] = Vector2.ZERO


## Прорыв: бойцы участка выбиты из строя — свободны, оглушены, раскиданы вбок от давки.
## Участок жив и места целы: договор доберёт людей, когда толпа отойдёт (VERBOVKA — не ближе
## 70 px к врагу).
func _press_break(c: Contract, s: int) -> void:
	var d := c.seg_bend_dir[s]
	if d.is_zero_approx():
		d = -c.seg_dir(s)
	var side := d.orthogonal()
	var center := c.seg_center(s)
	var n := 0
	for p in c.posts:
		if int(p["seg"]) != s or p["dead"] or p["unit"] == null:
			continue
		var u: Legionnaire = p["unit"]
		if not u.alive:
			continue
		u.set_free()
		# вбок — от середины участка в свою сторону: дыра открывается посередине
		var sgn := 1.0 if side.dot(u.position - center) >= 0.0 else -1.0
		var to := u.position + side * sgn * rng.randf_range(LegionCfg.PRESS_SCATTER.x,
			LegionCfg.PRESS_SCATTER.y) + d * LegionCfg.PRESS_SCATTER_BACK
		u.knock_to(to)
		u.stun(LegionCfg.PRESS_STUN)
		n += 1
	c.seg_bend[s] = 0.0
	c.seg_bend_dir[s] = Vector2.ZERO
	stats["press_breaks"] = int(stats.get("press_breaks", 0)) + 1
	segment_broken.emit(c, s, n)
	Juice.shake(self, LegionCfg.CHARGE_SHAKE, LegionCfg.CHARGE_SHAKE_TIME)

# ── v18 «Сбор» (R) ───────────────────────────────────────────────────────────────

## v19 (B-038): кого позовёт «Сбор» к точке — свободные в RALLY_R: reach — дойдут, cut — отрезаны
## стеной или водой (в одной связной области рельефа их нет). Для круга, пока R зажата.
func rally_preview(at: Vector2, side := 0) -> Dictionary:
	var reach: Array[Legionnaire] = []
	var cut: Array[Legionnaire] = []
	var c := rally_center(at)
	for u in units:
		if u.alive and u.side == side and u.state == Legionnaire.State.FREE \
				and u.position.distance_to(at) <= LegionCfg.RALLY_R:
			if c != Vector2.INF and terrain.connected(u.position, c):
				reach.append(u)
			else:
				cut.append(u)
	return {"reach": reach, "cut": cut}


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		# Прогоны без окна и скрытые агентные окна не зависят от фокуса рабочего стола.
		if not Settings.is_agent_run() and DisplayServer.get_name() != "headless":
			focus_lost()
		else:
			cancel_human_gestures()


func focus_lost() -> void:
	cancel_human_gestures()
	# Сетевая схватка считает общее время: остановка одного клиента нарушила бы матч.
	if phase == Phase.BATTLE and not pvp and not paused:
		set_paused(true)


## Свободные бойцы в RALLY_R от точки бегут к ней и встают вокруг подсолнухом (ближние — в
## середину). Возвращает, скольких позвали; -1 — откат или не бой. Некого звать — 0, откат не
## тратится (кольцо мигает, чтобы было видно, что нажатие дошло).
## side — чья «Сбор» (PvP): свои свободные, свой откат, свои пути.
func rally(cursor: Vector2, side := 0) -> int:
	var s := sides[side]
	if phase != Phase.BATTLE or s.rally_cd > 0.0 or not rally_unlocked():
		return -1
	if not can_pay_ability(LegionCfg.RALLY_SLOT, side):
		# D-0927-140: мало маны — кольцо мигает красным (как «некого звать»), слот и звук отказа
		_rallies.append({"pos": cursor, "t": LegionCfg.RALLY_FX_TIME, "n": 0, "side": side})
		if side == local_side:   # слот и звук — интерфейс игрока за этим экраном
			mana_short.emit(LegionCfg.RALLY_SLOT)
		return -1
	var picked: Array[Legionnaire] = []
	var at := rally_center(cursor)
	for u in units:
		if at != Vector2.INF and u.alive and u.side == side and u.state == Legionnaire.State.FREE \
				and u.position.distance_to(cursor) <= LegionCfg.RALLY_R:
			picked.append(u)
	picked.sort_custom(func(a: Legionnaire, b: Legionnaire) -> bool:
		return a.position.distance_squared_to(at) < b.position.distance_squared_to(at))
	var n := 0
	var spots := _rally_spots(at, picked.size(), side)
	for i in picked.size():
		var u := picked[i]
		var dest: Vector2 = spots[i] if i < spots.size() else at
		var path := s.contracts.recruit_path(u.position, dest)
		if path.is_empty():
			continue
		u.rally_to(path)
		n += 1
	if n > 0:
		pay_ability(LegionCfg.RALLY_SLOT, side)
		s.rally_cd = rally_cd_total(side)   # «Рупор» — у своей стороны
		if side == 0:   # stats — счёт игрока стороны 0
			stats["rallies"] = int(stats.get("rallies", 0)) + 1
			stats["rallied_units"] = int(stats.get("rallied_units", 0)) + n
	var shown := cursor if at == Vector2.INF else at
	_rallies.append({"pos": shown, "t": LegionCfg.RALLY_FX_TIME, "n": n, "side": side})
	if pvp:   # артефакты — владельцу «Сбора» (в PvP сигнал мира предметы не слушают)
		items_of(side).on(&"rally_used", [shown, n])
	if side == local_side:   # слушатели (обучение, вид) — игрока за этим экраном, как hero_cast
		rally_used.emit(shown, n)
	return n


## v19: куда зовёт «Сбор» по курсору — сам курсор на земле; на кромке скалы или в ограде —
## ближайшая земля в пределах полутора клеток (промах на ширину забора — не повод никого не
## звать); глубже в скале — никуда (INF), круг честно пишет «позовёт 0». Курсор у края экрана
## сначала подтягивается внутрь карты: за кадром рельеф «проходим» ради ворот.
func rally_center(cursor: Vector2) -> Vector2:
	var field := _rally_field()
	# до end − 1 px: Rect2.has_point не считает правую и нижнюю границу своими, и курсор у этих
	# краёв, прижатый ровно к границе, не звал никого (четвёртый verifier d26f8623)
	var inside := cursor.clamp(field.position, field.end - Vector2.ONE)
	var p := terrain.nearest_open(inside)
	if p == Vector2.INF or p.distance_to(inside) > LegionCfg.CELL * 1.5 or not field.has_point(p):
		return Vector2.INF
	return p


## Где «Сбор» ставит бойцов: карта без полосы в радиус тела у края.
func _rally_field() -> Rect2:
	return Rect2(Vector2.ZERO, world_size).grow(-LegionCfg.UNIT_RADIUS)


## Точки подсолнуха вокруг курсора: золотой угол, радиус растёт как √j — плотно и без стопки
## в одной точке. v19: точка берётся, только если от курсора до неё прямая по проходимому, —
## иначе следующая. Точка за тонкой стеной стоит на проходимой земле, и бойца слали бы в обход
## на ту сторону; точка в скале раньше сводилась к самому курсору, и у стены кучка вставала
## стопкой. Точка — на карте и в той же связной области, что центр (за краем экрана рельеф
## «проходим» ради ворот, и бойца слали за кадр, а круг, считающий по связности, обещал его —
## третий verifier d26f8623). В чистом поле точки те же, что и прежде (j = i).
func _rally_spots(at: Vector2, count: int, side := 0) -> Array[Vector2]:
	var spots: Array[Vector2] = []
	var tries := count * LegionCfg.RALLY_SPOT_TRIES + LegionCfg.RALLY_SPOT_TRIES
	var field := _rally_field()
	for j in tries:
		if spots.size() >= count:
			break
		# B-365: подсолнух не симметричен — у стороны справа он отражён (side_dx)
		var p := at + side_dx(Vector2.from_angle(float(j) * 2.39996) * LegionCfg.RALLY_SPREAD
			* sqrt(float(j)), side)
		if field.has_point(p) and _clear_walk(at, p) and terrain.connected(at, p):
			spots.append(p)
	return spots


## Прямая a→b целиком по проходимым клеткам (шаг — полклетки).
func _clear_walk(a: Vector2, b: Vector2) -> bool:
	var steps := maxi(1, ceili(a.distance_to(b) / (LegionCfg.CELL * 0.5)))
	for k in range(steps + 1):
		if not terrain.walkable(a.lerp(b, float(k) / float(steps))):
			return false
	return true


## Сколько секунд осталось откату сбора (для панели способностей).
func rally_left() -> float:
	return my_side().rally_cd


func _draw_rallies() -> void:
	if rally_aiming and phase == Phase.BATTLE:
		_draw_rally_aim(aim_pos())
	# «Рупор завхоза»: «Сбор» своего цвета и с расходящимися звуковыми дугами — видно, что он
	# теперь ещё и оглушает
	for r in _rallies:
		var owned := items_of(int(r.get("side", 0)))
		var horn := owned.look_of(&"rally", &"color")
		var k := 1.0 - float(r["t"]) / LegionCfg.RALLY_FX_TIME
		var at: Vector2 = r["pos"]
		var ok := int(r["n"]) > 0
		var col := LegionCfg.RALLY_COLOR if ok else Color(1.0, 0.35, 0.3)
		if not horn.is_empty():
			col = horn["color"] if ok else col
			owned.note_look(&"rally", &"color")
			for wave in 3:
				var wr := LegionCfg.RALLY_R * (0.35 + 0.45 * float(wave) + 0.5 * k)
				_fx.draw_arc(at, wr, -0.9, 0.9, 20, Color(horn["color"], 0.7 * (1.0 - k)), 3.0, true)
				_fx.draw_arc(at, wr, PI - 0.9, PI + 0.9, 20, Color(horn["color"], 0.7 * (1.0 - k)),
					3.0, true)
		# кольцо сходится от радиуса сбора к точке: «все сюда»
		var rad := lerpf(LegionCfg.RALLY_R, 14.0, 1.0 - pow(1.0 - k, 2.0))
		_fx.draw_arc(at, rad, 0.0, TAU, 48, Color(col, 0.8 * (1.0 - k)), 3.0, true)
		for q in 4:
			var d := Vector2.from_angle(PI * 0.5 * float(q) + PI * 0.25)
			var tip := at + d * (rad - 10.0)
			var side := d.orthogonal() * 6.0
			_fx.draw_colored_polygon(PackedVector2Array([tip - d * 10.0, tip + side, tip - side]),
				Color(col, 0.9 * (1.0 - k)))


## v19 (B-038): R зажата — круг «Сбора» у курсора, кольца под теми, кто прибежит, серые — под
## отрезанными стеной, подпись «позовёт N» (на откате — «откат N с»).
func _draw_rally_aim(at: Vector2) -> void:
	var me := my_side()
	var paid := can_pay_ability(LegionCfg.RALLY_SLOT, local_side)
	var ready := me.rally_cd <= 0.0 and paid
	var col := LegionCfg.RALLY_COLOR if ready else Color(0.6, 0.58, 0.66)
	_fx.draw_circle(at, LegionCfg.RALLY_R, Color(col, LegionCfg.RALLY_AIM_FILL))
	_fx.draw_arc(at, LegionCfg.RALLY_R, 0.0, TAU, 64, Color(col, 0.75), 2.0, true)
	var pv := rally_preview(at, local_side)
	for u: Legionnaire in pv["reach"]:
		_fx.draw_arc(u.position + LegionCfg.RALLY_AIM_MARK_OFFSET, LegionCfg.RALLY_AIM_MARK_R,
			0.0, TAU, 16, Color(col, 0.95), 2.0, true)
	for u: Legionnaire in pv["cut"]:
		_fx.draw_arc(u.position + LegionCfg.RALLY_AIM_MARK_OFFSET, LegionCfg.RALLY_AIM_MARK_R,
			0.0, TAU, 16, Color(0.55, 0.55, 0.6, 0.7), 1.5, true)
	var text := "позовёт %d" % (pv["reach"] as Array).size() if ready \
		else "откат %d с" % ceili(me.rally_cd)
	if me.rally_cd <= 0.0 and not paid:
		text = "мало маны: %d из %d" % [int(me.contracts.mana), roundi(LegionCfg.RALLY_MANA)]
	var font := ThemeDB.fallback_font
	var pos := at + LegionCfg.RALLY_AIM_LABEL_OFFSET
	var rally_fs := PvpView.fs(self, LegionCfg.RALLY_AIM_FONT)   # B-303
	_fx.draw_string(font, pos + Vector2(1, 1), text, HORIZONTAL_ALIGNMENT_LEFT, -1,
		rally_fs, Color(0, 0, 0, 0.8))
	_fx.draw_string(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, rally_fs, col)


## v17 LAW: Юрист дочитал — участок расторгнут без натиска: места гаснут, бойцы участка
## (стоявшие и шедшие на место) свободны. segment_released не шлём: натиска не было, а на
## этот сигнал завязаны счёт печатей бота и шаги обучения про выпуск.
func tear_segment(c: Contract, seg: int) -> void:
	if seg < 0 or seg >= c.seg_count() or not c.seg_alive(seg):
		return
	c.release_causes[seg] = &"torn"
	c.seg_dead[seg] = 1
	var n := 0
	for p in c.posts:
		if int(p["seg"]) != seg:
			continue
		p["dead"] = true
		var u: Legionnaire = p["unit"]
		p["unit"] = null
		if u == null or not u.alive:
			continue
		u.set_free()
		# v20: «в отказе» — расторгнутые стоят оглушённые: цена расторжения видна (B-061)
		u.stun(LegionCfg.LAWYER_TEAR_STUN)
		n += 1
	stats["segments_torn"] = int(stats.get("segments_torn", 0)) + 1
	_tears.append({"poly": c.seg_polys[seg], "t": LegionCfg.LAWYER_TEAR_FX})
	segment_torn.emit(c, seg, n)
	toast("Юрист расторг участок договора!", &"warn")


func on_contract_created(c: Contract) -> void:
	stats["lines"] = int(stats["lines"]) + 1
	# overtime_clause (mods): +с к сроку жизни каждого участка нового договора.
	c.ttl += mod_add("seg_ttl_bonus") + item_add(&"seg_ttl", c.owner_side)
	contract_created.emit(c)


func on_contract_refreshed(c: Contract, segs: PackedInt32Array, n: int) -> void:
	stats["refreshes"] = int(stats["refreshes"]) + n
	contract_refreshed.emit(c, segs)


func on_contract_removed(c: Contract) -> void:
	contract_removed.emit(c)


## Общий с черновиком план: ближайшее достижимое место своего вида в радиусе бойца.
## Кэш путей и поиск по клеткам принадлежат полю; назначенных на марше не трогаем.
## field — поле стороны (PvP: у каждой своя раздача и только свои бойцы).
func _assign_free(field: ContractField = null) -> void:
	if field == null:
		field = contracts
	for assignment in field.assignment_plan(field.contracts):
		var u: Legionnaire = assignment["unit"]
		u.assign(assignment["contract"], assignment["post"], assignment["path"])


# ── Бой ─────────────────────────────────────────────────────────────────────

func on_unit_died(u: Legionnaire) -> void:
	if u.side == 0:
		stats["lost"] = int(stats["lost"]) + 1
	sides[u.side].staff.on_unit_died(u)
	# PvP: души за чужого бойца — стороне, чей удар был последним (DESIGN §2.4)
	if pvp and u.last_hit_side >= 0 and u.last_hit_side != u.side:
		sides[u.last_hit_side].staff.add_souls(PvpRules.SOULS_PER_UNIT)
	unit_died.emit(u)


func on_foe_died(f: Foe) -> void:
	if f.type_id == "boss":
		stats["boss_killed"] = 1
	stats["kills"] = int(stats["kills"]) + 1
	if f.type_id == "signer":
		stats["signers_killed"] = int(stats["signers_killed"]) + 1
	if pvp:
		# души — добившей стороне; добили не бойцы (свита, внештатник) — хозяину половины
		var who := f.last_hit_side if f.last_hit_side >= 0 else f.goal_side
		sides[who].staff.on_foe_killed(f)
	else:
		staff.on_foe_killed(f)
	if pvp and f.last_hit_side >= 0 and f.last_hit_side < sides.size():
		items_of(f.last_hit_side)._on_foe_killed(f, f.position)
	foe_died.emit(f)
	foe_killed.emit(f, f.position)


func foe_reached_cauldron(f: Foe) -> void:
	if String(f.origin.get("breach", "")) != "" and not f.has_meta(&"breach_leaked"):
		f.set_meta(&"breach_leaked", true)
		stats["breach_leaks"] = int(stats.get("breach_leaks", 0)) + 1
	if f.type_id == "boss" and LegionCfg.BOSS_SIEGE_ENABLED:
		f.begin_siege()
		return
	if pvp:
		sides[f.goal_side].leaked_waves[int(f.origin.get("wave", 0))] = true
	damage_cauldron(float(f.def.get("cauldron", 10.0)), f.type_id, f.goal_side, f.origin)
	f.vanish()


## Прорыв и осада используют один сигнал: существующий звук, вспышка и тряска котла.
## mode (BOOK §1): foe_type — вид врага, нанёсшего удар; запоминаем последний в
## stats["last_hit_foe_type"] (final_stats() сливает stats в итог боя) — им «Бесконечный подряд»
## называет причину смерти в некрологе. "" — источник не знает вида (тест/старый вызов), поле
## не трогаем — прежнее значение (если было) остаётся.
## side — чей Котёл (PvP); сигнал и счёт stats — только Котла стороны 0 (интерфейс игрока).
## PvP: урон по источникам — PvpSide.cauldron_dmg.
func damage_cauldron(dmg: float, foe_type: String = "", side := 0, source: Dictionary = {}) -> void:
	var s := sides[side]
	var before := s.cauldron_hp
	if pvp:
		dmg *= PvpRules.cauldron_mult(now)
		var src := "units" if foe_type == "" else "waves"
		s.cauldron_dmg[src] = float(s.cauldron_dmg.get(src, 0.0)) + minf(dmg, s.cauldron_hp)
	if not dev_invuln:
		s.cauldron_hp = maxf(0.0, s.cauldron_hp - dmg)
	if not pvp and side == 0:
		BattleDebrief.record(stats, maxf(0.0, before - s.cauldron_hp), foe_type, source, now)
	if pvp:
		items_of(side).on(&"cauldron_hit", [dmg])
	if side != 0:
		if s.necro != null:
			s.necro.play_once(&"flinch")
		if side == local_side:   # вспышка, звук, тряска плашки — Котлу человека за этим экраном
			cauldron_hit.emit(dmg)
		return
	stats["cauldron_dmg"] = float(stats["cauldron_dmg"]) + dmg
	if foe_type != "":
		stats["last_hit_foe_type"] = foe_type
	if _necro != null:
		_necro.play_once(&"flinch")
	if local_side == 0:
		cauldron_hit.emit(dmg)


## Удар по кругу (печать нотариуса, таран босса): предупреждение уже отыграло.
func stamp_hit(at: Vector2, r: float, dmg: float, from: Vector2) -> void:
	_impacts.append(Vector3(at.x, at.y, 0.3))
	_impact_r.append(r)
	stats["stamp_hits"] = int(stats["stamp_hits"]) + grid.hit_units(at, r, dmg, from)


func _tick_impacts(dt: float) -> void:
	for i in range(_impacts.size() - 1, -1, -1):
		var v := _impacts[i]
		v.z -= dt
		if v.z <= 0.0:
			_impacts.remove_at(i)
			_impact_r.remove_at(i)
		else:
			_impacts[i] = v
	for i in range(_tears.size() - 1, -1, -1):
		_tears[i]["t"] = float(_tears[i]["t"]) - dt
		if float(_tears[i]["t"]) <= 0.0:
			_tears.remove_at(i)
	for s in sides:
		s.rally_cd = maxf(0.0, s.rally_cd - dt)
	for i in range(_rallies.size() - 1, -1, -1):
		_rallies[i]["t"] = float(_rallies[i]["t"]) - dt
		if float(_rallies[i]["t"]) <= 0.0:
			_rallies.remove_at(i)


func _cleanup(dt: float) -> void:
	var removed := false
	for i in range(units.size() - 1, -1, -1):
		if not units[i].alive:
			_corpses.append(units[i])
			units.remove_at(i)
			removed = true
	for i in range(foes.size() - 1, -1, -1):
		if not foes[i].alive:
			removed = true
			var f := foes[i]
			_damage_hp.erase(f)
			foes.remove_at(i)
			if f.visible:
				_corpses.append(f)
			else:
				f.queue_free()
	for i in range(_corpses.size() - 1, -1, -1):
		var c := _corpses[i]
		if c is Legionnaire:
			(c as Legionnaire).tick(dt)
			if (c as Legionnaire).is_corpse_done():
				_corpses.remove_at(i)
				c.queue_free()
		elif c is Foe:
			(c as Foe).tick(dt)
			if (c as Foe).is_corpse_done():
				_corpses.remove_at(i)
				c.queue_free()
	# Индексы сетки (_u_head/_f_head) указывают в units/foes на момент rebuild() в начале шага;
	# уборка сдвинула массивы, и подсказки поля (LegionIntuit._contact → nearest_unit), читающие
	# сетку в этом же кадре после шага, ловили «Out of bounds» или чужого бойца (ревью 29.09).
	# Перестраиваем, только если кого-то убрали; порядок шага и бой не меняются — следующий шаг
	# всё равно начинает с rebuild().
	if removed:
		grid.rebuild()


func on_wave_started(i: int, total: int) -> void:
	if wave_runner.is_climax(i):
		toast("Кульминация! Волна %d из %d" % [i + 1, total], &"warn")
	else:
		toast("Волна %d из %d" % [i + 1, total], &"wave")
	wave_started.emit(i, total)


func on_wave_cleared(i: int) -> void:
	if pvp:
		# «отбитая волна» — на своей половине никто из этой волны не дошёл до Котла (DESIGN §2.4)
		for s in sides:
			if not s.leaked_waves.has(i + 1):
				s.staff.on_wave_cleared()
	else:
		staff.on_wave_cleared()
	wave_cleared.emit(i)


func on_all_waves_cleared() -> void:
	if pvp:
		return   # волны «Схватки» — давление, а не цель: матч кончает Котёл, предел или сдача
	_end(true)


func _end(victory: bool) -> void:
	_depth_generation += 1
	_cancel_ground_loading()
	# Даже принудительный итог не должен выдавать финал за пережитый прорыв.
	if victory and LegionCfg.BOSS_SIEGE_ENABLED and map_id == "boss" \
			and int(stats.get("boss_killed", 0)) == 0:
		return
	if victory and LegionCfg.BOSS_SIEGE_ENABLED:
		for foe in foes:
			if foe.alive and foe.type_id == "boss":
				return
	phase = Phase.VICTORY if victory else Phase.DEFEAT
	# уроки на экране итога не нужны: плашка, шаблон и голос урока уходят вместе с боем
	# (проверяющий 27.09, кадр vv_fork_victory_banner)
	if tutorial != null:
		tutorial.teardown()
		tutorial = null
	_release_corpses()
	plot_menu.close()
	for s in sides:
		s.contracts.active = false
		s.contracts.cancel()
	if pvp_menu != null:
		pvp_menu.close()
	# Последний враг мог погибнуть от ручной Ку между шагами мира.
	_track_damage(_damage_hp, 0.0)
	# Вещи и награды за тот же исход должны попасть в одну версию профиля.
	# LegionMain дополняет её синхронным обработчиком match_ended; вложенные update допустимы.
	if not pvp:
		Campaign.begin_update()
	# артефакты забега пишутся только победой: проигранный бой (и «Заново» посреди него) свои
	# находки теряет — иначе переигровкой карты кампании их можно было бы фармить
	if victory and carry_items and not pvp:
		Campaign.set_run_items(items.owned())
	var final := final_stats(victory)
	hud.show_result(victory, stats)
	match_ended.emit(victory, final)
	if not pvp:
		Campaign.end_update()
	if args.has("quit_on_end"):
		print(JSON.stringify(final))
		get_tree().quit()


func final_stats(victory: bool) -> Dictionary:
	var out := {
		"result": "victory" if victory else "defeat", "map": map_id,
		"bot": String(args.get("bot", "off")), "seed": _base_seed,
		"t": snappedf(now, 0.1), "wave": wave_runner.wave_no() if wave_runner else 0,
		"hp": snappedf(cauldron_hp, 0.1), "army": army_alive(), "difficulty": difficulty,
	}
	out.merge(stats)
	if out.has("debrief"):
		var report: Dictionary = Dictionary(out["debrief"]).duplicate(true)
		var titles := {}
		var labels := PgLayout.road_labels(map)
		for road: String in labels:
			titles[road] = String(Dictionary(labels[road]).get("title", "подход к Котлу"))
		report["road_titles"] = titles
		out["debrief"] = report
	out.merge(pace_stats())
	out["boss_killed"] = int(stats.get("boss_killed", 0))
	out["mana_spent"] = snappedf(float(stats["mana_spent"]), 0.1)
	# «Касса»: ключи — только если в неё закладывали (итог без кассы побайтно прежний: его хэшируют
	# эталоны трасс бота). Поражение — касса сгорает: премии 0, заложенные души — для отчёта.
	if not pvp and kassa.souls > 0:
		out["kassa"] = kassa.earned() if victory else 0
		out["kassa_souls"] = kassa.souls
	if pvp_match != null:
		out["pvp"] = pvp_stats()
		if int(out["pvp"].get("winner", 0)) == -1 and not pvp_match.result.is_empty():
			out["result"] = "draw"
	return out


## Итог «Схватки» для серий и отчёта: победитель (−1 — ничья), причина, по сторонам — HP Котла,
## армия, души, счётчики бота.
func pvp_stats() -> Dictionary:
	var res := pvp_match.result if pvp_match != null else {}
	var per: Array = []
	for s in sides:
		var row := {"hp": snappedf(s.cauldron_hp, 0.1), "army": army_alive(s.index),
			"souls": s.souls, "surrendered": s.surrendered,
			"dmg": {"units": snappedf(float(s.cauldron_dmg["units"]), 0.1),
				"waves": snappedf(float(s.cauldron_dmg["waves"]), 0.1)}}
		if s.bot is PvpBot:
			row["bot"] = (s.bot as PvpBot).counts.duplicate()
		per.append(row)
	return {"winner": int(res.get("winner", -2)), "reason": String(res.get("reason", "")),
		"t": snappedf(now, 0.1), "sides": per}


func toast(text: String, kind: StringName = &"info", time := -1.0) -> void:
	if hud != null:
		hud.toast(text, kind, time)
	toast_posted.emit(text, kind)


func foe_in_front(p: Vector2, n: Vector2, dist: float, type: String) -> bool:
	for f in foes:
		if not f.is_active() or f.type_id != type:
			continue
		var d := f.position - p
		var along := d.dot(n)
		if along > 0.0 and along <= dist and absf(d.cross(n)) <= LegionCfg.SEG_LEN * 1.5:
			return true
	return false


## Для бота: призрак прошёл сквозь участок и уже позади него (ближе dist).
func ghost_behind(p: Vector2, n: Vector2, dist: float) -> bool:
	for f in foes:
		if not f.is_active() or not f.ghost:
			continue
		var d := f.position - p
		var along := d.dot(n)
		if along < 0.0 and along >= -dist and absf(d.cross(n)) <= LegionCfg.SEG_LEN:
			return true
	return false


## Расталкивание: не строевые бойцы и враги не слипаются в точку; строй неподвижен и
## выталкивает из себя пехоту (стена не протекает от давки сзади).
# ── Служебное: trace / bench / shot ─────────────────────────────────────────

func print_trace() -> void:
	var free := 0
	var posted := 0
	var charge := 0
	for u in units:
		if not u.alive:
			continue
		match u.state:
			Legionnaire.State.FREE:
				free += 1
			Legionnaire.State.POSTED:
				posted += 1
			Legionnaire.State.CHARGE:
				charge += 1
	if pvp:
		# полосы по расстоянию до чужого Котла: < 300 (осада), 300–800 (чужая половина), дальше
		var bands: Array = []
		for s in sides:
			var b := [0, 0, 0]
			var enemy := sides[(s.index + 1) % sides.size()].cauldron_pos
			for u in units:
				if u.alive and u.side == s.index:
					var d := u.position.distance_to(enemy)
					b[0 if d < 300.0 else (1 if d < 800.0 else 2)] += 1
			bands.append(b)
		print(JSON.stringify({"t": snappedf(now, 0.1), "wave": wave_runner.wave_no(),
			"foes": active_foes(), "bands": bands, "pvp": pvp_stats()}))
		return
	print(JSON.stringify({
		"t": snappedf(now, 0.1), "wave": wave_runner.wave_no(), "phase": phase,
		"hp": snappedf(cauldron_hp, 0.1), "mana": snappedf(contracts.mana, 1.0),
		"army": army_alive(), "free": free, "posted": posted, "charge": charge,
		"foes": active_foes(), "contracts": contracts.contracts.size(), "empty": _empty_posts(),
		"kills": stats["kills"], "lost": stats["lost"], "refreshes": stats["refreshes"],
		"releases": stats["releases"], "rel_melt": stats["releases_melt"],
		"rel_manual": stats["releases_manual"], "charges": stats["charges"],
		"souls": souls, "buildings": buildings.size(),
		"first_contact_t": stats.get("first_contact_t", -1.0),
		"no_dmg_s": snappedf(float(stats.get("no_dmg_s", 0.0)), 0.1),
	}))


func _bench_tick(delta: float, tick_us: int) -> void:
	if _frames <= 30:
		return
	if _bench_n == 0:
		_bench_wall0 = Time.get_ticks_usec()
	_bench_el += delta
	_bench_n += 1
	_bench_tick_us += tick_us
	_bench_ticks.append(tick_us)
	if _bench_el >= _bench_s:
		var fps := float(_bench_n) / _bench_el
		print(JSON.stringify({
			"engine": "godot", "mode": "pvp" if pvp else "legion", "units": army_alive(-1),
			"foes": active_foes(),
			"seconds": snappedf(_bench_el, 0.01), "frames": _bench_n,
			"realFps": snappedf(fps, 0.1), "frameMs": snappedf(1000.0 / fps, 0.01),
			"tickMs": snappedf(float(_bench_tick_us) / float(_bench_n) / 1000.0, 0.01),
		}.merged(_bench_extra())))
		get_tree().quit()


## Перцентили тика и стенная цена кадра (весь кадр движка: мир, виды, отрисовка-заглушка).
func _bench_extra() -> Dictionary:
	var s := _bench_ticks.duplicate()
	s.sort()
	var n := s.size()
	var wall := float(Time.get_ticks_usec() - _bench_wall0) / 1000.0 / float(maxi(1, _bench_n))
	return {"tickP50Ms": snappedf(s[n / 2] / 1000.0, 0.01),
		"tickP99Ms": snappedf(s[mini(n - 1, n * 99 / 100)] / 1000.0, 0.01),
		"tickMaxMs": snappedf(s[n - 1] / 1000.0, 0.01), "wallFrameMs": snappedf(wall, 0.01),
		"armies": [army_alive(0), army_alive(1)] if pvp else [army_alive(0)]}


## Серия кадров для приёмки вида (--dev shot_every=S --dev shot_count=C): с --shot-frame каждые
## S кадров, всего C, файлы «<путь>_f<кадр>.png»; без ключей — один кадр и выход, как раньше.
func _shot_due() -> bool:
	var every := maxi(1, int(dev.get("shot_every", 1)))
	var k := _frames - _shot_frame
	# shot_count=0 — как без ключа: один кадр и выход (раньше k < 0 не выполнялось никогда —
	# ни кадра, ни выхода, игра висела)
	return k % every == 0 and k < every * maxi(1, int(dev.get("shot_count", 1)))


func _take_shot() -> void:
	var count := maxi(1, int(dev.get("shot_count", 1)))
	var every := maxi(1, int(dev.get("shot_every", 1)))
	var path := _shot_path
	if count > 1:
		path = "%s_f%05d.png" % [_shot_path.trim_suffix(".png"), _frames]
	var last := _frames >= _shot_frame + every * (count - 1)
	# кадр PvP — поле целиком: камеру вписывает сам вид поля (_apply_view, P5a)
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var err := img.save_png(path)
	print(JSON.stringify({"shot": path, "error": err}))
	if last:
		get_tree().quit()


# ── Отрисовка: серая земля и эффекты ────────────────────────────────────────

func _draw() -> void:
	if map.is_empty() or _ground != null:
		return
	_draw_ground()


func _draw_ground() -> void:
	draw_rect(Rect2(Vector2.ZERO, world_size), C_GROUND)
	for poly in terrain.swamp:
		draw_colored_polygon(poly, C_SWAMP)
	for r in map.get("roads", []):
		var pts := road_path(String(r.get("id", "")))
		if pts.size() >= 2:
			draw_polyline(pts, C_ROAD, ROAD_W, true)
	for poly in terrain.water:
		draw_colored_polygon(poly, C_WATER)
	for poly in terrain.bridges:
		draw_colored_polygon(poly, C_BRIDGE)
	for poly in terrain.rocks:
		draw_colored_polygon(poly, C_ROCK)
		var closed := poly.duplicate()
		closed.append(poly[0])
		draw_polyline(closed, C_ROCK.lightened(0.25), 2.0, true)


func _draw_fx() -> void:
	_draw_breaches()
	# печать нотариуса и Юрист (v17 LAW): телеграфы рисует сам враг — foe.gd; нить «кто бросает
	# печать» — не больше STAMP_LINK_MAX нотариусов, ближние к Котлу (slow/notary-read)
	var linked := StampThrower.owners(foes, cauldron_pos)
	for f in foes:
		if f.alive and f.type_id == "boss":
			f.draw_ram_warning(_fx)
		f.draw_stamp_warning(_fx, STAMP_COLOR, linked.has(f))
		f.draw_law_telegraph(_fx)
	_draw_tears()
	_draw_rallies()
	ability_aim.draw(_fx, aim_pos())
	projectiles.draw(_fx)
	for i in _impacts.size():
		var v := _impacts[i]
		var a := v.z / 0.3
		_fx.draw_circle(Vector2(v.x, v.y), _impact_r[i] * (1.2 - 0.2 * a), Color(1.0, 0.8, 0.5, 0.35 * a))
	# HP Котла прямо над ним: взгляд в бою не на краю экрана
	var k2 := clampf(cauldron_hp / maxf(1.0, cauldron_max), 0.0, 1.0)
	var tl := cauldron_view_pos + Vector2(-40.0, -LegionCfg.CAULDRON_DRAW_H - 14.0)
	_fx.draw_rect(Rect2(tl - Vector2(2, 2), Vector2(84, 10)), Color(0.05, 0.03, 0.08, 0.8))
	var fill := Color(0.35, 0.85, 0.45).lerp(Color(0.95, 0.25, 0.2), 1.0 - k2)
	_fx.draw_rect(Rect2(tl, Vector2(80.0 * k2, 6)), fill)
	for i in range(1, sides.size()):
		var s := sides[i]
		var ks := s.hp_frac()
		var at := s.cauldron_view_pos + Vector2(-40.0, -LegionCfg.CAULDRON_DRAW_H - 14.0)
		_fx.draw_rect(Rect2(at - Vector2(2, 2), Vector2(84, 10)), Color(0.05, 0.03, 0.08, 0.8))
		_fx.draw_rect(Rect2(at, Vector2(80.0 * ks, 6)),
			Color(0.35, 0.85, 0.45).lerp(Color(0.95, 0.25, 0.2), 1.0 - ks))


## Пустые места живых договоров — видно в trace, успевает ли набор за таянием.
func _empty_posts() -> int:
	var n := 0
	for c in contracts.contracts:
		n += c.free_posts()
	return n


## UI и клавиатура проходят одну проверку: бот и пауза не могут вызвать волну.
func call_wave() -> int:
	# PvP: волны общие по часам — вызвать раньше нельзя никому (DESIGN §2.1)
	if pvp or _ground_loading or not contracts.human_input or wave_runner == null:
		return -1
	return wave_runner.call_next()


## Точка at — длина ломаной, а не расстояние по прямой до ворот.
func road_remainder(road: String, at: float) -> PackedVector2Array:
	var path := road_path(road)
	if path.is_empty():
		return path
	var left := maxf(0.0, at)
	for i in range(1, path.size()):
		var length := path[i - 1].distance_to(path[i])
		if length > 0.0 and left < length:
			var rest := PackedVector2Array([path[i - 1].lerp(path[i], left / length)])
			rest.append_array(path.slice(i))
			return rest
		left -= length
	return PackedVector2Array([path[-1]])


func breach_data(id: String) -> Dictionary:
	for entry: Dictionary in map.get("breaches", []):
		if String(entry.get("id", "")) == id:
			return entry
	return {}


func breach_pos(id: String) -> Vector2:
	var entry := breach_data(id)
	var path := road_remainder(String(entry.get("road", "")), float(entry.get("at", 0.0)))
	return path[0] if not path.is_empty() else Vector2.ZERO


func warn_breach(id: String, in_s: float, summary: Array) -> void:
	_breach_marks.append({"id": id, "left": in_s, "summary": summary.duplicate(true)})
	breach_warned.emit(id, in_s, summary)
	toast("Трещина у поворота дрожит…", &"wave")
	# Подходящей записи в текущем наборе нет: новые файлы и чужие реплики не подменяем.


func _draw_breaches() -> void:
	var font := ThemeDB.fallback_font
	var size := PvpView.fs(self, LegionCfg.WAVE_PREVIEW_FONT)   # B-303
	for mark in _breach_marks:
		var pos := breach_pos(String(mark["id"]))
		var pulse := 0.65 + 0.25 * sin(now * LegionCfg.BREACH_MARK_PULSE_SPEED)
		var color := LegionCfg.BREACH_MARK_COLOR
		_fx.draw_circle(pos, LegionCfg.BREACH_MARK_RADIUS, Color(color, 0.25 * pulse))
		# Контур поверх заливки: на кадре приёмки 25.09 одна заливка тонула в лаве подложки.
		_fx.draw_arc(pos, LegionCfg.BREACH_RING_RADIUS * (0.85 + 0.15 * pulse), 0.0, TAU, 40,
			Color(color, LegionCfg.BREACH_RING_ALPHA * pulse), LegionCfg.BREACH_RING_WIDTH, true)
		var crack := PackedVector2Array()
		for point: Vector2 in LegionCfg.BREACH_MARK_POINTS:
			crack.append(pos + point)
		_fx.draw_polyline(crack, Color(color, pulse), LegionCfg.BREACH_MARK_WIDTH, true)
		var label := "Трещина · %d с" % ceili(float(mark["left"]))
		var parts := PackedStringArray()
		for g: Dictionary in mark["summary"]:
			parts.append("%s ×%d" % [foe_caption(String(g["type"])), int(g["count"])])
		var composition := " · ".join(parts)
		var width := maxf(font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x,
			font.get_string_size(composition, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x)
		var margin := LegionCfg.BREACH_MARK_MARGIN
		var line_height := LegionCfg.BREACH_MARK_LINE_HEIGHT
		var top := pos + LegionCfg.BREACH_MARK_LABEL_OFFSET
		# Тёмная подложка сохраняет предупреждение читаемым даже на лаве и вспышке Котла.
		_fx.draw_rect(Rect2(top, Vector2(width + margin * 2, line_height * 2 + margin)),
			LegionCfg.BREACH_MARK_BG)
		_fx.draw_string(font, top + Vector2(margin, line_height), label,
			HORIZONTAL_ALIGNMENT_LEFT, -1, size, color)
		_fx.draw_string(font, top + Vector2(margin, line_height * 2), composition,
			HORIZONTAL_ALIGNMENT_LEFT, -1, size, color)


static func foe_caption(type: String) -> String:
	var names := {"zombie": "● Зомби", "beetle": "◆ Курьер", "signer": "■ Нотариус",
		"ghost": "◇ Призрак", "mimic": "■ Мимик", "boss": "★ Прораб",
		"shield_inspector": "▣ Инспектор", "lawyer": "§ Юрист"}
	return String(names.get(type, type))


## v17 LAW: разрыв участка — рваная красная линия по его ломаной, гаснет за LAWYER_TEAR_FX.
func _draw_tears() -> void:
	for tear in _tears:
		var a := float(tear["t"]) / LegionCfg.LAWYER_TEAR_FX
		var poly: PackedVector2Array = tear["poly"]
		var jag := PackedVector2Array()
		for i in poly.size() - 1:
			var p0 := poly[i]
			var p1 := poly[i + 1]
			var n := (p1 - p0).orthogonal().normalized()
			var steps := maxi(2, int(p0.distance_to(p1) / 8.0))
			for k in steps:
				var side := 1.0 if k % 2 == 0 else -1.0
				jag.append(p0.lerp(p1, float(k) / steps) + n * side * 5.0 * (1.5 - a))
		jag.append(poly[poly.size() - 1])
		_fx.draw_polyline(jag, Color(LegionCfg.LAWYER_TEAR_COLOR, a), 3.0 + 3.0 * a, true)
		_fx.draw_polyline(poly, Color(1.0, 0.95, 0.8, 0.6 * a * a), 8.0 * a, true)


func _track_damage(before: Dictionary, dt: float) -> void:
	var damaged := false
	for key in before.keys():
		# Дубль-вэ освобождает свежий труп раньше уборки мира: ключ остаётся, объект — нет
		# (repro Astra 25.09: SCRIPT ERROR «freed instance» в _track_damage после W).
		if not is_instance_valid(key):
			before.erase(key)
			continue
		var f := key as Foe
		if f.hp < float(before[key]):
			damaged = true
		before[key] = f.hp
	if damaged and float(stats["first_contact_t"]) < 0.0:
		stats["first_contact_t"] = now
	# Длина текущего затишья отличает ходьбу от коротких пауз между ударами.
	stats["no_dmg_s"] = 0.0 if damaged else float(stats["no_dmg_s"]) + dt


func _tick_breach_marks(dt: float) -> void:
	# Отсчёт предупреждения использует то же игровое время и held, что и расписание.
	if not wave_runner.held:
		for i in range(_breach_marks.size() - 1, -1, -1):
			_breach_marks[i]["left"] = float(_breach_marks[i]["left"]) - dt
			if float(_breach_marks[i]["left"]) <= 0.0:
				_breach_marks.remove_at(i)
