class_name HowtoLegion
extends Control
##
## Правила режима «По истечении договора» на одном экране (v15, DESIGN_V15.md): текст по
## разделам + маленькие схемы кодом (`_draw`) для управления, без завязки на боевые классы.
## Паттерн карточки — `scripts/ui/howto_overlay.gd`.
##
## Экран стоит отдельно от боя (открывается и из главного меню, и из паузы) — своего мира нет,
## поэтому «соцпакет» ниже читает статический дефолт LegionCfg.LINE_AURA_ENABLED, а не боевой
## флаг конкретного матча (LegionCfg — правило файла: числа/дефолты там, тут только текст).
##

signal closed
## Пакет tutorial: запросить интерактивное обучение на wasteland (docs/legion/TUTORIAL_SPEC.md).
signal tutorial_pressed

## D-0927-121: false — кнопки «Обучение» нет (из боя «Вызова дня» уйти можно только «Меню» с
## подтверждением). Ставить до add_child — читается в _ready().
var show_tutorial := true

## Владелец фокуса до открытия: закрыв экран, вернём клавиатуру ему (кнопке «Как играть»
## паузы или меню), иначе Tab/Enter после закрытия терялись бы в никуда.
var _focus_before: Control = null
var _closing := false

func _ready() -> void:
	UiStyle.fill_rect(self)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	var backdrop := ColorRect.new()
	backdrop.color = Color(0.0, 0.0, 0.0, 0.82)
	UiStyle.fill_rect(backdrop)
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(backdrop)

	# Захватить ДО собственного grab_focus ниже: это фокус нижнего экрана, его и вернём.
	_focus_before = get_viewport().gui_get_focus_owner()

	# v15: шесть разделов не влезают в 720 высоты — UiStyle.card_box центрирует панель
	# анкорами и растёт ПОД содержимое, со ScrollContainer внутри это не сочетается (нечему
	# считать протяжённость прокрутки). Вместо неё — своя панель с фиксированным прямоугольником
	# и прокруткой внутри; стиль панели — тот же panel_style(), что у card_box.
	# interface-safety (03.10): поля панели — от вьюпорта: в 960×540 прежние 230/30 оставляли
	# панели 500 px ширины и текст обрезался (горизонтальной прокрутки нет); в 1280×720
	# пропорции дают те же 230/30, вид не меняется.
	var vp := get_viewport_rect().size
	var side := clampf(vp.x * 0.18, 24.0, 230.0)
	var top := clampf(vp.y * 0.05, 12.0, 30.0)
	var panel := PanelContainer.new()
	panel.name = "HowtoPanel"
	panel.anchor_left = 0.0
	panel.anchor_top = 0.0
	panel.anchor_right = 1.0
	panel.anchor_bottom = 1.0
	panel.offset_left = side
	panel.offset_right = -side
	panel.offset_top = top
	panel.offset_bottom = -maxf(top, 92.0)
	var pst := UiStyle.panel_style(Color(0.07, 0.05, 0.11, 0.97), 16)
	pst.border_color = Color(Cfg.RUNE_COLOR, 0.7)
	pst.set_border_width_all(2)
	pst.content_margin_left = 32.0
	pst.content_margin_right = 32.0
	pst.content_margin_top = 20.0
	pst.content_margin_bottom = 24.0
	panel.add_theme_stylebox_override("panel", pst)
	add_child(panel)
	resized.connect(_fit_panel)
	_fit_panel()

	# interface-safety: заголовок и кнопки — ВНЕ прокрутки, между ними листается только текст:
	# «Понятно» доступно при любом положении чтения, не надо докручивать до низа.
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 10)
	panel.add_child(outer)

	var title := UiStyle.label("Как играть", 34, UiStyle.FONT_TITLE)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	outer.add_child(title)

	var scroll := ScrollContainer.new()
	scroll.follow_focus = true
	scroll.name = "HowtoScroll"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer.add_child(scroll)

	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 10)
	scroll.add_child(box)

	_section(box, "Управление")
	box.add_child(_row(
		"ЛКМ, протяжка — начертить договор. Короткий клик по серой площадке — открыть постройку.",
		_DiagramLine.new()))
	# 25.09.2026: рогатка — главный выпуск, поэтому сразу после рисования; Пробел — только
	# стрелка для таяния и идёт после объяснения таяния (раньше стоял вторым и читался как
	# основной способ — владелец решил, что управление осталось старым).
	box.add_child(_row(
		"ПКМ по участку: оттяните назад и отпустите — отряд сорвётся в натиск (подробно ниже).",
		null))
	# slow/tab-erase (Игорь 29.09): стирание куска линии Табом, бойцы — в натиск
	box.add_child(_row(
		"Таб над линией — стереть кусок под курсором: до ближайшего растаявшего участка, кольцо и "
			+ "фигуру — целиком. Его бойцы сорвутся в натиск по стрелке, мана не вернётся.",
		null))
	box.add_child(_row(
		"Линия тает участками. Растаявший участок отпускает своих бойцов в натиск по стрелке.",
		_DiagramMelt.new()))
	box.add_child(_row(
		"Стрелку для таяния задаёт Пробел или зажатое колесо: держите, пока чертите, и укажите "
			+ "мышью; отпустите и продолжайте от конца пера. Тот же приём над готовой линией или "
			+ "строем над ней — повернуть её стрелку; договор подсветится заранее.",
		_DiagramArrow.new()))
	box.add_child(_row(
		"Подрисуйте поверх линии — продлите срок задетых участков.",
		_DiagramRedraw.new()))
	box.add_child(_row("Замкните линию в круг — «Оцепление»: строй смотрит внутрь, ПКМ по любому "
		+ "участку срывает всё кольцо разом: к центру — «Сжать кольцо!»; Пробел снаружи — "
		+ "стрелки наружу, «Круговой удар!» во все стороны.", null))
	box.add_child(_row("Восьмёрка — «Двойная смена»: строй бьёт чаще, ПКМ — крест-накрест; "
		+ "дождётесь таяния полной — «Сверхурочные», второй натиск.", null))
	box.add_child(_row("Треугольник — «Обряд»: трое встают по одному на углы. Строй не бьёт — "
		+ "держит обряд. Наберите двоих из трёх и держите: обод заряда наполнится за полторы "
		+ "секунды. Сорвите заряженную — удар в центре, оглушение, свежие трупы встают.", null))
	box.add_child(_row("Квадрат — «Каре»: четверо на углах, строй получает меньше урона, давка "
		+ "его не продавливает, фигура тает дольше. Трое из четырёх и заряженный срыв — отряд "
		+ "уйдёт в натиск под защитой.", null))
	box.add_child(_row("Пятиугольник — «Комиссия по упокоению»: четверо на выбранных углах из "
		+ "пяти (пятый угол пуст). Дождавшиеся заряда получают личный щит, а заряженный выпуск "
		+ "метит врага — по меченому группа бьёт сильнее.", null))
	box.add_child(_row("Полукруг — «Неустойка»: прямая сторона и дуга, двое на углах между "
		+ "ними. Заряженный выпуск вешает на врагов просрочку — они замедляются.", null))
	box.add_child(_row("Подготовка: у фигуры копится обод заряда, пока на местах стоит "
		+ "достаточно бойцов (Обряд — двое из трёх, Каре и Комиссия — трое из четырёх, "
		+ "Неустойка — оба). Мало кто встал или ушёл — заряд сбрасывается. Сорвали до готовности "
		+ "— обычный натиск, без ульты.", null))
	box.add_child(_row("Маленькая фигура (меньше ладони) — та же фигура: мест меньше, числа "
		+ "мягче, стоит дешевле. Небольшой резерв, который дёшево держать рядом.", null))
	box.add_child(_row(
		"Волны идут внахлёст: панель справа вверху показывает, кто и откуда придёт следующим. "
			+ "F (или N) и кнопка «Вызвать» — следующая волна сейчас, за сэкономленные секунды "
			+ "дают души.",
		null))
	box.add_child(_row(
		"Трещина: за 10 с до выхода врагов посреди дороги над ней загорается отсчёт и состав — "
			+ "успейте поставить договор ближе к Котлу или перебросить отряд цепочкой договоров.",
		null))
	box.add_child(_row(
		"Прокрутка колеса или клавиши 1/2/3 — вид договора (подряд, охрана, аудит) по мере "
			+ "открытия.",
		null))
	box.add_child(_row(
		"Цена договора — в маны за аршин: аршин — это 100 px линии (примерно пять мест строя в ряд).",
		null))
	box.add_child(_row(
		"Q/W/E — способности некроманта по курсору. Зажмите клавишу — у курсора круг, под целями "
			+ "кольца и подпись, что будет; отпустите — каст. Быстрое нажатие — сразу каст, Esc — "
			+ "передумать.",
		null))
	box.add_child(_row(
		("Способности стоят маны сверх отката — из того же запаса, что договоры. "
			+ "В одиночке: Ку %d, Дубль-вэ "
			+ "%d, Е %d, «Сбор» %d. Цена — в углу слота; красная — не хватает: каст не пройдёт, "
			+ "откат не потратится. Выбирайте: перечертить фронт или ударить.") % [
			roundi(LegionCfg.ABILITY_MANA[0]), roundi(LegionCfg.ABILITY_MANA[1]),
			roundi(LegionCfg.ABILITY_MANA[2]), roundi(LegionCfg.RALLY_MANA)],
		null))
	box.add_child(_row(
		("В «Схватке» свои цены: Ку %d, Дубль-вэ %d, Е %d; восстановление %d маны/с. "
			+ "Текущая цена всегда указана на слоте способности.") % [
			roundi(PvpRules.ABILITY_MANA[0]), roundi(PvpRules.ABILITY_MANA[1]),
			roundi(PvpRules.ABILITY_MANA[2]), roundi(PvpRules.MANA_REGEN)],
		null))
	box.add_child(_row(
		"Ку (Q) — молния по цепи: бьёт ближайшего к курсору врага и перескакивает на соседних, "
			+ "номера под врагами — порядок удара. Оглушает: оглушённый не давит строй, Юрист "
			+ "бросает зачитку, нотариус — печать; натиск по оглушённому сильнее. Призраков строй "
			+ "не бьёт — молния бьёт их ×%s." % LegionAbilityAim.num(LegionCfg.Q_GHOST_MULT),
		null))
	box.add_child(_row(
		("Дубль-вэ (W) — до %d свежих трупов врага у курсора встают и воюют за вас, пока не "
			+ "истечёт срок: подкрепление туда, где поредел строй.") % LegionCfg.W_RAISE_MAX, null))
	box.add_child(_row(
		("Е (E) — «Аврал»: свои бойцы в круге на несколько секунд быстрее и сильнее, а строй держит "
			+ "напор ×%s — спасает линию, которую продавливают (красная дуга у кольца срока).")
			% LegionAbilityAim.num(LegionCfg.E_PRESS_HOLD_MULT),
		null))
	# slow/intuit: когда жать — подсказывает сама игра
	box.add_child(_row(
		"Когда навык готов и сейчас пригодится, его слот пульсирует, а у места на поле "
			+ "всплывает подсказка: Ку — Юрист зачитывает, нотариус замахнулся печатью или толпа "
			+ "давит линию; Е — строй прогибается; Дубль-вэ — у фронта лежат свежие трупы. Над "
			+ "оглушёнными — звёздочки. Подсказки выключаются в «Настройках».",
		null))
	box.add_child(_row(
		"R — «Сбор»: зажмите — у курсора круг и кольца под теми, кто прибежит (серые — за стеной); "
			+ "отпустите — свободные бойцы (над ними «Zz») бегут к курсору. Сами они "
			+ "за врагом не ходят — соберите их к линии или в кучку для натиска. Откат 4 с. "
			+ "«Заново» — в паузе (Esc).",
		null))

	_section(box, "Рогатка: натиск по вашей команде")
	box.add_child(_row(
		"ПКМ по участку, чуть оттяните НАЗАД и отпустите — строй сорвётся вперёд, в сторону, "
			+ "противоположную оттяжке. Сила всегда полная: важно не сколько тянуть, а когда "
			+ "отпустить.",
		_DiagramSling.new()))
	box.add_child(_row(
		"Щелчок ПКМ без оттяжки — выпуск по стрелке договора. Участок светится золотом — враг "
			+ "уже в зоне удара: щелчок по нему сразу даёт «Точно!». Правило одно: золотой — "
			+ "щёлкни, тяни — прицелишься точнее. Короткая оттяжка (бледная стрелка) и Esc или ЛКМ "
			+ "во время натяжки — передумать. Мана за выпуск не возвращается.",
		null))
	box.add_child(_row(
		"ПКМ всегда берёт ОДНУ фигуру: она подсвечивается целиком, уходит по оси оттяжки, а "
			+ "соседняя остаётся на месте. Пустые рёбра фигуры не стена — их продавливает давка, "
			+ "как обычную линию.",
		null))
	box.add_child(_row(
		"Когда отпускать: пока тянете, у курсора «Жди врага в зоне». Враг вошёл — стрелка и зона "
			+ "перед участком золотятся, у курсора «Срывай!». Отпустите в этот миг — «Точно!»: "
			+ "первый удар ×2 и враги отлетают дальше.",
		null))
	box.add_child(_row(
		"Отсрочка: пока тянете, бой идёт почти втрое медленнее. Шкала у курсора тратится за 2,5 с "
			+ "натяжки и копится сама; пустая — время не замедляется.",
		null))
	box.add_child(_row(
		"Комбо: натиск, задевший врага не позже 4 с после прошлого, растит комбо — урон натиска "
			+ "и души за его убийства до ×1,8. Натиск впустую или пауза дольше 4 с — сброс.",
		null))
	box.add_child(_row(
		"В настройках можно вернуть классику: ПКМ — только щелчок, без натяжки и замедления.",
		null))

	_section(box, "Давка и пружина")
	box.add_child(_row(
		"Строй держит столько врагов, сколько в нём бойцов (охрана — больше, аудит — меньше). "
			+ "Толпа сверх этого давит участок: он прогибается, вокруг кольца срока растёт "
			+ "красная дуга. Дуга замкнулась — «Прорыв!»: бойцов раскидывает, колонна идёт в дыру.",
		null))
	box.add_child(_row(
		"Прогнутый участок — сжатая пружина: над ним «пружина ×N» — во сколько раз ударит "
			+ "натиск, если сорвать сейчас (до ×1,9), и отбросит дальше; метка покраснела — до "
			+ "прорыва близко, срывайте. Стена на дороге хороша против горстки; колонну "
			+ "встречайте пружиной, натиском с фланга, Ку — или стройте охрану.",
		null))
	box.add_child(_row(
		"Постройки выпускают бойцов в стороне от дороги — на проезжую часть сами не встают.",
		null))

	_section(box, "Препятствия")
	box.add_child(_row(
		"Стены, ограды, склепы, саркофаги, скалы и кучи хлама не пропускают ни бойцов, ни пеших "
			+ "врагов, а линия договора обрывается о них. Пока чертите или тянете рогатку — и в "
			+ "начале боя — они обведены красной штриховкой. Надгробия, деревья и фонари не мешают; "
			+ "призраков стены не держат.",
		null))

	_section(box, "Дальность")
	box.add_child(_row(
		"Договор набирает только своих бойцов в радиусе. «Наберёт N / мест M» на черновике и "
			+ "пузырь «Zz» над теми, кто не дотянулся, — сигнал переставить линию ближе. "
			+ "Пузырь с точками — договор рядом, но мест не хватило: протяни линию длиннее.",
		null))
	if LegionCfg.LINE_AURA_ENABLED:
		box.add_child(_row(
			"Соцпакет: боец рядом с живым договором своего вида восстанавливает HP, даже стоя без дела.",
			null))

	_section(box, "Штат и возрождение")
	box.add_child(_row(
		"Армия = сумма штатов построек. Погибший освобождает место; через время возрождения "
			+ "постройка выпускает нового — своим таймером у каждого места.",
		null))
	box.add_child(_row(
		"Котёл выпускает подрядчиков всегда. Постройки на площадках — за души, по виду бойцов; "
			+ "улучшение — больше штат и короче возрождение.",
		null))

	_section(box, "Души и премия")
	box.add_child(_row(
		"Души — валюта боя: за убийства и отбитые волны. Тратятся на постройки и их улучшение, "
			+ "а в разгар боя — на «Срочный найм»: павшие постройки встают сразу, без возрождения.",
		null))
	box.add_child(_row(
		"Премия — валюта между картами: за исход боя. В «Конторе» — апгрейды дальности, штата, "
			+ "возрождения и маны по видам.",
		null))

	_section(box, "Виды бойцов, пакет и печать")
	box.add_child(_row(
		"Подряд, охрана, аудит — каждый вид договора набирает только своих: у охраны броня "
			+ "спереди, у аудита — дальний бой и обзор призраков.",
		null))
	box.add_child(_row(
		"Пакет: участки двух разных видов рядом усиливают строй на обоих — вместе держат крепче.",
		null))
	box.add_child(_row(
		"Расчёт: участок, который вы подновляли и который истёк сам, платит бойцам, отстоявшим "
			+ "срок, — прибавку здоровья (до двойного). Усиливает поправка «Бумажная броня».",
		null))
	box.add_child(_row(
		"Печать расчёта: участок в пакете, истёкший сам (не ПКМ), выпускает отряд с временным "
			+ "усилением удара.",
		null))

	_section(box, "Враги")
	box.add_child(_row(
		"Инспектор, курьер, нотариус — обычные проверяющие. Призрака бьют только свободные и "
			+ "атакующие бойцы (и аудит — из строя). Надгробие таится под видом сокровища.",
		null))
	box.add_child(_row(
		"Щитоносец держит щит спереди — снаряды почти не берут, заходи с фланга или в ближний бой. "
			+ "Прораб — финальный босс: таранит строй и осаждает Котёл.",
		null))

	_section(box, "Артефакты")
	box.add_child(_row(
		("Элитный враг — крупнее, в золотом ореоле и короне, втрое толще и даёт больше душ. "
			+ "Со второй половины боя (не в последней волне) изредка идёт НОСИТЕЛЬ — элитный с "
			+ "голубым портфелем над короной: убей его, и выпадет артефакт. Не больше %d за бой, "
			+ "бывает и ни одного.") % CfgItems.MAX_PER_BATTLE,
		null))
	box.add_child(_row(
		"Артефакт сильный и заметный: меняет, как работает навык, линия, бойцы или Котёл, и "
			+ "меняет их вид (молния другого цвета, печати на бойцах, огоньки на крышах). Собранные "
			+ "артефакты остаются на всю кампанию или весь забег — сохраняются победой. Наведите "
			+ "курсор на иконку в полоске слева внизу — название и что делает.",
		null))

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 16)
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	outer.add_child(buttons)

	var tutorial_btn := Button.new()
	tutorial_btn.name = "HowtoTutorial"
	tutorial_btn.text = "Обучение"
	tutorial_btn.custom_minimum_size = Vector2(180.0, 44.0)
	tutorial_btn.add_theme_font_override("font", UiStyle.FONT_TITLE)
	tutorial_btn.add_theme_font_size_override("font_size", 20)
	UiStyle.style_button(tutorial_btn)
	tutorial_btn.pressed.connect(func() -> void: tutorial_pressed.emit())
	if show_tutorial:
		buttons.add_child(tutorial_btn)
	else:
		tutorial_btn.free()

	var nav := LegionUi.nav_bar(self, "← Назад", _close)
	var close_btn := nav.get_node("NavBack") as Button
	close_btn.name = "HowtoClose"

	# Начальный фокус — «Понятно»: главный ответ экрана, Esc делает то же; Tab дальше идёт
	# по «Обучению». Отложенно: фокус — после входа панели в дерево.
	close_btn.grab_focus.call_deferred()


