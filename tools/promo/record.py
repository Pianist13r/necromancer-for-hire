#!/usr/bin/env python3
"""Запись промо движком: режиссёрский сценарий → AVI Movie Maker → мастера, кадры, листы.

Зачем: ролики и кадры для Steam — настоящий бой игры (симуляция, настоящий ввод), а не генерация
и не ручная OBS-запись. Сценарий — tools/promo/scenarios/*.json (формат — шапка
godot/scripts/dev/legion_director.gd). Аудит: docs/dev/audit-1008/recording.md (REC-01…REC-11).

    python tools/promo/record.py tools/promo/scenarios/a_wasteland_defense.json
    python tools/promo/record.py SCN.json --variant clean      # без HUD и курсора (кадры Steam)
    python tools/promo/record.py SCN.json --preview            # без записи: только кадры director
    python tools/promo/record.py SCN.json --skip-record        # перекодировать уже записанное

Что делает:
  1. Песочница: свой APPDATA (по умолчанию <batch>/appdata), в нём user://movie_override.cfg
     с размером кадра 1920×1080 и качеством MJPEG (override.cfg проекта читает этот файл; у
     владельца и в гейте файла нет). Сохранения и настройки владельца не трогаются; запуск
     отказывается, если APPDATA совпал с настоящим.
  2. Движок: --write-movie <batch>/raw/<имя>.avi --fixed-fps 60, окно за экраном (--offscreen:
     как --mute, но звук пишется в файл, на колонки не идёт), NECRO_NO_DEV_BRIDGE=1, PID — в лог.
  3. ffmpeg: мастер H.264 CRF 16 yuv420p BT.709 (полный диапазон MJPEG → ТВ-диапазон, без
     цветокоррекции: LUT записи OBS здесь не нужен) + AAC 320k после двух проходов loudnorm
     (-14 LUFS, пик не выше -2 dBTP; в записи director опускает Master на 6 dB против клиппинга); 30 fps.
  4. Кадры PNG по таймкодам сценария ("stills") из AVI, кадры без потерь из шагов "shot" director
     (окно 1920×1080 → PNG), листы: раскадровка мастера и лист кадров.
  5. Звук: volumedetect/ebur128 сырья и мастера, пики по секундам — в отчёт <batch>/logs/<имя>.audio.txt.

Выход: <batch>/{raw,master,stills,sheets,logs}/. Требует Python 3.10+, ffmpeg из imageio_ffmpeg.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
GODOT_DIR = REPO / "godot"
DEFAULT_GODOT = "C:/Projects/SharedTools/godot/Godot_v4.7.2-stable_win64_console.exe"
DEFAULT_BATCH = "C:/AI/necro/batches/promo-1008"
FPS = 60
W, H = 1920, 1080
MJPEG_QUALITY = 0.95
# Звук: микс игры в залпах упирался в 0 dBFS и срезался (проба 08.10: 266 сэмплов на 0 dB,
# flat factor 13 — настоящий клиппинг, лимитером после него не вылечить). Поэтому director в
# записи опускает шину Master на headroom_db (6 dB), а здесь громкость выравнивается двумя
# проходами loudnorm (линейно, баланс SFX/музыки игры не меняется) к -14 LUFS. Цель пика -2.0 dBTP в готовом AAC: loudnorm целим в -2.5 (кодек AAC добавляет
# 0,1–0,2 dB, verifier 08.10 видел -1.3…-1.45 при цели -1.5); audio_report проверяет итог.
LOUD_I, LOUD_TP, LOUD_LRA = -14.0, -2.5, 11.0
TP_LIMIT = -2.0


def ffmpeg_exe() -> str:
    try:
        import imageio_ffmpeg  # type: ignore

        return imageio_ffmpeg.get_ffmpeg_exe()
    except ImportError:
        # без imageio_ffmpeg — бинарь из site-packages текущего интерпретатора (без путей машины)
        return str(Path(sys.prefix) / "Lib" / "site-packages" / "imageio_ffmpeg" / "binaries"
                   / "ffmpeg-win-x86_64-v7.1.exe")


def user_dir_name() -> str:
    text = (GODOT_DIR / "project.godot").read_text(encoding="utf-8")
    m = re.search(r'^config/custom_user_dir_name="([^"]+)"', text, re.M)
    if not m:
        sys.exit("record: в project.godot нет config/custom_user_dir_name")
    return m.group(1)


def prepare_sandbox(appdata: Path) -> Path:
    real = os.environ.get("APPDATA", "")
    if real and Path(real).resolve() == appdata.resolve():
        sys.exit("record: APPDATA песочницы совпал с настоящим — сохранения владельца под угрозой")
    udir = appdata / user_dir_name()
    udir.mkdir(parents=True, exist_ok=True)
    (udir / "movie_override.cfg").write_text(
        "; tools/promo/record.py: размер кадра Movie Maker и качество MJPEG (только песочница записи)\n"
        "[display]\n\n"
        f"window/size/window_width_override={W}\n"
        f"window/size/window_height_override={H}\n\n"
        "[editor]\n\n"
        f"movie_writer/mjpeg_quality={MJPEG_QUALITY}\n"
        f"movie_writer/fps={FPS}\n",
        encoding="utf-8")
    return udir


def run(cmd: list[str], log: Path | None = None, env: dict | None = None, timeout: float = 3600) -> int:
    if log is None:
        return subprocess.run(cmd, env=env, timeout=timeout).returncode
    with open(log, "w", encoding="utf-8", errors="replace") as fh:
        proc = subprocess.Popen(cmd, stdout=fh, stderr=subprocess.STDOUT, env=env)
        print(f"  PID {proc.pid} → {log}")
        try:
            return proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            proc.kill()   # только свой процесс, по объекту Popen
            raise


def ff(*args: str) -> str:
    """ffmpeg с выводом stderr (там же отчёты фильтров)."""
    r = subprocess.run([ffmpeg_exe(), "-hide_banner", *args], capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    if r.returncode != 0:
        print(r.stderr[-3000:])
        sys.exit(f"record: ffmpeg упал: {' '.join(args[:6])}…")
    return r.stderr


def duration(path: Path) -> float:
    err = subprocess.run([ffmpeg_exe(), "-hide_banner", "-i", str(path)], capture_output=True,
                         text=True, encoding="utf-8", errors="replace").stderr
    m = re.search(r"Duration: (\d+):(\d+):([\d.]+)", err)
    return int(m.group(1)) * 3600 + int(m.group(2)) * 60 + float(m.group(3)) if m else 0.0


def record(scn: dict, scn_path: Path, args, batch: Path, name: str) -> Path:
    raw = batch / "raw" / f"{name}.avi"
    shots = batch / "stills" / name
    for d in (raw.parent, shots, batch / "logs"):
        d.mkdir(parents=True, exist_ok=True)
    appdata = Path(args.appdata or batch / "appdata")
    prepare_sandbox(appdata)
    env = dict(os.environ, APPDATA=str(appdata), NECRO_NO_DEV_BRIDGE="1")
    seconds = float(args.seconds or scn.get("seconds", 18))
    frames = int(seconds * FPS) + 3 * FPS   # страховка: сценарий сам кончается шагом end
    cmd = [args.godot, "--path", str(GODOT_DIR)]
    if not args.preview:
        cmd += ["--write-movie", str(raw)]
    cmd += ["--fixed-fps", str(FPS), "--quit-after", str(frames), "res://scenes/legion.tscn", "--",
            "--offscreen", "--map", scn["map"], "--seed", str(scn.get("seed", 1)),
            "--dev", f"director={scn_path.resolve().as_posix()}",
            "--dev", f"director_out={shots.as_posix()}"]
    for k, v in scn.get("dev", {}).items():
        cmd += ["--dev", f"{k}={v}"]
    if args.variant == "clean":
        cmd += ["--dev", "director_hud=off", "--dev", "director_cursor=0"]
    if args.preview:
        cmd += ["--mute"]
    log = batch / "logs" / f"{name}{'.preview' if args.preview else ''}.log"
    print(f"[{name}] движок: {seconds:.0f} с сценария, {'кадры director' if args.preview else raw}")
    t0 = time.time()
    code = run(cmd, log, env, timeout=max(1800.0, seconds * 120))
    text = log.read_text(encoding="utf-8", errors="replace")
    errs = text.count("SCRIPT ERROR")
    print(f"  код {code}, {time.time() - t0:.0f} с, SCRIPT ERROR: {errs}")
    for line in text.splitlines():
        if line.startswith(("DIRECTOR", "EDIT_MARK")):
            print("  " + line)
    if code != 0 or errs:
        sys.exit(f"record: движок упал (код {code}, ошибок {errs}) — {log}")
    return raw


def audio_filter(raw: Path) -> str:
    """Второй проход loudnorm по замеру первого (линейное усиление, если пик позволяет)."""
    first = f"loudnorm=I={LOUD_I}:TP={LOUD_TP}:LRA={LOUD_LRA}:print_format=json"
    err = ff("-i", str(raw), "-af", first, "-vn", "-f", "null", "-")
    m = re.search(r"\{[^{}]*\"input_i\"[^{}]*\}", err)
    if not m:
        sys.exit("record: loudnorm не дал замера")
    meas = json.loads(m.group(0))
    return (f"loudnorm=I={LOUD_I}:TP={LOUD_TP}:LRA={LOUD_LRA}:linear=true"
            f":measured_I={meas['input_i']}:measured_TP={meas['input_tp']}"
            f":measured_LRA={meas['input_lra']}:measured_thresh={meas['input_thresh']}"
            f":offset={meas['target_offset']},aresample=48000")


def encode(raw: Path, batch: Path, name: str) -> list[Path]:
    out = []
    af = audio_filter(raw)
    print(f"  звук: {af.split(',')[0][:120]}…")
    # MJPEG Movie Maker — yuvj420p (полный диапазон, матрица BT.601). Без accurate_rnd swscale
    # темнил кадр на ~2–3 уровня из 255 (сверка с PNG без потерь из шага shot, 08.10).
    color = ["-vf", "scale=in_range=full:out_range=tv:in_color_matrix=bt601:out_color_matrix=bt709"
             ":flags=accurate_rnd+full_chroma_int+bicubic,format=yuv420p",
             "-color_range", "tv", "-colorspace", "bt709", "-color_primaries", "bt709",
             "-color_trc", "bt709",
             "-x264-params", "colorprim=bt709:transfer=bt709:colormatrix=bt709:range=tv"]
    for fps, tag in ((60, "60"), (30, "30")):
        dst = batch / "master" / f"{name}_1080p{tag}.mp4"
        dst.parent.mkdir(parents=True, exist_ok=True)
        vf = list(color)
        if fps != 60:
            vf[1] = f"fps={fps}," + vf[1]
        ff("-y", "-i", str(raw), *vf, "-c:v", "libx264", "-preset", "slow", "-crf", "16",
           "-profile:v", "high", "-movflags", "+faststart",
           "-af", af, "-c:a", "aac", "-b:a", "320k", str(dst))
        print(f"  мастер {dst} ({dst.stat().st_size / 1e6:.1f} МБ, {duration(dst):.2f} с)")
        out.append(dst)
    return out


def stills(raw: Path, scn: dict, batch: Path, name: str) -> list[Path]:
    out = []
    d = batch / "stills" / name
    d.mkdir(parents=True, exist_ok=True)
    for t in scn.get("stills", []):
        dst = d / f"{name}_t{float(t):05.1f}.png"
        # кадр AVI (MJPEG 0.95) → PNG в sRGB полного диапазона, как видит игрок
        ff("-y", "-ss", f"{float(t):.3f}", "-i", str(raw), "-frames:v", "1",
           "-vf", "scale=in_range=full:out_range=full:flags=accurate_rnd+full_chroma_int+bicubic,"
           "format=rgb24", str(dst))
        out.append(dst)
    print(f"  кадров по таймкодам: {len(out)} → {d}")
    return out


def sheets(master: Path, shots_dir: Path, batch: Path, name: str) -> None:
    sd = batch / "sheets"
    sd.mkdir(parents=True, exist_ok=True)
    dur = duration(master)
    n = 16
    ff("-y", "-i", str(master), "-vf",
       f"fps={n / max(dur, 1):.5f},scale=480:-1,tile=4x4:padding=4:color=black", "-frames:v", "1",
       "-q:v", "3", str(sd / f"{name}_storyboard.jpg"))
    pngs = sorted(p for p in shots_dir.glob("*.png"))
    if pngs:
        from PIL import Image  # кадры без потерь из шагов shot + таймкоды

        cell_w = 640
        cols = 3
        cells = [Image.open(p).convert("RGB") for p in pngs]
        cell_h = round(cell_w * cells[0].height / cells[0].width)
        rows = (len(cells) + cols - 1) // cols
        sheet = Image.new("RGB", (cols * cell_w + (cols + 1) * 4, rows * cell_h + (rows + 1) * 4))
        for i, im in enumerate(cells):
            x = 4 + (i % cols) * (cell_w + 4)
            y = 4 + (i // cols) * (cell_h + 4)
            sheet.paste(im.resize((cell_w, cell_h), Image.LANCZOS), (x, y))
        sheet.save(sd / f"{name}_stills.jpg", quality=90)
    print(f"  листы → {sd}")


def audio_report(raw: Path, master: Path, batch: Path, name: str) -> None:
    lines = []
    for label, src in (("сырьё AVI", raw), ("мастер", master)):
        vd = ff("-i", str(src), "-af", "volumedetect", "-vn", "-f", "null", "-")
        eb = ff("-i", str(src), "-af", "ebur128=peak=true", "-vn", "-f", "null", "-")
        mean = re.search(r"mean_volume: ([-\d.]+)", vd)
        peak = re.search(r"max_volume: ([-\d.]+)", vd)
        summary = eb[eb.rfind("Summary:"):]
        integ = re.search(r"I:\s+([-\d.]+) LUFS", summary)
        tp = re.search(r"Peak:\s+([-\d.]+) dBFS", summary)
        h0 = re.search(r"histogram_0db: (\d+)", vd)
        lines.append(f"{label}: mean {mean.group(1) if mean else '?'} dB, max {peak.group(1) if peak else '?'}"
                     f" dB (сэмплов на 0 dB: {h0.group(1) if h0 else 0}),"
                     f" {integ.group(1) if integ else '?'} LUFS, true peak {tp.group(1) if tp else '?'} dBFS")
        if label == "мастер" and tp and float(tp.group(1)) > TP_LIMIT:
            lines.append(f"ВНИМАНИЕ: true peak мастера {tp.group(1)} выше цели {TP_LIMIT} dBTP")
    # где пики: максимум по полусекундам сырья
    st = ff("-i", str(raw), "-af", "asetnsamples=24000,astats=metadata=1:reset=1,"
            "ametadata=print:key=lavfi.astats.Overall.Peak_level", "-vn", "-f", "null", "-")
    peaks = re.findall(r"pts_time:([\d.]+)[\s\S]*?Peak_level=([-\w.]+)", st)
    hot = [(float(t), v) for t, v in peaks if v not in ("-inf",) and float(v) > -1.0]
    lines.append("полсекунды с пиком выше -1 dBFS (сырьё): " +
                 (", ".join(f"{t:.1f} с ({float(v):.1f})" for t, v in hot[:30]) or "нет"))
    rep = batch / "logs" / f"{name}.audio.txt"
    rep.write_text("\n".join(lines) + "\n", encoding="utf-8")
    for line in lines:
        print("  " + line)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("scenario")
    ap.add_argument("--batch", default=DEFAULT_BATCH)
    ap.add_argument("--godot", default=DEFAULT_GODOT)
    ap.add_argument("--appdata", default="")
    ap.add_argument("--seconds", type=float, default=0.0)
    ap.add_argument("--variant", choices=["hud", "clean"], default="hud",
                    help="hud — как в сценарии; clean — без HUD и курсора (кадры Steam)")
    ap.add_argument("--preview", action="store_true", help="без записи, только кадры шагов shot")
    ap.add_argument("--skip-record", action="store_true", help="AVI уже есть — только постобработка")
    args = ap.parse_args()
    scn_path = Path(args.scenario)
    scn = json.loads(scn_path.read_text(encoding="utf-8"))
    batch = Path(args.batch)
    name = scn.get("name", scn_path.stem) + ("_clean" if args.variant == "clean" else "")
    raw = batch / "raw" / f"{name}.avi"
    if not args.skip_record:
        raw = record(scn, scn_path, args, batch, name)
    if args.preview:
        return 0
    if not raw.exists():
        sys.exit(f"record: нет {raw}")
    print(f"  сырьё {raw} ({raw.stat().st_size / 1e6:.0f} МБ, {duration(raw):.2f} с)")
    masters = encode(raw, batch, name)
    stills(raw, scn, batch, name)
    sheets(masters[0], batch / "stills" / name, batch, name)
    audio_report(raw, masters[0], batch, name)
    return 0


if __name__ == "__main__":
    sys.exit(main())
