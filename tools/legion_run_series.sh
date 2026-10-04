#!/bin/bash
# Серия забегов «Бесконечного подряда» цепочкой (B-358): забеги × сиды бота → таблица по номеру
# объекта. В отличие от tools/legion_series.sh (одна карта gen:<забег>:<k> за прогон), бот идёт
# объектами 1..N ОДНОГО забега через настоящий поток игры и копит поправки, артефакты, покупки
# «Конторы», стаж и души, как игрок (раннер godot/tests/legion_run_chain_runner.gd).
#
# Использование (из корня worktree, Git Bash):
#   tools/legion_run_series.sh selective 3341246352,7,11 91 92 93 94
#   OBJECTS=5 DEV="difficulty=hell run_shop=off" tools/legion_run_series.sh selective 7 91 92
# Аргументы: политика бота, забеги через запятую, сиды бота (по умолчанию 91 92 93 94).
# Переменные: GODOT, OUT (логи; по умолчанию C:/AI/necro/batches/legion/series/<worktree>),
# OBJECTS (N объектов, 10), PAR (сколько забегов сразу, 1..3, по умолчанию 3), WALL (секунд
# реального времени на забег — страховка от зависшего процесса, 3600), DEV (доп. --dev key=val
# раннера через пробел), SERIES_APPDATA (папка данных движка; по умолчанию $OUT/appdata).
# Лог на прогон: <OUT>/run_<забег>_<политика>_s<сид>.log. Сводка — tools/legion_run_series_sum.py.
# Всё — с --mute и APPDATA-песочницей; чужие процессы Godot не трогаем.

set -u
GODOT="${GODOT:-C:/Projects/SharedTools/godot/Godot_v4.7.2-stable_win64_console.exe}"
policy="${1:?политика бота}"; runs_csv="${2:?забеги через запятую}"; shift 2
seeds=("$@"); [ ${#seeds[@]} -eq 0 ] && seeds=(91 92 93 94)
IFS=',' read -r -a runs <<< "$runs_csv"
OUT="${OUT:-C:/AI/necro/batches/legion/series/$(basename "$(pwd)")}"
OBJECTS="${OBJECTS:-10}"
PAR="${PAR:-3}"
WALL="${WALL:-3600}"
[[ "$PAR" =~ ^[1-3]$ ]] || { echo 'PAR must be 1..3'; exit 2; }
[[ "$OBJECTS" =~ ^[1-9][0-9]*$ ]] || { echo 'OBJECTS must be a positive integer'; exit 2; }
for v in "${runs[@]}" "${seeds[@]}"; do
  [[ "$v" =~ ^[0-9]+$ ]] || { echo "Invalid seed: $v"; exit 2; }
done
mkdir -p "$OUT"
# Как в legion_gate.sh/legion_series.sh: своя папка данных движка, папку владельца не трогаем.
# Сохранение раннера у каждого прогона своё (user://legion_run_chain_<забег>_<сид>.cfg).
export APPDATA="${SERIES_APPDATA:-$OUT/appdata}"
mkdir -p "$APPDATA"
# параллельные движки не спорят за порт моста MCP (9090)
export NECRO_NO_DEV_BRIDGE=1
extra=()
for kv in ${DEV:-}; do extra+=(--dev "$kv"); done

run_one() {
  local run="$1" seed="$2"
  timeout "$WALL" "$GODOT" --headless --path godot --fixed-fps 60 \
    --script res://tests/legion_run_chain_runner.gd -- --mute \
    --dev run_seed="$run" --dev bot_seed="$seed" --dev bot="$policy" \
    --dev run_objects="$OBJECTS" "${extra[@]}" \
    > "$OUT/run_${run}_${policy}_s${seed}.log" 2>&1
  local code=$?
  # 124 — сработал timeout: процесс завис целиком (не таймаут боя — тот раннер пишет сам)
  echo "exit=$code" >> "$OUT/run_${run}_${policy}_s${seed}.log"
}

i=0
logs=()
for r in "${runs[@]}"; do
  for s in "${seeds[@]}"; do
    logs+=("$OUT/run_${r}_${policy}_s${s}.log")
    run_one "$r" "$s" &
    i=$((i + 1))
    # 12 ГБ видеопамяти и 34 ГБ RAM делят с другими сессиями
    if [ $((i % PAR)) -eq 0 ]; then wait; fi
  done
done
wait

python "$(dirname "$0")/legion_run_series_sum.py" "$OBJECTS" "${logs[@]}"
