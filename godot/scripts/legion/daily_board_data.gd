class_name DailyBoardData
extends RefCounted
## Общая таблица читает законченные попытки, не меняя кампанию и личные рекорды.
## Квитанция хранится отдельно: после потери ответа повторяет тот же token и payload.

const OUTBOX := "user://daily_board.cfg"


static func key(date: String, difficulty: String) -> Dictionary:
	return {"version": ProcGen.VERSION, "date": date,
		"seed": LegionEndless.daily_seed(date), "difficulty": difficulty}


static func key_id(board: Dictionary) -> String:
	return "%s|v%d|%d|%s" % [board["date"], board["version"], board["seed"], board["difficulty"]]


static func dates() -> Array[String]:
	var out: Array[String] = [LegionEndless.today_date()]
	var done: Variant = Campaign.raw_file().get_value(
		Campaign.DAILY_SECTION, LegionRunStore.DONE_KEY, {})
	if done is Dictionary:
		for id: String in done:
			var date := id.get_slice("|", 0)
			if id == LegionRunStore.daily_key(date) and not date in out and _valid_date(date):
				out.append(date)
	out.sort()
	out.reverse()
	return out


static func _valid_date(date: String) -> bool:
	var regex := RegEx.new()
	regex.compile("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
	return regex.search(date) != null


static func result(board: Dictionary) -> Dictionary:
	if int(board.get("version", 0)) != ProcGen.VERSION:
		return {}
	var date := String(board.get("date", ""))
	if int(board.get("seed", -1)) != LegionEndless.daily_seed(date):
		return {}
	var done: Variant = Campaign.raw_file().get_value(
		Campaign.DAILY_SECTION, LegionRunStore.DONE_KEY, {})
	if not done is Dictionary:
		return {}
	var row: Variant = done.get(LegionRunStore.daily_key(date), {})
	if not row is Dictionary or row.get("difficulty", "") != board.get("difficulty", ""):
		return {}
	for field: String in ["tenure", "souls"]:
		if not row.get(field) is int or int(row[field]) < 0:
			return {}
	return {"tenure": int(row["tenure"]), "souls": int(row["souls"])}


## Только явное нажатие отправки создаёт квитанцию; чтение таблицы ничего не пишет.
static func submission(board: Dictionary, path: String = OUTBOX) -> Dictionary:
	var own := result(board)
	if own.is_empty():
		return {}
	var cfg := SafeConfig.load_file(path)
	var id := key_id(board)
	var saved: Variant = cfg.get_value("pending", id, {})
	if saved is Dictionary and not saved.is_empty():
		var token: Variant = saved.get("token")
		if not token is String or token.length() != 64 or not token.is_valid_hex_number(false):
			return {}
		var expected := board.duplicate()
		expected.merge(own)
		expected.merge({"schema": 1, "token": token})
		return saved.duplicate(true) if saved == expected else {}
	var payload := board.duplicate()
	payload.merge(own)
	payload["schema"] = 1
	payload["token"] = Crypto.new().generate_random_bytes(32).hex_encode()
	cfg.set_value("pending", id, payload)
	if SafeConfig.save_file(cfg, path) != OK:
		return {}
	return payload
