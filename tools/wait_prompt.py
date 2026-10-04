#!/usr/bin/env python3
"""wait_prompt.py — дождаться готовности задания ComfyUI по prompt_id и забрать результат.

Нужен, когда генерация длинная и наблюдатель мог отвалиться: сама задача при этом
продолжает считаться на сервере, и результат надо просто забрать по её идентификатору.

    python tools/wait_prompt.py <prompt_id> <папка_назначения> [таймаут_сек]
"""
import sys, time, json, urllib.request, urllib.parse
from pathlib import Path

SERVER = "http://127.0.0.1:8188"


def api(path: str, timeout: int = 60) -> bytes:
    with urllib.request.urlopen(SERVER + path, timeout=timeout) as r:
        return r.read()


def main() -> int:
    pid, outdir = sys.argv[1], Path(sys.argv[2])
    limit = int(sys.argv[3]) if len(sys.argv) > 3 else 5400
    t0 = time.time()
    while time.time() - t0 < limit:
        # сервер под нагрузкой отвечает не всегда: обрыв опроса — не повод бросать
        # задание, которое продолжает считаться на сервере
        try:
            hist = json.loads(api(f"/history/{pid}", timeout=30))
        except Exception as e:
            print(f"  опрос не удался ({type(e).__name__}), повтор через 15 c", flush=True)
            time.sleep(15)
            continue
        if pid in hist:
            h = hist[pid]
            st = h.get("status", {})
            if st.get("completed"):
                outdir.mkdir(parents=True, exist_ok=True)
                n = 0
                for node in h.get("outputs", {}).values():
                    for kind in ("images", "gifs", "videos"):
                        for f in node.get(kind, []):
                            q = urllib.parse.urlencode({"filename": f["filename"],
                                                        "subfolder": f.get("subfolder", ""),
                                                        "type": f.get("type", "output")})
                            data = api(f"/view?{q}", timeout=600)
                            (outdir / f["filename"]).write_bytes(data)
                            print(f"saved: {outdir / f['filename']} ({len(data)} bytes)")
                            n += 1
                print(f"готово за {int(time.time()-t0)}s, файлов: {n}")
                return 0
            if st.get("status_str") == "error":
                print("ERROR:", json.dumps(st.get("messages", []), ensure_ascii=False)[:3000])
                return 1
        time.sleep(5)
    print("не дождались")
    return 2


if __name__ == "__main__":
    sys.exit(main())
