extends SceneTree
## EN presentation must format after translation without changing canonical game data.

const Teaching := preload("res://scripts/legion/legion_teaching_text.gd")
var _checks := 0
var _fails := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(ok: bool, label: String) -> void:
	_checks += 1
	if not ok:
		_fails += 1
		print("FAIL ", label)


func _english(text: String) -> bool:
	var russian := RegEx.new()
	russian.compile("[А-Яа-яЁё]")
	return russian.search(text) == null


func _run() -> void:
	Settings.path = "user://localization_runtime_b_test.cfg"
	Settings.lefty_override = "off"
	var map_before := JSON.stringify(Campaign.FALLBACK_MAPS)
	var amendments_before := JSON.stringify(AmendmentDb.CARDS)
	I18n.language = "en"
	_check(LegionAbilityAim.num(1.25) == "1.25", "English decimal point")
	_check(Teaching.number(0.25) == "0.25", "English teaching decimal point")
	_check(LegionAbilityAim.plural(21, "цель", "цели", "целей") == "targets",
		"21 targets is plural in English")
	_check(LegionAbilityAim.plural(1, "цель", "цели", "целей") == "target",
		"one target is singular in English")
	var shape := Teaching.render(
		"Треугольник — «Обряд»: {charge:triangle}, заряд {cfg:charge} с, ПКМ — срыв")
	_check(_english(shape) and shape.contains(" of "), "shape count inserted in English")
	_check(not shape.contains("{cfg:") and not shape.contains("{charge:"),
		"shape numeric placeholders resolved")
	_check(_english(ContractField.limit_label()), "contract limit translated before formatting")
	_check(ContractField.limit_label().contains(Controls.label(&"erase_piece")),
		"contract limit preserves binding")
	_check(ContractField.fig_label(ContractShape.TRIANGLE) == "Ritual", "figure name")
	_check(_english(LegionKassa.reason_text("souls")), "cash desk failure")
	_check(_english(LegionEndless.death_reason("boss")), "death reason")
	_check(_english(Controls.text(LegionMapHints.SIGNER_HINT)), "joined notary hint")
	_check(_english(Controls.text(LegionTutorial.HINT_NOT_PRESSED)), "joined tutorial hint")
	_check(PgLayout.display_road_text("вост. верх.") == "E top", "short road branch")
	_check(_english(PgLayout.display_road_text("восточные ворота, верхняя ветка")),
		"full road branch")
	_check(PgLayout.display_road_text("4-я") == "#4", "numbered road branch")
	_check(_english(LegionChallenge.answer_hint([{"type": "ghost"},
		{"type": "shield_inspector"}])), "joined wave counter advice")
	var report := {"damage": 20.0, "sources": {"boss": 20.0},
		"roads": {"east": 20.0}, "waves": {"2": 20.0}, "first_at": 61.0}
	for line in BattleDebrief.lines(report):
		_check(_english(line), "battle debrief " + line)
	_check(JSON.stringify(Campaign.FALLBACK_MAPS) == map_before, "map data unchanged")
	_check(JSON.stringify(AmendmentDb.CARDS) == amendments_before, "amendment data unchanged")
	I18n.language = "ru"
	_check(LegionAbilityAim.num(1.25) == "1,25", "Russian decimal unchanged")
	_check(Teaching.number(0.25) == "0,25", "Russian teaching decimal unchanged")
	_check(LegionAbilityAim.plural(21, "цель", "цели", "целей") == "цель",
		"Russian plural unchanged")
	_check(ContractField.fig_label(ContractShape.TRIANGLE) == "Обряд", "Russian figure unchanged")
	print("LOCALIZATION RUNTIME B: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails else 0)

