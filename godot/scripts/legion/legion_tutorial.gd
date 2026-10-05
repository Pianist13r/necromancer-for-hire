# gdlint: disable=max-public-methods,max-file-lines
# Уроки — один движок на все карты: метки, бот и тесты читают его цели (target_*), поэтому
# публичных методов много; плашка, бот и шаблоны фигур уже вынесены в свои файлы.
class_name LegionTutorial
extends RefCounted
##
## Уроки карты (кампания v20, docs/legion/CAMPAIGN_V20.md, решение D-0926-46; таблица —
## docs/legion/TUTORIAL_SPEC.md). Игорь 26.09: «все эти элементы постепенно в игре вводились и
## обучались тоже постепенно… первые два-три уровня». Сами уроки — данные: поле `lessons` в JSON
## карты, `[{id, when, text, done, mark, hold, voice}]`:
##   when — `start` (урок начала боя, по порядку) | `wave:N` | `first_foe:<тип>` | `first_elite`
##          | `pressed` (участок продавливают — пора «пружины» и Е);
##   done — сигнал мира, которым урок зачтён (разбор — _KINDS ниже): `contract_created[:вид]`,
##          `aimed`, `contract_refreshed`, `segment_released`, `perfect`, `spring_released`,
##          `rally_used`, `building_built[:вид]`, `hero_cast:Q|W|E`,
##          `figure_made:ring|eight|triangle|square`,
##          `item_gained`, `stunned_charge`, `tab_erased` (Таб над линией с бойцами);
##   mark — метка на поле: `line` (светящаяся дорожка), `plot` (площадка), `figure`+`at`+`r`
##          (шаблон фигуры), `road` (откуда идут учебные зомби); без mark — метка по виду урока;
##   hold — `true`: волны ждут, пока урок не зачтён (обучение «Пустыря»); число — ждут не дольше
##          стольких секунд; нет — волны идут. Держит только урок начала боя.
## Обучение «Пустыря» — это просто уроки карты 1 (пять шагов: линия, подновление, рогатка,
## Бытовка, Ку); стрелка, «Сбор», фигуры, Дубль-вэ и Е переехали на следующие карты.
##
## Правила v16 (25.09.2026, «его невозможно пройти…») остаются в силе для каждого урока:
## - зачёт — только настоящее действие игрока через сигналы мира; ни одного таймера;
## - материал урока восполняется, пока урок не зачтён: мана, живая линия, учебные зомби,
##   свободные бойцы «Сбора», души постройки, откат своей способности, свежий труп Дубль-вэ;
##   пока урок держит волну, Котёл не проседает — поражение посреди урока было бы тупиком.
##   Урок посреди боя (не держит волну) даром зовёт только откат способности и души постройки —
##   по разу за бой: бой идёт, чужих зомби и маны не подбрасываем;
## - урок посреди боя — по ситуации СЕЙЧАС (D-0927-54, находка B-084): стоит на плашке, пока
##   есть его условие (present: повод + то, на чём учить), и гаснет, если условия нет
##   LessonsCfg.WITHDRAW_T с подряд, а урок не сделан; встанет снова, когда условие вернётся.
##   Уже сделанное (постройка стоит, предмет в руках) засчитывается без плашки;
## - бот (`world.bot != null`) проходит уроки теми же действиями через API мира (LegionLessonBot);
## - подсказки промахов — тостом под плашкой.
## Урок, зачтённый или пропущенный, не показывается снова: флаг `lesson_<карта>_<id>` в
## сохранении (Campaign.hint_seen). Вне кампании (`--map`, гейт, серии) уроки не идут вовсе —
## их зовёт LegionMain; бой бота от них не зависит (tests/legion_lessons_test.gd сверяет трассу).
##
## Живёт как RefCounted, тикается миром явно (world._step -> tutorial.tick), тем же паттерном,
## что WaveRunner и LegionBot. Узлы — только плашка (CanvasLayer) и метки (Node2D в мире).
##

signal step_changed(index: int)
signal finished

const FOE_TYPE := "zombie"  # учебный «проверяющий» — обычный зомби, отдельного вида не нужно
const WASTELAND_MAP_ID := "wasteland"  # карта обучения — используют legion_world.gd/legion_main.gd
## Флаг «урок пройден» в сохранении: lesson_<карта>_<id>.
const FLAG_FMT := "lesson_%s_%s"
## done → вид урока: по виду движок выбирает материал, метку, зачёт и действие бота.
const _KINDS := {
	"contract_created": &"draw", "aimed": &"aim", "contract_refreshed": &"refresh",
	"segment_released": &"release", "perfect": &"perfect", "spring_released": &"spring",
	"rally_used": &"rally", "building_built": &"build", "figure_made": &"figure",
	"item_gained": &"item", "stunned_charge": &"stun_hit", "tab_erased": &"erase",
	# D-1002: фигура выпущена ЗАРЯЖЕННОЙ (урок кончается действием игрока, а не контуром),
	# фигура выпущена рогаткой по одной группе, фигура мини-размера
	"figure_ult": &"figure_ult", "figure_slung": &"figure_slung", "figure_mini": &"figure_mini",
}
## Уроки-фигуры: штрих шаблона, запас армии и зачёт (значение `done` головой вида).
const FIGURE_KINDS: Array[StringName] = [&"figure", &"figure_ult", &"figure_mini",
	&"figure_slung"]
const _HERO_KINDS := {"Q": &"hero_q", "W": &"hero_w", "E": &"hero_e"}

const TEXT_DONE := "Обучение пройдено — держите Котёл!"
## Подсказки промахов — тостом под плашкой, не поверх задания.
const HINT_FAR := "Далеко от бойцов: договор набирает только рядом. Ведите по светящейся линии."
const HINT_SHORT := "Коротковато: протяните договор через всю дорогу, по светящейся линии."
const HINT_PLOT := "Нажмите на площадку с кольцом."
const HINT_EARLY := "Сначала дайте бойцам встать в строй на линии."
const HINT_REDRAW := "Договор растаял без бойцов. Начертите его заново по светящейся линии."
const HINT_KIND := "Здесь нужен Подряд — нажмите 1 и ведите по светящейся линии."
const HINT_NEW_LINE := "Это новая линия. Ведите прямо по своей — тогда она продлится."
const HINT_RALLY := "В круге никого: наведите на свободных бойцов и зажмите Эр."
const HINT_NO_LINE := "Сначала начертите договор: зажмите ЛКМ и ведите."
const HINT_NOT_PRESSED := "Е бережёт строй, когда его продавливают, — нажмите, пока дуга красная."

## Стрелка засчитана, если игрок повернул её хотя бы на столько от той, что была на входе в урок:
## нажатие Пробела с курсором ровно по стрелке ещё не показывает, что она ходит за мышью.
const AIM_TURN_DEG := 25.0
## На уроках стрелки и подновления линия не тает: возраст её живых участков держим не выше этой
## доли срока. Не ноль — игрок видит, что договор выцветает и что подновление вернуло яркость.
const LINE_AGE_CAP := 0.5
## Свободных бойцов для «Сбора» не осталось (всё в строю и никто не бежит в натиск) — столько
## подрядчиков выходит у Котла. Штат Котла сам возрождает павших, это — только от тупика.
const RALLY_SPARE := 3
## Реплики, чей ТЕКСТ урока изменился в D-1002 (углы, подготовка, мини): старая запись говорит
## прежнее правило и до переозвучки молчит — урок показывает только текст. Список ведёт
## координатор: после записи новых файлов (tools/voice/lines.tsv, те же id) строки убираются.
const STALE_VOICE: Array[StringName] = []
## Где кучнее всего свои (цель «Сбора» и «Аврала»): соседи в этой доле радиуса способности.
const CLUSTER_FRAC := 0.5

var world: LegionWorld = null
var active := false
## Уроки этого боя (разобранные, см. parse); пройденные — в _passed.
var lessons: Array[Dictionary] = []
## Бот уже сделал разовое действие этого урока (линию, поворот, фигуру).
var bot_done := false
## world.now, когда текущий урок встал на плашку (LegionIntuit.muted: первые секунды урока
## советы молчат все, дальше — только те, что спорят с уроком, B-081).
var entered_at := 0.0

