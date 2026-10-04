"""Лист 4×4 кадров-доноров для перерисовки генератором и разрезка результата обратно в клипы.

Зачем (26.09.2026): новые персонажи и исправления поз — одной генерацией на 16 кадров (совет
Игоря: «можно экономить и сразу размещать много изображений… плитками, особенно похожие»).
Проверенный приём проекта (сессия e41af8): модель перерисовывает ГОТОВЫЕ позы в другого
персонажа, а не придумывает цикл — позы берутся у донора.

  python tools/sheet_redraw.py compose OUT.png SPEC...      # SPEC = путь/к/клипу[:кадры]
  python tools/sheet_redraw.py split SHEET.png LAYOUT.json OUTDIR [--canvas 320]

compose кладёт рядом OUT.json (раскладка: какой кадр какого клипа в какой ячейке, bbox
донора). Фон ячеек — чистый пурпур #FF00FF: в персонажах его нет, генератор альфу не отдаёт.
split: вырезает пурпур (мягкая альфа + снятие пурпурного ореола), режет по сетке, каждую
фигуру сажает так, чтобы середина ступней и высота совпали с донором (генератор слегка
сдвигает фигуры в ячейке), кладёт кадры в OUTDIR/<клип>/spr_NN.png.
"""
import argparse
import json
from pathlib import Path

import cv2
import numpy as np
from PIL import Image

KEY = np.array([255.0, 0.0, 255.0])
GRID = 4


def load_rgba(p: Path) -> Image.Image:
    return Image.open(p).convert("RGBA")


