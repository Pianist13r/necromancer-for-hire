# gdlint: disable=max-public-methods,max-file-lines
class_name ContractField
extends Node2D
##
## Руны-договоры: ввод мыши, мана, черновик со стрелкой выпуска, распознавание подрисовки,
## таяние участков и вся отрисовка светящихся линий (стиль scripts/game/rune_field.gd).
##
## Мана утекает ПО МЕРЕ рисования, как в старой игре: кончилась — штрих перестаёт тянуться
## прямо сейчас, и это видно. Поэтому подрисовка «оплачивается по длине штриха» сама собой.
##
## Что делать с бойцами при таянии, решает мир (release_segment): поле знает только линии.
##
## v15 (пакет f0): вид договора — current_kind (клавиши 1/2/3, сигнал kind_changed); цена за
## пиксель, шаг мест и цвет линии — по виду (LegionCfg.UNIT_KINDS). Стрелка — одна на договор
## (Contract.dir). Арбитраж ЛКМ (DESIGN_V15 §12 п.5): нажатие сначала «ждёт»; сдвиг от точки
## нажатия >= TAP_SLOP — рисование ОТ точки нажатия, отпускание раньше — сигнал tap(pos)
## (меню участка пакета staff), договора нет и мана не тратится. press_consumer (если задан и
## вернул true) съедает нажатие целиком — так открытое меню ловит клик закрытия.
## Бот и тесты рисуют через API (add_contract / begin-extend-finish) — арбитраж их не касается.
##
## v17 (DESIGN_V17 §2): рогатка на ПКМ. Нажатие над живым участком — захват; сдвиг >= TAP_SLOP —
## натяжка: стрелка натиска ПРОТИВОПОЛОЖНА оттяжке, сила — по длине оттяжки, мир замедлен
## «Отсрочкой» (масштаб dt мира через real_tick()), зона удара золотится, если в ней враг.
## Отпустил — release_aimed(); сдвиг меньше порога — щелчок: release() ровно как раньше.
## Esc или ЛКМ во время захвата — отмена. Классика (Settings, controls/scheme) — ПКМ по нажатию,
## без натяжки и замедления (прежнее поведение).
##

## Короткий клик ЛКМ (сдвиг < TAP_SLOP от точки нажатия): не рисование, а «тап».
signal tap(pos: Vector2)
## Сменился вид договора для рисования (клавиши 1/2/3, HUD пакета core).
signal kind_changed(kind: StringName)
## Пробел/колесо повернули стрелку живого договора (зачёт шага «стрелка» обучения).
signal aimed(c: Contract)
## Заключена фигура: кольцо (c.ring) или восьмёрка/треугольник/квадрат (c.figure) — зачёт уроков.
signal figure_made(c: Contract)

const GLOW_W := 14.0
const MID_W := 6.0
const CORE_W := 2.6
const ARROW_LEN := 16.0
const ARROW_WING := 6.0
## Цвет черновика-подрисовки: игрок должен ДО отпускания кнопки видеть, что это продление,
## а не новая линия поперёк. Серебро, а не мятный: мятный совпадал со счетоводом (ΔE 0,09),
## а у серебра нет оттенка — ни с одним видом не путается.
const REFRESH_COLOR := Color(0.92, 0.95, 1.0)
## Стрелка — перед передним рядом строя (ряд ROW_OFFSET + полтела бойца), иначе её закрывают.
const ARROW_OFFSET := 20.0
const ARROW_COLOR := Color(0.93, 0.9, 1.0)
## Тревога стрелки (участку меньше SEG_BLINK): малиновая, «красное = опасность» заодно с давкой.
## Прежняя оранжевая совпала бы с линией подрядчика (ΔE 0,03) и перестала бы быть тревогой.
const ARROW_WARN := Color(1.0, 0.26, 0.4)
## Кто держит прицел (_aim_held): Пробел и зажатое колесо — одно и то же (Игорь 26.09), прицел
## жив, пока зажат хоть один.
const AIM_SPACE := 1
const AIM_WHEEL := 2
## «Оцепление» (раздел в конце файла). Цвет фигуры: подсказка черновика, «Сжать кольцо!», обод.
const RING_COLOR := Color(0.62, 0.95, 1.0)
const RING_LABEL := "Оцепление"
const RING_SQUEEZE_LABEL := "Сжать кольцо!"
## То же, когда стрелки кольца смотрят наружу (Пробел снаружи — круговая оборона).
const RING_BURST_LABEL := "Круговой удар!"
## Подпись натяжки у курсора — ЧТО делать, а не сколько силы (сила всегда полная, 26.09):
## пока в зоне нет врага — ждать, вошёл — отпускать. Тот же слот, что прежняя «Сила N%».
const SLING_WAIT_LABEL := "Жди врага в зоне"
const SLING_GO_LABEL := "Срывай!"
## Отступ подписи от краёв окна: x — слева/справа/снизу, y — сверху (ниже полосы HUD).
const SLING_HINT_MARGIN := Vector2(12.0, 64.0)
## Подпись у курсора: правее и выше острия, чтобы не закрывать сам штрих.
const RING_LABEL_OFFSET := Vector2(18.0, -16.0)
const RING_LABEL_SIZE := 20
## Схлопывание обода при сжатии, мс реального времени (хит-стоп мира его не тормозит).
const RING_FX_MS := 420.0
## Шаг стрелок черновика кольца по штриху, px (как участки договора).
const RING_DRAFT_ARROW_STEP := 64.0
## Зазор между «Точно!» и «Сжать кольцо!» по вертикали (всплывашки 30 px, вспухают до 48).
const RING_POPUP_GAP := 52.0
## Всплывашка встаёт над своей точкой на столько px и за жизнь всплывает ещё на POPUP_RISE;
## кегль вспухает до POPUP_POP × размер (_draw_popups).
const POPUP_LIFT := 34.0
const POPUP_RISE := 30.0
const POPUP_POP := 1.6
## Онлайн-«Схватка»: стрелка живого договора под Пробелом уходит командой не чаще раза в столько
## мс (и последней точкой на отпускание) — поток AIM на каждое движение мыши забил бы канал.
const NET_AIM_GAP_MS := 100

## Общий Input принадлежит приложению: обе стороны PvP и тестовые миры не должны
## возвращать накопление, пока на экране ещё осталось поле для рисования.
static var _input_fields := 0
static var _saved_accumulated_input := true

var world: LegionWorld = null
## Чьё поле (сторона боя, PvpSide.index; одиночка — 0). У каждой стороны PvP своё поле: мана,
## договоры, черновик (docs/pvp/DESIGN.md §2.4). Не `side`: так в этом файле зовут стрелку.
var owner_side := 0
## «Отсрочка» (замедление мира натяжкой рогатки). В PvP выключена: мир общий (DESIGN §2.5).
var delay_enabled := true
var mana := LegionCfg.MANA_MAX
var mana_max := LegionCfg.MANA_MAX
var mana_regen := LegionCfg.MANA_REGEN
var contracts: Array[Contract] = []
var active := false          ## рисовать можно только в бою
var human_input := true      ## бот играет — мышь игрока не мешает серии
var now := 0.0
var overlay: Node2D = null
## Вид следующего договора игрока. Менять — через set_kind().
var current_kind: StringName = LegionCfg.KIND_LABORER
## Callable(pos: Vector2) -> bool. Вернул true — нажатие ЛКМ поглощено (не рисование, не tap).
var press_consumer: Callable = Callable()
## Счётчики последнего кадра (тесты и замер): сколько линий нарисовано, сколько штрихов течения.
var drawn_lines := 0
var drawn_flow := 0
## slow/intuit: сколько вспышек «стена» показано (тесты).
var wall_bumps := 0

var recruit_r: Dictionary = {}
var unlocked: Dictionary = {}
## Кампания v20 (D-0926-46): открытые фигуры (ContractShape.RING/EIGHT/TRIANGLE/SQUARE -> bool).
## Закрытая фигура чертится обычной линией — распознавание её просто не видит. Вне кампании всё
## открыто.
var shapes: Dictionary = {}
## Стрелка отряда Пробелом/колесом открыта (кампания: с «Проходной»). Закрыта — клавиши молчат.
var aim_unlocked := true
var settlement_mult := 1.0
## polish1: перк «Мелкий шрифт» (camp_stat mana_cost_mult) — тот же множитель, что каждый
## Contract несёт сам (Contract.mana_cost_mult); setup() читает его один раз на карту.
var mana_cost_mult := 1.0
## Тот же множитель без предметов боя: «Чернила оптом» (LegionWorld.apply_items) умножают его.
var base_cost_mult := 1.0
var aura_enabled := LegionCfg.LINE_AURA_ENABLED
var path_queries := 0
## v17 рогатка: схема ввода (Settings.control_scheme() на старте карты) и шкала «Отсрочка».
var scheme := Settings.SCHEME_SLING
var delay := LegionCfg.DELAY_MAX
## Рисование выполняется этим же CanvasItem; помощник не добавляет узлов/трансформов.
var _renderer: ContractRenderer = null
var _draft := PackedVector2Array()
var _draft_len := 0.0
var _drawing := false
var _draft_dir := Vector2.ZERO
## «Оцепление»: черновик замкнут в кольцо (ContractShape.is_ring, пересчёт на каждой точке) —
## игрок видит это ДО отпускания кнопки.
var _draft_ring := false
## Восьмёрка/треугольник/квадрат (ContractShape.EIGHT/TRIANGLE/SQUARE) — черновик признан
## фигурой, пересчёт на каждой точке, как у кольца; &"" — нет. Кольцо по-прежнему в _draft_ring.
var _draft_fig: StringName = &""
## Вспышки обряда: {center, tips, r, ms}.
var _rite_fx: Array[Dictionary] = []
## Стрелки «крест-накрест» восьмёрки: {a, b, ms} — от центра петли к центру другой и обратно.
var _cross_fx: Array[Dictionary] = []
## Схлопывающиеся ободы сжатий кольца: {center, r, ms}.
var _ring_fx: Array[Dictionary] = []
var _space := false
var _aim_held := 0
## До этого FxClock.ms() прокрутка вид договора не меняет (нажатие колеса проворачивает).
var _wheel_quiet_ms := 0
## B-057: тик прокрутки, сменивший вид, — когда и с какого вида (серия тиков — вид до первого).
## Нажатие колеса в пределах WHEEL_CLICK_QUIET после такого тика возвращает прежний вид.
var _wheel_tick_ms := -1000000
var _wheel_prev_kind: StringName = &""
## B-044: Шифт зажат — штрих не подновляет живую линию, а ложится новой поверх (пакет). У человека
## — из модификаторов событий ввода; у штриха из сети — флаг команды STROKE (stroke()).
var _stack := false
## Что возьмут Пробел/колесо/ПКМ под курсором (pick_segment); пересчёт — только после движения
## мыши или смены линий (_hover_dirty), не каждый кадр.
var _hover: Dictionary = {}
var _hover_dirty := true
var _pen_wait := false
var _aim_contract: Contract = null
var _paths: Dictionary = {}
var _rings: Array[Array] = []
var _path_terrain: LegionTerrain = null
var _package_pairs: Array[Dictionary] = []
var _pair_times: Dictionary = {}
var _package_t := 0.0
var _preview: Contract = null
var _preview_plan: Array[Dictionary] = []
var _preview_t := 0.0
var _next_id := 1
var _pointer := Vector2.ZERO
## Сколько маны реально ушло на черновик: вид могут сменить посреди штриха, возврат — ровно это.
var _draft_cost := 0.0
## Арбитраж ЛКМ: нажато и ждём порога / нажатие съедено потребителем.
var _pressing := false
var _press_pos := Vector2.ZERO
var _press_pts := PackedVector2Array()
var _press_eaten := false
var _grab: Dictionary = {}          ## {contract, seg} захваченного ПКМ участка или {}
var _grab_pos := Vector2.ZERO       ## где нажата ПКМ — от неё меряется оттяжка
var _pull := Vector2.ZERO
var _slinging := false
var _aim: Dictionary = {}           ## sling_aim() этого кадра (превью и звук)
var _tick_t := 0.0
## Всплывающие слова: {pos, t[, text, color]}; без text — «Точно!».
var _popups: Array[Dictionary] = []
var _hits: Array[Dictionary] = []     ## кольца удара натиска: {pos, t, perfect}
var _lanes := PackedFloat32Array()   ## strike_clear: поперечные места стоящих бойцов участка
var _lanes_a := PackedFloat32Array()  ## и их места вдоль стрелки
## pack_lures: приманки плоскими массивами; _ls_* — отобранные для текущего участка
var _lp_pos := PackedVector2Array()
var _lp_speed := PackedFloat32Array()
var _lp_rad := PackedFloat32Array()
var _lp_ghost := PackedByteArray()
var _ls_a := PackedFloat32Array()
var _ls_lat := PackedFloat32Array()
var _ls_r := PackedFloat32Array()
var _ls_v := PackedFloat32Array()
var _ls_sig := PackedByteArray()
## Вид линий (только отрисовка, симуляцию не читает): Contract -> {born, alive, renew, renew_until,
## frame}. По нему видно рождение, продление и какие участки умерли с прошлого кадра.
var _vis: Dictionary = {}
var _vis_frame := 0
## Растворяющиеся участки: {poly, body, core, t0, seed}.
var _fading: Array[Dictionary] = []
## Переиспользуемый буфер штрихов течения/искр — в кадре не аллоцируем.
var _strokes := PackedVector2Array()
var _sfx: AudioStreamPlayer = null
## slow/intuit: штрих, начатый в скале, — вспышка «стена» у курсора {pos, ms} и когда последняя
## (не чаще IntuitCfg.WALL_GAP реальных секунд).
var _wall_fx: Array[Dictionary] = []
var _wall_ms := -1000000
## B-092: точка нажатия, если штрих начат в стене и начало перенесено на кромку (INF — нет).
var _begin_raw := Vector2.INF
## Онлайн-«Схватка»: черновик — превью человека (мана не тратится, договор уходит командой).
var _draft_net := false
## Онлайн-«Схватка»: когда ушла последняя команда AIM и куда смотрит неотправленная стрелка.
var _aim_sent_ms := -1000000
var _aim_unsent := Vector2.INF


func _enter_tree() -> void:
	# Standalone world tests/tools also receive the saved/default named controls.
	Controls.apply()
	if _input_fields == 0:
		_saved_accumulated_input = Input.use_accumulated_input
		# Накопление срезает повороты до одного motion на кадр и добавляет кадр задержки.
		# Отключаем ДО ЛКМ: первый быстрый штрих иначе уже приходит склеенным.
		Input.use_accumulated_input = false
	_input_fields += 1


func _exit_tree() -> void:
	_input_fields -= 1
	if _input_fields == 0:
		Input.use_accumulated_input = _saved_accumulated_input


func setup(w: LegionWorld) -> void:
	world = w
	recruit_r.clear()
	unlocked.clear()
	for kind in LegionCfg.KIND_ORDER:
		recruit_r[kind] = LegionCfg.RECRUIT_R + world.camp_stat(StringName("recruit_r_" + kind))
		unlocked[kind] = world.camp_stat(StringName("kind_unlocked_" + kind)) > 0.5
	# Новые фигуры перечислены ЯВНО (D-1002 §6): shapes.get(fig, true) иначе открыл бы
	# забытый ключ, а распознавание — это не то же, что разрешение кампании
	for fig: StringName in [ContractShape.RING, ContractShape.EIGHT, ContractShape.TRIANGLE,
			ContractShape.SQUARE, ContractShape.PENTAGON, ContractShape.D_SHAPE]:
		shapes[fig] = world.camp_stat(StringName("shape_unlocked_" + String(fig))) > 0.5
	aim_unlocked = world.camp_stat(&"control_unlocked_aim") > 0.5
	if not bool(unlocked.get(current_kind, true)):
		for kind in LegionCfg.KIND_ORDER:
			if bool(unlocked[kind]):
				current_kind = kind
				break
	settlement_mult = world.camp_stat(&"settlement_mult")
	base_cost_mult = world.camp_stat(&"mana_cost_mult")
	mana_cost_mult = base_cost_mult
	aura_enabled = int(world.dev.get("line_aura", int(LegionCfg.LINE_AURA_ENABLED))) != 0
	_paths.clear()
	path_queries = 0
	_path_terrain = world.terrain
	_package_pairs.clear()
	_pair_times.clear()
	_package_t = 0.0
	_space = false
	_aim_held = 0
	_aim_contract = null
	_hover = {}
	_hover_dirty = true
	_preview = null
	_preview_plan.clear()
	world.configure_contract_mana(self)
	mana = mana_max
	contracts.clear()
	# B-363: номера договоров — с 1 на каждой карте, а не сквозные по миру: иначе id (и трасса
	# бота) зависят от прошлых боёв в том же мире, а двум клиентам сети нужны одинаковые id
	_next_id = 1
	_draft.clear()
	_drawing = false
	_draft_ring = false
	_ring_fx.clear()
	_draft_cost = 0.0
	_pressing = false
	_press_eaten = false
	scheme = Settings.control_scheme()
	delay = LegionCfg.DELAY_MAX
	cancel_sling()
	_popups.clear()
	_hits.clear()
	_vis.clear()
	_fading.clear()
	_wall_fx.clear()
	wall_bumps = 0
	# часы поля — часы мира, а мир новой карты стартует с нуля; без сброса договор, заключённый
	# до первого тика, «рождался» бы в будущем прошлой карты (голова рождения висела на месте)
	now = 0.0
	# кольца удара натиска и звук — у поля человека за этим экраном (вне сети — сторона 0)
	if owner_side == w.local_side and not w.charge_impact.is_connected(_on_charge_impact):
		w.charge_impact.connect(_on_charge_impact)
	elif owner_side != w.local_side and w.charge_impact.is_connected(_on_charge_impact):
		w.charge_impact.disconnect(_on_charge_impact)
	if not w.segment_broken.is_connected(_on_segment_broken):
		w.segment_broken.connect(_on_segment_broken)
	if not w.spring_released.is_connected(_on_spring_released):
		w.spring_released.connect(_on_spring_released)
	# пауза посреди натяжки (кнопка меню) — отмена: отпускание ПКМ на паузе мы не увидим
	if not w.paused_changed.is_connected(_on_paused):
		w.paused_changed.connect(_on_paused)


