extends SceneTree
##
## Регресс slow/keys-texts (08.10.2026, постановка Игоря: «обучение не всегда совпадает с тем,
## что есть по факту, особенно если мы переназначаем клавиши»; аудит docs/dev/audit-1008/
## tutorial_keys.md, KB-01…KB-11, TU-01…TU-09).
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_keys_text_test.gd -- --mute
##
## Переназначает почти всю клавиатуру (Ку→Z, Дубль-вэ→X, Е→C, Эр→T, волна→H, Касса→K, стрелка→G,
## Таб→B, виды 1/2/3→4/5/6, пауза→O) и проверяет, что ни подпись слота, ни тосты HUD и мира,
## ни брифинг («Новое: …» и hint карты), ни уроки и их подсказки, ни «Как играть», ни Досье и
## карточки поправок не называют старую клавишу; Controls.text раскрывает токены {key:…}, не
## задваивает «Ку (Q)», подставляет одиночные цифры видов. Линтер: ни одна строка игровых
## текстов не называет клавишу литералом мимо токена (кроме моста — файлов других потоков, их
## вывод проверяется здесь же через сток). Итог «LEGION KEYS TEXT: N/M OK»; код выхода 1.
## Сохранение и настройки — свои временные файлы (сохранения владельца не трогает).
##

const SAVE := "user://legion_keys_text_test.cfg"
const SETTINGS := "user://legion_keys_text_test_settings.cfg"
const FPS := 60.0
const CONTROLS_PATH := "res://scripts/common/controls.gd"
const TUTORIAL_PATH := "res://scripts/legion/legion_tutorial.gd"
const ABILITY_BAR_PATH := "res://scripts/legion/ui/ability_bar.gd"
const LESSON_MAPS := ["wasteland", "gatehouse", "fork", "bridge", "archive", "swamp", "maze", "boss"]
## Переназначение для всего теста: ни одна новая клавиша не совпадает со штатной другого действия.
const REMAP := {&"cast_q": KEY_Z, &"cast_w": KEY_X, &"cast_e": KEY_C, &"rally": KEY_T,
	&"call_wave": KEY_H, &"kassa": KEY_K, &"aim_contract": KEY_G, &"erase_piece": KEY_B,
	&"rune_normal": KEY_4, &"rune_frost": KEY_5, &"rune_ash": KEY_6, &"pause": KEY_O}
## Старая клавиша как слово: кириллические имена, буква в скобках, связка видов, цифра вида после
## «нажмите»/«линия —», не раскрытый токен.
const STALE := ("(?<![\\p{L}\\p{N}])(?:Ку|Дубль-вэ|Е|Эр|Эф|Дэ|Пэ|Пробел\\p{L}*|Таб|Табом"
	+ "|\\([QWERFDЕ]\\)|1/2/3)(?![\\p{L}\\p{N}])|[Нн]ажмите [123](?!\\p{N})"
	+ "|линия — [123](?!\\p{N})|\\{(?:keys?\\+?|cap):")
## «Z (Z)» — слово и буква в скобках заменились независимо (KB-05).
const DOUBLED := "(?<![\\p{L}\\p{N}])(\\p{L}+) \\(\\1\\)"

var w: LegionWorld
var _fails := 0
var _checks := 0
var _toasts: Array[String] = []
var _stale := RegEx.new()
var _doubled := RegEx.new()


func _initialize() -> void:
	_run.call_deferred()


func _check(cond: bool, what: String) -> void:
	_checks += 1
	if cond:
		print("  ok   ", what)
	else:
		_fails += 1
		print("  FAIL ", what)


func _frames(n: int) -> void:
	for i in n:
		await process_frame


func _on_toast(text: String, _kind: StringName) -> void:
	_toasts.append(text)


## Вызов статической функции, которой в старом коде нет: без неё — null и FAIL, не обрыв теста.
func _static(path: String, method: String, args: Array = []) -> Variant:
	var scr: Script = load(path)
	for m: Dictionary in scr.get_script_method_list():
		if String(m["name"]) == method:
			return scr.callv(method, args)
	print("  (нет %s.%s)" % [path.get_file(), method])
	return null


