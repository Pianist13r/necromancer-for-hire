# Full-battle comparison cycles

To continue accumulating evidence after an older run stopped, use a fresh output
and `--initial-context ABSOLUTE_PATH_TO_LAST_FINISHED_BATCH/next-context.json`.
The controller verifies the old raw reports, requires the same fixed ten seeds,
and binds the context hash into the new configuration. It never changes the old
run or retries its failed proposal. `--round-limit` is an absolute comparison
offset: starting from20 with limit22 and cycle-limit2 runs two new comparisons.
This is separate from `--resume`, which retains the same frozen source/config.
The finite fixed-pool space contains336 legal comparisons; reaching it finishes
with `coverage_exhausted`. Repeated controls count as executions, not independent
new observations or coverage.

`run_cycles.py --workload battle` reuses the owned local server, unload/death proof,
STOP/deadline budget and immutable batch lifecycle from the gesture pilot. The
original default remains `--workload gesture`.

One battle batch makes **up to three** loopback structured JSON model requests on the same loaded server. The model
chooses one existing map/difficulty and candidate bot/profile with a brief
hypothesis. A fixed selective/base control and coordinator seeds base through
base+9 expand this into ten pairs, twenty complete battles. `--batch-rounds 1`
is required; `--round-limit` counts committed comparisons, not requests or games (at most three requests per comparison). `--workers 20`
selects the existing bounded parallel runner (BelowNormal, 4 GiB available RAM
stop threshold). Model and engine stages do not overlap.

`--workers` is a ceiling. Before engine launch, admission fixes the effective ceiling
to `min(requested, floor((available RAM - 4 GiB - 1 GiB headroom) / 1 GiB))`,
never raising a zero capacity to one. A 1 GiB reservation per process is conservative
against the observed failed Archive/hell batch's approximately 0.51 GiB average
owned RSS; it is a safety estimate, not a guarantee for every map. Before every
launch, current available RAM must also cover the 4 GiB emergency floor, 1 GiB
headroom, and a full 1 GiB reservation for every active process plus the new one.
This deliberately double-reserves some established RSS, protecting startup without
assuming newborn processes have already allocated their working set. If admission
cannot fit a new process, active games drain before another check; if no game is
active and no slot fits, the untouched queue tail is retained with
`stop_reason=memory_admission`. The existing emergency 4 GiB guard, STOP and time
limits remain in force. A completed game can admit the next queued game, but the
initial effective ceiling never grows during the batch. Old failed replays are
never automatically retried. `requested_workers`, `effective_workers`,
`peak_active_cases`, `resource_peaks.peak_live_cases`, and `memory_admission` report
the requested ceiling, budget-derived ceiling, observed concurrency and exact byte
basis; events record the admission plan and pauses/resumptions.

Example, after importing the worktree's Godot project and confirming no other
engine/model run is active; choose a fresh output and a future deadline with
at least 45 minutes available (stage reserves can require more):

```powershell
python -X utf8 tools/night_pilot/run_cycles.py --repo . --out local/qa/full-battles-01 --workload battle --batch-rounds 1 --round-limit 2 --cycle-limit 2 --seed 101 --collect-minutes 15 --replay-minutes 15 --workers 20 --model-load-mode mmap+mlock --deadline 2026-10-14T20:00:00+05:00 --server-exe C:/AI/llama.cpp/llama-server.exe --model-file C:/AI/models/Ornith-1.5-35B-Q4_K_M.gguf --chat-template C:/AI/models/ornith-1.5-claude.jinja
```

