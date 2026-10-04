#!/usr/bin/env bash
# Спайк сети PvP (docs/pvp/DESIGN.md §10): безголовый сервер Godot + два клиента на localhost.
# НЕ гейт игры — доказательство каркаса и замеры. Четыре прогона:
#   base  — 150 бойцов, 2 клиента, 20 снимков/с
#   big   — 320 бойцов (2×140 своих + 40 проверяющих — потолок PvP 1 на 1)
#   abuse — вредный клиент (залп, длинный пакет, точка за полем) + клиент с чужим кодом
#   nocap — как base, но сервер без Engine.max_fps: сколько процессора ест холостой цикл
# Итог — tools/net_spike_check.py: проверки и сводка. Последняя строка — NET SPIKE OK / FAIL.
#
#   bash tools/net_spike.sh [OUT_DIR]
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GODOT="${GODOT:-C:/Projects/SharedTools/godot/Godot_v4.7.2-stable_win64_console.exe}"
OUT="${1:-C:/AI/necro/batches/pvp/net_spike/$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUT/appdata"
# папка данных движка — песочница: иначе прогон пишет в сохранения владельца
export APPDATA="$OUT/appdata"
PORT_BASE="${PORT_BASE:-24580}"
DUR=10

srv() {  # имя порт аргументы-сервера...
	local name="$1" port="$2"; shift 2
	"$GODOT" --headless --path "$ROOT/godot" --script res://scripts/net_spike/spike_server.gd \
		-- --mute --port "$port" --duration $((DUR + 6)) "$@" > "$OUT/$name.server.log" 2>&1 &
	SRV_PID=$!
	for _ in $(seq 1 50); do
		grep -q '"listening"' "$OUT/$name.server.log" 2>/dev/null && return 0
		sleep 0.2
	done
	echo "сервер $name не поднялся"; return 1
}

cli() {  # имя порт метка аргументы-клиента...
	local name="$1" port="$2" tag="$3"; shift 3
	"$GODOT" --headless --path "$ROOT/godot" --script res://scripts/net_spike/spike_client.gd \
		-- --mute --port "$port" --duration $DUR "$@" > "$OUT/$name.$tag.log" 2>&1 &
	PIDS+=($!)
}

cpu_of() {  # порт → секунды процессора своего сервера (см. net_spike_cpu.ps1)
	powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$ROOT/tools/net_spike_cpu.ps1" \
		-Port "$1" 2>/dev/null | tr -d '\r'
}

run() {  # имя порт [args-сервера] -- клиенты: normal|evil|badcode ...
	local name="$1" port="$2"; shift 2
	local sargs=()
	while [ $# -gt 0 ] && [ "$1" != "--" ]; do sargs+=("$1"); shift; done
	shift
	srv "$name" "$port" "${sargs[@]}" || return 1
	# клиенты запускаются в этой же оболочке (не в $(...)): иначе wait их не увидит
	PIDS=()
	local i=0
	for kind in "$@"; do
		i=$((i + 1))
		case "$kind" in
			normal) cli "$name" "$port" "c$i" ;;
			evil) cli "$name" "$port" "c$i" --evil ;;
			badcode) cli "$name" "$port" "c$i" --badcode ;;
		esac
	done
	sleep 3
	local c0 c1
	c0=$(cpu_of "$port"); sleep 4; c1=$(cpu_of "$port")
	echo "{\"role\": \"cpu\", \"cpu_s_start\": \"$c0\", \"cpu_s_end\": \"$c1\", \"window_s\": 4}" \
		> "$OUT/$name.cpu.log"
	for p in "${PIDS[@]}"; do wait "$p"; done
	wait "$SRV_PID"
	echo "прогон $name: сервер вышел с кодом $?"
}

run base $((PORT_BASE + 0)) --units 150 -- normal normal
run big $((PORT_BASE + 1)) --units 320 -- normal normal
run abuse $((PORT_BASE + 2)) --units 150 -- evil badcode
run nocap $((PORT_BASE + 3)) --units 150 --max-fps 0 -- normal normal
python "$ROOT/tools/net_spike_check.py" "$OUT"
