class_name Campaign
extends RefCounted
##
## Прогресс кампании «По истечении договора»: карты, звёзды, открытые поправки к договору.
## Хранение — `user://legion.cfg` (ConfigFile), паттерн повторяет `scripts/game/records.gd`.
## Список карт читает `res://assets/legion/maps/*.json` (владелец файлов — пакет MAPS, его
## тут нет и может не быть ещё несколько сессий) — при пустом каталоге подставляет 6 заглушек
## из CONCEPT.md, чтобы экраны кампании были играбельны сами по себе.
##

const PATH := "user://legion.cfg"
## Сохранение прогонов мира без кампании (гейт, бот, demo.bat, --bench/--shot): туда, а не
## в прогресс владельца, пишутся разовые подсказки и прочее (LegionWorld.use_standalone_save).
const STANDALONE_PATH := "user://legion_standalone.cfg"
const MAPS_DIR := "res://assets/legion/maps/"
## mode: секции забегов ХРАНЯТСЯ РАЗДЕЛЬНО (verifier 27.09: общая секция стирала прогресс
## другого) — номер объекта, сид, стаж/души и, в scope, ключи "meta".
const ENDLESS_SECTION := "endless_run"
const DAILY_SECTION := "daily_run"
## Рекорды по стажу/душам — отдельно от самих забегов, переживают endless_start()/endless_end_run().
const ENDLESS_RECORDS_SECTION := "endless_records"
## D-0927-162: песочница переигровки из коллекции — чистит reset_replay_scratch() перед разом.
const REPLAY_SECTION := "collection_replay"
## D-0927-162: коллекция сохранённых карт — список Dictionary под ключом "entries".
const COLLECTION_SECTION := "collection"

## Заглушки на случай пустого/отсутствующего каталога карт (docs/CONCEPT.md, раздел «Карты»).
## Каждая — минимальный набор полей, которые читают экраны этого пакета (briefing, map_select).
const FALLBACK_MAPS: Array[Dictionary] = [
	{
		"id": "wasteland", "order": 0, "title": "Пустырь",
		"subtitle": "Первый заказ — не облажайся", "theme": "ash",
		"hint": "Одна дорога. Поставь строй, дай натиску сделать остальное.",
		"waves": [{"groups": [{"type": "zombie"}]}],
	},
	{
		"id": "fork", "order": 1, "title": "Развилка",
		"subtitle": "Две дороги — один Котёл", "theme": "grave",
		"hint": "Держи фланг, который тише, отпускай тот, что громче.",
		"waves": [{"groups": [{"type": "zombie"}, {"type": "beetle"}]}],
	},
	{
		"id": "bridge", "order": 2, "title": "Мост через Стикс",
		"subtitle": "Нотариусы заверяют всё, что видят", "theme": "swamp",
		"hint": "Строй держит мост. Отпусти крыло на нотариусов.",
		"waves": [{"groups": [{"type": "zombie"}, {"type": "signer"}]}],
	},
	{
		"id": "graveyard_maze", "order": 3, "title": "Кладбищенский лабиринт",
		"subtitle": "Призраки проходят сквозь любой договор", "theme": "grave",
		"hint": "Три подхода. Свободные бойцы ловят призраков, строй — нет.",
		"waves": [{"groups": [{"type": "ghost"}, {"type": "zombie"}]}],
	},
	{
		"id": "swamp_reports", "order": 4, "title": "Болото отчётности",
		"subtitle": "Надгробия спят, пока рядом тихо", "theme": "swamp",
		"hint": "Возьми склепы — они сами подкидывают людей. Не буди мимиков зря.",
		"waves": [{"groups": [{"type": "mimic"}, {"type": "beetle"}]}],
	},
	{
		"id": "foreman", "order": 5, "title": "Прораб",
		"subtitle": "Финальная сдача объекта", "theme": "office",
		"hint": "Босс таранит строй. Держи резерв на натиск позади разрыва.",
		"waves": [{"groups": [{"type": "boss"}]}],
	},
]

