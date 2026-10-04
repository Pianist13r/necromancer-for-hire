class_name NetMatchStats
extends RefCounted
##
## Сводка матча онлайн-«Схватки» для ретранслятора (Игорь 01.10: «после живой игры по relay.log
## видеть, как прошло у каждого, не прося файлы user://net_logs»; docs/pvp/NET_LOCKSTEP.md,
## «Сводка матча»). Сессия копит здесь счётчики боя и один раз за матч шлёт пакет `stats`.
##

## Замеров RTT до ретранслятора (p50/p90) — не больше: матч до часа, pong раз в 2 с.
const RTT_ALL_MAX := 2048

## Сводка уже ушла (или матча нет) — повторно не шлём.
var sent := true
var stall_total := 0.0
var stall_max := 0.0
var stall_n := 0
var delay_go := -1
var fallback_tick := -1
var go_ms := 0
var relay_rtts: Array[int] = []


func reset() -> void:
	sent = false
	stall_total = 0.0
	stall_max = 0.0
	stall_n = 0
	delay_go = -1
	fallback_tick = -1
	go_ms = 0
	relay_rtts.clear()


## Кадр простоя: before — сколько уже стоим, show — с какого простоя игрок видит «Ждём соперника».
func on_stall(before: float, delta: float, show: float) -> void:
	if before < show and before + delta >= show:
		stall_n += 1
	stall_total += delta
	stall_max = maxf(stall_max, before + delta)


func add_relay_rtt(ms: int) -> void:
	if relay_rtts.size() < RTT_ALL_MAX:
		relay_rtts.append(ms)


## Пакет сводки по состоянию сессии s; end — чем кончился матч (набор — у ретранслятора).
func packet(s: NetSession, end: String) -> Dictionary:
	var p2p := s._p2p
	var arr: Array = p2p._samples.get(p2p.chosen_key, []) if p2p != null else []
	var w := s._world
	var ticks := w.net_tick if w != null and is_instance_valid(w) else 0
	return {"t": "stats", "mode": s.path_mode, "fb_tick": fallback_tick,
		"udp": int(s.first_via.get("udp", 0)), "relay": int(s.first_via.get("relay", 0)),
		"stall_s": snappedf(stall_total, 0.1), "stall_max": snappedf(stall_max, 0.1),
		"stall_n": stall_n, "d0": delay_go, "d1": s.delay, "p2p50": pct(arr, 0.5),
		"p2p90": pct(arr, 0.9), "rel50": pct(relay_rtts, 0.5), "rel90": pct(relay_rtts, 0.9),
		"nat": p2p.nat if p2p != null else "off", "desync": s._desync_first, "heal": s.heals,
		"ticks": ticks,
		"wall": snappedf((Time.get_ticks_msec() - go_ms) / 1000.0, 0.1) if go_ms > 0 else 0.0,
		"end": end}


## Итог боя по счёту мира (судья при рассинхроне мог засчитать иное).
static func end_result(w: LegionWorld, side: int) -> String:
	if w == null or not is_instance_valid(w) or w.pvp_match == null or w.pvp_match.result.is_empty():
		return "draw"
	var win := int(w.pvp_match.result.get("winner", -1))
	return "draw" if win < 0 else ("win" if win == side else "loss")


static func pct(a: Array, q: float) -> int:
	if a.is_empty():
		return -1
	var srt := a.duplicate()
	srt.sort()
	return int(srt[clampi(int(round(q * (srt.size() - 1))), 0, srt.size() - 1)])
