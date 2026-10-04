extends SceneTree
##
## Регресс линии filter процгена (STAGE2.md, BOOK §7 и §10): фильтр годности PgFilter.
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_procgen_filter_test.gd -- --mute
##
## 1) measure() на 8 картах кампании сходится с замерами книги §3.1 (comfort_measure.py):
##    мин и p10 пролёта поперёк дороги ±3 px, доля < 76 px ±2 п.п.;
## 2) check() видит У-1 на «Двух отделах» и «Лабиринте» и не видит на «Болоте» и «Мосте»;
## 3) синтетические поломки годной карты — каждая ловится своим правилом; горло с разметкой годно;
## 4) время разбора карты (цель ≤ 40 мс: генератор зовёт фильтр до ~12 раз на объект);
## 5) находки verifier 27.09: правила изюминок §4.1 по данным, рубеж-отрезок у HUD, щель у края
##    кадра, сглаженный поворот, битые словари (строка «Словарь: …» вместо SCRIPT ERROR).
## Плюс сводка «какие правила нарушает каждая карта кампании» — информационно: кампания рисована
## руками и У-правилам не обязана. Бой не создаётся, сохранений не пишет.
## Итог «LEGION PROCGEN FILTER: N/M OK»; код выхода 1, если что-то упало.
##

## Замеры книги §3.1: мин, p10, доля < 76 px (%).
const BOOK := {
	"wasteland": [54, 238, 1.3], "gatehouse": [0, 136, 4.3], "fork": [56, 62, 13.1],
	"archive": [81, 159, 0.0], "bridge": [96, 309, 0.0], "maze": [38, 53, 18.5],
	"swamp": [255, 344, 0.0], "boss": [126, 232, 0.0],
}
const PX_TOL := 3.0
const PP_TOL := 2.0
## Цель фильтра — 40 мс на карту; в тесте пороги с запасом, чтобы чужая нагрузка на машине
## (гейты и серии параллельно) не роняла гейт: медиана из TIME_RUNS прогонов (координатор 27.09).
const BUDGET_MS := 40.0
## Пороги времени — страховка от зависания, не замер скорости (Игорь 03.10 «скорость генерации
## не критична»; 60/100 мс шумели с загрузкой машины: 60,3 и 101,9 мс на том же коде, B-393).
const CAMPAIGN_LIMIT_MS := 300.0
const HEAVY_LIMIT_MS := 500.0
const TIME_RUNS := 5
## «Тяжёлая» карта для замера: столько препятствий-предметов и звеньев оград, сколько даст
## генератор с запасом (кампания — 10–40 скал).
const HEAVY_ROCKS := 80
const HEAVY_WALLS := 10

var _fails := 0
var _checks := 0


