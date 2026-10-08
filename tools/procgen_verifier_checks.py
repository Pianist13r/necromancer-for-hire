"""Targeted verifier checks only; never invokes the full gate."""
import argparse
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'batches/procgen-verifier-1008'
GODOT = 'C:/Projects/SharedTools/godot/Godot_v4.7.2-stable_win64_console.exe'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--visual', action='store_true')
    parser.add_argument('--only', help='Rerun one affected script, retaining previous log and summary')
    args = parser.parse_args()
    env = dict(os.environ, APPDATA=str(OUT / 'appdata-checks'),
               NECRO_NO_DEV_BRIDGE='1', NECRO_NO_METRICS='1')
    if args.visual:
        jobs = [('procgen_bg_dump', ['--maps', 'gen:7:3:pvp,gen:11:3:pvp,gen:23:3:pvp,gen:1005:3',
                                    '--out', str(OUT / 'after')])]
    else:
        jobs = [(name, []) for name in ['legion_procgen_1008_test', 'legion_procgen_mode_test',
                'legion_procgen_mode_guard_test', 'legion_procgen_harmony_test', 'legion_pvp_ground_test']]
        jobs += [('campaign_candidates', ['--out', str(OUT / 'candidates')]),
                 ('legion_campaign_candidate_test', ['--candidate-dir', str(OUT / 'candidates')]),
                 ('procgen_dump', ['--seeds', '1001-1024', '--k', '1-10',
                                   '--out', str(OUT / 'default-dump')])]
    summary = OUT / ('visual.json' if args.visual else 'checks.json')
    rows = []
    if args.only:
        jobs = [(name, extra) for name, extra in jobs if name == args.only]
        if not jobs:
            raise SystemExit('Unknown check')
        if summary.exists():
            rows = json.loads(summary.read_text(encoding='utf-8'))
    for name, extra in jobs:
        command = [GODOT, '--path', str(ROOT / 'godot'), '--fixed-fps', '60']
        command += ['--position', '-5000,-5000'] if args.visual else ['--headless']
        command += ['--script', 'res://tests/' + name + '.gd', '--', '--mute', *extra]
        path = OUT / (name + '.log')
        if args.only and path.exists():
            backup = path.with_suffix('.previous.log')
            if not backup.exists():
                path.rename(backup)
        with path.open('w', encoding='utf-8') as log:
            result = subprocess.run(command, cwd=ROOT, env=env, stdout=log,
                                    stderr=subprocess.STDOUT, timeout=1800)
        text = path.read_text(encoding='utf-8')
        row = dict(name=name, code=result.returncode, script_errors=text.count('SCRIPT ERROR'),
                   log=str(path), command=command)
        rows = [old for old in rows if old['name'] != name] + [row]
        summary.write_text(
            json.dumps(rows, ensure_ascii=False, indent=2), encoding='utf-8')
        print(json.dumps(row, ensure_ascii=False), flush=True)
    raise SystemExit(int(any(r['code'] or r['script_errors'] for r in rows)))


if __name__ == '__main__':
    main()
