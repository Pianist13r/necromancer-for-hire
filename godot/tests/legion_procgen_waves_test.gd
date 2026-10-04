extends SceneTree
##
## Регресс линии waves процгена (BOOK §5.2, §4.1, §6.4, §10 п.4; docs/procgen/WAVES.md):
##
##   "$GODOT" --headless --path godot --fixed-fps 60
##       --script res://tests/legion_procgen_waves_test.gd -- --mute
##
## 1) детерминизм: те же (сид, k) → те же волны; PgWaves.build с тем же RNG → тот же массив;
## 2) лестница видов по k (нотариусы с 3, щиты с 4, призраки с 5, юристы с 6, Прораб — только
##    «объект особой важности» в последней волне), новый вид к k ≥ from+1 есть в каждой карте,
##    где он в составе; юристов ≤ 2 за волну;
## 3) темп: пауза после клира ≥ 10 с, первая встреча ≤ 25 с (движком LegionTerrain, топь
##    учтена), кульминация — одна и предпоследняя, она самая тяжёлая, передышка легче соседки
##    до неё, перед финалом пауза длиннее;
## 4) бюджет: объект 1 ≈ «Пустырь» (110–150 врагов), в среднем растёт (k 1–5 < 6–10 < 16–20),
##    но «плавает» — у части забегов бывает спад;
## 4б) кривая сложности (серии 03.10, docs/dev/BALANCE.md): объект 2 — ещё вход новичка, к 3–4
##    волны заметно тяжелее объекта 1, к 5–8 — в разы, а 16–20 — не стена (почти полка после 8–12).
##    Волны v0 (master до 03.10) так не растут: полный бот не проигрывал на них 1–16 вовсе;
## 5) уровни: у кульминации есть группы tier 1 («Стажёр» их не видит) — «Стажёр» легче
##    «Штатного»; клещи стартуют вместе; трещины не раньше 10 с;
## Итог «LEGION PROCGEN WAVES: N/M OK»; код выхода 1 при провале. Сохранений не пишет.
##

const SEEDS := 12
const KS := 20
const FIRST_CONTACT_MAX := 25.0
const PAUSE_MIN := 10.0
const BREACH_MIN := 10.0
const K1_RANGE := Vector2(110.0, 150.0)
## Кривая (очки «Штатного», средние по забегам; к объекту 1): объект 2 не выше K2_MAX, 3–4 не
## ниже EARLY_MIN, 5–8 не ниже MID_MIN; 16–20 к 8–12 — не выше LATE_MAX.
const K2_MAX := 1.7
const EARLY_MIN := 2.5
const MID_MIN := 6.0
const LATE_MAX := 1.25
## Без обрыва (v3, цепочка 03.10): 9–12 не круче 5–8 более чем в MID_STEP_MAX, 13–16 к 9–12 — не
## выше PLATEAU_MAX (почти плато), соседние объекты (средние) — не скачок вдвое.
const MID_STEP_MAX := 1.6
const PLATEAU_MAX := 1.15
const NEIGHBOR_MAX := 2.0
const FROM := {"signer": 3, "shield_inspector": 4, "ghost": 5, "lawyer": 6, "boss": 7}
const COST := {"zombie": 1.0, "beetle": 1.0, "signer": 1.4, "shield_inspector": 1.8,
	"ghost": 1.2, "lawyer": 2.5, "boss": 20.0}
const SPEED := {"zombie": 34.0, "beetle": 70.0, "signer": 34.0, "shield_inspector": 28.0,
	"ghost": 30.0, "lawyer": 42.0, "boss": 22.0}
## Разброс старта групп одной волны у «Клещей», с (PgWaves.DELAY_JITTER + запас на округление).
const SYNC_TOL := 1.6

var _checks := 0
var _fails := 0


func _initialize() -> void:
	_determinism()
	var maps := _maps()
	_ladder(maps)
	_tempo(maps)
	_budget(maps)
	_curve(maps)
	_levels(maps)
	print("LEGION PROCGEN WAVES: %d/%d OK" % [_checks - _fails, _checks])
	quit(1 if _fails > 0 else 0)


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_fails += 1
		print("  FAIL ", what)


func _maps() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for s in range(1, SEEDS + 1):
		for k in range(1, KS + 1):
			var m := ProcGen.generate(s, k)
			if not m.is_empty():
				out.append(m)
	_check(out.size() == SEEDS * KS, "все %d карт сгенерированы (%d)" % [SEEDS * KS, out.size()])
	return out


