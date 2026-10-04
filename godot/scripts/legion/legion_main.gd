class_name LegionMain
extends Node
##
## Корень scenes/legion.tscn — конечный автомат экранов режима «По истечении договора»:
## меню → карты → брифинг → бой → итог → (победа) поправка → брифинг следующей карты.
## Экраны — пакет UI (scripts/legion/ui/*), самодостаточные Control: этот файл их строит,
## слушает сигналы и переключает. Бой — LegionWorld, встроенный как ребёнок (embedded = true),
## кампания и поправки — campaign.gd / legion_meta_cfg.gd.
##
## СОВМЕСТИМОСТЬ (обязательна для гейта/бота/серий/тестов, см. docs/legion/SLICE_SPEC.md):
## при любом из --autostart/--bot/--bench/--shot/--map сцена идёт прямо в бой ТОЧНО как раньше —
## мир встраивается с embedded = false и сам разбирает CLI-аргументы в своём _ready().
## --dev screen=<имя> (в паре с --shot) — кадр экрана меню/кампании вне боя для приёмки; имеет
## приоритет над compat-путём, иначе снять кадр меню было бы невозможно без --map.
##

## Экраны поверх боя (итог, пауза, настройки, «Как играть», катсцены) — Control на холсте 0, а
## мир рисует объекты с z_index (кольца склепов, метки, эффекты героя до 60): без своего z_index
## подписи мира ложились поверх карточки итога (corr 29.09, turn_1024). Полный экран — выше всего.
const OVERLAY_Z := 1000
const WORLD_SCENE := preload("res://scenes/legion_world.tscn")

# ── Пакет cuts: катсцены (docs/legion/DESIGN_V15.md §9) ──────────────────────
const CUT_INTRO_1 := preload("res://assets/legion/cutscenes/lg_intro_1.png")
const CUT_INTRO_2 := preload("res://assets/legion/cutscenes/lg_intro_2.png")
const CUT_INTRO_3 := preload("res://assets/legion/cutscenes/lg_intro_3.png")
const CUT_INTRO_4 := preload("res://assets/legion/cutscenes/lg_intro_4.png")
const CUT_BOSS_APPEAR := preload("res://assets/legion/cutscenes/lg_boss_appear.png")
const CUT_FINALE_1 := preload("res://assets/legion/cutscenes/lg_finale_1.png")
const CUT_FINALE_2 := preload("res://assets/legion/cutscenes/lg_finale_2.png")
## Видео-вставка вступления — необязательная (COMMON.md пакета: "если генерация даст
## качество"), путь проверяется в рантайме через ResourceLoader.exists(), .ogv в git не
## обязателен.
const CUT_INTRO_1_VIDEO_PATH := "res://assets/legion/cutscenes/lg_intro_1.ogv"

var world: LegionWorld = null
## polish1: узел озвучки кампании — единственный на весь сеанс, экраны вне боя (меню, карты,
## брифинг, катсцены, «Контора», герой, итог) зовут `_ensure_audio()`; когда стартует первый бой,
## `start_battle()` передаёт этот же узел миру через `LegionWorld.injected_audio` — второй узел
## `LegionAudio` мир больше не создаёт (находка ревью 25.09.2026: экраны до первого боя были немы).
var audio: LegionAudio = null
## Текущий верхний экран кампании (меню/карты/брифинг/итог/поправка) — публично для тестов:
## flow-тест ведёт игру, эмитируя сигналы прямо у этого узла, как реальные клики.
var screen: Control = null
## Аргументы командной строки из `_ready()`: `_ensure_audio()` создаёт узел до появления `world`.
var _args: Dictionary = {}
var _pause_screen: LegionPause = null
## id карты, куда вести игрока после выбора поправки на экране итога; "" — кампания пройдена.
var _pending_next_map := ""
## Катсцена Прораба — один раз за сессию, не за сохранение: это выход конкретного боя,
## а не разовый сюжетный момент, как вступление. Флаг в Campaign не нужен.
var _boss_cutscene_shown := false
## mode (BOOK §1, docs/procgen/STAGE2.md линия mode): идущий бой — объект «Бесконечного
## подряда»/«Вызова дня», не карта кампании. match_ended — одно подключение на весь сеанс
## (world переживает и кампанию, и забег), поэтому _on_match_ended различает получателя этим
## флагом, а не отдельным сигналом. ВАЖНО (verifier 27.09, п.1): выставляется заново при СТАРТЕ
## КАЖДОГО боя — start_battle() сбрасывает в false, _start_endless_battle() ставит true: пауза →
## «Меню» посреди забега и «Как играть → Обучение» идут в обход _on_match_ended и раньше оставляли
## флаг висеть true — следующий бой КАМПАНИИ ошибочно уходил в endless-ветку (verifier 27.09, п.1).
var _in_endless_battle := false
## Какой из двух забегов идёт сейчас — обычный «Бесконечный подряд» или «Вызов дня» (у них РАЗНЫЕ
## секции сохранения, verifier 27.09 п.2). Источник истины — нажатая в меню кнопка
## (_start_endless_flow); show_endless_briefing()/_start_endless_battle() каждый раз СНОВА
## выставляют по нему Campaign-scope, а не наследуют прежний (тот же verifier, п.1).
var _endless_daily := false
## D-0927-162: идущий бой — переигровка карты из LegionCollection (вне забега/дня, поправки не
## копятся). Тот же приём, что _in_endless_battle — сбрасывается КАЖДЫМ start_battle()/
## _start_endless_battle(), ставится только LegionCollectionFlow.start_battle().
var _in_collection_battle := false


