extends SceneTree
##
## E-1005: свод модификаторов из РАЗНЫХ источников (каждая поправка, артефакт, подготовка «Конторы»)
## одним правилом — ключ-множитель перемножается (∏(1+v)), прибавочный складывается; строка
## «Вместе с „X“: …» на экране выбора поправок; режим боя (in_campaign) у забега.
##
## До правки те же числа были другими — сверено пробой на базовой ревизии d6c8626d
## (int-oct05/tE-before/, «BEFORE E-1005: 0/5 OK»); сам файл на базе не запускается: модуля MetaMods
## и четвёртого параметра configure() там ещё нет.
##   * «Текучка кадров» + «Живая очередь» складывали cap_mult в −45 % (0,55) вместо 0,75·0,8 = 0,6;
##   * «Опасное напряжение» (−0,5 к оглушению) и «Скрепка судьбы» (+0,5) взаимно гасились в ×1,0
##     вместо ×0,75 — артефакт молчал;
##   * MetaMods.together_notes() не существовало, строки на карточке не было.
##
##   "$GODOT" --headless --path godot --fixed-fps 60 --script
##       res://tests/legion_amendments_e1005_test.gd
##       -- --mute

const TEST_PATH := "user://legion_e1005_test.cfg"

var checks := 0
var fails := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		fails += 1
		print("FAIL: ", label)


func _run() -> void:
	Campaign.set_save_path(TEST_PATH)
	_test_multipliers()
	_test_together_notes()
	await _test_card_line()
	await _test_artifact_branch()
	await _test_endless_mode()
	print("AMENDMENTS E-1005: %d/%d OK" % [checks - fails, checks])
	quit(1 if fails > 0 else 0)


## Ключ-множитель от разных источников — произведение (E-1005), прибавочный — по-прежнему сумма.
func _test_multipliers() -> void:
	Campaign.use_campaign_scope()
	Campaign.reset()
	Campaign.unlock_all()
	Campaign.add_upgrade(&"lean_staff")     # cap_mult_* −0,25
	Campaign.add_upgrade(&"living_queue")   # cap_mult_* −0,2
	var two := Campaign.stat(&"cap_mult_laborer")
	_check(is_equal_approx(two, 0.75 * 0.8), "два множителя перемножаются: %.3f" % two)
	_check(not is_equal_approx(two, 1.0 - 0.25 - 0.2), "и не сумма −45 %%, как раньше: %.3f" % two)
	Campaign.add_upgrade(&"soul_dividend")  # cap_mult_* −0,15 — третья карточка сборки
	var three := Campaign.stat(&"cap_mult_laborer")
	_check(is_equal_approx(three, 0.75 * 0.8 * 0.85),
		"три источника — произведение, не «приговор» −60 %%: %.3f" % three)

	# Прибавочные ключи вилку не меняют: recruit_r_* −60 и +100 = +40 (условие «а не произведение»).
	Campaign.reset()
	Campaign.unlock_all()
	Campaign.add_upgrade(&"bulk_ink")       # recruit_r_* −60, mana_cost_mult −0,35
	Campaign.add_upgrade(&"moving_office")  # recruit_r_* +100, mana_cost_mult +0,25
	_check(is_equal_approx(Campaign.stat(&"recruit_r_laborer"), 40.0),
		"прибавочный ключ складывается: %.1f" % Campaign.stat(&"recruit_r_laborer"))
	var cost := Campaign.stat(&"mana_cost_mult")
	_check(is_equal_approx(cost, 0.65 * 1.25),
		"«Мелкий шрифт» и «Выездная канцелярия» больше не гасят друг друга: %.4f" % cost)
	_check(not is_equal_approx(cost, 1.0 - 0.35 + 0.25),
		"и не сходятся в −10 %% (старое): %.4f" % cost)

	# e_dur — прибавка к длительности Аврала: −2 и +4 = +2.
	Campaign.reset()
	Campaign.unlock_all()
	Campaign.add_upgrade(&"temp_agency")     # e_dur −2
	Campaign.add_upgrade(&"overtime_cycle")  # e_dur +4
	_check(is_equal_approx(Campaign.stat(&"e_dur"), 2.0),
		"e_dur складывается: %.1f" % Campaign.stat(&"e_dur"))


## Строка «Вместе с „X“» на экране выбора: ключ, который карточка делит с действующим источником,
## и итог — тем же правилом, что считает бой.
func _test_together_notes() -> void:
	Campaign.use_campaign_scope()
	Campaign.reset()
	Campaign.unlock_all()
	Campaign.add_upgrade(&"living_queue")            # cap_mult_* −0,2
	Campaign.set_run_items([&"clip_of_fate"])        # артефакт забега: q_stun +0,5
	var with_share := MetaMods.together_notes(&"lean_staff")
	_check(with_share.size() == 1 and with_share[0].contains("Живая очередь")
		and with_share[0].contains("0,6"),
		"штат трёх видов — одна строка о дележе: %s" % str(with_share))
	var artifact_share := MetaMods.together_notes(&"high_voltage")
	_check(artifact_share.size() == 1 and artifact_share[0].contains("Скрепка судьбы")
		and artifact_share[0].contains("0,75"),
		"«Вместе с „Скрепка судьбы“: оглушение разряда ×0,75»: %s" % str(artifact_share))
	_check(MetaMods.together_notes(&"bulk_ink").is_empty(),
		"карточка без общих множителей молчит")
	_check(MetaMods.together_notes(&"golden_exit").is_empty(),
		"charge_dmg_mult делить не с кем — молчит")
	Campaign.set_run_items([])


