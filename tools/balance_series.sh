#!/bin/bash
# Серия балансовых прогонов игры с фиксированными сидами.
#
# Зачем: один прогон — это шум. В сессии v6 одиночный замер показывал победу там, где серия
# из шести сидов даёт поражение. Баланс правится по РАСПРЕДЕЛЕНИЮ, а не по одному запуску.
#
# Почему быстро: --fixed-fps 60 отвязывает игровое время от реального, а --quit-on-end
# завершает процесс сразу после итога матча. Все сиды идут параллельно.
#
# Использование (из C:\Projects\Necromancer):
#   tools/balance_series.sh --demo 1 2 3 4 5 6                        # средний игрок (демо-бот)
#   tools/balance_series.sh --idle 1 2 3 4 5 6                        # никто не играет
#   tools/balance_series.sh --demo --difficulty manager 1 2 3 4 5 6   # явная сложность
#
# Переменные окружения: GODOT (путь к движку), OUT (куда класть логи), FRAMES (лимит кадров —
# страховка от зависания; по умолчанию 60000 = 1000 игровых секунд).
#
# Ориентиры приёмки среза v6 (3 волны; если они поехали — баланс сломан):
#   без игрока  — поражение 6 из 6;
#   демо-бот    — победа 5 из 6, медиана остатка котла ~32 из 160.
#
# В последней строке каждого прогона: "phase":4 — победа, "phase":5 — поражение, "hp" — котёл.

set -u
GODOT="${GODOT:-C:/Projects/SharedTools/godot/Godot_v4.7.2-stable_win64_console.exe}"
OUT="${OUT:-C:/AI/necro/assets/balance}"
FRAMES="${FRAMES:-60000}"

mode="${1:---idle}"
shift || true
# старый вызов с пустым режимом ("") — это «без игрока»
[ -z "$mode" ] && mode="--idle"

difficulty=""
if [ "${1:-}" = "--difficulty" ]; then
  difficulty="${2:-}"
  shift 2 || true
fi
seeds=("$@")
[ ${#seeds[@]} -eq 0 ] && seeds=(1 2 3 4 5 6)

extra=()
[ -n "$difficulty" ] && extra=(--difficulty "$difficulty")

mkdir -p "$OUT"
tag="${mode//-/}"
[ -n "$difficulty" ] && tag="${tag}_${difficulty}"

for seed in "${seeds[@]}"; do
  "$GODOT" --headless --path godot --fixed-fps 60 --quit-after "$FRAMES" \
    -- --autostart --mute --trace --quit-on-end --seed "$seed" "$mode" "${extra[@]}" \
    > "$OUT/s_${seed}_${tag}.log" 2>&1 &
done
wait

echo "режим: $mode · сложность: ${difficulty:-по умолчанию} · лимит кадров: $FRAMES"
for seed in "${seeds[@]}"; do
  f="$OUT/s_${seed}_${tag}.log"
  errors=$(grep -c "SCRIPT ERROR" "$f")
  printf "seed=%-3s ошибок=%-3s %s\n" "$seed" "$errors" \
    "$(grep '^{' "$f" | tail -1 | sed 's/,"far[^,]*//;s/,"lines[^,]*//;s/,"rising[^,]*//;s/,"mana[^,]*//')"
done
