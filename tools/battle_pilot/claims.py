"""Opt-in structured claims against an externally accepted observation report.

This does not establish report provenance, validate free prose, or change batch acceptance.
The caller must obtain the accepted report SHA independently of the claim sidecar.
"""
from __future__ import annotations

import argparse
from decimal import Decimal, InvalidOperation
import hashlib
import json
import math
from pathlib import Path
import re

MAX_REPORT_BYTES = 512_000
MAX_CLAIM_BYTES = 64_000
MAX_CLAIMS = 64
HEX = re.compile(r"[a-f0-9]{64}")
COHORTS = {"observed_before_proposal", "observed_after_replay"}
OUTCOMES = {"both_win", "control_only", "candidate_only", "both_lose"}


def require(ok, reason):
    if not ok:
        raise ValueError(reason)


def keys(value, names, label):
    require(type(value) is dict and set(value) == set(names.split()), label + " exact keys")


def integer(value, low, high, label):
    require(type(value) is int and low <= value <= high, label + " integer range")


def finite(value):
    if type(value) is Decimal:
        return value.is_finite()
    if type(value) not in (int, float):
        return False
    try:
        return math.isfinite(value)
    except OverflowError:
        return False


def direction(value):
    return "positive" if value > 0 else "negative" if value < 0 else "zero"


def _pairs(items):
    result = {}
    for name, value in items:
        require(name not in result, "duplicate JSON key")
        result[name] = value
    return result


def _constant(_value):
    raise ValueError("nonfinite JSON number")


def _float(value):
    # Keep the JSON decimal value exact. Converting first would erase extra digits
    # (183.20000000000000000001) or turn a nonzero claim (1e-999) into zero.
    try:
        parsed = Decimal(value)
    except InvalidOperation as error:
        raise ValueError("invalid decimal JSON number") from error
    native = float(parsed)
    require(parsed.is_finite() and math.isfinite(native), "nonfinite JSON number")
    require(parsed == 0 or native != 0, "nonzero JSON number underflow")
    return parsed


def read_json(data, cap):
    require(type(data) is bytes and 0 < len(data) <= cap, "JSON byte cap")
    return json.loads(data.decode("utf-8"), object_pairs_hook=_pairs,
                      parse_constant=_constant, parse_float=_float)


def _cohort(row):
    keys(row, "map difficulty control candidate pairs paired_win_counts control_wins "
         "candidate_wins metric_deltas lost_mean_direction", "observation")
    require(type(row["map"]) is str and type(row["difficulty"]) is str, "cohort map/difficulty")
    for arm in ("control", "candidate"):
        keys(row[arm], "bot profile", "observation arm")
        require(all(type(value) is str for value in row[arm].values()), "cohort arm identity")
    integer(row["pairs"], 1, 10, "cohort pairs")
    counts = row["paired_win_counts"]
    keys(counts, "both_win control_only candidate_only both_lose", "paired outcomes")
    for count in counts.values():
        integer(count, 0, row["pairs"], "paired count")
    require(sum(counts.values()) == row["pairs"], "paired outcomes conservation")
    for arm in ("control", "candidate"):
        integer(row[arm + "_wins"], 0, row["pairs"], "arm wins")
        require(row[arm + "_wins"] == counts["both_win"] + counts[arm + "_only"], "arm wins conservation")
    keys(row["metric_deltas"], "hp lost", "metric inventory")
    for metric in row["metric_deltas"].values():
        if metric is not None:
            keys(metric, "n mean", "delta summary")
            integer(metric["n"], 1, row["pairs"], "metric n")
            require(finite(metric["mean"]), "finite metric mean")
    lost = row["metric_deltas"]["lost"]
    expected = "unavailable" if lost is None else (
        "candidate_lost_more" if lost["mean"] > 0 else
        "candidate_lost_fewer" if lost["mean"] < 0 else "equal_mean_losses")
    require(row["lost_mean_direction"] == expected, "observation lost direction")


