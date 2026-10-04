"""Проверка прогона tools/net_heal.sh (подтяжка снимком судьи): net_heal_check.py <сценарий> <папка>.

Читает host.log, guest.log (строки NET_DUEL / NET_DUEL_AFTER пробы tests/net_duel_probe.gd) и
relay.log. Печатает каждую проверку («ok» / «FAIL») и итог; код выхода 0/1.
"""
import json
import pathlib
import sys

name, out = sys.argv[1], pathlib.Path(sys.argv[2])
fails = 0


def check(cond, what):
    global fails
    print(("  ok   " if cond else "  FAIL ") + what)
    if not cond:
        fails += 1


def text(fname):
    p = out / fname
    return p.read_text(encoding="utf-8", errors="replace") if p.exists() else ""


res, after = {}, {}
for role in ("host", "guest"):
    for line in text(f"{role}.log").splitlines():
        if line.startswith("NET_DUEL "):
            res[role] = json.loads(line[len("NET_DUEL "):])
        elif line.startswith("NET_DUEL_AFTER "):
            after[role] = json.loads(line[len("NET_DUEL_AFTER "):])
relay = text("relay.log")
check(len(res) == 2 and len(after) == 2, "оба клиента дошли до итога пробы")
if len(res) < 2 or len(after) < 2:
    print(f"NET_HEAL {name}: FAIL")
    sys.exit(1)
h, g = res["host"], res["guest"]


def winner(r):
    v = r.get("verdict") or {}
    return int(v["winner"]) if "winner" in v else None


for role in ("host", "guest"):
    errs = text(f"{role}.log").count("SCRIPT ERROR")
    check(errs == 0, f"{role}: SCRIPT ERROR {errs}")
check(relay.count("SCRIPT ERROR") == 0, f"relay: SCRIPT ERROR {relay.count('SCRIPT ERROR')}")
check(h["why"] == "ok" and g["why"] == "ok", f"матч сыгран до конца: {h['why']} / {g['why']}")
check(h["phase"] != 0 and g["phase"] != 0, "у обоих бой кончился (не стоит в фазе боя)")
check(h["result"] == "loss" and g["result"] == "win",
      f"хозяин сдался: итог хозяина {h['result']}, гостя {g['result']}")
check(winner(after["host"]) == 1 and winner(after["guest"]) == 1,
      f"вердикт судьи пришёл обоим, победитель 1: {winner(after['host'])} / "
      f"{winner(after['guest'])}")
check("итог судьи" in relay and '"winner":1' in relay.replace(" ", ""),
      "relay.log: итог судьи с победителем 1")
for role, r in (("host", h), ("guest", g)):
    check(r["ends"] == 1 and after[role]["ends"] == 1,
          f"{role}: экран итога один (match_ended {r['ends']}, после ожидания {after[role]['ends']})")
check(h["heals"] == 0 and h["desync_first"] == -1 and "сторона 0 разошлась" not in relay,
      f"хозяин не расходился (подтяжек {h['heals']}, расхождение {h['desync_first']})")
diverged = relay.count("сторона 1 разошлась с судьёй")
healed = relay.count("сторона 1 подтянута снимком судьи")
snaps = relay.count("снимок для стороны 1 снят судьёй")
heal_ev = []
for f in sorted((out / "guest_appdata").rglob("*.jsonl")):
    for line in f.read_text(encoding="utf-8", errors="replace").splitlines():
        if '"ev":"heal"' in line:
            heal_ev.append(json.loads(line))
for e in heal_ev:
    print(f"  гость: подтяжка {e['id']}: снимок тика {e['k']}, свой тик {e['from']} → {e['at']}, "
          f"{e['ms']} мс, кусков {e['parts']}, {'принят' if e['ok'] else 'отказ: ' + e['why']}")
if name == "late":
    check(any(e["ok"] and e["from"] > e["k"] for e in heal_ev),
          "снимок старше своего тика — бой досчитан своими ходами (from > k)")
if name in ("heal", "late"):
    check("ложный healed" not in relay, "relay.log: ложных healed от честного клиента нет")
    check(g["desync_first"] >= 0, f"гость разошёлся с судьёй (тик {g['desync_first']})")
    check(diverged == 1, f"relay.log: «сторона 1 разошлась» ровно 1 раз (есть {diverged})")
    check(snaps == 1 and healed == 1,
          f"relay.log: снимок снят судьёй ({snaps}) и гость подтянут ({healed}) — по одному")
    check(g["heals"] == 1, f"гость подтянулся снимком 1 раз (было {g['heals']})")
    check(g["desync"] == -1, f"у гостя нет надписи о расхождении (desync {g['desync']})")
    check(h["tick"] == g["tick"] and h["digest"] == g["digest"],
          f"к концу матча бой гостя = бою хозяина: тик {h['tick']}/{g['tick']}, отпечаток "
          f"{'совпал' if h['digest'] == g['digest'] else 'РАЗНЫЙ'}")
elif name == "big":
    check(g["desync_first"] >= 0, f"гость разошёлся с судьёй (тик {g['desync_first']})")
    check(relay.count("судья не снял снимок для стороны 1") == 1,
          "relay.log: отказ судьи «не снял снимок» — одна строка")
    check(snaps == 0 and healed == 0 and g["heals"] == 0,
          f"снимка нет, подтяжек нет (снят {snaps}, подтянут {healed}, у гостя {g['heals']})")
    check("не дошёл за" not in relay,
          "ретранслятор не ждал 60 с «снимок не дошёл» — отказ пришёл сразу")
    check(g["desync"] >= 0, f"у гостя надпись о расхождении сразу (desync {g['desync']})")
    check("ложный healed" not in relay, "ложных healed у честных клиентов нет")
else:
    check(g["heals"] == 3 and healed == 3,
          f"подтяжек ровно 3 (гость {g['heals']}, relay.log {healed})")
    check(relay.count("сторона 1 расходится с судьёй снова — подтяжек больше нет") == 1,
          "relay.log: «подтяжек больше нет» — одна строка")
    check(diverged >= 4, f"после подтяжек расхождение пишется как раньше ({diverged} строк)")
    check(g["desync"] >= 0, f"у гостя надпись о расхождении, как без подтяжки (desync {g['desync']})")
print(f"NET_HEAL {name}: {'OK' if fails == 0 else 'FAIL'}")
sys.exit(0 if fails == 0 else 1)
