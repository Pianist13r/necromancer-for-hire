#!/usr/bin/env bash
# Регресс атак обманщика на ретранслятор онлайн-«Схватки» (пробы verifier №2 01.10):
#   1) tests/net_attack_probe.gd — повтор хода честного в жалобе (B1, сразу и через очередь) и
#      придержанный «ready» с ходами по часам (A1);
#   2) tests/net_cheat_host.gd + настоящий гость (tests/net_duel_probe.gd --role guest) — честного
#      не выбивает за «ходы не доходят до сервера», отключается обманщик.
#   tools/net_attack.sh [порт=18881]
# Последняя строка — «NET ATTACK OK» / «NET ATTACK FAIL»; логи — $OUT.
set -u
cd "$(dirname "$0")/.."
PORT="${1:-18881}"
GODOT="${GODOT:-C:/Projects/SharedTools/godot/Godot_v4.7.2-stable_win64_console.exe}"
OUT="${OUT:-C:/AI/necro/net/attack/$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUT/appdata"
export APPDATA="$OUT/appdata" NECRO_NO_DEV_BRIDGE=1
CODE=0
"$GODOT" --headless --path godot --script res://scripts/legion/net/net_relay.gd -- --mute \
	--port "$PORT" --judges 0 > "$OUT/relay1.log" 2>&1 &
R1=$!
sleep 3
timeout 300 "$GODOT" --headless --path godot --script res://tests/net_attack_probe.gd -- --mute \
	--port "$PORT" > "$OUT/attack.log" 2>&1 || CODE=1
kill "$R1" 2>/dev/null
grep -E "ATTACK|NET ATTACK" "$OUT/attack.log"
if grep -q "SCRIPT ERROR" "$OUT/relay1.log"; then
	echo "FAIL: SCRIPT ERROR в ретрансляторе (атаки 1–8)"
	grep -m3 -A2 "SCRIPT ERROR" "$OUT/relay1.log"
	CODE=1
fi
P2=$((PORT + 1))
"$GODOT" --headless --path godot --script res://scripts/legion/net/net_relay.gd -- --mute \
	--port "$P2" --judges 0 > "$OUT/relay2.log" 2>&1 &
R2=$!
sleep 3
timeout 120 "$GODOT" --headless --path godot --script res://tests/net_cheat_host.gd -- --mute \
	--port "$P2" > "$OUT/cheat.log" 2>&1 &
C=$!
sleep 2
timeout 300 "$GODOT" --headless --path godot --max-fps 60 --script res://tests/net_duel_probe.gd \
	-- --mute --url "ws://127.0.0.1:$P2" --role guest --limit 60 > "$OUT/guest.log" 2>&1
wait "$C"
kill "$R2" 2>/dev/null
grep -h "CHEAT:" "$OUT/cheat.log"
GID=$(grep -o "игрок [0-9]* «probe-guest» вошёл" "$OUT/relay2.log" | grep -o "[0-9]*" | head -1)
if grep -q "игрок $GID отключён: ходы не доходят" "$OUT/relay2.log"; then
	echo "FAIL: честного гостя выбило за «ходы не доходят до сервера»"
	CODE=1
elif ! grep -q "раньше времени" "$OUT/relay2.log"; then
	echo "FAIL: обманщик, гнавший ходы без общего старта, не отключён"
	CODE=1
else
	echo "cheat_host: честный гость на месте, обманщик отключён: $(grep -o "отключён: ход [0-9]* раньше времени[^)]*)" "$OUT/relay2.log" | head -1)"
