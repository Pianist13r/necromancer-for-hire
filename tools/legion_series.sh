#!/bin/bash
# Серия прогонов режима «По истечении договора» ботом: карта × политика × сиды → таблица.
#
# Зачем: баланс и проверки концепции правятся по распределению, а не по одному запуску
# (урок сессии v6). --fixed-fps 60 отвязывает игровое время от реального, сиды идут параллельно.
#
# Использование (из корня worktree, Git Bash):
#   tools/legion_series.sh bridge selective 1 2 3 4 5
#   DEV="gray=1" tools/legion_series.sh maze hold 1 2 3     # доп. флаги --dev key=val (через пробел)
# Переменные: GODOT, OUT (каталог логов; по умолчанию C:/AI/necro/batches/legion/series/<worktree>),
# FRAMES (страховка от зависания; 60000 = 1000 игровых секунд), PAR (сколько сидов параллельно, 4).
# SUMMARY_ONLY=1 — не гонять бои, а только пересобрать сводку из итоговых строк лежащих логов сидов.
# Две серии с одной картой и политикой НЕ идут в один OUT одновременно (B-063: вторая затирала логи
# первой, и сводка первой считалась по чужим логам) — вторая отказывается с кодом 3. Сводка
# пишется ещё и файлом $OUT/<карта>_<политика>.summary.
# Вывод: строка на сид — итог JSON из --quit-on-end, затем сводка «побед N/M, медиана HP котла».

set -u
GODOT="${GODOT:-C:/Projects/SharedTools/godot/Godot_v4.7.2-stable_win64_console.exe}"
map="${1:?карта}"; policy="${2:?политика бота}"; shift 2
seeds=("$@")
if [ ${#seeds[@]} -eq 0 ]; then
  # B-386 (3): пересборка сводки без сидов брала бы 91–95 молча и могла собрать сводку по чужим
  # логам или «нет итога» — явная ошибка лучше; для обычной серии 91–95 по умолчанию остаются.
  if [ "${SUMMARY_ONLY:-0}" = "1" ]; then
    echo "SUMMARY_ONLY=1 требует явных сидов: tools/legion_series.sh $map $policy 91 92 ..." >&2
    exit 2
  fi
  seeds=(91 92 93 94 95)
fi
OUT="${OUT:-$(pwd)/batches/v16/balance/series}"
FRAMES="${FRAMES:-60000}"
PAR="${PAR:-3}"
[[ "$PAR" =~ ^[1-3]$ ]] || { echo 'PAR must be 1..3'; exit 2; }
# процедурная карта gen:<сид>:<объект> — двоеточие в имени файла Windows не допускает
tag="${map//:/_}"
mkdir -p "$OUT"
# Как в legion_gate.sh: движок — со своей папкой данных, папку владельца в %APPDATA% не трогаем
# (27.09.2026, сессия 9ef4ccac). SERIES_APPDATA — задать другую.
export APPDATA="${SERIES_APPDATA:-$OUT/appdata}"
mkdir -p "$APPDATA"
extra=()
# несколько флагов — через пробел: DEV="difficulty=intern kinds=laborer" (slow/challenge)
for kv in ${DEV:-}; do extra+=(--dev "$kv"); done

summarize() {
  local wins=0 hps=() s f line errs hp med
  for s in "${seeds[@]}"; do
    f="$OUT/${tag}_${policy}_s$s.log"
    line=$(grep -E '^{.*"result":' "$f" 2>/dev/null | tail -1)
    errs=$(grep -c "SCRIPT ERROR" "$f" 2>/dev/null)
    [ -z "$line" ] && line="(нет итога — завис или упал, см. $f)"
    echo "seed=$s ошибок=${errs:-0} $line"
    if echo "$line" | grep -q '"result":"victory"'; then wins=$((wins + 1)); fi
    hp=$(echo "$line" | grep -oE '"hp":[0-9.]+' | cut -d: -f2)
    [ -n "$hp" ] && hps+=("$hp")
  done
  med=$(printf '%s\n' "${hps[@]:-0}" | sort -n | awk '{a[NR]=$1} END {print (NR ? a[int((NR+1)/2)] : "-")}')
  echo "ИТОГ $map/$policy: побед $wins/${#seeds[@]}, медиана HP котла $med"
}

if [ "${SUMMARY_ONLY:-0}" = "1" ]; then
  summarize | tee "$OUT/${tag}_${policy}.summary"
  exit 0
fi

# замок на ключ «карта+политика» в этом OUT: живой чужой запуск — отказ, мёртвый (упал) — снимаем
# B-386 (2): замок появляется СРАЗУ с pid внутри — pid пишется во временный каталог, а тот
# переименовывается в замок одним действием (mv -T не вложит каталог в существующий замок и не
# перезапишет непустой). Раньше между mkdir и записью pid было окно: второй запуск видел замок без
# pid, считал его мёртвым и снимал.
lock="$OUT/.${tag}_${policy}.lock"
take_lock() {
  local tmp
  tmp=$(mktemp -d "$OUT/.lock-new.XXXXXX") || return 1
  echo $$ > "$tmp/pid"
  mv -T "$tmp" "$lock" 2>/dev/null && return 0
  rm -rf "$tmp"
  return 1
}
if ! take_lock; then
  other=$(cat "$lock/pid" 2>/dev/null)
  if [ -n "$other" ] && kill -0 "$other" 2>/dev/null; then
    echo "OUT $OUT уже занят серией $map/$policy (PID $other): логи затирали бы друг друга. Другой OUT или дождись."
    exit 3
  fi
  rm -rf "$lock"; take_lock || exit 3
fi
trap 'rm -rf "$lock"' EXIT

run_one() {
  "$GODOT" --headless --path godot --fixed-fps 60 --quit-after "$FRAMES" res://scenes/legion.tscn \
    -- --mute --autostart --bot "$policy" --seed "$1" --map "$map" --quit-on-end "${extra[@]}" \
    > "$OUT/${tag}_${policy}_s$1.log" 2>&1
}

i=0
for s in "${seeds[@]}"; do
  run_one "$s" &
  i=$((i + 1))
  # ограничиваем параллельность: 12 ГБ видеопамяти и 34 ГБ RAM делят с другими сессиями
  if [ $((i % PAR)) -eq 0 ]; then wait; fi
done
wait

summarize | tee "$OUT/${tag}_${policy}.summary"