func _determinism() -> void:
	var a := ProcGen.generate(5, 9)
	var b := ProcGen.generate(5, 9)
	_check(JSON.stringify(a["waves"]) == JSON.stringify(b["waves"]), "5:9 — волны те же")
	var m := a.duplicate(true)
	var card: Dictionary = m["procgen"]["card"]
	var w1 := PgWaves.build(m, card, PgRng.make(5, "waves:9", 0))
	var w2 := PgWaves.build(m.duplicate(true), card, PgRng.make(5, "waves:9", 0))
	_check(JSON.stringify(w1) == JSON.stringify(w2), "PgWaves.build с тем же RNG — тот же массив")
	_check(m["procgen"].has("waves") and float(m["procgen"]["waves"].get("budget", 0.0)) > 0.0,
		"procgen.waves — бюджет и роли волн записаны")


func _k(m: Dictionary) -> int:
	return int(m["procgen"]["k"])


func _ladder(maps: Array[Dictionary]) -> void:
	var early := 0
	var missing := 0
	var lawyers := 0
	var boss_bad := 0
	for m in maps:
		var k := _k(m)
		var card: Dictionary = m["procgen"]["card"]
		var seen := {}
		var waves: Array = m["waves"]
		for i in waves.size():
			var law := 0
			for g: Dictionary in waves[i]["groups"]:
				var t := String(g["type"])
				seen[t] = true
				if FROM.has(t) and k < int(FROM[t]):
					early += 1
					if early <= 5:
						print("  %s: %s на k=%d" % [m["id"], t, k])
				if t == "lawyer":
					law += int(g["count"])
				if t == "boss" and (i != waves.size() - 1 or not bool(card.get("boss", false))):
					boss_bad += 1
			if law > 2:
				lawyers += 1
		for t: String in card.get("foes", []):
			if t != "boss" and FROM.has(t) and k >= int(FROM[t]) + 1 and not seen.has(t):
				missing += 1
				if missing <= 5:
					print("  %s: вид %s в составе карточки, а в волнах нет" % [m["id"], t])
		if bool(card.get("boss", false)) and not seen.has("boss"):
			boss_bad += 1
	_check(early == 0, "лестница видов: никто не приходит раньше своего k (%d)" % early)
	_check(missing == 0, "вид из состава карточки есть в волнах к k ≥ from+1 (%d без)" % missing)
	_check(lawyers == 0, "юристов ≤ 2 за волну (%d волн больше)" % lawyers)
	_check(boss_bad == 0, "Прораб — только у карточки с боссом и в последней волне (%d)" % boss_bad)


func _pts(wave: Dictionary, tier := 1) -> float:
	var s := 0.0
	for g: Dictionary in wave["groups"]:
		if int(g.get("tier", 0)) <= tier:
			s += float(g["count"]) * float(COST.get(String(g["type"]), 1.0))
	return s


func _tempo(maps: Array[Dictionary]) -> void:
	var pause_bad := 0
	var contact_bad := 0
	var climax_bad := 0
	var rest_bad := 0
	var breath_bad := 0
	var breach_bad := 0
	var worst := 0.0
	for m in maps:
		var waves: Array = m["waves"]
		var n := waves.size()
		for i in range(1, n):
			if float(waves[i].get("pause", 0.0)) < PAUSE_MIN:
				pause_bad += 1
		var t := _first_contact(m)
		worst = maxf(worst, t)
		if t > FIRST_CONTACT_MAX:
			contact_bad += 1
			if contact_bad <= 5:
				print("  %s: первая встреча %.1f с" % [m["id"], t])
		var climaxes: Array[int] = []
		for i in n:
			if bool(waves[i].get("climax", false)):
				climaxes.append(i)
		if climaxes != [n - 2]:
			climax_bad += 1
			continue
		var c := n - 2
		for i in n:
			if i != c and _pts(waves[i]) >= _pts(waves[c]):
				climax_bad += 1
				if climax_bad <= 5:
					print("  %s: волна %d тяжелее кульминации" % [m["id"], i + 1])
				break
		var rest := int(m["procgen"].get("waves", {}).get("rest", -1))
		if rest < 1 or rest >= c or _pts(waves[rest]) >= _pts(waves[rest - 1]):
			rest_bad += 1
		if float(waves[c + 1].get("pause", 0.0)) <= float(waves[c].get("pause", 0.0)):
			breath_bad += 1
		for w: Dictionary in waves:
			for g: Dictionary in w["groups"]:
				if g.has("breach") and float(g.get("delay", 0.0)) < BREACH_MIN:
					breach_bad += 1
	print("худшая первая встреча: %.1f с" % worst)
	_check(pause_bad == 0, "пауза после клира ≥ 10 с (%d нарушений)" % pause_bad)
	_check(contact_bad == 0, "первая встреча ≤ 25 с (%d карт дольше)" % contact_bad)
	_check(climax_bad == 0, "кульминация одна, предпоследняя и самая тяжёлая (%d)" % climax_bad)
	_check(rest_bad == 0, "передышка: лёгкая волна между разгоном и кульминацией (%d)" % rest_bad)
	_check(breath_bad == 0, "перед финалом пауза длиннее (%d)" % breath_bad)
	_check(breach_bad == 0, "трещины — не раньше 10 с (%d)" % breach_bad)


