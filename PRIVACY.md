# Optional play statistics / Добровольная статистика

Starting with **0.1.1-alpha**, the game asks whether you want to help improve it by sharing basic play statistics. The default is **off**. You can play without accepting, and change your choice in Settings at any time.

With your permission, the game sends its version, operating-system family (Windows, Linux or macOS), a random identifier for this application session, a sequence number, and cumulative active battle time. It sends approximately once per minute and when leaving active play. Menus, pauses and time while the game window is unfocused are excluded. A crash or immediate exit can lose the last part of a session. A session is **not** a unique person or an installation; this feature does not identify returning players or the download source.

The recipient is the game's author, Igor Andreevich Gubanov, on the game's server in Yandex Cloud, Russia. Session records are deleted after 30 days without an accepted update; cleanup runs at startup and at least hourly while the service operates. Daily totals by version and operating system contain no session identifiers and remain until manually deleted. The session identifier exists only in game memory and changes on a new launch or after withdrawing permission. Turning sharing off cancels pending transmission and discards unsent session data; it does not retroactively remove previously received records. No offline upload queue is kept.

This feature does not collect names, emails, account details, hardware fingerprints, saves, screenshots or raw game logs. The server necessarily receives a network address to handle the connection and uses it temporarily for rate limiting; the metrics endpoint does not persist that address in its application database or HTTP access log. Hosting/network providers may process connection data under their own policies.

**Online versus play is a separate service.** The relay and its ordinary security/access logs may contain connection addresses and match diagnostics. Enabling optional direct peer-to-peer connections exposes connection addresses to the opponent. Play-statistics consent does not control those networking functions. GitHub and itch.io also maintain their own website/download statistics independently.

Questions or a bug report: https://github.com/Pianist13r/necromancer-for-hire/issues — do not post private logs or personal information publicly.

## По-русски

С версии **0.1.1-alpha** отправка игровой статистики включается только по вашему выбору. Можно отказаться и продолжить играть. Переключатель — в настройках.

Передаются версия игры, семейство ОС, случайный код текущего сеанса, номер сообщения и минуты активного боя. Не передаются имя, почта, постоянный идентификатор, сохранения, снимки экрана и полные логи. Меню, пауза и игра в фоне не входят во время боя. При аварии или быстром закрытии последние секунды могут не попасть в отчёт.

Получатель — автор игры Губанов Игорь Андреевич; сервер находится в Яндекс Облаке в России. Записи сеансов удаляются после 30 дней без обновлений: очистка выполняется при запуске службы и не реже часа, пока она работает. Общие итоги по дням, версии и системе не содержат кодов сеансов и сохраняются до ручного удаления. Код сеанса существует только в памяти игры и меняется при новом запуске. После отключения отправка прекращается, неотправленные данные удаляются из памяти; ранее полученные записи остаются до истечения срока хранения.

IP используется для соединения и временного ограничения частоты запросов, но endpoint статистики не сохраняет его в базе и журнале доступа. Сетевые журналы обычного онлайн-режима и статистика сайтов GitHub/itch.io — отдельные процессы. Эта настройка ими не управляет.

Счётчик показывает **сеансы согласившихся игроков**, а не всех игроков и не уникальных людей. Источник скачивания автоматически не определяется.
