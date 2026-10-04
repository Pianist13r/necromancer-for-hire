"""Run the requested polish gates without touching other Godot processes."""
import concurrent.futures
import json
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
GODOT = "C:/Projects/SharedTools/godot/Godot_v4.7.2-stable_win64_console.exe"
OUT = pathlib.Path(sys.argv[1])
OUT.mkdir(parents=True, exist_ok=True)


def run(name, args):
    result = subprocess.run([GODOT, "--headless", "--path", str(ROOT / "godot"),
                             *args, "--", "--mute"], capture_output=True, text=True,
                            encoding="utf-8", errors="replace", timeout=240)
    output = result.stdout + result.stderr
    (OUT / (name + ".log")).write_text(output, encoding="utf-8")
    return {"name": name, "exit": result.returncode,
            "script_errors": output.count("SCRIPT ERROR"), "errors": output.count("ERROR:")}


scripts = sorted((ROOT / "godot").rglob("*.gd"))
with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
    checks = list(pool.map(lambda p: run("check_" + str(p.relative_to(ROOT / "godot")).replace("\\", "_").replace("/", "_"),
                                       ["--check-only", "--script", "res://" + p.relative_to(ROOT / "godot").as_posix()]), scripts))
print("CHECK-ONLY", len(checks), "failures", [c for c in checks if c["exit"] or c["errors"]], flush=True)
tests = []
for name in ("f0_api_test", "p5_selftest", "review_fixes_test", "walk_transition_test"):
    r = run(name, ["--fixed-fps", "60", "--script", f"res://tests/{name}.gd"])
    tests.append(r)
    print(r, flush=True)
(OUT / "checks.json").write_text(json.dumps({"check_only": checks, "tests": tests}, indent=2), encoding="utf-8")
