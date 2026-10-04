#!/usr/bin/env python3
"""
make_clip.py — собрать клип анимации ОДНОЙ командой (конвейер v2).

Конвейер: движение берётся у рига, вид у генерации, чистая рисовка возвращается
полировкой, и всё это сводится в игровые спрайты.

    управляющий ролик (риг)  ->  перенос движения  ->  сетка  ->  полировка  ->  нарезка  ->  спрайты

Зачем скрипт: шагов много, и каждый уже наступал на грабли (композиция референса,
батч кадров, якорь по голове). Здесь порядок зафиксирован, чтобы владелец мог собрать
новый клип сам, не держа всё это в голове.

Запуск:
    # весь конвейер для варианта из anim_config.json
    python tools/make_clip.py walk --drive C:/AI/necro/assets/drive/walk_s25 \\
        --wan-variant wa_walk_s25 --polish-variant polish_w8

    # только вторая половина: у меня уже есть кадры переноса движения
    python tools/make_clip.py walk --from-frames C:/AI/necro/assets/wan_out/wa_walk2 \\
        --polish-variant polish_w8

Каждый шаг печатает, что сделал; при падении шага дальше не идём — чтобы не собрать
клип из полуфабриката и не выдать его за готовый.
"""
from __future__ import annotations

import argparse
import json
import pathlib
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
COMFY_INPUT = pathlib.Path(r"C:/AI/ComfyUI/input")
PY = sys.executable


def run(cmd: list[str], step: str) -> None:
    print(f"\n=== {step} ===\n$ {' '.join(str(c) for c in cmd)}", flush=True)
    r = subprocess.run(cmd, cwd=ROOT)
    if r.returncode != 0:
        raise SystemExit(f"шаг «{step}» упал (код {r.returncode}) — дальше не идём")


