#!/usr/bin/env python3
"""Проверить парные логи canonical/candidate и записать строгий manifest серии."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any


RESULT_PREFIX = '{"result":'
NON_CLEANUP_ERROR = re.compile(r"^(?:ERROR:|SCRIPT ERROR:|Parse Error:|WARNING:.*SCRIPT ERROR)")
CLEANUP_RID_LEAK = re.compile(
    r"^ERROR: \d+ RID allocations of type '[^']+' were leaked at exit\.$"
)


def reject_constant(value: str) -> None:
    raise ValueError(f"non-finite JSON number {value}")


def read_run(path: Path, side: str, map_id: str, policy: str, profile: str, seed: int) -> dict[str, Any]:
    if not path.is_file():
        raise ValueError(f"missing log: {path}")
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    errors = [
        line for line in lines
        if NON_CLEANUP_ERROR.match(line) and not CLEANUP_RID_LEAK.match(line)
    ]
    if errors:
        raise ValueError(f"engine errors in {path}: {errors[:3]}")
    result_lines = [line for line in lines if line.startswith(RESULT_PREFIX)]
    if len(result_lines) != 1:
        raise ValueError(f"expected one result line in {path}, found {len(result_lines)}")
    try:
        row = json.loads(result_lines[0], parse_constant=reject_constant)
    except (ValueError, json.JSONDecodeError) as exc:
        raise ValueError(f"invalid result JSON in {path}: {exc}") from exc
    expected = {
        "side": side,
        "actual_map": map_id,
        "candidate_profile": profile,
        "candidate_seed": seed,
        "seed": seed,
        "bot": policy,
    }
    for key, value in expected.items():
        if row.get(key) != value:
            raise ValueError(f"{path}: {key}={row.get(key)!r}, expected {value!r}")
    if row.get("result") not in {"victory", "defeat"}:
        raise ValueError(f"{path}: invalid result {row.get('result')!r}")
    if side == "canonical":
        if row.get("candidate_status") != "canonical" or row.get("candidate_digest") != "":
            raise ValueError(f"{path}: canonical metadata mismatch")
    else:
        if row.get("candidate_status") != "candidate_requires_visual_and_gameplay_review":
            raise ValueError(f"{path}: candidate status is not reviewable")
        if not row.get("candidate_digest") or int(row.get("candidate_manifest_seed", -1)) < 0:
            raise ValueError(f"{path}: missing candidate digest / generation seed metadata")
    return row


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--map", required=True)
    parser.add_argument("--policy", required=True)
    parser.add_argument("--profile", required=True)
    parser.add_argument("--seeds", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--head-before", required=True)
    parser.add_argument("--head-after", required=True)
    parser.add_argument("--candidate-sha-before", required=True)
    parser.add_argument("--candidate-sha-after", required=True)
    args = parser.parse_args()
    seeds = [int(value) for value in args.seeds.split(",") if value]
    if not seeds or len(seeds) != len(set(seeds)):
        print("REJECT: seed list is empty or contains duplicates", file=sys.stderr)
        return 2
    results: list[dict[str, Any]] = []
    failures: list[str] = []
    for side in ("canonical", "candidate"):
        for seed in seeds:
            path = args.out / f"{args.tag}_{args.policy}_{args.profile}_{side}_s{seed}.log"
            try:
                results.append(read_run(path, side, args.map, args.policy, args.profile, seed))
            except (OSError, ValueError) as exc:
                failures.append(str(exc))
    expected_files = {
        f"{args.tag}_{args.policy}_{args.profile}_{side}_s{seed}.log"
        for side in ("canonical", "candidate") for seed in seeds
    }
    actual_files = {
        p.name for p in args.out.glob(f"{args.tag}_{args.policy}_{args.profile}_*_s*.log")
    }
    extras = sorted(actual_files - expected_files)
    if extras:
        failures.append(f"unexpected/duplicate run logs: {extras}")
    if len(results) != 2 * len(seeds):
        failures.append(f"accepted {len(results)} of {2 * len(seeds)} expected runs")
    if args.head_before != args.head_after:
        failures.append("Git HEAD changed during paired series")
    if args.candidate_sha_before != args.candidate_sha_after:
        failures.append("candidate JSON bundle changed during paired series")
    manifest = {
        "map": args.map,
        "policy": args.policy,
        "profile": args.profile,
        "seeds": seeds,
        "frozen_git_head": args.head_before,
        "git_head_after": args.head_after,
        "candidate_bundle_sha256": args.candidate_sha_before,
        "candidate_bundle_sha256_after": args.candidate_sha_after,
        "sides": ["canonical", "candidate"],
        "wins": {
            side: sum(1 for row in results if row.get("side") == side and row.get("result") == "victory")
            for side in ("canonical", "candidate")
        },
        "runs": results,
        "rejected": failures,
    }
    args.out.mkdir(parents=True, exist_ok=True)
    (args.out / "strict_manifest.json").write_text(json.dumps(manifest, indent=2, allow_nan=False),
                                                   encoding="utf-8")
    if failures:
        for failure in failures:
            print(f"REJECT: {failure}", file=sys.stderr)
        return 1
    print(json.dumps({"map": args.map, "profile": args.profile, "seeds": seeds,
                      "wins": manifest["wins"], "runs": len(results)}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