## Первая встреча — как PgFilter.first_contact: первый рубеж бота на дороге (без рубежа —
## Котёл), скорость вида, топь по LegionTerrain.
func _first_contact(m: Dictionary) -> float:
	var terrain := LegionTerrain.new().setup(m)
	var w: Dictionary = m["waves"][0]
	var best := INF
	for g: Dictionary in w["groups"]:
		if g.has("breach"):
			continue
		var path := PackedVector2Array()
		for r: Dictionary in m["roads"]:
			if r["id"] == g["road"]:
				for q: Array in r["path"]:
					path.append(Vector2(q[0], q[1]))
		if path.is_empty():
			continue
		var meet := PgGeom.length(path)
		var base := 0.0
		for i in range(1, path.size()):
			for bl: Dictionary in m["bot_lines"]:
				var hit: Variant = Geometry2D.segment_intersects_segment(path[i - 1], path[i],
					Vector2(bl["a"][0], bl["a"][1]), Vector2(bl["b"][0], bl["b"][1]))
				if hit != null:
					meet = minf(meet, base + path[i - 1].distance_to(hit))
			base += path[i - 1].distance_to(path[i])
		var speed := float(SPEED.get(String(g["type"]), 34.0))
		var t := float(w.get("pause", 3.0)) + float(g.get("delay", 0.0))
		var s := float(g.get("at", 0.0))
		while s < meet:
			var step := minf(8.0, meet - s)
			t += step / (speed * terrain.speed_mult(PgGeom.point_at(path, s + step * 0.5)))
			s += step
		best = minf(best, t)
	return best


func _budget(maps: Array[Dictionary]) -> void:
	var by_k := {}
	var per_seed := {}
	for m in maps:
		var k := _k(m)
		var total := 0.0
		for w: Dictionary in m["waves"]:
			total += _pts(w)
		(by_k.get_or_add(k, []) as Array).append(total)
		(per_seed.get_or_add(int(m["procgen"]["seed"]), {}) as Dictionary)[k] = total
	var k1 := 0.0
	for x: float in by_k.get(1, []):
		k1 += x
	k1 /= maxf(1.0, (by_k.get(1, []) as Array).size())
	print("бюджет по k (среднее очков): ", _means(by_k))
	_check(k1 >= K1_RANGE.x and k1 <= K1_RANGE.y, "объект 1 ≈ «Пустырь»: %.0f очков" % k1)
	var a := _band(by_k, 1, 5)
	var b := _band(by_k, 6, 10)
	var c := _band(by_k, 16, 20)
	_check(a < b and b < c, "бюджет в среднем растёт: %.0f < %.0f < %.0f" % [a, b, c])
	var drops := 0
	for s: int in per_seed:
		var row: Dictionary = per_seed[s]
		for k in range(2, KS + 1):
			if row.has(k) and row.has(k - 1) and float(row[k]) < float(row[k - 1]):
				drops += 1
				break
	_check(drops >= 1, "бюджет «плавает»: у %d забегов из %d есть спад" % [drops, per_seed.size()])