func tick(delta: float, t: float) -> void:
	now = t
	if not _grab.is_empty() and not (_grab["contract"] as Contract).seg_alive(int(_grab["seg"])):
		cancel_sling()   # участок растаял или расторгнут, пока его держали
	if not _hover.is_empty() and not (_hover["contract"] as Contract).seg_alive(int(_hover["seg"])):
		_hover_dirty = true   # подсвеченный участок ушёл — под курсором может оказаться сосед
	_package_t += delta
	if _package_t >= LegionCfg.ASSIGN_INTERVAL:
		tick_packages(_package_t)
		_package_t = 0.0
	_preview_t -= delta
	if _drawing and _preview_t <= 0.0:
		update_preview()
		_preview_t = LegionCfg.ASSIGN_INTERVAL
	mana = minf(mana_max, mana + mana_regen * delta)
	var i := contracts.size() - 1
	while i >= 0:
		var c := contracts[i]
		# Подготовка фигуры (D-1002 §1): заряд копится, пока строй держит нужную долю углов
		# НЕПРЕРЫВНО, и обнуляется, как только просел. Ульта — только у заряженной фигуры.
		if c.charge_need() > 0:
			c.charge_t = minf(FigureCfg.CHARGE_TIME, c.charge_t + delta) \
				if c.charge_filled() else 0.0
		for s in c.seg_count():
			if c.seg_dead[s] != 0:
				continue
			c.seg_age[s] += delta
			if c.seg_age[s] >= c.ttl:
				if c.figure != &"":
					# фигуры тают целиком — одно событие, один порог (LegionFigures)
					world.figures.melt(c)
					break
				world.release_segment(c, s, &"melt")
		if is_stump(c):
			# B-345: пенёк гаснет на этом же шаге — слот свободен, места не набирают бойцов
			# (бойцов на нём нет: снимать некого, натиска нет)
			c.seg_dead.fill(1)
			for p in c.posts:
				p["dead"] = true
		if not c.alive():
			contracts.remove_at(i)
			world.on_contract_removed(c)
		i -= 1
	if world.no_view:
		return
	queue_redraw()
	if overlay != null:
		overlay.queue_redraw()


# ── API для бота и тестов ──────────────────────────────────────────────────

## B-345: «пенёк» — остаток линии после срыва (ПКМ/рогатка), на живых местах которой нет ни
## одного бойца (ни стоящего, ни идущего). Он гаснет в tick() на шаге срыва (D-1008-C2): раньше
## такие остатки до таяния (SEG_TTL) держали слот лимита и молча съедали новые штрихи, а «не
## считать их в лимит» обходилось (verifier: пенёк подновляли или он набирал бойцов — 10 живых
## договоров при лимите 6). Свежая линия без людей (срыва не было) — не пенёк. Фигуры и кольца
## срываются целиком — пеньков не оставляют. Решение — по состоянию мира шага (места, причины
## срыва), одно правило для человека, ботов и обоих клиентов «Схватки».
static func is_stump(c: Contract) -> bool:
	if c.shaped() or not c.alive():
		return false
	var torn := false
	for cause: StringName in c.release_causes.values():
		if cause != &"melt":
			torn = true
			break
	if not torn:
		return false
	for p in c.posts:
		if not p["dead"] and p["unit"] != null:
			return false
	return true


## Лимит MAX_CONTRACTS — все живые договоры (как у add_contract и pvp_bot): пеньки гаснут в
## tick() сами, отдельного счёта им не нужно.
func slots_full() -> bool:
	return contracts.size() >= LegionCfg.MAX_CONTRACTS


## Цвет черновика линии (ContractRenderer._draw_draft; part — "color" тело, "core" сердцевина):
## серебро — подновление, серый — новая линия упрётся в лимит (B-345, видно ещё до отпускания),
## иначе — цвет вида.
func draft_color(refresh_like: bool, part: String) -> Color:
	if not refresh_like and slots_full():
		return LegionCfg.LIMIT_DRAFT_COLOR
	if refresh_like and part == "color":
		return REFRESH_COLOR
	return _kind_color(current_kind, part)


## Подпись у пера при упоре в лимит; клавиша стирания — текущая (Controls.text).
static func limit_label() -> String:
	return Controls.text(LegionCfg.LIMIT_LABEL % LegionCfg.MAX_CONTRACTS)


## Новый договор по готовой ломаной. null — не хватило маны / лимит / слишком коротко.
## kind — вид договора (бот по умолчанию ставит подряд); цена — mana_per_px вида.
func add_contract(
	pts: PackedVector2Array, side: int, paid := true, kind: StringName = LegionCfg.KIND_LABORER
) -> Contract:
	if pts.size() < 2 or contracts.size() >= LegionCfg.MAX_CONTRACTS:
		return null
	var plen := _poly_len(pts)
	if plen < LegionCfg.LINE_MIN or plen > LegionCfg.LINE_MAX + 0.5:
		return null
	var cost := plen * _kind_price(kind) if paid else 0.0
	if paid:
		if cost > mana:
			return null
		_spend(cost)
	var c := _create(pts, side, kind)
	if c == null and paid:
		_refund(cost)   # угол фигуры в стене — фигура не заключена, мана возвращается
	return c


## Продлить участки договора (бот: «штрих» по этим участкам, цена — их длина).
func refresh(c: Contract, segs: PackedInt32Array, paid := true) -> bool:
	if segs.is_empty() or not contracts.has(c):
		return false
	if c.figure != &"":
		segs = _live_segs(c)   # фигура подновляется целиком: у неё один срок
	if paid:
		var cost := _segs_length(c, segs) * c.mana_per_px()
		if cost > mana:
			return false
		_spend(cost)
	var n := c.refresh_segments(segs)
	if n > 0:
		_mark_renew(c, segs)
		world.on_contract_refreshed(c, segs, n)
	return n > 0


## Досрочное расторжение участка (ПКМ): натиск сразу, мана не возвращается.
func release(c: Contract, seg: int) -> void:
	if contracts.has(c) and c.seg_alive(seg):
		if c.ring:
			_squeeze(c, -1.0, false)
			return
		if c.figure != &"":
			_fig_release(c, -1.0, false)
			return
		world.release_segment(c, seg, &"manual")


## v17 рогатка: расторжение с прицелом — стрелка dir, сила power 0..1, точный срыв perfect.
func release_aimed(c: Contract, seg: int, dir: Vector2, power: float, perfect: bool) -> void:
	if not contracts.has(c) or not c.seg_alive(seg):
		return
	if c.ring:
		_squeeze(c, power, perfect)
		return
	if c.figure != &"":
		# рогатка: выпуск по оси прицела (углы выходят по общей оси оттяжки); щелчок зовёт
		# release() напрямую и оси не даёт — тогда у фигуры своя геометрия
		_fig_release(c, power, perfect, dir)
		return
	world.release_segment_aimed(c, seg, dir, power, perfect)
	if perfect:
		perfect_fx(c.seg_center(seg))


## Надпись «Точно!» и удар точного срыва в точке at.
func perfect_fx(at: Vector2) -> void:
	_popups.append({"pos": at, "t": 0.0})
	_sound("mine_boom", 1.1)


## Какой договор штрих подрисовывает. {} — это новая линия (штрих поперёк или вдали).
## Правило: ≥ REFRESH_FRAC точек штриха ближе REFRESH_DIST к ЖИВОМУ участку одного договора
## любого вида; при зажатом Шифте (_stack) — всегда {}.
func match_refresh(stroke: PackedVector2Array) -> Dictionary:
	if stroke.size() < 2:
		return {}
	if _stack:
		return {}   # B-044: Шифт + штрих — новая линия поверх живой (пакет), не подновление
	var best: Dictionary = {}
	var best_frac := 0.0
	# B-044: подновляется живая линия ЛЮБОГО вида (вид линии сохраняется, цена — её mana_per_px):
	# раньше штрих «охраной» вдоль «подряда» молча ложился пакетом поверх
	for c in contracts:
		if is_stump(c):
			continue   # B-345: пенёк не подновляется — гаснет на ближайшем шаге
		var near := 0
		var segs := PackedInt32Array()
		for p in stroke:
			var pr := c.project(p)
			if pr.x > LegionCfg.REFRESH_DIST:
				continue
			var s := c.segment_at(pr.y)
			if not c.seg_alive(s):
				continue
			near += 1
			if not segs.has(s):
				segs.append(s)
		var frac := float(near) / float(stroke.size())
		if frac >= LegionCfg.REFRESH_FRAC and frac > best_frac:
			best_frac = frac
			best = {"contract": c, "segs": segs}
	if not best.is_empty() and (best["contract"] as Contract).figure != &"":
		best["segs"] = _live_segs(best["contract"])
	return best


## Длина живых участков из списка (без повторов) — цена их подновления.
static func _segs_length(c: Contract, segs: PackedInt32Array) -> float:
	var length := 0.0
	var seen := PackedInt32Array()
	for seg in segs:
		if seg >= 0 and seg < c.seg_count() and c.seg_alive(seg) and not seen.has(seg):
			seen.append(seg)
			length += minf(LegionCfg.SEG_LEN, c.length - seg * LegionCfg.SEG_LEN)
	return length


static func _live_segs(c: Contract) -> PackedInt32Array:
	var out := PackedInt32Array()
	for s in c.seg_count():
		if c.seg_alive(s):
			out.append(s)
	return out


## Участок под точкой — его берут ПКМ, Пробел и зажатое колесо. {} — рядом ничего.
## Меряем до того, что НАРИСОВАНО: живые участки по отдельности (раньше — проекция на всю
## ломаную, и мёртвый участок у стыка заслонял живого соседа), прогнутый давкой — по изгибу
## (контур уходит до PRESS_BREAK от прямой, как раз когда его хочется отпустить пружиной), у
## участка со строем — ещё и по фигурам бойцов над линией (LegionCfg.PICK_BODY_H). Радиус —
## pick_radius(), побеждает ближайший. Ничья по очкам — у кого ближе сама линия (попадание по
## линии важнее попадания по строю), дальше — меньший id договора и номер участка: выбор не
## зависит от порядка договоров в списке (verifier 26.09: ничья доставалась созданному позже).
func pick_segment(p: Vector2) -> Dictionary:
	var best: Dictionary = {}
	var r := pick_radius()
	var best_key := [INF, INF, 0, 0]
	for c in contracts:
		for s in c.seg_count():
			if not c.seg_alive(s):
				continue
			var poly := c.bent_poly(s)
			var direct := _poly_dist(p, poly)
			var d := direct
			# по строю — только если курсор на фигурах: полоса вниз не длиннее верха голов, и
			# радиус к ней не прибавляется (иначе ПКМ по пустой земле над строем срывала участок)
			if direct > LegionCfg.PICK_BODY_PENALTY \
					and direct <= LegionCfg.PICK_BODY_H + LegionCfg.PICK_BODY_SLOP \
					and c.seg_manned(s) > 0:
				var band := _band_dist(p, poly)
				if band <= LegionCfg.PICK_BODY_SLOP:
					d = minf(d, band + LegionCfg.PICK_BODY_PENALTY)
			# B-058: шеврон стрелки — то же, что рисует ContractRenderer._draw_arrow (ARROW_OFFSET..
			# +ARROW_LEN перед центром участка). Дороже прямого попадания: линия соседа побеждает.
			if direct > LegionCfg.PICK_ARROW_PENALTY:
				var n := c.seg_dir(s)
				var base := c.seg_center(s) + n * ARROW_OFFSET
				var arrow := p.distance_to(Geometry2D.get_closest_point_to_segment(
					p, base, base + n * ARROW_LEN))
				d = minf(d, arrow + LegionCfg.PICK_ARROW_PENALTY)
			if d > r:
				continue
			var key := [d, direct, c.id, s]
			if best.is_empty() or _key_less(key, best_key):
				best_key = key
				best = {"contract": c, "seg": s}
	return best


static func _key_less(a: Array, b: Array) -> bool:
	for i in a.size():
		if a[i] != b[i]:
			return a[i] < b[i]
	return false


## Радиус захвата в px мира: постоянный на экране (LegionCfg.PICK_SCREEN_R), в пределах MIN–MAX.
func pick_radius() -> float:
	var s := _screen_scale()
	if s <= 0.0:
		return LegionCfg.PICK_R_MAX
	# потолок — тоже экранный: в «Схватке» (вид ×0,8) участок берётся с того же расстояния на
	# экране, что в одиночке, а не ужимается масштабом (P5a)
	var cap := LegionCfg.PICK_R_MAX / (world.view_scale() if world != null else 1.0)
	return clampf(LegionCfg.PICK_SCREEN_R / s, LegionCfg.PICK_R_MIN, cap)


## Сколько пикселей экрана в пикселе мира: растяжение окна (canvas_items) × трансформ поля.
func _screen_scale() -> float:
	if not is_inside_tree():
		return 0.0
	# масштаб вида поля (view_xf), а не камеры: в игре камера всегда в масштабе вида, а крупный план
	# режиссёра записи (REC-07) не должен менять допуски захвата — ввод от камеры не зависит
	return get_viewport().get_final_transform().get_scale().x \
		* (world.view_scale() if world != null else 1.0)


static func _poly_dist(p: Vector2, poly: PackedVector2Array) -> float:
	var best := INF
	for i in range(1, poly.size()):
		best = minf(best, p.distance_to(Geometry2D.get_closest_point_to_segment(p, poly[i - 1], poly[i])))
	return best


## Расстояние от полосы «курсор — PICK_BODY_H ниже» до ломаной: курсор на фигуре бойца, линия
## под его ступнями.
static func _band_dist(p: Vector2, poly: PackedVector2Array) -> float:
	var q := p + Vector2(0.0, LegionCfg.PICK_BODY_H)
	var best := INF
	for i in range(1, poly.size()):
		var pair := Geometry2D.get_closest_points_between_segments(p, q, poly[i - 1], poly[i])
		best = minf(best, pair[0].distance_to(pair[1]))
	return best


## Что сейчас возьмут Пробел/колесо/ПКМ — для подсветки: {contract, seg}; seg −1 — идёт прицел,
## подсвечен прицельный договор целиком. Пока чертишь, жмёшь ЛКМ или держишь рогатку — {}.
func hover_pick() -> Dictionary:
	if not active or not human_input:
		return {}
	if _space:
		if _drawing or _aim_contract == null or not _aim_contract.alive():
			return {}
		return {"contract": _aim_contract, "seg": -1}
	if _drawing or _pressing or not _grab.is_empty():
		return {}
	if _hover_dirty:
		_hover = pick_segment(_pointer)
		_hover_dirty = false
	return _hover


## Сторона стрелки по умолчанию: ОТ Котла.
func default_side(pts: PackedVector2Array) -> int:
	var a := pts[0]
	var b := pts[pts.size() - 1]
	var right := Contract.side_normal(Contract.chord_dir(pts), 1)
	var mid := a.lerp(b, 0.5) + LegionCfg.CORE_CLIP_OFFSET
	return 1 if right.dot(mid - world.cauldron_of(owner_side)) >= 0.0 else -1


## Стрелка натиска по умолчанию: перпендикуляр к хорде, ОТ Котла (DESIGN_V15 §4).
func default_dir(pts: PackedVector2Array) -> Vector2:
	return Contract.side_normal(Contract.chord_dir(pts), default_side(pts))


## Сторона стрелки штриха игрока (B-123): навстречу ближайшему подходу врага по дороге — к точке
## дороги на STROKE_LOOK_BACK px пути выше по течению от ближайшей к линии. Строй поперёк дороги
## смотрит вверх по дороге, фланг вдоль неё — на дорогу. «От Котла» на змейке «Пустыря»
## смотрело мимо половины мест, а поворот стрелки открывается только с «Проходной». Дорог рядом
## нет (дальше STROKE_ROAD_R) — прежнее «от Котла». Бот и тесты, строящие линии по данным, зовут
## default_side: их числа не меняются.
func stroke_side(pts: PackedVector2Array) -> int:
	var mid := pts[0].lerp(pts[pts.size() - 1], 0.5)
	var target := approach_point(mid)
	if target == Vector2.INF:
		return default_side(pts)
	var right := Contract.side_normal(Contract.chord_dir(pts), 1)
	var d := right.dot(target - mid)
	if absf(d) < 0.001:
		return default_side(pts)
	return 1 if d > 0.0 else -1


func stroke_dir(pts: PackedVector2Array) -> Vector2:
	return Contract.side_normal(Contract.chord_dir(pts), stroke_side(pts))


## Откуда к точке at подходит враг: точка ближайшей дороги на STROKE_LOOK_BACK px пути выше по
## течению (дороги идут от ворот к Котлу). INF — дорог ближе STROKE_ROAD_R нет.
func approach_point(at: Vector2) -> Vector2:
	var best_d := LegionCfg.STROKE_ROAD_R
	var best := Vector2.INF
	for r: Dictionary in world.map.get("roads", []):
		var path := world.road_path(String(r.get("id", "")))
		var run := 0.0
		for i in range(1, path.size()):
			var q := Geometry2D.get_closest_point_to_segment(at, path[i - 1], path[i])
			var d := at.distance_to(q)
			if d < best_d:
				best_d = d
				best = _path_point(path, run + path[i - 1].distance_to(q) - LegionCfg.STROKE_LOOK_BACK)
			run += path[i - 1].distance_to(path[i])
	return best


static func _path_point(path: PackedVector2Array, dist: float) -> Vector2:
	if dist <= 0.0:
		return path[0]
	for i in range(1, path.size()):
		var seg := path[i - 1].distance_to(path[i])
		if dist <= seg:
			return path[i - 1].lerp(path[i], dist / seg) if seg > 0.0 else path[i]
		dist -= seg
	return path[path.size() - 1]


