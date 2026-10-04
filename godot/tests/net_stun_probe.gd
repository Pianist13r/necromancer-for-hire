extends SceneTree
##
## Живая проба STUN (нужен интернет): с одного UDP-сокета спросить оба публичных STUN-сервера
## NetP2P и сказать тип NAT этой машины — как его увидит прямое соединение онлайн-«Схватки».
##   "$GODOT" --headless --path godot --script res://tests/net_stun_probe.gd -- --mute [--show-ip]
## Внешний адрес по умолчанию маскируется (последние два октета) — лог можно показывать.
## Итог — строка «NET STUN {json}»; код выхода 0, если ответил хотя бы один сервер.
##

const WAIT_MS := 4000


func _initialize() -> void:
	var show_ip := "--show-ip" in OS.get_cmdline_user_args()
	var p := NetP2P.new()
	var t0 := Time.get_ticks_msec()
	p.start("0123456789abcdef0123456789abcdef", 0, true, t0)
	while not p.gathered() and Time.get_ticks_msec() - t0 < WAIT_MS:
		p.poll(Time.get_ticks_msec())
		OS.delay_msec(10)
	var stun: Array = []
	for c: Dictionary in p._stun_addrs:
		var ip := String(c["ip"])
		if not show_ip:
			var o := ip.split(".")
			ip = "%s.%s.x.x" % [o[0], o[1]]
		stun.append("%s:%d" % [ip, int(c["port"])])
	var res := {"nat": p.nat, "answers": p._stun_addrs.size(), "stun": stun,
		"same_port_as_socket": p._stun_addrs.any(func(c: Dictionary) -> bool:
			return int(c["port"]) == p._udp.get_local_port()) if p._udp != null else false,
		"ms": Time.get_ticks_msec() - t0, "candidates": p.local_candidates().size()}
	print("NET STUN ", JSON.stringify(res))
	p.close()
	quit(0 if not stun.is_empty() else 1)
