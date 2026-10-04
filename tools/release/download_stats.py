"""Snapshot public GitHub release download counters; these are NOT unique players.

No token required. Keep the snapshots outside the repository.
python tools/release/download_stats.py --out /path/to/stats.jsonl
"""
import argparse
import datetime as dt
import json
from pathlib import Path
from urllib.request import Request, urlopen


def collect(repo: str) -> dict:
    releases = []
    page = 1
    while True:
        request = Request(
            f"https://api.github.com/repos/{repo}/releases?per_page=100&page={page}",
            headers={"Accept": "application/vnd.github+json", "User-Agent": "Necromancer-release-stats"},
        )
        with urlopen(request, timeout=30) as response:
            batch = json.load(response)
        if not isinstance(batch, list):
            raise ValueError("Unexpected GitHub response")
        releases.extend({
            "tag": release["tag_name"],
            "assets": [{"id": asset["id"], "name": asset["name"],
                        "downloads": asset["download_count"]} for asset in release["assets"]],
        } for release in batch if not release["draft"])
        if len(batch) < 100:
            break
        page += 1
    return {"time_utc": dt.datetime.now(dt.timezone.utc).isoformat(), "repo": repo,
            "metric": "asset_download_requests_not_unique_players", "releases": releases}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    snapshot = collect("Pianist13r/necromancer-for-hire")
    args.out.parent.mkdir(parents=True, exist_ok=True)
    with args.out.open("a", encoding="utf-8") as output:
        output.write(json.dumps(snapshot, ensure_ascii=False) + "\n")
    print(json.dumps(snapshot, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