def validate(sidecar_bytes, report_bytes, accepted_report_sha256):
    """Compare declared facts to exact SHA-pinned display values; return a data-only receipt.

    The accepted SHA is an external trust input, never inferred from sidecar content.
    No tolerance, sign inference from prose, full-precision metric or causal claim is supported.
    """
    require(type(accepted_report_sha256) is str and HEX.fullmatch(accepted_report_sha256),
            "externally supplied accepted report SHA required")
    require(type(report_bytes) is bytes and 0 < len(report_bytes) <= MAX_REPORT_BYTES, "report byte cap")
    require(hashlib.sha256(report_bytes).hexdigest() == accepted_report_sha256, "accepted report source hash")
    report = read_json(report_bytes, MAX_REPORT_BYTES)
    keys(report, "version delta_direction metric_mean_format observed_before_proposal "
         "observed_after_replay proposal_hypothesis", "report")
    require(type(report["version"]) is int and report["version"] == 1
            and report["delta_direction"] == "candidate minus control"
            and report["metric_mean_format"] == "four significant digits", "supported observation report")
    keys(report["proposal_hypothesis"], "text verification_status selection_source", "hypothesis")
    require(report["proposal_hypothesis"]["verification_status"] == "unverified_free_text"
            and type(report["proposal_hypothesis"]["text"]) is str
            and type(report["proposal_hypothesis"]["selection_source"]) is str,
            "prose remains unverified")
    for name in COHORTS:
        if report[name] is not None:
            _cohort(report[name])
    sidecar = read_json(sidecar_bytes, MAX_CLAIM_BYTES)
    keys(sidecar, "kind report_sha256 claims", "claim sidecar")
    require(sidecar["kind"] == "battle-observation-claims-v1"
            and sidecar["report_sha256"] == accepted_report_sha256, "sidecar source/version binding")
    claims = sidecar["claims"]
    require(type(claims) is list and 1 <= len(claims) <= MAX_CLAIMS, "claim count cap")
    for index, claim in enumerate(claims):
        try:
            _claim(claim, report)
        except ValueError as error:
            raise ValueError(f"claim {index}: {error}") from error
    return {"kind": "battle-observation-claims-validation-v1", "accepted": True,
            "report_sha256": accepted_report_sha256,
            "sidecar_sha256": hashlib.sha256(sidecar_bytes).hexdigest(), "claims_checked": len(claims),
            "scope": "declared facts in the exact accepted display report only",
            "free_text_verification": "unverified_free_text", "causality_validated": False}


def _claim(claim, report):
    keys(claim, "cohort fact", "claim")
    selector = claim["cohort"]
    keys(selector, "observation map difficulty control candidate pairs", "cohort selector")
    require(type(selector["observation"]) is str and selector["observation"] in COHORTS, "named cohort")
    row = report[selector["observation"]]
    require(row is not None, "missing observation cohort")
    integer(selector["pairs"], 1, 10, "selector pairs")
    for arm in ("control", "candidate"):
        keys(selector[arm], "bot profile", "selector arm")
    require({key: selector[key] for key in selector if key != "observation"}
            == {key: row[key] for key in selector if key != "observation"}, "exact cohort/configuration")
    fact = claim["fact"]
    require(type(fact) is dict and type(fact.get("kind")) is str, "fact kind")
    kind = fact["kind"]
    if kind == "arm_outcome":
        keys(fact, "kind arm outcome count denominator", "arm outcome fact")
        require(type(fact["arm"]) is str and fact["arm"] in {"control", "candidate"}
                and type(fact["outcome"]) is str and fact["outcome"] in {"victory", "defeat"}, "arm/outcome")
        count = row[fact["arm"] + "_wins"]
        if fact["outcome"] == "defeat":
            count = row["pairs"] - count
    elif kind == "paired_outcome":
        keys(fact, "kind outcome count denominator", "paired outcome fact")
        require(type(fact["outcome"]) is str and fact["outcome"] in OUTCOMES, "paired outcome")
        count = row["paired_win_counts"][fact["outcome"]]
    elif kind == "metric_delta":
        keys(fact, "kind metric n display_mean direction", "metric fact")
        require(type(fact["metric"]) is str and fact["metric"] in {"hp", "lost"}, "supported metric")
        metric = row["metric_deltas"][fact["metric"]]
        require(metric is not None, "missing metric is not zero")
        integer(fact["n"], 1, row["pairs"], "claim metric n")
        require(fact["n"] == metric["n"] and finite(fact["display_mean"])
                and fact["display_mean"] == metric["mean"], "exact declared four-significant-digit display mean/n")
        require(fact["direction"] == direction(metric["mean"]), "candidate-minus-control direction")
        return
    else:
        raise ValueError("unsupported fact kind")
    integer(fact["count"], 0, row["pairs"], "claim count")
    integer(fact["denominator"], 1, 10, "claim denominator")
    require(fact["count"] == count and fact["denominator"] == row["pairs"], "exact count/denominator")


def _read(path, cap):
    path = Path(path)
    require(path.is_absolute() and path.is_file() and path.resolve() == path, "ordinary absolute input path")
    require(0 < path.stat().st_size <= cap, "input file cap")
    return path.read_bytes()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sidecar", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--accepted-report-sha256", required=True)
    args = parser.parse_args()
    try:
        result = validate(_read(args.sidecar, MAX_CLAIM_BYTES), _read(args.report, MAX_REPORT_BYTES),
                          args.accepted_report_sha256)
    except (ValueError, OSError, RecursionError) as error:
        print(json.dumps({"accepted": False, "error": str(error)}))
        return 1
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
