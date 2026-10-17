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
# Таймауты: GATE_TEST_TIMEOUT_S (на тест, по умолчанию 900), GATE_SLOW_LIST (медленные тесты через запятую,
# по умолчанию legion_snapshot_test) + GATE_SLOW_TIMEOUT_S (для них, 2400), GATE_SMOKE_TIMEOUT_S (смоук, 1800).
# GATE_PAR=N (по умолчанию 1) — N самотестов одновременно, у каждого свой APPDATA внутри GATE_APPDATA;
# GATE_SERIAL_LIST (по умолчанию legion_intuit_test) — эти тесты идут после пачки по очереди.
# Mandatory exclusive policy tools/legion_gate_resources.json runs after ALL other
# tests drain, regardless of GATE_PAR/GATE_SERIAL_LIST. Capture uses fixed 8/6 GiB.
# GATE_ONLY_TEST=<имя теста или путь к .gd> — прогнать только этот тест (без check-only/gdlint/смоука).
# GATE_ONLY_TEST=legion_input_replay — полный record/replay lifecycle с отрицательными случаями.
# Итог: GATE OK (0), GATE FAIL (1), либо GATE INCOMPLETE (77) при явно неподдержанном replay.
#
# Все прогоны с --mute (звук иначе играет на колонках владельца). Чужие процессы Godot не трогаем.

set -u
# APPDATA/XDG do not redirect native macOS user://. Stop before import/check-only
# or any other engine invocation until a natively verified isolation path exists.
if [ "$(uname -s)" = Darwin ]; then
  echo "GATE INCOMPLETE: macOS userdata isolation unsupported; no engine launched"
  exit 77
fi
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
# Preserve the actual owner profile BEFORE assigning the gate's sandbox variables.
# Exclusive dispatch must not accidentally snapshot the gate profile as the owner.
OWNER_APPDATA_BEFORE_GATE="${APPDATA:-}"
OWNER_XDG_DATA_BEFORE_GATE="${XDG_DATA_HOME:-}"
# Сохранения владельца лежат в %APPDATA%/Godot/app_userdata/…: гейт туда не пишет никогда.
# 27.09.2026 прогон без песочницы оставил legion_*_test.cfg в папке Игоря (сессия 9ef4ccac).
# Своя папка данных — рядом с логами; GATE_APPDATA — задать другую.
export APPDATA="${GATE_APPDATA:-$OUT/appdata}"
export XDG_DATA_HOME="$APPDATA"
export XDG_CONFIG_HOME="$APPDATA/config"
export XDG_CACHE_HOME="$APPDATA/cache"
# Мост MCP (godot/.dev_bridge у владельца) в гейте не нужен: 173 процесса подряд ловили «порт 9090 занят»
export NECRO_NO_DEV_BRIDGE=1
export NECRO_NO_METRICS=1
mkdir -p "$APPDATA"
fails=()
unsupported=()
durations=()

# Таймауты (B-455): зависший тест (Parse Error в зависимостях → _run падает до quit()) не должен
# вешать гейт. По истечении останавливается ИМЕННО его процесс движка — по PID, никогда по имени образа.
TEST_TIMEOUT="${GATE_TEST_TIMEOUT_S:-900}"      # обычный тест, с (15 мин)
SLOW_TIMEOUT="${GATE_SLOW_TIMEOUT_S:-2400}"     # тесты из GATE_SLOW_LIST, с (40 мин)
SLOW_LIST="${GATE_SLOW_LIST:-legion_snapshot_test}"   # имена через запятую, без .gd
SMOKE_TIMEOUT="${GATE_SMOKE_TIMEOUT_S:-1800}"   # смоук, с (30 мин)
PAR="${GATE_PAR:-1}"                            # сколько самотестов гнать одновременно (1 = по очереди)
SERIAL_LIST="${GATE_SERIAL_LIST:-legion_intuit_test}"  # чувствительные ко времени: после параллельной пачки, по очереди
APPDATA_BASE="$APPDATA"
GATE_PYTHON="${PYTHON:-python}"
if ! command -v "$GATE_PYTHON" >/dev/null 2>&1 && [ -z "${PYTHON:-}" ]; then GATE_PYTHON=python3; fi