## Один путь закрытия для Esc и «Понятно»: сначала вернуть фокус прежнему владельцу (по closed
## подписчик делает queue_free — позже возвращать было бы некому), затем сигнал.
func _close() -> void:
	if _closing:
		return
	_closing = true
	if _focus_before != null and is_instance_valid(_focus_before) \
			and _focus_before.is_inside_tree():
		_focus_before.grab_focus()
	closed.emit()


## Esc закрывает только этот экран. _input с потреблением: мир и экран паузы под нами слушают
## «pause» (Esc и P) ниже по цепочке — без потребления одно нажатие ушло бы дальше и следом
## сняло бы паузу боя. echo гасим: автоповтор Esc не должен захлопнуть то, что откроется на
## этом же месте. Берём только ui_cancel — Tab, стрелки и Enter уходят в GUI.
func _input(event: InputEvent) -> void:
	if event.is_echo() or not is_visible_in_tree():
		return
	if _closing:
		get_viewport().set_input_as_handled()
		return
	if event is InputEventKey:
		ModalFocus.contain(self)
	if event.is_action_pressed(&"ui_cancel"):
		get_viewport().set_input_as_handled()
		_close()


## Боевые горячие клавиши (P из «pause», F/N — волна, R — «Сбор», Ку/Дубль-вэ/Е) под модальным
## экраном миром не управляют. Стадия _unhandled_key_input — ПОСЛЕ GUI (клавиатура виджетов
## жива) и ДО LegionWorld._unhandled_input.
func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and is_visible_in_tree():
		get_viewport().set_input_as_handled()


