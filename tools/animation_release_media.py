#!/usr/bin/env python3
"""Package captured CharView frames and synchronized before/after source loops."""
import argparse
from html import escape
import json
from pathlib import Path
from PIL import Image, ImageDraw


def write_gallery(root):
    """Local review sheet; relative links keep the QA folder portable."""
    inventories = {
        stage: json.loads((root / stage / 'inventory.json').read_text(encoding='utf-8'))
        for stage in ['before', 'after']
    }
    parts = ['''<!doctype html><html lang="ru"><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Анимации — до и после, 08.10.2026</title>
<style>body{font:16px/1.5 system-ui;background:#282535;color:#eee;max-width:1100px;
margin:auto;padding:24px}a{color:#a9d9ff}summary{cursor:pointer;padding:12px;font-size:20px}
.pair{display:grid;grid-template-columns:1fr 1fr;gap:12px;margin-bottom:24px}
figure{margin:0}img{max-width:100%;height:auto}h2{margin-top:40px}</style>
<h1>Анимации: до и после</h1>
<p>QA-витрина, не игровая запись. Одноразовые клипы удерживают последний кадр 460 мс.
Death_alt использует те же позы с другим темпом; наклон виден в витрине CharView.
Пустая ячейка означает, что клип отсутствовал в исходном реестре.</p>
<h2>Настоящий CharView</h2>''']
    for path in sorted((root / 'comparison').glob('runtime_*.gif')):
        parts.append(f'<details><summary>{escape(path.stem)}</summary>'
                     f'<img loading="lazy" src="comparison/{escape(path.name)}" '
                     f'alt="CharView: {escape(path.stem)}"></details>')
    parts.append('<h2>Исходные клипы по персонажам</h2>')
    count = 0
    for who, clips in inventories['after']['clips'].items():
        parts.append(f'<details><summary>{escape(who)} — {len(clips)} клипов × ракурсов</summary>')
        for key in clips:
            parts.append(f'<h3>{escape(key)}</h3><div class="pair">')
            for stage, label in [('before', 'До'), ('after', 'После')]:
                record = inventories[stage]['clips'].get(who, {}).get(key)
                parts.append(f'<figure><figcaption>{label}</figcaption>')
                if record:
                    relative = f'{stage}/loops/{who}_{key}.gif'
                    if not (root / relative).is_file():
                        raise FileNotFoundError(root / relative)
                    parts.append(f'<a href="{escape(relative)}"><img loading="lazy" '
                                 f'src="{escape(relative)}" alt="{escape(who)} '
                                 f'{escape(key)}, {label}"></a><p>{record["frames"]} кадров, '
                                 f'{record["seconds"]:.3f} с</p>')
                    count += 1
                else:
                    parts.append('<p>Клипа не было</p>')
                parts.append('</figure>')
            parts.append('</div>')
        parts.append('</details>')
    parts.append('</html>')
    (root / 'index.html').write_text('\n'.join(parts), encoding='utf-8')
    print(f'GALLERY OK: {count} verified source GIF links -> index.html')


def verify_timing(root):
    checked, worst = 0, 0.0
    for stage in ['before', 'after']:
        inventory = json.loads((root / stage / 'inventory.json').read_text(encoding='utf-8'))
        registry = json.loads((root / stage / 'registry.json').read_text(encoding='utf-8'))
        for who, clips in inventory['clips'].items():
            for key, record in clips.items():
                state = key.rsplit('_', 1)[0]
                expected = record['seconds'] * 1000
                if not registry[who]['clips'][state]['loop']:
                    expected += 460
                path = root / stage / 'loops' / f'{who}_{key}.gif'
                with Image.open(path) as image:
                    total = 0
                    for index in range(image.n_frames):
                        image.seek(index)
                        duration = image.info['duration']
                        if duration < 20 or duration % 20:
                            raise ValueError(f'Non-browser-safe duration {path}: {duration}')
                        total += duration
                error = abs(total - expected)
                if error > 10.1:
                    raise ValueError(f'GIF timing drift {path}: {total} vs {expected}')
                checked += 1
                worst = max(worst, error)
    print(f'GIF TIMING: {checked}/{checked} OK; max cycle error {worst:.3f}ms')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('root', type=Path)
    parser.add_argument('--gallery-only', action='store_true')
    args = parser.parse_args()
    if args.gallery_only:
        write_gallery(args.root)
        return
    verify_timing(args.root)
    render = args.root / 'after/render'
    out = args.root / 'comparison'
    out.mkdir(parents=True, exist_ok=True)
    stages = ['idle', 'walk_e', 'walk_n', 'attack', 'hit', 'death_a', 'death_b', 'rise', 'cast']
    sheet = Image.new('RGB', (1280, 9 * 180), '#282535')
    for row, stage in enumerate(stages):
        paths = sorted(render.glob(stage + '_*.png'))
        if len(paths) != 24:
            raise ValueError(f'{stage}: expected 24 captured frames, got {len(paths)}')
        frames = [Image.open(p).convert('RGB') for p in paths]
        durations = [70 if i % 3 else 60 for i in range(len(frames))]
        frames[0].save(out / f'runtime_{stage}.gif', save_all=True,
                       append_images=frames[1:], loop=0, duration=durations)
        for column, i in enumerate([0, 2, 5, 8]):
            thumb = frames[i].resize((320, 180), Image.Resampling.LANCZOS)
            sheet.paste(thumb, (column * 320, row * 180))
    sheet.save(out / 'runtime_contact.jpg', quality=94)
    # Put the original and new cadence on the same timeline (Pillow GIF decoding).
    for who in ['skeleton', 'guard', 'clerk', 'zombie', 'beetle', 'boss']:
        tracks = []
        for stage in ['before', 'after']:
            image = Image.open(args.root / stage / 'loops' / f'{who}_walk_e.gif')
            frames, ends, duration = [], [], 0
            for i in range(image.n_frames):
                image.seek(i)
                frames.append(image.convert('RGB'))
                duration += image.info.get('duration', 30)
                ends.append(duration)
            tracks.append((frames, ends, duration))
        frames = []
        for ms in range(0, 2400, 40):
            panel = Image.new('RGB', (512, 280), '#282535')
            draw = ImageDraw.Draw(panel)
            for column, (pictures, ends, total) in enumerate(tracks):
                t = ms % total
                index = next(i for i, end in enumerate(ends) if t < end)
                picture = pictures[index].resize((256, 256), Image.Resampling.LANCZOS)
                panel.paste(picture, (column * 256, 24))
                draw.text((column * 256 + 10, 5), f'{who}: ' + ['BEFORE', 'AFTER'][column], fill='white')
            frames.append(panel)
        frames[0].save(out / f'{who}_walk.gif', save_all=True, append_images=frames[1:], loop=0, duration=40)
    print('MEDIA OK: 9 runtime loops, contact sheet, 6 synchronized comparisons')
    write_gallery(args.root)


if __name__ == '__main__':
    main()