def compose(out: Path, specs: list[str]) -> None:
    cells = []
    for spec in specs:
        # «C:/…» — двоеточие диска; номера кадров — только после последнего двоеточия и числами
        path, _, rng = spec.rpartition(":")
        if not rng.replace(",", "").isdigit():
            path, rng = spec, ""
        files = sorted(Path(path).glob("spr_*.png"))
        idx = list(range(len(files)))
        if rng:
            idx = [int(x) for x in rng.split(",")]
        for i in idx:
            cells.append((Path(path).name, i, files[i]))
    assert len(cells) <= GRID * GRID, f"ячеек {len(cells)} > 16"
    cell = load_rgba(cells[0][2]).size[0]
    sheet = Image.new("RGB", (cell * GRID, cell * GRID), tuple(int(v) for v in KEY))
    layout = {"cell": cell, "cells": []}
    for k, (clip, i, f) in enumerate(cells):
        im = load_rgba(f)
        x, y = (k % GRID) * cell, (k // GRID) * cell
        bg = Image.new("RGBA", im.size, tuple(int(v) for v in KEY) + (255,))
        sheet.paste(Image.alpha_composite(bg, im).convert("RGB"), (x, y))
        mb = main_bbox(np.asarray(im)[..., 3])
        layout["cells"].append({"clip": clip, "frame": i, "x": x, "y": y, "bbox": im.getbbox(),
                                "main_bbox": mb})
    sheet.save(out)
    out.with_suffix(".json").write_text(json.dumps(layout, ensure_ascii=False, indent=1),
                                        encoding="utf8")
    print(f"{out}: {len(cells)} ячеек по {cell} px")


def unkey(rgb: np.ndarray) -> np.ndarray:
    """Пурпур → прозрачность. Альфа по расстоянию до ключа, цвет — без пурпурной примеси."""
    d = np.linalg.norm(rgb - KEY, axis=2)
    a = np.clip((d - 60.0) / (200.0 - 60.0), 0.0, 1.0)
    # пурпурная примесь на краях: C = a·F + (1−a)·K → F = (C − (1−a)·K)/a
    f = (rgb - (1.0 - a[..., None]) * KEY) / np.maximum(a[..., None], 1e-3)
    f = np.clip(f, 0, 255)
    # остаточный пурпурный оттенок (R и B одновременно выше G) подрезаем до G
    spill = np.minimum(f[..., 0], f[..., 2]) - f[..., 1]
    edge = (a < 0.98)[..., None] & (spill > 0)[..., None]
    f = np.where(edge, np.stack([f[..., 0] - spill * 0.8, f[..., 1], f[..., 2] - spill * 0.8],
                                axis=2), f)
    return np.concatenate([np.clip(f, 0, 255), a[..., None] * 255.0], axis=2)


def main_bbox(alpha: np.ndarray) -> tuple[int, int, int, int] | None:
    """Рамка самой крупной связной фигуры: разлетающиеся листки и искры не в счёт."""
    mask = (alpha > 128).astype(np.uint8)
    n, labels, stats, _ = cv2.connectedComponentsWithStats(mask, 8)
    if n <= 1:
        return None
    i = 1 + int(np.argmax(stats[1:, cv2.CC_STAT_AREA]))
    x, y, w, h = stats[i, :4]
    return int(x), int(y), int(x + w), int(y + h)


def split(sheet_path: Path, layout_path: Path, outdir: Path, canvas: int) -> None:
    layout = json.loads(layout_path.read_text(encoding="utf8"))
    cell = layout["cell"]
    sheet = Image.open(sheet_path).convert("RGB")
    # генератор отдаёт свой размер (например 2048): приводим лист к исходной сетке
    sheet = sheet.resize((cell * GRID, cell * GRID), Image.LANCZOS)
    rgba = unkey(np.asarray(sheet, dtype=np.float32))
    base = Path(layout.get("src_dir", ""))
    # 1) масштаб один на весь лист: генератор рисует персонажа одним ростом, а рамка отдельного
    #    кадра врёт (разлетающиеся бумаги, лёжа). Медиана отношений ростов главной фигуры.
    items, ratios = [], []
    for c in layout["cells"]:
        x, y = c["x"], c["y"]
        fr = rgba[y:y + cell, x:x + cell]
        gb = main_bbox(fr[..., 3])
        db = tuple(c.get("main_bbox") or c["bbox"])
        items.append((c, fr, gb, db))
        if gb and db[3] - db[1] > cell * 0.3 and gb[3] - gb[1] > cell * 0.3:
            ratios.append((db[3] - db[1]) / (gb[3] - gb[1]))
    k = float(np.median(ratios)) if ratios else 1.0
    per_clip: dict[str, list] = {}
    for c, fr, gb, db in items:
        im = Image.fromarray(fr.astype(np.uint8), "RGBA")
        out = Image.new("RGBA", (cell, cell), (0, 0, 0, 0))
        if gb:
            big = im.resize((max(1, round(cell * k)), max(1, round(cell * k))), Image.LANCZOS)
            # 2) низ и середина главной фигуры — как у донора: ноги на той же земле
            gcx, gby = (gb[0] + gb[2]) / 2 * k, gb[3] * k
            dcx, dby = (db[0] + db[2]) / 2, db[3]
            # холст пуст: простая вставка верна и допускает отрицательный сдвиг
            out.paste(big, (int(round(dcx - gcx)), int(round(dby - gby))))
        if canvas and canvas != cell:
            out = out.resize((canvas, canvas), Image.LANCZOS)
        per_clip.setdefault(c["clip"], []).append((c["frame"], out))
    for clip, frames in per_clip.items():
        d = outdir / clip
        d.mkdir(parents=True, exist_ok=True)
        for n, (_, im) in enumerate(sorted(frames, key=lambda t: t[0])):
            im.save(d / f"spr_{n:02d}.png", optimize=True)
        print(f"{d}: {len(frames)} кадров")


def main() -> None:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("compose")
    c.add_argument("out", type=Path)
    c.add_argument("specs", nargs="+")
    s = sub.add_parser("split")
    s.add_argument("sheet", type=Path)
    s.add_argument("layout", type=Path)
    s.add_argument("outdir", type=Path)
    s.add_argument("--canvas", type=int, default=0)
    a = ap.parse_args()
    if a.cmd == "compose":
        compose(a.out, a.specs)
    else:
        split(a.sheet, a.layout, a.outdir, a.canvas)


if __name__ == "__main__":
    main()
