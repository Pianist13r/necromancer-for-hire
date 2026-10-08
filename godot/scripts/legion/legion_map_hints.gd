class_name LegionMapHints
extends Node
##
## Пакет tutorial (задание tutorial, п.2): «короткие подсказки при первом появлении» новых
## механик на картах 2-6 — одна плашка в бою при первом случае, не повторяется (флаг в
## Campaign.hint_seen/mark_hint_seen, тот же паттерн, что tutorial_done). ОБУЧЕНИЕ
## (LegionTutorial) живёт только на wasteland и учит целиком; здесь — точечные дополнения к
## брифингу «Новое:» (пакет meta, уже объявляет открытие вида/способности ПЕРЕД картой): вахтёр
## умеет держать фронт щитом, счетовод умеет пакет, щитоносец бьётся только в лоб. Захват склепа и
## Прораб подсказывают о себе сами (crypt.gd, foe.gd toast); сам склеп объясняется здесь один раз.
##
## Не Node мира, а отдельный ребёнок (add_child в _build(), как _Banner в legion_tutorial.gd):
## подсказки не участвуют в шаге кадра игры и не должны блокировать волны, поэтому просто
## опрашивают world.foes раз в кадр и слушают unit_spawned — дешевле, чем городить сигнал
## foe_spawned в чужом legion_world.gd ради трёх разовых плашек.
##

## Склеп: подсказка приходит не сразу — вводный тост карты (LegionCfg.TOAST_TIME) уже сошёл.
const CRYPT_HINT_AT := 3.5
const CRYPT_HINT_TIME := 7.0

var world: LegionWorld = null


func setup(w: LegionWorld) -> void:
	world = w
	world.unit_spawned.connect(_on_unit_spawned)


func _process(_dt: float) -> void:
	if world == null or world.map_id == LegionTutorial.WASTELAND_MAP_ID \
			or world.phase != LegionWorld.Phase.BATTLE:
		return
	if not world.crypts.is_empty() and world.now >= CRYPT_HINT_AT:
		# corr 29.09: подписи склепа («0/8 · 4 с») новичку ничего не говорили; линию рядом со
		# склепом, дающую ему пополнять бойцов, тестировщик понял только со второй попытки
		_fire(&"crypt_intro", "Склеп: %d бойцов рядом на %d с, без врагов, — он ваш и сам "
			% [LegionCfg.CRYPT_UNITS, int(LegionCfg.CRYPT_CAPTURE_TIME)]
			+ "возрождает подрядчиков. Договор рядом — и они встанут в строй.", CRYPT_HINT_TIME)
	for f: Foe in world.foes:
		if f.type_id == &"shield_inspector":
			_fire(&"foe_shield_inspector", "Щитоносец: щит держит спереди, снаряды "
				+ "почти не берут. Заходите с фланга или в ближний бой.")
		elif f.type_id == &"lawyer" and f.law_c != null:
			# v20: в миг, когда появился телеграф, — Игорь 26.09 механики Юриста не понял
			_fire(&"foe_lawyer", "Юрист идёт к самому людному участку и расторгает его — "
				+ "бойцы встанут «в отказе». Строй его не трогает: {key:cast_q} сорвёт зачитку, "
				+ "добейте натиском или «Сбором».")


func _on_unit_spawned(u: Legionnaire) -> void:
	if world == null or world.map_id == LegionTutorial.WASTELAND_MAP_ID:
		return
	if u.kind == LegionCfg.KIND_GUARD:
		_fire(&"unit_guard", "Вахтёр держит фронт щитом. Проходную можно улучшить "
			+ "в её меню: больше штат, быстрее возрождение.")
	elif u.kind == LegionCfg.KIND_CLERK:
		_fire(&"unit_clerk", "Счетовод бьёт издалека и видит призраков. Поставьте его "
			+ "участок рядом с другим видом — выйдет пакет: бонус обоим.")


func _fire(id: StringName, text: String, time := -1.0) -> void:
	if Campaign.hint_seen(id) or _taught(id):
		return
	Campaign.mark_hint_seen(id)
	world.toast(text, &"info", time)


## Кампания v20: у карты есть урок на тот же повод (щитоносец, Юрист) — урок учит сам, разовая
## подсказка его не дублирует. Подсказки о своих видах (вахтёр, счетовод, пакет) — остаются.
func _taught(id: StringName) -> bool:
	var when := {&"foe_shield_inspector": "first_foe:shield_inspector",
		&"foe_lawyer": "first_foe:lawyer"}
	if not world.in_campaign or not when.has(id):
		return false
	return LegionTutorial.map_covers(world.map, String(when[id]))
