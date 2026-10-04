import argparse, concurrent.futures, hashlib, json, os, pathlib, statistics, subprocess, time

ROOT = pathlib.Path(__file__).resolve().parents[1]
GODOT = 'C:/Projects/SharedTools/godot/Godot_v4.7.2-stable_win64_console.exe'
p = argparse.ArgumentParser()
p.add_argument('name')
p.add_argument('--maps', default='wasteland,fork,bridge,maze,swamp,boss')
p.add_argument('--policies', default='selective,hold,release')
p.add_argument('--seeds', default='91,92,93,94,95')
p.add_argument('--profiles', default='base')
p.add_argument('--dev', default='')
p.add_argument('--parallel', type=int, default=3)
a = p.parse_args()
if not 1 <= a.parallel <= 3:
    p.error('--parallel must be 1..3')
if any(int(s) in {*range(1, 16), *range(51, 66)} for s in a.seeds.split(',')):
    p.error('v16 uses tuning seeds 91..95 and reporting seeds 96..99')
out = ROOT / 'batches/v16/balance' / a.name
out.mkdir(parents=True, exist_ok=True)
sources=[ROOT/'godot/scripts/legion/legion_cfg.gd', ROOT/'godot/tests/legion_balance_runner.gd', ROOT/'godot/scripts/legion/staff.gd', ROOT/'godot/scripts/legion/legion_hero.gd']
sources += [ROOT/f'godot/scripts/legion/{name}.gd' for name in
            ['wave_runner', 'legion_world', 'legion_bot']]
sources.append(pathlib.Path(__file__).resolve())
sources += [ROOT/f'godot/assets/legion/maps/{m}.json' for m in a.maps.split(',')]
source_hashes = {str(f.relative_to(ROOT)):hashlib.sha256(f.read_bytes()).hexdigest() for f in sources}
(out/'manifest.json').write_text(json.dumps({'args':vars(a), 'sources':source_hashes},indent=2),encoding='utf-8')
def run(job):
    m, policy, profile, seed = job
    f = out / f'{m}_{policy}_{profile}_{seed}.log'
    cmd = [GODOT, '--headless', '--path', str(ROOT/'godot'), '--fixed-fps', '60',
           '--log-file', str(out/(f.stem + '.engine.log')),
           '--quit-after', '60000', '--script', 'res://tests/legion_balance_runner.gd',
           '--', '--mute', '--trace', '--bot', policy, '--seed', seed, '--map', m, '--quit-on-end',
           '--dev', f'profile={profile}']
    if a.dev:
        for flag in a.dev.split(';'): cmd += ['--dev', flag]
    env = os.environ.copy()
    env['APPDATA'] = str(out/'userdata'/f.stem)
    pathlib.Path(env['APPDATA']).mkdir(parents=True, exist_ok=True)
    with f.open('w', encoding='utf-8') as log:
        proc = subprocess.run(cmd, stdout=log, stderr=subprocess.STDOUT, timeout=900, env=env)
    txt = f.read_text(encoding='utf-8')
    rows = [json.loads(s) for s in txt.splitlines() if s.startswith('{') and '"result"' in s]
    if proc.returncode or not rows or 'SCRIPT ERROR' in txt or 'ERROR:' in txt:
        raise RuntimeError(f'Invalid run {f}')
    row = rows[-1] | {'profile': profile}
    trace = [json.loads(s) for s in txt.splitlines() if s.startswith('{') and '"mana"' in s and '"foes"' in s]
    if len(trace) < 2:
        raise RuntimeError(f'Missing trace {f}')
    pairs = list(zip(trace, trace[1:]))
    row['fight_share'] = sum(r['kills'] > prev['kills'] for prev, r in pairs) / len(pairs)
    row['no_enemy_share'] = sum(r['foes'] == 0 for prev, r in pairs) / len(pairs)
    # Native silence timer covers the whole interval, including hits between snapshots.
    row['no_damage_share'] = sum(r['no_dmg_s'] >= r['t'] - prev['t'] - 1e-6
                                for prev, r in pairs) / len(pairs)
    row['line_restores'] = trace[-1]['line_restores']
    print(m, policy, profile, seed, row['result'], row['hp'], flush=True)
    return row
jobs = [(m, p, pr, s) for m in a.maps.split(',') for p in a.policies.split(',')
        for pr in a.profiles.split(',') for s in a.seeds.split(',')]
with concurrent.futures.ThreadPoolExecutor(max_workers=a.parallel) as pool:
    pending = {pool.submit(run, job): job for job in jobs}
    rows, failures = [], []
    for future in concurrent.futures.as_completed(pending):
        try:
            rows.append(future.result())
        except Exception as error:
            failures.append({'job':pending[future], 'error':str(error)})
            print('INVALID', pending[future], str(error), flush=True)
rows.sort(key=lambda r:(a.maps.split(',').index(r['map']),r['profile'],r['bot'],r['seed']))
changed = [str(f.relative_to(ROOT)) for f in sources
           if source_hashes[str(f.relative_to(ROOT))] != hashlib.sha256(f.read_bytes()).hexdigest()]
if changed:
    failures.append({'error':'Sources changed during series', 'files':changed})
(out/'results.json').write_text(json.dumps(rows, indent=2), encoding='utf-8')
(out/'failures.json').write_text(json.dumps(failures, indent=2), encoding='utf-8')
lines = ['|map|policy|profile|wins|HP median|lost median|seconds median|contact|fight %|no damage %|empty %|restores|', '|---|---|---|---|---|---|---|---|---|---|---|---|']
for m,p,pr in dict.fromkeys((r['map'],r['bot'],r['profile']) for r in rows):
    group=[r for r in rows if (r['map'],r['bot'],r['profile'])==(m,p,pr)]
    vals=[round(statistics.median(r[k] for r in group), 2) for k in ['hp','lost','t','first_contact_t']]
    vals += [round(100 * statistics.median(r[k] for r in group), 1) for k in ['fight_share','no_damage_share','no_enemy_share']]
    vals += [statistics.median(r['line_restores'] for r in group)]
    lines.append(f'|{m}|{p}|{pr}|{sum(r["result"]=="victory" for r in group)}/{len(group)}|'+'|'.join(map(str,vals))+'|')
(out/'summary.md').write_text('\n'.join(lines)+'\n',encoding='utf-8')
print('\n'.join(lines))
if failures:
    raise SystemExit(f'{len(failures)} invalid runs; incomplete groups are not acceptance evidence')
