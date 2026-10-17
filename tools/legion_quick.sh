#!/bin/bash
# Только явно выбранные тесты; общий гейт остаётся в legion_gate.sh.
set -eu
usage() {
  echo 'Usage: bash tools/legion_quick.sh [--import] legion_name_test [another_test ...]'
}
if [ "${1:-}" = '--help' ]; then usage; exit 0; fi
export SKIP_IMPORT=1
if [ "${1:-}" = '--import' ]; then unset SKIP_IMPORT; shift; fi
if [ "$#" -eq 0 ]; then usage >&2; exit 2; fi
tests=()
for name in "$@"; do
  if ! [[ "$name" =~ ^[a-zA-Z0-9_]+$ ]] || [ ! -f "godot/tests/$name.gd" ]; then
    echo "Unknown test: $name (use basename without .gd)" >&2
    exit 2
  fi
  tests+=("$name")
done
export GATE_ONLY_TEST
GATE_ONLY_TEST=$(IFS=,; echo "${tests[*]}")
export OUT="${OUT:-$(pwd)/local/qa/quick-$(date +%Y%m%d-%H%M%S)-$$}"
export NECRO_NO_METRICS=1
echo "TARGETED ONLY: $GATE_ONLY_TEST; logs: $OUT"
bash tools/legion_gate.sh
echo 'TARGETED OK (full release gate not run)'
