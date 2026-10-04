class_name LegionRunStore
extends RefCounted
##
## D-0927-96/-162 (mode line): бухгалтерия «Бесконечного подряда»/«Вызова дня» — номер объекта,
## сид, стаж/души, закреплённая сложность «Вызова дня», рекорды по сложности, «одна попытка в
## день». Свой файл ради max-file-lines кампании (тот же приём, что LegionCollection) — хранение
## через Campaign.raw_file()/save_raw() (тот же кэш ConfigFile, что весь остальной Campaign);
## сам scope (use_endless_scope() и т.п.) остаётся в Campaign — им пользуется весь Campaign
## (bounty/shop/upgrades), не только этот файл.
##

## D-0927-121: «бой дня открыт» — ставится в сохранение СРАЗУ при старте боя «Вызова дня»,
## снимается только честным концом боя (endless_object_won/endless_end_run). Флаг, переживший бой
## (закрыли окно, игра упала, увели в обучение), значит самовольный уход — попытка засчитывается
## оконченной (settle_abandoned_daily).
const OPEN_KEY := "open_object"
const OPEN_TITLE_KEY := "open_title"
const OPEN_AT_KEY := "open_at"
## D-0927-122: словарь «дата → итог» сданных попыток «Вызова дня» (секция DAILY_SECTION).
const DONE_KEY := "done_dates"

# ── mode: «Бесконечный подряд» / «Вызов дня» (BOOK §1, §2; docs/procgen/STAGE2.md, линия mode) ──
## Кампания пройдена — последняя по order карта хотя бы раз выиграна (открывает «Бесконечный
## подряд»/«Вызов дня», BOOK §13). Пустой список карт — не пройдена.
static func campaign_completed() -> bool:
	var all := Campaign.maps()
	if all.is_empty():
		return false
	return Campaign.stars(String(all[all.size() - 1].get("id", ""))) > 0


## Забег идёт (k ≥ 1) — «Продолжить забег»/«Продолжить „Вызов дня"» в меню. k == 0 — забега нет.
## daily — какой из двух смотрим (РАЗНЫЕ секции); getter'ы не трогают текущий scope.
static func endless_active(daily: bool = false) -> bool:
	return endless_k(daily) > 0


static func endless_k(daily: bool = false) -> int:
	return int(Campaign.raw_file().get_value(Campaign._run_section_for(daily), "k", 0))


static func endless_seed(daily: bool = false) -> int:
	return int(Campaign.raw_file().get_value(Campaign._run_section_for(daily), "seed", 0))


## Дата (ГГГГ-ММ-ДД) «Вызова дня»; "" — ещё не начинался. Только Campaign.DAILY_SECTION.
static func endless_daily_date() -> String:
	return String(Campaign.raw_file().get_value(Campaign.DAILY_SECTION, "daily_date", ""))


## Стаж этого забега — число уже СДАННЫХ объектов (счёт БЕЗ текущего, ещё не пройденного k).
static func endless_tenure(daily: bool = false) -> int:
	return int(Campaign.raw_file().get_value(Campaign._run_section_for(daily), "tenure", 0))


## Души, накопленные за этот забег (вторичный счёт, BOOK §1).
static func endless_souls(daily: bool = false) -> int:
	return int(Campaign.raw_file().get_value(Campaign._run_section_for(daily), "souls", 0))


## Новый забег: сбрасывает объект 1, стаж/души/поправки/«Контору» ЗАБЕГА — прогресс кампании не
## трогает. Сложность «Вызова дня» НЕ фиксируется тут (D-0927-96, пикер ещё живой) — "" (не
## закреплена), закрепляет lock_daily_difficulty() при старте боя первого объекта.
static func endless_start(run_seed: int, daily_date: String = "") -> void:
	var sec := Campaign._run_section()
	var f := Campaign.raw_file()
	f.set_value(sec, "k", 1)
	f.set_value(sec, "seed", run_seed)
	f.set_value(sec, "tenure", 0)
	f.set_value(sec, "souls", 0)
	# D-0927-120: сложность не закреплена у ОБОИХ забегов до старта первого боя (пикер брифинга
	# объекта 1 ещё живой) — закрепляет lock_difficulty() в LegionMain._start_endless_battle().
	f.set_value(sec, "difficulty", "")
	if Campaign._scope == "daily":
		f.set_value(sec, "daily_date", daily_date)
	_reset_run_meta(sec)