func _ready() -> void:
	add_child(SaveNotice.new())
	var args := LegionWorld.parse_args()
	_args = args
	var dev: Dictionary = args.get("dev", {})
	Settings.use_dev_save(String(dev.get("save", "")))   # B-062: настройки — в парный файл своего save
	# сохранённые громкости, звук и полный экран (агентному прогону окно не разворачивает)
	Settings.apply()
	if args.has("mute"): AudioServer.set_bus_mute(0, true)
	# --dev save=user://файл.cfg — прогон меню-пути (приёмка обучения из кампании) на
	# отдельном чистом сохранении: настоящий user://legion.cfg владельца не читается и не пишется.
	# Путь обязан быть не настоящим сохранением, иначе reset() стёр бы прогресс владельца.
	var dev_save := String(dev.get("save", ""))
	# отклонённый путь — отказ, а не молча настоящее сохранение (verifier 180f1168: на master
	# «user://exe probe.cfg» был отдельным файлом, а белый список отправил бы игру в legion.cfg)
	if dev_save != "" and not Campaign.is_safe_dev_save(dev_save):
		push_error("legion_main: --dev save=%s отклонён: только user://имя.cfg" % dev_save)
		if dev.has("corr"):
			# игрок-агент ждёт ход — причина файлом, как и у отказа без сохранения ниже
			var corr_err := String(dev["corr"])
			DirAccess.make_dir_recursive_absolute(corr_err)
			var f := FileAccess.open(corr_err.path_join("error.txt"), FileAccess.WRITE)
			f.store_string("--dev save=%s отклонён: только user://имя.cfg " % dev_save
				+ "(буквы, цифры, _ и -; не legion, не settings)")
			f.close()
		get_tree().quit(1)
		return
	if dev_save != "" and Campaign.is_safe_dev_save(dev_save):
		Campaign.set_save_path(dev_save)
		# --dev save_keep=1 — продолжить своё сохранение (кампания по переписке идёт в несколько
		# запусков), а не начать с чистого листа
		if not dev.has("save_keep"):
			Campaign.reset()
	var dev_screen := String(dev.get("screen", ""))
	if dev_screen != "":
		_ensure_audio()
		_capture_dev_screen(dev_screen, String(args.get("shot", "")), int(args.get("shot_frame", 90)))
		return
	# Пакет cuts: --dev cutscene=intro|boss|finale — прогон катсцены вне брифинга/боя,
	# приёмка кадрами (COMMON.md п.6).
	var dev_cutscene := String(dev.get("cutscene", ""))
	if dev_cutscene != "":
		_ensure_audio()
		_capture_dev_cutscene(
			dev_cutscene, String(args.get("shot", "")), int(args.get("shot_frame", 90)))
		return
	var compat := args.has("autostart") or args.has("bot") or args.has("bench") \
		or args.has("shot") or args.has("map")
	if compat:
		world = WORLD_SCENE.instantiate() as LegionWorld
		add_child(world)   # embedded остаётся false — мир сам стартует бой, как раньше
		return
	_ensure_audio()
	show_menu()
	add_child(PlayMetrics.new())
	# приёмка обучения из кампании настоящим вводом: --dev save=… --dev tutorial_play=campaign|skip
	# (tools/tutorial_play.sh). Без чужого сохранения не запускаем — водитель жмёт «Начать кампанию».
	if dev.has("tutorial_play") and Campaign.is_safe_dev_save(dev_save):
		var drv: Node = (load(LegionWorld.TUTORIAL_DRIVER) as GDScript).new()
		drv.call("setup_main", self, String(dev["tutorial_play"]))
		add_child(drv)
	# кампания по переписке: --dev corr=папка --dev save=user://свой.cfg (без --map) — меню,
	# брифинги, уроки и открытия как у игрока (scripts/dev/corr_play.gd). Только своё сохранение:
	# настоящий прогресс владельца агент не трогает.
	if dev.has("corr") and OS.is_debug_build():
		var corr_dir := String(dev["corr"])
		if not Campaign.is_safe_dev_save(dev_save):
			DirAccess.make_dir_recursive_absolute(corr_dir)
			var ef := FileAccess.open(corr_dir.path_join("error.txt"), FileAccess.WRITE)
			ef.store_string("кампания по переписке — только со своим --dev save=user://имя.cfg "
				+ "(буквы, цифры, _ и -; не legion, не settings)")
			ef.close()
			get_tree().quit(1)
			return
		var corr: Node = (load(LegionWorld.CORR_PLAY) as GDScript).new()
		corr.call("setup_main", self, corr_dir)
		add_child(corr)


## polish1: единственный узел `LegionAudio` кампании — создаётся при первом обращении (обычно
## из `_ready()`, до `show_menu()`/dev-путей), дальше переиспользуется всеми экранами и, когда
## стартует первый бой, передаётся миру (`start_battle()` → `LegionWorld.injected_audio`).
func _ensure_audio() -> LegionAudio:
	if audio == null:
		audio = LegionAudio.new()
		add_child(audio)
		var dev: Dictionary = _args.get("dev", {})
		audio.setup_standalone(_args.has("mute"), _args.has("trace") or dev.has("audio_log"))
	return audio


# ── Экраны кампании ────────────────────────────────────────────────────────

func show_menu() -> void:
	# mode: меню — всегда кампания (забег продолжает жить в своей секции сохранения, «Продолжить
	# забег» перечитает его заново при следующем входе в _start_endless_flow()). Пауза → «Меню»
	# посреди забега не проходит через _on_match_ended (verifier 27.09, п.1) — снимаем флаг здесь
	# же, а не только в момент реального окончания боя.
	if _settle_abandoned_daily():
		return
	Campaign.use_campaign_scope()
	_in_endless_battle = false
	_in_collection_battle = false
	if world != null:
		world.go_to_menu()   # эмитит menu_entered — LegionAudio сам переключит трек на "menu"
	else:
		_ensure_audio().play_menu_music()   # до первого боя world.menu_entered некому слать
		audio.silence_for_menu()
	_teardown_screen()
	var m := LegionMenu.new()
	var dev: Dictionary = _args.get("dev", {})
	m.dev_force_open = OS.is_debug_build() and dev.has("endless_open")
	_set_screen(m)
	m.continue_pressed.connect(_on_continue_pressed)
	m.maps_pressed.connect(show_map_select)
	# meta: «Контора» и «Герой» доступны из меню, оба возвращают в меню (show_menu — Callable
	# без скобок в GDScript ссылается на метод этого узла).
	m.office_pressed.connect(func() -> void: show_office(show_menu))
	m.hero_pressed.connect(func() -> void: show_hero(show_menu))
	m.howto_pressed.connect(_show_howto)
	m.settings_pressed.connect(func() -> void: _show_settings(true))
	m.quit_pressed.connect(func() -> void: get_tree().quit())
	m.endless_pressed.connect(func() -> void: _start_endless_flow(false))
	m.daily_pressed.connect(func() -> void: _start_endless_flow(true))
	m.collection_pressed.connect(func() -> void: LegionCollectionFlow.show_screen(self))
	m.pvp_pressed.connect(func() -> void: PvpFlow.show_field_select(self))


## «Продолжить» из меню: если с прошлой игры осталась незабранная награда (игрок ушёл в «Меню»,
## не нажав «Дальше» — ревью, п.4), сперва предлагаем её, потом ведём на карту.
func _on_continue_pressed(map_id: String) -> void:
	var pending := Campaign.pending_reward()
	if pending != "":
		_pending_next_map = pending
		_offer_upgrade_or_skip()
		return
	show_briefing(map_id)


