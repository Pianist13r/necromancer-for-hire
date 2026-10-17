"""Structured B507 regressions; pure data, no engine, model, network or old raw writes."""
import copy
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import claims
import feedback


def encoded(value):
    return json.dumps(value, ensure_ascii=False).encode("utf-8")


def battle(map_id, wins, lost):
    pairs = [{"control": {"result": "victory"},
              "candidate": {"result": "victory" if i < wins else "defeat"},
              "delta": {"hp": -16.62345, "lost": lost}} for i in range(10)]
    return {"prior_battle": {"pairs": pairs,
            "proposal": {"map": map_id, "difficulty": "normal",
                         "candidate": {"bot": "melt", "profile": "base"},
                         "hypothesis": "10 defeats; low-loss (+183.2) — unverified free prose."},
            "control": {"bot": "selective", "profile": "base"}}}


class ClaimTests(unittest.TestCase):
    def setUp(self):
        self.report = feedback.observation_report(battle("swamp", 10, 183.245),
                                                   battle("archive", 5, -5), "model")
        self.report_bytes = encoded(self.report)
        self.accepted = hashlib.sha256(self.report_bytes).hexdigest()
        self.selector = {key: copy.deepcopy(self.report["observed_before_proposal"][key])
                         for key in ("map", "difficulty", "control", "candidate", "pairs")}
        self.selector["observation"] = "observed_before_proposal"
        self.fact = {"kind": "arm_outcome", "arm": "candidate", "outcome": "victory",
                     "count": 10, "denominator": 10}
        self.sidecar = {"kind": "battle-observation-claims-v1", "report_sha256": self.accepted,
                        "claims": [{"cohort": self.selector, "fact": self.fact}]}

    def check(self, sidecar=None, report=None, accepted=None):
        return claims.validate(encoded(self.sidecar if sidecar is None else sidecar),
                               self.report_bytes if report is None else report,
                               self.accepted if accepted is None else accepted)

    def delta_fact(self):
        return {"kind": "metric_delta", "metric": "lost", "n": 10,
                "display_mean": 183.2, "direction": "positive"}

    def replace_report(self, report):
        self.report_bytes = encoded(report)
        self.accepted = hashlib.sha256(self.report_bytes).hexdigest()
        self.sidecar["report_sha256"] = self.accepted

    def test_valid_facts_do_not_validate_contradictory_prose_or_change_legacy(self):
        before = copy.deepcopy(self.report)
        result = self.check()
        self.assertTrue(result["accepted"])
        self.assertEqual(result["claims_checked"], 1)
        self.assertEqual(result["free_text_verification"], "unverified_free_text")
        self.assertFalse(result["causality_validated"])
        self.assertEqual(self.report, before)
        self.assertEqual(feedback.schema.PROPOSAL_KEYS,
                         {"version", "hypothesis", "map", "difficulty", "candidate"})

    def test_ten_actual_wins_cannot_be_declared_ten_defeats(self):
        self.fact["outcome"] = "defeat"
        with self.assertRaisesRegex(ValueError, "exact count"):
            self.check()
        self.fact["count"] = 0
        self.assertTrue(self.check()["accepted"])

    def test_positive_losses_cannot_be_claimed_negative_or_more_precise(self):
        self.sidecar["claims"][0]["fact"] = self.delta_fact()
        self.assertTrue(self.check()["accepted"])
        for change in ({"direction": "negative"}, {"display_mean": -183.2},
                       {"display_mean": 183.245}, {"display_mean": 183.2000000001}, {"n": 9}):
            value = copy.deepcopy(self.sidecar)
            value["claims"][0]["fact"].update(change)
            with self.subTest(change=change), self.assertRaises(ValueError):
                self.check(value)

    def test_wrong_before_after_map_arm_profile_and_denominator_refuse(self):
        for field, value in (("observation", "observed_after_replay"), ("map", "archive"),
                             ("difficulty", "hell"), ("pairs", 9),
                             ("candidate", {"bot": "hold", "profile": "base"}),
                             ("control", {"bot": "selective", "profile": "novice"})):
            invalid = copy.deepcopy(self.sidecar)
            invalid["claims"][0]["cohort"][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.check(invalid)
        self.fact["denominator"] = 9
        with self.assertRaisesRegex(ValueError, "denominator"):
            self.check()

    def test_report_and_sidecar_cannot_self_select_changed_source_hash(self):
        changed = self.report_bytes + b"\n"
        self.sidecar["report_sha256"] = hashlib.sha256(changed).hexdigest()
        with self.assertRaisesRegex(ValueError, "source hash"):
            self.check(report=changed)
        with self.assertRaisesRegex(ValueError, "source/version"):
            self.check()
        for digest in (None, "", "f" * 63, True):
            with self.subTest(digest=digest), self.assertRaises(ValueError):
                self.check(accepted=digest if digest is not None else False)

    def test_zero_negative_and_partial_metric_n_are_explicit(self):
        for value, sign in ((0.0, "zero"), (-5.0, "negative")):
            report = copy.deepcopy(self.report)
            row = report["observed_before_proposal"]
            row["metric_deltas"]["hp"] = {"n": 7, "mean": value}
            self.replace_report(report)
            self.sidecar["claims"][0]["fact"] = {"kind": "metric_delta", "metric": "hp",
                                                   "n": 7, "display_mean": value, "direction": sign}
            self.assertTrue(self.check()["accepted"])
            self.sidecar["claims"][0]["fact"]["n"] = 10
            with self.assertRaises(ValueError):
                self.check()

    def test_decimal_tokens_do_not_round_extra_precision_or_underflow_to_zero(self):
        self.sidecar["claims"][0]["fact"] = self.delta_fact()
        original = encoded(self.sidecar)
        for token in (b"183.20000000000000000001", b"183.19999999999999999999"):
            sidecar = original.replace(b'"display_mean": 183.2', b'"display_mean": ' + token)
            with self.subTest(token=token), self.assertRaisesRegex(ValueError, "exact declared"):
                claims.validate(sidecar, self.report_bytes, self.accepted)
        for token in (b"183.2000", b"1.832e2"):
            sidecar = original.replace(b'"display_mean": 183.2', b'"display_mean": ' + token)
            self.assertTrue(claims.validate(sidecar, self.report_bytes, self.accepted)["accepted"])
        report = copy.deepcopy(self.report)
        report["observed_before_proposal"]["metric_deltas"]["hp"] = {"n": 10, "mean": 0.0}
        self.replace_report(report)
        self.sidecar["claims"][0]["fact"] = {"kind": "metric_delta", "metric": "hp", "n": 10,
                                               "display_mean": 0.0, "direction": "zero"}
        original = encoded(self.sidecar)
        for token in (b"1e-999", b"-1e-999"):
            sidecar = original.replace(b'"display_mean": 0.0', b'"display_mean": ' + token)
            with self.subTest(token=token), self.assertRaisesRegex(ValueError, "underflow"):
                claims.validate(sidecar, self.report_bytes, self.accepted)

    def test_report_integer_and_float_display_values_compare_as_exact_numbers(self):
        for observed, declared in ((5, 5.0), (5.0, 5), (0.0, 0)):
            report = copy.deepcopy(self.report)
            report["observed_before_proposal"]["metric_deltas"]["hp"] = {"n": 10, "mean": observed}
            self.replace_report(report)
            self.sidecar["claims"][0]["fact"] = {"kind": "metric_delta", "metric": "hp", "n": 10,
                "display_mean": declared, "direction": "positive" if declared > 0 else "zero"}
            with self.subTest(observed=observed, declared=declared):
                self.assertTrue(self.check()["accepted"])

    def test_missing_metric_and_initial_cohort_are_not_zero(self):
        report = copy.deepcopy(self.report)
        row = report["observed_before_proposal"]
        row["metric_deltas"]["lost"] = None
        row["lost_mean_direction"] = "unavailable"
        self.replace_report(report)
        self.sidecar["claims"][0]["fact"] = self.delta_fact()
        with self.assertRaisesRegex(ValueError, "missing metric"):
            self.check()
        report["observed_before_proposal"] = None
        self.replace_report(report)
        with self.assertRaisesRegex(ValueError, "missing observation"):
            self.check()

    def test_mixed_paired_outcomes_use_the_exact_cited_cohort(self):
        row = self.report["observed_after_replay"]
        self.selector.update({key: copy.deepcopy(row[key])
                              for key in ("map", "difficulty", "control", "candidate", "pairs")})
        self.selector["observation"] = "observed_after_replay"
        self.sidecar["claims"][0]["fact"] = {"kind": "paired_outcome", "outcome": "both_win",
                                               "count": 5, "denominator": 10}
        self.assertTrue(self.check()["accepted"])
        self.sidecar["claims"][0]["fact"]["count"] = 10
        with self.assertRaises(ValueError):
            self.check()

    def test_bool_float_counts_nonfinite_and_unknown_nested_fields_refuse(self):
        for field, value in (("count", True), ("count", 10.0), ("denominator", 10.0),
                             ("denominator", True), ("unknown", "prose")):
            invalid = copy.deepcopy(self.sidecar)
            invalid["claims"][0]["fact"][field] = value
            with self.subTest(field=field, value=value), self.assertRaises(ValueError):
                self.check(invalid)
        for value in (float("nan"), float("inf"), 10 ** 400, True):
            self.sidecar["claims"][0]["fact"] = self.delta_fact() | {"display_mean": value}
            with self.subTest(value=value), self.assertRaises(ValueError):
                self.check()
        invalid = copy.deepcopy(self.sidecar)
        invalid["claims"][0]["cohort"]["candidate"]["unknown"] = 1
        with self.assertRaises(ValueError):
            self.check(invalid)
        self.sidecar["claims"][0]["fact"] = self.delta_fact() | {"n": True}
        with self.assertRaises(ValueError):
            self.check()

    def test_unknown_kind_duplicate_keys_and_caps_refuse(self):
        self.sidecar["claims"][0]["fact"] = {"kind": "causal_improvement"}
        with self.assertRaisesRegex(ValueError, "unsupported"):
            self.check()
        for data in (b'{"kind":1,"kind":2}', b'{"overflow":1e400}', b"[]",
                     b" " * (claims.MAX_CLAIM_BYTES + 1)):
            with self.subTest(data=data[:24]), self.assertRaises(ValueError):
                claims.validate(data, self.report_bytes, self.accepted)
        self.sidecar["claims"] = []
        with self.assertRaisesRegex(ValueError, "count cap"):
            self.check()
        self.sidecar["claims"] = [{}] * 65
        with self.assertRaisesRegex(ValueError, "count cap"):
            self.check()

    def test_censored_counts_or_inconsistent_observation_are_not_supported(self):
        for mutate in (lambda row: row["paired_win_counts"].update(both_win=9),
                       lambda row: row.update(candidate_wins=9),
                       lambda row: row["metric_deltas"]["lost"].update(n=11),
                       lambda row: row.update(lost_mean_direction="candidate_lost_fewer")):
            report = copy.deepcopy(self.report)
            mutate(report["observed_before_proposal"])
            self.replace_report(report)
            with self.assertRaises(ValueError):
                self.check()

    def test_cli_success_failure_and_no_input_writes(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            report, sidecar = base / "report.json", base / "claims.json"
            report.write_bytes(self.report_bytes)
            sidecar.write_bytes(encoded(self.sidecar))
            originals = {p: (p.read_bytes(), p.stat().st_mtime_ns) for p in (report, sidecar)}
            command = [sys.executable, "-B", str(Path(claims.__file__)), "--report", str(report),
                       "--sidecar", str(sidecar), "--accepted-report-sha256", self.accepted]
            good = subprocess.run(command, capture_output=True, text=True, check=False)
            self.assertEqual(good.returncode, 0, good.stderr)
            self.assertTrue(json.loads(good.stdout)["accepted"])
            command[-1] = "0" * 64
            bad = subprocess.run(command, capture_output=True, text=True, check=False)
            self.assertEqual(bad.returncode, 1, bad.stderr)
            self.assertFalse(json.loads(bad.stdout)["accepted"])
            self.assertEqual(originals, {p: (p.read_bytes(), p.stat().st_mtime_ns) for p in (report, sidecar)})
            self.assertEqual({p.name for p in base.iterdir()}, {"report.json", "claims.json"})


if __name__ == "__main__":
    unittest.main()
