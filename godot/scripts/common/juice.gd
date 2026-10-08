class_name Juice
extends RefCounted
##
## Тонкая обёртка над автолоадом Juicee.
##
## Зачем она: гейт `--headless --check-only --script ...` НЕ регистрирует автолоады, и прямое
## обращение к `Juicee` роняет проверку типов ошибкой «Identifier not found» — то есть самый
## дешёвый контроль качества переставал работать ровно там, где мы добавляем сочность
## (проверено запуском 2026-08-22). Обёртка обращается к автолоаду через дерево и `call()`,
## поэтому статическая проверка проходит, а если аддона вдруг нет — игра не падает, просто
## остаётся без тряски.
##


static func _lib(ctx: Node) -> Node:
	if ctx == null or not ctx.is_inside_tree():
		return null
	return ctx.get_tree().root.get_node_or_null("Juicee")


static func shake(ctx: Node, intensity: float = 8.0, duration: float = 0.3) -> void:
	if not Settings.is_screen_shake_enabled() or not permit(ctx, &"visual_shake", 300):
		return
	var lib := _lib(ctx)
	if lib != null:
		lib.call("shake_camera", ctx, minf(intensity, 6.0), minf(duration, 0.18))


static func hit_stop(ctx: Node, freeze: float = 0.06) -> void:
	var lib := _lib(ctx)
	if lib != null:
		lib.call("hit_stop", ctx, freeze, 0.0)


static func flash(target: CanvasItem, color: Color = Color.WHITE, duration: float = 0.15) -> void:
	# Одиночные события (Котёл, босс) не конкурируют с лимитом молнии или виньеткой.
	if not Settings.is_flashes_enabled():
		return
	var lib := _lib(target)
	if lib != null:
		lib.call("flash", target, color, duration, 1)


## Общий лимит экранных эффектов на viewport, не на каждый источник удара.
## Окно — по FxClock (D-1008-S14): в живой игре это те же настенные часы, в записи режиссёра /
## Movie Maker — кадры (число тряск за прогон повторяемо). Расхождение «полной» и «экономной»
## графики в тесте линий лечит не окно, а свой генератор Juicee (JuiceeEffect.rng): раньше
## каждая тряска тратила глобальный randi(), а их число за бой зависело от нагрузки машины.
static func permit(ctx: Node, key: StringName, interval_ms: int) -> bool:
	if ctx == null or not ctx.is_inside_tree():
		return false
	var vp := ctx.get_viewport()
	var now := FxClock.ms()   # часы эффектов: в записи режиссёра — по кадрам, в игре — настенные
	if now - int(vp.get_meta(key, -interval_ms)) < interval_ms:
		return false
	vp.set_meta(key, now)
	return true


static func screen_flash_allowed(ctx: Node, channel: StringName = &"visual_flash",
		interval_ms: int = 500) -> bool:
	return Settings.is_flashes_enabled() and permit(ctx, channel, interval_ms)


static func flash_alpha(value: float) -> float:
	return value if Settings.is_flashes_enabled() else 1.0


static func sync_accessibility() -> void:
	JuiceeEffect.accessibility.no_flash = not Settings.is_flashes_enabled()
	JuiceeEffect.accessibility.no_screenshake = not Settings.is_screen_shake_enabled()
	# Выключение во время эффекта сразу возвращает камеру/цвет, даже из паузы.
	for effect: JuiceeEffect in JuiceeEffect._alive.duplicate():
		if not JuiceeEffect.accessibility.is_allowed(effect.get_accessibility_tag()):
			effect.stop()


static func punch(target: Node2D, offset: Vector2, duration: float = 0.25) -> void:
	var lib := _lib(target)
	if lib != null:
		lib.call("punch_position", target, offset, duration)