## Что открылось и ещё не показано игроку — для плашки «Новое: …» на брифинге (задание meta
## п.4). gdlint (class-definitions-order) требует все const класса ДО var и ДО методов —
## объявление здесь, а не рядом с pending_unlock_labels()/mark_unlocks_seen(), которые его
## используют.
const _UNLOCK_LABELS := {
	"kind_guard": ["kind_unlocked_guard", "Новый вид бойца: Вахтёр"],
	"kind_clerk": ["kind_unlocked_clerk", "Новый вид бойца: Счетовод"],
	"aim": ["control_unlocked_aim", "Стрелка отряда: Пробел или зажатое колесо"],
	"rally": ["control_unlocked_rally", "«Сбор»: Эр (R)"],
	"ring": ["shape_unlocked_ring", "Фигура «Оцепление»: кольцо"],
	"hero_w": ["ability_unlocked_w", "Навык Дубль-вэ: трупы встают за тебя"],
	"hero_e": ["ability_unlocked_e", "Навык Е «Аврал»: строй держит давку"],
	"eight": ["shape_unlocked_eight", "Фигура «Двойная смена»: восьмёрка"],
	"items": ["loot_unlocked_items", "Элитные проверяющие и предметы"],
	# D-1002-03: звезду сменил треугольник. Старый id "star" в meta/unlocks_seen просто не читается
	# (его нет в таблице) — игрок, видевший звезду, узнает про треугольник плашкой «Новое»
	"triangle": ["shape_unlocked_triangle", "Фигура «Обряд»: треугольник"],
	"square": ["shape_unlocked_square", "Фигура «Каре»: квадрат"],
	# D-1002 §4: «Комиссия по упокоению» (пятиугольник) — «Лабиринт», «Неустойка» (полукруг) —
	# «Болото». Открываются их же уроками.
	"pentagon": ["shape_unlocked_pentagon", "Фигура «Комиссия по упокоению»: пятиугольник"],
	"d_shape": ["shape_unlocked_d_shape", "Фигура «Неустойка»: полукруг"],
}
## Сохранение старше v20 (D-0927-50): эти открытия игрок уже имел до лестницы v20 — плашка
## «Новое» о них не выскакивает пачкой при первом входе (они и так в руках). Новое для всех —
## восьмёрка, треугольник, квадрат, предметы — объявляется как обычно.
const _PRE_V20_KNOWN := ["kind_guard", "kind_clerk", "hero_w", "hero_e", "aim", "rally", "ring"]

static var _cfg: ConfigFile = null
static var _path := PATH
## meta: кэш _all_mods() — статические переменные класса должны идти одним блоком до методов
## (gdlint), поэтому объявление здесь, а не рядом со stat().
static var _mods_cache: Dictionary = {}
static var _mods_cache_valid := false
## mode: "campaign"/"endless"/"daily" — bounty()/shop_*/upgrades()/pending_reward() читают и
## пишут "meta"/ENDLESS_SECTION/DAILY_SECTION (поправки и «Контора» — В ЗАБЕГЕ). Каждый бой ставит
## scope СЕБЕ САМ при старте, не наследует от предыдущего (verifier 27.09). Герой/открытия —
## секции "hero"/"progress", scope не знают.
static var _scope := "campaign"
static var _update_depth := 0
static var _update_before := ""
static var _update_dirty := false
static var _maps_cache: Array[Dictionary] = []
static var _maps_by_id: Dictionary = {}


## Тест меняет путь на временный файл (не трогать реальный прогресс владельца). Сбрасывает
## закэшированный ConfigFile, чтобы следующее чтение открыло новый путь.
static func set_save_path(path: String) -> void:
	_path = path
	_cfg = null
	_mods_cache_valid = false
	_update_depth = 0
	_update_dirty = false
	RunProgression.clear_stage()


## true — путь указывает на настоящее сохранение владельца при любом написании (регистр, «./»,
## абсолютный путь к тому же файлу): --dev save не должен сбрасывать его (verifier 180f1168).
static func is_real_save_path(path: String) -> bool:
	var a := ProjectSettings.globalize_path(path.strip_edges()).simplify_path().to_lower()
	var b := ProjectSettings.globalize_path(PATH).simplify_path().to_lower()
	return a == b


## true — путь годится для --dev save: только простое имя в user:// (буквы, цифры, _ и -) с .cfg,
## не legion, не settings, не legion_standalone и не net. Белый список, а не сравнение с
## настоящим путём: NTFS-потоки («::$DATA»), префикс «\\?\», короткие имена 8.3 и точки
## соединения обходили сравнение строк
## и стирали настоящее сохранение (verifier 180f1168, второй круг).
static func is_safe_dev_save(path: String) -> bool:
	var p := path.strip_edges()
	if not p.begins_with("user://"):
		return false
	var name := p.trim_prefix("user://")
	var re := RegEx.create_from_string("^[A-Za-z0-9_-]+\\.cfg$")
	if re.search(name) == null:
		return false
	# Настоящие файлы игры (прогресс, настройки, бой без кампании, адрес «Схватки» по сети) —
	# Campaign.reset() стёр бы любой из них (B-386 (4), verifier 5513a16c).
	var base := name.get_basename().to_lower()
	for real: String in [PATH, STANDALONE_PATH, Settings.PATH, NetLobby.CFG]:
		if base == real.trim_prefix("user://").get_basename().to_lower():
			return false
	return true


