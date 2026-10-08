"""Only tutorial-related checks; intentionally does not run the full Legion gate."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "batches/tutorial-1008/checks"
GODOT = "C:/Projects/SharedTools/godot/Godot_v4.7.2-stable_win64_console.exe"
TESTS = ["legion_tutorial_1008_test", "legion_tutorial_test", "legion_lessons_test",
         "legion_keys_text_test", "legion_voice_test", "legion_voice_events_test",
         "legion_play_metrics_test", "legion_cutscene_flow_test"]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("tests", nargs="*")
    parser.add_argument("--skip-import", action="store_true")
    args = parser.parse_args()
    allowed = [*TESTS, "legion_intuit_test", "legion_teach_test", "legion_small_1002_test"]
    if any(name not in allowed for name in args.tests):
        parser.error("Only tutorial-related tests are allowed")
    OUT.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, APPDATA=str(OUT / "appdata"), NECRO_NO_DEV_BRIDGE="1")
    results = json.loads((OUT / "results.json").read_text(encoding="utf-8")) if (OUT / "results.json").exists() else []
    names = args.tests or TESTS
    for name in (["import"] if not args.skip_import else []) + names:
        command = [GODOT, "--headless", "--path", "godot"]
        command += ["--import"] if name == "import" else ["--fixed-fps", "60", "--script", f"res://tests/{name}.gd"]
        command += ["--", "--mute"]
        start = time.monotonic()
        log = OUT / (name + ".log")
        with log.open("w", encoding="utf-8") as output:
            result = subprocess.run(command, cwd=ROOT, env=env, stdout=output, stderr=subprocess.STDOUT,
                                    timeout=1200)
        text = log.read_text(encoding="utf-8", errors="replace")
        summary = [line for line in text.splitlines() if " OK" in line][-1:]
        row = dict(name=name, exit_code=result.returncode, seconds=round(time.monotonic()-start, 1),
                   script_errors=text.count("SCRIPT ERROR"), summary=summary)
        results = [r for r in results if r["name"] != name] + [row]
        print(json.dumps(row, ensure_ascii=False), flush=True)
        (OUT / "results.json").write_text(json.dumps(results, ensure_ascii=False, indent=2), encoding="utf-8")
    raise SystemExit(1 if any(r["exit_code"] or r["script_errors"] for r in results) else 0)


if __name__ == "__main__":
    main()
