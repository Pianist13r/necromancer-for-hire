#!/usr/bin/env bash
# Проба ретранслятора онлайн-«Схватки»: поднимает net_relay.gd на свободном порту, гоняет
# tests/net_relay_probe.gd, гасит СВОЙ процесс ретранслятора (только свой PID).
#   tools/net_probe.sh [порт]
set -u
cd "$(dirname "$0")/.."
PORT="${1:-18799}"
GODOT="${GODOT:-C:/Projects/SharedTools/godot/Godot_v4.7.2-stable_win64_console.exe}"
OUT="${OUT:-$(mktemp -d)}"
export APPDATA="$OUT/appdata" NECRO_NO_DEV_BRIDGE=1
mkdir -p "$APPDATA"
"$GODOT" --headless --path godot --script res://scripts/legion/net/net_relay.gd -- --mute \
	--port "$PORT" --judges 0 --ready-timeout 4000 --stats-grace 2000 > "$OUT/relay.log" 2>&1 &
RELAY=$!
sleep 3
timeout 180 "$GODOT" --headless --path godot --script res://tests/net_relay_probe.gd -- --mute \
	--port "$PORT" > "$OUT/probe.log" 2>&1
CODE=$?
kill "$RELAY" 2>/dev/null
grep -E "FAIL|net_relay_probe:" "$OUT/probe.log"
ERR=$(grep -c "SCRIPT ERROR" "$OUT/relay.log")
echo "SCRIPT ERROR в ретрансляторе: $ERR"
[ "$ERR" -gt 0 ] && CODE=1
# прямое соединение: строки пути, жалоб и доказанного подлога в relay.log (их смотрит владелец);
# непроверенная жалоба честного видна, хотя подменщик до неё выжег 45 строк пути
if grep -q "напрямую, 9 мс в одну сторону, задержка 2" "$OUT/relay.log" \
		&& [ "$(grep -c "непроверенная жалоба стороны 1 «Yforge»" "$OUT/relay.log")" -eq 2 ] \
		&& grep -q "ПОДМЕНА ХОДА ДОКАЗАНА — сторона 0 «Xforge», ход 4" "$OUT/relay.log" \
		&& grep -Eq "раньше времени \(по часам боя — [0-9]+\)" "$OUT/relay.log" \
		&& grep -q "раньше времени (по часам боя — -1)" "$OUT/relay.log" \
		&& grep -q "строка не этого хода" "$OUT/relay.log" \
		&& grep -q "поле не загружено у обоих" "$OUT/relay.log" \
		&& grep -q "матч прерван без итога — сторона 0 «Xlag»" "$OUT/relay.log" \
		&& grep -q "отклонено прерывание стороны 0 «Xvoid0» (разрыв 0 ходов) — матч идёт" "$OUT/relay.log" \
		&& [ "$(grep -c "прерывание стороны 0 «Xvoid0»" "$OUT/relay.log")" -eq 1 ] \
		&& ! grep -q "как выход" "$OUT/relay.log" \
		&& ! grep -q "ходы не доходят до сервера" "$OUT/relay.log"; then
	echo "relay.log: строки пути, жалоб, подлога, забега и прерывания есть"
else
	echo "FAIL: relay.log без строк пути/жалоб/подлога/забега/прерывания"
	CODE=1
fi
# сводка матча: одна строка на сторону, мусор обрезан, нет сводки — «не пришёл»
R="$OUT/relay.log"
GOOD="итог стороны 0 «Xstats»: напрямую 87 % ходов, в конце напрямую, простой 3,1 с (макс 0,8, 5 раз), задержка 2→3, пинг напрямую 15/40 мс, до сервера 110/190 мс, NAT cone, расхождение нет, 6:12 (22320 тиков), конец (со слов стороны): победа"
if [ "$(grep -cF "$GOOD" "$R")" -eq 1 ] && [ "$(grep -c "итог стороны 0 «Xstats»" "$R")" -eq 1 ] \
		&& grep "итог стороны 1 «Ystats»" "$R" | grep -q "NAT ?, .*конец (со слов стороны): ?" \
		&& grep -q "итог стороны 0 «Xnostats» не пришёл" "$R" \
		&& grep -q "итог стороны 1 «Ynostats» не пришёл" "$R" \
		&& grep -q "итог стороны 1 «Yafterleft»: .*конец (со слов стороны): соперник ушёл" "$R" \
		&& ! grep -q "итог стороны 1 «Yafterleft» не пришёл" "$R"; then
	echo "relay.log: сводки матча — одна на сторону, мусор обрезан, «не пришёл» есть"
else
	echo "FAIL: сводки матча в relay.log не такие"
	CODE=1
fi
echo "логи: $OUT"
exit $CODE