## Выбрать вид следующего договора. Неизвестный вид — отказ (false).
func set_kind(kind: StringName) -> bool:
	if not LegionCfg.UNIT_KINDS.has(kind) or not bool(unlocked.get(kind, true)):
		return false
	if kind != current_kind:
		if _drawing:
			finish()
		current_kind = kind
		kind_changed.emit(kind)
	return true


## v18: следующий открытый вид договора по кругу (step +1 — вниз по списку, −1 — вверх).
## Возвращает, сменился ли вид (открыт один — нет).
func cycle_kind(step: int) -> bool:
	var order := LegionCfg.KIND_ORDER
	var i := order.find(current_kind)
	for k in range(1, order.size()):
		var kind: StringName = order[posmod(i + step * k, order.size())]
		if bool(unlocked.get(kind, true)):
			return set_kind(kind)
	return false


# ── API стороны (PvpCmd): то же, что делает рука, но смыслом, а не событиями мыши ──

## Договор этого поля по id; null — нет такого (или он чужой: id ищутся только здесь).
func by_id(id: int) -> Contract:
	for c in contracts:
		if c.id == id:
			return c
	return null


## Штрих целиком: те же begin/extend/finish, что у мыши, — мана, скалы, подрисовка, фигуры и
## отказы ровно как у человека. arrow — точка, куда смотрит стрелка (как Пробел посреди штриха);
## INF — стрелка по умолчанию. stack — штрих с Шифтом (B-044): новая линия поверх живой, без
## подновления. {contract, refreshed} или {contract: null, reason}.
func stroke(pts: PackedVector2Array, kind: StringName, arrow := Vector2.INF,
		stack := false) -> Dictionary:
	# Шифт штриха из сети — флаг команды, а не клавиатура этого клиента: решение одинаково у обоих
	var held := _stack
	_stack = stack
	var res := _stroke(pts, kind, arrow)
	_stack = held
	return res


func _stroke(pts: PackedVector2Array, kind: StringName, arrow: Vector2) -> Dictionary:
	if not active:
		return {"contract": null, "reason": "inactive"}
	if not set_kind(kind):
		return {"contract": null, "reason": "kind"}
	cancel()
	var before := _next_id
	begin(pts[0])
	if not _drawing:
		return {"contract": null, "reason": "rock" if world.terrain.is_rock(pts[0]) else "mana"}
	for i in range(1, pts.size()):
		extend(pts[i])
	if arrow != Vector2.INF and _draft.size() >= 2:
		var v := arrow - _poly_point(_draft, _draft_len * 0.5)
		if not v.is_zero_approx():
			_draft_dir = v.normalized()
	var hit := match_refresh(_draft) if _draft_len >= LegionCfg.LINE_MIN else {}
	finish()
	if _next_id > before:
		return {"contract": contracts[contracts.size() - 1], "refreshed": false}
	if not hit.is_empty():
		return {"contract": hit["contract"], "refreshed": true}
	return {"contract": null, "reason": "rejected"}


## Стрелка живого договора к точке at (Пробел над договором и движение мыши).
func aim_contract(c: Contract, at: Vector2) -> void:
	if not contracts.has(c) or not c.alive():
		return
	if c.ring:
		c.set_ring_out(not ContractShape.inside(at, c.points))
	elif c.figure == &"":
		c.set_dir(at - c.point_at(c.length * 0.5))
		aimed.emit(c)


## Рогатка смыслом: оттяжка pull от участка — стрелка против неё, сила и «Точно!» — тем же
## sling_aim(), что у мыши (решает мир, не клиент). false — участка нет или стрелка нулевая.
func sling_release(c: Contract, seg: int, pull: Vector2) -> bool:
	if not contracts.has(c) or not c.seg_alive(seg) or pull.is_zero_approx():
		return false
	var keep := [_grab, _grab_pos, _pull, _slinging, _aim]
	_grab = {"contract": c, "seg": seg}
	_grab_pos = c.seg_center(seg)
	_pull = _grab_pos + pull
	var aim := sling_aim()
	_grab = keep[0]
	_grab_pos = keep[1]
	_pull = keep[2]
	_slinging = keep[3]
	_aim = keep[4]
	if aim.is_empty() or (aim["dir"] as Vector2).is_zero_approx():
		return false
	release_aimed(c, seg, aim["dir"], float(aim["power"]), bool(aim["perfect"]))
	return true


## Щелчок ПКМ смыслом: по золотому участку — «Точно!», иначе прежний роспуск.
func click(c: Contract, seg: int) -> void:
	if contracts.has(c) and c.seg_alive(seg):
		_click_release(c, seg)


## Таб смыслом (команда ERASE): кусок линии вокруг seg — в натиск; фигура — целиком, как щелчок.
## Без проверок жеста руки (erase_at): у команды жеста нет. Возвращает, сколько участков сорвано.
func erase(c: Contract, seg: int) -> int:
	if not contracts.has(c) or not c.seg_alive(seg):
		return 0
	return _erase_core(c, seg)


# ── Онлайн-«Схватка» (docs/pvp/NET_LOCKSTEP.md): ввод человека — команды, а не мир ──────

## Жест руки этого поля сейчас уходит командой: сетевой матч, поле человека за этим экраном, и
## мир не исполняет пришедшую команду (тогда поле работает как у бота — по-настоящему).
func _net_preview() -> bool:
	return world != null and world.net_mode and owner_side == world.local_side \
		and not world.net_applying


## Черновик и вид человека — на время чужой (или своей вернувшейся) команды: поле исполняет её
## на чистом листе. Только вид руки, бой из этих полей ничего не читает.
func net_stash() -> Array:
	var keep := [_drawing, _draft, _draft_len, _draft_cost, _draft_ring, _draft_fig, _draft_dir,
		_pen_wait, _begin_raw, _draft_net, current_kind, _preview, _preview_plan.duplicate(),
		_preview_t]
	_drawing = false
	_draft = PackedVector2Array()
	_draft_len = 0.0
	_draft_cost = 0.0
	_draft_ring = false
	_draft_fig = &""
	_draft_dir = Vector2.ZERO
	_pen_wait = false
	_begin_raw = Vector2.INF
	_draft_net = false
	return keep


func net_restore(keep: Array) -> void:
	_drawing = keep[0]
	_draft = keep[1]
	_draft_len = keep[2]
	_draft_cost = keep[3]
	_draft_ring = keep[4]
	_draft_fig = keep[5]
	_draft_dir = keep[6]
	_pen_wait = keep[7]
	_begin_raw = keep[8]
	_draft_net = keep[9]
	current_kind = keep[10]
	_preview = keep[11]
	_preview_plan.assign(keep[12])
	_preview_t = keep[13]


## Штрих человека закончен: договор уходит командой STROKE (точки — по правилам PvpCmd), черновик
## гаснет без возврата маны — её и не брали. Короткий штрих без подрисовки — та же подпись, что
## у одиночки, и без команды.
func _net_finish() -> void:
	var pts := PvpCmd.stroke_points(_draft, world.world_size)
	var kind := current_kind
	var arrow := Vector2.INF
	if _draft_dir != Vector2.ZERO and pts.size() >= 2:
		arrow = PvpCmd.arrow_point(pts, _draft_dir, world.world_size)
	var short := _draft_len < min_len(_draft) and match_refresh(_draft).is_empty()
	if short:
		_short_bump(_draft)
	cancel()
	if not short and pts.size() >= 2:
		world.local_cmd(PvpCmd.stroke(pts, kind, arrow, _stack))


## Стрелка живого договора под Пробелом: командой AIM с прореживанием; force — последняя точка
## (отпускание Пробела), если она ещё не ушла.
func _net_aim(at: Vector2, force: bool) -> void:
	if _aim_contract == null or not _aim_contract.alive():
		return
	if not _aim_contract.ring and _aim_contract.figure != &"":
		return   # фигуры стрелкой не поворачиваются (aim_at)
	var ms := FxClock.ms()
	if force and _aim_unsent == Vector2.INF:
		return
	if not force and ms - _aim_sent_ms < NET_AIM_GAP_MS:
		_aim_unsent = at
		return
	_aim_sent_ms = ms
	_aim_unsent = Vector2.INF
	world.local_cmd(PvpCmd.aim(_aim_contract.id, at))


# ── Ввод человека ───────────────────────────────────────────────────────────

## Курсор — из КАЖДОГО события мыши, до интерфейса (как LegionWorld.aim_pos): движение над кнопкой
## HUD до _unhandled_input не доходит, и Пробел целился бы из места, где мышь была раньше.
func _input(event: InputEvent) -> void:
	if human_input:
		_track_stack(event)
	var m := event as InputEventMouse
	if m != null:
		_pointer = _to_world(m.position)
		if m is InputEventMouseMotion:
			_hover_dirty = true
		return
	var k := event as InputEventKey
	if k != null and event.is_action(&"erase_piece") and _battle_input():
		# Таб в бою — стирание куска. Гасим здесь, в _input: разбор интерфейса идёт раньше
		# _unhandled_input, и ui_focus_next увёл бы фокус на кнопку HUD (D-0929-10). На паузе и в
		# меню Таб по-прежнему ходит по кнопкам.
		get_viewport().set_input_as_handled()
		if k.pressed and not k.echo and not k.alt_pressed:
			erase_at(_pointer)


## B-044: Шифт — модификатор «пакет» (не переназначается: это не клавиша действия, а зажим к
## штриху). Сам Шифт — по нажатию/отпусканию, остальные события — по флагу модификатора.
func _track_stack(event: InputEvent) -> void:
	var k := event as InputEventKey
	if k != null and (k.keycode == KEY_SHIFT or k.physical_keycode == KEY_SHIFT):
		_stack = k.pressed
		return
	var mods := event as InputEventWithModifiers
	if mods != null:
		_stack = mods.shift_pressed


## Позиция события мыши (экран вьюпорта) → мир: единый вид поля мира (LegionWorld.view_xf, P5a).
func _to_world(p: Vector2) -> Vector2:
	return world.screen_to_world(p) if world != null else p


## Меню Esc «Схватки» — та же пауза для ввода (B-361): самой паузы в PvP нет, бой идёт под меню.
func _battle_input() -> bool:
	return active and human_input and not world.paused and not world.is_ground_loading() \
		and not world.pvp_menu_open()


func _unhandled_input(event: InputEvent) -> void:
	if not active or not human_input or world.paused or world.is_ground_loading():
		return
	# B-361: под меню «Схватки» нажатия (вид 1/2/3, Пробел, кнопки мыши, колесо) не берём;
	# отпускания и движение проходят — прицел и штрих, начатые до меню, не залипают
	if world.pvp_menu_open() and _is_press(event):
		return
	if not _grab.is_empty() and _sling_cancel_event(event):
		cancel_sling()
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseMotion:
		_pointer = _to_world((event as InputEventMouseMotion).position)
		_hover_dirty = true
		if not _grab.is_empty():
			_sling_move(_pointer)
		elif _space:
			aim_at(_pointer)
		elif _pressing:
			_press_move(_pointer)
		elif _drawing:
			extend(_pointer)
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		_pointer = _to_world(mb.position)
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_press(_pointer)
			else:
				_release(_pointer)
		elif mb.button_index == MOUSE_BUTTON_RIGHT:
			if mb.pressed:
				_right_press(_pointer)
			else:
				_right_release(_pointer)
		elif mb.button_index == MOUSE_BUTTON_MIDDLE:
			# Зажатое колесо = Пробел (Игорь 26.09; отменяет «нажатие колеса не используем»
			# D-0926-12). Тики прокрутки вокруг нажатия глушим — см. WHEEL_CLICK_QUIET.
			var ms := FxClock.ms()
			var quiet := roundi(LegionCfg.WHEEL_CLICK_QUIET * 1000.0)
			# B-057: тики, пришедшие ДО нажатия (колесо провернулось под пальцем), окно тишины не
			# ловило — вид уже сменился. Возвращаем вид, бывший до серии этих тиков.
			if mb.pressed and ms - _wheel_tick_ms <= quiet and _wheel_prev_kind != &"" \
					and _wheel_prev_kind != current_kind and not _drawing:
				set_kind(_wheel_prev_kind)
			_wheel_tick_ms = -1000000
			_wheel_quiet_ms = ms + quiet
			_hold_aim(AIM_WHEEL, mb.pressed)
			get_viewport().set_input_as_handled()
		elif mb.pressed and (mb.button_index == MOUSE_BUTTON_WHEEL_UP
				or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN):
			# v18: прокрутка — вид договора по кругу. Во время штриха и натяжки колесо молчит:
			# смена вида завершает штрих (set_kind → finish), а колесо задеть случайно легче,
			# чем 1/2/3 (находка verifier 26.09). Молчит и пока колесо зажато и сразу после.
			if not is_slinging() and not _drawing and not _pressing \
					and _aim_held & AIM_WHEEL == 0 and FxClock.ms() >= _wheel_quiet_ms:
				var ms := FxClock.ms()
				if ms - _wheel_tick_ms > roundi(LegionCfg.WHEEL_CLICK_QUIET * 1000.0):
					_wheel_prev_kind = current_kind   # первый тик серии — запомнить, откуда
				_wheel_tick_ms = ms
				cycle_kind(-1 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 1)
			get_viewport().set_input_as_handled()
		return
	if event is InputEventKey:
		var k := event as InputEventKey
		if k.echo:
			return
		if event.is_action(&"aim_contract"):
			_hold_aim(AIM_SPACE, k.pressed)
			get_viewport().set_input_as_handled()
		elif k.pressed:
			for i in 3:
				if event.is_action([&"rune_normal", &"rune_frost", &"rune_ash"][i]):
					choose_kind(LegionCfg.KIND_ORDER[i])
					get_viewport().set_input_as_handled()
					break


static func _is_press(event: InputEvent) -> bool:
	return (event is InputEventKey or event is InputEventMouseButton) and event.is_pressed()


## Нажатие ЛКМ: потребитель (меню) — первым; иначе ждём, клик это или протяжка.
func _press(at: Vector2) -> void:
	cancel()
	_pressing = false
	_press_eaten = false
	if press_consumer.is_valid() and bool(press_consumer.call(at)):
		_press_eaten = true
		return
	_pressing = true
	_press_pos = at
	_press_pts = PackedVector2Array([at])


func _press_move(at: Vector2) -> void:
	_press_pts.append(at)
	if at.distance_to(_press_pos) < LegionCfg.TAP_SLOP:
		return
	# порог пройден: штрих начинается ОТ точки нажатия, накопленные точки не теряются
	_pressing = false
	begin(_press_pos)
	for i in range(1, _press_pts.size()):
		extend(_press_pts[i])
	_press_pts = PackedVector2Array()


func _release(at: Vector2) -> void:
	if _press_eaten:
		_press_eaten = false
		return
	# Между последним motion и отпусканием курсор мог уйти дальше (быстрый жест,
	# тяжёлый кадр). Эта точка проходит те же стены, цену и предел длины, что motion.
	if _pressing:
		_press_move(at)
	if _pressing:
		_pressing = false
		_press_pts = PackedVector2Array()
		# B-055: карточки вида и «Вызвать» мышь не ловят (иначе штрих над ними не начинался) —
		# короткий щелчок по ним разбирает HUD; протяжка с них — обычный штрих.
		if _hud_tap(true):
			return
		tap.emit(_press_pos)
		return
	if _drawing:
		extend(at)
		# Дрогнувший щелчок по карточке (сдвиг больше TAP_SLOP, но линия короче минимума) — тоже
		# щелчок: до B-055 кнопка ловила его целиком, «коротко» под пальцем было бы новым отказом.
		if _draft_len < min_len(_draft) and _hud_tap(false):
			cancel()
			_hud_tap(true)
			return
	finish()


## Щелчок поля по кнопке HUD, которая сама мышь не ловит (B-055). act=false — только проверка.
func _hud_tap(act: bool) -> bool:
	return world != null and world.hud != null \
		and world.hud.ui_tap(world.world_to_screen(_press_pos), act)


## Выбор вида человеком (клавиши 1/2/3, карточка): откат вида колесом (B-057) больше не про него.
func choose_kind(kind: StringName) -> bool:
	_wheel_tick_ms = -1000000
	return set_kind(kind)


# ── v17: рогатка на ПКМ ─────────────────────────────────────────────────────────

## Нажатие ПКМ. Классика и ПКМ посреди штриха — роспуск сразу, как раньше; рогатка — захват.
func _right_press(at: Vector2) -> void:
	# Прежний захват, чьё отпускание потерялось (Alt+Tab с зажатой ПКМ), не должен сорваться
	# от щелчка по пустому месту (находка verifier v17). Схема — живая: переключатель в
	# настройках из паузы действует сразу, а не со следующей карты.
	cancel_sling()
	scheme = Settings.control_scheme()
	var hit := pick_segment(at)
	if hit.is_empty():
		return
	if scheme != Settings.SCHEME_SLING or _drawing:
		_click_release(hit["contract"], int(hit["seg"]))
		return
	_grab = hit
	_grab_pos = at
	_pull = at
	_slinging = false
	_aim = {}


func _sling_move(at: Vector2) -> void:
	_pull = at
	if not _slinging and _sling_armed(at):
		_slinging = true
		_tick_t = 0.0
	if _slinging:
		_aim = sling_aim()


## Взвод натяжки: оттяжка от SLING_ARM. Короче — ещё щелчок: дрожь руки при клике не превращается
## в выстрел вбок. У края окна курсору дальше некуда — там хватает TAP_SLOP (Игорь 26.09: «когда
## надо тянуть за край экрана, не всегда можно сильно тянуть»).
func _sling_armed(at: Vector2) -> bool:
	var d := at.distance_to(_grab_pos)
	if d >= LegionCfg.SLING_ARM:
		return true
	return d >= LegionCfg.TAP_SLOP and _at_view_edge(at)


## Курсор упёрся в край окна или ушёл за него (чёрные полосы, окно меньше экрана). В полноэкранном
## режиме ОС держит курсор на краю, и оттяжка к краю короче порога взвода.
func _at_view_edge(at: Vector2) -> bool:
	return not get_viewport().get_visible_rect().grow(-LegionCfg.SLING_EDGE_PAD).has_point(at)


