NECROMANCER FOR HIRE — macOS
Death, guaranteed by contract.
Alpha version 0.4.1-alpha.

NEW IN 0.4.1
  Campaign briefings show a loading screen before the first battle.
  Optional pentagon guides help you draw the shape by hand:
  Pause > How to play > Help draw a Commission. Click to pin the guides,
  then trace the corners with a separate continuous stroke. The old lesson
  pentagon is hidden while help is enabled; Esc restores it.
  The first lesson explains Shift. Shape examples stop animating after
  six seconds; the D example is clearer. Clerk shots are easier to see,
  and enemy crypts use a short nearby label.
  Campaign pacing and the Swamp difficulty step still need further testing.

NEW IN 0.4.0
  Contractors charge; guards move a cohesive front and keep their shield facing
  when retreating; clerks stay at their posts and fire a directional rolling barrage.
  Pull distance controls the reach of guard and clerk orders.
  The preview shows the path and obstacles. Shape recognition and pen feedback
  are improved; staffing and shape charge are shown separately.
  Some sparse, ambiguous outlines and the Archives tutorial still need work.
  Online play requires version 0.4.0 for both players and the server.
English instructions first. Русская инструкция ниже.

CONTENTS
  The .app is a universal build for Intel and Apple Silicon. It is the same game
  as the Windows edition. No account is required. Saves are local; the campaign
  and single-player battles work offline.

INSTALLATION
  1. Double-click the downloaded ZIP. The built-in Archive Utility extracts it;
     no third-party extractor is required.
  2. Move the extracted .app into Applications.
  3. Open the game from Launchpad or Finder.

FIRST LAUNCH
  The build is ad-hoc signed using Godot's built-in signing and is NOT notarized
  by Apple. Gatekeeper may therefore say that the application cannot be verified.
  If you trust this build, allow this application specifically:
    System Settings -> Privacy & Security -> Open Anyway
  next to the message about the application.
  Use a normal double-click on subsequent launches.

REQUIREMENTS AND TESTING LIMITS
  Universal binary: Intel or Apple Silicon.
  Intel: macOS 11.0 or newer. Apple Silicon: macOS 13.0 or newer.
  Metal-capable graphics for the Mobile renderer.
  This build was made on Windows and checked structurally only: ZIP integrity,
  Info.plist and .pck presence, and executable permissions. It has not been run
  on a physical Mac. If it fails, report your macOS version and processor type.

UPDATES AND SAVES
  Installed version: Settings -> About -> Releases and updates.
  https://github.com/Pianist13r/necromancer-for-hire/releases
  Close the game, extract the new release and replace the app in Applications.
  Progress and settings are stored separately and survive updates:
  ~/Library/Application Support/Godot/app_userdata/Некромант на аутсорсе/
  Keep this folder. Its old Russian name is retained for save compatibility.
  Changing language does not require a new profile.

LANGUAGE AND DEFAULT CONTROLS
  From the main menu, Settings -> Language / Язык: choose English or Русский.
  The language setting covers menus, tutorials, cutscenes and spoken instructions.
  Keyboard bindings can be changed in Settings. The controls below are defaults.
  Left-handed mode swaps the combat mouse buttons; menu buttons still use LMB.
  LMB means left mouse button; RMB means right mouse button.

  Drag LMB              Draw a contract; nearby troops form up along the line.
  RMB on a segment      Pull back and release to order troops opposite to the pull:
                        contractors charge, guards move, clerks fire from their posts.
                        Pull distance sets guard/clerk reach; contractor power is full.
                        Release with an enemy in the gold zone for “Perfect!”.
                        Click without pulling to order along the contract arrow.
  Draw over a line      Renew the segments you touch. Expired segments issue
                        each troop role's order along their arrows.
  Hold Space or wheel   Aim the melting arrow while drawing, or turn the arrow
                        of an existing line. Move the mouse to choose direction.
  Tab                   Erase a contract section.
  F or N / Call Wave    Bring the next wave now; time saved earns souls.
  Click a plot          Buy, upgrade or sell a building. Its menu explains the
                        troops it produces and the contract type they use.
  1 / 2 / 3 or wheel    Contract type: Contract Work, Security, Audit, as unlocked.
  Q / W / E             Abilities: hold to aim, release to cast.
  R                     Rally troops to the cursor, once unlocked.
  D                     Cash Desk, in single player.
  Esc / P               Pause single-player battles. Online battles keep running.
  Full instructions and the tutorial are in How to Play.

GETTING STARTED
  The large menu button continues the campaign; Maps lets you choose an unlocked
  map. Your first game includes a tutorial. Replay it via How to Play -> Tutorial.
  To start the campaign over: Settings -> Reset Progress. This is permanent;
  sound and display settings are kept.

ONLINE SKIRMISH
  Main menu -> Skirmish -> Online: enter a name. The server address is prefilled.
  After upgrading an old version, use Refresh address, then Connect: a saved
  address is not replaced automatically. Use the same button if the server moves.
  If the address file is unavailable or you are offline, the current address is
  kept. You can enter it manually. The public address is published on main:
  https://raw.githubusercontent.com/Pianist13r/necromancer-for-hire/main/server.json
  Join another room with Play or open your own. Windows, macOS and Linux can play
  together; game and server versions must match. Direct peer-to-peer connections
  are optional and expose connection addresses to your opponent.