var _step := -1
var _banner: LegionLessonBanner = null
## Вводный тост карты уже погашен первым уроком начала боя (один раз за запуск уроков).
var _brief_toast_dropped := false
var _marks: LegionTutorialMarks = null
var _main: Contract = null
## Урок зачтён сигналом мира; переход — в tick (тот же кадр, до бота).
var _credit := false
var _passed: Dictionary = {}
## Уроки, чей повод уже случился, а плашка занята другим: встанут следом (индексы lessons).
var _armed: Array[int] = []
## Стрелки договоров на входе в урок «стрелка» (Contract -> Vector2) — от них меряем поворот.
var _aim_base: Dictionary = {}
var _built_at := 0
## Сколько душ урок постройки ещё может подарить: цена одной постройки на урок. Доливать каждый
## кадр без предела нельзя — строй-продавай давал 600 душ возврата за полминуты, а при старте с
## 60 душами застраивались все площадки (проверяющий 27.09, зонды vv2_misc/vv_souls).
## id урока -> души, которые он ещё может подарить (урок посреди боя встаёт и гаснет не раз, а
## подарок — один на бой).
var _build_gifts: Dictionary = {}
## Уроки посреди боя, уже снявшие откат своей способности (id -> true): снова вставший урок
## второй раз откат не снимает, иначе прогиб туда-сюда давал бы бесконечные Е.
var _cd_gifted: Dictionary = {}
## Уроки посреди боя, чья реплика уже звучала в этом бою: снова вставший урок молчит.
var _voiced: Dictionary = {}
## Следующая подсыпка свободных к пустым углам фигуры урока (_staff_figure), секунды боя.
var _staff_t := 0.0
## Сколько подрядчиков урок фигуры уже вывел у Котла из тупика (не больше порога заряда).
var _staff_spawned := 0
var _perfect_at := 0
var _plot: Dictionary = {}
var _foes: Array[Foe] = []
## Когда последний раз показана каждая подсказка промаха (текст -> world.now).
var _hint_at: Dictionary = {}
var _skip_requested := false
var _hold_on := false
var _hold_left := 0.0
## Сколько секунд подряд у урока посреди боя нет его условия (LessonsCfg.WITHDRAW_T).
var _absent_t := 0.0
## id урока -> world.now, когда он ушёл с плашки незачтённым (LessonsCfg.REAPPEAR_T).
var _withdrawn_at: Dictionary = {}


# ── Данные ─────────────────────────────────────────────────────────────────

## Уроки карты из её JSON в рабочем виде: {id, when, start, text, voice, done, kind, arg, hold,
## mark}. Урок с непонятным `done` пропускается с предупреждением — лучше без урока, чем тупик.
static func parse(map: Dictionary) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for raw: Variant in map.get("lessons", []):
		if not raw is Dictionary:
			continue
		var d: Dictionary = raw
		var done := String(d.get("done", ""))
		var head := done.get_slice(":", 0)
		var arg := done.get_slice(":", 1) if done.contains(":") else ""
		var kind: StringName = _KINDS.get(head, &"")
		if head == "hero_cast":
			kind = _HERO_KINDS.get(arg, &"")
		if kind == &"":
			push_warning("LegionTutorial: урок %s — непонятный done «%s»" % [d.get("id", "?"), done])
			continue
		var hold: Variant = d.get("hold", false)
		var when := String(d.get("when", "start"))
		out.append({
			"id": StringName(String(d.get("id", ""))), "when": when, "start": when == "start",
			"text": String(d.get("text", "")), "voice": StringName(String(d.get("voice", ""))),
			"done": done, "kind": kind, "arg": arg, "mark": d.get("mark", {}),
			# держит волну только урок начала боя: посреди боя волна уже идёт
			"hold": 0.0 if when != "start" else (INF if hold is bool and hold
				else (float(hold) if hold is float or hold is int else 0.0)),
		})
	return out


static func flag(map_id: String, id: StringName) -> StringName:
	# Урок перенесён на берег «Моста»: старый зачёт в «Лабиринте» сохраняет силу.
	if map_id == "bridge" and id == &"triangle":
		map_id = "maze"
	return StringName(FLAG_FMT % [map_id, String(id)])


## Уроки карты, ещё не пройденные в этом сохранении (force — все).
static func pending(map_id: String, map: Dictionary, force := false) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if not force and map_id == WASTELAND_MAP_ID and Campaign.tutorial_done():
		# обучение «Пустыря» пройдено или пропущено (в том числе старым обучением до v20, без
		# флагов уроков) — само не предлагается, только кнопкой «Обучение»
		return out
	if not force and Campaign.stars(map_id) > 0:
		# карта уже выиграна (в том числе до v20) — её уроки считаются пройденными: удержание
		# волн и подсказки на знакомой карте мешали бы (проверяющий 27.09, сохранение владельца)
		return out
	for l in parse(map):
		if force or not Campaign.hint_seen(flag(map_id, l["id"])):
			out.append(l)
	return out


## Карта учит этому поводу (`first_foe:lawyer` …) — разовые подсказки LegionMapHints молчат.
static func map_covers(map: Dictionary, when: String) -> bool:
	for l in parse(map):
		if l["when"] == when:
			return true
	return false


# ── Жизнь ──────────────────────────────────────────────────────────────────

func setup(w: LegionWorld, list: Array[Dictionary] = []) -> void:
	world = w
	lessons = list if not list.is_empty() else pending(w.map_id, w.map, true)
	active = true
	_skip_requested = false
	_step = -1
	_passed.clear()
	_armed.clear()
	_build_gifts.clear()
	_cd_gifted.clear()
	_voiced.clear()
	_withdrawn_at.clear()
	world.contract_created.connect(_on_contract_created)
	world.segment_released.connect(_on_segment_released)
	world.tab_erased.connect(_on_tab_erased)
	world.hero_cast.connect(_on_hero_cast)
	world.contract_refreshed.connect(_on_contract_refreshed)
	world.rally_used.connect(_on_rally_used)
	world.building_changed.connect(_on_building_changed)
	world.spring_released.connect(_on_spring_released)
	world.stunned_charge_hit.connect(_on_stunned_hit)
	world.items.gained.connect(_on_item_gained)
	world.contracts.tap.connect(_on_tap)
	world.contracts.aimed.connect(_on_aimed)
	world.contracts.figure_made.connect(_on_figure_made)
	world.figure_ult.connect(_on_figure_ult)
	world.figure_slung.connect(_on_figure_slung)
	_banner = LegionLessonBanner.new(world)
	world.add_child(_banner)
	_marks = LegionTutorialMarks.new(self)
	world.add_child(_marks)
	_next()


## Мир зовёт из _step() ровно там, где раньше звал wave_runner/bot — тот же порядок кадра.
func tick(dt: float) -> void:
	if not active:
		return
	if _skip_requested:
		_finish(false)
		return
	if _hold_on:
		# Котёл не проседает, пока урок держит волну: учебный зомби, дошедший до Котла, пока
		# игрок читает, не должен довести до поражения посреди урока
		world.cauldron_hp = world.cauldron_max
		_hold_left -= dt
		if _hold_left <= 0.0:
			_set_hold(false, 0.0)
	_scan_triggers(dt)
	if _step < 0 or not active:
		return
	if _credit:
		_complete()
		return
	if step_kind() == &"perfect" and _taught_perfects() > _perfect_at:
		# «Точно!» — любым выпуском: рогаткой, щелчком по золотому, кольцом или фигурой; не Табом
		_complete()
		return
	if not _tick_material(dt) and active and world.bot != null:
		LegionLessonBot.act(self)


## «Точно!» тем действием, которому учит урок, — щелчком или рогаткой (кольцом, фигурой). Таб
## кусок срывает целиком, и золотой сосед давал «Точно!» без щелчка по золоту (verifier
## slow/tab-erase): его «Точно!» в бою остаются, но урок их не засчитывает.
func _taught_perfects() -> int:
	return int(world.stats.get("perfect_releases", 0)) - world.tab_perfect_releases


## Урок держит волну прямо сейчас (плашка HUD «обучение», элитные не выпадают).
func holding() -> bool:
	return active and _hold_on