## Отпускание ПКМ: натяжка — срыв по прицелу; оттяжка меньше TAP_SLOP — щелчок
## (_click_release); между TAP_SLOP и взводом — отмена (B-071: раньше это был щелчок, и отряд
## уходил по стрелке договора, а не туда, куда тянули).
func _right_release(at: Vector2) -> void:
	if _grab.is_empty():
		return
	_pull = at
	var c: Contract = _grab["contract"]
	var seg := int(_grab["seg"])
	var was_sling := _slinging or _sling_armed(at)
	var aim := sling_aim() if was_sling else {}
	var short_pull := not was_sling and at.distance_to(_grab_pos) >= LegionCfg.TAP_SLOP
	cancel_sling()
	if short_pull:
		return
	if not was_sling:
		_click_release(c, seg)
	elif not (aim["dir"] as Vector2).is_zero_approx():
		if _net_preview():   # сеть: оттяжку считает мир у обоих клиентов (sling_release)
			world.local_cmd(PvpCmd.sling(c.id, seg, at - _grab_pos))   # cancel_sling его не трогает
			return
		release_aimed(c, seg, aim["dir"], float(aim["power"]), bool(aim["perfect"]))


## Щелчок ПКМ игрока (slow/intuit): по золотому участку — «Точно!» по стрелке участка с полной
## силой, как у точного срыва рогаткой; по обычному — прежний роспуск. Только ввод человека:
## бот и тесты зовут release()/release_aimed() напрямую, их бой не меняется. Золото — то, что
## игрок видел (скан раз в 0,1 с), или то, что есть сейчас: враг, вышедший из зоны в эти 0,1 с,
## щелчок не обманывает.
func _click_release(c: Contract, seg: int) -> void:
	if _net_preview():   # сеть: «Точно!» или роспуск решит мир у обоих клиентов (команда CLICK)
		world.local_cmd(PvpCmd.click(c.id, seg))
		return
	if click_gold(c, seg) and contracts.has(c) and c.seg_alive(seg):
		release_aimed(c, seg, c.seg_dir(seg), 1.0, true)
		if world.intuit != null:
			world.intuit.on_done(&"gold")   # правильное действие сделано — совет больше не нужен
	else:
		release(c, seg)


## Щелчок ПКМ по этому участку сейчас — «Точно!» (правило _click_release; им же пользуется Таб).
func click_gold(c: Contract, seg: int) -> bool:
	# слой подсказок (intuit) — вид игрока стороны 0: чужому полю его скан не указ (PvP). В сети
	# скан (реальное время, только у человека) не читается: исход щелчка решает мир, одинаково у
	# обоих клиентов
	return seg_gold(c, seg) or (owner_side == 0 and not world.net_mode and world.intuit != null
		and world.intuit.is_gold(c, seg) and _can_strike(c, seg))


## Таб (slow/tab-erase): стереть кусок линии под at — его бойцы в натиск (ContractErase).
## Фигура — одна сущность: выпускается целиком обычным щелчком ПКМ (D-0929-09). Пока идёт штрих
## или нажата ЛКМ, держится рогатка или прицел Пробела/колеса — ничего (D-0929-10): у жеста уже
## есть хозяин, а срыв из-под штриха оборвал бы его. Возвращает, сколько участков сорвано.
func erase_at(at: Vector2) -> int:
	if _drawing or _pressing or not _grab.is_empty() or _space:
		return 0
	var hit := pick_segment(at)
	if hit.is_empty():
		return 0
	var c: Contract = hit["contract"]
	var seg := int(hit["seg"])
	if _net_preview():   # сеть: кусок сорвёт мир у обоих клиентов (команда ERASE)
		world.local_cmd(PvpCmd.erase(c.id, seg))
		return 0
	return _erase_core(c, seg)


## Сам Таб: линия — кусок (ContractErase), фигура — щелчком. Сорванное объявляет мир
## (`tab_erased`: урок Таба учит именно этому жесту, а не ПКМ — у обоих один сигнал срыва).
func _erase_core(c: Contract, seg: int) -> int:
	var charges := int(world.stats.get("charges", 0))
	var n := 0
	if not c.shaped():
		n = ContractErase.erase_run(self, c, seg)
	else:
		var before := ContractErase.live_count(c)
		_click_release(c, seg)
		n = before - ContractErase.live_count(c)
	if n > 0:
		world.tab_erased.emit(c, n, int(world.stats.get("charges", 0)) - charges)
	return n


## Срыв сейчас кого-то пошлёт (по золоту прошлого скана — вдруг бойцы ушли за 0,1 с): у линии —
## стоящий на этом участке, у кольца, восьмёрки и квадрата — на любом; треугольник — никогда.
func _can_strike(c: Contract, seg: int) -> bool:
	if not c.shaped():
		return not seg_strike(c, seg, 1.0).is_empty()
	for s in c.seg_count():
		if c.seg_alive(s) and not seg_strike(c, s, 1.0).is_empty():
			return true
	return false


## Участок «золотой»: враг в зоне «Точно!» при полной силе по стрелке участка (кольцо и фигуры —
## враг у любого их участка, как у ring_aim). Геометрия — та же, что у sling_aim.
## D-0927-53: и никакая приманка не перехватит натиск (strike_clear).
func seg_gold(c: Contract, seg: int) -> bool:
	if not contracts.has(c) or not c.seg_alive(seg):
		return false
	pack_live_lures()
	if not c.shaped():
		return _seg_gold_one(c, seg)
	for s in c.seg_count():
		if c.seg_alive(s) and _seg_gold_one(c, s):
			return true
	return false


## Перебором (без сетки слоя подсказок): враг в зоне участка s, и натиск не перехватят.
## Приманки — уже упакованы (pack_live_lures).
func _seg_gold_one(c: Contract, s: int) -> bool:
	var hit := seg_strike(c, s, 1.0)
	if hit.is_empty():
		return false
	var center := c.seg_center(s)
	var half_w := _seg_length(c, s) * 0.5
	if not zone_has_foe(center, hit["dir"], half_w, hit["depth"]):
		return false
	# и без приманок — через strike_clear: возьмёт ли кто-то врага зоны (B-086)
	return strike_clear(c, s, center, hit["dir"], half_w, hit["depth"],
		zone_foes(center, hit["dir"], half_w, hit["depth"]))


## Упаковать живые приманки поля (нотариусы, призраки — LegionGrid.is_lure) для strike_clear.
func pack_live_lures() -> void:
	var lures: Array[Foe] = []
	for f in world.foes:
		if f.is_active() and LegionGrid.is_lure(f):
			lures.append(f)
	pack_lures(lures)


## Приманки для strike_clear — в плоские массивы один раз на скан (слой подсказок) или на
## запрос: иначе свойства врагов читались бы заново для каждого участка и каждого врага зоны.
func pack_lures(lures: Array[Foe]) -> void:
	var n := lures.size()
	_lp_pos.resize(n)
	_lp_speed.resize(n)
	_lp_rad.resize(n)
	_lp_ghost.resize(n)
	for i in n:
		var f := lures[i]
		_lp_pos[i] = f.position
		_lp_speed[i] = f.speed
		_lp_rad[i] = f.radius
		_lp_ghost[i] = 1 if f.ghost else 0


## Враги в зоне удара (та же полоса, что у zone_has_foe), перебором.
func zone_foes(center: Vector2, dir: Vector2, half_w: float, depth: float) -> Array[Foe]:
	var out: Array[Foe] = []
	var side := dir.orthogonal()
	for f in world.foes:
		if f.is_active() and _in_zone(f, center, dir, side, half_w, depth):
			out.append(f)
	return out


## Приманка at ближе r к середине хоть одного живого участка фигуры c (кольцо, восьмёрка).
func _lure_near_shape(c: Contract, at: Vector2, r: float) -> bool:
	var r2 := r * r
	for k in c.seg_count():
		if c.seg_alive(k) and c.seg_center(k).distance_squared_to(at) <= r2:
			return true
	return false


# gdlint: disable=max-returns
## D-0927-53 (B-082), консервативное золото: срыв участка seg по стрелке dir наверняка ударит
## врага зоны «Точно!» (zone), и нотариус или призрак его не перехватит. Натиск выбирает цель
## заново каждый тик (LegionGrid.charge_target): нотариуса — в CHARGE_SEEK_SIGNER и конусе
## CHARGE_SIGNER_DOT, призрака — в CHARGE_SEEK_GHOST в любую сторону, оба важнее пехоты.
## Золоту хватает одного удара в зону: ищем врага зоны z, которого возьмёт хоть один стоящий
## боец (z впереди в его конусе: пехота — в узком CHARGE_SEEK_DOT и на полосе ±CHARGE_SEEK, нотариус
## — в широком, призрак — всегда), и отрезок пути этих бойцов до касания z (от строя до «вдоль
## z − досягаемость − радиус z») никакая приманка вне зоны не достаёт своим радиусом (и конусом)
## с запасом IntuitCfg.LURE_MARGIN (перевыбор цели, шаг вбок, отброс) плюс своим ходом за время
## до касания. Приманка в самой зоне — удар по ней и есть удар в зону. Проверка — формулой по
## отрезку, а не шагами по бойцам: скан раз в 0,1 с почти не тяжелеет. Приманки — упакованы
## (pack_lures / pack_live_lures).
## B-086: и без приманок — только если врага зоны возьмёт хоть один стоящий боец (раньше без
## приманок ответ был «да» не глядя: пехоту за краем зоны или сбоку от бойцов узкий конус не брал).
func strike_clear(c: Contract, seg: int, center: Vector2, dir: Vector2, half_w: float,
		depth: float, zone: Array[Foe]) -> bool:
	var n := _lp_pos.size()
	_pack_lanes(c, seg, center, dir)
	if not _zone_taken(zone, center, dir):
		return false
	if n == 0:
		return true
	var side := dir.orthogonal()
	var spec: Dictionary = LegionCfg.UNIT_KINDS[c.kind]
	var dash := maxf(1.0, float(spec["speed"]) * LegionCfg.CHARGE_SPEED_MULT
		* LegionCfg.SLING_SPEED.y)
	var reach := float(spec["reach"])
	var lane := LegionCfg.CHARGE_SEEK \
		* sqrt(1.0 - LegionCfg.CHARGE_SEEK_DOT * LegionCfg.CHARGE_SEEK_DOT)
	var cone_k := LegionCfg.CHARGE_SIGNER_DOT \
		/ sqrt(1.0 - LegionCfg.CHARGE_SIGNER_DOT * LegionCfg.CHARGE_SIGNER_DOT)
	var t0 := -LegionCfg.ROW_OFFSET
	var t_max := depth + LegionCfg.CORE_FOE_RADIUS_MAX   # дальше касания z не бывает
	# есть ли приманка в самой зоне: тогда натиск может выбрать и её (она ближе), и «наверняка
	# уведёт» ниже не решить
	var zone_lure := false
	for z in zone:
		zone_lure = zone_lure or LegionGrid.is_lure(z)
	# приманки, которые вообще могут достать этот участок (и не стоят в зоне), — в свои массивы
	_ls_a.resize(0)
	_ls_lat.resize(0)
	_ls_r.resize(0)
	_ls_v.resize(0)
	_ls_sig.resize(0)
	var band := half_w + lane + LegionCfg.CORE_FOE_RADIUS_MAX
	for i in n:
		var v := _lp_pos[i] - center
		var a := v.dot(dir)
		var lat := v.dot(side)
		var fr := _lp_rad[i]
		if a >= -fr and a <= depth + fr and absf(lat) <= half_w + fr:
			continue   # приманка в зоне «Точно!» — бить её и есть обещанное
		var ghost := _lp_ghost[i] != 0
		var r0 := LegionCfg.CHARGE_SEEK_GHOST if ghost else LegionCfg.CHARGE_SEEK_SIGNER
		if c.shaped() and _lure_near_shape(c, _lp_pos[i], r0 + IntuitCfg.LURE_MARGIN_SHAPE):
			# фигура срывается целиком: «Точно!» соседних участков отбрасывает приманку к любому
			# участку фигуры (кольцо 120 px: призрак в 20 px за кольцом подходил к центру на 45 px —
			# verify-gold 728b959). Приманка в досягаемости хоть одного участка — фигура не золото
			return false
		if not zone_lure:
			# быстрый ответ (плотная толпа, скан не тяжелеет): приманка уже в радиусе (и конусе)
			# у КАЖДОГО места строя участка — натиск всех бойцов уйдёт к приманкам с места
			var far_a := absf(a) + LegionCfg.ROW_OFFSET
			var far_l := absf(lat) + half_w
			if far_a * far_a + far_l * far_l <= r0 * r0 \
					and (ghost or a - LegionCfg.ROW_OFFSET >= cone_k * far_l):
				return false
		# фигура срывается целиком: залпы соседних участков отбрасывают приманку внутрь (кольцо
		# внутрь, призрак в 40 px за кольцом — за 0,1 с на 75 px ближе; verify-gold e7f7790)
		var r := r0 + (IntuitCfg.LURE_MARGIN_SHAPE if c.shaped() else IntuitCfg.LURE_MARGIN)
		var r_far := r + _lp_speed[i] * (t_max - t0) / dash
		if a < t0 - r_far or a > t_max + r_far or absf(lat) > band + r_far:
			continue   # эта приманка не достанет путь бойцов участка ни при каком ходе
		_ls_a.append(a)
		_ls_lat.append(lat)
		_ls_r.append(r)
		_ls_v.append(_lp_speed[i])
		_ls_sig.append(0 if _lp_ghost[i] != 0 else 1)
	var m_cnt := _ls_a.size()
	if m_cnt == 0:
		return true
	# бойцы участка (поперёк и вдоль стрелки) уже в _lanes/_lanes_a — _pack_lanes в начале
	for z in zone:
		var zv := z.position - center
		var z_lat := zv.dot(side)
		var z_a := zv.dot(dir)
		var z_sig := z.type_id == "signer" and not z.ghost
		var lo_l := INF
		var hi_l := -INF
		for k in _lanes.size():
			if _lane_takes(k, z_sig, z.ghost, z.radius, z_lat, z_a):
				lo_l = minf(lo_l, minf(_lanes[k], z_lat))
				hi_l = maxf(hi_l, maxf(_lanes[k], z_lat))
		if lo_l > hi_l:
			continue   # z никто не возьмёт — удар по нему не обещан
		var t_c := maxf(t0, z_a - reach - z.radius)
		var t_go := (t_c - t0) / dash
		var clear := true
		for j in m_cnt:
			var a := _ls_a[j]
			var f_lat := _ls_lat[j]
			var m := _ls_v[j] * t_go
			var r := _ls_r[j] + m
			var l := maxf(0.0, maxf(lo_l - f_lat, f_lat - hi_l))   # до полосы бойцов
			if l > r or a < t0 - r or a > t_c + r:
				continue
			var s := sqrt(r * r - l * l)
			var hi := a + s
			if _ls_sig[j] != 0:
				# нотариус — только впереди, в конусе (с тем же запасом)
				hi = minf(hi, a - cone_k * l + IntuitCfg.LURE_MARGIN + m)
			if maxf(a - s, t0) <= minf(hi, t_c):
				clear = false
				break
		if clear:
			return true
	return false   # ни один враг зоны не достанется наверняка


## Стоящие бойцы участка seg: поперёк (_lanes) и вдоль (_lanes_a) стрелки от середины участка.
func _pack_lanes(c: Contract, seg: int, center: Vector2, dir: Vector2) -> void:
	var side := dir.orthogonal()
	_lanes.clear()
	_lanes_a.clear()
	for p in c.posts:
		var ps := int(p["seg"])
		if ps > seg:
			break   # места идут по линии — участки по возрастанию
		if ps != seg or p["dead"]:
			continue
		var u: Legionnaire = p["unit"]
		if u != null and u.alive and u.state == Legionnaire.State.POSTED:
			var uv := u.position - center
			_lanes.append(uv.dot(side))
			_lanes_a.append(uv.dot(dir))


## B-086: хоть одного врага зоны возьмёт хоть один стоящий боец (_pack_lanes уже вызван).
func _zone_taken(zone: Array[Foe], center: Vector2, dir: Vector2) -> bool:
	var side := dir.orthogonal()
	for z in zone:
		var zv := z.position - center
		var z_sig := z.type_id == "signer" and not z.ghost
		for k in _lanes.size():
			if _lane_takes(k, z_sig, z.ghost, z.radius, zv.dot(side), zv.dot(dir)):
				return true
	return false


## Боец k (из _pack_lanes) возьмёт врага: тот впереди в его конусе (LegionGrid.charge_target) —
## пехота в узком CHARGE_SEEK_DOT и на полосе ±CHARGE_SEEK, нотариус в широком, призрак всегда.
func _lane_takes(k: int, z_sig: bool, z_ghost: bool, z_r: float, z_lat: float, z_a: float) -> bool:
	var dl := absf(_lanes[k] - z_lat)
	var ahead := z_a - _lanes_a[k]
	var dot2 := LegionCfg.CHARGE_SEEK_DOT * LegionCfg.CHARGE_SEEK_DOT
	if z_sig:
		var sdot := LegionCfg.CHARGE_SIGNER_DOT
		return ahead >= sdot / sqrt(1.0 - sdot * sdot) * dl
	if z_ghost:
		return true
	return dl <= LegionCfg.CHARGE_SEEK * sqrt(1.0 - dot2) + z_r \
		and ahead >= LegionCfg.CHARGE_SEEK_DOT / sqrt(1.0 - dot2) * dl


## Враг f в зоне удара: та же полоса и те же допуски на радиус, что у zone_has_foe.
static func _in_zone(f: Foe, center: Vector2, dir: Vector2, side: Vector2, half_w: float,
		depth: float) -> bool:
	var v := f.position - center
	var along := v.dot(dir)
	return along >= -f.radius and along <= depth + f.radius \
		and absf(v.dot(side)) <= half_w + f.radius


