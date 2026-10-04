class_name LegionPlotView
extends Node2D
##
## Пустые участки под застройку (integrate1, DESIGN_V15 §5): спрайт art1 `plot_empty.png` на
## каждом участке без постройки. Застроенный участок не рисуется вовсе — постройка стоит на
## своём фундаменте (спрайт LegionBuilding), двойной отрисовки нет. Слой земли: над подложкой
## карты, под бойцами и постройками. Перерисовка — по world.building_changed (постройка/продажа).
##

var world: LegionWorld = null


func setup(w: LegionWorld) -> void:
	world = w
	world.building_changed.connect(func(_b: Object) -> void: queue_redraw())


func _draw() -> void:
	if world == null:
		return
	var tex := LegionBuilding.sprite("plot_empty")
	for plot: Dictionary in world.staff.plots:
		if plot["building"] != null:
			continue
		var at: Vector2 = plot["pos"]
		if tex == null:
			draw_circle(at, LegionCfg.MAP_PLOT_DOT * 3.0, LegionCfg.MAP_PLOT_FILL)
			continue
		var rect := LegionBuilding.sprite_rect(
			tex, LegionCfg.PLOT_SPRITE_W, LegionCfg.PLOT_SPRITE_ANCHOR_Y)
		rect.position += at
		draw_texture_rect(tex, rect, false)
