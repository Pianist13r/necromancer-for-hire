#!/usr/bin/env bash
# Сквозная проба прямого соединения онлайн-«Схватки» (docs/pvp/NET_LOCKSTEP.md, «Прямое
# соединение»): свой ретранслятор (с судьёй) + два клиента-бота на этой машине в реальном времени:
#   a  прямой путь (частный LAN-адрес машины; 127.0.0.1 в живой игре не используется) выбран,
#      отпечатки совпадают весь матч, в relay.log строки пути «напрямую»
#   b  UDP заглушён (--udp-off) — запасной путь через сервер, матч доходит до конца
#   c  потеря 30 % входящих UDP — матч идёт, отпечатки совпадают (избыточность ходов)
#   d  подлог: host с хода 40 шлёт напрямую не то, что серверу — у guest прямой путь выключен,
#      сервер доказал подмену по HMAC, техническое поражение host
#   e  копия ходов host на сервер опаздывает на 4 с (лаг WebSocket/Funnel или придержка) — guest
#      не стоит (копия в пределах 10 с), никто не отключён, матч доходит до конца (verifier 01.10, A)
#   f  host придерживает копию на 25 с — guest стоит «Соперник не передаёт ходы на сервер…» (меньше
#      30 с за раз) и продолжает, когда копии приходят; никого не рвут, матч доходит до конца
#   h  придержка 45 с — простой guest дольше 30 с: матч прерван БЕЗ итога у обоих (не сдача)
#   g  подлог при копии на сервер позже на 400 мс (подменённый ход у guest применён первым, как в
#      живой игре) — вердикт «подмена хода», победа guest (verifier 01.10, B)
#   tools/net_p2p_duel.sh [сценарии=abcdefgh] [игровые_секунды=120] [порт=18831]
# Итог — по строке на сценарий и «P2P DUEL OK|FAIL»; логи — $OUT/<сценарий>/.
set -u
cd "$(dirname "$0")/.."
WHICH="${1:-abcdefgh}"
LIMIT="${2:-120}"
PORT="${3:-18831}"
OUT="${OUT:-C:/AI/necro/net/p2p_duel/$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUT"
fails=()
n=0
for sc in a b c d e f g h; do
	case "$WHICH" in *$sc*) ;; *) continue ;; esac
	n=$((n + 1))
	p=$((PORT + n))
	lim="$LIMIT"
	case $sc in
		a) H="" ; G="" ;;
		b) H="--udp-off" ; G="--udp-off" ;;
		c) H="--udp-loss 30" ; G="--udp-loss 30" ;;
		d) H="--forge 40" ; G="" ;;
		e) H="--vhold 200 --vhold-ms 4000" ; G="" ;;
		f) H="--vhold 200 --vhold-ms 25000" ; G="" ; [ "$lim" -lt 60 ] && lim=60 ;;
		g) H="--forge 40 --vhold 0 --vhold-ms 400" ; G="" ;;
		h) H="--vhold 200 --vhold-ms 45000" ; G="" ; [ "$lim" -lt 90 ] && lim=90 ;;
	esac
	# реальное время (--max-fps 60 без --fixed-fps): иначе клиенты бегут быстрее часов, стоят друг
	# из-за друга, и задержка растёт по опозданиям, которых у живых игроков не было бы (проверено)
	OUT="$OUT/$sc" HOST_EXTRA="--direct 1 $H" GUEST_EXTRA="--direct 1 $G" GODOT_FLAGS="${GODOT_FLAGS---max-fps 60}" \
		bash tools/net_duel.sh pvp:duel "$lim" "$p" \
		> "$OUT/$sc.txt" 2>&1
	code=$?
	python -X utf8 - "$OUT/$sc" "$sc" "$code" <<'PY'
import json, re, sys, pathlib
out, sc, code = pathlib.Path(sys.argv[1]), sys.argv[2], int(sys.argv[3])
r = {}
for role in ("host", "guest"):
    p = out / f"{role}.log"
    if p.exists():
        for line in p.read_text(encoding="utf-8", errors="replace").splitlines():
            if line.startswith("NET_DUEL "):
                r[role] = json.loads(line[9:])
relay = (out / "relay.log").read_text(encoding="utf-8", errors="replace") \
    if (out / "relay.log").exists() else ""
