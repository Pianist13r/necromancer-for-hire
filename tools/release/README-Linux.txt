NECROMANCER FOR HIRE — Linux
Death, guaranteed by contract.
Alpha version 0.3.4-alpha.
English instructions first. Русская инструкция ниже.

RUNNING THE GAME
  tar -xzf NecromancerForHire-Linux.tar.gz
  ./Necromancer/Necromancer.x86_64

  The game data is embedded in one executable. Requires x86_64 and a graphics
  card/driver with Vulkan support. Launch was checked headlessly on Ubuntu 24.04;
  desktop Linux support remains alpha.

UPDATES AND SAVES
  Installed version: Settings -> About -> Releases and updates.
  Close the game and extract the entire new release into a separate folder.
  Progress and settings are stored separately and survive updates:
  ~/.local/share/godot/app_userdata/Некромант на аутсорсе/
  Keep this folder. Its old Russian name preserves compatibility with earlier
  saves. Changing language does not require a new profile.

LANGUAGE AND DEFAULT CONTROLS
  From the main menu, Settings -> Language / Язык: choose English or Русский.
  The language setting covers menus, tutorials, cutscenes and spoken instructions.
  Keyboard bindings can be changed in Settings. The controls below are defaults.
  Left-handed mode swaps the combat mouse buttons; menu buttons still use LMB.
  LMB means left mouse button; RMB means right mouse button.

  Drag LMB              Draw a contract; nearby troops form up along the line.
  RMB on a segment      Pull back and release to slingshot the squad forward,
                        opposite to your pull. Power is always full. Release
                        while an enemy is in the gold zone for “Perfect!”.
                        Click without pulling to charge along the contract arrow.
  Draw over a line      Renew the segments you touch. Expired segments release
                        their troops to charge along their arrows.
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


НЕКРОМАНТ ПО НАЙМУ (Necromancer for Hire) — сборка для Linux
Смерть с гарантией по договору.
Альфа-версия 0.3.4-alpha.
Добровольная статистика сеансов выключена до вашего согласия; подробности — licenses/PRIVACY.md.

КАК ЗАПУСТИТЬ
  tar -xzf NecromancerForHire-Linux.tar.gz
  ./Necromancer/Necromancer.x86_64
  Один файл, игра вшита. Нужны x86_64 и видеокарта/драйвер с Vulkan.
  Сборка проверялась на запуск без экрана (сервер Ubuntu 24.04); на настольном Linux — альфа.

ГДЕ ПРОГРЕСС
  ~/.local/share/godot/app_userdata/Некромант на аутсорсе/
  (прежнее название игры — так прогресс тестеров не потерялся)

ОБНОВЛЕНИЯ
  Текущая версия: «Настройки» -> «О игре».
  Нажмите «Версии и обновления» или откройте:
  https://github.com/Pianist13r/necromancer-for-hire/releases
  Закройте игру и распакуйте новый выпуск целиком в отдельную папку.
  Прогресс и настройки хранятся отдельно и сохранятся; удалять папку сохранений не нужно.

ИГРА ПО СЕТИ
  Меню -> «Схватка» -> «По сети»: введите имя, адрес сервера уже заполнен.
  После старой версии сначала нажмите «Обновить адрес», затем «Подключиться»:
  сохранённый адрес прежнего сервера не заменяется автоматически.
  Эта же кнопка пригодится, если сервер снова переедет.
  Без сети или при недоступном файле адрес останется прежним. Его можно ввести вручную.
  Актуальный адрес опубликован в ветке main:
  https://raw.githubusercontent.com/Pianist13r/necromancer-for-hire/main/server.json
  Выберите «Играть» в чужой комнате или откройте свою. Можно играть с Windows, macOS
  и Linux; версии игры и сервера должны совпадать.

УПРАВЛЕНИЕ, ОНЛАЙН, ОШИБКИ
  https://github.com/Pianist13r/necromancer-for-hire

ЛИЦЕНЗИИ
  Папка licenses/: код — PolyForm Noncommercial 1.0.0, графика/звук/тексты — все права у автора
  (играть, стримить, снимать видео — можно), движок Godot — MIT, шрифты — SIL OFL 1.1.
  © 2026 Губанов Игорь Андреевич.
