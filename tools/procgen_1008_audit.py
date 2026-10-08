"""Fail closed on missing evidence; summarize only complete local acceptance runs."""
import hashlib
import json
from pathlib import Path
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'batches/procgen-1008'


def read(path):
    data = path.read_bytes()
    return data.decode('utf-16' if data.startswith((b'\xff\xfe', b'\xfe\xff')) else 'utf-8-sig')


def main():
    problems = []
    summary = {}
    for folder, count in [('after/dump', 240), ('after/stress', 200), ('after/pvp', 17)]:
        files = sorted((OUT / folder).glob('*.json'))
        if len(files) != count:
            problems.append(f'{folder}: {len(files)} files, expected {count}')
        summary[folder] = len(files)
        for file in files:
            data = json.loads(read(file))
            if not data.get('roads') or not data.get('plots'):
                problems.append(str(file))
    for manifest in ['after/runs.json', 'after/visual_runs.json']:
        runs = json.loads(read(OUT / manifest))
        for run in runs:
            if run['code'] or run['script_errors']:
                problems.append(f'{manifest}: {run["name"]}')
    candidate = json.loads(read(OUT / 'after/candidates/manifest.json'))
    if len(candidate) != 8 or any(r.get('blocking_errors') for r in candidate):
        problems.append('campaign candidates incomplete or blocked')
    for side in ['before', 'after']:
        if len(list((OUT / side / 'art').glob('*.png'))) != 27:
            problems.append(f'{side}: expected 27 backgrounds')
        if not (OUT / side / 'layout_01.png').is_file():
            problems.append(f'{side}: layout sheet missing')
        for seed in [7, 11, 23]:
            text = read(OUT / side / f'entry_{seed}.log')
            row = next((json.loads(line) for line in text.splitlines()
                        if line.startswith('{') and 'advanced_during_loading' in line), {})
            if not row.get('loading_seen') or row.get('advanced_during_loading') \
                    or row.get('captures') != 4:
                problems.append(f'{side}: entry {seed} incomplete')
            frames = sorted((OUT / side / f'entry_{seed}').glob('*.png'))
            if len(frames) != 4:
                problems.append(f'{side}: entry {seed} frames missing')
            for frame in frames:
                with Image.open(frame) as img:
                    if img.size != (1280, 720):
                        problems.append(f'{frame}: expected 1280x720')
                    img.verify()
    games = json.loads(read(OUT / 'balance/results.json'))
    keys = {(r['side'], r['layout_seed'], r['bot_seed']) for r in games}
    if len(games) != 18 or len(keys) != 18:
        problems.append('paired PvE matrix incomplete')
    for row in games:
        if row['code'] or row['script_errors'] or not row['result']:
            problems.append(row['name'])
    summary['games'] = [{k: r[k] for k in ['name', 'side', 'layout_seed', 'bot_seed']} |
                        {k: r['result'][k] for k in ['result', 'hp', 't']} for r in games]
    pvp = json.loads(read(OUT / 'balance/pvp_adapted_results.json'))
    if len(pvp) != 6 or len({r['name'] for r in pvp}) != 6:
        problems.append('paired PvP matrix incomplete')
    summary['pvp'] = []
    for row in pvp:
        result = (row.get('result') or {}).get('pvp', {})
        if row['code'] or row['script_errors'] or not result:
            problems.append(row['name'])
        summary['pvp'].append(dict(name=row['name'], **result))
    late = json.loads(read(OUT / 'balance/late_results.json'))
    if len(late) != 2 or len({r['name'] for r in late}) != 2:
        problems.append('paired late PvE matrix incomplete')
    for row in late:
        if row['code'] or row['script_errors'] or not row['result']:
            problems.append(row['name'])
    summary['late'] = [{k: r['result'][k] for k in ['result', 'hp', 't']} |
                       {'name': r['name']} for r in late]
    gate = read(OUT / 'gate-console.log')
    if not gate.rstrip().endswith('GATE OK'):
        problems.append('GATE OK missing')
    sheets = sorted(OUT.glob('*compare*.jpg'))
    if len(sheets) != 7:
        problems.append('expected 4 art and 3 entry comparison sheets')
    for sheet in sheets:
        with Image.open(sheet) as img:
            img.verify()
    summary['gate'] = gate.splitlines()[-1] if gate.splitlines() else 'pending'
    summary['problems'] = problems
    summary['spent_rub'] = 0
    summary['evidence_sha256'] = {str(p.relative_to(OUT)): hashlib.sha256(p.read_bytes()).hexdigest()
                                   for p in sheets}
    (OUT / 'acceptance.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2),
                                        encoding='utf-8')
    print(json.dumps({k: v for k, v in summary.items()
                      if k not in ['games', 'pvp', 'late', 'evidence_sha256']},
                     ensure_ascii=False, indent=2))
    raise SystemExit(int(bool(problems)))


if __name__ == '__main__':
    main()
