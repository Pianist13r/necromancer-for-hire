#!/bin/bash
# Игра по переписке (скилл corr-play): дождаться хода N и напечатать сжатое состояние.
# Использование: tools/corr_turn.sh <папка_ходов> <N> [таймаут_с=120]
# Печатает: время, волну, Котёл, ману, души, армию, откаты Q/W/E и комбо; договоры с участками
# (центр, остаток, людей); врагов — нотариусов, призраков, юристов, босса поимённо (цели рогатки),
# остальных кучками по клеткам 100 px; четыре ближайших к Котлу; кучки своих СВОБОДНЫХ бойцов
# (сами не ходят — из них чертят линии); постройки с дверями; пункты открытого меню площадки.
# Кампания по переписке: ход меню — экран, надписи (T) и кнопки (BTN) с центрами для tap.
# Кадр хода — <папка>/turn_NNN.png (смотреть глазами, когда цифр мало).
d="$1"; n="$2"; limit="${3:-120}"
for i in $(seq 1 "$limit"); do
  [ -f "$d/error.txt" ] && { echo "ОШИБКА: $(cat "$d/error.txt")"; exit 1; }
  [ "$(cat "$d/waiting.txt" 2>/dev/null)" = "$n" ] && break; sleep 1
done
python - "$d" "$n" <<'PY'
import json, sys
from collections import Counter, defaultdict
d, n = sys.argv[1], int(sys.argv[2])
try:
    s = json.load(open('%s/turn_%03d.json' % (d, n), encoding='utf-8'))
except FileNotFoundError:
    sys.exit('ход %d не пришёл — игра упала или ещё грузится (смотри лог запуска)' % n)
if s.get('mode') == 'menu':
    # кампания по переписке, ход вне боя: экран, кнопки для tap, надписи, прогресс
    print('turn', s['turn'], 'MENU', s.get('screen', ''), 'camp', json.dumps(s.get('camp', {}), ensure_ascii=False))
    for t in s.get('texts', []):
        print(' T', t)
    for b in s.get('buttons', []):
        print(' BTN %s @%s%s' % (b['text'], b['at'], ' (закрыт)' if b['off'] else ''))
    if s['log']:
        print(' LOG', s['log'])
    sys.exit(0)
print('turn', s['turn'], 't', s['t'], 'wave', s['wave'], 'hp', s['hp'], 'mana', s['mana'],
      'souls', s['souls'], 'army', s['army'], 'over', s['over'])
for wtxt in s.get('warn', []):
    print(' WARN', wtxt)
pv = s.get('pvp')
if pv:
    # «Схватка»: ты — сторона 0 (слева), координаты мировые 1600x900
    m, f_ = pv['me'], pv['foe']
    print(' PVP clock %.0f/%.0f (left %.0f) · me hp %.0f/%.0f army %d souls %d mana %d · FOE hp %.0f/%.0f army %d souls %d mana %d @%s' % (
        pv['clock'], pv['limit'], pv['left'], m['hp'], m['max'], m['army'], m['souls'], m['mana'],
        f_['hp'], f_['max'], f_['army'], f_['souls'], f_['mana'], f_['at']))
    fa = s.get('foe_army', [])
    if fa:
        print(' foe_army', ' '.join('%d@(%d,%d)' % (g[2], g[0], g[1]) for g in fa[:12]))
    if pv.get('result'):
        print(' RESULT', json.dumps(pv['result'], ensure_ascii=False))
cd = s.get('cd', {})
combo = s.get('combo', [0, 1.0])
if cd:
    print(' cd', ' '.join('%s %.1f' % (k, cd[k]) for k in ('Q', 'W', 'E', 'R') if k in cd),
          '· combo %d x%.2f' % (combo[0], combo[1]))


def seg(g):
    # давка: «!b0.62 p14» — прогиб 62 % до прорыва, у участка масса толпы 14 (печать с v18)
    out = '[%d@%s %.1fs %dm' % (g['i'], g['at'], g['left'], g['men'])
    if g.get('near'):
        out += ' vs%s' % json.dumps(g['near'], ensure_ascii=False).replace(' ', '')
    if g.get('bend', 0) > 0 or g.get('press', 0) > 0:
        out += ' !b%.2f p%g' % (g.get('bend', 0), g.get('press', 0))
    return out + ']'


for c in s['contracts']:
    print(' C%d %s dir%s' % (c['id'], c['kind'], c['dir']), ' '.join(seg(g) for g in c['segs']))
f = s['foes']
print(' foes', len(f), dict(Counter(x[0] for x in f)))
# натиск сам доводится на нотариуса (200 px, широкий конус) и призрака (120 px) — их поимённо
SOLO = ('signer', 'ghost', 'lawyer', 'boss', 'mimic')
for kind in SOLO:
    pts = sorted((x, y) for k, x, y in f if k == kind)
    if pts:
        print('  %s: %s' % (kind, ' '.join('(%d,%d)' % p for p in pts)))
# остальные — кучками: где колонна и сколько в ней (голова — по «nearest» и кадру)
cells = defaultdict(list)
for k, x, y in f:
    if k not in SOLO:
        cells[(k, x // 100, y // 100)].append((x, y))
groups = defaultdict(list)
for (k, _, _), pts in cells.items():
    groups[k].append((len(pts), sum(p[0] for p in pts) // len(pts), sum(p[1] for p in pts) // len(pts)))
for k in sorted(groups):
    print('  %s: %s' % (k, ' '.join('%d@(%d,%d)' % g for g in sorted(groups[k], reverse=True))))
cx, cy = s.get('cauldron', [200, 370])
print(' nearest', sorted(f, key=lambda x: (x[1] - cx) ** 2 + (x[2] - cy) ** 2)[:4])
free = s.get('free_at', [])
if free:
    print(' free', ' '.join('%d@(%d,%d)' % (g[2], g[0], g[1]) for g in free[:10]))
for b in s.get('buildings', []):
    if b.get('src') == 'plot':
        print(' B%s %s L%d %d/%d @%s door%s' % ('' if not pv else ('/s%d' % b.get('side', 0)),
              b['kind'], b['lvl'], b['alive'], b['cap'], b['at'], b['door']))
for m in s.get('menu', []):
    print(' MENU %s @%s%s' % (m['text'], m['at'], ' (закрыт)' if m['off'] else ''))
# кампания по переписке: надписи поверх боя (плашки уроков) — только новые против прошлого хода
if s.get('mode') == 'battle':
    try:
        prev = json.load(open('%s/turn_%03d.json' % (d, n - 1), encoding='utf-8')).get('texts', [])
    except (FileNotFoundError, ValueError):
        prev = []
    for t in s.get('texts', []):
        if t not in prev:
            print(' T', t)
for b in s.get('buttons', []):
    print(' BTN %s @%s%s' % (b['text'], b['at'], ' (закрыт)' if b['off'] else ''))
if s['log']:
    print(' LOG', s['log'])
PY