## Нужен гарантированный предмет: урок «элитный и предмет» ещё не зачтён.
func wants_item() -> bool:
	if not active:
		return false
	for l in lessons:
		if l["kind"] == &"item" and not _passed.has(l["id"]):
			return true
	return false


## Пропустить уроки (пункт паузы) — считаются пройденными, чтобы не предлагались заново.
func skip() -> void:
	_skip_requested = true


## Номер текущего урока в lessons (-1 — плашка пуста: ждём повода).
func step() -> int:
	return _step


func step_id() -> StringName:
	return lessons[_step]["id"] if _step >= 0 else &""


func step_kind() -> StringName:
	return lessons[_step]["kind"] if _step >= 0 else &""


func lesson() -> Dictionary:
	return lessons[_step] if _step >= 0 else {}


## Номер урока по id (-1 — нет такого).
func index_of(id: StringName) -> int:
	for i in lessons.size():
		if lessons[i]["id"] == id:
			return i
	return -1


func passed(id: StringName) -> bool:
	return _passed.has(id)


## Текст плашки урока с числами из LegionCfg (ранг способности — текущий).
func step_text(i: int) -> String:
	var text := Controls.text(String(lessons[i]["text"]))
	if not text.contains("%d"):
		return text
	match lessons[i]["kind"]:
		&"hero_w":
			var r := world.hero.rank(LegionHero.SLOT_W) if world.hero != null else 0
			return text % roundi(float(LegionCfg.W_DURATION_BY_RANK[r]))
		&"hero_e":
			var r := world.hero.rank(LegionHero.SLOT_E) if world.hero != null else 0
			# та же формула, что LegionHero._cast_e
			var dur := minf(LegionCfg.E_DURATION_BASE + LegionCfg.E_DURATION_RANK_STEP * r
					+ LegionCfg.E_DURATION_PERK_BONUS * world.camp_stat(&"perk_overtime"),
				LegionCfg.E_DURATION_CAP)
			return text % roundi(dur)
	return text


## Прямоугольник плашки на экране (тест: тосты его не пересекают). Пустой — плашки нет.
func banner_rect() -> Rect2:
	if _banner == null or not is_instance_valid(_banner):
		return Rect2()
	return _banner.rect()


## --dev lesson=<id>, tutorial_step=N и тесты — поставить урок так, как его видит игрок: прошлые
## уроки начала боя пройдены; урокам про живую линию на ней уже стоит договор (бесплатно).
func force_lesson(id: StringName) -> void:
	var idx := index_of(id)
	if idx < 0:
		return
	_passed.clear()
	for k in idx:
		if lessons[k]["start"]:
			_passed[lessons[k]["id"]] = true
	_armed.erase(idx)
	if lessons[idx]["kind"] in [&"aim", &"refresh", &"release", &"erase", &"perfect", &"spring",
			&"stun_hit"] \
			and world.contracts.contracts.is_empty():
		# _step=idx ДО add_contract(): иначе _on_contract_created засчитал бы урок линии сам
		_step = idx
		_lay_line()
	_enter(idx)


## Старый вход приёмки (1-based номер урока по порядку).
func force_step(i: int) -> void:
	if i >= 0 and i < lessons.size():
		force_lesson(lessons[i]["id"])


func _enter(i: int) -> void:
	_step = i
	entered_at = world.now
	_credit = false
	bot_done = false
	_staff_spawned = 0
	_absent_t = 0.0
	var l := lessons[i]
	var again: bool = not l["start"] and _voiced.has(l["id"])
	match l["kind"]:
		&"draw":
			_main = null
			# вид договора переживает restart()/start_map(): после 2/3 штрих по призраку набирал
			# бы вахтёров/счетоводов, а подсказка врала бы «далеко». Урок учит нужный вид сам.
			world.contracts.set_kind(_draw_kind())
		&"aim":
			_aim_base.clear()
			for c in world.contracts.contracts:
				_aim_base[c] = c.dir
		&"release", &"hero_q":
			if float(l["hold"]) > 0.0:
				_restock()
		&"perfect":
			_perfect_at = _taught_perfects()
			if float(l["hold"]) > 0.0:
				_restock()
				_cover_road()
				_recall_free()
		&"build":
			_built_at = int(world.stats.get("buildings_built", 0))
			if not _build_gifts.has(l["id"]):
				_build_gifts[l["id"]] = LegionStaff.build_price(_build_kind())
			_plot = _pick_plot()
	_set_hold(float(l["hold"]) > 0.0, float(l["hold"]))
	if _hold_on and FIGURE_KINDS.has(l["kind"]):
		# Выбор вида переживает прошлую карту; учебный штат и шаблон — подрядчики.
		world.contracts.set_kind(LegionCfg.KIND_LABORER)
		_stock_figure_army()
	var slot := _slot_of(l["kind"])
	if slot >= 0 and world.hero != null and world.hero.is_unlocked(slot) \
			and (l["start"] or not _cd_gifted.has(l["id"])):
		# урок про способность: откат снят один раз — сразу можно попробовать (урок посреди
		# боя — один раз за бой, а не на каждый показ)
		world.hero._cd[slot] = 0.0
		_cd_gifted[l["id"]] = true
	if l["start"] and not _brief_toast_dropped and world.hud != null:
		# первый урок начала боя: вводный тост карты под плашкой — лишняя вторая плашка
		_brief_toast_dropped = true
		world.hud.drop_toasts()
	_banner.set_task(step_text(i), _counter(i))
	if not l["start"]:
		_voiced[l["id"]] = true
	if world.audio != null and not again:
		var voice: StringName = l.get("voice", &"")
		# Реплика, чей ТЕКСТ изменился (D-1002 §6), пока не переозвучена, молчит: старая запись
		# говорит прежнее правило и спорит с плашкой. Список снимается после переозвучки.
		if voice != &"" and not STALE_VOICE.has(voice):
			# Сюжет (LegionAudio.voice()): реплика урока не обрывает брифинг или прошлый урок на
			# полуслове — встаёт в очередь; более поздний урок заменяет в ней устаревший.
			world.audio.voice(voice, LegionCfg.AUDIO_V15_PRIORITY_HR, LegionAudio.VoiceClass.STORY)
		else:
			# урок без голоса: реплика прошлого, ещё ждущая в очереди, уже устарела
			world.audio.drop_tutorial_voice()
	step_changed.emit(i)


## «2/5» — у уроков начала боя (их проходят подряд); у уроков по поводу — пусто.
func _counter(i: int) -> String:
	if not lessons[i]["start"]:
		return ""
	var n := 0
	var at := 0
	for k in lessons.size():
		if lessons[k]["start"]:
			n += 1
			if k == i:
				at = n
	return "%d/%d" % [at, n] if n > 1 else ""


## Следующий урок: сперва непройденный урок начала боя, потом случившиеся поводы; нет — плашка
## прячется и ждёт повода; всё пройдено — конец.
func _next() -> void:
	for i in lessons.size():
		if lessons[i]["start"] and not _passed.has(lessons[i]["id"]):
			_enter(i)
			return
	while not _armed.is_empty():
		var i: int = _armed.pop_front()
		if present(lessons[i]):
			_enter(i)
			return
	_step = -1
	_set_hold(false, 0.0)
	if _passed.size() >= lessons.size():
		_finish(true)
	elif _banner != null:
		_banner.hide_task()


## Урок пройден: флаг в сохранение (не покажется снова) и дальше.
func _complete() -> void:
	var id: StringName = step_id()
	_passed[id] = true
	Campaign.mark_hint_seen(flag(world.map_id, id))
	_next()


