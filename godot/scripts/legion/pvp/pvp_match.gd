class_name PvpMatch
extends RefCounted
##
## Конец матча «Схватки» (docs/pvp/DESIGN.md §2.7): Котёл стороны ≤ 0 — она проиграла, оба в
## одном шаге — ничья; предел MATCH_LIMIT — больший процент HP Котла, разница меньше DRAW_MARGIN
## — ничья; сдача засчитывается сразу. Мир спрашивает check() в конце шага; итог — словарь
## {winner: сторона или -1 (ничья), reason: cauldron|limit|surrender|draw}.
##
## Отдельно от мира: правила конца матча — одно место, их же зовёт будущий сервер (L3) и тест.
##

const REASON_CAULDRON := "cauldron"
const REASON_LIMIT := "limit"
const REASON_SURRENDER := "surrender"
const REASON_DRAW := "draw"

var limit := PvpRules.MATCH_LIMIT
var result: Dictionary = {}


func _init(match_limit: float = PvpRules.MATCH_LIMIT) -> void:
	limit = match_limit


## Итог на момент now по сторонам sides; {} — матч идёт. Один раз решённый итог не меняется.
func check(sides: Array[PvpSide], now: float) -> Dictionary:
	if not result.is_empty():
		return result
	var standing: Array[int] = []
	var gave_up := false
	for s in sides:
		gave_up = gave_up or s.surrendered
		if s.alive():
			standing.append(s.index)
	if standing.size() == 1:
		result = {"winner": standing[0],
			"reason": REASON_SURRENDER if gave_up else REASON_CAULDRON}
	elif standing.is_empty():
		result = {"winner": -1, "reason": REASON_DRAW}
	elif now >= limit:
		result = _by_hp(sides)
	return result


## Предел времени: у кого больше доля HP Котла; ближе DRAW_MARGIN к лучшему — ничья.
func _by_hp(sides: Array[PvpSide]) -> Dictionary:
	var best := -1
	var best_k := -1.0
	var second_k := -1.0
	for s in sides:
		var k := s.hp_frac()
		if k > best_k:
			second_k = best_k
			best_k = k
			best = s.index
		elif k > second_k:
			second_k = k
	if best_k - second_k < PvpRules.DRAW_MARGIN:
		return {"winner": -1, "reason": REASON_LIMIT}
	return {"winner": best, "reason": REASON_LIMIT}