func show_map_select() -> void:
	Campaign.use_campaign_scope()
	_ensure_audio().play_menu_music()
	_teardown_screen()
	var s := MapSelect.new()
	_set_screen(s)
	s.map_chosen.connect(show_briefing)
	s.office_pressed.connect(func() -> void: show_office(show_map_select))
	s.back.connect(show_menu)


func show_briefing(map_id: String) -> void:
	Campaign.use_campaign_scope()
	var data := Campaign.map(map_id)
	if data.is_empty():
		show_menu()
		return
	# Пакет cuts: вступление кампании — один раз, перед брифингом самой первой карты (флаг
	# в Campaign переживает выход в меню и повторный заход, docs/legion/DESIGN_V15.md §9).
	if _is_first_map(map_id) and not Campaign.intro_cutscene_seen():
		Campaign.set_intro_cutscene_seen()
		_play_cutscene(_intro_frames(), _ensure_audio(), func() -> void: show_briefing(map_id))
		return
	_ensure_audio().play_menu_music()
	_teardown_screen()
	var b := Briefing.new()
	_set_screen(b)
	# populate() кладёт карточку через UiStyle.card_box — тому нужен готовый родитель
	# (см. tests/legion_ui_preview.gd), поэтому вызываем деферренно, после add_child выше.
	# integrate1: открылся новый вид/способность — эйчар объявляет (плашка «Новое» — у брифинга)
	if not Campaign.pending_unlock_labels().is_empty():
		audio.voice_any(["lg_contract_new_1", "lg_contract_new_2", "lg_contract_new_3"],
			LegionCfg.AUDIO_V15_PRIORITY_HR, LegionAudio.VoiceClass.STORY)
	b.call_deferred("populate", data)
	b.start.connect(start_battle)
	b.back.connect(show_map_select)


## Публичный вход в бой — используется и экраном брифинга, и flow-тестом напрямую, и «Как играть →
## Обучение» из паузы (_show_pause() ниже, минуя брифинг). mode (verifier 27.09, п.1): бой
## КАМПАНИИ явно ставит СВОЙ режим у себя же — сбрасывает _in_endless_battle и Campaign-scope,
## а не наследует их от того, что шло до него (в т.ч. от забега, из которого вышли паузой в
## меню, минуя _on_match_ended).
func start_battle(map_id: String) -> void:
	if _settle_abandoned_daily():
		return
	_in_endless_battle = false
	_in_collection_battle = false
	Campaign.use_campaign_scope()
	# Пакет cuts: выход Прораба — перед боем на его карте, один раз за сессию.
	if _has_boss(map_id) and not _boss_cutscene_shown:
		_boss_cutscene_shown = true
		# голос — тем же узлом, который уже озвучивал экраны кампании (до первого боя он ещё
		# не встроен в мир, но живой и играющий)
		_play_cutscene(_boss_frames(), _ensure_audio(), func() -> void: start_battle(map_id))
		return
	_teardown_screen()
	_ensure_world()
	# D-0927-96: снимаем возможный override сложности «Вызова дня» (world.dev["difficulty"],
	# см. _start_endless_battle()) — кампания всегда читает живой Settings.difficulty().
	world.dev.erase("difficulty")
	world.mods = Campaign.active_mods()
	# артефакты кампании живут между картами (D-0927-163), как поправки
	world.carry_items = true
	world.start_map(map_id)
	# Кампания v20 (D-0926-46): у каждой карты свои уроки (поле lessons её JSON) — ещё не
	# пройденные идут поверх боя; обучение «Пустыря» — это уроки карты 1. Флаги уроков в
	# сохранении не дают показать урок повторно (docs/legion/TUTORIAL_SPEC.md).
	world.start_lessons()


## Мир создаётся один раз на сеанс и переживает и кампанию, и «Бесконечный подряд» (mode line):
## оба флоу зовут start_map() на одном и том же узле, разница — что в это время в Campaign
## включён другой scope (use_campaign_scope()/use_endless_scope()) и мир по-прежнему думает,
## что он «в кампании» (in_campaign читает Campaign.stat(), а тот сам смотрит на текущий scope).
func _ensure_world() -> LegionWorld:
	if world == null:
		world = WORLD_SCENE.instantiate() as LegionWorld
		world.embedded = true
		# polish1: переиспользовать единственный узел звука кампании вместо второго, который
		# завела бы `LegionWorld._build()` сама (см. её докстринг и `injected_audio`).
		world.injected_audio = _ensure_audio()
		add_child(world)
		world.match_ended.connect(_on_match_ended)
		world.paused_changed.connect(_on_world_paused_changed)
		world.pvp_menu_requested.connect(show_menu)
		world.hud.show_native_ui = false
	world.in_campaign = true   # «Схватка» (PvpFlow.start) снимает на свой матч
	world.kassa_allowed = true   # переигровка из коллекции снимает (премии там нет)
	# B-093 (newbie2): любой старт боя снимает «покрытие» экранов — сюда идут все три ветки
	# (кампания start_battle, забег/«Вызов дня» _start_endless_battle, переигровка из
	# коллекции LegionCollectionFlow.start_battle), а мир мог стоять спрятанным с прошлого
	# экрана. Безусловно, не только при создании: второй бой идёт на том же узле.
	_cover_battle(false)
	return world


# ── meta: «Контора» и экран героя (DESIGN_V15 §7, §12 п.8–9) ─────────────────────────────────
## on_back — Callable без аргументов, куда вести по «Дальше»/«Назад» (show_menu, show_map_select
## или _finish_pending_reward — GDScript даёт ссылку на метод как Callable без скобок).
## Из «Конторы» можно уйти на экран героя и вернуться обратно в ту же «Контору» (не в on_back
## напрямую) — иначе кнопка «Герой» из «Конторы» после поправки пропускала бы её «Дальше».

## greet — эйчар здоровается при входе в «Контору»; возврат с экрана героя — без приветствия.
func show_office(on_back: Callable, greet := true) -> void:
	_ensure_audio().play_menu_music()
	_teardown_screen()
	var o := OfficeShop.new()
	_set_screen(o)
	o.back.connect(on_back)
	o.hero_pressed.connect(func() -> void: show_hero(func() -> void: show_office(on_back, false)))
	# integrate1: озвучка «Конторы» — единым узлом звука кампании (polish1: живёт с первого
	# экрана, не только с первого боя)
	if greet:
		audio.voice(&"lg_office_enter", LegionCfg.AUDIO_V15_PRIORITY_HR, LegionAudio.VoiceClass.STORY)
	o.bought.connect(func() -> void:
		audio.voice(&"lg_office_buy", LegionCfg.AUDIO_V15_PRIORITY_HR, LegionAudio.VoiceClass.STORY))


