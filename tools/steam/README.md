# Steam: сборка и заливка (SteamPipe)

План и правила магазина — `docs/dev/STEAM_PLAN.md`; аудит сборки — `docs/dev/audit-1008/build_steam.md`.
Ничего в Steamworks пока не создано: AppID и DepotID в `*.vdf` — плейсхолдеры `0000000/0000001/0000002`.

## 1. Сборка

```bash
python -X utf8 C:/Projects/Necromancer/tools/build_steam.py
```

- Пресеты `godot/export_presets.cfg`: «Steam Windows» и «Steam Linux», фичи `ship,steam`, pck вшит в исполняемый файл.
  Release-шаблоны Godot 4.7.2 берутся из `C:/AI/necro/export-templates/4.7.2/…tpz` и распаковываются в песочницу APPDATA.
  В `%APPDATA%` владельца ничего не ставится.
- Иконку (`godot/assets/img/icon.ico`, котёл, 16–256 px; пересоздать — `tools/make_icon.py`) и свойства exe
  (версия `X.Y.Z.0` из `ReleaseInfo.VERSION`, «Pianist13r», «Некромант по найму») Godot 4.7.2 пишет в exe сам.
  rcedit для этого не нужен: проверено pefile 08.10.2026.
- Steam-сеть «Схватки»: после проб скрипт вызывает `tools/steam/stage_godotsteam.py` для Windows и Linux —
  рядом с бинарём ложатся `godotsteam/` и `steam_api64.dll` / `libsteam_api.so`, в `licenses/` — `GODOTSTEAM_LICENSE.md`;
  `steam_appid.txt` в поставку не идёт (скрипт останавливается, если он есть). Депо берут их маской `*`.
  Плагин: `--godotsteam <папка>`, иначе `NECRO_GODOTSTEAM_PLUGIN`, иначе `C:/AI/necro/export-templates/godotsteam-4.23.1`.
  Нет плагина или `--no-godotsteam` — сборка без Steam-сети с `[WARN]` и строкой в `BUILD.md`; игра работает и так
  («По сети» через ретранслятор). Пробы запуска идут без `godotsteam/`; загрузку расширения из сборки скрипт не проверяет
  (это `steamInitEx` под аккаунтом владельца — только с его ведома, `docs/dev/ONLINE.md`). Тест раскладки:
  `python -X utf8 tools/steam/test_build_steam_godotsteam.py`.
- Скрипт отказывается работать, пока открыт `Necromancer.exe`. Прежнюю `dist/steam` он переименовывает в `dist/steam.prev-<время>`.
- После экспорта скрипт проверяет:
  - состав pck по журналу: ни одного пути из exclude_filter пресета;
  - пробу exe `-- --dev build_probe=1`: версия, `steam=true`, `ship=true`, `debug=false`;
  - запуск игры headless на 300 кадров в песочнице с `NECRO_NO_METRICS=1`;
  - свойства exe.
  Итог пишется в `dist/steam/BUILD.md` и `SHA256SUMS.txt`, журналы — в `dist/steam/logs/` (в депо не идут).
- В Steam-сборке (`ReleaseInfo.is_steam()`) скрыты «Версии и обновления» (GitHub Releases) и подсказка «скачайте новый выпуск».
  Согласие на статистику, раздел «О игре», версия и «Лицензии» остаются.

Перед выпуском новой версии:
1. Поднять `ReleaseInfo.VERSION` и `application/file_version`/`product_version` пресета «Steam Windows» (`X.Y.Z.0`).
   Если они разойдутся, скрипт остановится.
2. Сервер статистики должен принимать новую версию: `tools/release/metrics_preflight.py`.

## 2. Заливка

Нужен SteamCMD (входит в Steamworks SDK: partner.steamgames.com → SDK; или steamcmd.zip с developer.valvesoftware.com)
и аккаунт с правом «Edit App Metadata / Publish» на приложение. Первый вход спросит код Steam Guard.

```bash
steamcmd +login <steam-логин> +run_app_build "C:/Projects/Necromancer/tools/steam/app_build.vdf" +quit
```

- Пути в VDF считаются относительно самих файлов: `ContentRoot` = `dist/steam/`. В депо Windows идёт `dist/steam/windows/`, в депо Linux — `dist/steam/linux/`.
- Сначала можно поставить `"Preview" "1"`: steamcmd покажет состав, ничего не заливая.
- `SetLive` пуст: билд появится в кабинете (SteamPipe → Builds), ветку назначают руками. Сначала — закрытая beta-ветка.
- AppID/DepotID — где взять, написано в комментариях `app_build.vdf`.

## 3. Настройки в кабинете (App Admin)

**Installation → General Installation → Launch Options**

| ОС | Executable | Аргументы | Тип |
|---|---|---|---|
| Windows (64-bit) | `Necromancer.exe` | — | Launch (default) |
| Linux + SteamOS | `Necromancer.x86_64` | — | Launch (default) |

Install Folder — например, `Necromancer for Hire` (латиница: кириллица в путях запуска не проверялась).

Linux: файл собирается на Windows, бита запуска у него нет. Получит ли он бит после установки клиентом Steam — не проверено.
Проверить первой установкой из beta-ветки на Linux или Deck. Не запустится — смотреть настройки депо в SteamPipe.

**Steam Cloud → Auto-Cloud** (без Steamworks API). Квота — например, 1 МБ и 20 файлов: сохранения весят единицы КБ.

| Root | Subdirectory | Pattern | OS |
|---|---|---|---|
| `WinAppDataRoaming` | `Godot/app_userdata/Некромант на аутсорсе` | `legion*.cfg*` | Windows |
| `WinAppDataRoaming` | `Godot/app_userdata/Некромант на аутсорсе` | `net.cfg` | Windows |

Root Overrides для Linux: `WinAppDataRoaming` → `LinuxXdgDataHome`, OS = Linux, замена пути `Godot/` → `godot/`. Точный вид полей сверить в кабинете.
У Linux-сборки папка в нижнем регистре: `project.godot`, `config/custom_user_dir_name.linuxbsd`.

- `legion*.cfg*` — кампания (`legion.cfg`), её `.bak` и бой вне кампании (`legion_standalone.cfg`).
  Временные `*.tmp` пишутся только на время сохранения (SafeConfig).
- `settings.cfg` (экран, громкость, клавиши, согласие на статистику) синхронизировать или нет — **решение Игоря** (аудит, вопрос 5).
- Не синхронизировать: `logs/`, `net_logs/`.
- Кириллицу в подпапке Auto-Cloud никто не проверял (аудит B19). Проверить на beta-ветке: сохранить на одной машине, загрузить на другой.

## 4. Что ещё нужно от владельца

- Создать приложение (взнос $100) и вписать AppID/DepotID в `app_build.vdf`, `depot_*.vdf`.
- Ответить, синхронизировать ли `settings.cfg`.
- macOS в Steam — после Apple Developer ID (нотаризация); пресета «Steam macOS» нет.