## Первое устаревшее имя клавиши в тексте ("" — нет).
func _stale_in(text: String) -> String:
	var hit := _stale.search(text)
	if hit != null:
		return hit.get_string()
	hit = _doubled.search(text)
	return hit.get_string() if hit != null else ""


func _clean(text: String, what: String) -> void:
	var bad := _stale_in(text)
	_check(bad == "", "%s: нет старой клавиши%s" % [what, "" if bad == "" else " — «%s» в «%s»"
		% [bad, text.substr(maxi(0, text.find(bad) - 40), 100).replace("\n", " ")]])


func _collect(n: Node, out: PackedStringArray) -> void:
	if n is Label:
		out.append((n as Label).text)
	elif n is RichTextLabel:
		out.append((n as RichTextLabel).get_parsed_text())
	elif n is Button:
		out.append((n as Button).text)
	for c in n.get_children():
		_collect(c, out)


func _ui_text(n: Node) -> String:
	var out := PackedStringArray()
	_collect(n, out)
	return "\n".join(out)


func _remap() -> void:
	Controls.reset()
	for action: StringName in REMAP:
		var err := Controls.rebind(action, int(REMAP[action]))
		if not err.is_empty():
			print("  rebind %s: %s" % [action, err])
	var ok := true
	for action: StringName in REMAP:
		ok = ok and Controls.key(action) == int(REMAP[action])
	_check(ok, "раскладка переназначена целиком (%d действий)" % REMAP.size())


