#!/usr/bin/env python3
"""anim_lab_comfy.py — прогон анимационных экспериментов через локальный ComfyUI.

Сессия анимационного матч-апа (см. ANIMATION_SESSION_PROMPT.md).
Всё, что определяет результат (промпты, сиды, размеры, fps), приходит из
assets/anim-lab/anim_config.json — чтобы каждый принятый кадр был воспроизводим.

Использование:
  python tools/anim_lab_comfy.py upload <картинка>
  python tools/anim_lab_comfy.py wan-walk [--variant ID]   # Wan 2.2 TI2V: мастер -> видео ходьбы
  python tools/anim_lab_comfy.py qwen-cn --pose <png> [--seed N]  # Qwen + ControlNet pose (позже)

Сервер: http://127.0.0.1:8188 (поднимается отдельно, см. docs/ANIM_PIPELINE.md).
Результаты складываются в assets/anim-lab/out/<вариант>/.
"""
import argparse
import json
import sys
import time
import urllib.request
import urllib.parse
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LAB = ROOT / "assets" / "anim-lab"
CONFIG = LAB / "anim_config.json"
SERVER = "http://127.0.0.1:8188"


def load_cfg() -> dict:
    return json.loads(CONFIG.read_text(encoding="utf-8"))


def api(path: str, data: bytes = None, headers: dict = None, timeout: int = 60) -> bytes:
    req = urllib.request.Request(SERVER + path, data=data, headers=headers or {})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def upload_image(path: Path) -> str:
    """Загружает картинку в ComfyUI input/, возвращает имя для LoadImage."""
    boundary = uuid.uuid4().hex
    body = b""
    body += f"--{boundary}\r\n".encode()
    body += f'Content-Disposition: form-data; name="image"; filename="{path.name}"\r\n'.encode()
    body += b"Content-Type: image/png\r\n\r\n"
    body += path.read_bytes() + b"\r\n"
    body += f"--{boundary}\r\nContent-Disposition: form-data; name=\"overwrite\"\r\n\r\ntrue\r\n".encode()
    body += f"--{boundary}--\r\n".encode()
    resp = json.loads(api("/upload/image", body, {"Content-Type": f"multipart/form-data; boundary={boundary}"}))
    print(f"uploaded: {resp['name']}")
    return resp["name"]


def submit(workflow: dict) -> str:
    payload = json.dumps({"prompt": workflow, "client_id": "anim-lab"}).encode()
    resp = json.loads(api("/prompt", payload, {"Content-Type": "application/json"}))
    return resp["prompt_id"]


def wait_done(prompt_id: str, timeout_s: int = 1800) -> dict:
    t0 = time.time()
    last = ""
    while time.time() - t0 < timeout_s:
        hist = json.loads(api(f"/history/{prompt_id}"))
        if prompt_id in hist:
            h = hist[prompt_id]
            status = h.get("status", {})
            if status.get("completed"):
                return h
            if status.get("status_str") == "error":
                print("ERROR:", json.dumps(status.get("messages", []), ensure_ascii=False)[:2000])
                sys.exit(1)
        # прогресс из /queue не даёт %, печатаем живость
        el = int(time.time() - t0)
        if el // 30 != last:
            last = el // 30
            print(f"  ...{el}s", flush=True)
        time.sleep(3)
    print("TIMEOUT waiting for prompt")
    sys.exit(2)


def fetch_outputs(hist: dict, outdir: Path) -> list[Path]:
    outdir.mkdir(parents=True, exist_ok=True)
    saved = []
    for node_out in hist.get("outputs", {}).values():
        for kind in ("images", "gifs", "videos"):
            for f in node_out.get(kind, []):
                if f.get("type") == "temp" and kind == "images":
                    continue
                q = urllib.parse.urlencode({"filename": f["filename"], "subfolder": f.get("subfolder", ""), "type": f.get("type", "output")})
                data = api(f"/view?{q}", timeout=300)
                dest = outdir / f["filename"]
                dest.write_bytes(data)
                saved.append(dest)
                print(f"saved: {dest} ({len(data)} bytes)")
    return saved


# ---------------------------------------------------------------- workflows

