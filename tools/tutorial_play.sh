#!/bin/bash
# Приёмка обучения «глазами игрока»: прогон сценария настоящим вводом (мышь/клавиатура через
# Input.parse_input_event — водитель godot/scripts/dev/legion_tutorial_driver.gd) окном, с роликом.
#
# Использование (из корня worktree, Git Bash):
#   tools/tutorial_play.sh good|clumsy|pause|campaign|skip|short|kind [ещё сценарии…]
#   tools/tutorial_play.sh all            # все семь подряд
# good/clumsy/pause/short/kind — бой напрямую (--map wasteland --dev tutorial=1). campaign/skip — путь
# владельца: главное меню → «Начать смену» → вступление → брифинг → бой → обучение
# (LegionMain без --map, сохранение — во временный user://legion_menu_test.cfg).
# Переменные: GODOT (путь к движку), OUT (куда класть ролики и логи; по умолчанию
# C:/AI/necro/batches/legion/v16/tutorial/after).
# На каждый сценарий: $OUT/<сценарий>.avi, $OUT/<сценарий>.log и строка JSON итога
# {"tutorial_play": …, "ok": true/false, "steps": {время зачёта каждого шага}, …}.
# Код выхода 1, если хоть один сценарий не дошёл до волн.
#
# Прогоны пишут сохранение в user://legion_standalone.cfg (бой без кампании) или в
# user://legion_menu_test.cfg (путь кампании), не в legion.cfg владельца. Звук заглушён (--mute). Пока идёт запись, мышь над окном игры не мешает: водитель
# глушит настоящий ввод, но окно лучше не трогать.

set -u
GODOT="${GODOT:-C:/Projects/SharedTools/godot/Godot_v4.7.2-stable_win64_console.exe}"
OUT="${OUT:-C:/AI/necro/batches/legion/v16/tutorial/after}"
mkdir -p "$OUT"
export APPDATA="${APPDATA_TUTORIAL:-$OUT/appdata}"
export NECRO_NO_DEV_BRIDGE=1
mkdir -p "$APPDATA"
scenarios=("$@")
if [ ${#scenarios[@]} -eq 0 ] || [ "${scenarios[0]}" = "all" ]; then
  scenarios=(good clumsy pause campaign skip short kind)
fi
fail=0
for s in "${scenarios[@]}"; do
  # clumsy ждёт по 20+ с на каждом шаге — запас кадров больше
  frames=3600
  [ "$s" = "clumsy" ] && frames=9000
  case "$s" in
    campaign|skip) game_args=(--dev save=user://legion_menu_test.cfg) ;;
    *) game_args=(--map wasteland --dev tutorial=1) ;;
  esac
  "$GODOT" --path godot --write-movie "$OUT/$s.avi" --fixed-fps 30 --quit-after "$frames" \
    -- --mute "${game_args[@]}" --dev tutorial_play="$s" > "$OUT/$s.log" 2>&1
  line=$(grep -E '^\{.*"tutorial_play"' "$OUT/$s.log" | tail -1)
  errs=$(grep -c "SCRIPT ERROR" "$OUT/$s.log")
  echo "$s: ошибок скрипта $errs · ${line:-нет итога (упёрся в --quit-after)}"
  if [ -z "$line" ] || [ "$errs" -ne 0 ] || ! echo "$line" | grep -q '"ok":true'; then
    fail=1
  fi
done
exit $fail