## Страховка от путей в обход _unhandled_key_input (например, echo-события): пока экран
## открыт, клавиатура не доходит до мира ни одной дорогой.
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and is_visible_in_tree():
		get_viewport().set_input_as_handled()


## Заголовок раздела — карточка выросла с одного списка до шести разделов (v15), без подписи
## правила расползаются в сплошной текст.
func _fit_panel() -> void:
	var panel := get_node_or_null("HowtoPanel") as PanelContainer
	if panel == null:
		return
	var side := clampf(size.x * 0.18, 24.0, 230.0)
	var top := clampf(size.y * 0.05, 12.0, 30.0)
	panel.offset_left = side
	panel.offset_right = -side
	panel.offset_top = top
	panel.offset_bottom = -maxf(top, 92.0)


func _section(box: Control, text: String) -> void:
	var label := UiStyle.label(text, 20, UiStyle.FONT_TITLE, UiStyle.GOLD)
	box.add_child(label)


## Строка «схема слева, текст справа» — схема необязательна (null для чисто текстовых правил).
func _row(text: String, diagram: Control) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	if diagram != null:
		diagram.custom_minimum_size = Vector2(90.0, 46.0)
		diagram.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(diagram)
	else:
		var spacer := Control.new()
		spacer.custom_minimum_size = Vector2(90.0, 46.0)
		spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(spacer)
	var label := UiStyle.label(Controls.text(text), 17, UiStyle.FONT_TEXT)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD
	# interface-safety: ширина — от карточки, а не константа 630: в окне 960×540 фиксированная
	# строка вылезала за панель, а горизонтальной прокрутки нет — текст обрезался. Теперь
	# лишнее переносится по фактической ширине.
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(label)
	return row


