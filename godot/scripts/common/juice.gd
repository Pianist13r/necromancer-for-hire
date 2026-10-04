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
	var lib := _lib(ctx)
	if lib != null:
		lib.call("shake_camera", ctx, intensity, duration)


static func hit_stop(ctx: Node, freeze: float = 0.06) -> void:
	var lib := _lib(ctx)
	if lib != null:
		lib.call("hit_stop", ctx, freeze, 0.0)


static func flash(target: CanvasItem, color: Color = Color.WHITE, duration: float = 0.15) -> void:
	var lib := _lib(target)
	if lib != null:
		lib.call("flash", target, color, duration, 1)


static func punch(target: Node2D, offset: Vector2, duration: float = 0.25) -> void:
	var lib := _lib(target)
	if lib != null:
		lib.call("punch_position", target, offset, duration)