## Условие урока посреди боя есть сейчас — урок встаёт в очередь; ушло — урок на плашке гаснет.
func _scan_triggers(dt: float) -> void:
	for i in lessons.size():
		var l := lessons[i]
		if l["start"] or _passed.has(l["id"]):
			continue
		if _done_already(l):
			_pass_quietly(i)
			if not active:
				return
			continue
		if i != _step and not _armed.has(i) and present(l) and not _reappear_wait(l):
			_armed.append(i)
	if _step >= 0 and not lessons[_step]["start"] and not _credit:
		# условие ушло, урок не сделан (прогиб выпрямился, бойцов забрал договор, Юриста добили
		# без Ку, способность в откате) — плашка гаснет и ждёт следующего раза
		_absent_t = 0.0 if present(lessons[_step]) else _absent_t + dt
		if _absent_t >= LessonsCfg.WITHDRAW_T:
			_withdraw()
			return
	# очередь: урок встаёт, только если его условие ещё в силе
	while _step < 0 and not _armed.is_empty():
		var i: int = _armed.pop_front()
		if present(lessons[i]):
			_enter(i)


## Урок с качающимся условием (LessonsCfg.REAPPEAR_KINDS) недавно ушёл с плашки — ещё рано
## показывать снова, иначе плашка мигает.
func _reappear_wait(l: Dictionary) -> bool:
	if not LessonsCfg.REAPPEAR_KINDS.has(l["kind"]):
		return false
	return world.now - float(_withdrawn_at.get(l["id"], -INF)) < LessonsCfg.REAPPEAR_T


## Урок посреди боя уходит с плашки незачтённым: реплика, ещё ждущая в очереди голоса, устарела.
func _withdraw() -> void:
	if _step >= 0:
		_withdrawn_at[lessons[_step]["id"]] = world.now
	_step = -1
	_absent_t = 0.0
	if world.audio != null:
		world.audio.drop_tutorial_voice()
	_next()


## Урок посреди боя стоит на плашке, только пока его условие есть сейчас (D-0927-54): повод
## (trigger_met) и то, на чём учить, — свободные бойцы для «Сбора», свежий труп для Дубль-вэ,
## готовая способность, пустая площадка.
func present(l: Dictionary) -> bool:
	if not trigger_met(l):
		return false
	match l["kind"]:
		&"rally":
			return world.rally_cd <= 0.0 and world.can_pay_ability(LegionCfg.RALLY_SLOT) \
				and idle_cluster() >= LessonsCfg.RALLY_MIN
		&"hero_w":
			return _slot_ready(l) and target_corpse() != null
		&"hero_q", &"hero_e":
			return _slot_ready(l)
		&"stun_hit":
			# есть кого сорвать — или Ку готова, чтобы оглушить
			return _slot_ready(l) or stunned_foe() != null
	return true


## То, чему учит урок посреди боя, уже сделано в этом бою (постройка этого вида стоит, предмет
## в руках) или учить нечему (все площадки застроены) — урок засчитан без плашки.
func _done_already(l: Dictionary) -> bool:
	match l["kind"]:
		&"build":
			var kind := _kind_of(l)
			for p in world.staff.plots:
				var b := p["building"] as LegionBuilding
				if b != null and b.kind == kind:
					return true
			return _pick_plot_for(l).is_empty()
		&"item":
			return world.items != null and not world.items.counts.is_empty()
	return false


func _pass_quietly(i: int) -> void:
	if i == _step:
		_complete()
		return
	var id: StringName = lessons[i]["id"]
	_passed[id] = true
	Campaign.mark_hint_seen(flag(world.map_id, id))
	_armed.erase(i)
	if _step < 0 and _passed.size() >= lessons.size():
		_finish(true)


## Способность урока готова: не в откате — или урок ещё не снимал откат в этом бою (снимет при
## показе). Способность закрыта — урок встаёт и тут же засчитывается (_ready_slot).
func _slot_ready(l: Dictionary) -> bool:
	var slot := _slot_of(l["kind"])
	if slot < 0 or world.hero == null or not world.hero.is_unlocked(slot):
		return true
	# D-0927-140: урок не зовёт жать способность, на которую нет маны (откат урок дарит сам,
	# ману — нет: посреди боя это была бы бесплатная способность)
	if not world.can_pay_ability(slot):
		return false
	return not _cd_gifted.has(l["id"]) or world.hero.cd_left(slot) <= 0.0


## Сколько свободных бойцов, простаивающих не меньше LegionCfg.IDLE_NOTICE_TIME, стоит в радиусе
## «Сбора» от самого окружённого из них (урок «Сбор»: есть кого собрать).
func idle_cluster() -> int:
	var pool: Array[Legionnaire] = []
	for u in world.units:
		if u.alive and u.state == Legionnaire.State.FREE \
				and u.idle_time >= LegionCfg.IDLE_NOTICE_TIME:
			pool.append(u)
	var best := 0
	var r2 := LegionCfg.RALLY_R * LegionCfg.RALLY_R
	for u in pool:
		var n := 0
		for v in pool:
			if u.position.distance_squared_to(v.position) <= r2:
				n += 1
		best = maxi(best, n)
	return best


func trigger_met(l: Dictionary) -> bool:
	var when := String(l["when"])
	var arg := when.get_slice(":", 1)
	match when.get_slice(":", 0):
		"wave":
			return world.wave_runner != null and world.wave_runner.wave_no() >= int(arg)
		"first_foe":
			return _nearest_foe(func(f: Foe) -> bool: return f.type_id == arg) != null
		"first_elite":
			return _nearest_foe(func(f: Foe) -> bool: return f.elite) != null
		"pressed":
			return not spring_target().is_empty()
	return false


func _set_hold(on: bool, secs: float) -> void:
	_hold_on = on
	_hold_left = secs
	if world != null and world.wave_runner != null:
		world.wave_runner.held = on


func _finish(completed: bool) -> void:
	var was_start := _step >= 0 and bool(lessons[_step]["start"])
	if _skip_requested:
		for l in lessons:
			Campaign.mark_hint_seen(flag(world.map_id, l["id"]))
	active = false
	_set_hold(false, 0.0)
	if world != null and world.map_id == WASTELAND_MAP_ID:
		Campaign.set_tutorial_done()
	# B-065: пройденное обучение не стирает из очереди реплику последнего шага (игрок прошёл шаг
	# быстрее реплики); прерванное и пропущенное — стирает
	_disconnect(completed and not _skip_requested)
	if _marks != null and is_instance_valid(_marks):
		_marks.queue_free()
	_marks = null
	var outro := String(world.map.get("lessons_outro", ""))
	if completed and outro != "" and _banner != null and is_instance_valid(_banner) \
			and (was_start or _all_start()):
		# плашка доживает сама: «пройдено» ~3 с, затем убирает себя
		_banner.play_outro(outro)
		_banner = null
	else:
		_teardown_ui()
	finished.emit()


func _all_start() -> bool:
	for l in lessons:
		if not l["start"]:
			return false
	return true


## Отписка сигналов и снос плашки — без отметки «пройдено» (зовёт world._clear() на рестарте
## карты и go_to_menu(), когда уроки прервали, а не прошли/пропустили).
func teardown() -> void:
	active = false
	if world != null and world.audio != null:
		# реплика урока, звучащая сейчас, — тоже прочь (конец боя, рестарт, меню)
		world.audio.end_tutorial_voice()
	if world != null and world.wave_runner != null and _hold_on:
		world.wave_runner.held = false
	_hold_on = false
	_disconnect()
	_teardown_ui()


func _disconnect(keep_voice := false) -> void:
	if world == null:
		return
	# конец уроков: их реплики, ждущие в очереди голоса, не звучат (кроме пройденного до конца)
	if world.audio != null and not keep_voice:
		world.audio.drop_tutorial_voice()
	for pair: Array in [[world.contract_created, _on_contract_created],
			[world.segment_released, _on_segment_released], [world.tab_erased, _on_tab_erased],
			[world.hero_cast, _on_hero_cast],
			[world.contract_refreshed, _on_contract_refreshed], [world.rally_used, _on_rally_used],
			[world.building_changed, _on_building_changed],
			[world.spring_released, _on_spring_released],
			[world.stunned_charge_hit, _on_stunned_hit],
			[world.figure_ult, _on_figure_ult], [world.figure_slung, _on_figure_slung]]:
		var sig: Signal = pair[0]
		if sig.is_connected(pair[1]):
			sig.disconnect(pair[1])
	if world.items != null and world.items.gained.is_connected(_on_item_gained):
		world.items.gained.disconnect(_on_item_gained)
	if world.contracts != null:
		for pair: Array in [[world.contracts.tap, _on_tap], [world.contracts.aimed, _on_aimed],
				[world.contracts.figure_made, _on_figure_made]]:
			var sig: Signal = pair[0]
			if sig.is_connected(pair[1]):
				sig.disconnect(pair[1])