def wf_wan_i2v(image_name: str, v: dict) -> dict:
    """Официальный шаблон video_wan2_2_5B_ti2v (ComfyUI templates 0.11.19), API-форма."""
    return {
        "37": {"class_type": "UNETLoader", "inputs": {"unet_name": "wan2.2_ti2v_5B_fp16.safetensors", "weight_dtype": "default"}},
        "38": {"class_type": "CLIPLoader", "inputs": {"clip_name": "umt5_xxl_fp8_e4m3fn_scaled.safetensors", "type": "wan", "device": "default"}},
        "39": {"class_type": "VAELoader", "inputs": {"vae_name": "wan2.2_vae.safetensors"}},
        "56": {"class_type": "LoadImage", "inputs": {"image": image_name}},
        "55": {"class_type": "Wan22ImageToVideoLatent", "inputs": {
            "vae": ["39", 0], "start_image": ["56", 0],
            "width": v["width"], "height": v["height"], "length": v["length"], "batch_size": 1}},
        "6": {"class_type": "CLIPTextEncode", "inputs": {"clip": ["38", 0], "text": v["prompt"]}},
        "7": {"class_type": "CLIPTextEncode", "inputs": {"clip": ["38", 0], "text": v["negative"]}},
        "48": {"class_type": "ModelSamplingSD3", "inputs": {"model": ["37", 0], "shift": v.get("shift", 8.0)}},
        "3": {"class_type": "KSampler", "inputs": {
            "model": ["48", 0], "positive": ["6", 0], "negative": ["7", 0], "latent_image": ["55", 0],
            "seed": v["seed"], "control_after_generate": "fixed",
            "steps": v["steps"], "cfg": v["cfg"], "sampler_name": "uni_pc", "scheduler": "simple", "denoise": 1.0}},
        "8": {"class_type": "VAEDecode", "inputs": {"samples": ["3", 0], "vae": ["39", 0]}},
        "57": {"class_type": "SaveAnimatedWEBP", "inputs": {
            "images": ["8", 0], "filename_prefix": f"animlab/{v['id']}",
            "fps": v["fps"], "lossless": False, "quality": 92, "method": "default"}},
    }


