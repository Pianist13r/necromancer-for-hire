class_name ContractErase
extends RefCounted
##
## Таб — стереть кусок линии под курсором (slow/tab-erase, Игорь 29.09.2026: «чтобы линия
## полностью стиралась под мышкой. Но если перед этим линия была разрезана на несколько
## фрагментов, чтобы стирался только этот фрагмент»; «бойцы при таком стирании тоже должны идти
## в натиск»).
##
## Участки линии тают и срываются независимо, мёртвый — навсегда мёртв, поэтому со временем
## линия распадается на куски. Кусок — наибольшая непрерывная цепочка живых участков вокруг
## участка под курсором (поиск — ContractField.pick_segment, как у ПКМ). Все его участки уходят
## в натиск, как от щелчка ПКМ по каждому (стрелка участка, золотой — «Точно!»), одним жестом:
## комбо растёт один раз (LegionWorld.release_run). Мана не возвращается (D-0929-08).
## Фигуры (кольцо, восьмёрка, треугольник, квадрат) — одна сущность: их выпускает сам
## ContractField.erase_at обычным щелчком ПКМ (D-0929-09).
##


## Кусок живых участков вокруг seg (по возрастанию). Мёртвый seg — пусто.
static func run_of(c: Contract, seg: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	if seg < 0 or seg >= c.seg_count() or not c.seg_alive(seg):
		return out
	var a := seg
	while a > 0 and c.seg_alive(a - 1):
		a -= 1
	var b := seg
	while b < c.seg_count() - 1 and c.seg_alive(b + 1):
		b += 1
	for s in range(a, b + 1):
		out.append(s)
	return out


static func live_count(c: Contract) -> int:
	var n := 0
	for s in c.seg_count():
		if c.seg_alive(s):
			n += 1
	return n


## Сорвать кусок линии c вокруг seg. Золото решается для всех участков ДО срыва: первый
## сорванный не должен менять ответ соседу. Надпись «Точно!» — одна на жест, у первого
## золотого участка (подряд идущие участки по 64 px — надписи легли бы друг на друга).
static func erase_run(field: ContractField, c: Contract, seg: int) -> int:
	var run := run_of(c, seg)
	if run.is_empty():
		return 0
	var gold := PackedByteArray()
	var first_gold := -1
	for s in run:
		var g := field.click_gold(c, s)
		gold.append(1 if g else 0)
		if g and first_gold < 0:
			first_gold = s
	var at := c.seg_center(first_gold) if first_gold >= 0 else Vector2.ZERO
	var n := field.world.release_run(c, run, gold)
	# Совет «золото — щёлкни» (intuit.on_done) и уроки «Точно!» Таб не закрывает: они учат щелчку
	# по золоту, а Таб срывает кусок целиком (verifier: урок засчитывался Табом по не-золотому)
	if n > 0 and first_gold >= 0:
		field.perfect_fx(at)
	return n
