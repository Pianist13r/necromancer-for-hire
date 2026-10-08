"""Contact sheets of actual rendered frames and map diagrams; no generated imagery."""
import json
from pathlib import Path
import subprocess

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'batches/procgen-1008'
FONT = ImageFont.truetype('C:/Windows/Fonts/segoeui.ttf', 22)


def paired(paths, prefix, per=8):
    for start in range(0, len(paths), per):
        batch = paths[start:start + per]
        sheet = Image.new('RGB', (1280, len(batch) * 390), '#20222a')
        draw = ImageDraw.Draw(sheet)
        for row, relative in enumerate(batch):
            for col, side in enumerate(['before', 'after']):
                path = OUT / side / relative
                picture = Image.open(path).convert('RGB')
                picture.thumbnail((640, 360))
                sheet.paste(picture, (col * 640, row * 390 + 30))
                draw.text((col * 640 + 8, row * 390 + 2),
                          f'{side} / {relative}', fill='white', font=FONT)
        sheet.save(OUT / f'{prefix}_{start // per + 1:02}.jpg', quality=93)


def main():
    only = ','.join(f'gen_{s}_3' for s in range(1001, 1025))
    for side in ['before', 'after']:
        subprocess.run(['python', '-X', 'utf8', 'tools/procgen_sheet.py',
                        str(OUT / side / 'dump'), str(OUT / side / 'layout'),
                        '--only', only, '--cols', '4', '--per', '24', '--scale', '0.3'],
                       cwd=ROOT, check=True)
    paths = [f'art/gen_{seed}_3.png' for seed in range(1001, 1025)]
    paths += [f'art/gen_{seed}_3_pvp.png' for seed in [7, 11, 23]]
    paired(paths, 'art_compare')
    paired([f'entry_{seed}/{t}s.png' for seed in [7, 11, 23]
            for t in ['0.1', '0.8', '2.0', '5.0']], 'entry_compare', 4)
    counts = {}
    for path in (OUT / 'after/dump').glob('*.json'):
        data = json.loads(path.read_text(encoding='utf-8'))
        pattern = data['procgen']['card'].get('plot_pattern', 'ordinary')
        counts[pattern] = counts.get(pattern, 0) + 1
    (OUT / 'patterns.json').write_text(json.dumps(counts, indent=2), encoding='utf-8')
    print(counts)


if __name__ == '__main__':
    main()
