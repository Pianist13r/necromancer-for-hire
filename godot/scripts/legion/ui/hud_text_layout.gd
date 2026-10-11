class_name LegionHudTextLayout
extends RefCounted
## Measured layout for fixed HUD panels. Text keeps its full localized wording.

const GAP := 10.0
const NUMBER_EDGE := 6.0


static func width(font: Font, text: String, font_size: int) -> float:
	return font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x


static func fit_font(font: Font, text: String, font_size: int, available: float) -> int:
	while font_size > 1 and width(font, text, font_size) > available:
		font_size -= 1
	return font_size


## Stable widths reserve four digits, so changing counters do not move HUD columns.
static func columns(original: Array[float], captions: Array[String], reserves: Array[String],
		icon_width: float) -> Array[float]:
	var total := 0.0
	for item in original:
		total += item
	var needed: Array[float] = []
	var caption_size := 15
	var number_size := 19
	while true:
		needed.clear()
		var sum := 0.0
		for i in original.size():
			var item := icon_width + width(LegionUi.FONT_TITLE, captions[i], caption_size) \
				+ width(LegionUi.num_font(), reserves[i], number_size) + GAP + NUMBER_EDGE
			needed.append(item)
			sum += item
		if sum <= total:
			break
		if caption_size > 12:
			caption_size -= 1
		else:
			number_size -= 1
	var result: Array[float] = needed.duplicate()
	var remaining := total
	for item in result:
		remaining -= item
	# First restore the original spacious columns (army breakdown, progress bars).
	for i in original.size():
		var extra := minf(remaining, maxf(0.0, original[i] - result[i]))
		result[i] += extra
		remaining -= extra
	result[-1] += remaining
	return result


## Bounds include both outlines. Bump is limited to actual spare room.
static func header(available: float, caption: String, value: String, bump := 0.0) -> Dictionary:
	var cap_size := 15
	var num_size := 19
	while width(LegionUi.FONT_TITLE, caption, cap_size) \
			+ width(LegionUi.num_font(), value, num_size) + GAP + NUMBER_EDGE > available:
		if cap_size > 12:
			cap_size -= 1
		elif num_size > 1:
			num_size -= 1
		else:
			cap_size = maxi(1, cap_size - 1)
	var cw := width(LegionUi.FONT_TITLE, caption, cap_size)
	var nw := width(LegionUi.num_font(), value, num_size)
	var spare := maxf(0.0, available - cw - nw - GAP - NUMBER_EDGE)
	var actual_bump := minf(clampf(bump, 0.0, 1.0), spare / maxf(0.3 * nw, 1.0))
	var expansion := nw * 0.15 * actual_bump
	return {"caption_size": cap_size, "number_size": num_size, "bump": actual_bump,
		"caption_right": cw, "number_left": available - NUMBER_EDGE - nw - expansion * 2.0,
		"number_right": available - NUMBER_EDGE, "anchor": available - NUMBER_EDGE - expansion}


static func draw_header(ci: CanvasItem, at: Vector2, available: float, caption: String,
		value: String, cap_color: Color, number_color: Color, bump := 0.0) -> void:
	var layout := header(available, caption, value, bump)
	LegionUi.draw_text(ci, at + Vector2(0.0, 18.0), caption, layout.caption_size,
		cap_color, LegionUi.FONT_TITLE)
	LegionUi.draw_number(ci, at + Vector2(layout.anchor, 20.0), value, layout.number_size,
		number_color, layout.bump, true)