## true — пишем в настоящий прогресс владельца (путь не подменён тестом или прогоном без кампании).
static func uses_real_save() -> bool:
	return _path == PATH


# ── mode: переключатель раздела «поправки/Контора/премия/ожидающая награда» ──────────────────
## Смена раздела снимает отложенную замену поправки: выбор, сделанный в одном scope, не должен
## «оживать» после возврата в прежний (A1-4a: clear_stage при каждом переключении).
static func use_campaign_scope() -> void:
	_scope = "campaign"
	_mods_cache_valid = false
	RunProgression.clear_stage()


static func use_endless_scope() -> void:
	_scope = "endless"
	_mods_cache_valid = false
	RunProgression.clear_stage()


static func use_daily_scope() -> void:
	_scope = "daily"
	_mods_cache_valid = false
	RunProgression.clear_stage()


## D-0927-162: переигровка из коллекции — вне забега/дня, поправки/«Контора» не копятся
## (REPLAY_SECTION чистит reset_replay_scratch() перед КАЖДЫМ разом).
static func use_replay_scope() -> void:
	_scope = "replay"
	_mods_cache_valid = false
	RunProgression.clear_stage()


## true — «Бесконечный подряд» или «Вызов дня» (не кампания, не переигровка из коллекции).
static func is_endless_scope() -> bool:
	return _scope == "endless" or _scope == "daily"


static func is_daily_scope() -> bool:
	return _scope == "daily"


static func _run_section() -> String:
	match _scope:
		"endless":
			return ENDLESS_SECTION
		"daily":
			return DAILY_SECTION
		"replay":
			return REPLAY_SECTION
		_:
			return "meta"


static func _meta_section() -> String:
	return _run_section()


## Секция конкретного забега для чтения БЕЗ переключения scope (LegionMenu — метки обеих кнопок).
static func _run_section_for(daily: bool) -> String:
	return DAILY_SECTION if daily else ENDLESS_SECTION


static func _file() -> ConfigFile:
	if _cfg == null:
		_cfg = SafeConfig.load_file(_path)
		RunProgression.migrate(_cfg, _path)
	return _cfg


static func _save() -> Error:
	_mods_cache_valid = false
	if _update_depth > 0:
		_update_dirty = true
		return OK
	if int(_file().get_value(RunProgression.SECTION, "version", 0)) != RunProgression.VERSION:
		# Миграция в этой сессии уже отказывала (диск был недоступен) и _cfg держит откат: пробуем
		# ещё раз (J9) — иначе играть можно, а сохранить итоги нельзя до перезапуска.
		if not RunProgression.migrate(_file(), _path):
			return ERR_FILE_CORRUPT
	var err := SafeConfig.save_file(_file(), _path)
	if err != OK:
		push_warning("Campaign: не удалось сохранить %s (%d)" % [_path, err])
	return err


## Повтор записи из памяти после отказа диска (J2): содержимое не меняется — идемпотентно.
static func save_now() -> bool:
	return _save() == OK
## Связанные изменения (покупка, награды за бой) попадают на диск одним целым.
static func begin_update() -> void:
	if _update_depth == 0:
		_update_before = _file().encode_to_text()
		_update_dirty = false
	_update_depth += 1


static func end_update(rollback_on_error := false) -> bool:
	assert(_update_depth > 0)
	_update_depth -= 1
	if _update_depth > 0 or not _update_dirty:
		return true
	_update_dirty = false
	var ok := _save() == OK
	if not ok and rollback_on_error:
		_cfg = ConfigFile.new()
		_cfg.parse(_update_before)
		_mods_cache_valid = false
	return ok


## Все карты кампании, отсортированные по order. Читает JSON-каталог, при пустом/битом —
## заглушки. DirAccess по res:// в экспортированной игре видит только файлы, включённые
## в экспорт (docs/legion/SLICE_SPEC.md не оговаривает это явно — грабля отмечена в задании
## пакета UI), поэтому заглушки — не только dev-фолбэк, но и рабочий путь для release-сборки
## без ресурсов MAPS.
static func maps() -> Array[Dictionary]:
	return _catalog().duplicate(true)


## Карты в res:// неизменны в сборке. Кэш хранит оригиналы, публичный API выдаёт копии.
static func _catalog() -> Array[Dictionary]:
	if not _maps_cache.is_empty():
		return _maps_cache
	var out: Array[Dictionary] = []
	var dir := DirAccess.open(MAPS_DIR)
	if dir != null:
		dir.list_dir_begin()
		var name := dir.get_next()
		while name != "":
			if not dir.current_is_dir() and name.ends_with(".json") and not name.begins_with("_"):
				var data := _load_map_json(MAPS_DIR + name)
				if not data.is_empty():
					out.append(data)
			name = dir.get_next()
		dir.list_dir_end()
	if out.is_empty():
		out = FALLBACK_MAPS.duplicate(true)
	# order дробный: новая карта встаёт между соседями (2.5 — между 2 и 3), не перенумеровывая их
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.get("order", 0)) < float(b.get("order", 0)))
	_maps_cache = out
	for entry: Dictionary in out:
		_maps_by_id[String(entry.get("id", ""))] = entry
	return out