func _teardown_ui() -> void:
	if _banner != null and is_instance_valid(_banner):
		_banner.queue_free()
	_banner = null
	if _marks != null and is_instance_valid(_marks):
		_marks.queue_free()
	_marks = null


# ── Материал: восполняется, пока урок не зачтён ─────────────────────────────

## true — урок сменился (откат к линии), бот в этом кадре не ходит.
## Пока урок держит волну — материал полный (мана, вечная линия, учебные зомби, свободные
## бойцы, откат каждый кадр). Урок посреди боя (волна идёт) даром даёт только души постройки и
## откат своей способности ОДИН раз при входе (_enter): иначе весь бой шёл с полной маной,
## нетающими линиями и бесконечными кастами (проверяющий 27.09, зонд vv_melt).
func _tick_material(dt: float) -> bool:
	var hold := _hold_on
	var moved := false
	_staff_t -= dt
	match step_kind():
		&"draw", &"figure", &"figure_ult", &"figure_mini", &"figure_slung":
			if hold:
				world.contracts.mana = world.contracts.mana_max
			# фигура урока должна встать: свободных подсыпаем к её пустым углам по ходу боя
			if FIGURE_KINDS.has(step_kind()) and _staff_t <= 0.0:
				_staff_t = 0.5
				_staff_figure()
		&"aim", &"refresh", &"erase":
			if hold:
				moved = _tick_line()
			elif world.contracts.contracts.is_empty():
				_hint(HINT_NO_LINE)
		&"release":
			if hold:
				_restock()
				moved = _need_line()
		&"perfect":
			if hold:
				_restock()
				_cover_road()
				# каждый кадр: натиск, сорванный мимо, кончается где угодно, а «Сбора» нет
				_recall_free()
				moved = _need_line()
				if not moved:
					_keep_line()
		&"rally":
			if hold:
				_tick_rally()
		&"build":
			moved = _tick_build()
		&"hero_q", &"stun_hit":
			if hold:
				_restock()
			moved = _ready_slot(LegionHero.SLOT_Q)
		&"hero_w":
			if hold:
				_restock_corpse()
			moved = _ready_slot(LegionHero.SLOT_W)
		&"hero_e":
			moved = _ready_slot(LegionHero.SLOT_E)
	return moved


## Фигура урока должна набрать строй без покупки здания. Размер берём из шаблона, а подкрепление
## выдаём только пока волна ждёт: обычный бой не получает подарков.
func _stock_figure_army() -> void:
	var shape := _lesson_figure()
	if shape == null or shape.figure == &"":
		return
	var have := 0
	for u in world.units:
		if u.alive and u.kind == LegionCfg.KIND_LABORER:
			have += 1
	for i in maxi(0, ContractField.fig_need(shape) - have):
		world.spawn_unit(LegionCfg.KIND_LABORER, world._near_cauldron())
	_staff_figure()


## Фигура урока должна набрать порог заряда. Зовётся при входе в урок и дальше подсыпается по
## ходу боя: бот мира чертит свои линии и уводит свободных на них, а фигура урока стоит не у
## самого Котла — её дальние углы вне радиуса набора, и строй набирал двух бойцов из четырёх,
## заряд не копился и урок стоял (находка прогона 05.10). Радиус набора и размер подарка
## остаются обычными: свободного ведём к пустому углу своим ходом, на 0,5 радиуса в сторону Котла.
func _staff_figure() -> void:
	var c := _lesson_figure_live()
	if c == null:
		return
	var need := maxi(1, c.charge_need())
	if need > 0 and c.posted_posts() >= need:
		return
	var radius := float(world.contracts.recruit_r.get(LegionCfg.KIND_LABORER, LegionCfg.RECRUIT_R))
	# Свободных не осталось (бот мира разобрал всех по своим линиям): пока волна ждёт, урок
	# выходит у Котла ровно столько подрядчиков, сколько не хватает до порога, — не больше need
	# за урок (иначе тупик: фигура не встанет, а бой идёт).
	var free: Array[Legionnaire] = []
	for u in world.units:
		if u.alive and u.kind == LegionCfg.KIND_LABORER and u.state == Legionnaire.State.FREE:
			free.append(u)
	if free.is_empty() and _hold_on:
		var lack := maxi(0, need - c.posted_posts() - _staff_spawned)
		for i in lack:
			world.spawn_unit(LegionCfg.KIND_LABORER, world._near_cauldron())
		_staff_spawned += lack
		for u in world.units:
			if u.alive and u.kind == LegionCfg.KIND_LABORER \
					and u.state == Legionnaire.State.FREE:
				free.append(u)
	var posts: Array = c.posts.duplicate()
	posts.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return (a["pos"] as Vector2).distance_to(world.cauldron_pos) \
			> (b["pos"] as Vector2).distance_to(world.cauldron_pos))
	for post: Dictionary in posts:
		if post["dead"] or post["unit"] != null or free.is_empty():
			continue
		var at: Vector2 = post["pos"]
		# вести надо ПОЧТИ к самому углу: у 0,5 радиуса боец вставал ближе к линии бота мира,
		# чем к углу, и раздача отдавала его чужой линии (находка прогона 05.10)
		var spot := world.terrain.nearest_open(
			at + (world.cauldron_pos - at).normalized() * maxf(24.0, radius * 0.15))
		if spot == Vector2.INF:
			continue
		var pick := -1
		var best := INF
		for i in free.size():
			var d := free[i].position.distance_to(spot)
			if d < best:
				best = d
				pick = i
		if pick < 0:
			continue
		var u: Legionnaire = free[pick]
		if u.position.distance_to(at) <= radius:
			continue   # уже в радиусе — раздача мест поставит его сама
		var path := world.contracts.recruit_path(u.position, spot)
		if not path.is_empty():
			free.remove_at(pick)
			u.rally_to(path)


## Живая фигура ТЕКУЩЕГО урока (по его `arg`); нет своей — самая требовательная из живых.
## Иначе на смене урока (тест/--dev lesson) бойцов подсыпали к прежней фигуре.
func _lesson_figure_live() -> Contract:
	var want := figure_kind_of(String(lesson().get("arg", "")))
	var best: Contract = null
	for k in world.contracts.contracts:
		if k.figure == &"" or not k.alive():
			continue
		if want != &"" and k.figure == want:
			return k
		if best == null or k.charge_need() > best.charge_need():
			best = k
	return best


## Фигура-шаблон урока по его `arg` (как её строит ContractField из штриха). null — вид не
## опознан. «mini» — та же крыша, только размер шаблона задаёт mark.r.
func _lesson_figure() -> Contract:
	var fig := figure_kind_of(String(lesson().get("arg", "")))
	var pts := figure_points()
	if pts.size() < 2:
		return null
	if fig == ContractShape.RING:
		return Contract.new().build_ring(pts, world.terrain.walkable, LegionCfg.KIND_LABORER)
	return Contract.new().build_figure(pts, fig, world.terrain.walkable, LegionCfg.KIND_LABORER)


## Вид фигуры по `arg` урока. «mini» — крыша (важен размер, а не вид); "ring" — кольцо (у него
## нет Contract.figure).
static func figure_kind_of(arg: String) -> StringName:
	match arg:
		"triangle", "mini":
			return ContractShape.TRIANGLE
		"square":
			return ContractShape.SQUARE
		"pentagon":
			return ContractShape.PENTAGON
		"d_shape":
			return ContractShape.D_SHAPE
		"eight":
			return ContractShape.EIGHT
		"ring":
			return ContractShape.RING
	return &""


## Урок постройки: души на цену (не больше одной постройки за урок), площадка отмечена. true —
## урок сменился.
func _tick_build() -> bool:
	var price := LegionStaff.build_price(_build_kind())
	var left := int(_build_gifts.get(step_id(), 0))
	if world.souls < price and left > 0:
		var gift := mini(price - world.souls, left)
		world.staff.add_souls(gift)
		_build_gifts[step_id()] = left - gift
	if _plot.is_empty() or _plot["building"] != null:
		_plot = _pick_plot()
	if _plot.is_empty():
		# все площадки застроены раньше урока — строить негде, учить нечему
		_complete()
		return true
	return false