fi
# 3) verifier №3: обманщик-хозяин гонит ходы по часам, честный гость медленный (6 кадров/с) или с
#    заминками 1,5 с раз в 6 с — сервер не рвёт честного, тот доигрывает, отпечатки с судьёй сходятся
grief() {   # имя порт лимит_с флаги_движка флаги_пробы
	local d="$OUT/$1"
	mkdir -p "$d"
	APPDATA="$d" "$GODOT" --headless --path godot --script res://scripts/legion/net/net_relay.gd \
		-- --mute --port "$2" > "$d/relay.log" 2>&1 &
	local r=$!
	sleep 3
	APPDATA="$d" timeout 400 "$GODOT" --headless --path godot --script res://tests/net_grief_host.gd \
		-- --mute --port "$2" > "$d/host.log" 2>&1 &
	local h=$!
	sleep 2
	APPDATA="$d" timeout 400 "$GODOT" --headless --path godot $4 --script res://tests/net_duel_probe.gd \
		-- --mute --url "ws://127.0.0.1:$2" --role guest --limit "$3" $5 > "$d/guest.log" 2>&1
	kill "$h" "$r" 2>/dev/null
	python -X utf8 - "$d" "$1" "$3" <<'PY'
import json, sys, pathlib
d, name, lim = pathlib.Path(sys.argv[1]), sys.argv[2], int(sys.argv[3])
g = {}
for l in (d / "guest.log").read_text(encoding="utf-8", errors="replace").splitlines():
    if l.startswith("NET_DUEL "):
        g = json.loads(l[9:])
relay = (d / "relay.log").read_text(encoding="utf-8", errors="replace")
gid = ""
for l in relay.splitlines():
    if "«probe-guest» вошёл" in l:
        gid = l.split("игрок ")[1].split(" ")[0]
cut = any(f"игрок {gid} отключён:" in l and "закрыл соединение" not in l
          for l in relay.splitlines())   # сам закрыл в конце пробы — не разрыв сервером
ok = g.get("why") == "ok" and g.get("tick") == lim * 60 and g.get("desync", 0) < 0 and not cut \
    and "разошлась" not in relay
print(f"grief {name}: {'OK' if ok else 'FAIL'} — гость {g.get('why')}, тик {g.get('tick')}/{lim * 60}, "
      f"рассинхрон {g.get('desync')}, отключён сервером: {'да' if cut else 'нет'}, "
      f"стена {g.get('wall_s')} с")
sys.exit(0 if ok else 1)
PY
	return $?
}
grief slow6 $((PORT + 2)) 45 "--max-fps 6" "" || CODE=1
grief freeze $((PORT + 3)) 130 "--max-fps 60" "--freeze-ms 1500" || CODE=1
# 4) verifier №4: запросы «void»/«no_ready» не превращаются в выход честного.
#    race1/race2 — обманщик держит копии и сбрасывает их за миг до «void» честного (пинг 200 / 60 мс);
#    stall1 — у честного 45 с стоит приём с сервера (без умысла);
#    rr1 — обманщик шлёт «ready» через 29,9 с после «ready» честного (гонка с отменой загрузки).
#    Честный не получает сдачу: матч идёт дальше (запрос отклонён) или прерван без итога.
pair() {   # имя порт лимит_с флаги_host флаги_guest
	local d="$OUT/$1"
	mkdir -p "$d"
	APPDATA="$d" "$GODOT" --headless --path godot --script res://scripts/legion/net/net_relay.gd \
		-- --mute --port "$2" > "$d/relay.log" 2>&1 &
	local r=$!
	sleep 3
	APPDATA="$d" timeout 500 "$GODOT" --headless --path godot --max-fps 60 \
		--script res://tests/net_duel_probe.gd -- --mute --url "ws://127.0.0.1:$2" --role host \
		--limit "$3" $4 > "$d/host.log" 2>&1 &
	local h=$!
	sleep 2
	APPDATA="$d" timeout 500 "$GODOT" --headless --path godot --max-fps 60 \
		--script res://tests/net_duel_probe.gd -- --mute --url "ws://127.0.0.1:$2" --role guest \
		--limit "$3" $5 > "$d/guest.log" 2>&1
	wait "$h"
	kill "$r" 2>/dev/null
	verdict "$d" "$1"
}
verdict() {   # каталог имя — честный (гость) не получил сдачу, сервер его не рвал
	python -X utf8 - "$1" "$2" <<'PY'
import json, sys, pathlib
d, name = pathlib.Path(sys.argv[1]), sys.argv[2]
r = {}
for role in ("host", "guest"):
    p = d / f"{role}.log"
    if p.exists():
        for l in p.read_text(encoding="utf-8", errors="replace").splitlines():
            if l.startswith("NET_DUEL "):
                r[role] = json.loads(l[9:])
relay = (d / "relay.log").read_text(encoding="utf-8", errors="replace")
g, h = r.get("guest", {}), r.get("host", {})
lost = "как выход" in relay or h.get("remote_left") or "отключён: ход" in relay
fine = g.get("why") == "ok" or str(g.get("why", "")).startswith("aborted: Матч прерван") \
    or str(g.get("why", "")).startswith("aborted: Матч отменён")
denied = [l.split("] ", 1)[-1] for l in relay.splitlines() if "отклонен" in l or "прерван без" in l]
ok = fine and not lost
print(f"{name}: {'OK' if ok else 'FAIL'} — гость {g.get('why')}, тик {g.get('tick')}, хозяину "
      f"«соперник ушёл»: {'да' if h.get('remote_left') else 'нет'}; " + " | ".join(denied[:2]))
sys.exit(0 if ok else 1)
PY
}
pair race1 $((PORT + 4)) 80 "--vhold 600 --vhold-ms 90000 --race-ms 29800" "--down-lat 200" || CODE=1
pair race2 $((PORT + 5)) 80 "--vhold 600 --vhold-ms 90000 --race-ms 29900" "--down-lat 60" || CODE=1
pair stall1 $((PORT + 6)) 90 "" "--down-stall-tick 1800 --down-stall-ms 45000" || CODE=1
d="$OUT/rr1"
mkdir -p "$d"
P=$((PORT + 7))
APPDATA="$d" "$GODOT" --headless --path godot --script res://scripts/legion/net/net_relay.gd \
	-- --mute --port "$P" --judges 0 > "$d/relay.log" 2>&1 &
R=$!
sleep 3
APPDATA="$d" timeout 200 "$GODOT" --headless --path godot --script res://tests/net_ready_race_host.gd \
	-- --mute --port "$P" --race 29900 > "$d/host.log" 2>&1 &
H=$!
sleep 2
APPDATA="$d" timeout 200 "$GODOT" --headless --path godot --max-fps 60 \
	--script res://tests/net_duel_probe.gd -- --mute --url "ws://127.0.0.1:$P" --role guest \
	--limit 30 > "$d/guest.log" 2>&1
kill "$H" "$R" 2>/dev/null
grep -h "VFR" "$d/host.log"
verdict "$d" rr1 || CODE=1
echo "логи: $OUT"
if [ $CODE -eq 0 ]; then echo "NET ATTACK OK"; else echo "NET ATTACK FAIL"; fi
exit $CODE
