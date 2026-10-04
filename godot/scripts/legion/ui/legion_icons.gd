class_name LegionIcons
extends RefCounted
##
## Иконки art1 (`assets/legion/icons/<имя>.png`, 128×128) для HUD и экранов меты (integrate1):
## карточки видов, слоты способностей, души, премия. Один путь загрузки и один размер-по-месту,
## чтобы каждый экран не тянул свой load() и не растягивал 128 px вручную.
##

const DIR := "res://assets/legion/icons/"


## Векторные знаки способностей масштабируются без потери края; старый набор остаётся запасным.
## null — файла нет (экран рисует как раньше, без иконки).
static func tex(icon_name: String) -> Texture2D:
	var vector_path := DIR + "vector/" + icon_name + ".svg"
	if ResourceLoader.exists(vector_path):
		return load(vector_path) as Texture2D
	var path := DIR + icon_name + ".png"
	return load(path) as Texture2D if ResourceLoader.exists(path) else null


## Готовый TextureRect side×side с сохранением пропорций — для строк HBox (души, премия).
static func rect(icon_name: String, side: float) -> TextureRect:
	var r := TextureRect.new()
	r.texture = tex(icon_name)
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	r.custom_minimum_size = Vector2(side, side)
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r