func show_hero(on_back: Callable) -> void:
	_ensure_audio().play_menu_music()
	_teardown_screen()
	var h := HeroScreen.new()
	_set_screen(h)
	h.back.connect(on_back)


# ── Итог боя → поправка → следующая карта ───────────────────────────────────

func _on_match_ended(victory: bool, stats: Dictionary) -> void:
	if PvpFlow.swallows_match_end(self):   # итог «Схватки» — экран PvpResult, не кампании
		return
	# D-0927-162: переигровка из коллекции — своя ветка, тоже раньше кампании/забега (флаг ставит
	# только LegionCollectionFlow.start_battle(), кампания/забег его не видят).
	if _in_collection_battle:
		_in_collection_battle = false
		LegionCollectionFlow.on_match_ended(self, victory, stats)
		return
	# mode: тот же сигнал у объекта «Бесконечного подряда»/«Вызова дня» — своя ветка целиком,
	# кампании ничего из неё не нужно (record_result/record_rewards/следующая КАРТА КАМПАНИИ,
	# катсцены Прораба/финала — всё это чужая семантика для забега).
	if _in_endless_battle:
		_in_endless_battle = false
		_on_endless_match_ended(victory, stats)
		return
	var map_id := world.map_id
	var max_hp: float = maxf(1.0, world.cauldron_max)
	var ratio := clampf(float(stats.get("hp", 0.0)) / max_hp, 0.0, 1.0)
	Campaign.begin_update()
	var stars := Campaign.record_result(map_id, victory, ratio)
	# meta (задание meta п.1, п.3): kills_rewardable — статистика боя пакета staff (штрафует
	# убийства свиты Прораба, которая душ/опыта/премии не даёт, DESIGN_V15 §12 п.4); нет ключа —
	# берём обычный kills, как велит задание, пока staff его не добавил.
	var kills_rewardable := int(stats.get("kills_rewardable", stats.get("kills", 0)))
	var rewards := Campaign.record_rewards(victory, stars, kills_rewardable)
	LegionKassa.grant(victory, stats, rewards)   # «Касса»: туда же, куда премия за бой
	var next_id := _next_map_id(map_id)
	# Ожидающая награда — в Campaign, не только в этом поле (ревью, п.4): переживает выход
	# в «Меню» без клика «Дальше». set_pending_reward() сам не даёт второй ожидающей поверх
	# уже стоящей — повторная победа на пройденной карте её не плодит.
	if victory and next_id != "":
		Campaign.set_pending_reward(next_id)
	_pending_next_map = Campaign.pending_reward() if victory else ""
	Campaign.end_update()

	var view_stats := {
		"map_title": String(world.map.get("title", map_id)),
		"cauldron_hp": float(stats.get("hp", 0.0)),
		"cauldron_max": max_hp,
		"kills": int(stats.get("kills", 0)),
		"lost": int(stats.get("lost", 0)),
		"charges": int(stats.get("charges", 0)),
		"refreshes": int(stats.get("refreshes", 0)),
		"releases": int(stats.get("releases", 0)),
		"releases_manual": int(stats.get("releases_manual", 0)),
		"time": float(stats.get("t", 0.0)),
	}
	# Победа на последней карте кампании (следующей нет) — отдельный текст итога (ревью, п.7),
	# а не общий «Договор исполнен»; кнопка «Дальше» всё равно скрыта (has_next = false).
	var campaign_complete := victory and next_id == ""
	var has_next := victory and next_id != ""

	# Пакет cuts: финал кампании — 2 кадра после победы над Прорабом, перед экраном итога.
	# Озвучка берёт живой узел LegionAudio боя (world ещё не разобран на этом шаге).
	if campaign_complete:
		_play_cutscene(_finale_frames(), _ensure_audio(), func() -> void:
			_show_result_screen(map_id, victory, view_stats, stars, has_next, campaign_complete,
				rewards))
		return
	_show_result_screen(map_id, victory, view_stats, stars, has_next, campaign_complete, rewards)


func _show_result_screen(map_id: String, victory: bool, view_stats: Dictionary, stars: int,
		has_next: bool, campaign_complete: bool, rewards: Dictionary) -> void:
	_teardown_screen()
	var r := LegionResult.new()
	_set_screen(r)
	r.call_deferred("show_result", victory, view_stats, stars, has_next, campaign_complete,
		rewards)
	r.next.connect(_on_result_next)
	r.retry.connect(func() -> void: start_battle(map_id))
	r.maps.connect(show_map_select)
	r.menu.connect(show_menu)


func _on_result_next() -> void:
	_offer_upgrade_or_skip()


## Показывает выбор поправки, либо, если пул исчерпан (все 10 взяты), сразу ведёт в «Контору»
## (ревью, п.1: раньше экран поправок при пустом пуле оставался пуст и без выхода). Общий путь
## для «Дальше» на итоге боя и для «Продолжить» из меню с незабранной наградой (ревью, п.4).
func _offer_upgrade_or_skip() -> void:
	if Campaign.reward_claimed():
		show_office(_finish_pending_reward)
		return
	# Случайность — не своя RandomNumberGenerator.randomize(), а world.rng, где мир уже есть:
	# воспроизводимо от сида боя (ревью, п.5). Но `world` МОЖЕТ быть null — свежий запуск игры,
	# «Продолжить» с незабранной наградой ведёт сюда через _on_continue_pressed()/
	# _start_endless_flow() ДО первого боя этой сессии (verifier 27.09, п.5: на реальном
	# сохранении с pending_reward="gatehouse" это валило игру `SCRIPT ERROR: Invalid access to
	# property 'rng' on 'Nil'`) — тогда берём RNG, детерминированный от самого́ сохранения.
	var rng := world.rng if world != null else Campaign.pending_reward_rng()
	var options := Campaign.offer_upgrades(rng)
	if options.is_empty():
		Campaign.claim_reward()
		show_office(_finish_pending_reward)
		return
	_teardown_screen()
	var picker := UpgradePicker.new()
	_set_screen(picker)
	picker.call_deferred("offer", options)
	picker.picked.connect(pick_upgrade)


## Публичный API поправки — вызывает и клик по карточке UpgradePicker, и flow-тест напрямую
## (эмулирует выбор без клика по кнопке, как делает legion_core_test.gd для боевых систем).
## meta (задание meta п.2): после поправки — «Контора» (премия уже начислена в _on_match_ended),
## «Дальше» там ведёт на следующую карту (_finish_pending_reward).
func pick_upgrade(id: StringName) -> void:
	if Campaign.claim_reward(id):
		show_office(_finish_pending_reward)


