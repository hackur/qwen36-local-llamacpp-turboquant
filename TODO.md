# TODO

## P0 - clean clone works

- [x] Make `make build` clone the required `llama.cpp` checkouts when `vendor/` is empty.
- [x] Ensure every target that redirects into `logs/` creates that directory first.
- [x] Add a lightweight setup check that reports missing command-line tools, models, and builds.
- [x] Keep privacy scans green before every public push.

## P1 - public user experience

- [x] Tighten README quickstart so a new user understands online vs offline steps.
- [x] Remove local-machine-only references from docs and replace them with generic examples.
- [x] Add a short requirements section for macOS, Xcode command line tools, CMake, Git, curl, jq, and Python 3.
- [x] Document how to use model paths directly when LM Studio is not installed.

## P2 - validation

- [x] Add a non-model shell test that runs `bash -n` over scripts and checks Makefile help.
- [x] Add a dry-run mode for model symlinking and startup preflight.
- [ ] Add a CI workflow for static checks that does not download models or build large dependencies.

## P3 - release hygiene

- [x] Add a license after choosing the intended license. (MIT — `LICENSE`)
- [x] Add a changelog or release notes for `v0.0.1`.
- [x] Decide whether raw benchmark text outputs should stay tracked or move to generated artifacts. (gitignored; aggregates kept in `benchmarks/RESULTS.md` and `SWEEP.md`)
- [x] Add contribution notes for model path changes and benchmark submissions.
- [x] Add `SECURITY.md` and document the offline-clean guarantee.
- [x] Document non-LM-Studio install path (`docs/install-models.md`, `MODELS_ROOT` env var).

## P4 - benchmarking discipline

See `docs/benchmarking-discipline.md` for the underlying observations
(2026-05-25 MTP vs turboquant ad-hoc "comparison" that wasn't one).

- [x] Add a `scripts/bench-ab.sh` harness that takes two endpoints + a fixed
      prompt + fixed `max_tokens`, warms each side once, then runs N=5 at the
      raw `/v1/chat/completions` layer and reports median tok/s with min/max.
      Refuses to run if both ports are listening simultaneously (thermal).
- [ ] Re-run MTP vs turboquant **on matched artifacts** (same weights, same
      quant) once turboquant gains `--spec-type draft-mtp`, or downgrade
      turboquant to UD-Q4_K_XL for one apples-to-apples pass. Use
      `scripts/bench-ab.sh`.
- [x] Stop reporting wall time measured through hermes/any agent harness as a
      model speed number — rule stated in `CONTRIBUTING.md` + RESULTS.md
      header.
- [x] Require metadata block on every new `benchmarks/RESULTS.md` entry
      (model + quant, `max_tokens`, ctx, KV dtype, warm/cold, sample count,
      bench script, git SHA). Header added to RESULTS.md.
- [ ] Backfill or annotate the 2026-05-07 RESULTS.md entries with the new
      metadata block (or mark "uncontrolled").
- [x] Add "smoke test ≠ verification" reminder to `CONTRIBUTING.md`.

## P5 - Interactive A/B bench TUI

Goal: turn `bench-ab.sh` into a queued, observable suite runner. Live
per-job status (queued / waiting / warming / running / ok / failed /
skipped / stopped), arrow-key navigation, select-to-stop or
select-to-start. Thermal rule preserved: **one llama-server bench at a
time**, enforced by the runner via a lock file; UI parallelism only.

Stack (locked): Python 3 + `textual` for the TUI, `pyyaml` for suites.
Both already-installable via pip; gated behind an optional
`requirements-tui.txt`. Existing `scripts/bench-ab.sh` stays as the
zero-dep fallback.

### Component A — Suite schema  `benchmarks/suites/*.yaml`

Each YAML file is a logical *group* (e.g. `qwen36-family.yaml`,
`kv-cache-types.yaml`, `spec-decoding.yaml`). Schema:

```yaml
name: qwen36-family
description: A/B sweeps across Qwen 3.6 variants
defaults:
  n: 5
  max_tokens: 500
  prompt: |
    Explain in detail how transformer attention mechanisms work...
jobs:
  - id: turboquant-vs-mtp
    a: { label: turboquant, port: 10501 }
    b: { label: mtp,        port: 10502 }
  - id: baseline-vs-turboquant
    a: { label: baseline,   port: 10500 }
    b: { label: turboquant, port: 10501 }
    # per-job overrides allowed: n, max_tokens, prompt
```

Ship at least two real suites: `qwen36-family.yaml` and
`kv-cache-types.yaml`. Validation helper (`bench_suite.py`) loads +
checks schema; CLI: `python3 scripts/bench_suite.py validate <file>`.

### Component B — Job runner  `scripts/bench_runner.py`

- Loads one or more suite YAMLs, builds a job queue.
- Runs jobs sequentially; per job: wait for *only* A listening → warmup
  (discarded) → N timed runs → wait for *only* B listening → warmup →
  N timed runs → compute median/min/max.
- Emits status events to `benchmarks/runs/<run-id>/events.jsonl`:
  ```json
  {"ts":"2026-05-25T18:00:00Z","job":"turboquant-vs-mtp","phase":"running","side":"A","run":3,"tok_s":61.4}
  {"ts":"2026-05-25T18:01:30Z","job":"turboquant-vs-mtp","phase":"ok","summary":{"a":{"median":61.5,"min":60.2,"max":62.1},"b":{"median":15.4,"min":14.9,"max":16.0}}}
  ```
- Phases (closed set): `queued`, `waiting_port`, `warming`, `running`,
  `ok`, `failed`, `skipped`, `stopped`.
- Reads `benchmarks/runs/<run-id>/control.jsonl` (append-only) between
  every run iteration:
  - `{"action":"stop","job":"<id>"}` → abort that job, mark `stopped`
  - `{"action":"skip","job":"<id>"}` → mark `skipped` without running
  - `{"action":"start","job":"<id>"}` → promote queued job to front of queue
- One-bench-at-a-time enforced via a lockfile at
  `benchmarks/runs/.bench.lock`. Refuses to start if another runner
  holds it. If both A and B ports listen at the same moment, runner
  reports `waiting_port` and polls — never both at once.

### Component C — TUI  `scripts/bench_tui.py`

Textual app. Three panes:

- **Left (tree)**: groups → jobs, with phase glyph next to each id
  (`·` queued, `…` waiting, `⚙` running, `✓ ok`, `✗ failed`, `⊘ skipped`).
- **Right top (table)**: current job's per-side stats (label, port,
  runs done / N, last tok/s, median so far).