The JSON proposal has exactly version, hypothesis, map, difficulty and candidate
(bot/profile); seeds, game edits and code are unavailable. A single HTTP request
uses the installed b11583-988015788 server's nested
`response_format: {type: json_schema, json_schema: {name, strict, schema}}`
and a 4096 token output bound. This is verified against the
[pinned parser](https://raw.githubusercontent.com/ggml-org/llama.cpp/988015788/tools/server/server-common.cpp),
which reads `json_schema.schema` for this type; its flat schema form belongs to
`json_object`. The system prompt also gives the exact five keys, version1 and an
output example. A first live request with the flat form produced a stopped but
schema-invalid response, which was retained and rejected before any games.
Non-stop completion, invalid schema, duplicate comparison and transient request errors
retain separate immutable request/raw/proposal/error files under `attempts/NNN`.
Up to three attempts include prior rejection reasons and an untested legal menu.
After three rejected proposals, deterministic coverage fallback selects a different,
unseen configuration; rejected JSON is never repaired or reused. Even comparison
offsets require the preferred under-tested menu; odd offsets allow adaptive unique
choices. Ranking prioritizes base bot-only interventions, then least-covered
map/difficulty strata. All prior verified comparisons contribute separate paired
statistics to the prompt; win rates across maps are never pooled.

The prompt excludes previous proposal hypotheses: those texts are predictions,
not measured results. Before detailed metrics, `latest_verified_outcome` presents
the latest verified map/difficulty, control/candidate, pair count, named four paired
outcomes and wins for each arm. These counts come from verified replay statistics;
negative metric deltas do not imply defeats. Historical raw proposals and feedback
contexts remain unchanged. This reduces one source of misleading model motivation
but does not guarantee that a new model hypothesis is factually correct. The full
system plus user prompt retains its 48 KiB bound.

For each newly finished battle batch, read the sealed `batch-NNN/observation-report.json`
at the path recorded as `observation_report_path` in `cycle-status.json`. Its
`observed_before_proposal` describes the last verified comparison available when
the proposal was made; `observed_after_replay` describes the newly completed
comparison. Both give named paired outcomes, arm wins, and HP/loss mean differences
with N. A positive `lost` difference means the candidate lost more units than the
control. The separate `proposal_hypothesis` retains the original text and marks it
`unverified_free_text`, including when coverage fallback selected the proposal.
This report does not judge arbitrary prose or establish a causal effect. It does
not alter proposal, queue, receipt, or existing batch-seal formats; old batches
are left untouched.

An optional `claims.py` validates a separate `battle-observation-claims-v1`
sidecar against one **externally accepted exact report SHA256**. The coordinator
must obtain that SHA from an accepted batch/report outside the sidecar; supplying
an arbitrary report and its freshly computed hash does not establish battle
acceptance. Existing `feedback.load()`/batch-seal verification remain responsible
for raw evidence. This tool does not replace them or run during ordinary proposal
acceptance. Legacy five-key proposals, free hypotheses, queues and seals are unchanged.

The sidecar has exactly `kind`, `report_sha256`, `claims` (1–64). Each claim has
`cohort` and `fact`. A cohort cites `observation` (`observed_before_proposal` or
`observed_after_replay`) plus exact `map`, `difficulty`, `control`/`candidate`
(`bot`, `profile`) and `pairs`. Supported facts are:

- `arm_outcome`: `kind`, `arm` (control/candidate), `outcome` (victory/defeat),
  integer `count` and integer `denominator` equal to that cohort's pairs.
- `paired_outcome`: `kind`, `outcome` (both_win/control_only/candidate_only/both_lose),
  integer `count` and `denominator`.
- `metric_delta`: `kind`, `metric` (hp/lost), integer `n`, `display_mean` and
  `direction` (positive/negative/zero). Mean comparison is exact against the
  report's declared **four-significant-digit display value**, not full-precision
  raw data and not a tolerance. JSON decimals retain their exact token value:
  extra nonzero precision cannot round into a match, and nonzero underflow is
  refused. Numerically equal forms (`5`, `5.0`, `5e0`) are equivalent; counters
  still require JSON integers. Positive is candidate minus control: positive
  lost means the candidate lost more units. Missing metrics/cohorts are refused,
  never converted to zero; metric N can be smaller than the full pair count.

Example sidecar for a previously accepted ten-pair report with ten candidate wins:

```json
{"kind":"battle-observation-claims-v1","report_sha256":"<accepted-report-sha256>","claims":[{"cohort":{"observation":"observed_before_proposal","map":"swamp","difficulty":"normal","control":{"bot":"selective","profile":"base"},"candidate":{"bot":"melt","profile":"base"},"pairs":10},"fact":{"kind":"arm_outcome","arm":"candidate","outcome":"victory","count":10,"denominator":10}}]}
```

File-only invocation (absolute paths; prints a receipt, writes no files):

```powershell
python -B tools/battle_pilot/claims.py --sidecar C:/absolute/claims.json --report C:/absolute/observation-report.json --accepted-report-sha256 <independently-accepted-sha256>
python -B -m unittest discover -s tools/battle_pilot -p test_claims.py
```

Unknown keys/kinds, changed source hash/cohort, wrong count/N/sign, booleans used
as numbers and nonfinite values fail. Accepted structured facts do **not** validate
contradictory free prose, predictions, causality or model selection utility, and
do not promote a battle/model/service trust label. An `accepted:true` receipt
applies only to the explicitly enumerated claims and exact report bytes.

History is a
compact table of configuration, pair count, four paired outcome counts and paired
HP/loss/time/economy mean differences with their N. Numbers use four significant
digits; the full precision raw values remain on disk. At larger histories oldest
numeric detail is explicitly omitted first, while all configurations and outcome
counts remain. The latest ten pairs retain their detailed metrics. System+user
content has a hard48KiB UTF-8 ceiling checked before HTTP, with2KiB reserved for
rejection feedback. This bounds prompt growth for the65536-token server instead
of repeatedly failing context length and silently staying on fallback.

STOP or the monotonic total collection deadline aborts selection without fallback.
The daemon HTTP receiver writes no files; cancellation records `response_incomplete`
and can omit an unfinished raw response. A per-request wall timeout selects a
coverage fallback immediately (even after just one request), marked explicitly as
`fallback_reason=request_wall_timeout`. No subsequent request is started, the
collector exits, and owned server death is required before replay. Socket errors
from a completed receiver may be retried within the same total collection budget.
`worker_runs`/`model_request_runs` count actual request starts; `experiment_runs`
counts the one comparison attempt. `generator_success` means a model proposal was
accepted; `selection_source=fallback`, `degraded=true` explicitly distinguish
coverage recovery. Collection/replay acceptance measures intact real battle data,
not generator quality. All attempt files and fallback receipts are SHA-bound,
checked before replay/feedback, and sealed for resume. Legacy single-request
contexts remain readable. Integrity failures always stop the pipeline.
The installed build's API compatibility was verified in the
bounded live run described below.

Every next prompt receives concrete verified previous paired outcomes, finite
combat/economy metrics and candidate-minus-control differences, plus all completed
comparison configurations. Feedback checks exact queue/case hashes, execution
commands, terminal identity, exit/death proof, result files and raw logs; it
rebuilds statistics from those executions. Rewording a hypothesis cannot bypass
comparison deduplication. Model analysis informs proposals only; it cannot edit
policies, maps, balance or the evaluator.

The same fixed seed pool is reused across cycles for comparison training. This
pairs seeded initial conditions; bot reactions and elite rolls can consume shared
RNG differently, so realized random draws are not identical. This is not
independent validation or generalizable causal evidence. A profile change bundles
resource/recruitment changes with any bot change; reports identify both profiles.
Victories and defeats are valid data. Censored/invalid/incomplete cases stop this
initial protocol and never become defeats or an automatic game bug. Full pilot
acceptance requires all twenty terminal results in every requested batch and all
input/owner guards and owned process death proofs. The final batch has no further
local model analysis; the supervisor evaluates its final report.

`OUT/STOP` requests bounded shutdown. Resume refuses living owned PID/creation-time
identities, changed sources/artifacts/context/seals and rejected completed replay.
Interrupted queued replay uses fresh output and is completed before any reload;
completed batches are never repeated. Source guards cover all Godot inputs except
`.godot` cache and all night/battle Python sources including untracked files.
Model GGUF, template, server launcher, optional `llama-server-impl.dll`, and both
Godot executables are fully hashed at entry and resume. Between batches their
size/mtime are checked; this avoids rereading 21.7 GB per cycle but cannot detect
an adversarial same-size/same-mtime replacement. Shared CUDA/runtime DLLs are not
all hashed. `mmap+mlock` requests VirtualLock, which can fail; inspect the server
log and resources before claiming residency. No foreign process priorities or
paging settings are changed.

## Live acceptance, 14 October 2026

`local/qa/2026-10-14-night-full-battles/run-02` on `77f09c12` completed two model
requests and two full twenty-game batches: 40/40 valid terminal results, actual
peak concurrency20 in each, no censored/invalid/aborted games, full pilot acceptance.
Whole controller lifetime was609.14seconds including initial hashes, model loads,
analysis and replay. Each replay took151.344/127.703seconds including its guards.
The second prompt received verified first-batch statistics; its final proposal
explicitly cited the first comparison's2/10 versus4/10 result. Both completed
queues, seals, process death ordering and12 historical control traces were
independently verified in `accepted/run-02-independent-review.md` beside that run.
This proves the bounded workflow, not unattended all-night reliability or a new
strategy improvement. The final batch was reviewed by the coordinator; it did
not receive another local-model analysis pass.

Replay available RAM stayed above11.08GiB; model phases briefly reached only
0.102GiB available. The four-GiB replay threshold does not apply to model loading.
Both loads requested mmap+mlock; full page residency was not proven.

Focused tests use HTTP and process stubs, with no engine/model services:

```powershell
python -m unittest discover -s tools/battle_pilot -p 'test_*.py' -v
```


## Recovery acceptance, 15 October 2026

QA `local/qa/2026-10-15-night-recovery`: the original400 terminals and1440
sealed files were verified; only250 case hashes were distinct. A scripted HTTP
fixture then rejected three duplicates and selected a fresh coverage fallback.
The first real replay aborted20 games on memory pressure (retained as failure).
After RAM admission, a fresh replay completed20 defeats in193.079s, peak7;
fixture responses are not genuine model reasoning.

Two real-model batches on a7a4dc5e completed40 terminals before an intentional
coordinator STOP to improve the prompt: that run is stopped, not full acceptance.
The continuation on9270d312 completed4/4 batches,80/80 terminals, four real model
requests and full bounded acceptance in1395.00s, sampled live-process peaks14
in all four batches. Active-queue peaks14/15/14/14 can include a process already
exited but not yet classified; they are not simultaneous-live measurements.
All120 model-selected executions plus20 fallback executions extend the verified
history to540 executions, 380 distinct cases,27 comparisons and
11 map/difficulty strata. Repeated controls are not independent samples.
Feedback, request contents, seals and owned process death were independently
reviewed.47 battle tests and110 unchanged night tests pass.

This is not an unattended overnight proof. Model narratives remained unreliable:
false prior defeat counts, reversed interpretation of loss deltas and a prediction
of fewer candidate-only wins than zero. B-507 tracks that limitation; schema
acceptance and usable raw measurements do not validate prose or demonstrate
selection superiority over deterministic coverage. No gameplay/balance change,
release build, publication or new overnight schedule was made.