func _curve(maps: Array[Dictionary]) -> void:
	var by_k := {}
	for m in maps:
		var total := 0.0
		for w: Dictionary in m["waves"]:
			total += _pts(w)
		(by_k.get_or_add(_k(m), []) as Array).append(total)
	var k1 := maxf(1.0, _band(by_k, 1, 1))
	var k2 := _band(by_k, 2, 2) / k1
	var early := _band(by_k, 3, 4) / k1
	var mid := _band(by_k, 5, 8) / k1
	var late := _band(by_k, 16, 20) / maxf(1.0, _band(by_k, 8, 12))
	print("кривая к объекту 1: k2 ×%.2f, k3–4 ×%.2f, k5–8 ×%.2f; 16–20 к 8–12 ×%.2f" % [
		k2, early, mid, late])
	_check(k2 <= K2_MAX, "объект 2 — ещё вход: ×%.2f ≤ ×%.1f" % [k2, K2_MAX])
	_check(early >= EARLY_MIN, "к 3–4 волны тяжелее: ×%.2f ≥ ×%.1f" % [early, EARLY_MIN])
	_check(mid >= MID_MIN, "к 5–8 — в разы: ×%.2f ≥ ×%.1f" % [mid, MID_MIN])
	_check(late <= LATE_MAX, "16–20 не стена: ×%.2f к 8–12 ≤ ×%.2f" % [late, LATE_MAX])
	var step := _band(by_k, 9, 12) / maxf(1.0, _band(by_k, 5, 8))
	var plateau := _band(by_k, 13, 16) / maxf(1.0, _band(by_k, 9, 12))
	_check(step <= MID_STEP_MAX, "9–12 не обрыв после 5–8: ×%.2f ≤ ×%.1f" % [step, MID_STEP_MAX])
	_check(plateau <= PLATEAU_MAX, "13–16 — плато к 9–12: ×%.2f ≤ ×%.2f" % [plateau, PLATEAU_MAX])
	var worst := 0.0
	for k in range(2, 17):
		worst = maxf(worst, _band(by_k, k, k) / maxf(1.0, _band(by_k, k - 1, k - 1)))
	_check(worst <= NEIGHBOR_MAX, "наибольший скачок соседних объектов ×%.2f ≤ ×%.1f" % [worst, NEIGHBOR_MAX])


func _means(by_k: Dictionary) -> String:
	var parts: PackedStringArray = []
	for k in range(1, KS + 1):
		parts.append("%d:%.0f" % [k, _band(by_k, k, k)])
	return " ".join(parts)


func _band(by_k: Dictionary, lo: int, hi: int) -> float:
	var s := 0.0
	var n := 0
	for k in range(lo, hi + 1):
		for x: float in by_k.get(k, []):
			s += x
			n += 1
	return s / maxf(1.0, n)


func _levels(maps: Array[Dictionary]) -> void:
	var no_tier := 0
	var intern_heavier := 0
	var pincers := 0
	var desync := 0
	for m in maps:
		var waves: Array = m["waves"]
		var c := waves.size() - 2
		var tier1 := false
		for g: Dictionary in waves[c]["groups"]:
			tier1 = tier1 or int(g.get("tier", 0)) == 1
		if _k(m) >= 3 and not tier1:
			no_tier += 1
		var intern := LegionChallenge.apply_map(m, LegionChallenge.INTERN)
		var normal := LegionChallenge.apply_map(m, LegionChallenge.NORMAL)
		if _k(m) >= 3 and _pts(intern["waves"][c], 9) >= _pts(normal["waves"][c], 9):
			intern_heavier += 1
		if String(m["procgen"]["card"]["archetype"]) != "pincers":
			continue
		pincers += 1
		for w: Dictionary in waves:
			var lo := INF
			var hi := -INF
			for g: Dictionary in w["groups"]:
				if String(g["type"]) == "zombie" and not g.has("breach") and not g.has("tier"):
					lo = minf(lo, float(g["delay"]))
					hi = maxf(hi, float(g["delay"]))
			if hi - lo > SYNC_TOL:
				desync += 1
	_check(no_tier == 0, "у кульминации k ≥ 3 есть группы tier 1 (%d без)" % no_tier)
	_check(intern_heavier == 0, "кульминация «Стажёра» легче «Штатного» (%d)" % intern_heavier)
	_check(pincers > 0 and desync == 0,
		"«Клещи»: колонны зомби по дорогам стартуют вместе (%d карт, %d волн врозь)" % [
			pincers, desync])
