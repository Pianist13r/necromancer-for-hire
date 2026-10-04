#!/bin/bash
# Серия медленной сессии slow/challenge: карты × {полный, только подряд} на «Штатном» и полный на
# «Стажёре» (сверка с прежними числами). Каталоги: $ROOT/{normal-full,normal-lab,intern-full}.
#
# Использование (из корня worktree, Git Bash):
#   ROOT=C:/AI/necro/batches/legion/series/challenge-after tools/challenge_series.sh "fork bridge" 91 92 93
# Переменные: ROOT (обязательно), SETS (какие наборы, по умолчанию все три), PAR (по умолчанию 2).
set -u
maps="${1:?карты через пробел}"; shift
seeds=("$@"); [ ${#seeds[@]} -eq 0 ] && seeds=(91 92 93 94 95 96 97 98)
: "${ROOT:?ROOT}"
SETS="${SETS:-normal-full normal-lab intern-full}"
export PAR="${PAR:-2}"
for set in $SETS; do
  case "$set" in
    normal-full) dev="difficulty=normal" ;;
    normal-lab) dev="kinds=laborer" ;;      # «Штатный» — уровень агентного прогона по умолчанию
    intern-full) dev="difficulty=intern" ;;
    intern-lab) dev="difficulty=intern kinds=laborer" ;;
    hell-full) dev="difficulty=hell" ;;
    *) echo "неизвестный набор $set"; exit 2 ;;
  esac
  for m in $maps; do
    OUT="$ROOT/$set" DEV="$dev" bash tools/legion_series.sh "$m" selective "${seeds[@]}"
  done
done
echo ALLDONE
