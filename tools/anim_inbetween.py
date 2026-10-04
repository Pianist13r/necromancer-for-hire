"""Промежуточные кадры клипа персонажа: RIFE + восстановление прозрачности + отбраковка двоения.

Зачем (Игорь 26.09.2026: «анимации более плавные, больше кадров, более естественные»): клипы
врагов нарисованы 4–13 кадрами на 10–15 кадр/с — рывками. Новые позы генератор рисует плохо
(память проекта: «генеративная модель рисует позы, но не цикл»), а промежуточный кадр между
двумя готовыми позами — ровно задача интерполяции движения.

Как:
- RIFE (rife-ncnn-vulkan, C:/tools/rife, MIT) работает с RGB и альфу выбрасывает. Клип
  рисуется поверх двух светлых подложек, RIFE интерполирует обе серии, альфа и цвет
  восстанавливаются из разницы (out = a·F + (1−a)·B). Подложки светлые обе: контур
  персонажей тёмный, и поток на обеих сериях видит одни и те же края.
- Крупное движение (падение, мах рукой) RIFE «двоит»: полупрозрачный второй силуэт. Такой
  кадр отбраковывается по двум признакам относительно соседних исходных кадров — доле
  полупрозрачных пикселей и числу контурных пикселей (калибровка на зомби 26.09: чистые
  1,2–1,6 / ×1,00, двоение 2,6–4,6 / ×1,07–1,27). Вместо него исходный кадр держится
  дольше — длительности кадров пишутся в clip.json и в вывод для CfgAnim.
- Исходные кадры копируются как есть, без потерь.

  python tools/anim_inbetween.py SRC_DIR OUT_DIR --factor 2 [--loop] [--canvas 280]

SRC_DIR / OUT_DIR — папки кадров spr_NN.png. --canvas уменьшает холст (Ланцош по
предумноженной альфе, без тёмной каймы): фигура на экране ~120–140 px, а в холсте 460 —
390 px, и уменьшение в 3 раза без мипмапов даёт зубчатый мерцающий контур.
"""
import argparse
import json
import shutil
import subprocess
import tempfile
from pathlib import Path

import cv2
import numpy as np
from PIL import Image, ImageFilter

RIFE_DIR = Path("C:/tools/rife/rife-ncnn-vulkan-20221029-windows")
BG_A = 250.0
BG_B = 125.0
## пороги двоения — см. докстринг (калибровка на zombie walk/death/attack)
GHOST_SEMI = 2.3
GHOST_EDGE = 1.10
## альфа ниже этого — шум матирования, в ноль
ALPHA_FLOOR = 0.02


def load_clip(d: Path) -> list[np.ndarray]:
    files = sorted(d.glob("spr_*.png"))
    return [np.asarray(Image.open(f).convert("RGBA"), dtype=np.float32) / 255.0 for f in files]


def composite(fr: np.ndarray, bg: float) -> np.ndarray:
    a = fr[..., 3:4]
    return fr[..., :3] * a + (bg / 255.0) * (1.0 - a)


def run_rife(frames_rgb: list[np.ndarray], count: int, model: str, work: Path) -> list[np.ndarray]:
    src, dst = work / "in", work / "out"
    for p in (src, dst):
        shutil.rmtree(p, ignore_errors=True)
        p.mkdir(parents=True)
    for i, fr in enumerate(frames_rgb):
        img = (np.clip(fr, 0, 1) * 255.0 + 0.5).astype(np.uint8)
        Image.fromarray(img).save(src / f"{i:08d}.png")
    cmd = [str(RIFE_DIR / "rife-ncnn-vulkan.exe"), "-i", str(src), "-o", str(dst),
           "-n", str(count), "-m", str(RIFE_DIR / model)]
    subprocess.run(cmd, check=True, capture_output=True)
    return [np.asarray(Image.open(f).convert("RGB"), dtype=np.float32) / 255.0
            for f in sorted(dst.glob("*.png"))]


def unmatte(out_a: np.ndarray, out_b: np.ndarray) -> np.ndarray:
    diff = (out_a - out_b).mean(axis=2, keepdims=True)
    alpha = np.clip(1.0 - diff / ((BG_A - BG_B) / 255.0), 0.0, 1.0)
    premul = out_b - (BG_B / 255.0) * (1.0 - alpha)
    color = np.where(alpha > 1e-3, premul / np.maximum(alpha, 1e-3), 0.0)
    return np.concatenate([np.clip(color, 0, 1), alpha], axis=2)