## Куда и как далеко РЕАЛЬНО ударит натиск участка при силе power: {dir, depth} зоны «Точно!»
## и run — весь пробег натиска (для strike_clear).
## Пусто — «Точно!» у участка не бывает (проверяющий 27.09, d1c055b):
##  - на участке нет ни одного СТОЯЩЕГО бойца (пустой, на марше) — срыв никого не пошлёт, а
##    «Точно!» засчиталось бы впустую; тот же признак, по которому срывает мир (POSTED);
##  - треугольник: его срыв — выброс ульты («Обряд» — набрать строй), звать к нему нельзя.
## Восьмёрка бьёт не по стрелке участка, а к центру другой петли (LegionFigures.charge_for) —
## зона по этому направлению и не дальше центра петли с перебегом: иначе золото обещало бы удар
## туда, куда никто не побежит. Кольцо — по своей стрелке (_ring_front: внутрь или наружу по
## ring_out), внутрь — не дальше центра с перебегом, как release_ring.
func seg_strike(c: Contract, seg: int, power: float) -> Dictionary:
	if c.figure == ContractShape.TRIANGLE or c.seg_manned(seg) <= 0:
		return {}
	var reach := float(LegionCfg.UNIT_KINDS[c.kind]["charge_dist"])
	var run := reach * lerpf(LegionCfg.SLING_RANGE.x, LegionCfg.SLING_RANGE.y, power)
	var depth := run * world.perfect_zone_frac(owner_side)
	var center := c.seg_center(seg)
	var dir := c.seg_dir(seg)
	if c.figure == ContractShape.EIGHT and c.lobes.size() >= 2:
		var along := minf(c.length, (seg + 0.5) * LegionCfg.SEG_LEN)
		var other := c.lobes[1 - c.lobe_at(along)]
		dir = (other - center).normalized()
		run = minf(run, center.distance_to(other) + FigureCfg.EIGHT_OVERRUN)
		depth = minf(depth, run)
	elif c.ring and not c.ring_out:
		run = minf(run, center.distance_to(c.center) + ContractShape.RING_OVERRUN)
		depth = minf(depth, run)
	if dir.is_zero_approx():
		return {}
	return {"dir": dir, "depth": depth, "run": run}


## Полдлины участка (ширина зоны удара) — слою подсказок.
func seg_half_len(c: Contract, seg: int) -> float:
	return _seg_length(c, seg) * 0.5


## Этот участок сейчас держит рогатка (его золото рисует сама натяжка).
func is_grabbed(c: Contract, seg: int) -> bool:
	return not _grab.is_empty() and _grab["contract"] == c and int(_grab["seg"]) == seg


## B-071: ПКМ зажата, оттяжка уже не щелчок (≥ TAP_SLOP), но ещё не взвод — отпускание сейчас
## ничего не сорвёт; видна бледная стрелка, куда пойдёт натиск.
func sling_pending() -> bool:
	return not _grab.is_empty() and not _slinging \
		and _pull.distance_to(_grab_pos) >= LegionCfg.TAP_SLOP


## Esc (действие pause) или ЛКМ во время захвата — отмена без выпуска.
func _sling_cancel_event(event: InputEvent) -> bool:
	if event.is_action_pressed(&"pause"):
		return true
	var mb := event as InputEventMouseButton
	return mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT


## Окно потеряло фокус посреди натяжки — отпускание ПКМ сюда уже не придёт: снимаем захват.
## Так же гаснет прицел Пробела/колеса: их отпускание ушло в другое окно, и без этого прицел
## «залипал» — следующий штрих ЛКМ не чертился, а крутил стрелку (пакет «ввод», 26.09).
## B-056: и штрих ЛКМ — снимается с возвратом маны, как натяжка без выпуска. Без этого после
## Alt+Tab он оставался открытым и тянулся за курсором без кнопки, пока не щёлкнешь.
func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		cancel_gestures()


## Снять всё начатое человеком на поле: натяжку рогатки, прицел Пробела/колеса, штрих ЛКМ (с
## возвратом маны) и ещё не решённое нажатие (тап по участку). Отпускание, пришедшее потом,
## ничего не делает. Зовут потеря фокуса окна и открытие меню «Схватки» (B-370): паузы там нет,
## отпускания под меню поле всё равно увидело бы.
func cancel_gestures() -> void:
	if not _grab.is_empty():
		cancel_sling()
	stop_aiming()
	if _drawing or _pressing:
		cancel()
		_pressing = false
		_press_pts = PackedVector2Array()
	_press_eaten = false


## Перерисовать поле и слой поверх бойцов в этом кадре (queue_redraw за кадр склеивается).
func _redraw_now() -> void:
	queue_redraw()
	if overlay != null:
		overlay.queue_redraw()


func cancel_sling() -> void:
	_grab = {}
	_slinging = false
	_aim = {}


func is_slinging() -> bool:
	return _slinging and not _grab.is_empty()


## Игрок чертит договор или тянет рогатку — в это время видно, где препятствия (ObstacleHint).
func is_gesturing() -> bool:
	return _drawing or is_slinging()


func sling_pointer() -> Vector2:
	return _pull


## Прицел текущей натяжки: {dir, power, pull, perfect, depth, half_w, center}. Стрелка —
## против оттяжки. Сила всегда полная (26.09): длина оттяжки не важна, умение — момент отпускания.
## У ФИГУР (кроме кольца) dir — ОБЩАЯ ось оттяжки: тот же вектор уходит в бой (aim["dir"] →
## release_aimed → axis), поэтому превью и бой берут ось из одного места. Своя геометрия фигуры
## (к центру/наружу/крест-накрест) работает только при щелчке и таянии, когда оси нет.
func sling_aim() -> Dictionary:
	if _grab.is_empty():
		return {}
	var c: Contract = _grab["contract"]
	var seg := int(_grab["seg"])
	var pull := _pull - _grab_pos
	var axis := -pull.normalized()
	var power := 1.0
	if c.shaped():
		if c.ring:
			return ring_aim(c, seg, pull, power)   # кольцо сжимается: стрелка участка к центру/наружу
		# фигура: строй летит по общей оси оттяжки. Восьмёрка срывается целиком, соседние залпы
		# отбрасывают приманку внутрь, поэтому ей «Точно!» гасит перехватывающая приманка (D-0927-53)
		return figure_aim(c, seg, pull, power, axis, not c.corners_only)
	var dist := float(LegionCfg.UNIT_KINDS[c.kind]["charge_dist"]) \
		* lerpf(LegionCfg.SLING_RANGE.x, LegionCfg.SLING_RANGE.y, power)
	var center := c.seg_center(seg)
	var half_w := _seg_length(c, seg) * 0.5
	var depth := dist * world.perfect_zone_frac(owner_side)
	# «Точно!» — только если срыв кого-то пошлёт: на участке есть стоящий боец (seg_strike), и
	# натиск не перехватит нотариус или призрак (D-0927-53: «Срывай!» не врёт)
	var perfect := c.seg_manned(seg) > 0 and zone_has_foe(center, axis, half_w, depth) \
		and _sling_clear(c, seg, center, axis, half_w, depth)
	return {
		"dir": axis, "power": power, "pull": pull, "center": center, "half_w": half_w,
		"depth": depth, "perfect": perfect,
	}


## «Срывай!» у рогатки — только если натиск по прицелу не перехватят (D-0927-53).
func _sling_clear(c: Contract, seg: int, center: Vector2, dir: Vector2, half_w: float,
		depth: float) -> bool:
	pack_live_lures()
	return strike_clear(c, seg, center, dir, half_w, depth, zone_foes(center, dir, half_w, depth))


## Подпись натяжки у курсора: «Жди врага в зоне» / «Срывай!»; "" — натяжки нет.
func sling_hint() -> String:
	if not is_slinging() or _aim.is_empty():
		return ""
	return SLING_GO_LABEL if bool(_aim["perfect"]) else SLING_WAIT_LABEL


## Зона удара: полоса вдоль стрелки шириной с участок, глубиной depth от середины участка.
func zone_has_foe(center: Vector2, dir: Vector2, half_w: float, depth: float) -> bool:
	if dir.is_zero_approx():
		return false
	var side := dir.orthogonal()
	for f in world.foes:
		if not f.is_active():
			continue
		var v := f.position - center
		var along := v.dot(dir)
		if along >= -f.radius and along <= depth + f.radius \
				and absf(v.dot(side)) <= half_w + f.radius:
			return true
	return false


static func _seg_length(c: Contract, seg: int) -> float:
	return minf(LegionCfg.SEG_LEN, c.length - seg * LegionCfg.SEG_LEN)


## Реальное время кадра (мир зовёт до шага): шкала «Отсрочка», тик золотой зоны, всплывашки.
## Возвращает масштаб dt мира: DELAY_SLOW, пока идёт натяжка и шкала не пуста, иначе 1.0.
func real_tick(delta: float) -> float:
	var scale := 1.0
	if is_slinging() and delay_enabled:
		if delay > 0.0:
			scale = LegionCfg.DELAY_SLOW
			delay = maxf(0.0, delay - LegionCfg.DELAY_DRAIN * delta)
		_aim = sling_aim()
		if bool(_aim.get("perfect", false)):
			_tick_t -= delta
			if _tick_t <= 0.0:
				_tick_t = LegionCfg.PERFECT_TICK
				_sound("ult_ready", 1.6)
		else:
			_tick_t = 0.0
	else:
		delay = minf(LegionCfg.DELAY_MAX, delay + LegionCfg.DELAY_REGEN * delta)
	# сеть: мышь замерла под Пробелом — придержанная прореживанием стрелка уходит сама
	if _aim_unsent != Vector2.INF and _space and _net_preview() \
			and FxClock.ms() - _aim_sent_ms >= NET_AIM_GAP_MS:
		_net_aim(_aim_unsent, true)
	for list: Array[Dictionary] in [_popups, _hits]:
		for i in range(list.size() - 1, -1, -1):
			list[i]["t"] = float(list[i]["t"]) + delta
			if float(list[i]["t"]) > LegionCfg.PERFECT_POPUP_TIME:
				list.remove_at(i)
	# slow/draw-lag: поле и слой черновика — каждый реальный кадр, а не только в шаге мира:
	# стоп-кадр (натиск, Ку, ритуал фигуры, находка — world.impact_stop, 45–160 мс) шаг
	# пропускает, и штрих стоял, пока курсор уходил (Игорь 29.09: «иногда рисуется линия с
	# задержкой»). Мир зовёт real_tick в _process, как и tick, — перерисовка за кадр одна.
	# Не из _unhandled_input: там отложенная перерисовка могла успеть в физическом шаге
	# итерации, и кадр рисовал поле дважды (замер: +1–2 мс кадра в густой драке).
	_redraw_now()
	return scale


## Пауза: отпускание ПКМ, Пробела и колеса на паузе поле не увидит — гасим всё сразу.
func _on_paused(p: bool) -> void:
	if p:
		cancel_sling()
		stop_aiming()


func _on_charge_impact(at: Vector2, perfect: bool) -> void:
	_hits.append({"pos": at, "t": 0.0, "perfect": perfect})
	_sound("skel_hit", 0.8 if perfect else 1.0)


## v18 «Давка»: участок прорван — надпись и треск.
func _on_segment_broken(c: Contract, seg: int, _n: int) -> void:
	if c.owner_side != owner_side:
		return
	_popups.append({"pos": c.seg_center(seg), "t": 0.0, "text": "Прорыв!",
		"color": LegionCfg.PRESS_COLOR})
	_sound("rune_fail", 0.7)


## v18 «Пружина»: прогнутый участок выпущен — надпись (если выпуск не «Точно!»: тот уже висит).
func _on_spring_released(c: Contract, seg: int, bend: float) -> void:
	if c.owner_side != owner_side:
		return
	_popups.append({"pos": c.seg_center(seg) + Vector2(0, -26.0), "t": 0.0,
		"text": "Пружина!" if bend < 0.75 else "Пружина!!", "color": LegionCfg.SPRING_COLOR})
	_sound("mine_boom", 1.35)


func _sound(id: String, pitch: float) -> void:
	if _sfx == null:
		_sfx = AudioStreamPlayer.new()
		_sfx.bus = &"SFX"
		add_child(_sfx)
	var stream := SfxGen.get_stream(id)
	if stream == null:
		return
	_sfx.stream = stream
	_sfx.pitch_scale = pitch
	_sfx.play()


## Пробел или колесо нажаты/отпущены: прицел включается первым нажатым и гаснет с последним
## отпущенным — перекрытие Пробела и колеса не рвёт и не перезапускает прицел.
func _hold_aim(bit: int, pressed: bool) -> void:
	if pressed and not aim_unlocked:
		return
	_aim_held = (_aim_held | bit) if pressed else (_aim_held & ~bit)
	var on := _aim_held != 0
	if on != _space:
		set_aiming(on)


func stop_aiming() -> void:
	_aim_held = 0
	if _space:
		set_aiming(false)


## Тот же API вызывают события ввода и приёмочные тесты.
func set_aiming(pressed: bool) -> void:
	_space = pressed
	if not pressed:
		_aim_held = 0
	if pressed:
		if not _drawing:
			var hit := pick_segment(_pointer)
			_aim_contract = hit.get("contract")
		aim_at(_pointer)
	else:
		if _net_preview():
			_net_aim(_pointer, true)   # последняя точка прицела — до того, как прицел погас
		_pen_wait = _drawing
		_aim_contract = null


func aim_at(at: Vector2) -> void:
	if _drawing and not _draft.is_empty():
		var v := at - _poly_point(_draft, _draft_len * 0.5)
		if not v.is_zero_approx():
			_draft_dir = v.normalized()
	elif _net_preview():
		_net_aim(at, false)   # живой договор поворачивает мир (команда AIM), черновик — рука
	elif _aim_contract != null and _aim_contract.alive() and _aim_contract.ring:
		_aim_contract.set_ring_out(not ContractShape.inside(at, _aim_contract.points))
	elif _aim_contract != null and _aim_contract.alive() and _aim_contract.figure == &"":
		_aim_contract.set_dir(at - _aim_contract.point_at(_aim_contract.length * 0.5))
		aimed.emit(_aim_contract)


func begin(at: Vector2) -> void:
	if not active or not bool(unlocked.get(current_kind, true)) or mana <= 0.0:
		return
	var raw := Vector2.INF
	if world.terrain.is_rock(at):
		# B-092: у ограды след коллизии толще нарисованного забора (~18 px), штрих «от забора»
		# начинался в нём и не рождался. Кромка стены в пределах LINE_BEGIN_SNAP — начало там;
		# с какой стороны стены — уточнит первое движение (extend, _resnap_start).
		var edge := _open_near(at, LegionCfg.LINE_BEGIN_SNAP)
		if edge == Vector2.INF:
			_wall_bump(at)   # раньше штрих в скале молча не рождался — теперь видно почему
			return
		raw = at
		at = edge
	cancel()
	_begin_raw = raw
	_draft_net = _net_preview()
	_drawing = true
	_draft_ring = false
	_draft_fig = &""
	_draft.append(at)
	_draft_len = 0.0
	_draft_cost = 0.0


## Штрих начат в стене (B-092): начало — там, где путь к курсору выходит из стены (в пределах
## LINE_BEGIN_SNAP от точки нажатия). Ближайшая кромка из begin могла лежать по ту сторону
## ограды — тогда штрих сразу упирался в неё и не рождался.
func _resnap_start(to: Vector2) -> void:
	var d := to - _begin_raw
	if d.length() < 1.0:
		return
	var step := d.normalized() * LegionCfg.CLIP_STEP
	var p := _begin_raw
	var run := 0.0
	while run <= minf(LegionCfg.LINE_BEGIN_SNAP, d.length()):
		if not world.terrain.is_rock(p):
			_draft[0] = p
			return
		p += step
		run += LegionCfg.CLIP_STEP


## Ближайшая точка вне скалы в радиусе r (шаг — CLIP_STEP, LINE_SNAP_DIRS направлений); INF — нет.
func _open_near(at: Vector2, r: float) -> Vector2:
	var d := LegionCfg.CLIP_STEP
	while d <= r:
		for k in LegionCfg.LINE_SNAP_DIRS:
			var p := at + Vector2.from_angle(TAU * float(k) / float(LegionCfg.LINE_SNAP_DIRS)) * d
			if not world.terrain.is_rock(p):
				return p
		d += LegionCfg.CLIP_STEP
	return Vector2.INF


## Короткий штрих поперёк коридора (B-092/B-099): упёрся в препятствие обоими концами — значит,
## перегородил проход целиком, а честная линия там короче LINE_MIN («Два отдела» — 67 px между
## оградой и стеной, «Лабиринт» — местами 38). Такой штрих берём от LINE_MIN_WALLED.
func min_len(pts: PackedVector2Array) -> float:
	if pts.size() < 2:
		return LegionCfg.LINE_MIN
	var a := pts[0]
	var b := pts[pts.size() - 1]
	if a.distance_to(b) < 1.0:
		return LegionCfg.LINE_MIN
	var d := (b - a).normalized()
	var probe := LegionCfg.LINE_WALL_PROBE
	if world.terrain.is_rock(a - d * probe) and world.terrain.is_rock(b + d * probe):
		return LegionCfg.LINE_MIN_WALLED
	return LegionCfg.LINE_MIN


## Вспышка «стена» у точки: не чаще раза в IntuitCfg.WALL_GAP реальных секунд (рука дёргается по
## камню — одна вспышка, а не мигание).
func _wall_bump(at: Vector2, label := IntuitCfg.WALL_LABEL, life := IntuitCfg.WALL_FX) -> void:
	var ms := FxClock.ms()
	# Короткая вспышка столкновения могла уже погаснуть до отпускания кнопки.
	# Тогда совету об отказе нужен свой показ, хотя cooldown общей вспышки ещё идёт.
	if ms - _wall_ms < roundi(IntuitCfg.WALL_GAP * 1000.0) \
			and (label == IntuitCfg.WALL_LABEL or not _wall_fx.is_empty()):
		# На отпускании уточняем причину отказа короткого штриха. Общий отклик
		# столкновения не должен глушить совет; новую вспышку при этом не создаём.
		if label != IntuitCfg.WALL_LABEL and not _wall_fx.is_empty():
			var last: Dictionary = _wall_fx[-1]
			if last["label"] == IntuitCfg.WALL_LABEL \
					and at.distance_to(last["pos"]) <= LegionCfg.POINT_STEP:
				last["label"] = label
				last["life"] = life
		return
	_wall_ms = ms
	wall_bumps += 1
	_wall_fx.append({"pos": at, "ms": ms, "label": label, "life": life})