gate_fail() { echo "GATE FAIL: $*"; exit 1; }
MANDATORY_EXCLUSIVE_LIST=$("$GATE_PYTHON" tools/legion_gate_owned_test.py --exclusive-list) \
  || gate_fail "mandatory exclusive resource policy unavailable"
MANDATORY_EXCLUSIVE_LIST="${MANDATORY_EXCLUSIVE_LIST// /,}"
# Godot/Windows can resolve case variants and backslash paths to the same heavy
# fixture. Canonicalize only mandatory lookups; ordinary script/log names stay as before.
mandatory_exclusive_name() {
  local candidate="${1//\\//}"
  candidate=$(basename "$candidate")
  candidate="${candidate,,}"
  candidate="${candidate%.gd}"
  case ",$MANDATORY_EXCLUSIVE_LIST," in
    *",$candidate,"*) echo "$candidate" ;;
  esac
}
result_name() {
  local mandatory
  mandatory=$(mandatory_exclusive_name "$1")
  if [ -n "$mandatory" ]; then echo "$mandatory"; else basename "$1" .gd; fi
}
# Нечисловой лимит молча отключал бы таймаут (`[ … -ge 15m ]` — ошибка, а не «да»)
for _v in GATE_TEST_TIMEOUT_S GATE_SLOW_TIMEOUT_S GATE_SMOKE_TIMEOUT_S GATE_PAR; do
  _val="${!_v:-}"
  if [ -n "$_val" ] && ! [[ "$_val" =~ ^[0-9]+$ ]]; then gate_fail "неверный таймаут/параметр $_v='$_val' (нужно целое число)"; fi
done
[ "$PAR" -ge 1 ] || gate_fail "неверный параметр GATE_PAR='$PAR' (нужно >= 1)"

# run_timed <лимит_с> <лог> <команда…> → RUN_CODE, RUN_DUR (с), RUN_TIMEOUT (0/1), RUN_PID
run_timed() {
  local limit="$1" log="$2"; shift 2
  local start=$SECONDS
  "$@" > "$log" 2>&1 &
  RUN_PID=$!
  RUN_TIMEOUT=0
  while kill -0 "$RUN_PID" 2>/dev/null; do
    if [ $((SECONDS - start)) -ge "$limit" ]; then
      RUN_TIMEOUT=1
      local winpid
      winpid=$(cat "/proc/$RUN_PID/winpid" 2>/dev/null)
      kill "$RUN_PID" 2>/dev/null
      sleep 1
      # kill не всегда берёт нативный процесс — добиваем по Windows PID (с деревом его детей)
      if kill -0 "$RUN_PID" 2>/dev/null && [ -n "$winpid" ]; then
        taskkill //PID "$winpid" //T //F > /dev/null 2>&1
        sleep 1
      fi
      break
    fi
    sleep 1
  done
  if [ "$RUN_TIMEOUT" -eq 1 ] && kill -0 "$RUN_PID" 2>/dev/null; then
    # процесс не снялся ни kill, ни taskkill: не виснем в wait, тест уже FAIL по таймауту
    RUN_CODE=137
  else
    wait "$RUN_PID" 2>/dev/null
    RUN_CODE=$?
  fi
  RUN_DUR=$((SECONDS - start))
}

if [ -z "${SKIP_IMPORT:-}" ]; then
  # после нового class_name без импорта классы не резолвятся (грабля из CLAUDE.md проекта)
  "$GODOT" --headless --fixed-fps 60 --path godot --import -- --mute > "$OUT/import.log" 2>&1
fi

if [ -z "${GATE_ONLY_TEST:-}" ]; then
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
fi

# 3. Самотесты: все tests/legion_*_test.gd + живые тесты общего слоя (walk_transition_test —
#    CharAnim/CfgAnim, без завязки на старую игру; F0 API старой игры снят вместе с ней)
if [ -n "${GATE_ONLY_TEST:-}" ]; then
  # Один тест (имя из godot/tests без .gd, либо путь к .gd) — для отладки гейта и быстрых проб
  tests_list="${GATE_ONLY_TEST//,/ }"
else
  tests_list="$(ls godot/tests/legion_*_test.gd 2>/dev/null | xargs -n1 basename 2>/dev/null | sed 's/\.gd$//') walk_transition_test legion_input_replay"
