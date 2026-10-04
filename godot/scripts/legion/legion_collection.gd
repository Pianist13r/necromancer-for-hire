class_name LegionCollection
extends RefCounted
##
## D-0927-162 (Игорь): коллекция сохранённых карт (сидов) процгена — сохранить во время боя
## (главное место, «если проигрываешь или тебе надо бежать») или на итоге объекта, переиграть
## позже вне забега/дня. Хранение — тот же ConfigFile, что весь Campaign (raw_file()/save_raw() —
## свой файл ради max-file-lines кампании, как и LegionRunStore), секция Campaign.
## COLLECTION_SECTION, не scope-зависима (одна коллекция на профиль, откуда бы карту ни сохранили).
##
## Запись: {"map_id","version","title","biome","archetype","difficulty","source"
## ("endless"/"daily"),"saved_date","best_result":{"victory","hp_ratio","kills"}}.
##


static func entries() -> Array[Dictionary]:
	var raw: Array = Campaign.raw_file().get_value(Campaign.COLLECTION_SECTION, "entries", [])
	var out: Array[Dictionary] = []
	for e in raw:
		if e is Dictionary:
			out.append(e)
	return out


static func has(map_id: String) -> bool:
	for e in entries():
		if String(e.get("map_id", "")) == map_id:
			return true
	return false


## Сохраняет новую запись или обновляет существующую по тому же map_id (не дублирует — повторное
## сохранение той же карты просто освежает метаданные); лучший результат переигровки — максимум
## старого и нового (обычно {} у нового, если карту ещё не переигрывали). Предел
## LegionCfg.COLLECTION_LIMIT — переполнение вытесняет САМУЮ СТАРУЮ запись (FIFO).
static func save(entry: Dictionary) -> void:
	var map_id := String(entry.get("map_id", ""))
	if map_id == "":
		return
	var list := entries()
	for i in list.size():
		if String(list[i].get("map_id", "")) == map_id:
			entry["best_result"] = _merge_best(list[i].get("best_result", {}),
				entry.get("best_result", {}))
			list[i] = entry
			Campaign.raw_file().set_value(Campaign.COLLECTION_SECTION, "entries", list)
			Campaign.save_raw()
			return
	list.append(entry)
	if list.size() > LegionCfg.COLLECTION_LIMIT:
		list.pop_front()
	Campaign.raw_file().set_value(Campaign.COLLECTION_SECTION, "entries", list)
	Campaign.save_raw()


static func remove(map_id: String) -> void:
	var list := entries()
	for i in list.size():
		if String(list[i].get("map_id", "")) == map_id:
			list.remove_at(i)
			Campaign.raw_file().set_value(Campaign.COLLECTION_SECTION, "entries", list)
			Campaign.save_raw()
			return


## Переигровка из коллекции закончилась — обновляет ТОЛЬКО "best_result" (максимум с прежним),
## сама карта уже сохранена раньше. Не-op, если карту убрали между стартом и концом боя.
static func record_replay(map_id: String, result: Dictionary) -> void:
	var list := entries()
	for i in list.size():
		if String(list[i].get("map_id", "")) == map_id:
			list[i]["best_result"] = _merge_best(list[i].get("best_result", {}), result)
			Campaign.raw_file().set_value(Campaign.COLLECTION_SECTION, "entries", list)
			Campaign.save_raw()
			return


## «Лучше» — победа лучше поражения, среди одинакового исхода — больше доли HP Котла на конец.
## Простая эвристика для одной кнопки «лучший результат», не точная шкала.
static func _merge_best(old: Dictionary, new: Dictionary) -> Dictionary:
	if old.is_empty():
		return new
	if new.is_empty():
		return old
	return new if _score(new) > _score(old) else old


static func _score(r: Dictionary) -> float:
	return (1000.0 if bool(r.get("victory", false)) else 0.0) + float(r.get("hp_ratio", 0.0)) * 100.0


## VERSION генератора записи не совпадает с текущей — карта могла бы выглядеть иначе, помечаем
## «старая версия генератора», но НЕ мешаем играть (генератор детерминирован в своей версии —
## карта та же, что была). TODO координатору после слияния layout: ProcGen.VERSION вместо
## LegionEndless.STUB_VERSION (тот же TODO, что у daily_seed()).
static func entry_stale(entry: Dictionary) -> bool:
	return int(entry.get("version", -1)) != LegionEndless.STUB_VERSION