func _run() -> void:
	_stale.compile(STALE)
	_doubled.compile(DOUBLED)
	Settings.path = SETTINGS
	Settings._cfg = ConfigFile.new()
	Settings.apply()
	Campaign.set_save_path(SAVE)
	Campaign.reset()
	root.size = Vector2i(1280, 720)
	_test_defaults()
	_remap()
	_test_text_unit()
	_test_slot_names()
	_test_static_texts()
	_test_lint()
	_test_voice()
	var scene: PackedScene = load("res://scenes/legion_world.tscn")
	w = scene.instantiate() as LegionWorld
	w.embedded = true
	root.add_child(w)
	w.toast_posted.connect(_on_toast)
	await _frames(2)
	await _test_toasts()
	await _test_lessons()
	await _test_banner_refresh()
	await _test_figure_marks()
	await _test_line_keeps()
	await _test_briefing()
	await _test_howto()
	await _test_cards()
	_test_swap_once()
	await _test_swap_ui()
	_test_layout()
	Controls.reset()
	Settings.scheme_override = ""
	Campaign.reset()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SETTINGS))
	print("LEGION KEYS TEXT: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


# ── 0. Штатная раскладка: текст как написан ────────────────────────────────────

func _test_defaults() -> void:
	print("— штатная раскладка: проза и токены")
	_check(Controls.text("Esc / П — пауза") == "Esc / П — пауза",
		"KB-10: «П» на штатной раскладке остаётся «П» (было «P»): %s" % Controls.text("Esc / П — пауза"))
	_check(Controls.text("Зажмите Ку (Q) у врага") == "Зажмите Ку (Q) у врага",
		"«Ку (Q)» на штатной раскладке не трогается")
	var tokens := "{key+:cast_q} · {key:rally} ({cap:rally}) · {keys:runes} · {key:pause}"
	_check(Controls.text(tokens) == "Ку (Q) · Эр (R) · 1/2/3 · Пэ",
		"токены на штатной раскладке: %s" % Controls.text(tokens))


# ── 1. Controls.text: токены, пары, цифры, склонение ──────────────────────────

func _test_text_unit() -> void:
	print("— Controls.text после переназначения")
	var cases := {
		"{key:cast_q}": "Z",
		"{key+:cast_w} у трупов": "X у трупов",
		"«Сбор» ({cap:rally})": "«Сбор» (T)",
		"Зажмите Ку (Q) у врага": "Зажмите Z у врага",
		"«Сбор»: Эр (R)": "«Сбор»: T",
		"Аврал (Е) дольше": "Аврал (C) дольше",
		"Здесь нужен Подряд — нажмите 1 и ведите": "Здесь нужен Подряд — нажмите 4 и ведите",
		"(их линия — 2)": "(их линия — 5)",
		"(его линия — 3)": "(его линия — 6)",
		"клавиши 1/2/3 — вид": "клавиши 4/5/6 — вид",
		"поверните стрелку Пробелом": "поверните стрелку клавишей G",
		"3 души, ×2, 12 с, до 3 целей": "3 души, ×2, 12 с, до 3 целей",
		"Esc / П — пауза": "Esc / O — пауза",
		"Касса (Дэ)": "Касса (K)",
		"F (или N)": "H",
		"{key:nope}": "{key:nope}",
	}
	for src: String in cases:
		var got := Controls.text(src)
		_check(got == cases[src], "«%s» → «%s» (ждём «%s»)" % [src, got, cases[src]])


# ── 2. KB-01: подпись под слотом способности ─────────────────────────────────

func _test_slot_names() -> void:
	print("— KB-01: подпись под слотами Q/W/E")
	var names: Array = []
	for i in 3:
		names.append(_static(ABILITY_BAR_PATH, "slot_name", [i]))
	_check(names == ["Z", "X", "C"], "подписи под слотами — текущие клавиши: %s" % str(names))


# ── 3. Статические тексты, которые выводятся через сток ────────────────────────

func _test_static_texts() -> void:
	print("— тексты уроков, кульминации, шпаргалки")
	for map_id: String in LESSON_MAPS:
		var map := LegionWorld.load_map(map_id)
		_clean(Controls.text(String(map.get("hint", ""))), "%s: hint" % map_id)
		for l in LegionTutorial.parse(map):
			_clean(Controls.text(String(l["text"])), "%s/%s: урок" % [map_id, l["id"]])
	var hint := LegionChallenge.answer_hint([{"type": "shield_inspector"}, {"type": "ghost"}])
	_clean(hint, "подсказка кульминации (KB-08)")
	_check(hint.contains("C") and hint.contains("Z"), "кульминация называет C и Z: %s" % hint)
	_clean("\n".join(LegionPause.cheatsheet()), "шпаргалка паузы")
	var mini := {}
	for l in LegionTutorial.parse(LegionWorld.load_map("maze")):
		if l["id"] == &"mini":
			mini = l
	_check(not mini.is_empty() and mini["kind"] == &"figure_ult" and String(mini["arg"]) == "mini",
		"TU-03: урок «мини» зачитывает срыв заряженной мини-фигуры (figure_ult:mini), а не контур")
	var hints_src := FileAccess.get_file_as_string("res://scripts/legion/legion_map_hints.gd")
	var ty := RegEx.create_from_string("(?<![\\p{L}])(Заходи|добей|Поставь|щёлкни|сорви|подними) ")
	var hit := ty.search(hints_src)
	_check(hit == null, "TU-07: разовые подсказки на «вы» (B-080)%s"
		% ("" if hit == null else " — «%s»" % hit.get_string()))


# ── 4. Линтер: клавиша в игровом тексте — только токеном или через мост ───────────

## Файлы, где имя клавиши литералом законно: таблица Controls, dev-инструменты, ролик (Пробел
## там — физическая клавиша, не действие). МОСТ — прозу этих файлов правят другие потоки; она
## проходит сток Controls.text (проверено ниже на экранах), перевод на токены — за ними.
const LINT_ALLOW := {
	"scripts/common/controls.gd": "таблица имён",
	"scripts/legion/ui/legion_cutscene.gd": "Пробел ролика не переназначается",
	"scripts/legion/amendment_db.gd": "МОСТ: поправки (поток прокачки)",
	"scripts/legion/campaign.gd": "МОСТ: «Новое: …» (поток кампании)",
	"scripts/legion/run_progression.gd": "МОСТ: «… появится на …» (поток прокачки)",
	"scripts/legion/ui/howto_legion.gd": "МОСТ: «Как играть» (поток прокачки)",
}
const LINT := ("(?<![\\p{L}\\p{N}])(?:Ку|Дубль-вэ|Е|Эр|Эф|Дэ|Пэ|Шифт|Пробел\\p{L}*|Таб|Табом"
	+ "|\\([QWERFDПЕ]\\)|1/2/3)(?![\\p{L}\\p{N}])|[Нн]ажмите [123](?!\\p{N})|линия — [123](?!\\p{N})")


## Содержимое строковых литералов строки .gd (комментарий после # вне кавычек отброшен).
static func _literals(line: String) -> PackedStringArray:
	var out := PackedStringArray()
	var i := 0
	while i < line.length():
		var ch := line[i]
		if ch == "#":
			break
		if ch == "\"" or ch == "'":
			var j := i + 1
			var buf := ""
			while j < line.length() and line[j] != ch:
				if line[j] == "\\":
					buf += line.substr(j, 2)
					j += 2
					continue
				buf += line[j]
				j += 1
			out.append(buf)
			i = j + 1
			continue
		i += 1
	return out


func _lint_dir(dir: String, re: RegEx, hits: PackedStringArray) -> void:
	for f in DirAccess.get_files_at(dir):
		var path := dir.path_join(f)
		var rel := path.trim_prefix("res://")
		if LINT_ALLOW.has(rel):
			continue
		if f.ends_with(".gd"):
			var n := 0
			for line in FileAccess.get_file_as_string(path).split("\n"):
				n += 1
				for lit in _literals(line):
					var m := re.search(lit)
					if m != null:
						hits.append("%s:%d «%s»" % [rel, n, m.get_string()])
		elif f.ends_with(".json"):
			var n := 0
			for line in FileAccess.get_file_as_string(path).split("\n"):
				n += 1
				var m := re.search(line)
				if m != null:
					hits.append("%s:%d «%s»" % [rel, n, m.get_string()])
	for d in DirAccess.get_directories_at(dir):
		if d == "dev":
			continue   # инструменты разработчика: сообщения агенту, не игроку
		_lint_dir(dir.path_join(d), re, hits)


func _test_lint() -> void:
	print("— линтер: клавиши в текстах — токеном {key:…} (KB-01…KB-08)")
	var re := RegEx.create_from_string(LINT)
	var hits := PackedStringArray()
	_lint_dir("res://scripts", re, hits)
	_lint_dir("res://assets/legion/maps", re, hits)
	_check(hits.is_empty(), "голых клавиш вне токенов нет (%d)%s" % [hits.size(),
		"" if hits.is_empty() else ":\n      " + "\n      ".join(hits)])
	# неизвестное действие в токене — опечатка, игрок увидит фигурные скобки
	var tok := RegEx.create_from_string("\\{(key\\+?|keys|cap):([a-z_]+)\\}")
	var bad := PackedStringArray()
	for path in ["res://scripts", "res://assets/legion/maps"]:
		_scan_tokens(path, tok, bad)
	_check(bad.is_empty(), "все токены называют настоящие действия%s"
		% ("" if bad.is_empty() else ": " + ", ".join(bad)))


func _scan_tokens(dir: String, tok: RegEx, bad: PackedStringArray) -> void:
	for f in DirAccess.get_files_at(dir):
		if not (f.ends_with(".gd") or f.ends_with(".json")):
			continue
		for m in tok.search_all(FileAccess.get_file_as_string(dir.path_join(f))):
			var ok := StringName(m.get_string(2)) in Controls.ACTIONS if m.get_string(1) != "keys" \
				else m.get_string(2) == "runes"
			if not ok:
				bad.append("%s %s" % [f, m.get_string()])
	for d in DirAccess.get_directories_at(dir):
		_scan_tokens(dir.path_join(d), tok, bad)


# ── 5. Голос уроков (KB-07, TU-01, TU-04) ─────────────────────────────────────

func _test_voice() -> void:
	print("— голос уроков: реплика с переназначенной клавишей молчит")
	_check(_static(TUTORIAL_PATH, "voice_muted", [&"lg_tut_4"]) == true,
		"KB-07: «нажмите Ку» молчит, когда Ку переназначена")
	_check(_static(TUTORIAL_PATH, "voice_muted", [&"lg_tut_1"]) == false,
		"реплика без клавиш звучит (lg_tut_1)")
	_check(_static(TUTORIAL_PATH, "voice_muted", [&"lg_tut_stun"]) == true,
		"TU-01: «в полтора раза» молчит до переозвучки (STALE_VOICE)")
	_check(_static(TUTORIAL_PATH, "voice_muted", [&"lg_tut_item"]) == true,
		"TU-04: «до конца боя» молчит до переозвучки (STALE_VOICE)")
	# линтер голоса: реплика lg_tut_*, называющая клавишу, обязана быть в LessonsCfg.VOICE_KEYS
	var tsv := ProjectSettings.globalize_path("res://").path_join("../tools/voice/lines.tsv")
	var re := RegEx.create_from_string("(?<![\\p{L}])(Ку|Дубль-вэ|Е|Эр|Эф|Дэ|Таб|[Пп]робел\\p{L}*)"
		+ "(?![\\p{L}])")
	var cfg: GDScript = load("res://scripts/legion/lessons_cfg.gd")
	var keys: Dictionary = cfg.get_script_constant_map().get("VOICE_KEYS", {})
	var missing := PackedStringArray()
	for line in FileAccess.get_file_as_string(tsv).split("\n"):
		var cols := line.split("\t")
		if cols.size() < 3 or not cols[0].begins_with("lg_tut"):
			continue
		if re.search(cols[2]) != null and not keys.has(StringName(cols[0])):
			missing.append(cols[0])
	_check(missing.is_empty(), "все реплики с клавишами учтены в LessonsCfg.VOICE_KEYS%s"
		% ("" if missing.is_empty() else ": " + ", ".join(missing)))


# ── 6. Тосты: один сток в HUD, без двойной подстановки ─────────────────────────

func _hud_last() -> String:
	var box: Node = w.hud.get("_toasts")
	if box == null or box.get_child_count() == 0:
		return ""
	return _ui_text(box.get_child(box.get_child_count() - 1))


func _test_toasts() -> void:
	print("— KB-02: тосты мира и HUD")
	w.dev = {"no_waves": "1"}
	w.in_campaign = false
	_toasts.clear()
	w.start_map("gatehouse")
	await _frames(2)
	var intro := ""
	for t in _toasts:
		if t.contains("Вахтёров"):
			intro = t
	_check(intro != "", "вводный тост «Проходной» с hint карты есть")
	_clean(intro, "вводный тост карты")
	_check(intro.contains("клавишей G") and intro.contains("(T)"), "вводный тост: G и T — %s" % intro)
	w.toast("Строй его не трогает: Ку сорвёт зачитку", &"info")
	_check(_hud_last() == "Строй его не трогает: Z сорвёт зачитку",
		"тост HUD через сток: %s" % _hud_last())
	_check(_toasts.back() == "Строй его не трогает: Z сорвёт зачитку",
		"toast_posted несёт то же, что видит игрок: %s" % _toasts.back())


# ── 7. Уроки: плашка, подсказки промахов, ×2 оглушённых ────────────────────────

func _start(map_id: String) -> LegionTutorial:
	Campaign.reset()
	Campaign.unlock_all()
	w.in_campaign = true
	w.dev = {"difficulty": "intern", "no_waves": "1"}
	w.args.erase("bot")
	w.start_map(map_id)
	w.start_lessons(true)
	var tut := w.tutorial
	await _frames(2)
	return tut


func _banner_text(tut: LegionTutorial) -> String:
	var banner: Node = tut.get("_banner")
	if banner == null or not is_instance_valid(banner):
		return ""
	var label: Label = banner.get("_label")
	return label.text if label != null else ""


func _test_lessons() -> void:
	print("— уроки после переназначения")
	for map_id: String in LESSON_MAPS:
		var tut := await _start(map_id)
		if tut == null:
			_check(false, "%s: уроки не стартовали" % map_id)
			continue
		for i in tut.lessons.size():
			_clean(tut.step_text(i), "%s/%s: плашка" % [map_id, tut.lessons[i]["id"]])
		_clean(_banner_text(tut), "%s: плашка на экране" % map_id)
	var tut := await _start("bridge")
	var stun := tut.step_text(tut.index_of(&"stun_hit"))
	var mult := ("%.1f" % LegionCfg.STUNNED_CHARGE_MULT).replace(".", ",").trim_suffix(",0")
	_check(stun.contains("×" + mult + ".") and not stun.contains("1,5"),
		"TU-01: урок «оглушённые» называет множитель LegionCfg ×%s: %s" % [mult, stun])
	tut = await _start("wasteland")
	_toasts.clear()
	tut.call("_hint", LegionTutorial.HINT_KIND)
	_check(not _toasts.is_empty() and _toasts.back().contains("нажмите 4"),
		"KB-04: подсказка промаха «нажмите 4»: %s" % (_toasts.back() if not _toasts.is_empty() else "—"))
	_clean(_hud_last(), "подсказка промаха урока в HUD")


## KB-06: настройки открыты поверх паузы посреди урока — после смены клавиши плашка новая.
func _test_banner_refresh() -> void:
	print("— KB-06: плашка урока после смены клавиши")
	var tut := await _start("gatehouse")
	var before := _banner_text(tut)
	_check(before.contains(" G "), "урок стрелки: «G» на плашке — %s" % before)
	Controls.rebind(&"aim_contract", KEY_V)
	tut.tick(1.0 / FPS)
	await _frames(1)
	var after := _banner_text(tut)
	_check(after.contains(" V ") and not after.contains(" G "),
		"после переназначения посреди урока плашка говорит «V»: %s" % after)
	Controls.rebind(&"aim_contract", KEY_G)


# ── 8. TU-02: шаблон фигуры у всех уроков-фигур ────────────────────────────────

func _test_figure_marks() -> void:
	print("— TU-02: шаблон фигуры на поле")
	for pair in [["maze", &"pentagon"], ["maze", &"mini"], ["swamp", &"square"],
			["bridge", &"triangle"], ["boss", &"sling_one"]]:
		var tut := await _start(pair[0])
		tut.force_lesson(pair[1])
		await _frames(1)
		var marks: Node = tut.get("_marks")
		var shows: Variant = marks.call("shows_template") \
			if marks != null and marks.has_method("shows_template") else null
		_check(shows == true and tut.figure_points().size() >= 2,
			"%s/%s (%s): шаблон «где чертить» рисуется" % [pair[0], pair[1], tut.step_kind()])


# ── 9. TU-09 / B-127: на «Пустыре» урок «Точно!» держит линию ─────────────────────

func _test_line_keeps() -> void:
	print("— B-127: «Точно!» на «Пустыре» — линия не тает")
	var tut := await _start("wasteland")
	tut.force_lesson(&"perfect")
	await _frames(1)
	var worst := 0.0
	var alive := 0
	for i in roundi(60.0 * FPS):
		w._step(1.0 / FPS)
		if i % 60 != 59:
			continue
		alive = 0
		for c in w.contracts.contracts:
			for s in c.seg_count():
				if c.seg_alive(s):
					alive += 1
					worst = maxf(worst, c.seg_age[s] / c.ttl)
	_check(tut.active and tut.step_id() == &"perfect", "урок «Точно!» всё ещё идёт (60 с без выпуска)")
	_check(alive > 0 and worst <= LegionTutorial.LINE_AGE_CAP + 0.05,
		"за 60 с живых участков %d, худший возраст %.2f срока (≤ %.2f)"
		% [alive, worst, LegionTutorial.LINE_AGE_CAP])


# ── 10. KB-03: брифинг — hint карты и «Новое: …» ───────────────────────────────

func _test_briefing() -> void:
	print("— KB-03: брифинг")
	Campaign.reset()
	Campaign.unlock_all()
	var pending := Campaign.pending_unlock_labels()
	var b := Briefing.new()
	root.add_child(b)
	b.populate(LegionWorld.load_map("gatehouse"))
	await _frames(1)
	var text := _ui_text(b)
	_check(pending.size() >= 4 and text.contains("Новое:"), "плашка «Новое» показана (%d)" % pending.size())
	_clean(text, "брифинг «Проходной»")
	_check(text.contains("«Сбор»: T") and text.contains("Навык X"),
		"«Новое»: «Сбор» на T, навык на X")
	b.queue_free()
	Campaign.reset()


# ── 11. «Как играть» (мост) ───────────────────────────────────────────────────

func _test_howto() -> void:
	print("— «Как играть» после переназначения")
	var howto := HowtoLegion.new()
	root.add_child(howto)
	await _frames(2)
	var text := _ui_text(howto)
	_clean(text, "«Как играть»")
	_check(text.contains("Z — молния"), "«Как играть»: «Z — молния…» без «Z (Z)»")
	howto.queue_free()
	await _frames(1)


# ── 12. KB-08: Досье, карточки поправок ───────────────────────────────────────

func _test_cards() -> void:
	print("— KB-08: Досье и карточки поправок")
	var dv := DossierView.new()
	root.add_child(dv)
	dv.configure(null, DossierView.TAB_ITEMS)
	for id in LegionItemDb.ids():
		dv.add_child(dv.call("_card", id))
	for id in LegionItemDb.synergy_ids():
		dv.add_child(dv.call("_synergy", id))
	await _frames(1)
	var text := _ui_text(dv)
	_clean(text, "Досье: артефакты и синергии")
	_check(text.contains("Молния Z"), "Досье: «Молния Z»")
	dv.queue_free()
	var rows := PackedStringArray()
	for id: String in AmendmentDb.ORDER:
		var row := ProgressionRow.new()
		root.add_child(row)
		row.configure(StringName(id), AmendmentDb.card(StringName(id)), "",
			{"expanded": true, "together": true, "note": RunProgression.unseen_note(StringName(id))})
		rows.append(_ui_text(row))
		row.queue_free()
	_clean("\n".join(rows), "карточки поправок (%d)" % AmendmentDb.ORDER.size())
	await _frames(1)


# ── 13. KB-11 и двойная подстановка ───────────────────────────────────────────

## Обмен Ку↔Дубль-вэ: слово «Ку» в тексте становится «Дубль-вэ» ровно один раз (второй проход
## вернул бы «Ку» — двойной сток).
func _test_swap_once() -> void:
	print("— KB-11: обмен клавиш при конфликте; сток один")
	Controls.reset()
	var err: Variant = _static(CONTROLS_PATH, "swap", [&"cast_q", KEY_W])
	_check(err == "" and Controls.key(&"cast_q") == KEY_W and Controls.key(&"cast_w") == KEY_Q,
		"swap: Ку на W, Дубль-вэ на Q (%s)" % str(err))
	_check(Controls.rebind(&"cast_e", KEY_Q) != "", "обычный rebind на занятую клавишу по-прежнему отказ")
	_toasts.clear()
	w.toast("Ку сорвёт зачитку", &"info")
	_check(_hud_last() == "Дубль-вэ сорвёт зачитку" and _toasts.back() == "Дубль-вэ сорвёт зачитку",
		"тост мира: одна подстановка (HUD «%s»)" % _hud_last())
	var tut: LegionTutorial = w.tutorial
	if tut != null:
		tut.call("_hint", "Ку — проверка подсказки")
		_check(_hud_last() == "Дубль-вэ — проверка подсказки",
			"подсказка урока: одна подстановка (HUD «%s»)" % _hud_last())
	# Слияние keys-texts с прокачкой: ProgressionUi.text уже сток — детали карточки и Досье
	# не должны подставлять второй раз.
	var row := ProgressionRow.new()
	root.add_child(row)
	row.configure(&"swap_probe", {"title": "Проба", "text": "Деталь Ку", "tradeoff": "Цена Ку",
		"hint": "Совет Ку"}, "", {"expanded": true, "chips": false})
	var row_text := _ui_text(row)
	_check(row_text.contains("Деталь Дубль-вэ") and row_text.contains("Мелкий шрифт: Цена Дубль-вэ")
		and row_text.contains("Совет Дубль-вэ") and not row_text.contains(" Ку"),
		"детали карточки поправки: одна подстановка («%s»)" % row_text.replace("\n", " | "))
	row.queue_free()
	var dv := DossierView.new()
	root.add_child(dv)
	var dossier_text := String((dv.call("_text", "Досье Ку") as Label).text)
	_check(dossier_text == "Досье Дубль-вэ", "Досье: одна подстановка («%s»)" % dossier_text)
	dv.queue_free()
	Controls.reset()


func _key_event(code: Key, pressed := true) -> InputEventKey:
	var event := InputEventKey.new()
	event.keycode = code
	event.physical_keycode = code
	event.pressed = pressed
	return event


## Экран настроек: занятая клавиша — подсказка «нажмите ещё раз», второе нажатие — обмен.
func _test_swap_ui() -> void:
	print("— KB-11: обмен в экране настроек")
	Controls.reset()
	var screen := SettingsScreen.new()
	root.add_child(screen)
	await process_frame
	var button := screen.find_child("Bind_cast_q", true, false) as Button
	if button == null:
		_check(false, "в настройках есть кнопка Bind_cast_q")
		return
	button.pressed.emit()
	for i in 2:
		Input.parse_input_event(_key_event(KEY_W))
		await process_frame
		Input.parse_input_event(_key_event(KEY_W, false))
		await process_frame
		if i == 0:
			var note := String((screen.get("_binding_note") as Label).text)
			_check(Controls.key(&"cast_q") == KEY_Q and note.contains("ещё раз"),
				"первое нажатие занятой W: ничего не меняет, предлагает обмен — «%s»" % note)
	var after := String((screen.get("_binding_note") as Label).text)
	_check(Controls.key(&"cast_q") == KEY_W and Controls.key(&"cast_w") == KEY_Q
		and screen.get("_capture") == &"", "второе нажатие W: Ку и Дубль-вэ поменялись — «%s»" % after)
	screen.queue_free()
	await process_frame
	Controls.reset()


# ── 14. KB-09: подпись по раскладке ОС ────────────────────────────────────────

func _test_layout() -> void:
	print("— KB-09: подпись физической клавиши по раскладке")
	Controls.reset()
	# AZERTY: физическая Q подписана «A», физическая A — «Q»
	_static(CONTROLS_PATH, "set_layout_labels", [{KEY_Q: KEY_A, KEY_A: KEY_Q}])
	_check(Controls.label(&"cast_q") == "A", "Ку на AZERTY подписана «A»: %s" % Controls.label(&"cast_q"))
	_check(Controls.text("Зажмите Ку (Q)") == "Зажмите A", "проза на AZERTY: %s" % Controls.text("Зажмите Ку (Q)"))
	# русская раскладка ОС даёт кириллицу — игра остаётся при своих именах
	_static(CONTROLS_PATH, "set_layout_labels", [{KEY_Q: 0x0419}])
	_check(Controls.label(&"cast_q") == "Q" and Controls.text("Ку (Q)") == "Ку (Q)",
		"кириллическая метка ОС не подменяет «Ку (Q)»")
	_static(CONTROLS_PATH, "set_layout_labels", [{}])