def wf_qwen_cn(pose_name: str, v: dict) -> dict:
    """Qwen-Image 2512 + Lightning LoRA + ControlNet-Union (openpose).

    Режим t2i: чистая генерация по промпту под контролем позы.
    Режим i2i: если в варианте задан ref_image — VAEEncode мастера + denoise,
    идентичность персонажа держится исходником, поза — ControlNet.

    Режим сетки: если заданы width/height, холст прямоугольный — тогда на входе не
    одна поза, а СЕТКА поз (tools/pose_grid.py), и вся анимация рисуется одной
    генерацией. Смысл: стиль и персонаж держатся тем, что кадры родились вместе,
    а фазы — тем, что поза каждой ячейки задана ригом (см. docs/ANIM_PIPELINE.md).
    """
    size = v.get("size", 1024)
    width = v.get("width", size)
    height = v.get("height", size)
    model_src = ["10", 0]
    wf = {
        "10": {"class_type": "UNETLoader", "inputs": {"unet_name": "qwen_image_2512_fp8_e4m3fn.safetensors", "weight_dtype": "default"}},
        "11": {"class_type": "CLIPLoader", "inputs": {"clip_name": "qwen_2.5_vl_7b_fp8_scaled.safetensors", "type": "qwen_image", "device": "default"}},
        "12": {"class_type": "VAELoader", "inputs": {"vae_name": "qwen_image_vae.safetensors"}},
        "20": {"class_type": "ControlNetLoader", "inputs": {"control_net_name": "qwen_image_controlnet_union.safetensors"}},
        "21": {"class_type": "SetUnionControlNetType", "inputs": {"control_net": ["20", 0], "type": "openpose"}},
        "22": {"class_type": "LoadImage", "inputs": {"image": pose_name}},
        "23": {"class_type": "ImageScale", "inputs": {"image": ["22", 0], "upscale_method": "lanczos", "width": width, "height": height, "crop": "disabled"}},
        "6": {"class_type": "CLIPTextEncode", "inputs": {"clip": ["11", 0], "text": v["prompt"]}},
        "7": {"class_type": "CLIPTextEncode", "inputs": {"clip": ["11", 0], "text": v.get("negative", "")}},
        "24": {"class_type": "ControlNetApplyAdvanced", "inputs": {
            "positive": ["6", 0], "negative": ["7", 0], "control_net": ["21", 0], "image": ["23", 0],
            "strength": v.get("cn_strength", 1.0), "start_percent": 0.0, "end_percent": 1.0, "vae": ["12", 0]}},
        "8": {"class_type": "VAEDecode", "inputs": {"samples": ["3", 0], "vae": ["12", 0]}},
        "9": {"class_type": "SaveImage", "inputs": {"images": ["8", 0], "filename_prefix": f"animlab/{v['id']}"}},
    }
    if v.get("lora", True):
        wf["13"] = {"class_type": "LoraLoaderModelOnly", "inputs": {
            "model": ["10", 0], "lora_name": "Qwen-Image-2512-Lightning-4steps-V1.0-fp32.safetensors", "strength_model": 1.0}}
        model_src = ["13", 0]
    if v.get("ref_image"):
        wf["30"] = {"class_type": "LoadImage", "inputs": {"image": v["_ref_name"]}}
        wf["31"] = {"class_type": "ImageScale", "inputs": {"image": ["30", 0], "upscale_method": "lanczos", "width": width, "height": height, "crop": "disabled"}}
        wf["32"] = {"class_type": "VAEEncode", "inputs": {"pixels": ["31", 0], "vae": ["12", 0]}}
        latent = ["32", 0]
        denoise = v.get("denoise", 0.75)
    else:
        wf["32"] = {"class_type": "EmptyLatentImage", "inputs": {"width": width, "height": height, "batch_size": 1}}
        latent = ["32", 0]
        denoise = 1.0
    # cn_strength = 0 -> ControlNet выключен совсем: режим «полировки», когда позы уже
    # содержатся в исходной картинке (кадры переноса движения), и от генерации нужна
    # только чистая рисовка. Тогда кондиционинг идёт мимо ControlNetApplyAdvanced.
    if v.get("cn_strength", 1.0) <= 0.0:
        wf.pop("20", None)
        wf.pop("21", None)
        wf.pop("22", None)
        wf.pop("23", None)
        wf.pop("24", None)
        pos_src, neg_src = ["6", 0], ["7", 0]
    else:
        pos_src, neg_src = ["24", 0], ["24", 1]

    wf["3"] = {"class_type": "KSampler", "inputs": {
        "model": model_src, "positive": pos_src, "negative": neg_src, "latent_image": latent,
        "seed": v["seed"], "control_after_generate": "fixed",
        "steps": v["steps"], "cfg": v["cfg"], "sampler_name": v.get("sampler", "euler"),
        "scheduler": v.get("scheduler", "simple"), "denoise": denoise}}
    return wf