## Штрих короче минимума не лёг (B-030/B-092): подпись у его конца, почему. Случайный щелчок
## (почти без протяжки) молчит. Упёрся хотя бы одним концом в препятствие — «узко, ведите
## наискось» (в узком проходе поперёк линия не помещается, наискось — да), иначе — «коротко».
func _short_bump(stroke: PackedVector2Array) -> void:
	if stroke.size() < 2 or _draft_len < IntuitCfg.NARROW_MIN_DRAG:
		return
	var a := stroke[0]
	var b := stroke[stroke.size() - 1]
	var walled := false
	if a.distance_to(b) >= 1.0:
		var d := (b - a).normalized()
		var probe := LegionCfg.LINE_WALL_PROBE
		walled = world.terrain.is_rock(a - d * probe) or world.terrain.is_rock(b + d * probe)
	_wall_bump(b, IntuitCfg.NARROW_LABEL if walled else IntuitCfg.SHORT_LABEL,
		IntuitCfg.NARROW_FX)


# gdlint: disable=max-returns
func extend(to: Vector2) -> void:
	if not _drawing:
		return
	if _space:
		aim_at(to)
		return
	if _begin_raw != Vector2.INF and _draft.size() == 1:
		_resnap_start(to)
	var last := _draft[_draft.size() - 1]
	if _pen_wait:
		if last.distance_to(to) >= LegionCfg.PEN_RETURN_R:
			return
		_pen_wait = false
	if last.distance_to(to) < LegionCfg.POINT_STEP:
		return
	# штрих не проходит сквозь скалу: обрезаем у контура, дальше ждём, пока курсор обойдёт камень
	var target := world.terrain.segment_clear(last, to)
	if target.distance_squared_to(to) > 1.0:
		# Конец пера остаётся у преграды, а причина видна и посреди длинного жеста.
		# Раньше «стена» появлялась только при неудачном начале или коротком штрихе.
		_wall_bump(target)
	var seg := last.distance_to(target)
	if seg < 1.0:
		return
	# предел — фигуры (FigureCfg.FIG_LEN_MAX); линия длиннее LINE_MAX обрежется в finish()
	if _draft_len + seg > FigureCfg.FIG_LEN_MAX:
		return
	var cost := seg * _kind_price(current_kind)
	if _draft_net:
		# сеть: превью без траты — черновик меряется против маны за вычетом уже начерченного
		if cost > mana - _draft_cost:
			return
	elif cost > mana:
		return
	else:
		_spend(cost)
	_draft_cost += cost
	_draft.append(target)
	_draft_len += seg
	_begin_raw = Vector2.INF
	var fig := ContractShape.classify(_draft)
	if fig != &"" and not bool(shapes.get(fig, true)):
		fig = &""   # фигура ещё не открыта кампанией — это обычная линия
	_draft_ring = fig == ContractShape.RING
	_draft_fig = fig if fig != ContractShape.RING else &""


func finish() -> void:
	if not _drawing:
		return
	if _draft_net:
		_net_finish()
		return
	_drawing = false
	var stroke := _draft
	var ring := _draft_ring
	var fig := _draft_fig
	_draft_ring = false
	_draft_fig = &""
	_draft = PackedVector2Array()
	if not ring and fig == &"" and _draft_len > LegionCfg.LINE_MAX:
		# не фигура — обычный штрих со своим пределом, как до фигур (черновик тогда упирался в
		# LINE_MAX): хвост отрезается ДО распознавания подновления, его мана возвращается
		# (проверяющий 26.09: обвод с перелётом платил весь хвост или ложился дублем)
		stroke = _truncate(stroke, LegionCfg.LINE_MAX)
		var back := minf(_draft_cost, (_draft_len - _poly_len(stroke)) * _kind_price(current_kind))
		_refund(back)
		_draft_cost -= back
		_draft_len = _poly_len(stroke)
	var hit := match_refresh(stroke)
	if not hit.is_empty():
		var c: Contract = hit["contract"]
		var actual_cost := _poly_len(stroke) * c.mana_per_px()
		if c.figure != &"":
			# фигура подновляется целиком — и платит за всю свою длину, а не за штрих
			# (проверяющий 26.09: 18 px за 2 маны продлевали всю фигуру)
			actual_cost = _segs_length(c, hit["segs"]) * c.mana_per_px()
		var difference := actual_cost - _draft_cost
		if difference > mana:
			_refund(_draft_cost)
			return
		_spend(difference)
		var n := c.refresh_segments(hit["segs"])
		if n > 0:
			_mark_renew(c, hit["segs"])
			world.on_contract_refreshed(c, hit["segs"], n)
		return
	if _draft_len < min_len(stroke):
		_refund(_draft_cost)
		_short_bump(stroke)
		return
	if slots_full():
		_refund(_draft_cost)
		if owner_side == world.local_side:
			# B-345: причина — у пера (взгляд там), тост остаётся для тех, кто смотрит в центр
			_wall_bump(stroke[stroke.size() - 1], limit_label(), LegionCfg.LIMIT_FX)
			world.toast("Не больше %d договоров сразу" % LegionCfg.MAX_CONTRACTS, &"warn")
		return
	# угловые фигуры: перелёт конца за начало срезается (ContractShape.trim_overshoot) и мест не
	# даёт — его мана возвращается, как хвост линии сверх LINE_MAX, а замыкание считается от
	# среза (D-1002-08)
	var poly := ContractShape.CORNER_FIGURES.has(fig)
	var closing := ContractShape.trim_overshoot(stroke) if poly else stroke
	var shape_cost := 0.0
	if ring or fig != &"":
		# замыкание зазора — тоже договор: платим за него, как за штрих (verifier 26.09: у предела
		# длины кольцо бесплатно выходило на ~12 % длиннее любой линии); нечем платить — линия
		var gap_cost := closing[0].distance_to(closing[closing.size() - 1]) \
			* _kind_price(current_kind)
		if gap_cost > mana:
			ring = false
			fig = &""
		else:
			_spend(gap_cost)
			shape_cost = gap_cost
	if poly and fig != &"":
		var cut := _poly_len(stroke) - _poly_len(closing)
		if cut > 0.0:
			var back := minf(_draft_cost, cut * _kind_price(current_kind))
			_refund(back)
			_draft_cost -= back
	if ring or fig != &"":
		# цена фигуры — max(контур, floor эффекта): доплата атомарна, не хватает маны — знак
		# отменяется с ПОЛНЫМ возвратом (D-1002 §6)
		var floor := float(FigureCfg.PRICE_FLOOR.get(
			ContractShape.RING if ring else fig, 0.0))
		var paid := _draft_cost + shape_cost
		if paid < floor:
			if floor - paid > mana:
				_refund(paid)
				_short_bump(stroke)
				return
			_spend(floor - paid)
	var c := _create(stroke, stroke_side(stroke), current_kind, ring, fig)
	if c == null:
		# угол фигуры встал в воду или скалу — фигура не заключена, мана вернулась целиком
		_refund(_draft_cost + shape_cost)
		var blocked := Contract.new().build_figure(stroke, fig, world.terrain.walkable,
			current_kind).blocked_tips
		_wall_bump(blocked[0] if not blocked.is_empty() else stroke[stroke.size() - 1])
		if owner_side == world.local_side:
			world.toast("Угол фигуры в стене — знак не встал", &"warn")
		return
	if ring:
		_on_ring_made(c)
		figure_made.emit(c)
	elif c.figure != &"":
		_on_figure_made(c)
		figure_made.emit(c)
	elif _draft_dir != Vector2.ZERO:
		c.set_dir(_draft_dir)
	_draft_dir = Vector2.ZERO
	_pen_wait = false


## Снять договор без натиска: места гаснут, бойцы, успевшие взять место, снова свободны,
## мана не возвращается. Нужен обучению: неподходящая линия шага 1 (коротко / далеко / не
## тот вид) иначе жила бы и глотала следующий штрих по призраку как продление (ревью 25.09).
func dismiss(c: Contract) -> void:
	if not contracts.has(c):
		return
	for p in c.posts:
		p["dead"] = true
		var u: Legionnaire = p["unit"]
		p["unit"] = null
		if u != null and is_instance_valid(u) and u.alive:
			u.set_free()
	c.seg_dead.fill(1)
	contracts.erase(c)
	world.on_contract_removed(c)


func cancel() -> void:
	if _drawing and not _draft_net:   # превью сети маны не брало — и не возвращает
		_refund(_draft_cost)
	_drawing = false
	_draft_net = false
	_draft_ring = false
	_draft_fig = &""
	_draft_dir = Vector2.ZERO
	_pen_wait = false
	_preview = null
	_preview_plan.clear()
	_draft = PackedVector2Array()
	_draft_len = 0.0
	_draft_cost = 0.0


func has_draft() -> bool:
	return _drawing


func _create(pts: PackedVector2Array, side: int, kind: StringName, ring := false,
		fig: StringName = &"") -> Contract:
	var c: Contract
	if ring:
		c = Contract.new().build_ring(pts, world.terrain.walkable, kind)
	elif fig != &"":
		c = Contract.new().build_figure(pts, fig, world.terrain.walkable, kind)
	else:
		c = Contract.new().build(pts, side, world.terrain.walkable, kind)
	if not c.blocked_tips.is_empty():
		# угол фигуры в воде или скале: фигура не заключается вовсе (D-1002 §2). Молча потерять
		# угол и считать оставшиеся полным треугольником нельзя — вызывающий вернёт ману.
		return null
	c.mana_cost_mult = mana_cost_mult   # перк «Мелкий шрифт» — договор несёт множитель сам
	c.owner_side = owner_side
	c.id = _next_id
	_next_id += 1
	contracts.append(c)
	_vis_of(c)   # рождение — с момента заключения, а не с первого кадра отрисовки
	_hover_dirty = true
	world.on_contract_created(c)
	return c


## D-0927-140: способность платит из того же кошелька, что линии (проверку «хватает ли» делает
## вызывающий — LegionWorld.can_pay_ability). mana_spent — вся мана боя, mana_abilities — её доля.
func pay(amount: float) -> void:
	_spend(amount)
	if owner_side == 0:   # stats — счёт игрока стороны 0 (как mana_spent в _spend)
		world.stats["mana_abilities"] = float(world.stats.get("mana_abilities", 0.0)) + amount


func _spend(amount: float) -> void:
	mana -= amount
	if owner_side == 0:   # stats — счёт игрока стороны 0 (итог боя, свёртка трассы бота)
		world.stats["mana_spent"] = float(world.stats["mana_spent"]) + amount


## Вернуть потраченное на черновик (сумма маны, не длина: цена зависит от вида).
func _refund(back: float) -> void:
	mana = minf(mana_max, mana + back)
	if owner_side == 0:
		world.stats["mana_spent"] = float(world.stats["mana_spent"]) - back


## polish1: раньше своя копия поиска по таблице (не static — перк требует mana_cost_mult этого
## поля); теперь зовёт Contract.base_price(), единственное место, где читается таблица видов.
func _kind_price(kind: StringName) -> float:
	return Contract.base_price(kind) * mana_cost_mult


static func _kind_color(kind: StringName, field: String) -> Color:
	var k := kind if LegionCfg.UNIT_KINDS.has(kind) else LegionCfg.KIND_LABORER
	return LegionCfg.UNIT_KINDS[k][field]


static func _poly_len(pts: PackedVector2Array) -> float:
	var plen := 0.0
	for i in range(1, pts.size()):
		plen += pts[i].distance_to(pts[i - 1])
	return plen


# ── Отрисовка ───────────────────────────────────────────────────────────────

func _seg_alpha(c: Contract, s: int) -> float:
	var left := c.seg_left(s)
	if left > LegionCfg.SEG_BLINK:
		return 1.0
	# мигание ускоряется к концу срока: последняя секунда читается как «вот-вот»
	var rate := lerpf(5.0, 14.0, 1.0 - left / LegionCfg.SEG_BLINK)
	return 0.3 + 0.7 * absf(cos(now * rate))


## Палитра линии вида: тело (им же красятся карточка вида, кольцо срока, снаряд и постройка)
## и сердцевина. Единственный источник — LegionCfg.UNIT_KINDS: цвет снят с кадров бойца
## (поле sprite, tools/kind_colors.py), чтобы линия читалась «эта зовёт этих».
static func line_palette(kind: StringName) -> Dictionary:
	return {"body": _kind_color(kind, "color"), "core": _kind_color(kind, "core")}


## Доля рождения договора 0..1 (полная графика); в экономной рождения нет — сразу 1.
func birth_k(c: Contract) -> float:
	if Settings.is_economy_graphics():
		return 1.0
	return _birth_k(c)


## Сколько участков сейчас растворяется (тесты и замер).
func fading_count() -> int:
	return _fading.size()


func _draw() -> void:
	_renderer_view()._draw()


## Прогон участков [s, конец): живые подряд и одного возраста (значит, одной альфы мигания) —
## рисуются ОДНОЙ ломаной на слой. Обычно это весь договор: все участки родились и тают вместе,
## а в 7–8 раз меньше команд отрисовки и нет светлых «узлов» внахлёст на стыках участков.
## with_bend — прогнутый участок (давка) идёт отдельно: его контур гнётся. Мёртвый s — вернёт s.
static func _run_end(c: Contract, s: int, with_bend: bool) -> int:
	if c.seg_dead[s] != 0:
		return s
	if with_bend and c.seg_bend[s] > 0.0:
		return s + 1
	var e := s + 1
	while e < c.seg_count() and c.seg_dead[e] == 0 and c.seg_age[e] == c.seg_age[s] \
			and not (with_bend and c.seg_bend[e] > 0.0):
		e += 1
	return e


## Ломаная прогона участков [s, e): весь договор — его собственные точки, один участок — его
## кусок, иначе склейка кусков (аллокация только в этом редком случае — частичное продление).
static func _run_poly(c: Contract, s: int, e: int) -> PackedVector2Array:
	if s == 0 and e == c.seg_count():
		return c.points
	if e == s + 1:
		return c.seg_polys[s]
	var out := c.seg_polys[s].duplicate()
	for i in range(s + 1, e):
		var poly := c.seg_polys[i]
		for j in range(1, poly.size()):
			out.append(poly[j])
	return out


## Слой ПОВЕРХ персонажей: плотный строй целиком закрывает руну под ногами, поэтому стрелки
## выпуска и черновик рисуются над бойцами, а стрелки вынесены перед передним рядом.
## Участок, которому осталось меньше SEG_BLINK, красит стрелку в цвет тревоги — видно,
## какой отряд вот-вот уйдёт в натиск.
func make_overlay() -> Node2D:
	overlay = Node2D.new()
	overlay.name = "ContractOverlay"
	overlay.draw.connect(_draw_overlay)
	return overlay


func _draw_overlay() -> void:
	_renderer_view()._draw_overlay()


# ── Вид линий: рождение, течение, продление, растворение (только полная графика) ──

## Сверка вида с договорами раз в кадр: новый договор — родился, участок, живой в прошлом
## кадре и мёртвый сейчас (растаял, выпущен, снят), — растворяется. Симуляцию не читает сверх
## seg_dead и ничего в неё не пишет; ГСЧ не трогает (искры — хэш от номера участка).
func _sync_vis(eco: bool) -> void:
	_vis_frame += 1
	for c in contracts:
		var v := _vis_of(c)
		v["frame"] = _vis_frame
		var alive: PackedByteArray = v["alive"]
		for s in alive.size():
			if alive[s] != 0 and c.seg_dead[s] != 0:
				alive[s] = 0
				if not eco:
					_fade(c, s)
		v["alive"] = alive
	if _vis.size() <= contracts.size():
		return
	# договор ушёл из списка целиком (последний участок растаял в этом тике, снят обучением)
	for c: Contract in _vis.keys():
		var v: Dictionary = _vis[c]
		if int(v["frame"]) == _vis_frame:
			continue
		if not eco:
			var alive: PackedByteArray = v["alive"]
			for s in alive.size():
				if alive[s] != 0:
					_fade(c, s)
		_vis.erase(c)


func _vis_of(c: Contract) -> Dictionary:
	var v: Dictionary = _vis.get(c, {})
	if v.is_empty():
		var alive := PackedByteArray()
		alive.resize(c.seg_count())
		for s in c.seg_count():
			alive[s] = 1 if c.seg_dead[s] == 0 else 0
		var renew := PackedFloat32Array()
		renew.resize(c.seg_count())
		renew.fill(-INF)
		v = {"born": now, "alive": alive, "renew": renew, "renew_until": -INF, "frame": _vis_frame}
		_vis[c] = v
	return v


func _birth_k(c: Contract) -> float:
	var v: Dictionary = _vis.get(c, {})
	if v.is_empty():
		return 0.0
	return clampf((now - float(v["born"])) / CfgLines.BIRTH_T, 0.0, 1.0)


func _fade(c: Contract, s: int) -> void:
	if _fading.size() >= CfgLines.FADE_CAP:
		return
	_fading.append({
		"poly": c.bent_poly(s), "body": _kind_color(c.kind, "color"),
		"core": _kind_color(c.kind, "core"), "t0": now, "seed": float(c.id * 31 + s),
	})


## Продлённые участки вспыхивают — видно, что подрисовка «взялась» и какие именно участки.
func _mark_renew(c: Contract, segs: PackedInt32Array) -> void:
	var v := _vis_of(c)
	var renew: PackedFloat32Array = v["renew"]
	for s in segs:
		if s >= 0 and s < renew.size():
			renew[s] = now
	v["renew"] = renew
	v["renew_until"] = now + CfgLines.RENEW_T


## Детерминированный «шум» 0..1 без ГСЧ: искры не сдвигают ни world.rng, ни глобальный randf.
static func _hash01(x: float) -> float:
	var v := sin(x * 12.9898) * 43758.5453
	return v - floorf(v)


