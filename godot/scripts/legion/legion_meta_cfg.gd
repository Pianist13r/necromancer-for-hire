class_name LegionMetaCfg
extends RefCounted
##
## Пороги разряда, звёзд и формулы наград. Колода — AmendmentDb.
## Исторические цены нужны только миграции RunProgression; в бою не действуют.
##

# ── Звёзды за карту, по доле HP Котла на конец боя (только при победе) ───────
## ≥ STAR3_RATIO — 3★, ≥ STAR2_RATIO — 2★, любая победа — минимум 1★, поражение — 0.
const STAR3_RATIO := 0.8
const STAR2_RATIO := 0.4

# ── Герой: опыт и разряд (DESIGN_V15 §6; переработка 06.10.2026) ───────────────────────────────
## Пороги — НАКОПЛЕННЫЙ опыт, нужный для разряда N (индекс 0 → разряд 2, ..., индекс 8 →
## разряд 10). Разряд 1 — старт; каждый пройденный порог открывает карточку колоды.
const HERO_LEVEL_THRESHOLDS: Array[int] = [100, 250, 450, 700, 1000, 1400, 1900, 2500, 3200]
const HERO_MAX_LEVEL := 10
## Ранги способностей и перки героя удалены в переработке 06.10.2026 (D-1006-11): покупку не
## предлагал ни один экран с 05.10, а в бой они не шли (читались через мёртвый _hero_mods).
## Разряд (HERO_LEVEL_THRESHOLDS выше) остался — он открывает варианты колоды поправок.


## Число звёзд по доле HP Котла на конец боя; вызывать только при победе (иначе 0 — Campaign
## сам не пускает сюда поражение).
static func stars_for_ratio(ratio: float) -> int:
	if ratio >= STAR3_RATIO:
		return 3
	if ratio >= STAR2_RATIO:
		return 2
	return 1


## За победу: 30 + 15×звёзды; за поражение: 10 + убийства/10 (целочисленно). Опыт героя:
## убийства + (50 + 20×звёзды при победе, иначе 0). kills — kills_rewardable статистики боя
## (пакет staff), если ключа ещё нет — обычный kills (задание meta, п.1 и п.3).
static func bounty_for_result(victory: bool, stars: int, kills: int) -> int:
	if victory:
		return 30 + 15 * stars
	return 10 + int(kills / 10.0)


static func hero_xp_for_result(victory: bool, stars: int, kills: int) -> int:
	return kills + (50 + 20 * stars if victory else 0)


## Один расчёт для сохранения и анимации промежуточных значений опыта.
static func rank_progress(xp: int) -> Dictionary:
	var level := 1
	var previous := 0
	for threshold in HERO_LEVEL_THRESHOLDS:
		if xp < threshold:
			return {"level": level, "cur": maxi(0, xp - previous),
				"need": threshold - previous, "maxed": false}
		previous = threshold
		level += 1
	return {"level": HERO_MAX_LEVEL, "cur": 0, "need": 0, "maxed": true}