- **Right bottom (log)**: live tail of `events.jsonl`.

Keybinds: `↑/↓` navigate, `Enter` expand group, `s` stop selected,
`r` run/start-now selected, `k` skip selected, `q` quit (UI only;
runner keeps going). Writes one control event per action; never
mutates events.jsonl. Runner is the single source of truth.

### Component D — Wire-up

- `make bench-tui` launches runner in background (`run_in_background`
  shell pattern) + TUI in foreground.
- `make bench-headless SUITE=…` runs without TUI (CI-friendly).
- `requirements-tui.txt` with `textual>=0.60` and `pyyaml>=6`.
- README and `docs/benchmarking-discipline.md` cross-link.
- `bench-ab.sh` keeps working unchanged; it becomes the "no-Python"
  fallback path documented in CONTRIBUTING.md.

### Protocol contract (locked — agents must not negotiate)

`events.jsonl` and `control.jsonl` schemas above are the integration
contract between B and C. Both files are append-only JSONL, UTF-8,
one event per line, ISO-8601 UTC timestamps. Run directory layout:

```
benchmarks/runs/<run-id>/
  events.jsonl     # runner writes, TUI reads (tail -f style)
  control.jsonl    # TUI writes, runner reads between runs
  summary.json     # runner writes once at end
  <job-id>.json    # per-job raw timing records
```

Where `<run-id>` is `YYYYMMDD-HHMMSS`.

### Tasks

- [x] A1: write `benchmarks/suites/qwen36-family.yaml` + `kv-cache-types.yaml`
- [x] A2: write `scripts/bench_suite.py` (load + validate)
- [x] B1: write `scripts/bench_runner.py` per the protocol above
- [x] C1: write `scripts/bench_tui.py` per the protocol above
- [x] D1: `requirements-tui.txt`, `make bench-suite` / `make bench-tui`
- [x] D2: docs cross-link (`docs/benchmarking-discipline.md`) + README target lines
- [ ] D3: end-to-end smoke test against live servers (deferred — thermal,
      user-gated). When you bring up baseline + turboquant + mtp in sequence,
      run `make bench-tui SUITE=benchmarks/suites/qwen36-family.yaml` and
      confirm tree updates, control writes are honored, summary.json lands.

