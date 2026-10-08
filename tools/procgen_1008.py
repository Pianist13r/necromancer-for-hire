"""Isolated reproducible procgen acceptance. All writes stay in this worktree."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
GODOT = 'C:/Projects/SharedTools/godot/Godot_v4.7.2-stable_win64_console.exe'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('stage', choices=['before', 'after'])
    parser.add_argument('--visual', action='store_true')
    args = parser.parse_args()
    out = ROOT / 'batches/procgen-1008' / args.stage
    out.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, APPDATA=str(out / 'appdata'), NECRO_NO_DEV_BRIDGE='1',
               NECRO_NO_METRICS='1')
    summary = []

    def run(name, script, extra=(), visual=False):
        command = [GODOT, '--path', str(ROOT / 'godot'), '--fixed-fps', '60']
        command += ['--resolution', '1280x720'] if visual else ['--headless']
        command += ['--script', 'res://tests/' + script, '--', '--mute', *extra]
        started = time.monotonic()
        with (out / (name + '.log')).open('w', encoding='utf-8') as log:
            result = subprocess.run(command, env=env, cwd=ROOT, stdout=log,
                                    stderr=subprocess.STDOUT, timeout=3600)
        log_text = (out / (name + '.log')).read_text(encoding='utf-8')
        row = dict(name=name, code=result.returncode, seconds=time.monotonic() - started,
                   script_errors=log_text.count('SCRIPT ERROR'), command=command)
        summary.append(row)
        (out / ('visual_runs.json' if args.visual else 'runs.json')).write_text(json.dumps(summary, ensure_ascii=False, indent=2),
                                       encoding='utf-8')
        print(json.dumps(row, ensure_ascii=False), flush=True)

    if not args.visual:
        run('series', 'procgen_dump.gd', ['--seeds', '1001-1024', '--k', '1-10',
                                         '--out', str(out / 'dump')])
        if args.stage == 'after':
            run('200_seeds', 'procgen_dump.gd', ['--seeds', '2001-2200', '--k', '3',
                                               '--out', str(out / 'stress')])
        run('pvp', 'procgen_pvp_dump.gd', ['--seeds', '7-23', '--k', '3',
                                         '--out', str(out / 'pvp')])
        run('candidates', 'campaign_candidates.gd', ['--out', str(out / 'candidates')])
        run('regression', 'legion_procgen_1008_test.gd')
        frozen = ROOT / 'batches/procgen-1008/before/dump'
        run('filter_bench', 'procgen_1008_bench.gd', ['--dir', str(frozen)])
        if args.stage == 'after':
            run('filter_quick', 'procgen_1008_bench.gd', ['--dir', str(frozen), '--quick'])
            run('reject_full', 'procgen_1008_bench.gd', ['--dir', str(frozen), '--invalid'])
            run('reject_quick', 'procgen_1008_bench.gd', ['--dir', str(frozen), '--invalid', '--quick'])
    else:
        maps = ','.join([f'gen:{s}:3' for s in range(1001, 1025)] +
                        [f'gen:{s}:3:pvp' for s in [7, 11, 23]])
        run('backgrounds', 'procgen_bg_dump.gd', ['--maps', maps, '--out', str(out / 'art')], True)
        for seed in [7, 11, 23]:
            run(f'entry_{seed}', 'procgen_1008_entry.gd', ['--autostart', '--map', f'gen:{seed}:3',
                '--bot', 'selective', '--dev', 'save=user://procgen_1008_entry.cfg',
                '--out', str(out / f'entry_{seed}')], True)
    raise SystemExit(int(any(row['code'] or row['script_errors'] for row in summary)))


if __name__ == '__main__':
    main()
