"""Matched scheme experiment: six maps x three schemes x bot seeds 91..96, PAR=2."""
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timedelta, timezone
import json
import math
import os
from pathlib import Path
import subprocess
from statistics import median
import time

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'batches/procgen-verifier-1008/series'
GODOT = 'C:/Projects/SharedTools/godot/Godot_v4.7.2-stable_win64_console.exe'


def write_json(path, value):
    tmp = path.with_suffix('.tmp')
    tmp.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding='utf-8')
    tmp.replace(path)


def run(name, script, extra):
    env = dict(os.environ, APPDATA=str(OUT / 'appdata' / name),
               NECRO_NO_DEV_BRIDGE='1', NECRO_NO_METRICS='1')
    command = [GODOT, '--headless', '--path', str(ROOT / 'godot'), '--fixed-fps', '60',
               '--script', 'res://tests/' + script, '--', '--mute', *extra]
    path = OUT / (name + '.log')
    start = time.monotonic()
    with path.open('w', encoding='utf-8') as log:
        try:
            process = subprocess.run(command, cwd=ROOT, env=env, stdout=log,
                                     stderr=subprocess.STDOUT, timeout=3600)
            code = process.returncode
        except subprocess.TimeoutExpired:
            code = 124
    text = path.read_text(encoding='utf-8')
    results = [json.loads(line) for line in text.splitlines()
               if line.startswith('{') and '"result"' in line]
    return dict(name=name, code=code, script_errors=text.count('SCRIPT ERROR'),
                seconds=round(time.monotonic() - start, 1), log=str(path),
                result=results[0] if len(results) == 1 else None, command=command)


def battle(fixture, seed):
    name = fixture['name'] + f'_s{seed}'
    row = run(name, 'procgen_1008_balance.gd', [
        '--fixture', fixture['path'], '--bot', 'selective', '--seed', str(seed),
        '--quit-on-end', '--dev', 'save=user://procgen_verifier_series.cfg',
        '--dev', 'profile=base', '--dev', 'difficulty=normal', '--dev', 'steps=8'])
    row.update(fixture=fixture, bot_seed=seed)
    return row


def valid(row):
    result = row.get('result') or {}
    fixture = row['fixture']
    return (not row['code'] and not row['script_errors']
            and result.get('result') in ('victory', 'defeat')
            and result.get('seed') == row['bot_seed']
            and result.get('bot') == 'selective' and result.get('difficulty') == 'normal'
            and result.get('map') == f"gen:{fixture['seed']}:{fixture['k']}"
            and all(isinstance(result.get(k), (float, int)) and math.isfinite(result[k])
                    for k in ('hp', 't')))


def report():
    manifest = json.loads((OUT / 'fixtures/manifest.json').read_text(encoding='utf-8'))
    rows = json.loads((OUT / 'results.json').read_text(encoding='utf-8'))
    now = datetime.now(timezone(timedelta(hours=5))).strftime('%Y-%m-%d %H:%M:%S UTC+5')
    print(f'Срез {now}: завершено {len(rows)}/108, валидных {sum(valid(r) for r in rows)}.')
    print('| Карта | Схема | Валидно / 6 | Побед | HP медиана | Секунды медиана | Логи (91–96) |')
    print('|---|---|---|---|---|---|---|')
    for fixture in manifest:
        group = [r['result'] for r in rows if r['fixture']['name'] == fixture['name'] and valid(r)]
        wins = sum(r['result'] == 'victory' for r in group)
        hp = f"{median(r['hp'] for r in group):.1f}" if group else '—'
        seconds = f"{median(r['t'] for r in group):.1f}" if group else '—'
        print(f"| gen:{fixture['seed']}:{fixture['k']} | {fixture['pattern']} | {len(group)}/6 "
              f"| {wins} | {hp} | {seconds} | `{fixture['name']}_s{{91..96}}.log` |")
    if any(not valid(row) for row in rows):
        raise SystemExit('Invalid results: table excludes failed or mismatched runs')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--wait', action='store_true', help='Wait for status.json done, no engine launch')
    parser.add_argument('--half', action='store_true', help='Only seeds 91..93 (54/108 battles)')
    parser.add_argument('--retry-fixtures', action='store_true', help='Retry failed preparation, retaining logs')
    parser.add_argument('--report', action='store_true', help='Print the current table from validated results')
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    if args.report:
        report()
        return
    status_path = OUT / 'status.json'
    if args.wait:
        while True:
            state = json.loads(status_path.read_text(encoding='utf-8'))
            print(json.dumps(state, ensure_ascii=False), flush=True)
            if state['state'] in ('done', 'failed'):
                raise SystemExit(state.get('code', 1))
            time.sleep(30)
    attempt = 1
    if status_path.exists():
        previous = json.loads(status_path.read_text(encoding='utf-8'))
        if not args.retry_fixtures or previous['state'] != 'failed' or previous['completed']:
            raise SystemExit('Existing series: use --wait; do not overwrite its evidence')
        attempt = previous.get('attempt', 1) + 1
        write_json(OUT / f'status_attempt{attempt - 1}.json', previous)
    status = dict(state='fixtures', pid=os.getpid(), parallel=2, completed=0, attempt=attempt,
                  planned=54 if args.half else 108, full_target=108)
    write_json(status_path, status)
    fixture_dir = OUT / 'fixtures'
    prep = run(f'fixtures_attempt{attempt}', 'procgen_verifier_fixtures.gd', ['--out', str(fixture_dir)])
    write_json(OUT / f'preparation_attempt{attempt}.json', prep)
    if prep['code'] or prep['script_errors']:
        status.update(state='failed', code=1)
        write_json(status_path, status)
        raise SystemExit(1)
    fixtures = json.loads((fixture_dir / 'manifest.json').read_text(encoding='utf-8'))
    rows = []
    status['state'] = 'running'
    write_json(status_path, status)
    with ThreadPoolExecutor(max_workers=2) as pool:
        futures = [pool.submit(battle, fixture, seed)
                   for seed in range(91, 94 if args.half else 97) for fixture in fixtures]
        for future in as_completed(futures):
            row = future.result()
            rows.append(row)
            write_json(OUT / 'results.json', rows)
            status['completed'] = len(rows)
            write_json(status_path, status)
            print(row['name'], row['code'], row['seconds'], flush=True)
    code = int(any(not valid(r) for r in rows))
    status.update(state='done', code=code)
    write_json(status_path, status)
    raise SystemExit(code)


if __name__ == '__main__':
    main()
