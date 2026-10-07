class_name HeroScreen
extends Control
## «Досье» из меню (D-1007-P2): хост общего DossierView — разряд и опыт, вкладки «Поправки»
## (слоты и каталог колоды, по умолчанию) и «Артефакты» (артефакты раздела без счётчиков боя).
## Тот же виджет показывает пауза (LegionItemDossier). Разряд открывает варианты, не покупает
## проценты.

signal back
var view: DossierView = null


func _ready() -> void:
	UiStyle.fill_rect(self)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var backdrop := ColorRect.new()
	backdrop.color = Color(0.035, 0.025, 0.065, 0.98)
	UiStyle.fill_rect(backdrop)
	backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(backdrop)
	var margin := MarginContainer.new()
	UiStyle.fill_rect(margin)
	for side: String in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 92 if side == "bottom" else 24)
	add_child(margin)
	view = DossierView.new()
	margin.add_child(view)
	view.configure(null, DossierView.TAB_UPGRADES)
	LegionUi.nav_bar(self, "← Назад", func() -> void: back.emit())
	ModalFocus.contain.call_deferred(self)


func _unhandled_key_input(_event: InputEvent) -> void:
	ModalFocus.contain(self)