## slow/intuit: отрезки черновика (длины вдоль линии превью, Vector2(from, to)), где у мест не
## будет людей — «наберёт N / мест M» при N < M. Места раздаются ближним первыми, поэтому пустым
## остаётся край, дальний от бойцов; по нему и видно, где враг обтечёт строй. Кольцо и фигуры —
## без разметки (у них подпись своя).
func draft_empty_runs() -> Array[Vector2]:
	var out: Array[Vector2] = []
	if not _drawing or _preview == null or _draft_ring or _draft_fig != &"" \
			or _preview_plan.size() >= _preview.posts.size():
		return out
	var step := _preview.post_step()
	var has_post: Dictionary = {}
	var filled: Dictionary = {}
	for p in _preview.posts:
		has_post[floori(float(p["along"]) / step)] = true
	for a in _preview_plan:
		filled[floori(float((a["post"] as Dictionary)["along"]) / step)] = true
	for k in int(_preview.length / step):
		if not has_post.has(k) or filled.has(k):
			continue
		var from := k * step
		if not out.is_empty() and is_equal_approx(out[out.size() - 1].y, from):
			out[out.size() - 1] = Vector2(out[out.size() - 1].x, from + step)
		else:
			out.append(Vector2(from, from + step))
	return out


static func _poly_point(pts: PackedVector2Array, dist: float) -> Vector2:
	var d := dist
	for i in range(1, pts.size()):
		var seg := pts[i].distance_to(pts[i - 1])
		if d <= seg:
			return pts[i - 1].lerp(pts[i], 0.0 if seg <= 0.0 else d / seg)
		d -= seg
	return pts[pts.size() - 1]


## Кэш A* по паре клеток хранит и отрицательный ответ. Марш использует этот же маршрут.
func recruit_path(from: Vector2, to: Vector2) -> PackedVector2Array:
	var cached := _cell_path(from, to)
	if cached.is_empty():
		return cached
	var out := cached.duplicate()
	out.remove_at(0)
	out.append(to)
	return out


## Путь A* между клетками из кэша — без копии; пустой — недостижимо. Не менять на месте.
## Кэш хранит только ответ A* по паре прижатых клеток — он от исходных точек не зависит.
## Проходимость концов проверяется каждый раз заново (по сетке — дёшево): прежде она решалась по
## исходным точкам и пряталась в кэш под ключ прижатой клетки (за краем карты — true, в крайней
## клетке-скале — false), и ответ зависел от того, кто спросил первым. Кэша нет в снимке боя
## (NetSnap): у клиента после подтяжки снимком он пуст, у судьи заполнен (B-375).
func _cell_path(from: Vector2, to: Vector2) -> PackedVector2Array:
	var terrain := world.terrain
	if _path_terrain != terrain:
		_paths.clear()
		_path_terrain = terrain
	if not (terrain.walkable(from) and terrain.walkable(to)):
		return PackedVector2Array()
	var a := terrain.cell_of(from)
	var b := terrain.cell_of(to)
	var key := Vector4i(a.x, a.y, b.x, b.y)
	if not _paths.has(key):
		path_queries += 1
		_paths[key] = terrain.cell_path(a, b)
	return _paths[key]


func nearby_kind(at: Vector2, kind: StringName) -> bool:
	var radius := float(recruit_r.get(kind, LegionCfg.RECRUIT_R))
	for c in contracts:
		if c.kind == kind and c.live_distance(at) <= radius:
			return true
	return false


## Одна чистая раздача для боя и прогноза: порядок стабилен, место резервируется один раз.
## Ближние к месту своего вида — первыми: по порядку появления линия у стопки забирала бойцов
## с дороги в 120 px, а стопку у самой линии оставляла (партия по переписке 25.09.2026).
## Один жадный порядок «ближние первыми» бросал бойцов без мест: сосед, у которого был выбор,
## занимал единственное место дальнего (9 из 180 при 87 пустых, verifier 26.09.2026). Поэтому
## после него — достройка цепочками: оставшийся без места берёт место соседа, если тот может
## перейти на другое. Так на местах не меньше бойцов, чем вообще можно поставить (теорема Берже).
## released — ещё не созданный черновик: идущие «Сбором» рядом с ним считаются свободными.
func assignment_plan(lines: Array[Contract], released: Contract = null) -> Array[Dictionary]:
	var buckets: Dictionary = {}   # вид → {клетка → [места]}
	var flats: Dictionary = {}     # вид → [места] (для достройки)
	var serial := 0
	for c in lines:
		if is_stump(c):
			continue   # B-345: пенёк гаснет на ближайшем шаге — бойцов не набирает
		if not buckets.has(c.kind):
			buckets[c.kind] = {}
			flats[c.kind] = []
		var cells: Dictionary = buckets[c.kind]
		for post in c.posts:
			if post["dead"] or post["unit"] != null:
				continue
			var cell := _bucket(post["pos"])
			if not cells.has(cell):
				cells[cell] = []
			var candidate := {"contract": c, "post": post, "key": serial}
			(cells[cell] as Array).append(candidate)
			(flats[c.kind] as Array).append(candidate)
			serial += 1
	var order: Array[Dictionary] = []
	for u in world.units:
		if not u.alive or not LegionStaff.free_for(u, self, released) or not buckets.has(u.kind):
			continue
		# PvP: поле раздаёт места только бойцам своей стороны, иначе игрок командовал бы чужими
		# (в одиночке и owner_side, и u.side — 0: отбор ничего не меняет)
		if u.side != owner_side:
			continue
		if world.grid.nearest_foe(u.position, LegionCfg.ASSIGN_BUSY_R, true) != null:
			continue
		var d := _nearest_post_d2(u, buckets[u.kind])
		if d < INF:
			order.append({"unit": u, "d": d, "i": order.size()})
	order.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if float(a["d"]) != float(b["d"]):
			return float(a["d"]) < float(b["d"])
		return int(a["i"]) < int(b["i"]))
	# reserved: ключ места → назначение; chosen: боец → назначение
	var reserved: Dictionary = {}
	var chosen: Dictionary = {}
	var left: Array[Legionnaire] = []
	for entry in order:
		var u: Legionnaire = entry["unit"]
		if reserved.size() >= serial:
			break   # мест больше нет — остальным искать нечего
		var best := _nearest_assignment(u, buckets[u.kind], reserved)
		if best.is_empty():
			left.append(u)
		else:
			reserved[best["key"]] = best
			chosen[u] = best
	# все места заняты — достраивать нечем (частый случай превью: бойцов больше, чем мест)
	if not left.is_empty() and reserved.size() < serial:
		_repair(left, flats, reserved, chosen, serial)
	var result: Array[Dictionary] = []
	for entry in order:
		var u: Legionnaire = entry["unit"]
		if not chosen.has(u):
			continue
		var a: Dictionary = chosen[u]
		if not a.has("path"):
			var post: Dictionary = a["post"]
			a["path"] = recruit_path(u.position, post["pos"])
		result.append(a)
	return result


## Ключ очереди раздачи: квадрат расстояния до ближайшего места своего вида в радиусе — без
## поиска путей и без учёта занятости (кольца клеток, ближнее найдено — дальше не смотрим).
## INF — мест в радиусе нет вовсе, бойца в раздачу не берём.
func _nearest_post_d2(u: Legionnaire, cells: Dictionary) -> float:
	var radius := float(recruit_r.get(u.kind, LegionCfg.RECRUIT_R))
	var best := radius * radius
	var found := false
	var origin := _bucket(u.position)
	for ring in ceili(radius / LegionCfg.POST_BUCKET) + 2:
		var lower := maxf(0.0, (ring - 1) * LegionCfg.POST_BUCKET)
		if lower * lower > best:
			break
		for offset: Vector2i in _ring(ring):
			var cell: Vector2i = origin + offset
			if not cells.has(cell):
				continue
			for candidate: Dictionary in cells[cell]:
				# места той же линии, из которой боец вышел натиском, — не его (no_return_id)
				if (candidate["contract"] as Contract).id == u.no_return_id:
					continue
				var post: Dictionary = candidate["post"]
				var d := u.position.distance_squared_to(post["pos"])
				if d <= best:
					best = d
					found = true
	return best if found else INF


## Достройка после жадной раздачи: для каждого оставшегося без места — самая короткая цепочка
## перестановок (поиск в ширину по бойцам), в конце которой свободное место. Бюджет работы —
## сколько мест-кандидатов просмотреть за вызов (ASSIGN_REPAIR_WORK): в обычном бою его хватает
## с запасом, а в крайнем случае (полторы сотни свободных у шести линий) раздача обрывается
## раньше максимума. Бюджет считает только места в досягаемости, не перебор списка и пути, —
## в такой синтетике вызов доходит до 50–70 мс (verifier 26.09: старый код там 6–12 мс).
## Все, кого обошёл неудачный поиск, до ближайшей удачи — «безнадёжные»: пока раздача не
## менялась, цепочки к свободному месту от них нет, и следующий поиск их не обходит (иначе
## превью на толпе у короткой линии стоило десятки мс — verifier 26.09.2026). Найденная цепочка
## от этого не меняется: через безнадёжного она пройти не может.
func _repair(left: Array[Legionnaire], flats: Dictionary, reserved: Dictionary,
		chosen: Dictionary, total: int) -> void:
	var options: Dictionary = {}   # боец → [места-кандидаты клеток, их расстояния²]
	var hopeless: Dictionary = {}
	var work := LegionCfg.ASSIGN_REPAIR_WORK
	for s in left:
		if work <= 0:
			return
		var flat: Array = flats[s.kind]
		var parent: Dictionary = {}   # боец → [кто хочет его место, кандидат этого места]
		var queue: Array[Legionnaire] = [s]
		var seen: Dictionary = {s: true}
		var head := 0
		var found := false
		while head < queue.size() and work > 0:
			var u: Legionnaire = queue[head]
			head += 1
			if not options.has(u):
				options[u] = _reachable_posts(u, flat)
				work -= (options[u][0] as Array).size()
			var mine: Array = options[u][0]
			var dist: PackedFloat32Array = options[u][1]
			work -= mine.size()
			var free := -1
			for i in mine.size():
				if not reserved.has(mine[i]["key"]) and (free < 0 or dist[i] < dist[free]):
					free = i
			if free >= 0:
				# с конца цепочки: u встаёт на свободное, каждый предок — на место потомка
				var v := u
				var cand: Dictionary = mine[free]
				while true:
					_take(v, cand, reserved, chosen)
					if v == s:
						break
					var link: Array = parent[v]
					v = link[0]
					cand = link[1]
				found = true
				break
			for cand: Dictionary in mine:
				var holder: Legionnaire = (reserved[cand["key"]] as Dictionary)["unit"]
				if not seen.has(holder) and not hopeless.has(holder):
					seen[holder] = true
					parent[holder] = [u, cand]
					queue.append(holder)
		if found:
			hopeless.clear()
		elif head >= queue.size():
			for u in queue:
				hopeless[u] = true
		if reserved.size() >= total:
			return


## Боец встаёт на место-кандидат клетки; его прежнее место освобождается. Путь — в конце раздачи.
func _take(u: Legionnaire, cand: Dictionary, reserved: Dictionary, chosen: Dictionary) -> void:
	if chosen.has(u):
		var old_key: int = (chosen[u] as Dictionary)["key"]
		var cur: Variant = reserved.get(old_key)
		if cur != null and (cur as Dictionary)["unit"] == u:
			reserved.erase(old_key)
	var a := {"unit": u, "contract": cand["contract"], "post": cand["post"], "key": cand["key"]}
	reserved[cand["key"]] = a
	chosen[u] = a


## Все места, куда боец может встать (в радиусе, у живой линии в радиусе, достижимо): кандидаты
## без копий и квадраты расстояний. Только для достройки. Перебор плоского списка мест вида
## (их не больше пары сотен) дешевле колец клеток при радиусе 200+ (сотни клеток на бойца).
func _reachable_posts(u: Legionnaire, flat: Array) -> Array:
	var radius := float(recruit_r.get(u.kind, LegionCfg.RECRUIT_R))
	var r2 := radius * radius
	var near_lines: Dictionary = {}
	var out: Array = []
	var dist := PackedFloat32Array()
	for candidate: Dictionary in flat:
		var post: Dictionary = candidate["post"]
		var d := u.position.distance_squared_to(post["pos"])
		if d > r2:
			continue
		var c: Contract = candidate["contract"]
		if c.id == u.no_return_id:
			continue   # та же линия, из которой боец вышел натиском, — не его (no_return_id)
		if not near_lines.has(c):
			near_lines[c] = c.live_distance(u.position) <= radius
		if not near_lines[c] or not world.terrain.connected(u.position, post["pos"]):
			continue
		out.append(candidate)
		dist.append(d)
	return [out, dist]


## Клетка раздачи мест (LegionCfg.POST_BUCKET): кольца поиска ближнего места — по ней, а не по
## клеткам рельефа (те с v19 мельче, 16 px).
static func _bucket(p: Vector2) -> Vector2i:
	return Vector2i(floori(p.x / LegionCfg.POST_BUCKET), floori(p.y / LegionCfg.POST_BUCKET))


## Смещения клеток кольца ring (квадратное кольцо), кэш на поле.
func _ring(ring: int) -> Array[Vector2i]:
	while ring >= _rings.size():
		var r := _rings.size()
		var offsets: Array[Vector2i] = []
		for y in range(-r, r + 1):
			for x in range(-r, r + 1):
				if maxi(absi(x), absi(y)) == r:
					offsets.append(Vector2i(x, y))
		_rings.append(offsets)
	return _rings[ring]


## Кольца клеток от бойца: найдя ближнее место, дальние клетки вообще не просматриваем.
## Места договора, из которого боец вышел натиском (no_return_id), не считаются: боец не
## возвращается на точки той же линии сам (Игорь 29.09.2026).
func _nearest_assignment(u: Legionnaire, cells: Dictionary, reserved: Dictionary) -> Dictionary:
	var radius := float(recruit_r.get(u.kind, LegionCfg.RECRUIT_R))
	var origin := _bucket(u.position)
	var best_d := radius * radius
	var best: Dictionary = {}
	var near_lines: Dictionary = {}
	for ring in ceili(radius / LegionCfg.POST_BUCKET) + 2:
		var lower := maxf(0.0, (ring - 1) * LegionCfg.POST_BUCKET)
		if lower * lower > best_d:
			break
		for offset: Vector2i in _ring(ring):
			var cell: Vector2i = origin + offset
			if not cells.has(cell):
				continue
			for candidate: Dictionary in cells[cell]:
				if reserved.has(candidate["key"]):
					continue
				var c: Contract = candidate["contract"]
				if c.id == u.no_return_id:
					continue
				var post: Dictionary = candidate["post"]
				var d := u.position.distance_squared_to(post["pos"])
				if d > best_d:
					continue
				if not near_lines.has(c):
					near_lines[c] = c.live_distance(u.position) <= radius
				# дойдёт ли — по связным областям рельефа (v19); маршрут — в конце раздачи, один
				if not near_lines[c] or not world.terrain.connected(u.position, post["pos"]):
					continue
				best_d = d
				best = {"unit": u, "contract": c, "post": post, "key": candidate["key"]}
	return best


func update_preview() -> void:
	_preview = null
	_preview_plan.clear()
	if _draft_len < min_len(_draft) or not match_refresh(_draft).is_empty() or slots_full():
		return
	if _draft_ring:
		_preview = Contract.new().build_ring(_draft, world.terrain.walkable, current_kind)
	elif _draft_fig != &"":
		_preview = Contract.new().build_figure(_draft, _draft_fig, world.terrain.walkable,
			current_kind)
	else:
		var line := _truncate(_draft, LegionCfg.LINE_MAX)
		_preview = Contract.new().build(line, stroke_side(line), world.terrain.walkable,
			current_kind)
	var lines: Array[Contract] = contracts.duplicate()
	lines.append(_preview)
	# B-441: тот же план, что раздаст бой, — с резервом из дома; иначе черновик обещал меньше,
	# чем придёт, и игрок не видел, кого уведёт линия (Игорь 09.10: «не те скелеты идут»)
	for assignment in LegionStaff.deployment_plan(self, lines, _preview):
		if assignment["contract"] == _preview:
			_preview_plan.append(assignment)


## Подпись превью «наберёт N / мест M»; придут ли из них бойцы из дома (автомарш) — в скобках.
func preview_caption(places: int) -> String:
	var home := 0
	for a in _preview_plan:
		if a.get("automarch", false):
			home += 1
	if home > 0:
		return "наберёт %d (%d из дома) / мест %d" % [_preview_plan.size(), home, places]
	return "наберёт %d / мест %d" % [_preview_plan.size(), places]


## Расстояние между ломанными участками, включая пересечение, а не только между центрами.
func _segments_near(a: PackedVector2Array, b: PackedVector2Array) -> bool:
	for i in range(1, a.size()):
		for j in range(1, b.size()):
			if Geometry2D.segment_intersects_segment(a[i - 1], a[i], b[j - 1], b[j]) != null:
				return true
			for p in [a[i - 1], a[i]]:
				if p.distance_to(Geometry2D.get_closest_point_to_segment(p, b[j - 1], b[j])) \
						<= LegionCfg.PACKAGE_R:
					return true
			for p in [b[j - 1], b[j]]:
				if p.distance_to(Geometry2D.get_closest_point_to_segment(p, a[i - 1], a[i])) \
						<= LegionCfg.PACKAGE_R:
					return true
	return false


func tick_packages(dt: float) -> void:
	var times: Dictionary = {}
	_package_pairs.clear()
	for i in contracts.size():
		var a := contracts[i]
		for j in range(i + 1, contracts.size()):
			var b := contracts[j]
			if a.kind == b.kind:
				continue
			for sa in a.seg_count():
				if not a.seg_alive(sa) or a.seg_manned(sa) < LegionCfg.PACKAGE_MIN_UNITS:
					continue
				for sb in b.seg_count():
					if not b.seg_alive(sb) or b.seg_manned(sb) < LegionCfg.PACKAGE_MIN_UNITS:
						continue
					if not _segments_near(a.seg_polys[sa], b.seg_polys[sb]):
						continue
					var key := Vector4i(a.id, sa, b.id, sb)
					var elapsed := float(_pair_times.get(key, 0.0)) + dt
					times[key] = elapsed
					if elapsed >= LegionCfg.PACKAGE_HOLD_TIME:
						_package_pairs.append({"a": a, "sa": sa, "b": b, "sb": sb})
	_pair_times = times


