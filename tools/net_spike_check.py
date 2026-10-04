"""Проверки и сводка спайка сети PvP (tools/net_spike.sh, docs/pvp/DESIGN.md §10).

Читает логи прогонов из папки и печатает таблицу замеров. Последняя строка — NET SPIKE OK
или NET SPIKE FAIL (код выхода 1): спайк не гейт игры, но падать молча не должен.
"""
import glob
import json
import os
import sys

# Пороги: снимки 20/с (допуск на старт и конец прогона), тик сервера укладывается в 1/60 с,
# задержка «команда → видно» на localhost — не больше тика + интервала снимка с запасом.
SNAPS_MIN = 15.0
TICK_P99_MAX_US = 16_600
LAT_P95_MAX_MS = 150.0


def json_lines(path):
    out = []
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if line.startswith("{"):
                try:
                    out.append(json.loads(line))
                except json.JSONDecodeError:
                    pass
    return out


def load(out_dir, name):
    server = [j for j in json_lines(os.path.join(out_dir, f"{name}.server.log")) if "ticks" in j]
    clients = []
    for p in sorted(glob.glob(os.path.join(out_dir, f"{name}.c[0-9]*.log"))):
        got = [j for j in json_lines(p) if j.get("role") == "client"]
        clients.append(got[-1] if got else {"missing": p})
    cpu = json_lines(os.path.join(out_dir, f"{name}.cpu.log"))
    return (server[-1] if server else {}), clients, (cpu[-1] if cpu else {})


def cpu_pct(cpu):
    try:
        return round((float(cpu["cpu_s_end"]) - float(cpu["cpu_s_start"])) / cpu["window_s"] * 100, 1)
    except (KeyError, ValueError, TypeError):
        return None


def main(out_dir):
    fails = []

    def need(ok, what):
        if not ok:
            fails.append(what)

    for name in ("base", "big", "nocap"):
        srv, clients, cpu = load(out_dir, name)
        need(bool(srv), f"{name}: нет итога сервера")
        need(len(clients) == 2, f"{name}: клиентов не 2")
        print(f"== {name}: сервер tick_us avg {srv.get('tick_us_avg')} p99 {srv.get('tick_us_p99')} "
              f"max {srv.get('tick_us_max')}, снимок {srv.get('snap_bytes')} Б = "
              f"{srv.get('snap_kbps_per_client')} КБ/с на клиента, кадров _process "
              f"{srv.get('process_frames')} за {srv.get('seconds')} с, CPU {cpu_pct(cpu)} % ядра, "
              f"применено команд {srv.get('cmds_applied')}")
        need(srv.get("tick_us_p99", 10**9) <= TICK_P99_MAX_US, f"{name}: тик p99 > 16.6 мс")
        for c in clients:
            print(f"   клиент side {c.get('side')}: снимков {c.get('snaps_per_s')}/с, "
                  f"{c.get('kb_per_s')} КБ/с, команд {c.get('cmds_acked')}/{c.get('cmds_sent')}, "
                  f"задержка команда→снимок p50 {c.get('lat_ms_p50')} p95 {c.get('lat_ms_p95')} "
                  f"max {c.get('lat_ms_max')} мс, RTT ENet p50 {c.get('rtt_ms_p50')} мс, "
                  f"HP {c.get('hp_first')}→{c.get('hp_last')}, не по порядку {c.get('out_of_order')}")
            need(c.get("welcomed") is True, f"{name}: клиента не приняли")
            need(c.get("snaps_per_s", 0) >= SNAPS_MIN, f"{name}: снимков меньше {SNAPS_MIN}/с")
            # последняя команда может уйти в миг выхода — подтверждение не успевает вернуться
            need(c.get("cmds_sent", 0) > 0 and c.get("cmds_acked", 0) >= c.get("cmds_sent", 0) - 1,
                 f"{name}: не все команды подтверждены")
            need(0 <= c.get("lat_ms_p95", -1) <= LAT_P95_MAX_MS, f"{name}: задержка p95 > {LAT_P95_MAX_MS}")
            need(c.get("hp_last", 0) < c.get("hp_first", 0), f"{name}: удары не дошли до состояния")
            need(c.get("units_seen") == (320 if name == "big" else 150), f"{name}: не то число бойцов")
    srv, clients, _ = load(out_dir, "abuse")
    print(f"== abuse: сервер {json.dumps({k: v for k, v in srv.items() if k.startswith(('rej', 'kick', 'cmds'))}, ensure_ascii=False)}")
    for c in clients:
        print(f"   клиент evil={c.get('evil')} принят={c.get('welcomed')} разорван сервером={c.get('closed_by_server')} "
              f"за {c.get('seconds')} с")
    need(srv.get("kicked", 0) >= 2, "abuse: сервер не выгнал обоих")
    need(srv.get("rejected_rate", 0) > 0, "abuse: залп не упёрся в лимит частоты")
    need(srv.get("rejected_code", 0) >= 1, "abuse: чужой код не отвергнут")
    need(srv.get("rejected_len", 0) >= 1, "abuse: длинный пакет не отвергнут")
    need(srv.get("rejected_bounds", 0) >= 1, "abuse: точка за полем не отвергнута")
    need(srv.get("cmds_applied", 10**9) <= 25, "abuse: из залпа применено больше ведра")
    need(all(c.get("closed_by_server") for c in clients), "abuse: вредные клиенты не разорваны")
    for f in fails:
        print("FAIL:", f)
    print("NET SPIKE OK" if not fails else "NET SPIKE FAIL")
    return 0 if not fails else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