## Та же строка действительно попадает на строку экрана выбора (E-1005 п.6) — проверяем по подписям,
## которые реально построил ProgressionRow с флагом together.
func _test_card_line() -> void:
	Campaign.use_campaign_scope()
	Campaign.reset()
	Campaign.unlock_all()
	Campaign.add_upgrade(&"living_queue")
	Campaign.set_run_items([&"clip_of_fate"])
	var data := AmendmentDb.card(&"lean_staff")
	var row := ProgressionRow.new()
	root.add_child(row)
	row.configure(&"lean_staff", data, "Подписать поправку", {"together": true})
	await process_frame
	var texts: Array[String] = []
	var told := false
	for l: Node in row.find_children("*", "Label", true, false):
		var t := (l as Label).text
		texts.append(t)
		told = told or t.begins_with("Вместе с")
	_check(told, "строка выбора несёт текст «Вместе с…»: %s" % str(texts))
	var plain := ProgressionRow.new()
	root.add_child(plain)
	plain.configure(&"lean_staff", data, "Вычеркнуть этот пункт")
	await process_frame
	var extra := false
	for l: Node in plain.find_children("*", "Label", true, false):
		extra = extra or (l as Label).text.begins_with("Вместе с")
	_check(not extra, "на «вычеркнуть» строки о дележе нет (там речь о потере, не о наборе)")
	row.queue_free()
	plain.queue_free()
	await process_frame
	Campaign.set_run_items([])


## Бой: поправка и артефакт — разные источники одного ключа. «Скрепка судьбы» поверх «Опасного
## напряжения» даёт ×0,75, а не взаимное гашение в базовое оглушение.
func _test_artifact_branch() -> void:
	var w := LegionWorld.new()
	root.add_child(w)
	await process_frame
	Campaign.set_save_path(TEST_PATH)
	Campaign.use_campaign_scope()
	Campaign.reset()
	Campaign.unlock_all()
	Campaign.add_upgrade(&"high_voltage")   # q_stun −0,5, q_chain +2
	w.dev = {"no_waves": "1", "spawn_units": "0"}
	w.in_campaign = true
	w.mods = Campaign.active_mods()
	w.start_map("_gray")
	w.set_process(false)
	w.set_physics_process(false)
	_check(is_equal_approx(w.hero.q_stun(), LegionCfg.Q_STUN * 0.5),
		"одна поправка: оглушение ×0,5 (%.3f)" % w.hero.q_stun())
	w.items.grant(&"clip_of_fate")          # q_stun +0,5, q_chain +2
	_check(is_equal_approx(w.hero.q_stun(), LegionCfg.Q_STUN * 0.75),
		"поправка × артефакт = ×0,75, а не гашение в ×1,0 (было %.3f)" % w.hero.q_stun())
	_check(is_equal_approx(w.item_add(&"q_stun"), -0.25),
		"q_stun — свод ∏(1+v)−1 = −0,25 (%.3f)" % w.item_add(&"q_stun"))
	_check(is_equal_approx(w.item_add(&"q_chain"), 4.0),
		"q_chain — прибавка, складывается: +2 и +2 (%.1f)" % w.item_add(&"q_chain"))
	# Подготовка «Конторы» — отдельный источник того же котла: −25 от карточки и +30 от «Термоса».
	Campaign.add_upgrade(&"overtime_cycle")   # mana_max_bonus −25
	w.battle_preparation = {"mana_max_bonus": 30.0}
	_check(is_equal_approx(w.camp_stat(&"mana_max_bonus"), 5.0),
		"подготовка складывается с поправкой: %.1f" % w.camp_stat(&"mana_max_bonus"))
	w.queue_free()
	await process_frame


## Забег — полноценный режим кампании: старт боя сам ставит in_campaign, и это не «липнет» —
## после «Схватки» (in_campaign = false) забег возвращает его себе.
func _test_endless_mode() -> void:
	Campaign.set_save_path(TEST_PATH)
	Campaign.reset()
	Campaign.unlock_all()
	Campaign.use_endless_scope()
	Campaign.add_upgrade(&"bulk_ink")       # канал camp_stat: mana_cost_mult −0,35
	Campaign.add_upgrade(&"ghost_clause")   # правило боя: призрак растаявшего участка
	Campaign.use_campaign_scope()
	var main := (load("res://scenes/legion.tscn") as PackedScene).instantiate() as LegionMain
	root.add_child(main)
	await process_frame
	main._start_endless_battle("_gray")
	await process_frame
	var w := main.world
	_check(w != null and w.in_campaign, "забег: мир снова «в кампании» (из меню было false)")
	_check(not w.pvp and w.amendment_runtime.rules.has("ghost"),
		"правило поправки подписано на бой забега: %s" % str(w.amendment_runtime.rules.keys()))
	_check(is_equal_approx(w.camp_stat(&"mana_cost_mult"), 0.65),
		"канал camp_stat жив в забеге: цена договора ×0,65 (%.3f)" % w.camp_stat(&"mana_cost_mult"))

	# «Схватка» — вне кампании, и после неё забег обязан включить режим себе сам, а не унаследовать.
	PvpFlow.start(main, "pvp:duel")
	await process_frame
	_check(w.pvp and not w.in_campaign and w.mods.is_empty(),
		"«Схватка»: поправки забега не текут (in_campaign=false)")
	main._start_endless_battle("_gray")
	await process_frame
	_check(not w.pvp and w.in_campaign, "после «Схватки» забег снова читает свою мету")
	_check(is_equal_approx(w.camp_stat(&"mana_cost_mult"), 0.65) and w.amendment_runtime.rules.has(
		"ghost"), "и карточки забега живы, а не «мёртвое» состояние")
	main.queue_free()
	await process_frame