## Уроки стрелки и подновления: мана полная, линия не тает. true — урок сменился (откат).
func _tick_line() -> bool:
	world.contracts.mana = world.contracts.mana_max
	if _need_line():
		return true
	_keep_line()
	return false


## Линия не тает, пока урок держит волну. На уроке «Точно!» игрок ждёт врага у строя, и таяние
## через 12 с откатывало его к уроку 1 «проведи договор» (B-090, кампания новичка 180f1168).
func _keep_line() -> void:
	for c in world.contracts.contracts:
		for s in c.seg_count():
			if c.seg_alive(s):
				c.seg_age[s] = minf(c.seg_age[s], c.ttl * LINE_AGE_CAP)


## Урок «Точно!»: живой строй должен стоять поперёк дороги учебных зомби. Урок натиска срывает
## участок — обычно тот, что на дороге, — и в линии остаётся дыра: зомби идут мимо, и «Точно!»
## не взять (B-090). Нет живого участка на дороге — линия урока ложится заново по светящейся
## дорожке (старая, лежащая на ней, расторгается: её бойцы встанут в новую). true — положил.
func _cover_road() -> bool:
	var ghost := ghost_points()
	var road := world.road_path(_road_id())
	if ghost.size() < 2 or road.size() < 2:
		return false
	for c in world.contracts.contracts:
		for s in c.seg_count():
			if c.seg_alive(s) and _poly_dist(c.seg_center(s), road) \
					<= world.contracts.seg_half_len(c, s) + LegionCfg.TUTORIAL_COVER_MARGIN:
				return false
	var mid := ghost[0].lerp(ghost[ghost.size() - 1], 0.5)
	for c: Contract in world.contracts.contracts.duplicate():
		if c.live_distance(mid) <= LegionCfg.TUTORIAL_COVER_MARGIN * 2.0:
			world.contracts.dismiss(c)
	if world.contracts.contracts.size() >= LegionCfg.MAX_CONTRACTS:
		return false
	_lay_line()
	return _main != null


static func _poly_dist(p: Vector2, poly: PackedVector2Array) -> float:
	var best := INF
	for i in range(1, poly.size()):
		best = minf(best, p.distance_to(Geometry2D.get_closest_point_to_segment(p, poly[i - 1], poly[i])))
	return best


## Урок «Точно!» учит ждать врага у строя. После урока натиска бойцы стоят свободными там, где
## натиск кончился, — на «Пустыре» это поворот дороги, и они рубили каждую пачку учебных зомби
## раньше строя, а «Сбор» на этой карте закрыт (B-090). Свободных вдали от строя (кроме резерва
## у Котла, D-0927-90) урок уводит за свою линию, как подвозит зомби и ману: строй доберёт их сам.
func _recall_free() -> void:
	var segs: Array[Dictionary] = []
	for c in world.contracts.contracts:
		for s in c.seg_count():
			if c.seg_alive(s):
				segs.append({"at": c.seg_center(s), "dir": c.dir})
	if segs.is_empty():
		return
	for u in world.units:
		if not u.alive or u.state != Legionnaire.State.FREE:
			continue
		if u.position.distance_to(world.cauldron_pos) <= LegionCfg.TUTORIAL_RECALL_KEEP_R:
			continue
		var best: Dictionary = segs[0]
		for sg in segs:
			if u.position.distance_squared_to(sg["at"]) < u.position.distance_squared_to(best["at"]):
				best = sg
		if u.position.distance_to(best["at"]) <= LegionCfg.TUTORIAL_RECALL_NEAR:
			continue
		var back: Vector2 = best["at"] - (best["dir"] as Vector2) * LegionCfg.TUTORIAL_RECALL_BACK
		var spot := world.terrain.nearest_open(back)
		if spot == Vector2.INF:
			continue
		var path := world.contracts.recruit_path(u.position, spot)
		if not path.is_empty():
			u.rally_to(path)


## Живых договоров нет: откат к уроку линии (если он есть у карты), иначе — бесплатная линия
## по метке урока или подсказка. true — урок сменился.
func _need_line() -> bool:
	if not world.contracts.contracts.is_empty():
		return false
	for i in _step:
		if lessons[i]["kind"] == &"draw" and lessons[i]["start"]:
			_hint(HINT_REDRAW)
			_passed.erase(lessons[i]["id"])
			_enter(i)
			return true
	if ghost_points().size() >= 2:
		_lay_line()
	else:
		_hint(HINT_NO_LINE)
	return false


func _lay_line() -> void:
	var pts := ghost_points()
	if pts.size() >= 2:
		world.contracts.set_kind(LegionCfg.KIND_LABORER)
		_main = world.contracts.add_contract(pts, world.contracts.default_side(pts), false)


## Урок «Сбор»: нужны свободные бойцы. Пока кто-то бежит в натиск, он скоро освободится сам.
func _tick_rally() -> void:
	var free := 0
	var busy := 0
	for u in world.units:
		if not u.alive:
			continue
		if u.state == Legionnaire.State.FREE:
			free += 1
		elif u.state == Legionnaire.State.CHARGE or u.state == Legionnaire.State.RALLY:
			busy += 1
	if free == 0 and busy == 0:
		for i in RALLY_SPARE:
			world.spawn_unit(LegionCfg.KIND_LABORER, world._near_cauldron())


## Уроки Ку/Дубль-вэ/Е: пока урок держит волну, откат своей способности нулевой каждый кадр
## (игрок мог нажать клавишу раньше, по пустому месту). Посреди боя откат снят один раз при
## входе в урок (_enter). Способность закрыта — учить нечему, урок пройден.
func _ready_slot(slot: int) -> bool:
	if world.hero == null or not world.hero.is_unlocked(slot):
		_complete()
		return true
	if _hold_on:
		world.hero._cd[slot] = 0.0
		# D-0927-140: урок держит волну и зовёт жать — маны на каст хватает всегда (как откат);
		# игрок, начертивший до урока длинные линии, не получит «мало маны» на первом касте
		var need := world.ability_mana(slot)
		world.contracts.mana = maxf(world.contracts.mana, minf(need, world.contracts.mana_max))
	return false


## Слот способности урока этого вида (-1 — урок не про способность).
static func _slot_of(kind: StringName) -> int:
	match kind:
		&"hero_q", &"stun_hit":
			return LegionHero.SLOT_Q
		&"hero_w":
			return LegionHero.SLOT_W
		&"hero_e":
			return LegionHero.SLOT_E
	return -1


# ── Цели меток и бота ───────────────────────────────────────────────────────

## Точки светящейся линии урока (мировые координаты): mark.line; у урока без своей дорожки
## (подновление, натиск «Пустыря») — дорожка урока линии этой карты.
func ghost_points() -> PackedVector2Array:
	var out := PackedVector2Array()
	var l := lesson()
	if not (l.get("mark", {}) as Dictionary).has("line"):
		for k in lessons:
			if (k["mark"] as Dictionary).has("line"):
				l = k
				break
	for p: Variant in (l.get("mark", {}) as Dictionary).get("line", []):
		out.append(Vector2(float(p[0]), float(p[1])))
	return out


## Шаблон фигуры урока — по нему бежит метка и чертит бот: {figure, at, r} из mark.
func figure_points() -> PackedVector2Array:
	var m: Dictionary = lesson().get("mark", {})
	var at: Array = m.get("at", [640, 360])
	var tpl := String(lesson().get("arg", ""))
	if tpl == "mini":
		tpl = "triangle"   # «mini» — та же крыша, только mark.r мал
	return LegionLessonBot.template(tpl, Vector2(float(at[0]), float(at[1])),
		float(m.get("r", 70.0)))


## Площадка, отмеченная кольцом на уроке постройки ({} — нет пустых).
func target_plot() -> Dictionary:
	return _plot


## Живой договор для уроков стрелки и подновления: договор урока линии, ушёл — любой живой.
func line_target() -> Contract:
	if _contract_alive(_main):
		return _main
	for c in world.contracts.contracts:
		if c.alive():
			return c
	return null