## Награда забрана (или пропущена из-за пустого пула) — снимаем метку ожидания в Campaign
## и ведём на карту, ради которой награда предлагалась.
func _finish_pending_reward() -> void:
	Campaign.clear_pending_reward()
	var next_id := _pending_next_map
	_pending_next_map = ""
	# mode: сентинел вместо id карты кампании — следующий объект забега (LegionEndless.
	# PENDING_SENTINEL), считается заново из LegionRunStore.endless_k(), а не запомнен здесь: пока
	# висела ожидающая награда, объект не сменился (endless_object_won() уже отработал до неё).
	if next_id == LegionEndless.PENDING_SENTINEL:
		show_endless_briefing()
	elif next_id != "":
		show_briefing(next_id)
	else:
		show_menu()


func _next_map_id(current_id: String) -> String:
	var all := Campaign.maps()
	for i in all.size():
		if String(all[i].get("id", "")) == current_id and i + 1 < all.size():
			return String(all[i + 1].get("id", ""))
	return ""


# ── mode: «Бесконечный подряд» / «Вызов дня» (BOOK docs/procgen/BOOK.md §1–2, вопрос 1) ────────

## Тестовая замена генератора картой кампании для быстрых проверок переходов.
func _endless_stub() -> bool:
	return OS.is_debug_build() and _args.get("dev", {}).has("endless_stub")


## Общий загрузчик брифинга забега и переигровки из коллекции (D-0927-162).
func _load_object_map_data(map_id: String) -> Dictionary:
	return LegionWorld.load_map(map_id) if map_id.begins_with("gen:") else Campaign.map(map_id)


## D-0927-162: сгенерированная карта объекта — сохранить можно только её (не карту кампании).
## В этой ветке "gen:" ещё не резолвится (генератор не смёржен) — стаб-id сохраняем ТОЛЬКО в
## dev-режиме (--dev endless_stub=1), для проверки самой механики коллекции.
func _collectible_map_id(map_id: String) -> bool:
	return map_id.begins_with("gen:") or _endless_stub()


## Кнопка «Бесконечный подряд»/«Вызов дня» в меню: продолжает уже идущий забег ТОГО ЖЕ вида
## (РАЗНЫЕ секции сохранения, друг друга не стирают), иначе начинает новый (endless_start()
## сбрасывает поправки/«Контору» ЗАБЕГА — прогресс кампании не трогает). Порядок как у
## _on_continue_pressed(): сперва отдать незабранную награду. D-0927-96/-122: ОДНА попытка на
## дату навсегда — запрет здесь, на уровне флоу, а не только закрытой кнопкой (LegionRunStore.
## daily_enter: забег другой даты сперва закрывается как сданный на свою дату).
func _start_endless_flow(daily: bool) -> void:
	_endless_daily = daily
	if daily:
		Campaign.use_daily_scope()
		if not LegionRunStore.daily_enter(LegionEndless.today_date()):
			show_menu()
			return
	else:
		Campaign.use_endless_scope()
		if not LegionRunStore.endless_active(false):
			LegionRunStore.endless_start(LegionEndless.random_seed())
	var pending := Campaign.pending_reward()
	if pending != "":
		_pending_next_map = pending
		_offer_upgrade_or_skip()
		return
	show_endless_briefing()


## Брифинг объекта k текущего забега (_endless_daily — какого именно, см. докстринг поля).
## Каталог карт пуст (ни заглушек, ни настоящих ресурсов — не должно случиться в релизе, но кадр/
## тест мог стереть их) или "gen:" ещё не резолвится (линия layout не смёржена, endless_stub
## выключен) — данных нет, не подвешиваем игрока на пустом экране (тот же приём, что
## show_briefing() при пустой Campaign.map()).
func show_endless_briefing() -> void:
	if _endless_daily:
		Campaign.use_daily_scope()
	else:
		Campaign.use_endless_scope()
	var stub := _endless_stub()
	var k := LegionRunStore.endless_k(_endless_daily)
	var map_id := LegionEndless.object_map_id(LegionRunStore.endless_seed(_endless_daily), k, stub)
	var data := _load_object_map_data(map_id)
	if map_id == "" or data.is_empty():
		show_menu()
		return
	_ensure_audio().play_menu_music()
	_teardown_screen()
	var b := EndlessBriefing.new()
	_set_screen(b)
	b.call_deferred("populate", data, k, LegionRunStore.endless_tenure(_endless_daily),
		LegionRunStore.endless_souls(_endless_daily), _endless_daily, LegionRunStore.endless_daily_date())
	b.start.connect(_start_endless_battle)
	b.back.connect(show_menu)


## mode (verifier 27.09, п.1): бой забега ЯВНО ставит СВОЙ режим у себя же — по _endless_daily,
## не по тому, что уже стоит в Campaign (правило одно на всех: КАЖДЫЙ старт боя ставит режим сам).
## D-0927-96/-120: сложность забега (обоих видов) фиксируется в момент старта ПЕРВОГО объекта
## (lock_difficulty — no-op на повторных) и подаётся миру через world.dev["difficulty"] в обход
## живого Settings.difficulty(). D-0927-121: бой дня сразу помечается в сохранении открытым.
func _start_endless_battle(map_id: String) -> void:
	if _settle_abandoned_daily():
		return
	_teardown_screen()
	_ensure_world()
	_in_endless_battle = true
	_in_collection_battle = false
	if _endless_daily:
		Campaign.use_daily_scope()
	else:
		Campaign.use_endless_scope()
	LegionRunStore.lock_difficulty(_endless_daily, Settings.difficulty())
	world.dev["difficulty"] = LegionRunStore.run_difficulty(_endless_daily)
	world.mods = Campaign.active_mods()
	# артефакты забега — в разделе этого забега (endless_run / daily_run)
	world.carry_items = true
	world.start_map(map_id)
	if _endless_daily:
		LegionRunStore.daily_open_mark(map_id, String(world.map.get("title", map_id)))


## D-0927-121: бой «Вызова дня» открыт, а мы уходим не его концом (меню, другой бой, обучение,
## прошлый запуск закрыли/уронили посреди объекта) — попытка засчитана оконченной, некролог
## «самовольный уход». true — некролог показан, вызывающему дальше идти нельзя.
func _settle_abandoned_daily() -> bool:
	var report := LegionRunStore.settle_abandoned_daily()
	if report.is_empty():
		return false
	_in_endless_battle = false
	_in_collection_battle = false
	_hide_pause()
	if world != null:
		world.go_to_menu()
	else:
		_ensure_audio().play_menu_music()   # запуск после падения: мира ещё нет, трек меню — сами
	_show_necrolog(report, LegionEndless.ABANDON_TYPE, String(report.get("map_title", "")))
	return true