lines = relay.splitlines()
paths = [l for l in lines if "в одну сторону" in l]
proven = [l for l in lines if "ПОДМЕНА ХОДА ДОКАЗАНА" in l]
desync_relay = [l for l in lines if "разошлась" in l or "РАССИНХРОН" in l]
dropped = [l for l in lines if "отключён:" in l and "закрыл соединение" not in l
           and "матч закрыт" not in l]
ids = {m.group(2): m.group(1) for m in re.finditer(r"игрок (\d+) «([^»]+)» вошёл", relay)}
errs = sum((out / f"{x}.log").read_text(encoding="utf-8", errors="replace").count("SCRIPT ERROR")
           for x in ("host", "guest", "relay") if (out / f"{x}.log").exists())
if len(r) < 2:
    print(f"{sc}: FAIL — нет результата клиента"); sys.exit(1)
h, g = r["host"], r["guest"]
same = h["digest"] == g["digest"] and h["tick"] == g["tick"]
judge_ok = not desync_relay
short = lambda x: (f"путь {x['path']} задержка {x['delay']} «{x['link']}» udp-первым "
                   f"{x['first_via']} итог {x['why']}")
if sc == "a":
    ok = code == 0 and same and judge_ok and h["path"] == g["path"] == "p2p" \
        and any("напрямую" in l for l in paths) and h["first_via"].get("udp", 0) > 0
elif sc == "b":
    ok = code == 0 and same and judge_ok and h["path"] == g["path"] == "relay" \
        and sum("через сервер" in l for l in paths) >= 2
elif sc == "c":
    ok = code == 0 and same and judge_ok and h["path"] == g["path"] == "p2p" \
        and h["first_via"].get("udp", 0) > 0 and g["first_via"].get("udp", 0) > 0
elif sc == "e":
    ok = code == 0 and same and judge_ok and not dropped and h["why"] == g["why"] == "ok" \
        and g["max_hold_s"] == 0
elif sc == "f":
    ok = code == 0 and same and judge_ok and not dropped and h["why"] == g["why"] == "ok" \
        and 3 <= g["max_hold_s"] < 30 and not any("прерван" in l for l in lines)
elif sc == "h":
    voided = [l for l in lines if "матч прерван без итога — сторона 1 «probe-guest»" in l]
    ok = bool(voided) and not dropped and g["why"].startswith("aborted: Матч прерван") \
        and h["why"].startswith("aborted: Матч прерван") and not g["remote_left"]
else:
    # d, g: подлог доказан по HMAC — поражение подменщику (host, сторона 0), победа guest
    ok = g["mismatch"] >= 40 and h["mismatch"] < 0 and g["forge_cheater"] == 0 \
        and h["forge_cheater"] == 0 and any("сторона 0 «probe-host»" in l for l in proven)
# сводка матча обеих сторон (Игорь 01.10) — в a и b
summ = [l for l in lines if re.search(r"итог стороны [01] «probe-(host|guest)»: ", l)]
if sc in ("a", "b"):
    ok = ok and len(summ) == 2 and not any("не пришёл" in l for l in lines)
ok = ok and errs == 0
print(f"{sc}: {'OK' if ok else 'FAIL'} — тик {h['tick']}/{g['tick']}, отпечаток "
      f"{'совпал' if same else 'РАЗНЫЙ'}, судья {'молчит' if judge_ok else 'нашёл расхождение'}, "
      f"ошибок скрипта {errs}; host: {short(h)}; guest: {short(g)}; подлог у guest на ходу "
      f"{g['mismatch']}, подменщик по серверу {g['forge_cheater']}; стоял до "
      f"{h['max_stall_s']}/{g['max_stall_s']} с, придержка у guest до {g['max_hold_s']} с")
voids = [l for l in lines if "прерван" in l]
for l in paths[:4] + proven[:2] + desync_relay[:2] + dropped[:2] + summ[:2] + voids[:2]:
    print("   relay.log:", l.split("] ", 1)[-1])
sys.exit(0 if ok else 1)
PY
	[ $? -ne 0 ] && fails+=("$sc")
done
echo "логи: $OUT"
if [ ${#fails[@]} -eq 0 ]; then
	echo "P2P DUEL OK"
	exit 0
fi
echo "P2P DUEL FAIL: ${fails[*]}"
exit 1