## Прямая линия с точками-бойцами вдоль неё.
class _DiagramLine:
	extends Control
	func _draw() -> void:
		var w := size.x
		var h := size.y * 0.5
		draw_line(Vector2(6, h), Vector2(w - 6, h), UiStyle.SOUL, 3.0)
		for i in 5:
			var x := 10.0 + float(i) * (w - 20.0) / 4.0
			draw_circle(Vector2(x, h), 4.0, UiStyle.GOLD)


## Линия со стрелкой-нормалью, показывающей направление натиска.
class _DiagramArrow:
	extends Control
	func _draw() -> void:
		var w := size.x
		var h := size.y * 0.5
		draw_line(Vector2(6, h), Vector2(w - 6, h), UiStyle.SOUL, 3.0)
		var tip := Vector2(w * 0.5, h - 26.0)
		var base := Vector2(w * 0.5, h)
		draw_line(base, tip, UiStyle.BAD, 3.0)
		draw_line(tip, tip + Vector2(-6, 8), UiStyle.BAD, 3.0)
		draw_line(tip, tip + Vector2(6, 8), UiStyle.BAD, 3.0)


## Рогатка: линия прогнута назад к курсору (оттяжка), толстая стрелка — вперёд.
class _DiagramSling:
	extends Control
	func _draw() -> void:
		var w := size.x
		var h := size.y * 0.5
		var pull := Vector2(w * 0.5, h + 16.0)
		draw_polyline(PackedVector2Array([Vector2(w * 0.5 - 22, h - 6), pull,
			Vector2(w * 0.5 + 22, h - 6)]), UiStyle.SOUL, 3.0)
		draw_dashed_line(pull, pull + Vector2(0, 6), UiStyle.TEXT_DIM, 2.0, 3.0)
		var tip := Vector2(w * 0.5, 2.0)
		var base := Vector2(w * 0.5, h - 10.0)
		draw_line(base, tip + Vector2(0, 8), UiStyle.WARN, 5.0)
		draw_colored_polygon(PackedVector2Array([tip, tip + Vector2(-8, 10), tip + Vector2(8, 10)]),
			UiStyle.WARN)