## Поправки/«Контора»/премия/награда — с нуля. Общее для endless_start() и reset_replay_scratch()
## (D-0927-162): у песочницы переигровки просто нет k/tenure/souls, их не трогаем.
static func _reset_run_meta(sec: String) -> void:
	var f := Campaign.raw_file()
	f.set_value(sec, "upgrades", [])
	# артефакты забега (D-0927-163) — новый забег/чистая песочница переигровки начинает без них
	# (в ветке items-v2 строка была в Campaign.endless_start; после mode сброс мета живёт тут)
	f.set_value(sec, CfgItems.SAVE_KEY, [])
	f.set_value(sec, "bounty", 0)
	f.set_value(sec, "pending_reward", "")
	for id in LegionMetaCfg.OFFICE_SHOP_ORDER:
		f.set_value(sec, "shop_%s" % id, 0)
		if bool(LegionMetaCfg.OFFICE_SHOP[id].get("per_kind", false)):
			for kind: StringName in LegionCfg.KIND_ORDER:
				f.set_value(sec, "shop_%s_%s" % [id, String(kind)], 0)
	Campaign.save_raw()


## Звать перед КАЖДОЙ переигровкой из коллекции (use_replay_scope() уже поставлен).
static func reset_replay_scratch() -> void:
	_reset_run_meta(Campaign.REPLAY_SECTION)


## D-0927-96/-120: сложность забега (daily — «Вызова дня», иначе «Бесконечного подряда»),
## закреплённая на весь забег при старте его первого боя — "" пока не закреплена. Рекорд пишется
## под неё, а не под живой Settings.difficulty(): иначе середину забега проходили бы на «Стажёре»,
## а рекорд записывался бы на «Аду» (verifier, проба A6).
static func run_difficulty(daily: bool) -> String:
	return String(Campaign.raw_file().get_value(Campaign._run_section_for(daily), "difficulty", ""))


static func is_difficulty_locked(daily: bool) -> bool:
	return run_difficulty(daily) != ""


## Закрепляет сложность один раз за забег — повторные вызовы (объекты 2, 3…) no-op.
static func lock_difficulty(daily: bool, d: String) -> void:
	if not is_difficulty_locked(daily):
		Campaign.raw_file().set_value(Campaign._run_section_for(daily), "difficulty",
			LegionChallenge.valid(d))
		Campaign.save_raw()


static func daily_difficulty() -> String:
	return run_difficulty(true)


static func is_daily_difficulty_locked() -> bool:
	return is_difficulty_locked(true)


static func lock_daily_difficulty(d: String) -> void:
	lock_difficulty(true, d)


## Объект k сдан (Котёл выстоял): стаж +1, души забега — прибавка, следующий объект — k+1.
## Секция ТЕКУЩЕГО scope.
static func endless_object_won(souls_gained: int) -> void:
	var sec := Campaign._run_section()
	var f := Campaign.raw_file()
	f.set_value(sec, "tenure", endless_tenure(Campaign._scope == "daily") + 1)
	f.set_value(sec, "souls", endless_souls(Campaign._scope == "daily") + maxi(0, souls_gained))
	f.set_value(sec, "k", endless_k(Campaign._scope == "daily") + 1)
	if Campaign._scope == "daily":
		f.set_value(Campaign.DAILY_SECTION, OPEN_KEY, "")   # бой кончился честно — не «уход»
	Campaign.save_raw()


## Ключ рекорда: своя пара «стаж/души» на сложность (D-0927-96), «Вызов дня» — ещё и на дату.
## Старые ключи без сложности молча перестают читаться (пре-релизные цифры, не переносим).
static func _record_key(daily: bool, daily_date: String, difficulty: String) -> String:
	var d := LegionChallenge.valid(difficulty)
	if daily:
		return "daily_%s_%s" % [daily_date, d]
	return "endless_%s" % d


## Забег кончился: рекорды по стажу/душам и ПО СЛОЖНОСТИ (D-0927-96), k → 0; «Вызов дня» ещё
## закрывает СЕГОДНЯШНИЙ ДЕНЬ целиком (одна попытка, новая — только завтра).
static func endless_end_run() -> Dictionary:
	var daily := Campaign._scope == "daily"
	var sec := Campaign._run_section()
	var tenure := endless_tenure(daily)
	var souls := endless_souls(daily)
	var daily_date := endless_daily_date() if daily else ""
	# Закреплённая сложность забега (D-0927-120 — у обоих видов); не закреплена только у забега,
	# кончившегося без единого боя (юнит-проверки, стаб-кадры) — тогда живой выбор игрока.
	var difficulty := run_difficulty(daily) if is_difficulty_locked(daily) else Settings.difficulty()
	var rec_key := _record_key(daily, daily_date, difficulty)
	var rf := Campaign.raw_file()
	var rs := Campaign.ENDLESS_RECORDS_SECTION
	var best_tenure := int(rf.get_value(rs, "%s_tenure" % rec_key, 0))
	var best_souls := int(rf.get_value(rs, "%s_souls" % rec_key, 0))
	var new_tenure := tenure > best_tenure
	var new_souls := souls > best_souls
	if new_tenure:
		rf.set_value(rs, "%s_tenure" % rec_key, tenure)
	if new_souls:
		rf.set_value(rs, "%s_souls" % rec_key, souls)
	rf.set_value(sec, "k", 0)
	if daily:
		# D-0927-122: множество сданных дат, а не одна done_date — одна попытка на дату НАВСЕГДА
		# (verifier, проба A3: сыграл «завтра», вернул дату — «сегодня» снова открывалось).
		var done := _done_dates()
		done[daily_date] = {"tenure": tenure, "souls": souls, "difficulty": difficulty}
		rf.set_value(Campaign.DAILY_SECTION, DONE_KEY, done)
		rf.set_value(Campaign.DAILY_SECTION, OPEN_KEY, "")
	Campaign.save_raw()
	return {
		"tenure": tenure, "souls": souls,
		"tenure_record": maxi(tenure, best_tenure), "souls_record": maxi(souls, best_souls),
		"is_new_tenure_record": new_tenure, "is_new_souls_record": new_souls,
		"daily": daily, "daily_date": daily_date, "difficulty": difficulty,
	}


