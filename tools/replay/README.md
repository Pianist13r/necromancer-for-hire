# Local input replay, schema 1

## Offline checkpoint receipt worker

`local_worker.py` is a small offline boundary around the guarded replay runner. It accepts
a local manifest and a replay file, checks pinned source/engine hashes and a SHA-256 of the
replay bytes, rejects unsupported progression before starting Godot, then runs the exact
checked bytes in an isolated child. The output directory must be new.
Use `run_input_replay.py --record-only --import` to make one current-source fixture without
the default negative suite; its `before.json` supplies the pinned identity. The imported
cache stays in that worktree. Existing accepted recordings keep their original identity.

```json
{
  "schema": 1,
  "kind": "neutral_checkpoint",
  "identity": {
    "code_sha256": "<64 lowercase hex from run_input_replay.py before.json identity.code>",
    "engine_sha256": "<64 lowercase hex from run_input_replay.py before.json identity.engine>"
  },
  "replay_sha256": "<64 lowercase hex SHA-256 of the replay file>"
}
```

```powershell
python tools/replay/local_worker.py --engine C:/Projects/SharedTools/godot/Godot_v4.7.2-stable_win64_console.exe --manifest C:/path/to/manifest.json --replay C:/path/to/recording.json --out C:/Projects/Necromancer/local/qa/receipt-unique
```

`receipt.json` records `matched`, `refused`, `diverged`, or `worker_failure`, the reason and
first reported tick. A zero exit means only that the neutral checkpoint reproduced; every
other status exits nonzero. Missing native output, diagnostics, timeout, interruption,
source/worker mutation, owner-profile mutation and RAM-floor failure cannot yield a match.
For `matched`, the native driver must also return its complete replay report: replay mode,
all declared ticks, two completed driver checks, empty failures, expected effect counters,
and a finite checkpoint score equal to the envelope. A malformed native success report is
`worker_failure` even if the process exits zero.
The receipt always contains `verified:false` and `score_eligible:false`: it is local
consistency evidence, neither a signed result nor a Daily/Endless/campaign score. This
command has no HTTP or production UI path. Manifest and replay input limits are 4 KiB and
8 MiB. `--timeout` bounds the whole worker; the existing runner owns and stops its child.

This is an opt-in developer tool for B-120, not a verified leaderboard score. Nothing is
recorded during ordinary play and nothing is submitted online. A recorder is explicitly
attached to `LegionWorld.net_out`; it persists the existing `NetCodec` commands and feeds
their normalized form back through `net_apply` before the next `net_step`.

```powershell
python tools/replay/run_input_replay.py --engine C:/Projects/SharedTools/godot/Godot_v4.7.2-stable_win64_console.exe --out C:/Projects/Necromancer/local/qa/replay-unique --import
python tools/replay/run_input_replay.py --engine C:/Projects/SharedTools/godot/Godot_v4.7.2-stable_win64_console.exe --out C:/Projects/Necromancer/local/qa/playback-unique --replay C:/Projects/Necromancer/local/qa/replay-unique/recording.json
```

Use a dedicated worktree. `--import` prepares its Godot cache. Output directories must be
new; recording does not overwrite a file. Python3 requires `psutil`; the shared process
wrapper uses Windows `OwnedJob` or a dedicated POSIX process session. Every engine launch
gets separate APPDATA and XDG data/config/cache paths, disabled metrics/dev bridge, muted audio, 4 GiB RAM admission, a 3 GiB floor and
a 240 second gameplay deadline (900 seconds for optional import). It records PID/creation
identity, logs, and source/owner manifests. A copied editor layout may contain stale UIDs;
reuse imported resources and class/UID caches without copying another editor's layout.
Only this runner's owned job may be stopped. Source identity hashes actual `.gd`, `.json`,
`.tscn`, `.tres` and `project.godot` bytes; engine identity hashes the exact executable.
Source dirtiness is not hidden by a Git revision. Art/audio bytes are outside this
headless simulation identity. Git HEAD is separately recorded as provenance.