## Куда показывает значок ПКМ: {contract, seg} — самый людный живой участок (при равенстве —
## с большим числом мест); {} — живых нет. Людный, а не первый: короткий хвост на 4 места мог
## стоять пустым, и ПКМ по нему не выпускала бы никого.
func release_target() -> Dictionary:
	var list: Array[Contract] = []
	if _contract_alive(_main):
		list.append(_main)
	list.append_array(world.contracts.contracts)
	for c in list:
		var best := -1
		var best_score := -1
		for s in c.seg_count():
			if not c.seg_alive(s):
				continue
			var places := 0
			for p in c.posts:
				if int(p["seg"]) == s:
					places += 1
			var score := c.seg_manned(s) * 1000 + places
			if score > best_score:
				best_score = score
				best = s
		if best >= 0:
			return {"contract": c, "seg": best}
	return {}


## Самый прогнутый участок, прогнутый не меньше LessonsCfg.PRESS_TRIGGER: {contract, seg}; {}.
func spring_target() -> Dictionary:
	var out := {}
	var best := LessonsCfg.PRESS_TRIGGER
	for c in world.contracts.contracts:
		for s in c.seg_count():
			if c.seg_alive(s) and c.bend_frac(s) >= best:
				best = c.bend_frac(s)
				out = {"contract": c, "seg": s}
	return out


## Враг урока: Юрист/щитоносец из повода `first_foe`, элитный — у урока предмета, учебный
## зомби — у урока Ку в начале боя. Ближайший к Котлу. null — нет.
func target_foe() -> Foe:
	var l := lesson()
	var when := String(l.get("when", ""))
	if l.get("kind", &"") == &"item" or when == "first_elite":
		return _nearest_foe(func(f: Foe) -> bool: return f.elite)
	if when.begins_with("first_foe:"):
		var t := when.get_slice(":", 1)
		return _nearest_foe(func(f: Foe) -> bool: return f.type_id == t)
	var best: Foe = null
	var best_d := INF
	for f in _foes:
		if is_instance_valid(f) and f.alive:
			var d := f.position.distance_squared_to(world.cauldron_pos)
			if d < best_d:
				best_d = d
				best = f
	if best == null and not l.get("start", true):
		return _nearest_foe(func(_f: Foe) -> bool: return true)
	return best


## Оглушённый враг, ближайший к Котлу (урок «сорви по оглушённым»). null — нет.
func stunned_foe() -> Foe:
	return _nearest_foe(func(f: Foe) -> bool: return f.is_stunned())


func _nearest_foe(ok: Callable) -> Foe:
	var best: Foe = null
	var best_d := INF
	for f in world.foes:
		if not is_instance_valid(f) or not f.alive or not bool(ok.call(f)):
			continue
		var d := f.position.distance_squared_to(world.cauldron_pos)
		if d < best_d:
			best_d = d
			best = f
	return best


## Свежий труп врага под Дубль-вэ (ближайший к Котлу) — те же условия, что у LegionHero.
func target_corpse() -> Foe:
	var best: Foe = null
	var best_d := INF
	var list: Array = []
	list.append_array(world.foes)
	list.append_array(world._corpses)
	for n in list:
		var f := n as Foe
		if f == null or not is_instance_valid(f) or not f.is_fresh_corpse() \
				or f.has_meta(&"summoned") or not f.visible:
			continue
		var d := f.position.distance_squared_to(world.cauldron_pos)
		if d < best_d:
			best_d = d
			best = f
	return best


## Куда звать «Сбор»: свободный боец, у которого больше всего свободных соседей. INF — некого.
func rally_target() -> Vector2:
	return _cluster(LegionCfg.RALLY_R * CLUSTER_FRAC, true)


## Куда жать Е: продавливаемый участок, если он есть, иначе кучнее всего свои. INF — своих нет.
func aura_target() -> Vector2:
	var hit := spring_target()
	if not hit.is_empty():
		return (hit["contract"] as Contract).seg_center(int(hit["seg"]))
	return _cluster(LegionCfg.E_RADIUS * CLUSTER_FRAC, false)


# ── Сигналы мира: здесь и только здесь зачитываются уроки ───────────────────

func _on_contract_created(c: Contract) -> void:
	if not active:
		return
	match step_kind():
		&"draw":
			_judge_draw(c)
		&"aim":
			_aim_base[c] = c.dir
		&"refresh":
			# штрих ушёл мимо своей линии (поперёк, вдали) и стал новым договором
			_hint(HINT_NEW_LINE)


## Штрих поверх живого договора — продление, а не новый договор (ContractField.finish). На
## уроке линии он не должен пропадать молча: продлённый договор годится — зачёт, нет — снять и
## подсказать. На уроке «подновление» это и есть урок.
func _on_contract_refreshed(c: Contract, _segs: PackedInt32Array) -> void:
	if not active:
		return
	match step_kind():
		&"draw":
			_judge_draw(c)
		&"refresh":
			_credit = true


## Зачёт урока линии или отказ. У урока с дорожкой (mark.line) неподходящий договор снимается
## без натиска: живой короткий/дальний договор глотал следующий полный штрих по дорожке как
## продление — послушный игрок застревал (ревью 25.09).
func _judge_draw(c: Contract) -> void:
	if not lesson()["mark"].has("line"):
		if c.kind == _draw_kind():
			_main = c
			_credit = true
		return
	var why := ""
	if c.kind != _draw_kind():
		why = HINT_KIND
	elif c.posts.size() < LegionCfg.TUTORIAL_MIN_POSTS:
		why = HINT_SHORT
	elif _in_reach(c) < LegionCfg.TUTORIAL_MIN_MANNED:
		# договор набирает только в радиусе RECRUIT_R — линия, до которой армии не дотянуться,
		# оставила бы урок натиска без бойцов. Точно по дорожке чертить не обязательно.
		why = HINT_FAR
	if why != "":
		world.contracts.dismiss(c)
		_hint(why)
		return
	_main = c
	_credit = true


## Урок «стрелка»: Пробел или колесо повернули стрелку живого договора. Засчитан поворот не
## меньше AIM_TURN_DEG от стрелки на входе в урок.
func _on_aimed(c: Contract) -> void:
	if not active or step_kind() != &"aim" or not c.alive():
		return
	var base: Vector2 = _aim_base.get(c, c.dir)
	if absf(rad_to_deg(base.angle_to(c.dir))) >= AIM_TURN_DEG:
		_credit = true


## Урок «натиск»: любой выпуск любого договора — ПКМ или таяние. Выпуск без единого бойца
## натиска не показывает и не засчитывается.
func _on_segment_released(c: Contract, seg: int, n_units: int) -> void:
	if not active or step_kind() != &"release":
		return
	var cause: StringName = c.release_causes.get(seg, &"")
	if cause != &"manual" and cause != &"melt":
		return
	if n_units > 0:
		_credit = true
	elif cause == &"manual":
		_hint(HINT_EARLY)


## Урок Таба: Таб стёр линию, и хоть один боец ушёл в натиск. Стёртое без бойцов (линию только
## начертили, строй не встал) урок не засчитывает — как и ПКМ в уроке натиска.
func _on_tab_erased(_c: Contract, _n_segs: int, n_units: int) -> void:
	if not active or step_kind() != &"erase":
		return
	if n_units > 0:
		_credit = true
	else:
		_hint(HINT_EARLY)


## Пружину учим срывом ПКМ: таяние прогнутого участка (cause melt) — не то действие.
func _on_spring_released(c: Contract, seg: int, _bend: float) -> void:
	if c.release_causes.get(seg, &"") == &"melt":
		return
	if active and step_kind() == &"spring":
		_credit = true
	else:
		_credit_hidden(&"spring")