func _initialize() -> void:
	_campaign()
	_breakages()
	_quirk_rules()
	_geometry_fixes()
	_broken_dicts()
	_turn_cases()
	_bad_values()
	_loop_bounds()
	_heavy()
	print("LEGION PROCGEN FILTER: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


func _check(cond: bool, what: String) -> void:
	_checks += 1
	if cond:
		print("  ok   ", what)
	else:
		_fails += 1
		print("  FAIL ", what)


func _has_rule(problems: Array[String], prefix: String, needle := "") -> bool:
	for p in problems:
		# String.contains("") в Godot — false, пустую иголку не спрашиваем
		if p.begins_with(prefix) and (needle.is_empty() or p.contains(needle)):
			return true
	return false


func _campaign() -> void:
	var total_ms := 0.0
	var worst_ms := 0.0
	var maps := Campaign.maps()
	for map: Dictionary in maps:
		var id := String(map.id)
		var times: Array[float] = []
		var r: Dictionary = {}
		for k in TIME_RUNS:
			var t0 := Time.get_ticks_usec()
			r = PgFilter.evaluate(map)
			times.append((Time.get_ticks_usec() - t0) / 1000.0)
		times.sort()
		total_ms += times[TIME_RUNS / 2]
		worst_ms = maxf(worst_ms, times[TIME_RUNS / 2])
		var sp: Dictionary = r.measure.span
		print("%s: пролёт мин %d p10 %.1f медиана %.1f · <76 %.1f %% · <90 %.1f %% · ≥200 %.1f %%"
			% [id, sp.min, sp.p10, sp.median, sp.lt76, sp.lt90, sp.ge200]
			+ " · встреча %.1f с · проходимо %.0f %% · штраф %.2f · %.1f мс"
			% [r.measure.first_contact, r.measure.walkable * 100.0, r.score, times[TIME_RUNS / 2]])
		if BOOK.has(id):
			var book: Array = BOOK[id]
			_check(absf(float(sp.min) - book[0]) <= PX_TOL,
				"%s: мин пролёта %d ≈ книга %d" % [id, sp.min, book[0]])
			_check(absf(float(sp.p10) - book[1]) <= PX_TOL,
				"%s: p10 %.1f ≈ книга %d" % [id, sp.p10, book[1]])
			_check(absf(float(sp.lt76) - book[2]) <= PP_TOL,
				"%s: доля < 76 px %.1f %% ≈ книга %.1f %%" % [id, sp.lt76, book[2]])
		var problems: Array[String] = r.problems
		var rules: Dictionary = {}
		for p in problems:
			rules[p.get_slice(":", 0)] = true
			print("     - ", p)
		var names := ", ".join(PackedStringArray(rules.keys())) if rules.size() > 0 else "ничего"
		print("   %s нарушает: %s" % [id, names])
		if id in ["fork", "maze"]:
			_check(_has_rule(problems, "У-1:"), id + ": check находит У-1 (узкие коридоры книги)")
		if id in ["swamp", "bridge"]:
			_check(not _has_rule(problems, "У-1:"), id + ": У-1 нет (эталон удобства)")
	var avg := total_ms / maps.size()
	print("время разбора карты: среднее по медианам %.1f мс, худшая медиана %.1f мс (цель ≤ %.0f)"
		% [avg, worst_ms, BUDGET_MS])
	_check(maps.size() == 8, "кампания — 8 карт")
	_check(worst_ms <= CAMPAIGN_LIMIT_MS,
		"худшая медиана по карте %.1f мс ≤ %.0f (порог с запасом на нагрузку)"
		% [worst_ms, CAMPAIGN_LIMIT_MS])


## Годная синтетическая карта: одна дорога-змейка справа к Котлу слева, чистое поле.
func _base() -> Dictionary:
	return {
		"id": "gen:test:1", "title": "Тест", "bg": "", "theme": "grave",
		"cauldron": [220, 360], "cauldron_hp": 200, "start_army": 6, "army_cap": 30,
		"rocks": [], "walls": [], "water": [], "bridges": [], "swamp": [],
		"crypts": [], "sleepers": [], "flights": [], "breaches": [], "decor": [],
		"roads": [{"id": "main", "path": [[1360, 360], [1000, 360], [1000, 180], [600, 180],
			[600, 540], [360, 540], [360, 360], [220, 360]]}],
		"plots": [
			{"id": "p1", "pos": [260, 460]}, {"id": "p2", "pos": [480, 420]},
			{"id": "p3", "pos": [900, 280]}, {"id": "p4", "pos": [1100, 460]}],
		"bot_lines": [
			{"id": "line_0", "road": "main", "kind": "guard", "a": [940, 270], "b": [1060, 270]},
			{"id": "line_1", "road": "main", "kind": "laborer", "a": [300, 300], "b": [300, 420]}],
		"waves": [
			{"pause": 3, "groups": [{"road": "main", "type": "zombie", "count": 5, "interval": 1.0,
				"delay": 0.0}]},
			{"pause": 10, "groups": [{"road": "main", "type": "zombie", "count": 8, "interval": 1.0}]}],
		"hint": "тест",
	}


## Две скалы поперёк дороги y = 180 на x 750–850 с просветом gap px.
func _squeeze(map: Dictionary, gap: float) -> void:
	var top := 180.0 - gap * 0.5
	var bottom := 180.0 + gap * 0.5
	map.rocks = [[[750, 90], [850, 90], [850, top], [750, top]],
		[[750, bottom], [850, bottom], [850, 270], [750, 270]]]


func _breakages() -> void:
	var base := _base()
	var ok := PgFilter.check(base)
	for p in ok:
		print("     база: ", p)
	_check(ok.is_empty(), "годная синтетическая карта проходит фильтр")
	_check(PgFilter.score(base) >= 0.0 and PgFilter.score(base) <= 1.0, "штраф в 0…1")

	var m := _base()
	m.roads[0].path = [[1100, -80], [1100, 360], [1000, 360], [1000, 180], [600, 180],
		[600, 540], [360, 540], [360, 360], [220, 360]]
	_check(_has_rule(PgFilter.check(m), "У-6:", "сверху"), "ворота под превью волны → У-6")

	m = _base()
	m.cauldron = [60, 360]
	m.roads[0].path[-1] = [60, 360]
	_check(_has_rule(PgFilter.check(m), "У-8:", "от края"), "Котёл у края → У-8")

	m = _base()
	m.roads[0].path = [[1360, 360], [1000, 360], [1000, 200], [1150, 200], [1150, 480],
		[600, 480], [600, 540], [360, 540], [360, 360], [220, 360]]
	_check(_has_rule(PgFilter.check(m), "У-7:", "сама себя"), "дорога сама через себя → У-7")

	m = _base()
	m.plots[3].pos = [820, 520]
	var far := PgFilter.check(m)
	_check(_has_rule(far, "У-4:", "p4"), "участок в 220 px от дороги → У-4")
	_check(_has_rule(far, "Тест:", "призыв достаёт дорогу"), "…и проверка теста карт (RECRUIT_R)")

	m = _base()
	_squeeze(m, 70.0)
	var narrow := PgFilter.check(m)
	_check(_has_rule(narrow, "У-1:", "дороге main"), "пролёт 70 px без горла → У-1")
	var mm: Dictionary = PgFilter.measure(m)
	_check(mm.span.min >= 66 and mm.span.min <= 72, "measure: мин пролёта %d ≈ 70" % mm.span.min)

	m = _base()
	m.waves[0].groups[0].delay = 25.0
	_check(_has_rule(PgFilter.check(m), "У-10:"), "первая встреча ~41 с → У-10")
	_check(absf(float(PgFilter.measure(m).first_contact) - 41.2) < 1.0,
		"встреча: пауза 3 + задержка 25 + 450 px / 34 px/с")

	m = _base()
	_squeeze(m, 86.0)
	_check(_has_rule(PgFilter.check(m), "У-1:"), "горло 86 px без разметки → У-1")
	m.procgen = {"card": {"quirks": ["throat"], "archetype": "snake"},
		"throat": {"road": "main", "from": 680.0, "to": 800.0}}
	var throat := PgFilter.check(m)
	for p in throat:
		print("     горло: ", p)
	_check(throat.is_empty(), "горло 86 px с разметкой (≤ 120 px, охрана рядом) — годно")
	m.procgen.throat.to = 900.0
	_check(_has_rule(PgFilter.check(m), "И-горло:", "длина"), "горло длиннее 120 px → И-горло")

	m = _base()
	# змейка вверх-вниз без самопересечений: ×3,3 прямого — выше 2,6, но ниже 4,0 спирали
	m.roads[0].path = [[1360, 360], [1200, 360], [1200, 100], [1050, 100], [1050, 620],
		[900, 620], [900, 100], [750, 100], [750, 620], [600, 620], [600, 100], [450, 100],
		[450, 360], [220, 360]]
	var twisty := PgFilter.check(m)
	_check(_has_rule(twisty, "У-11:"), "извилистая дорога → У-11")
	m.procgen = {"card": {"quirks": [], "archetype": "spiral"}}
	_check(not _has_rule(PgFilter.check(m), "У-11:"), "…у спирали та же дорога годна по У-11")


## Скорость на карте, забитой предметами: генератор зовёт фильтр на каждого кандидата.
func _heavy() -> void:
	var map := _base()
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var rocks: Array = []
	for i in HEAVY_ROCKS:
		var c := Vector2(rng.randf_range(40, 1240), rng.randf_range(60, 680))
		var poly: Array = []
		for k in 8:
			var r := rng.randf_range(14, 40)
			poly.append([c.x + cos(TAU * k / 8.0) * r, c.y + sin(TAU * k / 8.0) * r])
		rocks.append(poly)
	map.rocks = rocks
	var walls: Array = []
	for i in HEAVY_WALLS:
		var a := Vector2(rng.randf_range(100, 1100), rng.randf_range(100, 600))
		walls.append({"path": [[a.x, a.y], [a.x + 120, a.y], [a.x + 120, a.y + 80]], "w": 20,
			"kind": "fence"})
	map.walls = walls
	var times: Array[float] = []
	var problems := 0
	for k in TIME_RUNS:
		var t0 := Time.get_ticks_usec()
		problems = PgFilter.check(map).size()
		times.append((Time.get_ticks_usec() - t0) / 1000.0)
	times.sort()
	print("тяжёлая карта (%d скал, %d оград): %.1f мс, нарушений %d"
		% [HEAVY_ROCKS, HEAVY_WALLS, times[TIME_RUNS / 2], problems])
	# ловим грубый откат скорости, а не чужую нагрузку (тяжёлая карта на тихой машине ~25–30 мс)
	_check(times[TIME_RUNS / 2] <= HEAVY_LIMIT_MS,
		"тяжёлая карта: медиана %.1f мс ≤ %.0f" % [times[TIME_RUNS / 2], HEAVY_LIMIT_MS])


## Река x 700–800 поперёк дороги y = 180 и мост шириной width.
func _river(map: Dictionary, width: float) -> void:
	map.water = [[[700, 0], [800, 0], [800, 720], [700, 720]]]
	map.bridges = [[[690, 180 - width / 2], [810, 180 - width / 2], [810, 180 + width / 2],
		[690, 180 + width / 2]]]


## Вторая дорога, сливающаяся с main в (600,540): развилка/слияние для трещин и мимиков.
func _two_roads(map: Dictionary) -> void:
	map.roads.append({"id": "south", "path": [[1360, 620], [700, 620], [700, 540], [600, 540],
		[360, 540], [360, 360], [220, 360]]})


## BOOK §4.1: правила изюминок, видимые в данных (находка verifier 27.09).
func _quirk_rules() -> void:
	var m := _base()
	_river(m, 96.0)
	_check(not _has_rule(PgFilter.check(m), "И-мост:"), "мост 96 px годен")
	m = _base()
	_river(m, 92.0)
	_check(_has_rule(PgFilter.check(m), "И-мост:", "шириной"), "мост 92 px → И-мост")
	m = _base()
	_river(m, 96.0)
	m.procgen = {"card": {"quirks": ["bridge1"], "archetype": "crossing"}}
	_check(_has_rule(PgFilter.check(m), "И-мост:", "своём берегу"),
		"«Один мост» без участка на своём берегу ≤ 200 px → И-мост")
	m.plots[1].pos = [620, 250]
	_check(not _has_rule(PgFilter.check(m), "И-мост:"),
		"…а с участком у моста на своём берегу — годен")

	m = _base()
	m.breaches = [{"id": "b1", "road": "main", "at": 500.0}, {"id": "b2", "road": "main", "at": 600.0},
		{"id": "b3", "road": "main", "at": 700.0}]
	_check(_has_rule(PgFilter.check(m), "И-трещины:", "друг от друга"),
		"три трещины через 100 px → И-трещины (≥ 400)")
	m = _base()
	m.breaches = [{"id": "rear", "road": "main", "at": 1660.0}]
	m.waves[0].groups.append({"road": "main", "type": "zombie", "count": 3, "breach": "rear",
		"delay": 12.0})
	_check(_has_rule(PgFilter.check(m), "И-тыл:", "волне 1"),
		"тыловая трещина в первой волне → И-тыл (только кульминация)")
	m.waves[0].groups.pop_back()
	m.waves[1].groups.append({"road": "main", "type": "zombie", "count": 3, "breach": "rear",
		"delay": 12.0})
	_check(not _has_rule(PgFilter.check(m), "И-тыл:"), "…в последней волне (кульминация) — годна")
	m.waves[1].groups.pop_back()
	m.waves[0].groups.append({"road": "main", "type": "zombie", "count": 3, "breach": "rear",
		"delay": 12.0})
	m.waves[0]["climax"] = true
	_check(not _has_rule(PgFilter.check(m), "И-тыл:"),
		"…в волне с пометкой climax (PgWaves: предпоследняя) — годна")
	m.plots[0].pos = [700, 460]
	m.plots[1].pos = [700, 300]
	_check(_has_rule(PgFilter.check(m), "И-тыл:", "ближайший участок"),
		"у тыловой трещины нет участка ≤ 250 px → И-тыл")
	m = _base()
	_two_roads(m)
	m.breaches = [{"id": "merge", "road": "main", "at": 1350.0},
		{"id": "rear", "road": "main", "at": 1660.0}]
	_check(_has_rule(PgFilter.check(m), "И-трещины:", "на слиянии"),
		"трещина на слиянии вместе с тыловой → И-трещины")

	m = _base()
	m.sleepers = [{"pos": [1060, 120]}]
	_check(_has_rule(PgFilter.check(m), "И-мимик:", "колена (1000,180)"),
		"мимик в 85 px от колена дороги → И-мимик")
	m.sleepers = [{"pos": [780, 240]}]
	_check(not _has_rule(PgFilter.check(m), "И-мимик:"),
		"мимик в 60 px от прямой дороги, вдали от колен и участков — годен (книга: «дорога-колено»)")
	m = _base()
	_two_roads(m)
	m.sleepers = [{"pos": [620, 600]}]
	_check(_has_rule(PgFilter.check(m), "И-мимик:", "развилки"),
		"мимик у развилки без изюминки mimic_mine → И-мимик")
	m.procgen = {"card": {"quirks": ["mimic_mine"], "archetype": "fork"}}
	_check(not _has_rule(PgFilter.check(m), "И-мимик:"), "…с изюминкой «Мина на развилке» — годен")

	m = _base()
	m.crypts = [{"pos": [800, 620]}]
	_check(_has_rule(PgFilter.check(m), "И-склеп:"), "склеп далеко от участков → И-склеп (≤ 200)")

	m = _base()
	m.swamp = [[[330, 440], [390, 440], [390, 480], [330, 480]]]
	var swamp := PgFilter.check(m)
	_check(_has_rule(swamp, "И-топь:", "у (360,4"), "И-топь называет место топи, а не начало окна")

	m = _base()
	m.procgen = {"card": {"quirks": [], "archetype": "snake"}}
	m.cauldron = [640, 360]
	m.roads[0].path[-1] = [640, 360]
	_check(_has_rule(PgFilter.check(m), "И-центр:"), "Котёл в центре у змейки → И-центр")
	m = _base()
	m.procgen = {"card": {"quirks": [], "archetype": "snake"}}
	m.waves[1].groups.append({"road": "main", "type": "boss", "count": 1})
	_check(_has_rule(PgFilter.check(m), "И-прораб:"), "Прораб у змейки → И-прораб")
	m = _base()
	m.roads[0].path = [[1360, 360], [800, 360], [800, 100], [300, 100], [300, 600], [100, 600],
		[100, 360], [220, 360]]
	_check(not _has_rule(PgFilter.check(m), "И-полоса:"),
		"две прямые ≥ 480 px без изюминки (эстафета) — не нарушение")
	m.procgen = {"card": {"quirks": ["runway"], "archetype": "snake"}}
	_check(_has_rule(PgFilter.check(m), "И-полоса:"),
		"«Взлётная полоса» и две прямые ≥ 480 px → И-полоса (≤ 1)")
	m = _base()
	m.procgen = {"card": {"quirks": ["recruit_link"], "archetype": "snake"}}
	_check(not _has_rule(PgFilter.check(m), "И-перемычка:"), "перемычка: p1–p2 в 224 px — годна")
	m.plots[1].pos = [490, 380]
	_check(_has_rule(PgFilter.check(m), "И-перемычка:"), "перемычка без пары участков 210–240 px")


## Находки verifier 27.09 по геометрии: У-13 по отрезку, У-12 у края кадра, У-7 по накопленному
## углу.
func _geometry_fixes() -> void:
	var m := _base()
	m.bot_lines.append({"id": "diag", "road": "main", "kind": "guard", "a": [1010, 300],
		"b": [700, 100]})
	_check(not _has_rule(PgFilter.check(m), "У-13:"), "косой рубеж мимо панели — не под HUD")
	m.bot_lines[2].b = [1100, 60]
	_check(_has_rule(PgFilter.check(m), "У-13:", "diag"), "рубеж, заходящий под превью волны → У-13")

	m = _base()
	m.rocks = [[[40, 100], [140, 100], [140, 250], [40, 250]]]
	_check(_has_rule(PgFilter.check(m), "У-12:", "краем кадра"), "коридор 40 px у левого края → У-12")
	m = _base()
	# обочина ворот: скала на дороге у правого края, подрезанная полосой дороги, в 30 px от края
	m.rocks = [[[1210, 300], [1250, 300], [1250, 420], [1210, 420]]]
	_check(not _has_rule(PgFilter.check(m), "У-12:"), "скала у ворот дороги не даёт ложной щели")

	m = _base()
	m.roads[0].path = [[1360, 360], [1000, 360], [991.34, 355], [986.34, 346.34], [986.34, 336.34],
		[986.34, 296.34], [946.34, 296.34], [600, 296.34], [600, 540], [360, 540], [360, 360],
		[220, 360]]
	_check(_has_rule(PgFilter.check(m), "У-7:", "два поворота"),
		"сглаженный 90° (3×30° через 10 px) и 90° через 50 px → У-7")
	m = _base()
	m.roads[0].path = [[1360, 360], [1000, 360], [1000, 180], [1040, 180], [1040, 100], [600, 100],
		[600, 540], [360, 540], [360, 360], [220, 360]]
	_check(_has_rule(PgFilter.check(m), "У-7:", "два поворота"), "S-изгиб 90°/−90° через 40 px → У-7")


## Битые словари: фильтр отвечает строкой «Словарь: …», а не падает (BOOK §10, смоук).
func _broken_dicts() -> void:
	var cases := {
		"пустой словарь": func(m: Dictionary) -> Dictionary: return {},
		"без id": func(m: Dictionary) -> Dictionary:
			m.erase("id")
			return m,
		"дорога с пустым путём": func(m: Dictionary) -> Dictionary:
			m.roads[0].path = []
			return m,
		"дорога из одной точки": func(m: Dictionary) -> Dictionary:
			m.roads[0].path = [[1360, 360]]
			return m,
		"группа без type": func(m: Dictionary) -> Dictionary:
			m.waves[0].groups[0].erase("type")
			return m,
		"без волн": func(m: Dictionary) -> Dictionary:
			m.erase("waves")
			return m,
		"точка — строка": func(m: Dictionary) -> Dictionary:
			m.plots[0].pos = ["a", 1]
			return m,
	}
	for name: String in cases:
		var map: Dictionary = cases[name].call(_base())
		var problems := PgFilter.check(map)
		_check(_has_rule(problems, "Словарь:"), "битый словарь (%s) → «Словарь: …»" % name)
	var m := _base()
	m.erase("walls")
	m.erase("bot_lines")
	_check(not _has_rule(PgFilter.check(m), "Словарь:"), "необязательных полей может не быть")


## Дуга: из start по направлению dir0 (рад) n шагов длиной seg, поворот на step_deg за шаг.
func _arc(start: Vector2, dir0: float, step_deg: float, seg: float, n: int) -> PackedVector2Array:
	var out := PackedVector2Array([start])
	var ang := dir0
	var p := start
	for i in n:
		p += Vector2.from_angle(ang) * seg
		out.append(p)
		ang += deg_to_rad(step_deg)
	return out


func _sharp(path: PackedVector2Array) -> bool:
	return PgFilter._sharp_turns(path) != Vector2.INF


## Угол на deg из изломов по step через seg px; jitter — встречный излом −0,02° между шагами.
func _corner(p: PackedVector2Array, dir: float, deg: float, step: float, seg: float,
		jitter: bool) -> float:
	for i in int(round(deg / step)):
		dir += deg_to_rad(step)
		p.append(p[-1] + Vector2.from_angle(dir) * seg)
		if jitter:
			dir -= deg_to_rad(0.02)
			p.append(p[-1] + Vector2.from_angle(dir) * seg)
			dir += deg_to_rad(0.02)
	return dir


## Точки дуги окружности (центр c, радиус r) от a0 до a1 градусов шагом step; rnd — до целых.
func _arc_pts(c: Vector2, r: float, a0: float, a1: float, step: float,
		rnd: bool) -> PackedVector2Array:
	var out := PackedVector2Array()
	var n := int(round(absf(a1 - a0) / step))
	for i in n + 1:
		var q := c + Vector2.from_angle(deg_to_rad(a0 + (a1 - a0) * i / n)) * r
		out.append(Vector2(roundf(q.x), roundf(q.y)) if rnd else q)
	return out


## Таблица случаев У-7 (verifier-2 и verifier-3, 27.09): [название, путь, ждём нарушение].
func _turn_table() -> Array:
	var rows := []
	for g: float in [30.0, 39.0, 40.0, 41.0, 60.0, 79.0, 80.0, 100.0]:
		rows.append(["два угла по 90° через %.0f px" % g, PackedVector2Array([Vector2(0, 0),
			Vector2(300, 0), Vector2(300, g), Vector2(0, g)]), g < 80.0])
	for jit: bool in [false, true]:
		for gap: float in [30.0, 60.0]:
			var p := PackedVector2Array([Vector2(1360, 600), Vector2(900, 600)])
			var dir := _corner(p, PI, 90.0, 30.0, 3.0, jit)
			p.append(p[-1] + Vector2.from_angle(dir) * gap)
			dir = _corner(p, dir, 90.0, 30.0, 3.0, jit)
			p.append(p[-1] + Vector2.from_angle(dir) * 300)
			rows.append(["два угла из 3×30° через %.0f px%s" % [gap, ", встречные −0,02°" if jit else ""],
				p, true])
	for seg: float in [0.0, 3.0, 1.0]:
		var p := PackedVector2Array([Vector2(0, 0), Vector2(300, 0)])
		var dir := 0.0
		for k in 3:
			if seg == 0.0:
				dir += PI / 2
				p.append(p[-1] + Vector2.from_angle(dir) * (30.0 if k < 2 else 300.0))
				continue
			dir = _corner(p, dir, 90.0, 30.0, seg, false)
			p.append(p[-1] + Vector2.from_angle(dir) * (30.0 if k < 2 else 300.0))
		rows.append(["три угла по 90° через 30 px%s" % ("" if seg == 0.0 else
			" (из 3×30° через %.0f px)" % seg), p, true])
	for step: float in [9.0, 5.0]:
		var p := PackedVector2Array([Vector2(0, 0)])
		p.append_array(_arc_pts(Vector2(100, 100), 100, -90, 90, step, false))
		p.append(Vector2(0, 200))
		rows.append(["дуга R100 на 180° шагом %.0f°" % step, p, false])
	var steps := PackedVector2Array([Vector2(0, 0)])
	steps.append_array(_arc(Vector2(100, 0), 0.0, 9.0, 8.0, 20))
	steps.append(steps[-1] + Vector2(-100, 0))
	rows.append(["20 изломов по 9° через 8 px", steps, false])
	for rnd: bool in [false, true]:
		for step: float in [3.0, 5.0, 9.0]:
			var p := PackedVector2Array([Vector2(1360, 560)])
			p.append_array(_arc_pts(Vector2(700, 460), 100, 90, 180, step, rnd))
			var a2 := _arc_pts(Vector2(500, 460), 100, 0, -90, step, rnd)
			a2.remove_at(0)
			p.append_array(a2)
			p.append(Vector2(220, 360))
			rows.append(["S-изгиб R100 шагом %.0f°%s" % [step, " (целые)" if rnd else ""], p, true])
	for step: float in [2.0, 3.0, 5.0]:
		var p := PackedVector2Array([Vector2(1360, 500), Vector2(700, 500)])
		var arc := _arc_pts(Vector2(700, 460), 40, 90, 270, step, true)
		arc.remove_at(0)
		p.append_array(arc)
		p.append(Vector2(1100, 420))
		rows.append(["шпилька R40 шагом %.0f° (целые)" % step, p, true])
	var r300 := PackedVector2Array([Vector2(0, 0)])
	var chord := 2.0 * 300.0 * sin(deg_to_rad(3.0))
	var arc3 := _arc(Vector2(100, 0), deg_to_rad(3.0), 6.0, chord, 30)
	r300.append_array(arc3)
	r300.append(arc3[-1] + Vector2(-50, 0))
	r300.append(r300[-1] + Vector2.from_angle(deg_to_rad(240.0)) * 150)
	rows.append(["мягкая дуга R300 на 180° и угол 60° через 50 px", r300, true])
	var fine := PackedVector2Array([Vector2(0, 0)])
	fine.append_array(_arc(Vector2(200, 0), 0.0, 0.9, 1.0, 100))
	fine.append(fine[-1] + Vector2.from_angle(deg_to_rad(90.0)) * 30)
	fine.append(fine[-1] + Vector2(-300, 0))
	rows.append(["дуга 100×0,9° по 1 px и угол 90° через 30 px", fine, true])
	var zig := PackedVector2Array([Vector2(0, 0)])
	for i in 10:
		zig.append(zig[-1] + Vector2.from_angle(deg_to_rad(15.0 if i % 2 == 0 else -15.0)) * 30)
	rows.append(["зигзаг ±30° через 30 px", zig, false])
	return rows


## verifier-3 27.09: У-7 по зонам поворота (PgTurns) — вся таблица случаев.
func _turn_cases() -> void:
	for row: Array in _turn_table():
		var bad := _sharp(row[1])
		print("   У-7 %-48s → %s" % [row[0], "нарушение" if bad else "годно"])
		_check(bad == bool(row[2]), "У-7: %s — %s" % [row[0], "нарушение" if row[2] else "годно"])


## verifier-3 27.09: число, раздувающее цикл, — «Словарь: …»; счёт встречи с пределом шагов.
func _loop_bounds() -> void:
	var cases := {
		"at группы −1e9": func(m: Dictionary) -> void: m.waves[0].groups[0]["at"] = -1.0e9,
		"at трещины 1e9": func(m: Dictionary) -> void:
			m.breaches = [{"id": "b", "road": "main", "at": 1.0e9}],
		"delay 1e9": func(m: Dictionary) -> void: m.waves[0].groups[0].delay = 1.0e9,
		"interval 1e9": func(m: Dictionary) -> void: m.waves[0].groups[0].interval = 1.0e9,
		"pause 1e9": func(m: Dictionary) -> void: m.waves[1].pause = 1.0e9,
		"next_in −1e9": func(m: Dictionary) -> void: m.waves[0]["next_in"] = -1.0e9,
		"count 1e18": func(m: Dictionary) -> void: m.waves[0].groups[0].count = 1.0e18,
		"count 5001": func(m: Dictionary) -> void: m.waves[0].groups[0].count = 5001,
		"elite 1e9": func(m: Dictionary) -> void: m.waves[0].groups[0]["elite"] = 1.0e9,
		"w стены 1e9": func(m: Dictionary) -> void:
			m.walls = [{"path": [[100, 100], [200, 100]], "w": 1.0e9}],
		"вид врага не из FOES": func(m: Dictionary) -> void:
			m.waves[0].groups[0].type = "dragon",
	}
	for name: String in cases:
		var map := _base()
		cases[name].call(map)
		var t0 := Time.get_ticks_usec()
		var problems := PgFilter.check(map)
		var ms := (Time.get_ticks_usec() - t0) / 1000.0
		_check(_has_rule(problems, "Словарь:") and ms < HEAVY_LIMIT_MS,
			"%s → «Словарь: …» без зависания (%.1f мс)" % [name, ms])
	var m := _base()
	m.waves[0].groups[0]["at"] = -90000.0
	var t0 := Time.get_ticks_usec()
	var problems := PgFilter.check(m)
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	_check(_has_rule(problems, "Фильтр:", "У-10") and ms < HEAVY_LIMIT_MS,
		"at −90000 (в пределах чисел): счёт встречи упёрся в предел шагов → «Фильтр: …» (%.1f мс)"
		% ms)


## verifier-2 27.09: битые ЗНАЧЕНИЯ — «Словарь: …», а не SCRIPT ERROR и «годна».
func _bad_values() -> void:
	var cases := {
		"breach.at массивом": func(m: Dictionary) -> void:
			m.breaches = [{"id": "b", "road": "main", "at": [1, 2]}],
		"breach.at строкой": func(m: Dictionary) -> void:
			m.breaches = [{"id": "b", "road": "main", "at": "abc"}],
		"count массивом": func(m: Dictionary) -> void: m.waves[0].groups[0].count = [],
		"count строкой": func(m: Dictionary) -> void: m.waves[0].groups[0].count = "x",
		"count 0": func(m: Dictionary) -> void: m.waves[0].groups[0].count = 0,
		"pause массивом": func(m: Dictionary) -> void: m.waves[1].pause = [],
		"delay массивом": func(m: Dictionary) -> void: m.waves[0].groups[0].delay = [],
		"at группы массивом": func(m: Dictionary) -> void: m.waves[0].groups[0]["at"] = [],
		"elite массивом": func(m: Dictionary) -> void: m.waves[0].groups[0]["elite"] = [],
		"next_in массивом": func(m: Dictionary) -> void: m.waves[0]["next_in"] = [],
		"climax строкой": func(m: Dictionary) -> void: m.waves[1]["climax"] = "yes",
		"procgen массивом": func(m: Dictionary) -> void: m.procgen = [],
		"card строкой": func(m: Dictionary) -> void: m.procgen = {"card": "x"},
		"quirks строкой": func(m: Dictionary) -> void: m.procgen = {"card": {"quirks": "throat"}},
		"archetype числом": func(m: Dictionary) -> void: m.procgen = {"card": {"archetype": 5}},
		"throat массивом": func(m: Dictionary) -> void:
			m.procgen = {"card": {"quirks": ["throat"]}, "throat": []},
		"throat.roads null": func(m: Dictionary) -> void:
			m.procgen = {"card": {"quirks": ["throat"]},
				"throat": {"roads": null, "from": 1, "to": 50}},
		"throat.roads строкой": func(m: Dictionary) -> void:
			m.procgen = {"card": {"quirks": ["throat"]},
				"throat": {"roads": "main", "from": 680, "to": 800}},
		"throat.pos строкой": func(m: Dictionary) -> void:
			m.procgen = {"card": {"quirks": ["throat"]},
				"throat": {"road": "main", "from": 1, "to": 50, "pos": "x"}},
		"throat.from массивом": func(m: Dictionary) -> void:
			m.procgen = {"card": {"quirks": ["throat"]}, "throat": {"road": "main", "from": [], "to": 50}},
		"пролёт без id": func(m: Dictionary) -> void:
			m.flights = [{"road": 5, "path": [[1, 2], [3, 4]]}],
		"biome массивом": func(m: Dictionary) -> void:
			m.merge({"procgen": {"card": {"quirks": ["coffee"]}}, "biome": []}, true),
		"две дороги с одним id": func(m: Dictionary) -> void:
			m.roads.append(m.roads[0].duplicate(true)),
		"координата 1e7": func(m: Dictionary) -> void: m.roads[0].path[0] = [1.0e7, 360],
		"дорога из одной точки дважды": func(m: Dictionary) -> void:
			m.roads[0].path = [[500, 500], [500, 500]],
	}
	for name: String in cases:
		var map := _base()
		cases[name].call(map)
		_check(_has_rule(PgFilter.check(map), "Словарь:"), "битое значение (%s) → «Словарь: …»" % name)
	var dup := _base()
	dup.roads[0].path.insert(3, [1000, 180])
	var dup_problems := PgFilter.check(dup)
	_check(not _has_rule(dup_problems, "У-7:", "сама себя"),
		"повтор вершины подряд — не «пересекает себя»")
	_check(dup_problems.is_empty(), "…и карта с повтором вершины годна, как без него")
	_check(PgFilter.check({}).size() > 0 and PgFilter.score({}) == 1.0,
		"пустой словарь: нарушение и штраф 1")
