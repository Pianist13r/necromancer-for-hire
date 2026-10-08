"""B-199: воспроизведение очистки пяти фонов и возврат оригиналов swamp/archive.

Мастер — закреплённый исходный коммит. --apply пишет только готовые фоны в этом дереве.
Исходники и маски сохраняются в batches/visual-1008/provenance, генерации нет.
"""
from pathlib import Path
import argparse
import subprocess
import json
import cv2
import numpy as np
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'batches/visual-1008/provenance'
BASELINE = '0567a962134fa8183f62f2272def8666daea4684'
SIZES = {'fork': (89, 94), 'bridge': (46, 47), 'gatehouse': (85, 100),
         'wasteland': (48, 50), 'boss': (53, 57), 'swamp': (48, 49), 'archive': (77, 85)}
RESTORE_ORIGINAL = {'swamp', 'archive'}


def main(apply, maps):
    OUT.mkdir(parents=True, exist_ok=True)
    sheet = Image.new('RGB', (2100, 610), '#282231')
    text = ImageDraw.Draw(sheet)
    font = ImageFont.truetype('C:/Windows/Fonts/arial.ttf', 22)
    for index, (name, radius) in enumerate(SIZES.items()):
        if maps and name not in maps:
            continue
        rel = f'godot/assets/legion/maps/{name}_bg.jpg'
        original = subprocess.check_output(['git', 'show', f'{BASELINE}:{rel}'], cwd=ROOT)
        (OUT / f'{name}_original.jpg').write_bytes(original)
        source = cv2.imdecode(np.frombuffer(original, np.uint8), cv2.IMREAD_COLOR)
        spec = json.loads((ROOT / f'godot/assets/legion/maps/{name}.json').read_text('utf-8'))
        center = tuple(round(v * 1.5) for v in spec['cauldron'])
        mask = np.zeros(source.shape[:2], np.uint8)
        cv2.ellipse(mask, center, radius, 0, 0, 360, 255, -1)
        # Verifier 08.10: здесь маска пересекает край дороги/настила. Клонирование соседей
        # ломает геометрию, а blur оставляет пятно. Разрешённый fallback — исходный JPG;
        # контактную опору рисует cauldron_view.gd поверх карты, без порчи живописи.
        if name in RESTORE_ORIGINAL:
            repaired = source
        else:
            # Исторический рецепт остальных пяти фонов; доводка их не перезаписывает.
            repaired = cv2.inpaint(source, mask, 11, cv2.INPAINT_TELEA)
            low = cv2.GaussianBlur(repaired.astype(np.float32), (0, 0), 8)
            texture = np.roll(source.astype(np.float32), -155, axis=0)
            detail = texture - cv2.GaussianBlur(texture, (0, 0), 3)
            fill = np.clip(low + np.clip(detail, -3, 3) * 0.55, 0, 255)
            feather = cv2.GaussianBlur(mask.astype(np.float32) / 255, (0, 0), 2)[..., None]
            repaired = np.clip(source * (1 - feather) + fill * feather, 0, 255).astype(np.uint8)
        cv2.imwrite(str(OUT / f'{name}_mask.png'), mask)
        cv2.imwrite(str(OUT / f'{name}_repaired.jpg'), repaired, [cv2.IMWRITE_JPEG_QUALITY, 97])
        if apply:
            (ROOT / rel).write_bytes(original if name in RESTORE_ORIGINAL
                                    else (OUT / f'{name}_repaired.jpg').read_bytes())
        x, y = center
        for row, array in enumerate([source, repaired]):
            crop = Image.fromarray(cv2.cvtColor(array, cv2.COLOR_BGR2RGB)).crop(
                (x - 150, y - 150, x + 150, y + 150))
            sheet.paste(crop, (index * 300, row * 305))
        text.text((index * 300 + 5, 0), name, font=font, fill='white')
    sheet.save(OUT / 'cleanup-review.jpg', quality=94)
    (OUT / 'provenance.json').write_text(json.dumps({
        'source': BASELINE,
        'method': 'OpenCV TELEA radius 11; blur sigma 8; detail clip +/-3 * 0.55; feather sigma 2',
        'opencv_version': cv2.__version__, 'numpy_version': np.__version__,
        'masks': SIZES, 'paid_calls': 0, 'rub': 0, 'applied': apply,
        'restore_original_byte_exact': sorted(RESTORE_ORIGINAL), 'selected_maps': maps,
    }, ensure_ascii=False, indent=2), encoding='utf-8')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--maps', nargs='*', choices=list(SIZES), default=[])
    args = parser.parse_args()
    main(args.apply, args.maps)
