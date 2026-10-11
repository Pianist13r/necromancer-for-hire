class_name LegionRecords
extends RefCounted
##
## Личная таблица рекордов (slow/records 10.10.2026, фундамент под общую таблицу игроков B-120).
## Хранение — секция RECORDS_SECTION того же legion.cfg через Campaign.raw_file()/save_raw() (тот
## же кэш ConfigFile, что у LegionRunStore/LegionCollection): запись из обработчика итога попадает
## в открытую транзакцию Campaign.begin_update()/end_update() вместе с наградой (B-442).
##
## Ключ — "<режим>/<карта>/<сложность>" (KEY_SEP). Кампания и переигровка из коллекции: лучший
## результат — победа с наибольшим HP Котла, при равенстве — меньшее время (is_better); поражения
## не пишутся. «Бесконечный подряд»/«Вызов дня» здесь не дублируются: их рекорды уже ведёт
## LegionRunStore в Campaign.ENDLESS_RECORDS_SECTION — endless_rows() только читает её.
## «Схватка» с ботом — счёт побед/поражений/ничьих по полю и уровню бота (уровня бота в коде пока
## нет — PVP_LEVEL_NONE; сетевые матчи не пишутся).
## Campaign.reset() стирает файл целиком — секция уходит вместе с ним.
##

const RECORDS_SECTION := "records"
const KEY_SEP := "/"
const MODE_CAMPAIGN := "campaign"
const MODE_COLLECTION := "collection"
const MODE_PVP := "pvp"
const PVP_DUEL := "duel"
const PVP_RANDOM := "random"
## Уровня бота «Схватки» в коде пока нет: одна строка на поле.
const PVP_LEVEL_NONE := "bot"
## Поля записи рекорда одиночного боя (date — unix-время записи).
const FIELDS: Array[String] = ["hp", "t", "wave", "lost", "kills", "seed", "date", "stars"]


static func key(mode: String, map_id: String, difficulty: String) -> String:
	return KEY_SEP.join([mode, map_id, difficulty])


## Рекорд по ключу ({} — ещё нет).
static func best(mode: String, map_id: String, difficulty: String) -> Dictionary:
	var v: Variant = Campaign.raw_file().get_value(RECORDS_SECTION,
		key(mode, map_id, LegionChallenge.valid(difficulty)), {})
	return (v as Dictionary).duplicate() if v is Dictionary else {}


## new лучше old: больше HP Котла, при равном HP — меньше время. Пустой old — любой new лучше.
static func is_better(new: Dictionary, old: Dictionary) -> bool:
	if old.is_empty():
		return true
	var hp_new := float(new.get("hp", 0.0))
	var hp_old := float(old.get("hp", 0.0))
	if not is_equal_approx(hp_new, hp_old):
		return hp_new > hp_old
	return float(new.get("t", 0.0)) < float(old.get("t", 0.0))


## Итог одиночного боя (кампания/коллекция). stats — LegionWorld.final_stats(). Пишет только
## победу лучше прежней. Возвращает {"best": рекорд после записи ({} — нет), "is_new": bool,
## "previous": прежний рекорд} — его показывает экран итога.
static func record_run(mode: String, map_id: String, victory: bool, stats: Dictionary,
		stars: int = 0, title: String = "") -> Dictionary:
	var difficulty := LegionChallenge.valid(String(stats.get("difficulty", Settings.difficulty())))
	var old := best(mode, map_id, difficulty)
	var out := {"best": old, "is_new": false, "previous": old}
	if not victory:
		return out
	var rec := {
		"hp": snappedf(float(stats.get("hp", 0.0)), 0.1), "t": snappedf(float(stats.get("t", 0.0)), 0.1),
		"wave": int(stats.get("wave", 0)), "lost": int(stats.get("lost", 0)),
		"kills": int(stats.get("kills", 0)), "seed": int(stats.get("seed", 0)),
		"date": int(Time.get_unix_time_from_system()), "stars": stars,
	}
	if title != "":
		rec["title"] = title
	if not is_better(rec, old):
		return out
	Campaign.raw_file().set_value(RECORDS_SECTION, key(mode, map_id, difficulty), rec)
	Campaign.save_raw()
	out["best"] = rec
	out["is_new"] = true
	return out


## Поле «Схватки» по id карты: готовая «Дуэль» или случайное поле процгена.
static func pvp_field(map_id: String) -> String:
	return PVP_DUEL if map_id == PvpMaps.DUEL else PVP_RANDOM