static func endless_best_tenure(daily_date: String = "", difficulty: String = "") -> int:
	var rec_key := _record_key(daily_date != "", daily_date, difficulty)
	var v: Variant = Campaign.raw_file().get_value(Campaign.ENDLESS_RECORDS_SECTION,
		"%s_tenure" % rec_key, 0)
	return int(v)


static func endless_best_souls(daily_date: String = "", difficulty: String = "") -> int:
	var rec_key := _record_key(daily_date != "", daily_date, difficulty)
	var v: Variant = Campaign.raw_file().get_value(Campaign.ENDLESS_RECORDS_SECTION,
		"%s_souls" % rec_key, 0)
	return int(v)


## D-0927-96: true — на эту дату попытка уже сыграна до конца, кнопка в меню закрыта до завтра.
## Не путать с endless_active(true) — «попытка ЕЩЁ ИДЁТ»; тут — «уже кончилась сегодня».
static func daily_attempt_done(date: String) -> bool:
	return _done_dates().has(date)


## Итог попытки на дату date — для подписи закрытой кнопки в меню ({} — не сдавалась).
static func daily_done_result(date: String) -> Dictionary:
	return _done_dates().get(date, {})


static func _done_dates() -> Dictionary:
	var v: Variant = Campaign.raw_file().get_value(Campaign.DAILY_SECTION, DONE_KEY, {})
	return (v as Dictionary).duplicate() if v is Dictionary else {}


## D-0927-122: вход в «Вызов дня» на дату date (scope — daily, ставит вызывающий). Забег другой
## даты, оставшийся незаконченным (игрок перевёл часы или вышел между объектами до полуночи), —
## закрывается как сданный на СВОЮ дату, а не молча затирается новым: иначе, вернув дату, его
## день снова был бы «не сыгран». false — на date попытка уже была, новой не будет.
static func daily_enter(date: String) -> bool:
	if endless_active(true) and endless_daily_date() != date:
		endless_end_run()
	if endless_active(true):
		return true
	if daily_attempt_done(date):
		return false
	endless_start(LegionEndless.daily_seed(date), date)
	return true


# ── D-0927-121: «бой дня открыт» — окно/игра закрылись посреди объекта (ключи — в начале файла) ─
static func daily_open_mark(map_id: String, title: String) -> void:
	var f := Campaign.raw_file()
	f.set_value(Campaign.DAILY_SECTION, OPEN_KEY, map_id)
	f.set_value(Campaign.DAILY_SECTION, OPEN_TITLE_KEY, title)
	f.set_value(Campaign.DAILY_SECTION, OPEN_AT_KEY, int(Time.get_unix_time_from_system()))
	Campaign.save_raw()


static func daily_open_object() -> String:
	return String(Campaign.raw_file().get_value(Campaign.DAILY_SECTION, OPEN_KEY, ""))


## Бой дня открыт, но кончился не концом боя — закрыть попытку как самовольный уход: рекорд по
## стажу ДО этого объекта (он не сдан), дата — в сданные. {} — открытого боя не было. Оставляет
## scope кампании: зовут из меню/старта другого боя/закрытия окна — каждый ставит свой scope сам.
static func settle_abandoned_daily() -> Dictionary:
	if daily_open_object() == "" or not endless_active(true):
		Campaign.raw_file().set_value(Campaign.DAILY_SECTION, OPEN_KEY, "")
		return {}
	var title := String(Campaign.raw_file().get_value(Campaign.DAILY_SECTION, OPEN_TITLE_KEY, ""))
	Campaign.use_daily_scope()
	var report := endless_end_run()
	Campaign.use_campaign_scope()
	report["map_title"] = title
	report["abandoned"] = true
	return report

