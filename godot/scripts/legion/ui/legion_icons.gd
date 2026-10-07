class_name LegionIcons
extends RefCounted
##
## Иконки (`assets/legion/icons/<имя>.png`, RGBA 256×256, генерация 06.10.2026) для HUD и экранов
## меты (integrate1): карточки видов, слоты способностей, души, премия. Один путь загрузки и один
## размер-по-месту, чтобы каждый экран не тянул свой load() и не растягивал иконку вручную.
##

const DIR := "res://assets/legion/icons/"


## Все иконки — PNG: генерация 06.10.2026 (D-1006-01) заменила и кодовые, и векторные знаки,
## каталог vector/ снят, порядок загрузки один. null — файла нет (экран рисует без иконки).
static func tex(icon_name: String) -> Texture2D:
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
