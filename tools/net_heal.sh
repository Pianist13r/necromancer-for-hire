#!/usr/bin/env bash
# Подтяжка снимком судьи (docs/pvp/NET_LOCKSTEP.md, «Подтяжка»): свой ретранслятор С СУДЬЁЙ + два
# клиента с ботами через настоящий сокет, в реальном времени. Гость портит свой бой (Котёл −1).
#   heal — один раз на тике 600: судья замечает, снимает снимок, гость подтягивается; дальше ни
#          одного расхождения, к концу матча (хозяин сдаётся на тике 1800) отпечаток гостя = хозяина,
#          итог судьи = итог клиентов, экран итога у каждого один (match_ended один раз).
#   again — портит каждые 600 тиков: подтяжек ровно HEAL_MAX (3), потом строка «подтяжек больше нет»
#          и как раньше — надпись о расхождении у гостя, итог судьи.
#   late — как heal, но приём с сервера у гостя на 1,5 с позже: снимок старше его тика, досчёт.
#   big — как heal, но снимок «слишком большой» (судья с --snap-limit 2000): отказ heal_fail, подтяжки
#          нет, у гостя надпись о расхождении, итог судьи тот же.
#   tools/net_heal.sh [heal|late|again|big|all] [порт] (late, again, big — на порт +2, +1, +3)
# Порт — НЕ боевой 18765. Процессы гасит только свои (PID ретранслятора; судьи выходят сами,
# когда закрыт их сокет). Итог — строка «NET_HEAL: OK» или «NET_HEAL: FAIL …», код выхода 0/1.
set -u
cd "$(dirname "$0")/.."
WHAT="${1:-all}"
PORT="${2:-18911}"
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
	grep -hE "разошлась|подтян|снимок|подтяжек|итог судьи|ложный" "$dir/relay.log" | sed 's/^/  relay: /'
	python -X utf8 tools/net_heal_check.py "$name" "$dir"
	return $?
}

if [ "$WHAT" = "heal" ] || [ "$WHAT" = "all" ]; then
	scenario heal "--surrender-at 1800" "--corrupt 600" "$PORT" || CODE=1
fi
if [ "$WHAT" = "late" ] || [ "$WHAT" = "all" ]; then
	# приём с сервера у гостя на 1,5 с позже (ходы соперника идут напрямую): снимок приходит,
	# когда гость уже впереди тика снимка, — досчёт своими ходами
	scenario late "--surrender-at 1800" "--corrupt 600 --down-lat 1500 --after-s 4" "$((PORT + 2))" || CODE=1
fi
if [ "$WHAT" = "again" ] || [ "$WHAT" = "all" ]; then
	scenario again "--surrender-at 2700" "--corrupt 300 --corrupt-every 600" "$((PORT + 1))" \
		|| CODE=1
fi
if [ "$WHAT" = "big" ] || [ "$WHAT" = "all" ]; then
	# снимок больше предела (судья с --snap-limit 2000 знаков): судья шлёт ретранслятору отказ
	# heal_fail, подтяжки нет сразу, у гостя обычная надпись о расхождении
	scenario big "--surrender-at 1800" "--corrupt 600" "$((PORT + 3))" "--judge-snap-limit 2000" \
		|| CODE=1
fi
echo "логи: $OUT"
[ $CODE -eq 0 ] && echo "NET_HEAL: OK" || echo "NET_HEAL: FAIL"
exit $CODE