The full `tools/legion_gate.sh` always includes the `legion_input_replay` lifecycle case;
`GATE_ONLY_TEST=legion_input_replay SKIP_IMPORT=1` runs exactly that case. The renamed
`legion_input_replay_driver.gd` is intentionally outside the plain Godot test glob because
its environment is supplied by the Python lifecycle. Gate gives it fresh output and does
not repeat import. `--timeout` bounds the entire lifecycle (default900s); SIGTERM/SIGINT
request owned-child teardown. The outer gate receives nonzero failures normally.

Windows runtime is tested. The Linux XDG/session path is implemented but native Linux
runtime remains untested. macOS profile isolation is not implemented: the runner prints
`INPUT REPLAY UNSUPPORTED`, launches no engine and returns77. The shell gate also stops
early on Darwin before import/check-only/any engine invocation, with `GATE INCOMPLETE`
and exit77, never `GATE OK`. All Linux gate cases inherit isolated XDG data/config/cache
paths, including parallel tests. No native POSIX PASS is claimed.

## Envelope and playback

`recording.json` contains schema, source/engine/generator/NetSnap/codec identities, map,
battle RNG seed, difficulty, side 0, 60 Hz and explicit neutral progression. Tick means
simulation frame: events at tick K are ordered by sequence and applied BEFORE step K→K+1.
It stores a binary `NetSnap` start in base64 (preserving 64-bit RNG state), normalized
named commands with their real outcomes, full canonical snapshot SHA-256 at tick 0 and
every subsequent tick, and the final checkpoint score (HP/time/wave/kills/lost/souls/phase).
An unfinished battle is not presented as a win or an endless/daily score.
Instantiate a new `LegionInputReplay` session for each recording or playback.

The CLI validates the envelope before constructing a world. Identities, finite integral
ticks, order, side, commands, extra fields and bounds are checked. A fresh neutral world
is recreated from the declared config. Its initial binary snapshot must exactly equal
the saved bytes BEFORE any Variant deserialization. The saved snapshot is then restored
and checked again. Replay compares every command outcome, every tick digest, and score;
it stops at the first difference. The full snapshot contains RNG, units, contracts,
mana, buildings, wave state and statistics, beyond the narrower network digest.

Bounds: 8 MiB input file, 4 MiB base64 initial snapshot, 3600 ticks, 4096 events; existing
NetCodec coordinate/count/id limits apply. A caller using the helper directly must
enforce the file limit before JSON parsing, as the provided driver does.

## Tested vertical slice and limits

The default fixture is the shipped `_plots` solo map, seed 4242, normal difficulty,
1200 ticks. It uses `ContractField.begin/extend/finish` for drawing and `click` for release;
spell/build use `local_cmd`, the same semantic entry as the UI. Success requires actual
contract/release/hero/building signals, a purchased building, spell mana expense and a
manual release. It is scripted native semantic input, not recorded physical mouse
movement and not bot AI. Record and replay run in distinct processes/profiles with
different render-frame cadence. Negative files preserve changed stroke/score, incompatible
schema/code/generator, invalid timeline/side, unsupported input/extra field, altered
snapshot and nonneutral progression; rejection is checked at the expected tick.

Schema 1 supports fresh standalone solo on shipped authored maps and the named NetCodec
gameplay commands `stroke/aim/sling/click/erase/plot/cast/rally`. Only the four fixture
actions are demonstrated here. Campaign/endless/daily progression, generated maps,
carry/items/meta preparation, tutorial, bots, PvP, midbattle recording, surrender,
wave calling, kassa, pause/speed, raw device events, editor/dev mutations, OS focus timing
and menu transitions are unsupported. There is no automatic production recorder UI.
Presentation-only state is not part of NetSnap. Native Linux/macOS, different engine
binaries/hardware and completed run scores are unproven.

Hashes are consistency checks, not authentication. A person can rewrite the whole file,
source or expected hashes. This tool does not prove that a human supplied inputs, issue
a trusted score flag, provide a server judge, or complete B-120 anti-cheat/sharedboard.