fi
if [ -z "${tests_list//[[:space:]]/}" ]; then gate_fail "пустой список тестов"; fi
# Ключ результата и лог — basename; одинаковые имена затёрли бы друг друга и спрятали падение
dups=$(for n in $tests_list; do result_name "$n"; done | sort | uniq -d | paste -sd' ' -)
if [ -n "$dups" ]; then gate_fail "дубли имён тестов: $dups"; fi
# run_test <имя|путь.gd> — один тест: свой лог, (при GATE_PAR>1) свой APPDATA, результат в $OUT/.res/<имя>
run_test() {
  local name="$1" script logname limit summary replay_stage mandatory stamp=""
  case "$name" in
    */*) script="$name"; logname=$(basename "$name" .gd) ;;
    *) script="res://tests/$name.gd"; logname="$name" ;;
  esac
  mandatory=$(mandatory_exclusive_name "$name")
  [ -z "$mandatory" ] || logname="$mandatory"
  limit=$TEST_TIMEOUT
  case ",$SLOW_LIST," in *",$logname,"*) limit=$SLOW_TIMEOUT ;; esac
  # параллельные тесты не делят user://: у каждого свой каталог данных внутри GATE_APPDATA
  if [ "$PAR" -gt 1 ]; then
    export APPDATA="$APPDATA_BASE/$logname"
    export XDG_DATA_HOME="$APPDATA"
    export XDG_CONFIG_HOME="$APPDATA/config"
    export XDG_CACHE_HOME="$APPDATA/cache"
    mkdir -p "$APPDATA"
  fi
  if [ -n "$mandatory" ]; then
    # Native work is fixed at 120s; the outer 132s allows owned teardown. Neither
    # ordinary timeout variables nor SERIAL_LIST can weaken this resource class.
    limit=$("$GATE_PYTHON" tools/legion_gate_owned_test.py --wrapper-timeout "$logname") \
      || { echo "mandatory exclusive timeout policy unavailable"; return 1; }
    run_timed "$limit" "$OUT/$logname.log" \
      "$GATE_PYTHON" tools/legion_gate_owned_test.py --test "$logname" --godot "$GODOT" \
        --out "$OUT" --owner-appdata "$OWNER_APPDATA_BEFORE_GATE" \
        --owner-xdg-data "$OWNER_XDG_DATA_BEFORE_GATE"
  elif [[ "$logname" = legion_input_replay || "$logname" = legion_input_replay_test || "$logname" = legion_input_replay_driver ]]; then
    # The GD driver is not a standalone test: mandatory coverage includes persisted
    # recording, fresh-process playback and negatives. Never import again here.
    replay_stage=$(mktemp -d "$OUT/input-replay.XXXXXX") || { echo "replay output allocation failed"; return 1; }
    run_timed "$limit" "$OUT/$logname.log" \
      "$GATE_PYTHON" tools/replay/run_input_replay.py --engine "$GODOT" \
        --out "$replay_stage/run" --timeout "$limit"
  elif [ "$script" = res://tests/legion_daily_board_test.gd ]; then
    # This test requires a real, private loopback HTTP service. The helper owns
    # both child processes and gives this invocation a fresh DB and port.
    run_timed "$limit" "$OUT/$logname.log" \
      "$GATE_PYTHON" tools/legion_gate_daily_board.py --godot "$GODOT" --out "$OUT" \
        --appdata "$APPDATA" --timeout "$limit"
  else
    run_timed "$limit" "$OUT/$logname.log" \
      "$GODOT" --headless --path godot --fixed-fps 60 --script "$script" -- --mute
  fi
  summary=$(grep -E "[0-9]+/[0-9]+" "$OUT/$logname.log" | tail -1)
  [ "$PAR" -gt 1 ] && stamp="[$(date +%T)] "
  echo "${stamp}▶ $logname: код $RUN_CODE · $summary (${RUN_DUR} с)"
  if [ "$RUN_TIMEOUT" -eq 1 ]; then
    echo "  FAIL timeout: $logname не завершился за ${limit} с, процесс движка (PID $RUN_PID) остановлен"
  fi
  echo "$RUN_CODE $RUN_DUR $RUN_TIMEOUT $limit" > "$OUT/.res/$logname"
}

mkdir -p "$OUT/.res"
parallel_list=""; serial_part=""; exclusive_part=""
for name in $tests_list; do
  rm -f "$OUT/.res/$(result_name "$name")"
  if [ -n "$(mandatory_exclusive_name "$name")" ]; then
    exclusive_part="$exclusive_part $name"; continue
  fi
  if [ "$PAR" -gt 1 ]; then
    case ",$SERIAL_LIST," in
      *",$(basename "$name" .gd),"*) serial_part="$serial_part $name"; continue ;;
    esac
  fi
  parallel_list="$parallel_list $name"
done
if [ "$PAR" -gt 1 ]; then
  echo "параллельно: до $PAR тестов одновременно; последовательно после пачки: ${serial_part:- —}"
  for name in $parallel_list; do
    while [ "$(jobs -rp | wc -l)" -ge "$PAR" ]; do wait -n; done
    run_test "$name" &
  done
  wait
  for name in $serial_part; do run_test "$name"; done
else
  for name in $parallel_list; do run_test "$name"; done
fi
# Mandatory classes are serialized after both the parallel batch and optional
# serial tests have ended. Their own dispatcher also refuses another live engine.
for name in $exclusive_part; do run_test "$name"; done

export APPDATA="$APPDATA_BASE"
export XDG_DATA_HOME="$APPDATA"
export XDG_CONFIG_HOME="$APPDATA/config"
export XDG_CACHE_HOME="$APPDATA/cache"

# Разбор результатов — в порядке списка, одинаково для обоих режимов:
# код ≠ 0 или SCRIPT ERROR в логе = FAIL; таймаут = FAIL «timeout»
for name in $tests_list; do
  logname=$(result_name "$name")
  if ! read -r code dur tmo limit < "$OUT/.res/$logname" 2>/dev/null; then
    fails+=("$logname (нет результата)")
    continue
  fi
  durations+=("$dur $logname")
  if [ "$tmo" -eq 1 ]; then
    fails+=("$logname timeout ${limit}s")
  elif [ "$code" -eq 77 ] && [[ "$logname" = legion_input_replay || "$logname" = legion_input_replay_test || "$logname" = legion_input_replay_driver ]]; then
    unsupported+=("$logname (см. $OUT/$logname.log)")
  elif [ "$code" -ne 0 ] || grep -q "SCRIPT ERROR" "$OUT/$logname.log"; then
    fails+=("$logname")
  fi
done

# 4. Смоук: бот selective проходит карту до итога без ошибок скрипта
if [ -z "${GATE_ONLY_TEST:-}" ]; then
  MAP="${MAP:-bridge}"
  # Балансовый Стикс занимает до ~15 игровых минут на тренировочной серии.
  # Страховка 25 минут сохраняет требование настоящего итога без SCRIPT ERROR.
  run_timed "$SMOKE_TIMEOUT" "$OUT/smoke.log" \
    "$GODOT" --headless --path godot --fixed-fps 60 --quit-after 90000 res://scenes/legion.tscn \
    -- --mute --autostart --bot selective --seed 1 --map "$MAP" --quit-on-end
  durations+=("$RUN_DUR smoke")
  final=$(grep -E '^{.*"result":' "$OUT/smoke.log" | tail -1)
  errs=$(grep -c "SCRIPT ERROR" "$OUT/smoke.log")
  echo "▶ smoke $MAP: код $RUN_CODE · ошибок скрипта $errs · ${final:0:160} (${RUN_DUR} с)"
  if [ "$RUN_TIMEOUT" -eq 1 ]; then
    fails+=("smoke $MAP timeout ${SMOKE_TIMEOUT}s")
  elif [ "$RUN_CODE" -ne 0 ]; then
    fails+=("smoke $MAP code $RUN_CODE")
  elif [ -z "$final" ] || [ "$errs" -ne 0 ]; then
    fails+=("smoke $MAP")
  fi
fi

# Итог по времени: 5 самых долгих шагов
echo "Самые долгие (с):"
printf '%s\n' "${durations[@]}" | sort -rn | head -5 | sed 's/^/  /'

if [ ${#fails[@]} -eq 0 ]; then
  if [ ${#unsupported[@]} -ne 0 ]; then
    echo "GATE INCOMPLETE: unsupported ${unsupported[*]}"
    exit 77
  fi
  echo "GATE OK"
  exit 0
fi
echo "GATE FAIL: ${fails[*]}"
exit 1
