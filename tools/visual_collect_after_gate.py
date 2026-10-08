"""Снять итоговые кадры только после фактической строки GATE OK своего прогона."""
from pathlib import Path
import os
import shutil
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'batches/visual-1008'
ENGINE = 'C:/Projects/SharedTools/godot/Godot_v4.7.2-stable_win64_console.exe'


def capture(project, script, destination, log):
    env = dict(os.environ, APPDATA=str(OUT / 'gallery-appdata'),
               NECRO_NO_DEV_BRIDGE='1', NECRO_NO_METRICS='1')
    with (OUT / log).open('w', encoding='utf-8') as stream:
        code = subprocess.call([ENGINE, '--path', str(project), '--position', '3000,2000',
                                '--script', script, '--', '--mute',
                                f'--out={OUT / destination}'], env=env,
                               stdout=stream, stderr=subprocess.STDOUT)
    errors = [line for line in (OUT / log).read_text('utf-8').splitlines()
              if 'SCRIPT ERROR' in line or 'Parse Error' in line]
    if code or errors:
        raise RuntimeError(f'{log}: exit {code}; {errors[:3]}')
    print('Captured', destination, flush=True)


def main():
    gate = Path(os.environ.get('VISUAL_GATE_LOG', str(OUT / 'gate-console.log')))
    while True:
        data = gate.read_bytes() if gate.exists() else b''
        log = data.decode('utf-16' if data.startswith(b'\xff\xfe') else 'utf-8', errors='replace')
        if 'GATE FAIL:' in log:
            raise RuntimeError('Гейт не пройден; кадры не снимаются.')
        if log.rstrip().endswith('GATE OK'):
            print('Verified GATE OK; starting final captures', flush=True)
            break
        time.sleep(2)
    reference = OUT / 'reference/godot'
    shutil.copy2(ROOT / 'godot/tests/visual_gallery_probe.gd', reference / 'tests/visual_gallery_probe.gd')
    capture(reference, 'res://tests/visual_gallery_probe.gd', 'gallery_before', 'gallery-before.log')
    capture(ROOT / 'godot', 'res://tests/visual_gallery_probe.gd', 'gallery_after', 'gallery-after.log')
    capture(reference, 'res://tests/visual_capture_probe.gd', 'before/run1', 'final-before-crowd.log')
    capture(ROOT / 'godot', 'res://tests/visual_capture_probe.gd', 'after/run1', 'final-crowd.log')
    for mode in ['comparison', 'cauldron_comparison', 'motion']:
        subprocess.run(['python', '-X', 'utf8', str(ROOT / 'tools/visual_1008_sheets.py'), mode],
                       cwd=ROOT, check=True)
    print('VISUAL ARTIFACTS READY', flush=True)


if __name__ == '__main__':
    main()