static func _load_map_json(path: String) -> Dictionary:
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		return {}
	var parsed: Variant = JSON.parse_string(text)
	if parsed is Dictionary:
		return parsed
	return {}


## Одна карта по id, или пустой словарь, если такой нет.
static func map(id: String) -> Dictionary:
	_catalog()
	return (_maps_by_id.get(id, {}) as Dictionary).duplicate(true)


## Явная перезагрузка нужна редактору/тестам; сохранение прогресса каталог не инвалидирует.
static func clear_map_cache() -> void:
	_maps_cache = []
	_maps_by_id = {}


## Первая карта по порядку открыта всегда; дальше — по записи "progress/unlocked".
## Лестница монотонна (D-0927-50): карта открыта и тогда, когда открыта или пройдена любая карта
## ПОЗЖЕ её по order. Так новая карта, вставленная между уже пройденными (v20: «Проходная» 1.5,
## «Архив» 2.5), в старом сохранении открыта сразу, а вместе с ней — её открытия (_unlock_mods).
## Вычисляется, а не переписывается в сохранение: откат на старую сборку ничего не ломает.
static func is_unlocked(id: String) -> bool:
	var all := _catalog()
	if all.is_empty():
		return false
	if String(all[0].get("id", "")) == id:
		return true
	var unlocked: Array = _file().get_value("progress", "unlocked", [])
	var later := false
	for m in all:
		var mid := String(m.get("id", ""))
		if mid == id:
			later = true
		if later and (unlocked.has(mid) or stars(mid) > 0):
			return true
	return false


## Лучший результат по карте (0 — ещё не пройдена).
static func stars(id: String) -> int:
	return int(_file().get_value("progress", "%s_stars" % id, 0))


## Итог боя: сохраняет лучший результат, при победе открывает следующую карту по порядку.
## cauldron_ratio — доля HP Котла 0..1 на конец боя. Возвращает звёзды, заработанные ЭТИМ
## прогоном (0 при поражении — карта не считается пройденной).
static func record_result(id: String, victory: bool, cauldron_ratio: float) -> int:
	if not victory:
		return 0
	var earned := LegionMetaCfg.stars_for_ratio(clampf(cauldron_ratio, 0.0, 1.0))
	var best := stars(id)
	if earned > best:
		_file().set_value("progress", "%s_stars" % id, earned)
	var all := maps()
	var idx := -1
	for i in all.size():
		if String(all[i].get("id", "")) == id:
			idx = i
			break
	if idx >= 0 and idx + 1 < all.size():
		var next_id := String(all[idx + 1].get("id", ""))
		var unlocked: Array = _file().get_value("progress", "unlocked", [])
		if not unlocked.has(next_id):
			unlocked.append(next_id)
			_file().set_value("progress", "unlocked", unlocked)
	_save()
	return earned


## Открыть все карты сразу (сервис для QA/дев-прогонов, не завязан на --dev флаг: вызывающий
## решает сам, когда это уместно).
static func unlock_all() -> void:
	var ids: Array = []
	for m in maps():
		ids.append(String(m.get("id", "")))
	_file().set_value("progress", "unlocked", ids)
	_save()


## Взятые поправки к договору, в порядке взятия.
static func upgrades() -> Array[StringName]:
	var raw: Array = _file().get_value(_meta_section(), "upgrades", [])
	var out: Array[StringName] = []
	for id in raw:
		var sid := StringName(String(id))
		if not AmendmentDb.card(sid).is_empty() and not out.has(sid) \
				and out.size() < AmendmentDb.MAX_ACTIVE:
			out.append(sid)
	return out


static func add_upgrade(id: StringName) -> void:
	var mapped := id if not AmendmentDb.card(id).is_empty() else \
		StringName(AmendmentDb.LEGACY_MAP.get(String(id), ""))
	var raw := upgrades()
	if mapped == &"" or raw.has(mapped) or raw.size() >= AmendmentDb.MAX_ACTIVE:
		return
	raw.append(mapped)
	_file().set_value(_meta_section(), "upgrades", raw)
	_save()