## Итог «Схватки» с ботом: verdict — "win"/"lose"/"draw". Сетевые матчи сюда не зовут.
static func record_pvp(map_id: String, verdict: String, level: String = PVP_LEVEL_NONE) -> void:
	var k := key(MODE_PVP, pvp_field(map_id), level)
	var tally := pvp_tally(pvp_field(map_id), level)
	var field := {"win": "wins", "lose": "losses", "draw": "draws"}.get(verdict, "") as String
	if field == "":
		return
	tally[field] = int(tally[field]) + 1
	Campaign.raw_file().set_value(RECORDS_SECTION, k, tally)
	Campaign.save_raw()


static func pvp_tally(field: String, level: String = PVP_LEVEL_NONE) -> Dictionary:
	var v: Variant = Campaign.raw_file().get_value(RECORDS_SECTION,
		key(MODE_PVP, field, level), {})
	var d: Dictionary = v if v is Dictionary else {}
	return {"wins": int(d.get("wins", 0)), "losses": int(d.get("losses", 0)),
		"draws": int(d.get("draws", 0))}


## Исход «Схватки» от лица стороны local_side по итогу мира (final_stats). Принудительный конец без
## решённого PvpMatch (winner −2) — по флагу победы.
static func pvp_verdict(victory: bool, stats: Dictionary, local_side: int = 0) -> String:
	var pvp: Dictionary = stats.get("pvp", {})
	var winner := int(pvp.get("winner", -2))
	if winner == -1 or String(stats.get("result", "")) == "draw":
		return "draw"
	if winner >= 0:
		return "win" if winner == local_side else "lose"
	return "win" if victory else "lose"


## Все рекорды одиночных боёв режима mode: [{map, difficulty, ...поля рекорда}].
static func rows(mode: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var f := Campaign.raw_file()
	if not f.has_section(RECORDS_SECTION):
		return out
	for k: String in f.get_section_keys(RECORDS_SECTION):
		var parts := k.split(KEY_SEP)
		if parts.size() != 3 or parts[0] != mode:
			continue
		var v: Variant = f.get_value(RECORDS_SECTION, k, {})
		if not v is Dictionary:
			continue
		var row := (v as Dictionary).duplicate()
		row["map"] = parts[1]
		row["difficulty"] = parts[2]
		out.append(row)
	return out


## Рекорды «Подряда» (daily = false) или лучший «Вызов дня» по сложности (daily = true) из
## Campaign.ENDLESS_RECORDS_SECTION: {сложность: {tenure, souls[, date]}}; нет записи — нет ключа.
## «Вызов дня» хранит рекорд на каждую дату — берём дату с наибольшим стажем (при равном — душами).
static func endless_rows(daily: bool) -> Dictionary:
	var out := {}
	var f := Campaign.raw_file()
	var rs := Campaign.ENDLESS_RECORDS_SECTION
	if not daily:
		for d: String in LegionChallenge.ORDER:
			var tenure := LegionRunStore.endless_best_tenure("", d)
			var souls := LegionRunStore.endless_best_souls("", d)
			if tenure > 0 or souls > 0:
				out[d] = {"tenure": tenure, "souls": souls}
		return out
	if not f.has_section(rs):
		return out
	for k: String in f.get_section_keys(rs):
		if not k.begins_with("daily_") or not k.ends_with("_tenure"):
			continue
		var stem := k.trim_prefix("daily_").trim_suffix("_tenure")
		var cut := stem.rfind("_")
		if cut < 0:
			continue
		var d := stem.substr(cut + 1)
		var day_key := stem.substr(0, cut)
		var row := {"tenure": int(f.get_value(rs, k, 0)),
			"souls": int(f.get_value(rs, "daily_%s_%s_souls" % [day_key, d], 0)),
			"date": day_key.get_slice("|", 0)}
		var cur: Dictionary = out.get(d, {})
		if cur.is_empty() or int(row["tenure"]) > int(cur["tenure"]) \
				or (int(row["tenure"]) == int(cur["tenure"]) and int(row["souls"]) > int(cur["souls"])):
			out[d] = row
	return out


## «3:07» — минуты:секунды.
static func clock(t: float) -> String:
	var s := maxi(0, int(t))
	return "%d:%02d" % [s / 60, s % 60]


## «HP 180 · 3:07» — короткая подпись рекорда ("" — рекорда нет).
static func short_text(rec: Dictionary) -> String:
	if rec.is_empty():
		return ""
	return "HP %d · %s" % [int(float(rec.get("hp", 0.0))), clock(float(rec.get("t", 0.0)))]
