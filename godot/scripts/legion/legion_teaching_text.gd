extends RefCounted
## Учебные числа читают боевой конфиг. Геометрия мест — из того же Contract, что у поля.


static func number(value: float) -> String:
	return ("%.2f" % value).trim_suffix("0").trim_suffix("0").trim_suffix(".").replace(".", ",")


static func seats(figure: StringName) -> int:
	return FigureCfg.PENTA_SEATS if figure == &"pentagon" else Contract._figure_corners(figure)


static func required(figure: StringName) -> int:
	return ceili(seats(figure) * float(FigureCfg.CHARGE_FILL.get(figure, 0.0)) - 0.0001)


static func render(source: String) -> String:
	var values := {"rally_cd": LegionCfg.RALLY_CD, "perfect": LegionCfg.PERFECT_FIRST_MULT,
		"slow": LegionCfg.DELAY_SLOW, "delay": LegionCfg.DELAY_MAX / LegionCfg.DELAY_DRAIN,
		"combo_window": LegionCfg.COMBO_WINDOW, "combo_cap": LegionCfg.COMBO_CAP,
		"spring": 1.0 + LegionCfg.SPRING_DMG, "charge": FigureCfg.CHARGE_TIME}
	for key: String in values:
		source = source.replace("{cfg:" + key + "}", number(float(values[key])))
	for figure: StringName in FigureCfg.CHARGE_FILL:
		source = source.replace("{seats:" + String(figure) + "}", str(seats(figure)))
		source = source.replace("{charge:" + String(figure) + "}",
			"%d из %d" % [required(figure), seats(figure)])
	return source