## Артефакты забега (D-0927-163) — раздел ТЕКУЩЕГО scope ("meta" кампании или секция забега).
## Пишет мир ПОБЕДОЙ (LegionWorld._end при carry_items); сброс и endless_start их чистят
## (в стеке mode сброс — LegionRunStore._reset_run_meta).
static func run_items() -> Array[StringName]:
	var out: Array[StringName] = []
	for id in _file().get_value(_meta_section(), CfgItems.SAVE_KEY, []):
		if not LegionItemDb.item(StringName(String(id))).is_empty():
			out.append(StringName(String(id)))
	return out


static func set_run_items(ids: Array[StringName]) -> void:
	_file().set_value(_meta_section(), CfgItems.SAVE_KEY, ids.map(func(i: StringName) -> String:
		return String(i)))
	_save()


## Три случайные ещё не взятые поправки (меньше, если пул почти выбран целиком). Поправка про
## то, что кампания ещё не открыла (needs — ключ открытия), не предлагается (B-096).
static func offer_upgrades(rng: RandomNumberGenerator) -> Array[StringName]:
	return RunProgression.offer(rng)


static func _shuffle(arr: Array, rng: RandomNumberGenerator) -> void:
	for i in range(arr.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp: Variant = arr[i]
		arr[i] = arr[j]
		arr[j] = tmp


## Свод эффектов всех взятых поправок по ключу (правило — MetaMods.combine). КАЖДАЯ КАРТОЧКА —
## отдельный источник: ключ-множитель от разных карточек перемножается, прибавочный складывается.
## Форма возврата прежняя, прибавочная (множитель = 1 + значение), поэтому `world.mods` не менялся.
static func active_mods() -> Dictionary:
	var parts := {}
	for id in upgrades():
		var card_mods: Dictionary = AmendmentDb.card(id).get("mods", {})
		for k: String in card_mods:
			if not parts.has(k):
				parts[k] = []
			(parts[k] as Array).append(float(card_mods[k]))
	var out := {}
	for k: String in parts:
		out[k] = MetaMods.combine(StringName(k), parts[k])
	return out


## Ключ-множитель — делегат к MetaMods (E-1005): вид ключа объявлен один раз на проект.
static func is_mult_key(key: StringName) -> bool:
	return MetaMods.is_mult_key(key)


static func active_rules() -> Dictionary:
	var out := {}
	for id in upgrades():
		var card := AmendmentDb.card(id)
		var rule := String(card.get("rule", ""))
		if rule != "":
			out[rule] = card.get("params", {}).duplicate()
	return out


## v15 (DESIGN_V15 §7, §11; пакет f0 — нейтральная заготовка, наполняет пакет meta): итоговое
## значение параметра боя с поправками (и подготовкой «Конторы»). Бой читает
## только его и сам покупки не разбирает. Звать при старте карты, не в кадре (читает сохранение).
##
## Нейтраль — по виду ключа (MetaMods.is_mult_key): множитель 1.0, прибавка 0.0. Свод источников —
## MetaMods.combine (множитель ∏(1+v), прибавка Σv). extra — дополнительные источники (у боя это
## подготовка «Конторы»): сводятся тем же правилом.
##
## v15 (пакет meta, DESIGN_V15 §7, §11): источник свода — не только поправки к договору
## (active_mods), но и открытия кампанией — все они сводятся в один плоский набор
## «ключ → прибавка» (_all_mods, закэширован, сбрасывается любой записью в сохранение — _save()).
## Покупки «Конторы» (подготовка боя) идут отдельным источником прямо в мир (battle_preparation);
## рангов и перков героя больше нет (D-1006-11) — их покупку не предлагал ни один экран.
static func stat(key: StringName, extra: Array = []) -> float:
	var add := float(_all_mods().get(String(key), 0.0))
	for v: Variant in extra:
		add = MetaMods.combine(key, [add, float(v)])
	return 1.0 + add if is_mult_key(key) else add


static func _all_mods() -> Dictionary:
	if not _mods_cache_valid:
		var out := {}
		_merge_mods(out, active_mods())
		_merge_mods(out, _unlock_mods())
		_mods_cache = out
		_mods_cache_valid = true
	return _mods_cache


## Слияние двух наборов «ключ → прибавка» (E-1005): `from` — один источник, правило — MetaMods.
static func _merge_mods(into: Dictionary, from: Dictionary) -> void:
	for k: String in from:
		into[k] = MetaMods.combine(StringName(k), [float(into.get(k, 0.0)), float(from[k])])


## Награда (поправка к договору) за победу, ещё не забранная игроком — id карты, куда вести
## после выбора (ревью 2026-09-24 п.4: раньше хранилась только в памяти LegionMain и терялась,
## если игрок уходил в «Меню», не нажав «Дальше»). "" — нет ожидающей награды.
static func pending_reward() -> String:
	return String(_file().get_value(_meta_section(), "pending_reward", ""))


## Не перетирает уже стоящую ожидающую награду — повторная победа на уже пройденной карте не
## должна плодить вторую поправку поверх той, что игрок ещё не забрал.
static func set_pending_reward(next_map_id: String) -> void:
	if pending_reward() != "":
		return
	_file().set_value(_meta_section(), "pending_reward", next_map_id)
	_file().set_value(_meta_section(), "reward_claimed", false)
	_file().set_value(_meta_section(), "draft_options", [])
	RunProgression.clear_stage()
	_save()


static func clear_pending_reward() -> void:
	_file().set_value(_meta_section(), "pending_reward", "")
	_file().set_value(_meta_section(), "reward_claimed", false)
	_file().set_value(_meta_section(), "draft_options", [])
	RunProgression.clear_stage()
	_save()


## Незавершённый переход в Контору и незабранная поправка — разные стадии.
static func reward_claimed() -> bool:
	return bool(_file().get_value(_meta_section(), "reward_claimed", false))


static func claim_reward(id: StringName = &"") -> bool:
	if pending_reward() == "" or reward_claimed():
		return false
	if id != &"" and (not RunProgression.available(id) or upgrades().has(id)):
		return false
	var slot := RunProgression.replacement_slot()
	if id != &"" and upgrades().size() >= AmendmentDb.MAX_ACTIVE and slot < 0:
		return false
	begin_update()
	if id != &"":
		var active := upgrades()
		if slot >= 0:
			active[slot] = id
		else:
			active.append(id)
		_file().set_value(_meta_section(), "upgrades", active)
	_file().set_value(_meta_section(), "reward_claimed", true)
	_file().set_value(_meta_section(), "draft_options", [])
	_save()
	var ok := end_update(true)
	if ok:
		RunProgression.clear_stage()
	return ok


## Баг мастера (verifier 27.09, п.5): свежий запуск с незабранной наградой шёл в
## offer_upgrades(world.rng), а `world` ещё null — Nil.rng валил игру. RNG детерминирован от
## ТЕКУЩЕГО сохранения, не Time-based randomize() — тот же принцип без мира.
static func pending_reward_rng() -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("%s|%d|%d" % [pending_reward(), bounty(), hero_xp()])
	return rng


## Пакет tutorial: прошёл или пропустил обучение — при следующем запуске кампании (или прямом
## старте wasteland) оно не предлагается само, только по кнопке «Обучение» (docs/legion/
## TUTORIAL_SPEC.md).
static func tutorial_done() -> bool:
	return bool(_file().get_value("tutorial", "done", false))


static func set_tutorial_done() -> void:
	_file().set_value("tutorial", "done", true)
	_save()


## Пакет tutorial: подсказки новых механик карт 2-6 (LegionMapHints) — одна плашка в бою на
## id, не повторяется. Тот же паттерн, что tutorial_done()/set_tutorial_done() выше.
static func hint_seen(id: StringName) -> bool:
	return bool(_file().get_value("tutorial", "hint_%s" % String(id), false))


static func mark_hint_seen(id: StringName) -> void:
	_file().set_value("tutorial", "hint_%s" % String(id), true)
	_save()


# ── v15 meta: премия, покупки «Конторы», герой (DESIGN_V15 §6–§7, §12 п.8–9) ──────────────────

## Премия — мета-валюта за бои, сохраняется, никогда не уходит в минус.
static func bounty() -> int:
	return int(_file().get_value(_meta_section(), "bounty", 0))


static func _add_bounty(amount: int) -> void:
	if amount == 0:
		return
	_file().set_value(_meta_section(), "bounty", maxi(0, bounty() + amount))
	_save()


## Публичная обёртка — _add_bounty остаётся приватной по имени ради существующих тестов
## (legion_ui_preview.gd зовёт Campaign._add_bounty() напрямую).
static func add_bounty(amount: int) -> void:
	_add_bounty(amount)


## Итог боя вне звёзд/открытия карты (те делает record_result выше): премия и опыт героя.
## kills — kills_rewardable статистики боя (пакет staff кладёт её в LegionWorld.match_ended;
## нет ключа — задание meta п.1/п.3 велит брать обычный kills, подставляет вызывающий).
## stars — уже посчитанные record_result (0 на поражении сам по себе даёт верную формулу).
## Возвращает {"bounty": int, "xp": int, "leveled_up": bool, "level": int} — для экрана итога.
static func record_rewards(victory: bool, stars: int, kills: int) -> Dictionary:
	var bounty_earned := LegionMetaCfg.bounty_for_result(victory, stars, kills)
	var xp_earned := LegionMetaCfg.hero_xp_for_result(victory, stars, kills)
	var level_before := hero_level()
	begin_update()
	add_bounty(bounty_earned)
	_add_hero_xp(xp_earned)
	end_update()
	var level_after := hero_level()
	return {
		"bounty": bounty_earned, "xp": xp_earned,
		"leveled_up": level_after > level_before, "level": level_after,
	}


## mode (verifier 27.09 п.4): премия за объект — формула bounty_for_result(), БЕЗ опыта героя.
## ratio — доля HP Котла (звёзды формулы). Пишет в СЕКЦИЮ ТЕКУЩЕГО scope.
static func grant_endless_bounty(victory: bool, kills: int, ratio: float) -> int:
	var stars := LegionMetaCfg.stars_for_ratio(clampf(ratio, 0.0, 1.0)) if victory else 0
	var earned := LegionMetaCfg.bounty_for_result(victory, stars, kills)
	add_bounty(earned)
	return earned


# ── «Контора»: покупки по LegionMetaCfg.OFFICE_SHOP ────────────────────────────────────────────

static func _shop_save_key(id: String, kind: String) -> String:
	return "shop_%s" % id if kind == "" else "shop_%s_%s" % [id, kind]


## Текущий уровень покупки (0 — не куплена). kind — только для per_kind покупок.
static func shop_level(id: String, kind: String = "") -> int:
	return int(_file().get_value(_meta_section(), _shop_save_key(id, kind), 0))


static func shop_max_level(id: String) -> int:
	var data: Dictionary = LegionMetaCfg.OFFICE_SHOP.get(id, {})
	return Array(data.get("costs", [])).size()


## Премия за СЛЕДУЮЩИЙ уровень, -1 — уровень уже максимальный (кнопка покупки скрывается).
static func shop_cost(id: String, kind: String = "") -> int:
	var data: Dictionary = LegionMetaCfg.OFFICE_SHOP.get(id, {})
	var costs: Array = data.get("costs", [])
	var lvl := shop_level(id, kind)
	if lvl >= costs.size():
		return -1
	return int(costs[lvl])


static func shop_buy(id: String, kind: String = "") -> bool:
	# Цепочки процентов заменены услугами; старый API не даёт купить неработающий бонус.
	return RunProgression.buy_service(id) if kind == "" else false


# ── Герой: опыт и разряд (DESIGN_V15 §6; переработка 06.10.2026) ─────────────────────────────────
## Стаж героя стал «разрядом»: он открывает ВАРИАНТЫ колоды (unlock_level карточек, RunProgression.
## available), а не покупает проценты. Ранги способностей и перки героя удалены (D-1006-11): их
## покупку уже не предлагал ни один экран с переработки 05.10, а в бою они читались через мёртвый
## _hero_mods — держать их значило оставлять висящий ключ без источника.

static func hero_xp() -> int:
	return int(_file().get_value("hero", "xp", 0))


static func _add_hero_xp(amount: int) -> void:
	if amount <= 0:
		return
	_file().set_value("hero", "xp", hero_xp() + amount)
	_save()


## Уровень по накопленному опыту (HERO_LEVEL_THRESHOLDS — кумулятивные пороги), потолок 10.
static func hero_level() -> int:
	var xp := hero_xp()
	var lvl := 1
	for threshold in LegionMetaCfg.HERO_LEVEL_THRESHOLDS:
		if xp >= int(threshold):
			lvl += 1
	return mini(lvl, LegionMetaCfg.HERO_MAX_LEVEL)


## Для полоски опыта на экране героя: опыт внутри текущего уровня и сколько нужно до следующего.
static func hero_xp_progress() -> Dictionary:
	var lvl := hero_level()
	if lvl >= LegionMetaCfg.HERO_MAX_LEVEL:
		return {"level": lvl, "cur": 0, "need": 0, "maxed": true}
	var prev_th := 0 if lvl <= 1 else int(LegionMetaCfg.HERO_LEVEL_THRESHOLDS[lvl - 2])
	var next_th := int(LegionMetaCfg.HERO_LEVEL_THRESHOLDS[lvl - 1])
	return {"level": lvl, "cur": hero_xp() - prev_th, "need": next_th - prev_th, "maxed": false}


# ── Открытия кампанией: виды бойцов, способности героя (задание meta п.4) ──────────────────────
## Кампания v20 (D-0926-46): открытия — данные карты, поле `unlocks` её JSON (ключи stat():
## kind_unlocked_<вид>, ability_unlocked_q|w|e, shape_unlocked_ring|eight|triangle|square,
## control_unlocked_aim|rally, loot_unlocked_items). Открыто всё, что дают уже открытые карты
## (is_unlocked): на карте в первый раз — ровно то, чему она учит, и всё, что было раньше.
## Подряд открыт всегда. Каталог без единого поля `unlocks` (заглушки FALLBACK_MAPS) — открыто
## всё, как до v20: экраны без ресурсов карт не должны терять навыки.
static func _unlock_mods() -> Dictionary:
	var out := {"kind_unlocked_%s" % LegionCfg.KIND_LABORER: 1.0}
	var any_data := false
	for m in maps():
		if not m.has("unlocks"):
			continue
		any_data = true
		if is_unlocked(String(m.get("id", ""))):
			for key: Variant in m["unlocks"]:
				out[String(key)] = 1.0
	if not any_data:
		for id: String in _UNLOCK_LABELS:
			out[String(_UNLOCK_LABELS[id][0])] = 1.0
		out["ability_unlocked_q"] = 1.0
	return out


## Что открылось и ещё не показано игроку — для плашки «Новое: …» на брифинге (задание meta
## п.4). Помечать показанным через mark_unlocks_seen() сразу после отображения.
static func pending_unlock_labels() -> Array[String]:
	var seen := _unlocks_seen()
	var mods := _unlock_mods()
	var out: Array[String] = []
	for id in _UNLOCK_LABELS:
		var entry: Array = _UNLOCK_LABELS[id]
		if float(mods.get(String(entry[0]), 0.0)) > 0.5 and not seen.has(id):
			out.append(String(entry[1]))
	return out


static func mark_unlocks_seen() -> void:
	var stored: Array = _file().get_value("meta", "unlocks_seen", [])
	var seen := _unlocks_seen()
	var mods := _unlock_mods()
	var changed := seen.size() != stored.size()
	for id in _UNLOCK_LABELS:
		var entry: Array = _UNLOCK_LABELS[id]
		if float(mods.get(String(entry[0]), 0.0)) > 0.5 and not seen.has(id):
			seen.append(id)
			changed = true
	if changed:
		_file().set_value("meta", "unlocks_seen", seen)
		_save()


## Показанные открытия; у сохранения старше v20 к ним добавлены те, что игрок имел до лестницы
## (_PRE_V20_KNOWN) — вычисляется при чтении, в файл попадает только с mark_unlocks_seen().
static func _unlocks_seen() -> Array:
	var seen: Array = (_file().get_value("meta", "unlocks_seen", []) as Array).duplicate()
	if is_pre_v20():
		for id: String in _PRE_V20_KNOWN:
			if not seen.has(id):
				seen.append(id)
	return seen


## Сохранение старше v20 — «дырка в лестнице»: какая-то карта не открыта и не пройдена, а более
## поздняя по order — открыта или пройдена. Так бывает только у прогресса, записанного до того,
## как между картами вставили новые («Проходная», «Архив»): победа v20 всегда открывает
## следующую по порядку. Вычисляется при чтении, в сохранение не пишется.
static func is_pre_v20() -> bool:
	var unlocked: Array = _file().get_value("progress", "unlocked", [])
	var all := maps()
	var hole := false
	for i in range(1, all.size()):
		var id := String(all[i].get("id", ""))
		var reached := unlocked.has(id) or stars(id) > 0
		if reached and hole:
			return true
		hole = hole or not reached
	return false


## Пакет cuts: вступительная катсцена показана один раз за кампанию — при повторном заходе
## в «Продолжить»/новый брифинг после первого показа её больше не выводим (docs/legion/
## DESIGN_V15.md §9). Тот же паттерн, что tutorial_done()/set_tutorial_done() выше.
static func intro_cutscene_seen() -> bool:
	return bool(_file().get_value("cutscene", "intro_seen", false))


static func set_intro_cutscene_seen() -> void:
	_file().set_value("cutscene", "intro_seen", true)
	_save()


## Есть ли что продолжать: пройденная карта, начатое обучение или показанное вступление.
## Меню по нему пишет «Начать кампанию» вместо «Продолжить» (после сброса и при первом запуске).
static func has_progress() -> bool:
	if tutorial_done() or intro_cutscene_seen():
		return true
	for m in maps():
		if stars(String(m.get("id", ""))) > 0:
			return true
	return false


## Сброс прогресса (кнопка «Сначала», если понадобится) — стирает файл, не только кэш.
static func reset() -> void:
	_cfg = ConfigFile.new()
	_cfg.set_value(RunProgression.SECTION, "version", RunProgression.VERSION)
	RunProgression.clear_stage()
	_update_depth = 0
	_update_dirty = false
	var err := SafeConfig.save_file(_cfg, _path, true)
	if err != OK:
		push_warning("Campaign: не удалось сбросить %s (%d)" % [_path, err])
	_mods_cache_valid = false


## Мост для LegionRunStore/LegionCollection (свои файлы ради max-file-lines) — тот же кэш
## ConfigFile, не второй независимый экземпляр (иначе несинхронный кэш перезаписал бы диск
## устаревшим состоянием).
static func raw_file() -> ConfigFile:
	return _file()


static func save_raw() -> void:
	_save()