func _pair_alive(pair: Dictionary) -> bool:
	var a: Contract = pair["a"]
	var b: Contract = pair["b"]
	return a.seg_alive(pair["sa"]) and b.seg_alive(pair["sb"]) \
		and a.seg_manned(pair["sa"]) >= LegionCfg.PACKAGE_MIN_UNITS \
		and b.seg_manned(pair["sb"]) >= LegionCfg.PACKAGE_MIN_UNITS


func in_package(c: Contract, seg: int) -> bool:
	for pair in _package_pairs:
		if ((pair["a"] == c and pair["sa"] == seg) or (pair["b"] == c and pair["sb"] == seg)) \
				and _pair_alive(pair):
			return true
	return false


func seal_ready(c: Contract, seg: int) -> bool:
	return c.seg_renewed[seg] != 0 and in_package(c, seg)


# ── «Оцепление»: договор-кольцо (ContractShape) ───────────────────────────────────
# Отдельный раздел: цвет и красоту линий параллельно правит ветка slow/lines, поэтому кольцо
# не переписывает прежние функции отрисовки, а только добавляет свои.

## «Сжать кольцо!»: все живые участки разом к центру (мир — release_ring), отклик на весь круг.
func _squeeze(c: Contract, power: float, perfect: bool) -> void:
	var r := 0.0
	for s in c.seg_count():
		if c.seg_alive(s):
			r = maxf(r, c.seg_center(s).distance_to(c.center))
	if world.release_ring(c, power, perfect) <= 0:
		return
	# стрелки наружу — это не сжатие, а удар во все стороны (Игорь 26.09: «когда наружу расходится,
	# всё равно написано «сжать кольцо»»)
	_popups.append({"pos": c.center, "t": 0.0,
		"text": RING_BURST_LABEL if c.ring_out else RING_SQUEEZE_LABEL,
		"color": LegionCfg.PERFECT_COLOR if perfect else RING_COLOR})
	if perfect:
		# «Точно!» — строкой выше «Сжать кольцо!», иначе крупные буквы наезжают друг на друга
		_popups.append({"pos": c.center + Vector2(0.0, -RING_POPUP_GAP), "t": 0.0})
	if not c.ring_out:
		_ring_fx.append({"center": c.center, "r": r + ARROW_OFFSET, "ms": FxClock.ms()})
	_sound("mine_boom", 0.9)
	Juice.shake(world, LegionCfg.CHARGE_SHAKE * 1.5, LegionCfg.CHARGE_SHAKE_TIME * 1.5)


## Кольцо заключено: надпись над центром — игрок видит, что фигура засчитана.
func _on_ring_made(c: Contract) -> void:
	_popups.append({"pos": c.center, "t": 0.0, "text": RING_LABEL + "!", "color": RING_COLOR})
	_sound("ult_ready", 1.25)


## Прицел рогатки по ФИГУРЕ (крыша, каре, комиссия, неустойка, восьмёрка): стрелка — ОБЩАЯ ось
## оттяжки axis (у каждого участника своё начало траектории, LegionFigures.charge_for), а зона
## «Точно!» — полоса по РЕАЛЬНЫМ местам стоящих участников: пустые длинные рёбра больше не дают
## широкую зону попадания (D-1002 §5). Зона считается от середины строя по оси, ширина — разброс
## мест поперёк оси. lure — гасить «Точно!», если приманка способна перехватить натиск (D-0927-53):
## у восьмёрки фигура срывается целиком, соседние залпы отбрасывают приманку внутрь, поэтому ей
## нужен запас LURE_MARGIN_SHAPE (strike_clear его берёт по c.figure != "").
func figure_aim(c: Contract, seg: int, pull: Vector2, power: float, axis := Vector2.ZERO,
		lure := false) -> Dictionary:
	if axis.is_zero_approx():
		axis = -pull.normalized()
	if axis.is_zero_approx():
		axis = c.seg_dir(seg)
	var reach := float(LegionCfg.UNIT_KINDS[c.kind]["charge_dist"]) \
		* lerpf(LegionCfg.SLING_RANGE.x, LegionCfg.SLING_RANGE.y, power)
	var depth := reach * world.perfect_zone_frac(owner_side)
	var side := axis.orthogonal()
	var n := 0
	var sum := Vector2.ZERO
	var lo := INF
	var hi := -INF
	for p in c.posts:
		var u: Legionnaire = p["unit"]
		if p["dead"] or u == null or u.state != Legionnaire.State.POSTED:
			continue
		n += 1
		sum += u.position
		lo = minf(lo, u.position.dot(side))
		hi = maxf(hi, u.position.dot(side))
	if n == 0:
		return {"dir": axis, "power": power, "pull": pull, "center": c.center,
			"half_w": depth * 0.5, "depth": depth, "perfect": false, "axis": axis}
	var center := sum / float(n)
	var half_w := maxf((hi - lo) * 0.5, LegionCfg.UNIT_RADIUS)
	var perfect := zone_has_foe(center, axis, half_w, depth)
	if perfect and lure:
		pack_live_lures()
		perfect = strike_clear(c, seg, center, axis, half_w, depth,
			zone_foes(center, axis, half_w, depth))
	return {"dir": axis, "power": power, "pull": pull, "center": center, "half_w": half_w,
		"depth": depth, "perfect": perfect, "axis": axis}


## Прицел рогатки по кольцу: стрелка — своя у участка (к центру или наружу), сила — общая,
## «Точно!» — если враг в зоне удара хотя бы одного живого участка.
func ring_aim(c: Contract, seg: int, pull: Vector2, power: float) -> Dictionary:
	var dist := float(LegionCfg.UNIT_KINDS[c.kind]["charge_dist"]) \
		* lerpf(LegionCfg.SLING_RANGE.x, LegionCfg.SLING_RANGE.y, power)
	var perfect := false
	pack_live_lures()
	for s in c.seg_count():
		if not c.seg_alive(s):
			continue
		# зона — по реальному удару участка; пустые участки и треугольник не в счёт (seg_strike);
		# приманка, способная перехватить натиск, гасит «Точно!» (D-0927-53)
		var hit := seg_strike(c, s, power)
		var center := c.seg_center(s)
		var half_w := _seg_length(c, s) * 0.5
		if not hit.is_empty() and zone_has_foe(center, hit["dir"], half_w, hit["depth"]) \
				and strike_clear(c, s, center, hit["dir"], half_w, hit["depth"],
					zone_foes(center, hit["dir"], half_w, hit["depth"])):
			perfect = true
			break
	return {
		"dir": c.seg_dir(seg), "power": power, "pull": pull, "center": c.seg_center(seg),
		"half_w": _seg_length(c, seg) * 0.5, "depth": dist * world.perfect_zone_frac(owner_side),
		"perfect": perfect, "ring": true,
	}


# ── Восьмёрка «Двойная смена», треугольник «Обряд», квадрат «Каре» (LegionFigures) ─────
# Отдельный раздел, как у кольца: прежние функции отрисовки не переписываются.

## Штрих до предела max_len от начала (линия длиннее LINE_MAX — не фигура).
static func _truncate(pts: PackedVector2Array, max_len: float) -> PackedVector2Array:
	var out := PackedVector2Array([pts[0]])
	var run := 0.0
	for i in range(1, pts.size()):
		var seg := pts[i].distance_to(pts[i - 1])
		if run + seg > max_len:
			return out   # по целым точкам: так упирался черновик до фигур (extend)
		run += seg
		out.append(pts[i])
	return out


static func fig_color(fig: StringName) -> Color:
	match fig:
		ContractShape.TRIANGLE:
			return FigureCfg.TRI_COLOR
		ContractShape.SQUARE:
			return FigureCfg.SQUARE_COLOR
		ContractShape.PENTAGON:
			return FigureCfg.PENTA_COLOR
		ContractShape.D_SHAPE:
			return FigureCfg.D_COLOR
	return FigureCfg.EIGHT_COLOR


static func fig_label(fig: StringName) -> String:
	match fig:
		ContractShape.TRIANGLE:
			return FigureCfg.TRI_LABEL
		ContractShape.SQUARE:
			return FigureCfg.SQUARE_LABEL
		ContractShape.PENTAGON:
			return FigureCfg.PENTA_LABEL
		ContractShape.D_SHAPE:
			return FigureCfg.D_LABEL
	return FigureCfg.EIGHT_LABEL


## Что фигура сделает — вторая строка подписи черновика: жест не должен неожиданно значить
## другое (урок Robin Hood), поэтому до отпускания кнопки видно и имя, и суть.
static func fig_hint(fig: StringName) -> String:
	match fig:
		ContractShape.TRIANGLE:
			return "трое на углах · не бьют · набери строй и сорви — обряд"
		ContractShape.SQUARE:
			return "четверо на углах · держат удар и давку · тает дольше"
		ContractShape.PENTAGON:
			return "четверо из пяти углов · щит после подготовки · метят цель"
		ContractShape.D_SHAPE:
			return "двое на углах · выпуск по оттяжке замедляет врагов"
	return "бьют чаще · выпуск крест-накрест"


## Доля мест к награде фигуры: обряд треугольника, «Сверхурочные» восьмёрки; у квадрата — 0
## (награды нет, его польза — пока стоит).
static func fig_need_frac(fig: StringName) -> float:
	match fig:
		ContractShape.TRIANGLE:
			return FigureCfg.RITE_FILL
		ContractShape.EIGHT:
			return FigureCfg.OVERTIME_FILL
	return 0.0


## Сколько мест надо занять к срыву/таянию ради награды фигуры (0 — награды нет).
static func fig_need(c: Contract) -> int:
	return ceili(c.posts.size() * fig_need_frac(c.figure) - 0.001)


## Подпись фигуры: «Обряд 1/2» — сколько из нужных мест занято. Мест у фигуры больше, чем нужно
## для награды (у Обряда два из трёх), поэтому «в строю» бывает больше порога — счёт встаёт на
## пороге (прежде кадр показывал «Обряд 3/2», запись промо 08.10). need ≤ 0 — порога нет.
static func fig_progress_text(label: String, have: int, need: int) -> String:
	if need <= 0:
		return "%s %d" % [label, have]
	return "%s %d/%d" % [label, mini(have, need), need]


## Над строем фигуры (кольца): x центра, y — выше голов верхнего ряда (самое верхнее место или
## точка линии − FigureCfg.CROWD_HEAD). Сюда встают надписи фигуры — не поперёк бойцов.
static func fig_top(c: Contract) -> Vector2:
	var top := c.center.y
	for q in c.points:
		top = minf(top, q.y)
	for p in c.posts:
		top = minf(top, (p["pos"] as Vector2).y)
	return Vector2(c.center.x, top - FigureCfg.CROWD_HEAD)


## Под строем фигуры: самое нижнее место или точка линии (ноги нижнего ряда).
static func fig_bottom(c: Contract) -> float:
	var bottom := c.center.y
	for q in c.points:
		bottom = maxf(bottom, q.y)
	for p in c.posts:
		bottom = maxf(bottom, (p["pos"] as Vector2).y)
	return bottom


func _fig_release(c: Contract, power: float, perfect: bool, axis := Vector2.ZERO) -> void:
	var rites := int(world.stats.get("rites", 0))
	var guards := int(world.stats.get("guards", 0))
	if world.figures.release(c, power, perfect, axis) <= 0:
		return
	var text := FigureCfg.CROSS_LABEL
	if c.figure == ContractShape.EIGHT:
		_cross_fx.append({"a": c.lobes[0], "b": c.lobes[1], "ms": FxClock.ms()})
	elif c.figure == ContractShape.TRIANGLE:
		# обряд подписывает себя сам (on_rite); без него — обычный натиск к центру
		text = "" if int(world.stats.get("rites", 0)) > rites else "Натиск к центру!"
	elif c.figure == ContractShape.SQUARE:
		text = FigureCfg.SQUARE_GUARD_LABEL if int(world.stats.get("guards", 0)) > guards \
			else "Каре — в натиск!"
	else:
		text = fig_label(c.figure) + " — в натиск!"
	if text != "":
		_popups.append({"pos": c.center, "t": 0.0, "text": text,
			"color": LegionCfg.PERFECT_COLOR if perfect else fig_color(c.figure)})
	if perfect:
		_popups.append({"pos": c.center + Vector2(0.0, -RING_POPUP_GAP), "t": 0.0})
	_sound("mine_boom", 0.95)
	Juice.shake(world, LegionCfg.CHARGE_SHAKE * 1.5, LegionCfg.CHARGE_SHAKE_TIME * 1.5)


func _on_figure_made(c: Contract) -> void:
	var text := fig_label(c.figure) + "!"
	if c.figure == ContractShape.TRIANGLE:
		text = FigureCfg.RITE_BEGUN_LABEL
	_popups.append({"pos": fig_popup_pos(c), "t": 0.0, "text": text,
		"color": fig_color(c.figure), "fig": c})
	_sound("ult_ready", 1.1 if c.figure == ContractShape.EIGHT else 0.8)


## Всплывашка с именем фигуры c ещё на поле (B-390 (2)): совет «строй набран» ждёт, пока она
## погаснет, и не ложится на неё, если строй набран сразу.
func fig_popup_alive(c: Contract) -> bool:
	for p in _popups:
		if p.get("fig") == c:
			return true
	return false


## Точка всплывашки с именем фигуры: над строем (fig_top), а не у центра — строй сбегается к
## местам, пока надпись гаснет, и бледная надпись поверх толпы читалась «под бойцами» (кадр
## 4_overtime_0_melt, 02.10). Над фигурой нет места до полосы HUD — под нижним рядом.
func fig_popup_pos(c: Contract) -> Vector2:
	var size := POPUP_POP * float(_fsz(30))
	var top := fig_top(c)
	var text := FigureCfg.RITE_BEGUN_LABEL if c.figure == ContractShape.TRIANGLE \
		else fig_label(c.figure) + "!"
	var w := UiStyle.FONT_TITLE.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1,
		roundi(size)).x
	if world == null or room_above(world, top, size, w, POPUP_RISE):
		return top + Vector2(0.0, POPUP_LIFT)
	return Vector2(c.center.x, fig_bottom(c) + size + POPUP_RISE + POPUP_LIFT)


## Хватит ли места над точкой top для надписи кегля size и ширины w, что за жизнь всплывает ещё на
## rise: прямоугольник надписи не задевает НАСТОЯЩИЕ панели HUD (LegionWorld.hud_world_rects, в т.ч.
## правую «Вызвать») и не выходит за верх видимого поля. Раньше мерили полосой 64 px (B-390 (1)).
static func room_above(world: LegionWorld, top: Vector2, size: float, w: float,
		rise: float) -> bool:
	var view := world.view_rect()
	var rect := Rect2(top.x - w * 0.5, top.y - rise - size, w, size + rise + 4.0)
	rect.position.x = clampf(rect.position.x, view.position.x + 6.0, view.end.x - w - 6.0)
	if rect.position.y < view.position.y:
		return false
	for r in world.hud_world_rects():
		if r.intersects(rect):
			return false
	return true


## «Сверхурочные»: второй натиск восьмёрки сорвался (LegionFigures).
func on_overtime(at: Vector2, _n: int, lobes := PackedVector2Array()) -> void:
	if lobes.size() == 2:
		_cross_fx.append({"a": lobes[0], "b": lobes[1], "ms": FxClock.ms()})
	_popups.append({"pos": at, "t": 0.0, "text": FigureCfg.OVERTIME_LABEL,
		"color": FigureCfg.EIGHT_COLOR, "size": 40.0})
	_sound("mine_boom", 1.2)
	Juice.shake(world, LegionCfg.CHARGE_SHAKE * 1.5, LegionCfg.CHARGE_SHAKE_TIME * 1.5)


## «Обряд!»: вспышка треугольника, волна и крупная надпись (удар и тряску сделал LegionFigures).
func on_rite(c: Contract, r: float) -> void:
	# совет «строй набран — сорви» сделал своё: гаснет в этот же кадр, а не на скане подсказок
	# (кадр 7_rite_0_flash 02.10: «Обряд!» ложилась поверх ещё висящего совета)
	if world.intuit != null and world.my_field() == self:
		world.intuit.on_done(&"rite")
	_rite_fx.append({"center": c.center, "tips": c.tips, "r": r, "ms": FxClock.ms()})
	_popups.append({"pos": c.center + Vector2(0.0, -r * 0.35), "t": 0.0,
		"text": FigureCfg.RITE_LABEL, "color": FigureCfg.TRI_COLOR.lerp(Color.WHITE, 0.35),
		"size": float(FigureCfg.RITE_LABEL_SIZE)})
	_sound("mine_boom", 0.6)   # один плеер поля: второй звук перебил бы первый


## Правый край видимого мира (подписи у курсора не уходят за экран; в «Схватке» — вид ×0,8).
func _screen_w() -> float:
	if world != null:
		return world.view_rect().end.x
	return overlay.get_viewport_rect().size.x if overlay != null else 1280.0


## Размер шрифта подписи поля так, чтобы на экране он был прежним (B-303, вид «Схватки» ×0,8).
func _fsz(size: int) -> int:
	return PvpView.fs(world, size)


func _core_fs() -> int:
	return PvpView.fs(world, LegionCfg.CORE_LABEL_SIZE)


## Надпись шириной w целиком на экране по x (отступ 8 px).
func _clamp_label_x(x: float, w: float) -> float:
	var x0 := world.view_rect().position.x + 8.0 if world != null else 8.0
	return clampf(x, x0, maxf(x0, _screen_w() - 8.0 - w))


func _renderer_view() -> ContractRenderer:
	if _renderer == null:
		_renderer = ContractRenderer.new(self)
	return _renderer
