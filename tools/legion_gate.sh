#!/bin/bash
# Гейт режима «По истечении договора» (SLICE_SPEC §7) одной командой.
#
# Зачем: пакеты сессии v13 идут параллельно в разных worktree, и каждый обязан пройти один и тот же
# гейт. Раньше его собирали руками из четырёх команд — агенты пропускали то тесты, то старую игру.
#
# Использование (из корня worktree, Git Bash):
#   tools/legion_gate.sh            # полный гейт
#   SKIP_IMPORT=1 tools/legion_gate.sh   # без --import, если классы не менялись
# Переменные: GODOT (путь к движку), OUT (куда класть логи; по умолчанию C:/AI/necro/batches/legion/gate),
# GATE_APPDATA (папка данных движка; по умолчанию $OUT/appdata — сохранения владельца не трогаются).
# Последняя строка: «GATE OK» или «GATE FAIL: <что упало>»; код выхода 0/1.
#
# Все прогоны с --mute (звук иначе играет на колонках владельца). Чужие процессы Godot не трогаем.

set -u
# Движок и папка логов по умолчанию — машины владельца; у остальных (публичный репозиторий) —
# `godot` из PATH и batches/gate (папка уже в .gitignore). Переопределяются GODOT= и OUT=.
_own_godot=C:/Projects/SharedTools/godot/Godot_v4.7.2-stable_win64_console.exe
if [ -z "${GODOT:-}" ]; then
  if [ -x "$_own_godot" ]; then GODOT="$_own_godot"; else GODOT=godot; fi
fi
if [ -z "${OUT:-}" ]; then
  if [ -d C:/AI/necro ]; then OUT="C:/AI/necro/batches/legion/gate/$(basename "$(pwd)")"
  else OUT="batches/gate"; fi
fi
mkdir -p "$OUT"
# Сохранения владельца лежат в %APPDATA%/Godot/app_userdata/…: гейт туда не пишет никогда.
# 27.09.2026 прогон без песочницы оставил legion_*_test.cfg в папке Игоря (сессия 9ef4ccac).
# Своя папка данных — рядом с логами; GATE_APPDATA — задать другую.
export APPDATA="${GATE_APPDATA:-$OUT/appdata}"
# Мост MCP (godot/.dev_bridge у владельца) в гейте не нужен: 173 процесса подряд ловили «порт 9090 занят»
export NECRO_NO_DEV_BRIDGE=1
mkdir -p "$APPDATA"
fails=()

if [ -z "${SKIP_IMPORT:-}" ]; then
  # после нового class_name без импорта классы не резолвятся (грабля из CLAUDE.md проекта)
  "$GODOT" --headless --fixed-fps 60 --path godot --import -- --mute > "$OUT/import.log" 2>&1
fi

# 1. Синтаксис и типы: весь новый режим + общий слой, унаследованный от старой игры
#    (scripts/game и scripts/ui выпилены v15-removal, docs/legion/DESIGN_V15.md §10)
n=0
for f in $(find godot/scripts/legion godot/scripts/common godot/scripts/dev -name '*.gd' | sort); do
  n=$((n + 1))
  res="res://${f#godot/}"
  if "$GODOT" --headless --fixed-fps 60 --path godot --check-only --script "$res" -- --mute 2>&1 | grep -qE "SCRIPT ERROR|Parse Error|ERROR:"; then
    fails+=("check-only $f")
  fi
done
echo "check-only: $n файлов, ошибок ${#fails[@]}"

# 2. Линтер нового режима
if ! gdlint godot/scripts/legion > "$OUT/gdlint.log" 2>&1; then
  fails+=("gdlint (см. $OUT/gdlint.log)")
fi
echo "gdlint: $(tail -1 "$OUT/gdlint.log")"

# 3. Самотесты: все tests/legion_*_test.gd + живые тесты общего слоя (walk_transition_test —
#    CharAnim/CfgAnim, без завязки на старую игру; F0 API старой игры снят вместе с ней)
for t in $(ls godot/tests/legion_*_test.gd 2>/dev/null) godot/tests/walk_transition_test.gd; do
  name=$(basename "$t" .gd)
  "$GODOT" --headless --path godot --fixed-fps 60 --script "res://tests/$name.gd" -- --mute > "$OUT/$name.log" 2>&1
  code=$?
  summary=$(grep -E "[0-9]+/[0-9]+" "$OUT/$name.log" | tail -1)
  echo "$name: код $code · $summary"
  if [ $code -ne 0 ] || grep -q "SCRIPT ERROR" "$OUT/$name.log"; then
    fails+=("$name")
  fi
done

# 4. Смоук: бот selective проходит карту до итога без ошибок скрипта
MAP="${MAP:-bridge}"
# Балансовый Стикс занимает до ~15 игровых минут на тренировочной серии.
# Страховка 25 минут сохраняет требование настоящего итога без SCRIPT ERROR.
"$GODOT" --headless --path godot --fixed-fps 60 --quit-after 90000 res://scenes/legion.tscn \
  -- --mute --autostart --bot selective --seed 1 --map "$MAP" --quit-on-end > "$OUT/smoke.log" 2>&1
final=$(grep -E '^{.*"result":' "$OUT/smoke.log" | tail -1)
errs=$(grep -c "SCRIPT ERROR" "$OUT/smoke.log")
echo "smoke $MAP: ошибок скрипта $errs · ${final:0:160}"
if [ -z "$final" ] || [ "$errs" -ne 0 ]; then
  fails+=("smoke $MAP")
fi

if [ ${#fails[@]} -eq 0 ]; then
  echo "GATE OK"
  exit 0
fi
echo "GATE FAIL: ${fails[*]}"
exit 1
