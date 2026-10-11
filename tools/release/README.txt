NECROMANCER FOR HIRE — Windows
Death, guaranteed by contract.
Alpha version 0.3.4-alpha.
English instructions first. Русская инструкция ниже.

Draw a glowing contract with the mouse. Skeleton contractors form up along it
and hold back inspectors from Hell before they reach the Soul Cauldron. The
contract expires segment by segment, releasing troops to charge. Upon Expiry
combines tower defense, action and roguelike progression: a campaign, generated
endless runs, a Daily Challenge and Skirmish against a bot or another player.

RUNNING THE GAME
  1. Extract the entire archive into a folder. Do not run it from inside the ZIP.
  2. Run Necromancer.exe. Necromancer.pck must be beside it with that exact name:
     it contains the game data, and the executable cannot run without it.
     A single-file edition embeds the data and needs no .pck:
     NecromancerForHire-Windows.exe on GitHub, or the Necromancer-single folder
     when building from source.
  3. The executable has no digital signature. If Windows says “Windows protected
     your PC”, and you trust this download, choose More info -> Run anyway.
  Requirements: 64-bit Windows 10/11 and a Vulkan-capable graphics card/driver.
  No installation is needed.

UPDATES AND SAVES
  Installed version: Settings -> About. Choose Releases and updates, or open:
  https://github.com/Pianist13r/necromancer-for-hire/releases
  Close the game, then replace the single-file executable or extract the whole
  new archive into a separate folder. Progress and settings are stored separately:
  %APPDATA%\Godot\app_userdata\Некромант на аутсорсе\
  Keep this folder. Its old Russian name is intentional for save compatibility.
  Changing language does not require a new profile.

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


НЕКРОМАНТ ПО НАЙМУ (Necromancer for Hire)
Смерть с гарантией по договору.
Альфа-версия 0.3.4-alpha.

СТАТИСТИКА (ДОБРОВОЛЬНО)
  При первом запуске можно разрешить отправку версии, системы и минут активного боя.
  По умолчанию выключено. Можно отказаться или отключить в настройках.
  Имена, сохранения и полные логи не отправляются. Подробности — licenses/PRIVACY.md.

Режим «По истечении договора». Некромант открыл ИП и сдаёт скелетов-подрядчиков по
договорам. Мышью чертишь договор — светящуюся линию, скелеты встают на неё строем и держат
проверяющих из Ада на подходе к Котлу Душ. Договор истекает участками, и отпущенные бойцы
идут в натиск. Кампания на картах с извилистыми дорогами, три вида бойцов (подрядчик,
вахтёр, счетовод), постройки на участках, способности некроманта; между картами — поправки,
«Контора» и прокачка героя, в финале — босс «Прораб», которого надо сломать.

КАК ЗАПУСТИТЬ
  1. Распакуйте архив в любую папку (целиком, не запускайте из архива).
  2. Запустите Necromancer.exe.
     Файл Necromancer.pck должен лежать рядом с Necromancer.exe и называться так же:
     в нём вся игра, без него exe не запустит игру.
     Есть и вариант одним файлом (игра вшита, pck не нужен): на GitHub —
     NecromancerForHire-Windows.exe, в сборке из исходников — папка Necromancer-single.
     Скачать свежую версию: https://github.com/Pianist13r/necromancer-for-hire/releases
  3. Если Windows покажет «Windows защитила ваш компьютер» (файл без цифровой подписи):
     «Подробнее» -> «Выполнить в любом случае».
  Нужно: Windows 10/11 64-бит, видеокарта с поддержкой Vulkan. Установка не нужна.

ОБНОВЛЕНИЯ
  Текущая версия: «Настройки» -> «О игре».
  Нажмите «Версии и обновления» или откройте:
  https://github.com/Pianist13r/necromancer-for-hire/releases
  Закройте игру и замените exe одним файлом либо распакуйте новый архив целиком
  в отдельную папку. Прогресс и настройки хранятся отдельно и сохранятся;
  удалять папку сохранений не нужно.

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

УПРАВЛЕНИЕ
  ЛКМ (зажать и вести)   — начертить договор; бойцы в радиусе встают на линию строем
  ПКМ по участку: оттянуть назад и отпустить
                         — рогатка: отряд срывается в натиск в сторону, обратную оттяжке;
                           сила всегда полная, длина оттяжки её не меняет. Отпустил, когда
                           враг в золотой зоне, — «Точно!»: удар сильнее. Щелчок ПКМ без оттяжки —
                           натиск по стрелке договора
  Подрисовать поверх     — продлить срок задетых участков (растаявший участок сам уходит
                           в натиск по своей стрелке)
  Пробел (зажать)        — стрелка для таяния: пока чертишь, мышь указывает, куда отряд
                           уйдёт, когда линия растает; над готовой линией — повернуть её
  Таб                    — стереть участок договора
  F или N / «Вызвать»    — следующая волна сейчас (панель справа вверху показывает её состав),
                           за сэкономленные секунды начисляются души
  Клик по площадке       — постройка (покупка за души, улучшение, продажа); в меню написано,
                           кого выпускает каждая постройка и под какой договор
  1 / 2 / 3 или колесо   — вид договора: подряд, охрана, аудит (по мере открытия)
  Q / W / E              — способности некроманта: зажать — прицел, отпустить — применить
  R                      — сбор бойцов к курсору (когда откроется)
  D                      — Касса (в одиночной игре)
  Esc / P                — пауза (там же «Настройки» и выход в меню)
  Всё подробно — в меню «Как играть».

С ЧЕГО НАЧАТЬ
  Большая кнопка в меню ведёт на следующую карту кампании («Продолжить: …»), «Карты» —
  выбор открытой карты. Первая игра начинается с обучения; повторить его можно
  в «Как играть» -> «Обучение».
  Начать кампанию с нуля: меню -> «Настройки» -> «Сбросить прогресс…» (звук и экран
  останутся).

Настройки и прогресс кампании сохраняются в %APPDATA%\Godot\app_userdata\Некромант на аутсорсе\

Сделано на Godot Engine 4.7.2 (MIT, https://godotengine.org/license).
Текст лицензии движка — в папке licenses/GODOT_LICENSE.txt внутри архива GitHub
или в меню «Настройки» → «Лицензии».
