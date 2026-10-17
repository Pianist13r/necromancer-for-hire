"""Проверка прогона tools/net_rejoin.sh (переподключение в идущий матч): net_rejoin_check.py <сценарий> <папка>.

Читает host.log, guest.log (строки NET_DUEL / NET_CUT пробы tests/net_duel_probe.gd) и relay.log.
Печатает каждую проверку («ok» / «FAIL») и итог; код выхода 0/1.
"""
import json
import pathlib
import re
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


res, after, cuts = {}, {}, []
for role in ("host", "guest"):
    for line in text(f"{role}.log").splitlines():
        if line.startswith("NET_DUEL "):
            res[role] = json.loads(line[len("NET_DUEL "):])
        elif line.startswith("NET_DUEL_AFTER "):
            after[role] = json.loads(line[len("NET_DUEL_AFTER "):])
        elif line.startswith("NET_CUT ") and role == "guest":
            cuts.append(json.loads(line[len("NET_CUT "):]))
relay = text("relay.log")
check(len(res) == 2, "оба клиента дошли до итога пробы")
if len(res) < 2:
    print(f"NET_REJOIN {name}: FAIL")
    sys.exit(1)
h, g = res["host"], res["guest"]
for role in ("host", "guest"):
    errs = text(f"{role}.log").count("SCRIPT ERROR")
    check(errs == 0, f"{role}: SCRIPT ERROR {errs}")
check(relay.count("SCRIPT ERROR") == 0, f"relay: SCRIPT ERROR {relay.count('SCRIPT ERROR')}")
# никого не выкинули за нарушение: досылка хвоста — по порядку и не «слишком часто»
bad = re.findall(r"отключён: (вне очереди|ход \d+ вне очереди[^\n]*|слишком часто|ход \d+ раньше времени[^\n]*)",
                 relay)
check(not bad, f"relay: выкидываний за нарушение нет {bad[:3]}")
check(len(cuts) >= 1, f"обрывов у гостя: {len(cuts)}")
returned = relay.count("вернулась")
if name in ("cut", "flap"):
    want = 5 if name == "flap" else 1
    check(len(cuts) == want, f"обрывов {len(cuts)} (ждали {want})")
    check(h["why"] == "ok" and g["why"] == "ok", f"матч сыгран до конца: {h['why']} / {g['why']}")
    check(h["result"] == "loss" and g["result"] == "win",
          f"итог как без обрыва (хозяин сдался): {h['result']} / {g['result']}")
    check(g["rejoins"] == want and returned == want,
          f"гость вернулся {g['rejoins']} раз, relay «вернулась» {returned}")
    check(h["opp_away_seen"] == want, f"у хозяина «Соперник переподключается…» {h['opp_away_seen']} раз")
    check(not h["remote_left"] and not g["remote_left"], "ухода соперника не было ни у кого")
    check(h["desync"] < 0 and g["desync"] < 0, f"расхождений нет: {h['desync']} / {g['desync']}")
    check(h["digest"] == g["digest"] and h["tick"] == g["tick"],
          f"последний тик и отпечаток одни: {h['tick']}/{g['tick']}")
    # Первый результат печатается до штатного after_s ожидания судьи. Проверять
    # итог после этого ожидания: ответ может прийти между двумя строками пробы.
    check(len(after) == 2, "оба клиента завершили ожидание итогового ответа")
    check(all(int(after.get(role, {}).get("ends", -1)) == 1 for role in ("host", "guest")),
          "после ожидания бой завершён ровно один раз у обоих")
    vh = after.get("host", {}).get("verdict") or {}
    vg = after.get("guest", {}).get("verdict") or {}
    # пустой итог — не «совпал»: судья обязан был его прислать (verifier 11.10)
    check("winner" in vh and int(vh["winner"]) == 1 and "winner" in vg and int(vg["winner"]) == 1,
          f"итог судьи у обоих, победитель 1: {vh} / {vg}")
    check(re.search(r"итог стороны 1 .*переподключений %d" % want, relay) is not None,
          "relay.log: в сводке гостя число переподключений")
elif name.startswith("healcut"):
    # настоящий судья: гость портит свой бой (тик 600), судья подтягивает его снимком; обрыв —
    # во время подтяжки (mid) или после неё (after). Бой доигран, отпечатки сошлись, ухода нет
    check(h["why"] == "ok" and g["why"] == "ok", f"матч сыгран до конца: {h['why']} / {g['why']}")
    check(h["result"] == "loss" and g["result"] == "win",
          f"итог как без обрыва: {h['result']} / {g['result']}")
    check(g["rejoins"] == 1 and not h["remote_left"], f"гость вернулся ({g['rejoins']}), ухода нет")
    check(g["heals"] >= 1, f"гость подтянут снимком судьи ({g['heals']})")
    check(h["desync"] < 0 and g["desync"] < 0, f"надписи о расхождении нет: {h['desync']} / {g['desync']}")
    check(h["digest"] == g["digest"] and h["tick"] == g["tick"],
          f"последний тик и отпечаток одни: {h['tick']}/{g['tick']}")
    cancelled = "прервана обрывом" in relay
    print(f"  info подтяжка в момент обрыва {'шла — отменена и запрошена заново' if cancelled else 'не шла'}"
          f"; подтяжек у гостя {g['heals']}")
    if name == "healcut_mid":
        check(cancelled, "relay.log: подтяжка прервана обрывом (обрыв пришёлся на неё)")
    else:
        healed_before = relay.find("подтянута снимком") < relay.find("отключилась")
        check(healed_before and not cancelled,
              "relay.log: подтяжка состоялась до обрыва (судья мог отставать — тогда сдвинуть тик)")
elif name == "silent":
    check(h["why"] == "ok" and g["why"] == "ok", f"матч сыгран до конца: {h['why']} / {g['why']}")
    check(h["result"] == "loss" and g["result"] == "win",
          f"итог как без обрыва: {h['result']} / {g['result']}")
    check(not h["remote_left"], "у хозяина ухода соперника не было (молчание — не сдача)")
    check(h["desync"] < 0 and g["desync"] < 0, "расхождений нет")
    how = "сервер закрыл молчащий сокет, гость вернулся" if g["rejoins"] > 0 \
        else "сервер не закрыл сокет за время молчания — связь продолжилась без возврата"
    print(f"  info {how} (возвратов {g['rejoins']}, вне связи {g['away_ms']} мс)")
elif name == "expire":
    check(h["why"] == "ok", f"хозяин доиграл: {h['why']}")
    check(h["remote_left"] and h["result"] == "win",
          f"срок вышел — хозяину уход соперника и победа: left={h['remote_left']}, {h['result']}")
    check(g["why"].startswith("aborted") and g["rejoins"] == 0,
          f"гость не вернулся и ушёл в лобби: {g['why']}")
    check("не вернулась за" in relay, "relay.log: «не вернулась за N с»")
print(f"NET_REJOIN {name}: {'OK' if fails == 0 else 'FAIL'}")
sys.exit(1 if fails else 0)
