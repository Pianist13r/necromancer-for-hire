class_name ReleaseInfo
extends RefCounted
## Один источник версии и публичных ссылок. Удалённый JSON меняет только адрес лобби.

const VERSION := "0.4.1-alpha"
const REPOSITORY_URL := "https://github.com/Pianist13r/necromancer-for-hire"
const RELEASES_URL := REPOSITORY_URL + "/releases"
const SERVER_INFO_URL := (
	"https://raw.githubusercontent.com/Pianist13r/necromancer-for-hire/main/server.json")
const DEFAULT_RELAY := "wss://relay.necromancer-for-hire.ru"
const SERVER_BODY_LIMIT := 4096
const SERVER_TIMEOUT := 8.0
## Сообщество (B-467): канал и чат в Telegram, сайт игры. Меню и экран итога берут адреса отсюда.
const TELEGRAM_CHANNEL_URL := "https://t.me/necromancer_for_hire"
const TELEGRAM_CHAT_URL := "https://t.me/necromancer_for_hire_chat"
const SITE_URL := "https://necromancer-for-hire.ru"

## Канал сборки: "" — по фиче экспорта; тесты подставляют "steam" или "standalone"
## (в headless-прогоне фичу пресета не задать).
static var channel_override := ""
## Тесты подменяют открытие ссылки (url: String) -> void: настоящий браузер в прогоне не нужен.
static var url_opener := Callable()


## Открыть внешнюю ссылку: в игре — браузер ОС, в тесте — подменённый url_opener.
static func open_url(url: String) -> void:
	if url_opener.is_valid():
		url_opener.call(url)
		return
	OS.shell_open(url)


## Steam-сборка (пресеты «Steam Windows»/«Steam Linux», фича `steam`): обновляет клиент Steam,
## ссылок на раздачу вне Steam в игре быть не должно (STEAM_PLAN §4).
static func is_steam() -> bool:
	if channel_override != "":
		return channel_override == "steam"
	return OS.has_feature("steam")


## Строка пробы собранного exe (`-- --dev build_probe=1`, tools/build_steam.py): версия и фичи
## изнутри сборки. `--script` release-шаблон игнорирует, поэтому проба — через игру.
static func probe_line() -> String:
	return "PROBE version=%s steam=%s is_steam=%s ship=%s debug=%s" % [
		VERSION, OS.has_feature("steam"), is_steam(), OS.has_feature("ship"), OS.is_debug_build()]


## Только wss с доменным именем: без учётных данных, пробелов, управляющих символов,
## фрагментов и альтернативных схем. Ручное поле по-прежнему допускает локальный ws.
static func relay_from_body(body: PackedByteArray) -> String:
	if body.is_empty() or body.size() > SERVER_BODY_LIMIT:
		return ""
	var json := JSON.new()
	if json.parse(body.get_string_from_utf8()) != OK or not (json.data is Dictionary):
		return ""
	var value: Variant = json.data.get("relay")
	if not (value is String) or value.length() > 512:
		return ""
	var url: String = value
	var pattern := RegEx.new()
	pattern.compile("^wss://([A-Za-z0-9.-]+)(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?$")
	var matched := pattern.search(url)
	if matched == null or matched.get_string() != url:
		return ""
	var host := matched.get_string(1)
	var labels := host.split(".")
	if host.length() > 253 or labels.size() < 2 or labels[-1].is_valid_int():
		return ""
	for label: String in labels:
		if label.is_empty() or label.length() > 63 or label.begins_with("-") \
				or label.ends_with("-"):
			return ""
	var port := matched.get_string(2)
	if not port.is_empty() and (int(port.substr(1)) < 1 or int(port.substr(1)) > 65535):
		return ""
	return url
