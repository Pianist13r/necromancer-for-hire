#!/usr/bin/env bash
# Сквозная проба онлайн-«Схватки»: свой ретранслятор + два клиента (host/guest) с ботами через
# настоящий сокет. Совпали отпечатки на каждом 60-м тике (ретранслятор молчит про desync) и
# итоговый отпечаток — lockstep держится.
#   tools/net_duel.sh [карта] [игровые_секунды] [порт] [url]
#   url пустой — свой ретранслятор на 127.0.0.1:порт; иначе (wss://…) — внешний, свой не поднимаем.
# HOST_EXTRA / GUEST_EXTRA — аргументы пробы каждому клиенту; GODOT_FLAGS — движку обоих клиентов
# (по умолчанию «--max-fps 60» — реальное время, как у людей). С «--fixed-fps 60» проба бежит
# быстрее часов — с протокола 2 ретранслятор рвёт такого клиента («ход раньше времени»), так что
# его — только против внешнего сервера старой версии.
set -u
cd "$(dirname "$0")/.."
MAP="${1:-pvp:duel}"
LIMIT="${2:-240}"
PORT="${3:-18799}"
URL="${4:-}"
GODOT="${GODOT:-C:/Projects/SharedTools/godot/Godot_v4.7.2-stable_win64_console.exe}"
OUT="${OUT:-$(mktemp -d)}"
mkdir -p "$OUT"
export NECRO_NO_DEV_BRIDGE=1
RELAY=""
if [ -z "$URL" ]; then
	APPDATA="$OUT/relay_appdata" "$GODOT" --headless --path godot \
		--script res://scripts/legion/net/net_relay.gd -- --mute --port "$PORT" \
		> "$OUT/relay.log" 2>&1 &
	RELAY=$!
	URL="ws://127.0.0.1:$PORT"
	sleep 3
fi
run() {
	mkdir -p "$OUT/$1_appdata"
	APPDATA="$OUT/$1_appdata" timeout 2400 "$GODOT" --headless --path godot ${GODOT_FLAGS---max-fps 60} \
		--script res://tests/net_duel_probe.gd -- --mute --url "$URL" --role "$1" --map "$MAP" \
		--limit "$LIMIT" $2 > "$OUT/$1.log" 2>&1
	echo $? > "$OUT/$1.code"
}
run host "${HOST_EXTRA:-}" &
H=$!
sleep 2
run guest "${GUEST_EXTRA:-}" &
G=$!
wait $H $G
[ -n "$RELAY" ] && kill "$RELAY" 2>/dev/null
grep -h "NET_DUEL" "$OUT/host.log" "$OUT/guest.log"
grep -hE "РАССИНХРОН|разошлась|судья|итог судьи" "$OUT/relay.log" 2>/dev/null | head -8
grep -hc "SCRIPT ERROR" "$OUT/host.log" "$OUT/guest.log" | paste -sd' ' | sed 's/^/SCRIPT ERROR host guest: /'
python -X utf8 - "$OUT" <<'PY'
import json, sys, pathlib
out = pathlib.Path(sys.argv[1])
r = {}
for role in ("host", "guest"):
    for line in (out / f"{role}.log").read_text(encoding="utf-8", errors="replace").splitlines():
        if line.startswith("NET_DUEL "):
            r[role] = json.loads(line[9:])
if len(r) < 2:
    print("ИТОГ: нет результата одного из клиентов"); sys.exit(1)
h, g = r["host"], r["guest"]
same = h["digest"] == g["digest"] and h["tick"] == g["tick"]
ok = same and h["desync"] < 0 and g["desync"] < 0 and h["why"] == g["why"] == "ok"
print(f"ИТОГ: {'OK' if ok else 'FAIL'} — тик {h['tick']}/{g['tick']}, отпечаток "
      f"{'совпал' if same else 'РАЗНЫЙ'}, desync {h['desync']}/{g['desync']}, "
      f"команд {h['cmds_sent']}/{g['cmds_sent']}, стоял до {h['max_stall_s']}/{g['max_stall_s']} с, "
      f"стена {h['wall_s']:.0f}/{g['wall_s']:.0f} с")
sys.exit(0 if ok else 1)
PY
CODE=$?
echo "логи: $OUT"
exit $CODE