### Known outstanding (from 2026-05-25 verification pass)

- [ ] **TUI `--spawn` is a stub.** `scripts/bench_tui.py --spawn` creates a
      run dir + `suite_files.txt` and prints "start bench_runner.py
      manually". Real fix: spawn the runner as a `subprocess.Popen` child,
      capture its stderr into `runner.log` inside the run dir, send SIGTERM
      on TUI quit only if the user opted in.
- [ ] **No venv awareness in `make bench-tui` / `make bench-suite`.** Homebrew
      Python on macOS is externally-managed (PEP 668) — fresh clones need
      `python3 -m venv .venv && .venv/bin/pip install -r requirements-tui.txt`.
      Either auto-create `.venv` on first `make bench-tui`, or document the
      one-liner in README + `docs/benchmarking-discipline.md`. Currently
      undocumented; users will hit the same PEP-668 wall I did.
- [x] Tree auto-focus on mount in `bench_tui.py` (verified 2026-05-25 — was
      blocking arrow-key nav until manual focus).

## P6 - MCP in the llama.cpp chat UI

Investigation complete — see `docs/mcp-integration.md`. **MCP client is
already in our WebUI** (both mainline and turboquant builds). What's
missing: the server-side CORS proxy flag (`--ui-mcp-proxy` on mainline,
`--webui-mcp-proxy` on the older turboquant fork) and bridges for the
common stdio MCP servers.

Goal: get the WebUI at `http://127.0.0.1:10501/` to successfully call out
to a sandboxed filesystem MCP server and have the model use it via the
existing browser-side agentic loop, all opt-in, with the offline guarantee
preserved when the opt-in is off.

### Tasks

- [x] **P6.1 — `mcp_proxy_flag` helper in `scripts/_common.sh`.** Feature-
      detects `--ui-mcp-proxy` (mainline) vs `--webui-mcp-proxy`
      (turboquant fork) by grepping `--help`. Emits when `MCP_PROXY=1`.
- [x] **P6.2 — Wire `MCP_PROXY` env var** through `start-turboquant.sh`,
      `start-baseline.sh`, `start-qwen36-mtp.sh`. Off by default.
- [x] **P6.3 — `scripts/mcp-bridge.sh`** — `fs`/`git`/`time` subcommands,
      uses `supergateway --outputTransport streamableHttp --cors …`
      (not the SSE default — the WebUI only speaks Streamable HTTP).
      Ports 4001+, refuses to clobber, fails clear if `npx` missing.
- [x] **P6.5 — `make mcp-fs` / `make mcp-git` / `make mcp-time`** targets.
- [x] **P6.7 — Calibration smoke test.** Recorded in
      `benchmarks/mcp/2026-05-25-fs-smoke.md`. Agentic loop verified:
      `list_allowed_directories` → `list_directory` → NL summary of 30
      files, 338 tokens / 25 s / 13.09 tok/s. Not a perf claim — single
      prompt, single model.
- [ ] **P6.4 — Quickstart section** in `docs/mcp-integration.md` with
      the exact `make` + WebUI steps that just worked. Note three
      gotchas discovered live: (a) URL ends in `/mcp` not `/sse`,
      (b) supergateway needs `--outputTransport streamableHttp`,
      (c) supergateway needs `--cors http://127.0.0.1:10501`.
- [ ] **P6.6 — Offline-guarantee regression test.** During the smoke
      test, `MCP_PROXY=1` produced a real outbound HTTPS to
      `www.google.com` (favicon fetch via `/cors-proxy`). Add a
      `make audit-mcp-off` that asserts: with `MCP_PROXY` unset,
      llama-server holds exactly one localhost socket, zero outbound
      attempts during a 30-s WebUI session.
- [ ] **P6.8 — README cross-link** + `docs/usage.md` blurb explaining
      the opt-in and the **confirmed** offline trade-off (cite the
      favicon-leak observation from the smoke test).

### Out of scope (deferred or won't-do)

- MCP **sampling** (server-initiated callbacks into the client). Upstream
  llama-server doesn't implement it — see ggml-org discussion #22640.
- `mcpo` (Open WebUI's MCP→OpenAPI converter). Loses prompt/resource
  support and doesn't match what our WebUI expects.
- Multi-user / shared MCP-server config. localStorage is per-browser by
  design; a single-user local box is fine.