## D-0927-121: закрытие окна посреди боя дня — честно закрыть попытку до выхода (падение без
## этого уведомления ловит тот же флаг при следующем запуске, в show_menu()).
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		LegionRunStore.settle_abandoned_daily()


## Итог боя объекта: победа — стаж/души/премия +1 объект, поправка (общий пайплайн
## _offer_upgrade_or_skip()/pick_upgrade()/show_office()); поражение — некролог, забег закрыт
## (LegionRunStore.endless_end_run()). «Ещё раз» после ПОБЕДЫ намеренно не предлагается (verifier
## 27.09, п.3: старая кнопка засчитывала объект повторно) — в забеге после победы только
## «Дальше». Пауза → «Заново» на счёт не влияет: restart() зовёт start_map() напрямую, минуя
## endless_object_won().
func _on_endless_match_ended(victory: bool, stats: Dictionary) -> void:
	var map_title := String(world.map.get("title", world.map_id))
	# D-0927-162: «В коллекцию» и с итога/некролога, не только из паузы — та же проверка id.
	var collectible := _collectible_map_id(world.map_id)
	if not victory:
		var last_type := String(stats.get("last_hit_foe_type", ""))
		var report := LegionRunStore.endless_end_run()
		Campaign.use_campaign_scope()
		_show_necrolog(report, last_type, map_title, collectible)
		return
	# «Души» забега — вторичный счёт (BOOK §1): что осталось у некроманта на конец боя (world.souls;
	# решение инстанса mode, 27.09 — не всё заработанное за бой; заложенное в «Кассу» не в счёт).
	Campaign.begin_update()
	LegionRunStore.endless_object_won(int(world.souls))
	# verifier 27.09, п.4: премия за объект — формула карты кампании (bounty_for_result), в раздел
	# ТЕКУЩЕГО (endless/daily) scope; без неё «Контора» в забеге не на что покупать.
	var ratio := clampf(float(stats.get("hp", 0.0)) / maxf(1.0, world.cauldron_max), 0.0, 1.0)
	var kills_rewardable := int(stats.get("kills_rewardable", stats.get("kills", 0)))
	var bounty_earned := Campaign.grant_endless_bounty(true, kills_rewardable, ratio)
	Campaign.set_pending_reward(LegionEndless.PENDING_SENTINEL)
	_pending_next_map = LegionEndless.PENDING_SENTINEL
	var view_stats := {
		"map_title": map_title,
		"cauldron_hp": float(stats.get("hp", 0.0)),
		"cauldron_max": maxf(1.0, world.cauldron_max),
		"kills": int(stats.get("kills", 0)),
		"lost": int(stats.get("lost", 0)),
		"charges": int(stats.get("charges", 0)),
		"refreshes": int(stats.get("refreshes", 0)),
		"time": float(stats.get("t", 0.0)),
		"tenure": LegionRunStore.endless_tenure(_endless_daily),
		"souls": LegionRunStore.endless_souls(_endless_daily),
		"bounty": bounty_earned,
	}
	LegionKassa.grant(true, stats, view_stats)   # «Касса»: в премию забега и строкой на итоге
	Campaign.end_update()
	_teardown_screen()
	var r := LegionResult.new()
	_set_screen(r)
	r.call_deferred("show_result", true, view_stats, 0, true, false, {}, false, false, collectible)
	r.next.connect(_on_result_next)
	r.menu.connect(show_menu)
	if collectible:
		r.collect_pressed.connect(func() -> void: LegionCollectionFlow.save_current(self))


func _show_necrolog(report: Dictionary, foe_type: String, map_title: String,
		show_collect := false) -> void:
	_teardown_screen()
	var n := Necrolog.new()
	_set_screen(n)
	n.call_deferred("show_report", report, foe_type, map_title, show_collect)
	n.menu.connect(show_menu)
	if show_collect:
		n.collect_pressed.connect(func() -> void: LegionCollectionFlow.save_current(self))
	n.restart.connect(func() -> void:
		var daily := bool(report.get("daily", false))
		_start_endless_flow(daily))


# ── Пауза боя (Esc) ─────────────────────────────────────────────────────────

func _on_world_paused_changed(p: bool) -> void:
	if p:
		_show_pause()
	else:
		_hide_pause()


func _show_pause() -> void:
	if _pause_screen != null:
		return
	_pause_screen = LegionPause.new()
	# Пакет tutorial: пункт «Пропустить обучение» — только пока обучение реально идёт;
	# выставляется ДО add_child, LegionPause читает его в _ready().
	_pause_screen.show_skip_tutorial = world.tutorial != null and world.tutorial.step() >= 0
	# D-0927-96 («Вызов дня» — одна попытка в день): в бою забега «Заново» не предлагаем (не
	# обходить лимит переигрышем объекта), а «Меню» — с подтверждением: выход посреди объекта
	# засчитывает конец сегодняшней попытки.
	if _in_endless_battle and _endless_daily:
		_pause_screen.hide_restart = true
		_pause_screen.confirm_menu_text = ("Выход посреди объекта засчитает конец сегодняшней "
			+ "попытки «Вызова дня» — второй сегодня уже не будет.")
	# D-0927-162: «В коллекцию» — главное место сохранения (Игорь: «если проигрываешь или тебе
	# надо бежать»), только пока идёт бой ЗАБЕГА на сгенерированной карте.
	_pause_screen.show_collect = _in_endless_battle and _collectible_map_id(world.map_id)
	_pause_screen.cover = world   # B-113: подсказки поля/HUD не ложатся поверх паузы
	_pause_screen.process_mode = Node.PROCESS_MODE_ALWAYS
	_pause_screen.z_index = OVERLAY_Z
	add_child(_pause_screen)
	_pause_screen.resume_pressed.connect(func() -> void: world.set_paused(false))
	_pause_screen.restart_pressed.connect(func() -> void: world.restart())
	_pause_screen.settings_pressed.connect(_show_settings)
	_pause_screen.howto_pressed.connect(_show_howto)
	_pause_screen.menu_pressed.connect(_on_pause_menu_pressed)
	_pause_screen.collect_pressed.connect(func() -> void: LegionCollectionFlow.save_current(self))
	_pause_screen.skip_tutorial_pressed.connect(func() -> void:
		if world.tutorial != null:
			world.tutorial.skip()
		world.set_paused(false))


