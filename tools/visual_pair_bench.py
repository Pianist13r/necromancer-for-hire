"""Парный замер Godot внутри worktree, без переключения его исходников.

Создаёт копию закреплённого исходного коммита в ignored batches, APPDATA изолирован.
Артефакты движка копируются, готовые неизменяемые ассеты — hardlink (не редактировать).
Поочерёдно baseline/after, три пары. Внешние процессы не трогаются.
"""
from pathlib import Path
import argparse
import json
import os
import shutil
import statistics
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'batches/visual-1008'
ENGINE = 'C:/Projects/SharedTools/godot/Godot_v4.7.2-stable_win64_console.exe'
BASELINE = '0567a962134fa8183f62f2272def8666daea4684'


def engine(project, log, *args):
    env = dict(os.environ, APPDATA=str(OUT / 'paired-appdata'),
               NECRO_NO_DEV_BRIDGE='1', NECRO_NO_METRICS='1')
    with log.open('w', encoding='utf-8') as file:
        result = subprocess.run([ENGINE, '--path', str(project), *args], env=env,
                                stdout=file, stderr=subprocess.STDOUT, timeout=240)
    errors = [line for line in log.read_text('utf-8').splitlines()
              if 'SCRIPT ERROR' in line or 'Parse Error' in line]
    if result.returncode or errors:
        raise RuntimeError(f'{log}: exit {result.returncode}; {errors[:3]}')


def main(skip_import=False):
    reference = OUT / 'reference/godot'
    if not reference.exists():
        tracked = subprocess.check_output(['git', 'ls-tree', '-r', '--name-only', BASELINE, 'godot'],
                                          cwd=ROOT, text=True).splitlines()
        changed = set(subprocess.check_output(['git', 'diff', BASELINE, '--name-only'],
                                             cwd=ROOT, text=True).splitlines())
        for rel in tracked:
            source = ROOT / rel
            target = reference / Path(rel).relative_to('godot')
            target.parent.mkdir(parents=True, exist_ok=True)
            if rel in changed:
                target.write_bytes(subprocess.check_output(['git', 'show', f'{BASELINE}:{rel}'], cwd=ROOT))
            elif source.suffix.lower() in {'.png', '.jpg', '.ogg', '.wav', '.ttf', '.webp'}:
                os.link(source, target)
            else:
                shutil.copy2(source, target)
        shutil.copy2(ROOT / 'godot/tests/visual_capture_probe.gd', reference / 'tests/visual_capture_probe.gd')
        shutil.copytree(ROOT / 'godot/.godot', reference / '.godot')
        engine(reference, OUT / 'reference-import.log', '--headless', '--import', '--', '--mute')
    # Один и тот же актуальный харнесс, даже когда копия baseline уже существует.
    shutil.copy2(ROOT / 'godot/tests/visual_capture_probe.gd', reference / 'tests/visual_capture_probe.gd')
    all_results = {'before': [], 'after': []}
    if not skip_import:
        engine(ROOT / 'godot', OUT / 'paired-after-import.log', '--headless', '--import', '--', '--mute')
    for index in range(1, 4):
        # A-B / B-A / A-B: порядок не даёт постоянного преимущества прогретой второй сцене.
        order = ['before', 'after'] if index % 2 else ['after', 'before']
        for label in order:
            project = reference if label == 'before' else ROOT / 'godot'
            dest = OUT / 'paired' / label / f'run{index}'
            engine(project, OUT / f'paired-{label}{index}.log', '--position', '3000,2000',
                   '--script', 'res://tests/visual_capture_probe.gd', '--', '--mute', f'--out={dest}')
            data = json.loads((dest / 'performance.json').read_text('utf-8'))
            all_results[label].append(data['frames'])
            print(label, index, data['frames'], flush=True)
    report = {'runs': all_results, 'median': {}}
    for label, runs in all_results.items():
        report['median'][label] = {key: statistics.median(r[key] for r in runs)
                                   for key in ['mean_ms', 'p99_ms']}
    report['change_percent'] = {key: (report['median']['after'][key] /
                                      report['median']['before'][key] - 1) * 100
                                for key in ['mean_ms', 'p99_ms']}
    report['pass'] = all(change <= 10 for change in report['change_percent'].values())
    (OUT / 'performance-summary.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    print(json.dumps(report['median']), report['change_percent'], 'PASS', report['pass'], flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--skip-import', action='store_true', help='После уже выполненного импорта')
    main(parser.parse_args().skip_import)
