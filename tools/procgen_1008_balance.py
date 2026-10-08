"""Paired layout smoke, plus a bounded B-297 observation; does not change combat."""
import argparse
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'batches/procgen-1008/balance'
GODOT = 'C:/Projects/SharedTools/godot/Godot_v4.7.2-stable_win64_console.exe'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--suite', choices=['pve', 'pvp', 'late'], default='pve')
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    if args.suite != 'pve':
        extra(args.suite)
        return
    rows = []
    # Same bot seed, profile, difficulty and frozen input per side.
    for seed in [1001, 1002, 1003]:
        for side in ['before', 'after']:
            for bot in [1, 2, 3]:
                name = f'{side}_{seed}_s{bot}'
                fixture = ROOT / f'batches/procgen-1008/{side}/dump/gen_{seed}_3.json'
                command = [GODOT, '--headless', '--path', str(ROOT / 'godot'), '--fixed-fps', '60',
                           '--quit-after', '90000', '--script', 'res://tests/procgen_1008_balance.gd',
                           '--', '--mute', '--fixture', str(fixture), '--bot', 'selective',
                           '--seed', str(bot), '--quit-on-end', '--dev', 'profile=base',
                           '--dev', 'difficulty=normal', '--dev', 'steps=8']
                row = run(name, command)
                row.update(side=side, layout_seed=seed, bot_seed=bot)
                rows.append(row)
                (OUT / 'results.json').write_text(json.dumps(rows, ensure_ascii=False, indent=2),
                                                  encoding='utf-8')
    raise SystemExit(int(any(r['code'] or r['script_errors'] or not r['result'] for r in rows)))


def extra(suite):
    rows = []
    for side in ['before', 'after']:
        for seed in ([7, 11, 23] if suite == 'pvp' else [1001]):
            if suite == 'pvp':
                fixture = ROOT / f'batches/procgen-1008/{side}/pvp/pvp_{seed}_3.json'
                name = f'pvp_adapted_{side}_{seed}'
                flags = ['--pvp-bots']
            else:
                fixture = ROOT / f'batches/procgen-1008/{side}/dump/gen_{seed}_10.json'
                name = f'late_{side}_{seed}_k10'
                flags = ['--bot', 'selective', '--dev', 'difficulty=normal']
            command = [GODOT, '--headless', '--path', str(ROOT / 'godot'), '--fixed-fps', '60',
                       '--quit-after', '50000' if suite == 'pvp' else '90000',
                       '--script', 'res://tests/procgen_1008_balance.gd', '--', '--mute',
                       '--fixture', str(fixture), '--seed', '1', '--quit-on-end',
                       '--dev', 'profile=base', '--dev', 'steps=8', *flags]
            row = run(name, command)
            if suite == 'pvp' and not (row['result'] or {}).get('pvp'):
                raise RuntimeError('Not a PvP result: ' + name)
            rows.append(row)
            filename = 'pvp_adapted_results.json' if suite == 'pvp' else 'late_results.json'
            (OUT / filename).write_text(json.dumps(rows, ensure_ascii=False, indent=2),
                                       encoding='utf-8')
    raise SystemExit(int(any(r['code'] or r['script_errors'] or not r['result'] for r in rows)))


def run(name, command):
    env = dict(os.environ, APPDATA=str(OUT / 'appdata' / name), NECRO_NO_METRICS='1',
               NECRO_NO_DEV_BRIDGE='1')
    with (OUT / f'{name}.log').open('w', encoding='utf-8') as log:
        proc = subprocess.run(command, cwd=ROOT, env=env, stdout=log,
                              stderr=subprocess.STDOUT, timeout=1800)
    text = (OUT / f'{name}.log').read_text(encoding='utf-8')
    results = [json.loads(line) for line in text.splitlines()
               if line.startswith('{') and '"result"' in line]
    row = dict(name=name, code=proc.returncode, script_errors=text.count('SCRIPT ERROR'),
               result=results[-1] if len(results) == 1 else None)
    print(json.dumps(row, ensure_ascii=False), flush=True)
    return row


if __name__ == '__main__':
    main()
