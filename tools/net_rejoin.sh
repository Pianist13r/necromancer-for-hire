#!/usr/bin/env bash
# Переподключение в идущий матч (docs/pvp/NET_LOCKSTEP.md, «Переподключение»): свой ретранслятор
# С СУДЬЁЙ + два клиента с ботами через настоящий WebSocket, в реальном времени. Связь рвётся у гостя.
#   cut    — на тике 600 сокет гостя закрыт, 5 с попытки не проходят, потом возврат: матч доигран
#            (хозяин сдаётся на тике 2400), итог и последний отпечаток как без обрыва, у хозяина был
#            «Соперник переподключается…», ухода нет;
#   silent — на тике 600 связь гостя молчит 15 с (сокет не опрашивается и не закрывается): матч
#            доигран без ухода; что сделал сервер (закрыл сокет или нет) — строкой info;
#   expire — отсрочка ретранслятора 10 с (--rejoin-grace), гость молчит 30 с: хозяину уход соперника и
#            победа, гость — в лобби;
#   flap   — обрыв на 1 с каждые 300 тиков, 5 раз: 5 возвратов, матч доигран.
#   healcut_mid / healcut_after — настоящая подтяжка снимком судьи: гость портит бой на тике 600;
#            обрыв на 2 с, когда судья начал снимать снимок (подтяжка в пути — отменяется и
#            запрашивается заново), или на тике 1800, после подтяжки. Доиграно, отпечатки сошлись.
#   tools/net_rejoin.sh [cut|silent|expire|flap|healcut|healcut_mid|healcut_after|all] [порт]
#   (silent, expire, flap, healcut_mid, healcut_after — порт +1…+5)
# Порт — НЕ боевой 18765. Процессы гасит только свои (PID ретранслятора; судьи выходят сами,
# когда закрыт их сокет). Итог — «NET_REJOIN: OK» или «NET_REJOIN: FAIL», код выхода 0/1.
set -u
cd "$(dirname "$0")/.."
WHAT="${1:-all}"
PORT="${2:-18931}"
GODOT="${GODOT:-C:/Projects/SharedTools/godot/Godot_v4.7.2-stable_win64_console.exe}"
OUT="${OUT:-$(mktemp -d)}"
mkdir -p "$OUT"
export NECRO_NO_DEV_BRIDGE=1
CODE=0

scenario() {
	local name="$1" host_extra="$2" guest_extra="$3" port="$4" relay_extra="${5:-}"
	local dir="$OUT/$name"
	mkdir -p "$dir/relay_appdata" "$dir/host_appdata" "$dir/guest_appdata"
	APPDATA="$dir/relay_appdata" "$GODOT" --headless --path godot \
		--script res://scripts/legion/net/net_relay.gd -- --mute --port "$port" \
		$relay_extra > "$dir/relay.log" 2>&1 &
	local relay=$!
	sleep 3
	APPDATA="$dir/host_appdata" timeout 600 "$GODOT" --headless --path godot --max-fps 60 \
		--script res://tests/net_duel_probe.gd -- --mute --url "ws://127.0.0.1:$port" --role host \
		--limit 0 $host_extra > "$dir/host.log" 2>&1 &
	local h=$!
	sleep 2
	APPDATA="$dir/guest_appdata" timeout 600 "$GODOT" --headless --path godot --max-fps 60 \
		--script res://tests/net_duel_probe.gd -- --mute --url "ws://127.0.0.1:$port" --role guest \
		--limit 0 $guest_extra > "$dir/guest.log" 2>&1 &
	local g=$!
	wait $h $g
	sleep 2
	kill "$relay" 2>/dev/null
	echo "— $name ($dir)"
	grep -hE "отключ|вернулась|не вернулась|отказ в возврате|итог стороны|итог судьи" "$dir/relay.log" \
		| sed 's/^/  relay: /'
	python -X utf8 tools/net_rejoin_check.py "$name" "$dir"
	return $?
}

if [ "$WHAT" = "cut" ] || [ "$WHAT" = "all" ]; then
	scenario cut "--surrender-at 2400" "--cut-at 600 --cut-ms 5000" "$PORT" || CODE=1
fi
if [ "$WHAT" = "silent" ] || [ "$WHAT" = "all" ]; then
	scenario silent "--surrender-at 2400" "--cut-at 600 --cut-ms 15000 --cut-silent" \
		"$((PORT + 1))" || CODE=1
fi
if [ "$WHAT" = "expire" ] || [ "$WHAT" = "all" ]; then
	scenario expire "" "--cut-at 600 --cut-ms 30000" "$((PORT + 2))" "--rejoin-grace 10000" || CODE=1
fi
if [ "$WHAT" = "flap" ] || [ "$WHAT" = "all" ]; then
	scenario flap "--surrender-at 2400" "--cut-at 300 --cut-every 300 --cut-n 5 --cut-ms 1000" \
		"$((PORT + 3))" || CODE=1
fi
if [ "$WHAT" = "healcut_mid" ] || [ "$WHAT" = "healcut" ] || [ "$WHAT" = "all" ]; then
	scenario healcut_mid "--surrender-at 2400" "--corrupt 600 --cut-on-heal --cut-ms 2000" \
		"$((PORT + 4))" || CODE=1
fi
if [ "$WHAT" = "healcut_after" ] || [ "$WHAT" = "healcut" ] || [ "$WHAT" = "all" ]; then
	scenario healcut_after "--surrender-at 2400" "--corrupt 600 --cut-at 1800 --cut-ms 2000" \
		"$((PORT + 5))" || CODE=1
fi
echo "логи: $OUT"
[ $CODE -eq 0 ] && echo "NET_REJOIN: OK" || echo "NET_REJOIN: FAIL"
exit $CODE
