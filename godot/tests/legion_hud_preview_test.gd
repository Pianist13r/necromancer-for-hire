extends SceneTree
##
## Регресс панели превью волны 27.09.2026 (worktree hud-preview, B-203…B-205): панель растягивалась
## под составом волны и закрывала правые ворота (генератор процгена резервирует под HUD только
## y 0–200 — docs/procgen/BOOK.md). Проверяем нижний край панели ≤ 200 px при любом составе:
## синтетический максимум (7 видов × 3 дороги), синтетические 1–2 дороги, и КАЖДАЯ волна всех
## восьми карт кампании — без запуска боя, чтением wr.waves напрямую.
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_hud_preview_test.gd -- --mute
##
## Итог «LEGION HUD PREVIEW: N/M OK»; код выхода 1, если что-то упало. Сохранение временное.
##

const SAVE := "user://legion_hud_preview_test.cfg"
## Нижний край панели не должен закрывать резерв генератора под правые ворота (y 0–200) — 200
## есть предел из задачи, не собственная константа панели. Верх панели — WAVE_PREVIEW_POS.y (64:
## над ней в правом верхнем углу стоит кликабельная «❚❚ Пауза»), поэтому бюджет панели 136 px.
const MAX_BOTTOM := 200.0
## Все восемь карт кампании (без служебных _plots/_gray — они не входят в кампанию).
const CAMPAIGN_MAPS := ["archive", "boss", "bridge", "fork", "gatehouse", "maze", "swamp",
	"wasteland"]

var w: LegionWorld
var _fails := 0
var _checks := 0


func _initialize() -> void:
	_run.call_deferred()


func _check(cond: bool, what: String) -> void:
	_checks += 1
	if cond:
		print("  ok   ", what)
	else:
		_fails += 1
		print("  FAIL ", what)


func _run() -> void:
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	w = scene.instantiate() as LegionWorld
	root.add_child(w)
	await process_frame
	w.set_process(false)
	w.dev["no_waves"] = "1"
	w.dev["spawn_units"] = "0"
	w.start_map("fork")
	await process_frame
	await _test_synthetic_max()
	await _test_synthetic_two_gates()
	await _test_campaign_waves()
	Campaign.reset()
	print("LEGION HUD PREVIEW: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


## Полтора десятка строк по-старому (7 видов × 3 дороги, «сев./вост./юж.» на каждую) уводили
## нижний край панели до 493 px (задача B-203) — крайний случай кампании специально утрирован.
func _test_synthetic_max() -> void:
	print("— синтетический максимум: 7 видов × 3 дороги")
	var types := ["zombie", "beetle", "signer", "ghost", "boss", "shield_inspector", "lawyer"]
	var roads := ["north", "south", "east"]
	var groups: Array[Dictionary] = []
	for t in types:
		for r in roads:
			groups.append({"type": t, "road": r, "count": 12})
	_set_synthetic_wave(groups)
	await process_frame
	var rect := w.hud._preview.get_global_rect()
	_check(rect.position.y + rect.size.y <= MAX_BOTTOM,
		"нижний край %d px ≤ %d" % [roundi(rect.position.y + rect.size.y), int(MAX_BOTTOM)])
	var lines := w.hud._preview_text.text.split("\n")
	_check(lines.size() == 1 + LegionCfg.WAVE_PREVIEW_MAX_KINDS + 1,
		"строк %d = заголовок + %d видов + «+ ещё»" % [lines.size(), LegionCfg.WAVE_PREVIEW_MAX_KINDS])
	_check(w.hud._preview_text.text.contains("+ ещё 2 вид"), "хвост списка видов свёрнут")
	# Три дороги — короткие "вост."/"сев." не помещаются рядом со счётом, вместо них буквы.
	_check(w.hud._preview_text.text.contains("(с·в·ю)") or
		w.hud._preview_text.text.contains("(с·ю·в)") or
		w.hud._preview_text.text.contains("(в·с·ю)") or
		w.hud._preview_text.text.contains("(в·ю·с)") or
		w.hud._preview_text.text.contains("(ю·с·в)") or
		w.hud._preview_text.text.contains("(ю·в·с)"),
		"три дороги — однобуквенные метки у вида")
	_check(not w.hud._preview_text.text.contains("вост."),
		"полных коротких названий нет при 3 дорогах")


## Две дороги — вернулась сводная строка воротами (B-204), без переносов и с прежним потолком.
func _test_synthetic_two_gates() -> void:
	print("— синтетические 2 дороги")
	_set_synthetic_wave([
		{"type": "zombie", "road": "north", "count": 20},
		{"type": "zombie", "road": "south", "count": 16},
	])
	await process_frame
	var rect := w.hud._preview.get_global_rect()
	_check(rect.position.y + rect.size.y <= MAX_BOTTOM,
		"нижний край %d px ≤ %d" % [roundi(rect.position.y + rect.size.y), int(MAX_BOTTOM)])
	var text := w.hud._preview_text.text
	_check(text.contains("Зомби ×36"), "строка вида — сумма по воротам, без разбивки внутри")
	_check(text.contains("[font_size=%d]" % LegionCfg.WAVE_PREVIEW_GATE_FONT),
		"мелкая подпись воротами — уменьшенным шрифтом")
	_check(text.contains("сев. ×20") and text.contains("юж. ×16"), "подпись — счёт по каждым воротам")


## Каждая волна каждой из восьми карт кампании — читаем wr.waves напрямую, без боя и таймеров.
func _test_campaign_waves() -> void:
	print("— все волны восьми карт кампании")
	w.dev.erase("no_waves")  # иначе wave_runner.setup() получает пустую карту и total()==0
	for map_id in CAMPAIGN_MAPS:
		w.start_map(map_id)
		# Индекс волны двигаем напрямую, минуя _start(): _runs у настоящего wr пуст, и
		# can_call() падает по пустому массиву на человеческом вводе — start_map взводит его
		# заново, поэтому глушим после каждой карты, а не один раз до цикла.
		w.contracts.human_input = false
		await process_frame
		var wr := w.wave_runner
		_check(wr != null and wr.total() > 0, "%s: волны загружены" % map_id)
		if wr == null:
			continue
		for i in wr.total():
			wr.index = i - 1
			w.hud._update_preview()
			await process_frame
			var rect := w.hud._preview.get_global_rect()
			var bottom := rect.position.y + rect.size.y
			_check(bottom <= MAX_BOTTOM, "%s волна %d/%d: нижний край %d px ≤ %d" %
				[map_id, i + 1, wr.total(), roundi(bottom), int(MAX_BOTTOM)])


## Подсовывает волне синтетический состав групп напрямую в WaveRunner (без спавна и таймеров) —
## next_wave_groups() читает waves[index+1], index=-1 указывает на неё как на «следующую».
func _set_synthetic_wave(groups: Array[Dictionary]) -> void:
	var wr := WaveRunner.new()
	wr.world = w
	wr.waves = [{"pause": 10, "next_in": 40, "groups": groups}]
	wr.index = -1
	wr.phase = WaveRunner.Phase.PAUSE
	w.wave_runner = wr
	w.hud._update_preview()
