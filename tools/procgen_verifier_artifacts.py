"""Native-resolution crops and comparison with the verifier's pre-branch map dumps."""
import hashlib
import json
from pathlib import Path
from PIL import Image, ImageChops, ImageStat

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'batches/procgen-verifier-1008'
BASE = Path('C:/AI/necro/batches/verify-1008/procgen/dump_base_1')


def main():
    rows = []
    for seed in (7, 11, 23):
        images = []
        for stage in ('before', 'after'):
            source = OUT / stage / f'gen_{seed}_3_pvp.png'
            im = Image.open(source).convert('RGB')
            x = im.width // 2
            crop = im.crop((x - 300, 0, x + 300, im.height))
            target = OUT / stage / f'axis_gen_{seed}_3_pvp.png'
            crop.save(target)
            images.append(crop)
            rows.append(dict(seed=seed, stage=stage, source=str(source), crop=str(target),
                             box=[x - 300, 0, x + 300, im.height], size=list(crop.size),
                             sha256=hashlib.sha256(target.read_bytes()).hexdigest()))
        diff = ImageChops.difference(*images)
        rows.append(dict(seed=seed, mean_difference=sum(ImageStat.Stat(diff).mean) / 3,
                         identical_pixels=diff.getbbox() is None))
    comparisons = []
    for stage in ('before', 'after'):
        source = OUT / stage / 'gen_1005_3.png'
        crop = Image.open(source).crop((240, 270, 552, 510))
        target = OUT / stage / 'empty_plot_gen_1005_p1.png'
        crop.save(target)
        rows.append(dict(stage=stage, source=str(source), crop=str(target),
                         box=[240, 270, 552, 510], size=list(crop.size),
                         sha256=hashlib.sha256(target.read_bytes()).hexdigest()))
    for new_path in sorted((OUT / 'default-dump').glob('gen_*.json')):
        old_path = BASE / new_path.name
        if not old_path.exists():
            comparisons.append(dict(name=new_path.name, missing_baseline=True))
            continue
        old, new = [json.loads(p.read_text(encoding='utf-8')) for p in (old_path, new_path)]
        old['procgen'].pop('version', None)
        new['procgen'].pop('version', None)
        changed = [key for key in sorted(old.keys() | new.keys()) if old.get(key) != new.get(key)]
        comparisons.append(dict(name=new_path.name, changed_keys=changed))
    report = dict(crops=rows, default_comparison=comparisons,
                  compared=len(comparisons), equal=sum(r.get('changed_keys') == [] for r in comparisons),
                  baseline=str(BASE), ignored_fields=['procgen.version'])
    (OUT / 'artifacts.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps(dict(compared=report['compared'], equal=report['equal'],
                          crops=[r for r in rows if 'identical_pixels' in r]), ensure_ascii=False))
    if report['compared'] != 240 or report['equal'] != 240:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
