#!/bin/bash
# Серия «Схватки» бот против бота без окна (docs/pvp/DESIGN.md §11, линия L1).
#
# Использование (из корня worktree, Git Bash):
#   tools/pvp_series.sh 1 2 3 … 20             # сиды
# Переменные: MAP (по умолчанию pvp:duel), PAR (сколько боёв сразу, 1), OUT (папка логов,
# C:/AI/necro/batches/pvp/series/<метка времени>), GODOT, EXTRA (доп. аргументы после --).
# На каждый сид — лог <OUT>/s<N>.log; сводка — <OUT>/summary.txt: победитель, причина, время, HP.
# Всё — с --mute и APPDATA-песочницей (сохранения владельца не трогаются). Чужие процессы не трогаем.
set -u -o pipefail
GODOT="${GODOT:-C:/Projects/SharedTools/godot/Godot_v4.7.2-stable_win64_console.exe}"
MAP="${MAP:-pvp:duel}"
PAR="${PAR:-1}"
OUT="${OUT:-C:/AI/necro/batches/pvp/series/$(date +%Y%m%d-%H%M%S)}"
[[ "$PAR" =~ ^[1-9][0-9]*$ ]] || { echo "PAR must be a positive integer" >&2; exit 2; }
(( $# > 0 )) || { echo "Provide at least one seed" >&2; exit 2; }
declare -A seen=()
for seed in "$@"; do
  [[ "$seed" =~ ^[0-9]+$ ]] || { echo "Invalid seed: $seed" >&2; exit 2; }
  [[ -z "${seen[$seed]+yes}" ]] || { echo "Duplicate seed: $seed" >&2; exit 2; }
  seen[$seed]=1
done
mkdir -p "$OUT"
# предел кадров — страховка: матч сам кончается пределом 12 мин (43 200 шагов)
run() {
  mkdir -p "$OUT/appdata-s$1"
  APPDATA="$OUT/appdata-s$1" "$GODOT" --headless --path godot --fixed-fps 60 --quit-after 50000 res://scenes/legion_world.tscn \
    -- --mute --map "$MAP" --pvp-bots --seed "$1" --quit-on-end ${EXTRA:-} > "$OUT/s$1.log" 2>&1
}
failed=0
pids=()
join_batch() {
  local pid
  for pid in "${pids[@]}"; do
    wait "$pid" || failed=1
  done
  pids=()
}
for s in "$@"; do
  run "$s" &
  pids+=("$!")
  if (( ${#pids[@]} >= PAR )); then join_batch; fi
done
join_batch
python -X utf8 tools/pvp_series_sum.py "$OUT" "$@" | tee "$OUT/summary.txt" || failed=1
exit "$failed"
