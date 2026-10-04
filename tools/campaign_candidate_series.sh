#!/bin/bash
# Строгая парная серия по замороженным внешним JSON; в res:// карты не копирует.
# Пример: tools/campaign_candidate_series.sh C:/absolute/candidates archive selective base 91 92

set -u
candidate_dir="${1:?candidate directory}"; map="${2:?map id}"; policy="${3:?bot policy}"
profile="${4:?profile name}"; shift 4
seeds=("$@"); [ ${#seeds[@]} -eq 0 ] && seeds=(91 92 93 94 95)
GODOT="${GODOT:-C:/Projects/SharedTools/godot/Godot_v4.7.2-stable_win64_console.exe}"
OUT="${OUT:-$(pwd)/batches/campaign_candidates/${map}_${policy}_${profile}}"
FRAMES="${FRAMES:-60000}"
PAR="${PAR:-1}"
[[ "$PAR" = 1 ]] || { echo 'strict candidate series is sequential; set PAR=1' >&2; exit 2; }
[[ "$candidate_dir" = /* || "$candidate_dir" =~ ^[A-Za-z]:[/\\] ]] || {
  echo 'candidate-dir must be absolute' >&2; exit 2;
}
for id in wasteland gatehouse fork archive bridge maze swamp boss; do
  [[ -f "$candidate_dir/$id.json" ]] || { echo "missing candidate: $id" >&2; exit 2; }
done
[[ -f "$candidate_dir/manifest.json" ]] || { echo 'missing candidate manifest' >&2; exit 2; }
if [[ -e "$OUT" ]] && [[ -n "$(find "$OUT" -mindepth 1 -print -quit)" ]]; then
  echo "OUT must be new or empty: $OUT" >&2; exit 2
fi
git diff --quiet && git diff --cached --quiet \
  || { echo 'working tree must be clean to freeze the series revision' >&2; exit 2; }
[[ -z "$(git status --porcelain)" ]] \
  || { echo 'working tree must be clean to freeze the series revision' >&2; exit 2; }
head_before="$(git rev-parse HEAD)" || exit 2
candidate_sha() {
  (cd "$candidate_dir" && for file in *.json; do sha256sum "$file"; done \
    | LC_ALL=C sort | sha256sum | cut -d' ' -f1)
}
candidate_sha_before="$(candidate_sha)" || exit 2
mkdir -p "$OUT"
export APPDATA="${SERIES_APPDATA:-$OUT/appdata}"
mkdir -p "$APPDATA"
tag="${map//:/_}"

run_one() {
  side="$1"; seed="$2"
  "$GODOT" --headless --path godot --fixed-fps 60 --quit-after "$FRAMES" \
    --script res://tests/legion_campaign_candidate_balance_runner.gd -- \
    --mute --autostart --bot "$policy" --seed "$seed" --map "$map" --side "$side" \
    --dev "profile=$profile" --candidate-dir "$candidate_dir" --quit-on-end \
    > "$OUT/${tag}_${policy}_${profile}_${side}_s${seed}.log" 2>&1
}

failed=0
for side in canonical candidate; do
  for seed in "${seeds[@]}"; do
    run_one "$side" "$seed" || failed=1
  done
done
head_after="$(git rev-parse HEAD)" || failed=1
candidate_sha_after="$(candidate_sha)" || failed=1
if [[ "$head_before" != "$head_after" || "$candidate_sha_before" != "$candidate_sha_after" ]]; then
  echo 'REJECT: Git HEAD or candidate JSON bundle changed during paired series' >&2
  failed=1
fi
python tools/validate_campaign_candidate_series.py --out "$OUT" --map "$map" \
  --policy "$policy" --profile "$profile" --seeds "$(IFS=,; echo "${seeds[*]}")" \
  --tag "$tag" --head-before "$head_before" --head-after "$head_after" \
  --candidate-sha-before "$candidate_sha_before" --candidate-sha-after "$candidate_sha_after" \
  || failed=1
exit "$failed"