## Участок линии мигает и тает — точки бойцов слева уходят направо (в натиск).
class _DiagramMelt:
	extends Control
	func _draw() -> void:
		var w := size.x
		var h := size.y * 0.5
		draw_line(Vector2(6, h), Vector2(w * 0.5, h), UiStyle.SOUL, 3.0)
		draw_line(Vector2(w * 0.5, h), Vector2(w - 6, h), UiStyle.WARN.darkened(0.2), 3.0)
		draw_circle(Vector2(14.0, h), 4.0, UiStyle.GOLD)
		draw_circle(Vector2(w - 14.0, h), 4.0, UiStyle.BAD)
		var tip := Vector2(w - 14.0, h)
		draw_line(tip, tip + Vector2(-8, -6), UiStyle.BAD, 2.0)
		draw_line(tip, tip + Vector2(-8, 6), UiStyle.BAD, 2.0)


## Второй штрих поверх линии — «продление».
class _DiagramRedraw:
	extends Control
	func _draw() -> void:
		var w := size.x
		var h := size.y * 0.5
		draw_line(Vector2(6, h), Vector2(w - 6, h), UiStyle.SOUL.darkened(0.3), 3.0)
		draw_line(Vector2(w * 0.25, h), Vector2(w * 0.75, h), UiStyle.GOOD, 4.0)
