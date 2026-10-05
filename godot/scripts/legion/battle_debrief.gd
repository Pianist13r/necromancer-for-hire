class_name BattleDebrief
extends RefCounted
## Наблюдения о потерянном HP. Не угадывает, почему игрок выбрал действие или проиграл.


static func record(stats: Dictionary, damage: float, foe: String, source: Dictionary,
		at: float) -> void:
	if damage <= 0.0:
		return
	var report: Dictionary = stats.get("debrief", {
		"damage": 0.0, "sources": {}, "roads": {}, "waves": {}, "first_at": at,
	})
	report["damage"] = float(report["damage"]) + damage
	report["last_at"] = at
	_add(report["sources"], foe if foe != "" else "unknown", damage)
	var road := String(source.get("road", ""))
	if road != "":
		_add(report["roads"], road, damage)
	var wave := int(source.get("wave", 0))
	if wave > 0:
		_add(report["waves"], str(wave), damage)
	stats["debrief"] = report


static func _add(bucket: Dictionary, key: String, value: float) -> void:
	bucket[key] = float(bucket.get(key, 0.0)) + value


static func _largest(bucket: Dictionary) -> String:
	var result := ""
	var maximum := 0.0
	for key: String in bucket:
		if float(bucket[key]) > maximum:
			maximum = float(bucket[key])
			result = key
	return result


static func lines(report: Dictionary) -> Array[String]:
	var out: Array[String] = []
	var total := float(report.get("damage", 0.0))
	if total <= 0.0:
		return out
	var sources: Dictionary = report.get("sources", {})
	var foe := _largest(sources)
	if foe != "" and foe != "unknown":
		var title := String(Briefing.FOE_NAMES.get(foe, "Проверяющие"))
		out.append("%s: %d из %d потерянных HP." % [title,
			roundi(float(sources[foe])), roundi(total)])
	var roads: Dictionary = report.get("roads", {})
	var road := _largest(roads)
	if road != "":
		var titles: Dictionary = report.get("road_titles", {})
		var title := String(titles.get(road, LegionCfg.ROAD_TITLES.get(road, "подход к Котлу")))
		out.append("Главный прорыв — %s: %d HP." % [title, roundi(float(roads[road]))])
	var waves: Dictionary = report.get("waves", {})
	var wave := _largest(waves)
	if wave != "":
		out.append("Враги волны %s отняли %d HP. Первый удар — %d:%02d." % [wave,
			roundi(float(waves[wave])), int(float(report.get("first_at", 0.0))) / 60,
			int(float(report.get("first_at", 0.0))) % 60])
	return out


static func panel(report: Dictionary, color: Color = UiStyle.TEXT_DIM) -> Control:
	var box := VBoxContainer.new()
	box.name = "BattleDebrief"
	box.add_theme_constant_override("separation", 3)
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var observations := lines(report)
	if observations.is_empty():
		box.visible = false
		return box
	box.add_child(UiStyle.label("Разбор полётов", 19, UiStyle.FONT_TITLE, color))
	for text in observations:
		var label := UiStyle.label(text, 16, UiStyle.FONT_TEXT, color)
		label.autowrap_mode = TextServer.AUTOWRAP_WORD
		box.add_child(label)
	return box