def dilate_alpha(a: np.ndarray, size: int = 5) -> np.ndarray:
    im = Image.fromarray((np.clip(a, 0, 1) * 255).astype(np.uint8))
    return np.asarray(im.filter(ImageFilter.MaxFilter(size)), dtype=np.float32) / 255.0


def metrics(fr: np.ndarray) -> tuple[float, float]:
    a = fr[..., 3]
    opaque = max(int((a >= 0.92).sum()), 1)
    semi = int(((a > 0.08) & (a < 0.92)).sum())
    rgb = (fr[..., :3] * a[..., None] * 255).astype(np.uint8)
    edges = int((cv2.Canny(cv2.cvtColor(rgb, cv2.COLOR_RGB2GRAY), 40, 110) > 0).sum())
    return semi / opaque, edges / opaque


def inbetween(frames: list[np.ndarray], factor: int, loop: bool, model: str
              ) -> tuple[list[np.ndarray], list[float], list[dict]]:
    """Вернуть (кадры, длительности в долях исходного шага, отчёт по промежуточным)."""
    seq = frames + [frames[0]] if loop else frames
    n_in = len(seq)
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        out_a = run_rife([composite(f, BG_A) for f in seq], factor * n_in, model, work / "a")
        out_b = run_rife([composite(f, BG_B) for f in seq], factor * n_in, model, work / "b")
    src_metrics = [metrics(f) for f in seq]
    pairs = len(frames) if loop else len(frames) - 1
    result: list[np.ndarray] = []
    durations: list[float] = []
    report: list[dict] = []
    for k in range(pairs):
        result.append(seq[k])
        durations.append(1.0)
        hull = dilate_alpha(np.maximum(seq[k][..., 3], seq[k + 1][..., 3]))[..., None]
        ref_semi = (src_metrics[k][0] + src_metrics[k + 1][0]) / 2.0
        ref_edge = (src_metrics[k][1] + src_metrics[k + 1][1]) / 2.0
        mids = []
        ok = True
        for j in range(1, factor):
            i = k * factor + j
            fr = unmatte(out_a[i], out_b[i])
            fr[..., 3:4] = np.minimum(fr[..., 3:4], hull)
            fr[..., 3:4] = np.where(fr[..., 3:4] < ALPHA_FLOOR, 0.0, fr[..., 3:4])
            semi, edge = metrics(fr)
            rs, re = semi / max(ref_semi, 1e-6), edge / max(ref_edge, 1e-6)
            bad = rs > GHOST_SEMI or re > GHOST_EDGE
            report.append({"pair": k, "t": j / factor, "semi": round(rs, 2), "edge": round(re, 2),
                           "rejected": bad})
            ok = ok and not bad
            mids.append(fr)
        if ok:
            # доля исходного шага на каждый кадр пары: 1/factor
            durations[-1] = 1.0 / factor
            for fr in mids:
                result.append(fr)
                durations.append(1.0 / factor)
        # иначе пара целиком остаётся исходным кадром на полный шаг: полу-интерполяция
        # (часть кадров пары есть, часть нет) дала бы рывок темпа посреди движения
    if not loop:
        # последний кадр — полный исходный шаг: длина клипа (замах, труп) не меняется
        result.append(seq[-1])
        durations.append(1.0)
    return result, durations, report


def source_index_map(durations: list[float], factor: int, n_src: int) -> list[int]:
    """Новый номер каждого исходного кадра: исходный кадр открывает свою пару."""
    out, t, i = [], 0.0, 0
    for k in range(n_src):
        while i < len(durations) and abs(t - k) > 1e-6:
            t += durations[i]
            i += 1
        out.append(i)
    return out