OPTIONAL PLAY STATISTICS
  Off until you consent. The game asks at first launch; you may decline and play.
  You can change your choice in Settings. With permission, the game sends its
  version, OS family, a random session ID, sequence number and active battle time.
  Names, saves, screenshots and full logs are not sent. Online networking is a
  separate service. Details, recipient and retention: licenses/PRIVACY.md.

HELP AND LICENSES
  Releases: https://github.com/Pianist13r/necromancer-for-hire/releases
  Bugs: https://github.com/Pianist13r/necromancer-for-hire/issues
  Include your OS, game version and steps to reproduce; do not post private logs.
  Made with Godot Engine 4.7.2 (MIT, https://godotengine.org/license).
  Code: PolyForm Noncommercial 1.0.0. Art, audio, texts and characters: all rights
  reserved, with permission to play, stream and make videos. See licenses/.
  The Godot license is in licenses/GODOT_LICENSE.txt in the GitHub archive
  and in Settings -> Licenses.
  Copyright 2026 Igor Andreevich Gubanov.

============================================================
РУССКАЯ ИНСТРУКЦИЯ
Язык из главного меню: «Настройки» -> Язык / Language -> Русский или English.
============================================================


Некромант по найму (Necromancer for Hire) — сборка для macOS
=========================================
Альфа-версия 0.4.1-alpha.

НОВОЕ В 0.4.1
  Перед первым боем из брифинга кампании показывается экран загрузки.
  Добровольная помощь пятиугольнику: Пауза > Как играть >
  «Помочь нарисовать Комиссию». Щелчок закрепляет ориентиры; затем
  отдельным непрерывным штрихом обведите углы. Esc убирает ориентиры.
  Первый урок объясняет Шифт. Через шесть секунд образец фигуры
  становится неподвижным; D показана яснее. Полёт печатей заметнее,
  а надпись вражеского склепа стала короткой и находится у постройки.
  Темп кампании и скачок сложности на Болоте требуют отдельной проверки.

НОВОЕ В 0.4.0
  Подрядчики идут в натиск; вахтёры двигают связный фронт, сохраняя направление
  щитов при отходе; счетоводы остаются на постах и ведут направленный огневой вал.
  Длина оттяжки задаёт дальность приказа вахтёров и счетоводов.
  Прицел показывает путь и преграды. Фигуры лучше распознаются; у пера видны
  замыкание, цена и результат, а набор бойцов отделён от заряда фигуры.
  Редкие неоднозначные контуры и обучение на «Архиве» ещё требуют доработки.
  Для сетевой игры обоим игрокам и серверу нужна версия 0.4.0.
Добровольная статистика сеансов выключена до вашего согласия; подробности — licenses/PRIVACY.md.

Что внутри
----------
Приложение .app — универсальная сборка для Intel и Apple Silicon.
Игра та же, что и в версии для Windows, без аккаунтов; сохранения лежат
локально в папке пользователя. Кампания и одиночные бои — офлайн.

Игра по сети
------------
Меню -> «Схватка» -> «По сети»: введите имя, адрес сервера уже заполнен.
После старой версии сначала нажмите «Обновить адрес», затем «Подключиться»:
сохранённый адрес прежнего сервера не заменяется автоматически.
Эта же кнопка пригодится, если сервер снова переедет.
Без сети или при недоступном файле адрес останется прежним. Его можно ввести вручную.
Актуальный адрес опубликован в ветке main:
https://raw.githubusercontent.com/Pianist13r/necromancer-for-hire/main/server.json
Выберите «Играть» в чужой комнате или откройте свою. Можно играть с Windows, macOS
и Linux; версии игры и сервера должны совпадать.

Обновления и прогресс
--------------------
Текущая версия: «Настройки» -> «О игре». Нажмите «Версии и обновления» или откройте:
https://github.com/Pianist13r/necromancer-for-hire/releases
Закройте игру, распакуйте новый выпуск и замените приложение в «Программах».
Прогресс и настройки хранятся отдельно и сохранятся:
~/Library/Application Support/Godot/app_userdata/Некромант на аутсорсе/
Удалять эту папку не нужно; прежнее название сохранено для совместимости.

Установка
---------
1. Дважды щёлкните по скачанному zip-архиву — macOS распакует его штатным
   «Раскрыть архив» (Archive Utility); сторонние распаковщики не нужны.
2. Перетащите распакованное приложение .app в папку «Программы» (Applications).
3. Откройте игру как обычно — из Launchpad или Finder.

Первый запуск
-------------
Сборка подписана ad-hoc (встроенной подписью Godot) и НЕ нотаризована Apple,
поэтому при первом запуске Gatekeeper может предупредить: «не удалось
проверить приложение». Это ожидаемо для сборок без нотаризации.

Если вы доверяете этой сборке, разрешите её открытие:
  Системные настройки -> Конфиденциальность и безопасность ->
  кнопка «Открыть в любом случае» (Open Anyway) рядом с сообщением
  о приложении.

При следующем запуске используйте обычный двойной щелчок.

Требования
----------
- macOS на процессоре Intel или Apple Silicon (один универсальный бинарник).
- Intel: macOS 11.0 или новее. Apple Silicon: macOS 13.0 или новее.
- Графика с поддержкой Metal для рендерера Mobile.

Важно
-----
Сборка сделана на Windows и проверена только структурно: целостность zip,
наличие Info.plist и .pck внутри, права запуска у исполняемого файла.
На настоящем Mac её не запускали — если что-то не заведётся, сообщите
автору версию macOS и тип процессора.
