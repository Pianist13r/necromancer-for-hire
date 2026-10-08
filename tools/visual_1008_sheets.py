"""Воспроизводимые листы приёмки. Исходные игровые кадры остаются без надписей."""
from pathlib import Path
import json
import argparse
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'batches/visual-1008'
FONT = ImageFont.truetype('C:/Windows/Fonts/arial.ttf', 22)


def cauldrons():
    canvas = Image.new('RGB', (1200, 640), '#25212d')
    draw = ImageDraw.Draw(canvas)
    for index, name in enumerate(['fork', 'bridge', 'gatehouse', 'wasteland',
                                  'boss', 'swamp', 'archive', 'maze']):
        spec = json.loads((ROOT / f'godot/assets/legion/maps/{name}.json').read_text('utf-8'))
        x, y = [int(v * 1.5) for v in spec['cauldron']]
        image = Image.open(ROOT / spec['bg'].replace('res://', 'godot/'))
        crop = image.crop((x - 150, y - 150, x + 150, y + 150))
        left, top = index % 4 * 300, index // 4 * 320
        canvas.paste(crop, (left, top + 20))
        draw.text((left + 8, top), name, font=FONT, fill='white')
    canvas.save(OUT / 'cauldron-backgrounds.png')


def clerk():
    canvas = Image.new('RGB', (1400, 600), '#32343d')
    draw = ImageDraw.Draw(canvas)
    for row, direction in enumerate(['e', 'se', 's', 'ne', 'n']):
        for col, (clip, frame) in enumerate([('idle', 0), ('walk', 0), ('attack', 0),
                                            ('attack', 5), ('attack', 11), ('death', 5)]):
            image = Image.open(ROOT / f'godot/assets/anim/clerk/{clip}_{direction}/spr_{frame:02}.png')
            image.thumbnail((110, 110))
            x, y = col * 228 + 75, row * 120
            canvas.paste(image, (x, y), image)
            draw.text((col * 228 + 4, y + 94), f'{direction} {clip} {frame}', font=FONT, fill='white')
    canvas.save(OUT / 'clerk-current-clips.png')


def comparison():
    before = Image.open(OUT / 'before/run1/crowd.png').convert('RGB')
    after = Image.open(OUT / 'after/run1/crowd.png').convert('RGB')
    canvas = Image.new('RGB', (1920, 2110), '#1c1726')
    draw = ImageDraw.Draw(canvas)
    for x, im, folder, label in [(0, before, 'gallery_before', 'ДО · master'),
                                 (960, after, 'gallery_after', 'ПОСЛЕ · visual-1008')]:
        battle = Image.open(OUT / folder / 'battle_2399.png').convert('RGB')
        canvas.paste(battle.resize((960, 540), Image.Resampling.LANCZOS), (x, 42))
        draw.text((x + 18, 10), label, font=FONT, fill='#ffe0a0')
        draw.text((x + 18, 600), 'Нагрузка: 300 врагов + 24 своих', font=FONT, fill='#ffe0a0')
        canvas.paste(im.resize((960, 540), Image.Resampling.LANCZOS), (x, 632))
        draw.text((x + 18, 1194), 'Опора Котла и читаемость толпы · фрагменты 1:1',
                  font=FONT, fill='#ffe0a0')
        canvas.paste(im.crop((130, 380, 470, 640)), (x + 20, 1230))
        canvas.paste(im.crop((820, 365, 1250, 670)), (x + 390, 1230))
    for x, folder in [(0, 'gallery_before'), (960, 'gallery_after')]:
        path = OUT / folder / 'settings.png'
        if path.exists():
            draw.text((x + 18, 1538), 'Настройки изображения', font=FONT, fill='#ffe0a0')
            canvas.paste(Image.open(path).convert('RGB').resize((960, 540),
                         Image.Resampling.LANCZOS), (x, 1570))
    canvas.save(OUT / 'comparison.jpg', quality=94)


def cauldron_comparison():
    canvas = Image.new('RGB', (1600, 1060), '#1c1726')
    draw = ImageDraw.Draw(canvas)
    for index, name in enumerate(['fork', 'bridge', 'gatehouse', 'wasteland',
                                  'boss', 'swamp', 'archive', 'maze']):
        spec = json.loads((ROOT / f'godot/assets/legion/maps/{name}.json').read_text('utf-8'))
        cx, cy = [int(v * 1.5) for v in spec['cauldron']]
        x, y = index % 4 * 400, index // 4 * 530
        draw.text((x + 10, y + 4), name + ' · до / после', font=FONT, fill='#ffe0a0')
        for row, folder in enumerate(['gallery_before', 'gallery_after']):
            image = Image.open(OUT / folder / f'cauldron_{name}.png')
            crop = image.crop((cx - 200, cy - 150, cx + 200, cy + 90))
            canvas.paste(crop, (x, y + 35 + row * 245))
    canvas.save(OUT / 'cauldrons-comparison.jpg', quality=95)


def motion():
    # Только последовательные кадры viewport; цвет/геометрия рисунка не меняются.
    frames = []
    for index in range(12):
        canvas = Image.new('RGB', (800, 310), '#1c1726')
        draw = ImageDraw.Draw(canvas)
        for x, folder, label in [(0, 'gallery_before', 'До'),
                                  (400, 'gallery_after', 'После')]:
            image = Image.open(OUT / folder / f'cauldron_motion_{index:02d}.png')
            canvas.paste(image.crop((70, 360, 470, 640)), (x, 30))
            draw.text((x + 10, 2), label, font=FONT, fill='#ffe0a0')
        frames.append(canvas)
    # Замедлено для проверки короткого отклика, не запись в реальном времени.
    frames[0].save(OUT / 'cauldron-motion.webp', save_all=True,
                   append_images=frames[1:], duration=70, loop=0, lossless=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('mode', choices=['cauldrons', 'clerk', 'comparison', 'cauldron_comparison', 'motion'])
    globals()[parser.parse_args().mode]()