func _hide_pause() -> void:
	if _pause_screen != null:
		_pause_screen.restore_covered()
		_pause_screen.queue_free()
		_pause_screen = null


## D-0927-96: в обычном бою (кампания, забег вне «Вызова дня») «Меню» из паузы ведёт в меню, как
## раньше. В бою «Вызова дня» (подтверждение уже показал и снял LegionPause — сюда попадаем
## только после «Да, уйти») — выход посреди объекта засчитывается как конец попытки: тот же
## путь, что смерть Котла (world.force_end(false) → match_ended → _on_endless_match_ended),
## только причина некролога — не вид врага, а «самовольный уход» (LegionEndless.ABANDON_TYPE).
## Экран сам сменится на некролог внутри force_end() — до show_menu() тут дело не доходит.
func _on_pause_menu_pressed() -> void:
	if _in_endless_battle and _endless_daily:
		world.set_paused(false)
		world.stats["last_hit_foe_type"] = LegionEndless.ABANDON_TYPE
		world.force_end(false)
		return
	show_menu()


## Настройки поверх меню или паузы. Звук применяется к общим шинам Audio.
## from_menu — открыт из главного меню: тогда на экране есть «Сбросить прогресс» (из паузы — нет).
func _show_settings(from_menu := false) -> void:
	var s := SettingsScreen.new()
	s.process_mode = Node.PROCESS_MODE_ALWAYS
	s.allow_reset = from_menu
	s.z_index = OVERLAY_Z
	add_child(s)
	s.closed.connect(func() -> void: s.queue_free())
	s.reset_confirmed.connect(func() -> void:
		s.queue_free()
		reset_progress())


## Сброс сохранения из «Настроек»: стирает user://legion.cfg (Campaign.reset — кампания, премия,
## «Контора», герой, обучение, катсцены) и заново строит меню — «Продолжить» снова ведёт на первую
## карту, вступление и обучение покажутся как в первый раз. Settings (звук, экран) не трогает.
func reset_progress() -> void:
	Campaign.reset()
	_pending_next_map = ""
	_boss_cutscene_shown = false
	show_menu()


func _show_howto() -> void:
	# Оверлей поверх того, что уже показано (меню или пауза): просто убирает себя по closed,
	# нижний экран не трогает — не нужен параметр "куда вернуться".
	var h := HowtoLegion.new()
	h.process_mode = Node.PROCESS_MODE_ALWAYS
	# D-0927-121: из боя «Вызова дня» «Обучение» недоступно — единственный уход с объекта через
	# «Меню» с подтверждением; если всё же дойдёт, start_battle() засчитает самовольный уход.
	h.show_tutorial = not (_in_endless_battle and _endless_daily)
	h.z_index = OVERLAY_Z
	add_child(h)
	h.closed.connect(func() -> void: h.queue_free())
	# Пакет tutorial: «Обучение» из «Как играть» запускает его принудительно, даже если флаг
	# tutorial/done уже стоит — это явная просьба игрока, а не автозапуск первой игры.
	h.tutorial_pressed.connect(func() -> void:
		h.queue_free()
		_hide_pause()
		# «Как играть» открыт из паузы боя — start_map() ниже паузу дерева не снимает
		# (в отличие от restart()/go_to_menu()), обучение иначе стартовало бы замороженным
		# (ревью, п.3).
		if world != null:
			world.set_paused(false)
		if _settle_abandoned_daily():
			return
		start_battle("wasteland")
		world.start_tutorial())


# ── Пакет cuts: катсцены ──────────────────────────────────────────────────────

## Карта Прораба — по данным: в её волнах есть группа типа "boss" (integrate1: раньше
## сверялись с id "foreman", которого нет, — в кампании катсцена не сработала бы; id карт
## переделывает пакет maps, а сам босс в волнах — и есть смысл «выход Прораба»).
static func _has_boss(map_id: String) -> bool:
	for wave: Dictionary in Campaign.map(map_id).get("waves", []):
		for g: Dictionary in wave.get("groups", []):
			if String(g.get("type", "")) == "boss":
				return true
	return false


func _is_first_map(map_id: String) -> bool:
	var all := Campaign.maps()
	return not all.is_empty() and String(all[0].get("id", "")) == map_id


## Проигрывает катсцену поверх текущего экрана (тот прячется, не восстанавливается — вызывающий
## сам решает, что показать после `on_done`, обычно повторный вызов себя же с уже стоящим флагом).
func _play_cutscene(frames: Array[LegionCutscene.Frame], audio: LegionAudio,
		on_done: Callable) -> void:
	_teardown_screen()
	var c := LegionCutscene.new()
	c.z_index = OVERLAY_Z
	add_child(c)
	c.finished.connect(on_done, CONNECT_ONE_SHOT)
	c.play(frames, audio)


## polish1: раньше искала узел звука среди детей мира (был только там); теперь `audio` — узел
## кампании целиком (см. `_ensure_audio()`), метод остался тонкой обёрткой ради вызывающих мест
## вне этого файла (`tests/legion_cutscene_flow_test.gd`) — не null уже с первого экрана меню,
## не только «мир между картами».
func _find_world_audio() -> LegionAudio:
	return audio


func _load_video(path: String) -> VideoStream:
	if not ResourceLoader.exists(path):
		return null
	return load(path) as VideoStream


func _intro_frames() -> Array[LegionCutscene.Frame]:
	return [
		LegionCutscene.Frame.new(
			"Некромант открыл ИП. Штат — скелеты, офис — кладбище, клиент — вечность.",
			# v19: ролик выключен — в оживлении пар из кружки идёт через лицо и «стирает» глаз
			# (кадры 36–144; обрезкой не спасти). Картинка чистая, наезд как у остальных кадров.
			# Вернуть ролик: четвёртым аргументом _load_video(CUT_INTRO_1_VIDEO_PATH).
			&"lg_intro_1", CUT_INTRO_1),
		LegionCutscene.Frame.new(
			"Скелеты работают по договору: пока договор действует, они стоят строем.",
			&"lg_intro_2", CUT_INTRO_2),
		LegionCutscene.Frame.new(
			"Истёк договор — подрядчики идут в натиск. Вовремя продлевать — целое искусство.",
			&"lg_intro_3", CUT_INTRO_3),
		LegionCutscene.Frame.new(
			"А из Ада уже выехала проверка. Котёл Душ надо отстоять. Приступаем.",
			&"lg_intro_4", CUT_INTRO_4),
	]