def wf_wan_animate2(ref_name: str, v: dict) -> dict:
    """ТРЕК B: Wan-Animate-2 — перенос движения с управляющего ролика на нашего персонажа.

    Идея конвейера: движение берём НЕ у генеративной модели (она им не управляет), а у
    собственного меш-рига — он даёт механически корректные фазы (дрейф опорной стопы
    0.00 px/кадр). Риг рендерит управляющий ролик (walk_proto.gd --drive), модель одевает
    это движение в нашего персонажа и держит его идентичность по референс-кадру.

    Модель — дистиллят int8 (Apache-2.0, Comfy-Org/Wan-Animate-2): мало шагов, cfg 1.0.
    length обязан быть вида 4k+1 (временная компрессия VAE 4x), width/height кратны 16.
    """
    frames = v["drive_frames"]
    chain: dict = {}
    prev = None
    for i, name in enumerate(frames):
        nid = f"1{i:03d}"
        chain[nid] = {"class_type": "LoadImage", "inputs": {"image": name}}
        if prev is None:
            prev = [nid, 0]
        else:
            bid = f"2{i:03d}"
            chain[bid] = {"class_type": "ImageBatch", "inputs": {"image1": prev, "image2": [nid, 0]}}
            prev = [bid, 0]

    wf = {
        "10": {"class_type": "UNETLoader", "inputs": {
            "unet_name": "wan_animate_2_distill_int8_convrot.safetensors", "weight_dtype": "default"}},
        "11": {"class_type": "CLIPLoader", "inputs": {
            "clip_name": "umt5_xxl_fp8_e4m3fn_scaled.safetensors", "type": "wan", "device": "default"}},
        "12": {"class_type": "VAELoader", "inputs": {"vae_name": "Wan2_1_VAE_bf16.safetensors"}},
        "13": {"class_type": "CLIPVisionLoader", "inputs": {"clip_name": "clip_vision_h.safetensors"}},
        "20": {"class_type": "LoadImage", "inputs": {"image": ref_name}},
        "21": {"class_type": "CLIPVisionEncode", "inputs": {
            "clip_vision": ["13", 0], "image": ["20", 0], "crop": "none"}},
        # кадры управляющего ролика — ОДНИМ батчем.
        # LoadImageDataSetFromFolder тут не годится: он отдаёт СПИСОК, а ComfyUI на списке
        # прогоняет весь граф по разу на каждый кадр (замер: 33 прогона по 4 минуты вместо
        # одного). Поэтому кадры грузятся по одному и склеиваются цепочкой ImageBatch.
        "6": {"class_type": "CLIPTextEncode", "inputs": {"clip": ["11", 0], "text": v["prompt"]}},
        "7": {"class_type": "CLIPTextEncode", "inputs": {"clip": ["11", 0], "text": v.get("negative", "")}},
        "30": {"class_type": "WanAnimate2ToVideo", "inputs": {
            "positive": ["6", 0], "negative": ["7", 0], "vae": ["12", 0],
            "width": v["width"], "height": v["height"], "length": v["length"], "batch_size": 1,
            "reference_image": ["20", 0], "pose_video": prev, "clip_vision_output": ["21", 0],
            "pose_strength": v.get("pose_strength", 1.0),
            "pose_start_percent": 0.0, "pose_end_percent": v.get("pose_end_percent", 1.0),
            "reference_image_strength": v.get("ref_strength", 1.0),
            "video_frame_offset": 0}},
        "3": {"class_type": "KSampler", "inputs": {
            "model": ["10", 0], "positive": ["30", 0], "negative": ["30", 1], "latent_image": ["30", 2],
            "seed": v["seed"], "control_after_generate": "fixed",
            "steps": v.get("steps", 10), "cfg": v.get("cfg", 1.0),
            "sampler_name": v.get("sampler", "euler"), "scheduler": v.get("scheduler", "simple"),
            "denoise": 1.0}},
        "8": {"class_type": "VAEDecode", "inputs": {"samples": ["3", 0], "vae": ["12", 0]}},
        "9": {"class_type": "SaveAnimatedPNG", "inputs": {
            "images": ["8", 0], "filename_prefix": f"animlab/{v['id']}", "fps": v.get("fps", 16),
            "compress_level": 4}},
    }
    wf.update(chain)
    return wf