## Действие урока посреди боя сделано, пока его плашка спрятана, — урок засчитан, если в этом бою
## он уже показывался: игрок его видел и сделал (проверяющий 27.09: срыв пружиной в паузе не
## засчитывался, урок вставал и просил повторить). Ни разу не показанный урок так не засчитывается —
## его ещё не учили. Только уроки, чьё действие однозначно: пружина, «Сбор», срыв по оглушённым
## (Ку «куда угодно» урок «Ку по Юристу» засчитывать не должна).
func _credit_hidden(kind: StringName) -> void:
	if not active:
		return
	for i in lessons.size():
		var l := lessons[i]
		if i != _step and l["kind"] == kind and not l["start"] and _voiced.has(l["id"]) \
				and not _passed.has(l["id"]):
			_pass_quietly(i)
			return


func _on_rally_used(_at: Vector2, n: int) -> void:
	if not active:
		return
	if step_kind() != &"rally":
		if n > 0:
			_credit_hidden(&"rally")
		return
	if n > 0:
		_credit = true
	else:
		_hint(HINT_RALLY)


func _on_hero_cast(slot: int, _at: Vector2) -> void:
	if not active:
		return
	var want := -1
	match step_kind():
		&"hero_q":
			want = LegionHero.SLOT_Q
		&"hero_w":
			want = LegionHero.SLOT_W
		&"hero_e":
			want = LegionHero.SLOT_E
	if slot != want:
		return
	if String(lesson()["when"]) == "pressed" and spring_target().is_empty():
		# урок «Е, пока линию давят»: Е по спокойной линии — не то, что учим
		_hint(HINT_NOT_PRESSED)
		return
	_credit = true


func _on_figure_made(c: Contract) -> void:
	if not active:
		return
	if step_kind() == &"figure_mini":
		# урок мини-фигуры: зачёт по ЛЮБОЙ фигуре мини-размера — она та же фигура, но меньше
		if c.size_mini:
			_credit = true
		return
	if step_kind() != &"figure":
		return
	var fig := String(lesson()["arg"])
	if (fig == "ring" and c.ring) or String(c.figure) == fig:
		_credit = true


## Урок фигуры кончается ДЕЙСТВИЕМ игрока (D-1002 §7 п.10): срыв ЗАРЯЖЕННОЙ фигуры, а не одно
## появление контура. arg «mini» — годится любая фигура мини-размера.
func _on_figure_ult(c: Contract) -> void:
	if not active or step_kind() != &"figure_ult":
		return
	var want := String(lesson()["arg"])
	if want == "mini":
		if c.size_mini:
			_credit = true
	elif String(c.figure) == want:
		_credit = true


## Урок «выпусти ОДНУ группу»: рогатка сорвала фигуру по общей оси оттяжки (соседняя не ушла).
func _on_figure_slung(_c: Contract) -> void:
	if active and step_kind() == &"figure_slung":
		_credit = true


func _on_building_changed(b: Object) -> void:
	if not active or step_kind() != &"build":
		return
	var built := b as LegionBuilding
	if built != null and int(world.stats.get("buildings_built", 0)) > _built_at \
			and built.kind == _build_kind():
		_credit = true


func _on_item_gained(_id: StringName, _at: Vector2) -> void:
	if active and step_kind() == &"item":
		_credit = true


func _on_stunned_hit(_foe: Foe) -> void:
	if active and step_kind() == &"stun_hit":
		_credit = true
	else:
		_credit_hidden(&"stun_hit")


## Урок постройки: клик мимо площадки (по линии, по земле) — подсказка, куда кликать.
func _on_tap(pos: Vector2) -> void:
	if active and step_kind() == &"build" and world.staff.plot_at(pos).is_empty():
		_hint(HINT_PLOT)


# ── Служебное ──────────────────────────────────────────────────────────────

func _draw_kind() -> StringName:
	return _kind_of(lesson())


func _build_kind() -> StringName:
	return _draw_kind()


## Вид договора/постройки урока: `done` вида `building_built:guard` — guard, без вида — подряд.
static func _kind_of(l: Dictionary) -> StringName:
	var arg := String(l.get("arg", ""))
	return StringName(arg) if arg != "" else LegionCfg.KIND_LABORER


## Одна и та же подсказка — не чаще TUTORIAL_HINT_GAP; другая показывается сразу.
func _hint(text: String) -> void:
	if world.now - float(_hint_at.get(text, -INF)) < LegionCfg.TUTORIAL_HINT_GAP:
		return
	_hint_at[text] = world.now
	world.toast(Controls.text(text), &"warn")


func _pick_plot() -> Dictionary:
	return _pick_plot_for(lesson())


## Пустая площадка урока: отмеченная в mark.plot, иначе первая пустая ({} — все застроены).
func _pick_plot_for(l: Dictionary) -> Dictionary:
	var want := String((l.get("mark", {}) as Dictionary).get("plot", ""))
	var first: Dictionary = {}
	for p in world.staff.plots:
		if p["building"] != null:
			continue
		if String(p["id"]) == want:
			return p
		if first.is_empty():
			first = p
	return first


func _contract_alive(c: Contract) -> bool:
	return c != null and world.contracts.contracts.has(c) and c.alive()


## Сколько живых бойцов вида договора стоит в его радиусе набора (DESIGN_V15 §12 п.7).
func _in_reach(c: Contract) -> int:
	var r := float(world.contracts.recruit_r.get(c.kind, LegionCfg.RECRUIT_R))
	var n := 0
	for u in world.units:
		if u.alive and u.kind == c.kind and c.live_distance(u.position) <= r:
			n += 1
	return n


func manned(c: Contract) -> int:
	var n := 0
	for s in c.seg_count():
		if c.seg_alive(s):
			n += c.seg_manned(s)
	return n


## Свой боец с наибольшим числом своих соседей в радиусе r (free_only — только свободные).
func _cluster(r: float, free_only: bool) -> Vector2:
	var pool: Array[Legionnaire] = []
	for u in world.units:
		if u.alive and (not free_only or u.state == Legionnaire.State.FREE):
			pool.append(u)
	var best := Vector2.INF
	var best_n := -1
	var r2 := r * r
	for u in pool:
		var n := 0
		for v in pool:
			if u.position.distance_squared_to(v.position) <= r2:
				n += 1
		if n > best_n:
			best_n = n
			best = u.position
	return best


## Материал уроков натиска и Ку в начале боя: живых учебных зомби не осталось — новая пачка.
## true — пачка вышла сейчас.
func _restock() -> bool:
	for i in range(_foes.size() - 1, -1, -1):
		if not is_instance_valid(_foes[i]) or not _foes[i].alive:
			_foes.remove_at(i)
	if not _foes.is_empty():
		return false
	for i in LegionCfg.TUTORIAL_FOES:
		var f := _spawn_tutorial_foe(
			LegionCfg.TUTORIAL_FOE_SPAWN_BACK + LegionCfg.TUTORIAL_FOE_SPACING * float(i))
		if f != null:
			_foes.append(f)
	return true


## Материал урока Дубль-вэ в начале боя: свежего трупа нет — учебный зомби выходит и падает.
func _restock_corpse() -> void:
	if target_corpse() != null:
		return
	var f := _spawn_tutorial_foe(LegionCfg.TUTORIAL_FOE_SPAWN_BACK)
	if f != null:
		f.take_damage(f.hp + 1.0, f.position)


## Дорога учебных зомби: mark.road урока, иначе первая дорога карты.
func _road_id() -> String:
	var want := String((lesson().get("mark", {}) as Dictionary).get("road", ""))
	if want != "":
		return want
	var roads: Array = world.map.get("roads", [])
	return String((roads[0] as Dictionary).get("id", "")) if not roads.is_empty() else ""


## Зомби урока выходит на дороге за `back` px пути до Котла, а не у ворот карты — оттуда
## полминуты ходьбы (SLICE_SPEC §2: roads[].path начинается за краем).
func _spawn_tutorial_foe(back: float) -> Foe:
	var road := _road_id()
	var path := world.road_path(road)
	if path.size() < 2:
		return world.spawn_foe(FOE_TYPE, road)
	var d := back
	for i in range(path.size() - 1, 0, -1):
		var seg := path[i].distance_to(path[i - 1])
		if d <= seg and seg > 0.0:
			return world.spawn_foe_on_path(FOE_TYPE, path.slice(i), path[i].lerp(path[i - 1], d / seg))
		d -= seg
	return world.spawn_foe(FOE_TYPE, road)
