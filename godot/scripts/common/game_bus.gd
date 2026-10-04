class_name GameBus
extends Node
##
## Шина событий — раньше единственный канал старого режима (F0) для боевых сигналов; при
## выпиле `scripts/game/*` (v15-removal, docs/legion/DESIGN_V15.md §10) весь список сигналов
## о сущностях старой игры (Enemy/Skeleton/Ally/RuneLine/WavePlan и т.п.) снят вместе с ними —
## их эмитеров и подписчиков в проекте больше нет. Оставлен только контракт, который реально
## использует общий код: `Settings.set()` уведомляет `GameBus.inst.settings_changed`, если
## экземпляр вообще создан (в режиме «По истечении договора» `inst` никто не заводит —
## LegionMain/LegionWorld его не используют, поэтому ветка всегда false, но тип должен
## существовать — Settings типизирован статически).
##

signal settings_changed(key: String, value: Variant)

static var inst: GameBus = null