def stride_curve(frames: list[np.ndarray]) -> tuple[list[float], float]:
    """Разнос ног по кадрам цикла (0…1) и фаза первого касания (0…1).

    Покачивание корпуса в CharView синхронизируется с нарисованными шагами: тело ниже всего,
    когда ноги разнесены шире всего (касание). Мера — ширина силуэта в нижних 14 % фигуры.
    """
    raw = []
    for fr in frames:
        mask = fr[..., 3] > 0.5
        rows = np.where(mask.any(axis=1))[0]
        if rows.size == 0:
            raw.append(0.0)
            continue
        top, bottom = rows[0], rows[-1]
        band = mask[max(bottom - int((bottom - top) * 0.14), top):bottom + 1]
        cols = np.where(band.any(axis=0))[0]
        raw.append(float(cols[-1] - cols[0]) if cols.size else 0.0)
    v = np.array(raw)
    n = len(v)
    # круговое сглаживание: цикл замкнут
    v = (np.roll(v, 1) + 2 * v + np.roll(v, -1)) / 4.0
    lo, hi = float(v.min()), float(v.max())
    norm = (v - lo) / (hi - lo) if hi - lo > 1e-6 else np.zeros(n)
    return [round(float(x), 3) for x in norm], round(float(np.argmax(norm)) / n, 4)


def resize_premul(fr: np.ndarray, canvas: int) -> np.ndarray:
    if fr.shape[0] == canvas:
        return fr
    a = fr[..., 3:4]
    pre = np.concatenate([fr[..., :3] * a, a], axis=2)
    chans = []
    for c in range(4):
        im = Image.fromarray(pre[..., c].astype(np.float32), mode="F")
        chans.append(np.asarray(im.resize((canvas, canvas), Image.LANCZOS), dtype=np.float32))
    out = np.clip(np.stack(chans, axis=2), 0, 1)
    alpha = out[..., 3:4]
    color = np.where(alpha > 1e-4, out[..., :3] / np.maximum(alpha, 1e-4), 0.0)
    return np.concatenate([np.clip(color, 0, 1), alpha], axis=2)


def save_clip(frames: list[np.ndarray], durations: list[float], out: Path, meta: dict) -> None:
    out.mkdir(parents=True, exist_ok=True)
    # лишние кадры прошлой версии — вместе с .import; у оставшихся номеров .import не трогаем:
    # Godot переимпортирует их сам, а uid ресурса сохранится
    for f in out.glob("spr_*.png"):
        if int(f.stem.split("_")[1]) >= len(frames):
            f.unlink()
            Path(str(f) + ".import").unlink(missing_ok=True)
    for i, fr in enumerate(frames):
        img = (np.clip(fr, 0, 1) * 255.0 + 0.5).astype(np.uint8)
        Image.fromarray(img, "RGBA").save(out / f"spr_{i:02d}.png", optimize=True)
    meta = dict(meta)
    meta["durations"] = [round(d, 4) for d in durations]
    with open(out / "clip.json", "w", encoding="utf8", newline="\n") as fh:
        fh.write(json.dumps(meta, ensure_ascii=False, indent=1))


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("src", type=Path)
    ap.add_argument("out", type=Path)
    ap.add_argument("--factor", type=int, default=2)
    ap.add_argument("--loop", action="store_true")
    ap.add_argument("--canvas", type=int, default=0, help="сторона нового холста, px (0 — как был)")
    ap.add_argument("--model", default="rife-v4.6")
    ap.add_argument("--ghost-semi", type=float, default=GHOST_SEMI,
                    help="порог двоения по полупрозрачности (поднимать только после осмотра глазами)")
    ap.add_argument("--ghost-edge", type=float, default=GHOST_EDGE)
    a = ap.parse_args()
    globals()["GHOST_SEMI"], globals()["GHOST_EDGE"] = a.ghost_semi, a.ghost_edge
    frames = load_clip(a.src)
    if a.factor > 1 and len(frames) > 1:
        res, dur, report = inbetween(frames, a.factor, a.loop, a.model)
    else:
        res, dur, report = frames, [1.0] * len(frames), []
    if a.canvas > 0:
        res = [resize_premul(f, a.canvas) for f in res]
    rejected = sum(1 for r in report if r["rejected"])
    meta = {"src_frames": len(frames), "factor": a.factor, "loop": a.loop, "model": a.model,
            "src_index": source_index_map(dur, a.factor, len(frames)),
            "rejected": rejected, "report": report}
    if a.loop:
        meta["stride"], meta["contact_phase"] = stride_curve(res)
    save_clip(res, dur, a.out, meta)
    print(f"{a.src.name}: {len(frames)} -> {len(res)} кадров, отбраковано {rejected}"
          f" из {len(report)}, сумма длительностей {sum(dur):.2f} шага")


if __name__ == "__main__":
    main()