def resolve_prompt(sec: dict, key: str) -> str:
    if key == "CHARACTER":
        return sec["character_prompt"].replace("{ACTION}", "standing, side view facing right")
    if key == "CHARACTER_WALKING":
        return sec["character_prompt"].replace(
            "{ACTION}", "walking to the right, captured mid-stride with legs stepping apart, side view")
    if key.startswith("ACTION:"):
        return sec["character_prompt"].replace("{ACTION}", key[7:])
    return key


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["upload", "wan-walk", "qwen-cn", "qwen-cn-batch", "wan-animate"])
    ap.add_argument("args", nargs="*")
    ap.add_argument("--variant", default=None)
    a = ap.parse_args()

    if a.cmd == "upload":
        upload_image(Path(a.args[0]))
        return

    cfg = load_cfg()
    if a.cmd == "wan-walk":
        variants = {v["id"]: v for v in cfg["wan_walk"]["variants"]}
        vid = a.variant or cfg["wan_walk"]["active"]
        v = variants[vid]
        print(f"variant {vid}: seed={v['seed']} {v['width']}x{v['height']} len={v['length']} steps={v['steps']}")
        img = upload_image((ROOT / v["image"]).resolve())
        wf = wf_wan_i2v(img, v)
        t0 = time.time()
        pid = submit(wf)
        print(f"prompt_id={pid}")
        h = wait_done(pid)
        print(f"done in {int(time.time()-t0)}s")
        fetch_outputs(h, LAB / "out" / vid)
    elif a.cmd == "qwen-cn":
        variants = {v["id"]: v for v in cfg["qwen_cn"]["variants"]}
        vid = a.variant or cfg["qwen_cn"]["active"]
        v = dict(variants[vid])
        v["prompt"] = resolve_prompt(cfg["qwen_cn"], v.get("prompt", "CHARACTER"))
        v.setdefault("negative", cfg["qwen_cn"].get("negative", ""))
        canvas = f"{v['width']}x{v['height']}" if v.get("width") else f"{v.get('size', 1024)}²"
        print(f"variant {vid}: seed={v['seed']} canvas={canvas} steps={v['steps']} cfg={v['cfg']} cn={v.get('cn_strength', 1.0)}")
        pose = upload_image((ROOT / v["pose"]).resolve()) if v.get("pose") else ""
        if v.get("ref_image"):
            v["_ref_name"] = upload_image((ROOT / v["ref_image"]).resolve())
        wf = wf_qwen_cn(pose, v)
        t0 = time.time()
        pid = submit(wf)
        print(f"prompt_id={pid}")
        h = wait_done(pid)
        print(f"done in {int(time.time()-t0)}s")
        fetch_outputs(h, LAB / "out" / vid)
    elif a.cmd == "wan-animate":
        variants = {v["id"]: v for v in cfg["wan_animate"]["variants"]}
        vid = a.variant or cfg["wan_animate"]["active"]
        v = dict(variants[vid])
        print(f"variant {vid}: {v['width']}x{v['height']} length={v['length']} steps={v.get('steps', 10)} "
              f"pose_strength={v.get('pose_strength', 1.0)} ref_strength={v.get('ref_strength', 1.0)}")
        ref = upload_image((ROOT / v["ref_image"]).resolve()) if "/" in v["ref_image"] else v["ref_image"]
        wf = wf_wan_animate2(ref, v)
        t0 = time.time()
        pid = submit(wf)
        print(f"prompt_id={pid}")
        h = wait_done(pid, timeout_s=3600)
        print(f"done in {int(time.time()-t0)}s")
        fetch_outputs(h, LAB / "out" / vid)
    elif a.cmd == "qwen-cn-batch":
        # пакетная генерация клипа: одна запись с "poses": [...] — кадр на позу.
        # Все промпты ставятся в очередь разом; результаты раскладываются по frame_XX.png.
        batches = {b["id"]: b for b in cfg["qwen_cn"]["batches"]}
        bid = a.variant or cfg["qwen_cn"]["active_batch"]
        b = dict(batches[bid])
        prompt = resolve_prompt(cfg["qwen_cn"], b.get("prompt", "CHARACTER"))
        v = {**b, "prompt": prompt, "negative": cfg["qwen_cn"].get("negative", "")}
        outdir = LAB / "out" / bid
        outdir.mkdir(parents=True, exist_ok=True)
        state_f = outdir / "batch_state.json"
        state = json.loads(state_f.read_text()) if state_f.exists() else {}
        # state: {"frame_00": {"pid": "...", "pose": "..."}}
        t0 = time.time()
        actions = b.get("actions", [])
        for idx, pose_path in enumerate(b["poses"]):
            name = f"frame_{idx:02d}"
            if (outdir / f"{name}.png").exists():
                continue
            if name not in state:
                pose = upload_image((ROOT / pose_path).resolve())
                vv = dict(v)
                if idx < len(actions):
                    vv["prompt"] = resolve_prompt(cfg["qwen_cn"], actions[idx])
                vv["id"] = f"{bid}_tmp"
                wf = wf_qwen_cn(pose, vv)
                pid = submit(wf)
                state[name] = {"pid": pid, "pose": pose_path}
                state_f.write_text(json.dumps(state, indent=1))
                print(f"queued {name}: {Path(pose_path).name} -> {pid[:8]}")
        for name in sorted(state):
            if (outdir / f"{name}.png").exists():
                continue
            pid = state[name]["pid"]
            hist = json.loads(api(f"/history/{pid}"))
            if pid not in hist:
                print(f"{name}: ещё в очереди/работает, дождусь следующего запуска")
                continue
            h = hist[pid]
            st = h.get("status", {})
            if st.get("status_str") == "error":
                print(f"{name}: ERROR {json.dumps(st.get('messages', []), ensure_ascii=False)[:400]}")
                continue
            saved = fetch_outputs(h, outdir)
            for s in saved:
                target = outdir / f"{name}.png"
                if s.name != target.name:
                    s.replace(target)
                print(f"{name}: ok ({int(time.time()-t0)}s total)")


if __name__ == "__main__":
    main()