func _boss_frames() -> Array[LegionCutscene.Frame]:
	return [
		LegionCutscene.Frame.new(
			"Явка обязательна. Я Прораб Ада, и я по вашу душу — в прямом смысле.",
			&"lg_boss_appear", CUT_BOSS_APPEAR),
	]


func _finale_frames() -> Array[LegionCutscene.Frame]:
	return [
		LegionCutscene.Frame.new(
			"Акт подписан без замечаний. Котёл цел, репутация конторы тоже.",
			&"lg_victory_1", CUT_FINALE_1),
		LegionCutscene.Frame.new(
			"Ну наконец-то! Сдал объект, можно спать.",
			&"lg_victory_2", CUT_FINALE_2),
	]


# ── Служебное ────────────────────────────────────────────────────────────────

func _set_screen(node: Control) -> void:
	node.z_index = OVERLAY_Z
	add_child(node)
	screen = node
	_cover_battle(true)


## B-093: экраны вне боя (итог, поправки, «Контора», герой, меню) — узлы-Control на холсте 0, а
## слои боя (HUD 5, панель навыков и плашка урока 6) живут с миром и рисовались поверх: панель
## волн «Все волны вызваны / Вызвать (F)» и полоска видов висели на экране героя. Пока стоит
## экран, слои мира спрятаны; start_battle показывает их снова.
func _cover_battle(on: bool) -> void:
	if world == null or not is_instance_valid(world):
		return
	for layer: Node in world.find_children("*", "CanvasLayer", true, false):
		(layer as CanvasLayer).visible = not on


func _teardown_screen() -> void:
	if screen != null:
		screen.queue_free()
		screen = null


## --dev screen=menu|briefing|result_win|result_lose|result_win_campaign|upgrade|settings|
## office|hero|howto|menu_endless|menu_daily_locked|endless_briefing|necrolog|necrolog_abandon|
## collection (+ --shot ПУТЬ) — кадр экрана вне боя для приёмки (задание пакета flow, тот же
## паттерн, что tests/legion_ui_preview.gd; шесть последних — mode line, BOOK §1, D-0927-96/-162).
## Прогресс — во временный файл сохранения, реальный user://legion.cfg владельца не трогаем.
func _capture_dev_screen(screen_name: String, shot_path: String, shot_frame: int) -> void:
	Campaign.set_save_path("user://legion_dev_shot.cfg")
	Campaign.reset()
	match screen_name:
		"menu":
			var maps := Campaign.maps()
			if not maps.is_empty():
				Campaign.record_result(String(maps[0].get("id", "")), true, 0.9)
			show_menu()
		"briefing":
			var maps2 := Campaign.maps()
			if maps2.is_empty():
				get_tree().quit(1)
				return
			show_briefing(String(maps2[mini(1, maps2.size() - 1)].get("id", "")))
		"result_win", "result_lose", "result_win_campaign":
			var victory := screen_name != "result_lose"
			var campaign_complete := screen_name == "result_win_campaign"
			_teardown_screen()
			var r := LegionResult.new()
			_set_screen(r)
			r.call_deferred("show_result", victory, {
				"map_title": "Прораб" if campaign_complete else "Мост через Стикс",
				"cauldron_hp": 160.0 if victory else 0.0,
				"cauldron_max": 200.0, "kills": 84, "lost": 12, "charges": 9,
				"refreshes": 21, "releases": 3, "releases_manual": 2, "time": 187.0,
			}, 3 if victory else 0, victory and not campaign_complete, campaign_complete,
				{"bounty": 45, "xp": 134, "leveled_up": victory, "level": 2})
		"upgrade":
			_teardown_screen()
			var p := UpgradePicker.new()
			_set_screen(p)
			var rng := RandomNumberGenerator.new()
			rng.seed = 1
			p.call_deferred("offer", Campaign.offer_upgrades(rng))
		"office":
			# meta: демо-прогресс, чтобы кадр показывал не только «Уровень 0 / всё заперто»
			# (задание meta — «Кадры экранов через --dev screen=...»).
			Campaign.unlock_all()
			for m in Campaign.maps():
				Campaign.record_result(String(m.get("id", "")), true, 0.9)
			Campaign.record_rewards(true, 3, 40)
			Campaign.record_rewards(true, 3, 40)
			Campaign.shop_buy("range", "laborer")
			Campaign.shop_buy("mana")
			show_office(show_menu)
		"hero":
			Campaign.record_rewards(true, 3, 400)   # опыт с запасом на несколько уровней
			Campaign.hero_rank_up(&"q")
			Campaign.hero_take_perk(&"perk_fast_hire")
			show_hero(show_menu)
		"settings":
			show_menu()
			_show_settings(true)
		"howto":
			# tutorial: кадр «Как играть» для приёмки (задание tutorial, item 5) — тот же паттерн,
			# что "settings" выше.
			show_menu()
			_show_howto()
		_:
			# кадры mode line (меню забега, брифинг, некрологи, коллекция) — свой файл, max-file-lines
			if not LegionModeDevShots.show(self, screen_name):
				push_error("legion_main: неизвестный --dev screen=%s" % screen_name)
				get_tree().quit(1)
				return
	for i in maxi(2, shot_frame):
		await get_tree().process_frame
	if shot_path != "":
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		var err := img.save_png(shot_path)
		print(JSON.stringify({"shot": shot_path, "screen": screen_name, "error": err}))
	get_tree().quit()


## --dev cutscene=intro|boss|finale (+ --shot ПУТЬ, --shot-frame N) — прогон одной катсцены
## вне брифинга/боя для приёмки (задание пакета cuts). Тот же паттерн кадра, что
## _capture_dev_screen: N кадров ожидания, затем PNG и выход.
func _capture_dev_cutscene(cutscene_name: String, shot_path: String, shot_frame: int) -> void:
	var frames: Array[LegionCutscene.Frame]
	match cutscene_name:
		"intro":
			frames = _intro_frames()
		"boss":
			frames = _boss_frames()
		"finale":
			frames = _finale_frames()
		_:
			push_error("legion_main: неизвестный --dev cutscene=%s" % cutscene_name)
			get_tree().quit(1)
			return
	var c := LegionCutscene.new()
	add_child(c)
	# polish1: раньше немая (audio=null) — теперь тот же узел, что и остальные экраны, реплики
	# реально проверяются (COMMON.md п.6, задание — "--dev cutscene=intro ... с журналом звука").
	c.play(frames, _ensure_audio())
	for i in maxi(2, shot_frame):
		await get_tree().process_frame
	if shot_path != "":
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		var err := img.save_png(shot_path)
		print(JSON.stringify({"shot": shot_path, "cutscene": cutscene_name, "error": err}))
	get_tree().quit()