def stage_transfer(clip: str, drive_dir: pathlib.Path, wan_variant: str, ref_frame: pathlib.Path) -> pathlib.Path:
    """Перенос движения: кадры ролика в ComfyUI, референс под композицию, генерация."""
    dst = COMFY_INPUT / f"necro_{clip}_drive"
    if dst.exists():
        shutil.rmtree(dst)
    dst.mkdir(parents=True)
    frames = sorted(drive_dir.glob("frame_*.png"))
    if not frames:
        raise SystemExit(f"в управляющем ролике нет кадров: {drive_dir}")
    for f in frames:
        shutil.copy(f, dst / f.name)
    print(f"кадров ролика скопировано: {len(frames)} -> {dst}")

    ref_out = COMFY_INPUT / f"necro_{clip}_ref.png"
    run([PY, "tools/fit_reference.py", str(ref_frame), str(frames[0]), str(ref_out),
         "--bg", "128,128,128"], "референс под композицию ролика")

    cfg_path = ROOT / "assets/anim-lab/anim_config.json"
    cfg = json.loads(cfg_path.read_text(encoding="utf-8"))
    for v in cfg["wan_animate"]["variants"]:
        if v["id"] == wan_variant:
            v["ref_image"] = ref_out.name
            v["drive_frames"] = [f"necro_{clip}_drive/{f.name}" for f in frames]
            v["length"] = len(frames) if (len(frames) - 1) % 4 == 0 else ((len(frames) - 1) // 4) * 4 + 1
            break
    else:
        raise SystemExit(f"вариант переноса движения не найден в конфиге: {wan_variant}")
    cfg_path.write_text(json.dumps(cfg, ensure_ascii=False, indent=2), encoding="utf-8")

    run([PY, "tools/anim_lab_comfy.py", "wan-animate", "--variant", wan_variant], "перенос движения")
    return ROOT / "assets/anim-lab/out" / wan_variant


def stage_polish(clip: str, frames_dir: pathlib.Path, polish_variant: str, cols: int, cell: int,
                 every: int, limit: int) -> pathlib.Path:
    """Полировка: кадры -> сетка -> одна генерация -> нарезка обратно."""
    grid = ROOT / f"assets/anim-lab/poses/grid/grid_{clip}.png"
    run([PY, "tools/pose_grid.py", "build", str(frames_dir), str(grid),
         "--cols", str(cols), "--cell", str(cell), "--bg", "128,128,128",
         "--every", str(every), "--limit", str(limit)], "сетка кадров")

    cfg_path = ROOT / "assets/anim-lab/anim_config.json"
    cfg = json.loads(cfg_path.read_text(encoding="utf-8"))
    for v in cfg["qwen_cn"]["variants"]:
        if v["id"] == polish_variant:
            v["ref_image"] = str(grid.relative_to(ROOT)).replace("\\", "/")
            v["width"] = cell * cols
            v["height"] = cell * ((limit + cols - 1) // cols)
            break
    else:
        raise SystemExit(f"вариант полировки не найден в конфиге: {polish_variant}")
    cfg_path.write_text(json.dumps(cfg, ensure_ascii=False, indent=2), encoding="utf-8")

    run([PY, "tools/anim_lab_comfy.py", "qwen-cn", "--variant", polish_variant], "полировка листом целиком")

    out_dir = ROOT / "assets/anim-lab/out" / polish_variant
    results = sorted(out_dir.glob("*.png"))
    if not results:
        raise SystemExit(f"полировка не дала файлов: {out_dir}")
    cut = ROOT / "assets/anim-lab/out" / clip
    run([PY, "tools/pose_grid.py", "slice", str(results[-1]),
         str(grid) + ".json", str(cut)], "нарезка листа обратно на кадры")
    return cut


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("clip", help="имя клипа: walk / attack / idle / hit / spawn")
    ap.add_argument("--drive", help="папка управляющего ролика (кадры frame_XXX.png)")
    ap.add_argument("--from-frames", help="пропустить перенос движения: взять готовые кадры отсюда")
    ap.add_argument("--from-apng", help="взять готовый ролик переноса (анимированный PNG) и разложить его")
    ap.add_argument("--no-polish", action="store_true",
                    help="без полировки: сразу кадры -> игровые спрайты (полировка на этой машине тяжела)")
    ap.add_argument("--wan-variant", default="wa_walk1")
    ap.add_argument("--polish-variant", default="polish_w8")
    ap.add_argument("--ref", default="C:/AI/necro/assets/posegrid/cut_w8/frame_00.png",
                    help="кадр персонажа-эталона (задаёт внешность)")
    ap.add_argument("--cols", type=int, default=4)
    ap.add_argument("--cell", type=int, default=512)
    ap.add_argument("--every", type=int, default=4, help="брать каждый N-й кадр ролика")
    ap.add_argument("--limit", type=int, default=8, help="сколько кадров в клипе")
    ap.add_argument("--game-px", type=int, default=110, help="игровой размер персонажа")
    ap.add_argument("--fps", type=float, default=12.0)
    ap.add_argument("--loop", action="store_true", help="клип циклический (ходьба, покой)")
    a = ap.parse_args()

    if a.from_apng:
        from PIL import Image, ImageSequence
        frames_dir = pathlib.Path(rf"C:/AI/necro/assets/wan_out/{a.clip}")
        frames_dir.mkdir(parents=True, exist_ok=True)
        for f in frames_dir.glob("frame_*.png"):
            f.unlink()
        n = 0
        for i, fr in enumerate(ImageSequence.Iterator(Image.open(a.from_apng))):
            fr.convert("RGB").save(frames_dir / f"frame_{i:03d}.png")
            n = i + 1
        print(f"ролик разложен: {n} кадров -> {frames_dir}")
    elif a.from_frames:
        frames_dir = pathlib.Path(a.from_frames)
    elif a.drive:
        frames_dir = stage_transfer(a.clip, pathlib.Path(a.drive), a.wan_variant, pathlib.Path(a.ref))
        # APNG переноса раскладываем на кадры
        from PIL import Image, ImageSequence
        apng = sorted(frames_dir.glob("*.png"))[-1]
        frames_dir = pathlib.Path(rf"C:/AI/necro/assets/wan_out/{a.clip}")
        frames_dir.mkdir(parents=True, exist_ok=True)
        for i, fr in enumerate(ImageSequence.Iterator(Image.open(apng))):
            fr.convert("RGB").save(frames_dir / f"frame_{i:03d}.png")
        print(f"ролик разложен на кадры -> {frames_dir}")
    else:
        raise SystemExit("нужен либо --drive (полный конвейер), либо --from-frames")

    if a.no_polish:
        # без полировки: отбираем нужные фазы и сразу отдаём в постобработку.
        # Первый кадр ролика пропускаем — модель на нём ещё «разгоняется».
        import shutil
        cut = ROOT / "assets/anim-lab/out" / a.clip
        if cut.exists():
            shutil.rmtree(cut)
        cut.mkdir(parents=True)
        src = sorted(pathlib.Path(frames_dir).glob("frame_*.png"))
        keep = src[1::a.every][:a.limit] if a.every > 1 else src[:a.limit]
        for i, f in enumerate(keep):
            shutil.copy(f, cut / f"frame_{i:02d}.png")
        print(f"отобрано фаз: {len(keep)} -> {cut}")
    else:
        cut = stage_polish(a.clip, frames_dir, a.polish_variant, a.cols, a.cell, a.every, a.limit)
    post = [PY, "tools/anim_post.py", str(cut.relative_to(ROOT)),
            "--game-px", str(a.game_px), "--fps", str(a.fps)]
    if a.no_polish:
        post += ["--bg", "128,128,128"]   # кадры переноса приходят на сером фоне ролика
    if a.loop:
        post.append("--loop")
    run(post, "спрайты для игры")
    run([PY, "tools/anim_qa.py", str((cut / "sprites").relative_to(ROOT))]
        + (["--loop"] if a.loop else []), "числовая приёмка клипа")
    print(f"\nГОТОВО: {cut / 'sprites'} + preview_big.gif + preview_game.gif")
    return 0


if __name__ == "__main__":
    sys.exit(main())
