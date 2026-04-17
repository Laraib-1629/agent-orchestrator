# Rate-Limiting Discussion Notes

**Date:** 2026-04-16 – 2026-04-17
**Participants:** Dhruv, Claude
**Branch:** `feat/gh-rate-limiting` (PR #1238)

---

## What are we doing?

Making AO safely support 50+ concurrent sessions on a single GitHub PAT (5,000 requests/hr REST, 5,000 points/hr GraphQL).

Three sequential tracks:
1. **Track A — Measure:** Instrument AO to see what it costs. Build a repeatable benchmark.
2. **Track B — Fix bugs:** Starting with Bug #1 (ETag 304-as-error). Each fix validated by re-running the benchmark.
3. **Track C — Octokit migration (optional):** Only if Track B isn't enough.

---

## What we measured so far

Two independent runs at 5-6 sessions, quiet steady state, single repo (illegalcall/todo-app):

| Metric | Run 1 (Adil, 33min) | Run 2 (Dhruv, 22min) |
|--------|---------------------|----------------------|
| GraphQL burn/hr | ~25.7 (naive, unreliable) | 820–1,416 (per-window, reliable) |
| REST core burn/hr | not split | 28 |
| Total calls/min | 29.8 | 10.5 |
| Guard 304 rate | 9.3% | 11.5% |
| graphql-batch calls | 106 | 35 |

Difference in calls/min explained by session maturity — Adil's sessions had PRs and were being actively polled, ours were freshly spawned and most hadn't created PRs yet.

Full data in `experiments/baseline.md`.

---

## Extrapolated limits (rough, not validated)

| Sessions | GraphQL burn/hr (range) | Status |
|---------:|------------------------:|--------|
| 5 | 683 – 1,180 | Safe |
| 10 | 1,367 – 2,360 | Safe |
| 20 | 2,733 – 4,720 | At the edge |
| 25 | 3,417 – 5,900 | Risky |
| 50 | 6,833 – 11,800 | Over budget |

**Practical ceiling with current bugs: ~20-35 sessions.** But this is linear extrapolation from 6 sessions — not validated. The benchmark harness exists to replace this guess with real data at 5, 10, 20.

---

## Bug #1 — the highest priority fix

**Location:** `packages/plugins/scm-github/src/graphql-batch.ts`
**Functions:** `checkPRListETag`, `checkCommitStatusETag`

The ETag guard is broken:
1. `gh api -i` returns 304 → `gh` exits code 1 → `execFile` rejects
2. Catch block returns `true` ("assume changed")
3. This triggers a full graphql-batch call every poll cycle
4. Even when nothing has changed, AO pays full GraphQL cost

Also: Bug #2 — HTTP status check misses `HTTP/2.0 304` (only matches `HTTP/1.1` and `HTTP/2`).

**Status:** ✅ Fixed (commit `cd0b16ca`). Both `checkPRListETag` and `checkCommitStatusETag` catch blocks now inspect stdout/stderr for 304 before falling back to "assume changed". Also added `rateLimit { cost remaining resetAt }` to the GraphQL batch query for free cost attribution. PR comment posted to Adil for independent verification.

---

## What our benchmark covers vs doesn't cover

### Covers (quiet steady state):
- Lifecycle polling (30s loop)
- ETag guard behavior
- GraphQL batch enrichment
- PR detection, issue lookups, CI check queries

### Does NOT cover:
- Agents reacting to CI failures (push fix → new CI → state changes → more polls)
- Agents reacting to review comments
- Dashboard load (SSE/WebSocket)
- Spawn storms (many sessions starting at once)
- Cold start (AO restart, all caches empty)
- Multiple repos (different batching behavior)

### Key insight: Polling cost is frequency-driven, not content-driven

- AO polls every 30s regardless of what the repo has (CI, reviews, etc.)
- Adding CI checks or bugbot to the test repo doesn't change the rate-limit cost
- Same `gh` API calls fire whether the response has 0 check runs or 10
- The scenarios that change cost are ones where **agents are alive and reacting** — their reactions cause state changes, which cause cache misses in the guards, which cause more full-cost batch calls
- Quiet steady state (dead agents, existing PRs) is the **floor**, not the ceiling

### Does enabling CI/bugbot on todo-app change the numbers?

Discussed and concluded: **probably not** for the polling cost. The lifecycle manager calls the same endpoints at the same frequency. Response payload size changes but token cost per call doesn't. The difference would only show up if agents were alive to react to CI failures/reviews, which they aren't in the benchmark.

**However:** Dhruv enabled bugbot on todo-app and wants to verify this empirically. We should run the benchmark with bugbot/CI active and compare scorecards to confirm (or disprove) the hypothesis.

---

## Benchmark harness

**Spec:** `experiments/benchmark-spec.md`

Three commands:
- `setup` — spawn N sessions, wait for PRs, kill agents. One-time, expensive.
- `measure` — start AO, warm up 2min, measure for 15min, print scorecard. Repeatable, cheap.
- `report` — regenerate scorecard from old trace. Offline.

Scorecard metrics: GraphQL points/hr, REST core requests/hr, graphql-batch count, guard 304 count, guard error count, opaque call %, bracket delta, p50/p95/p99 latency.

**Methodology:**
1. Build harness
2. Run setup + measure at 5, 10, 20 sessions
3. Get real scaling curve (replaces extrapolation)
4. After Bug #1 fix: re-run same three sizes
5. Compare before/after scorecards

**Status:** ✅ Built and working (`experiments/benchmark.mjs`). Three modes: `setup`, `measure`, `report`. Validated end-to-end with B1 fix — see benchmark results below.

### Benchmark Results (2026-04-17, B1 fix applied)

15-minute quiet-steady benchmark, 5 sessions, single repo (`illegalcall/todo-app`):

| Metric | Value |
|--------|-------|
| GraphQL points/hr | 260 / 5,000 (5%) — **~70% reduction from pre-fix baseline** |
| REST core requests/hr | 0 / 5,000 (0%) |
| Total GH calls | 250 (16.7/min) |
| graphql-batch count | **0** (all skipped by ETag guards) |
| guard-pr-list 304s | 30 (100.0%) |
| guard-pr-list errors | 0 |
| ETag guard 304 rate | **100%** |
| p50 / p95 / p99 latency | 746 / 1,165 / 1,261 ms |

**Scorecard:** `experiments/out/scorecard-quiet-steady.single-repo.5-1776384105.json`
**Trace:** `experiments/out/gh-trace-bench-1776383083.jsonl` (281 rows)

### 10-Session Benchmark (2026-04-17, B1 fix applied)

| Metric | Value |
|--------|-------|
| GraphQL points/hr | 640 / 5,000 (13%) |
| REST core requests/hr | 0 / 5,000 (0%) |
| Total GH calls | 470 (31.3/min) |
| graphql-batch count | **0** |
| guard-pr-list 304s | 30 (100.0%) |
| p50 / p95 / p99 latency | 803 / 1,968 / 2,509 ms |

**Scorecard:** `experiments/out/scorecard-quiet-steady.single-repo.10-1776419128.json`
**Trace:** `experiments/out/gh-trace-bench-1776418105.jsonl` (526 rows)

### Scaling Analysis (5 → 10 sessions)

| Metric | 5 sessions | 10 sessions | Factor |
|--------|-----------|-------------|--------|
| GraphQL points/hr | 260 | 640 | 2.46x |
| Total calls/min | 16.7 | 31.3 | 1.88x |
| Opaque calls | 70 | 140 | 2.0x |
| Guard 304 count | 30 | 30 | 1.0x (repo-scoped) |
| p99 latency | 1,261ms | 2,509ms | 1.99x |

Scaling is slightly super-linear for GraphQL (2.46x for 2x sessions). Guard checks are repo-scoped and don't scale with session count. Opaque calls (per-session subcommands) scale linearly.

### 20-Session Benchmark (2026-04-17, B1 fix applied)

| Metric | Value |
|--------|-------|
| GraphQL points/hr | 680 / 5,000 (14%) |
| REST core requests/hr | 0 / 5,000 (0%) |
| Total GH calls | 910 (60.7/min) |
| graphql-batch count | **0** |
| guard-pr-list 304s | 30 (100.0%) |
| p50 / p95 / p99 latency | 761 / 2,798 / 3,052 ms |

**Scorecard:** `experiments/out/scorecard-quiet-steady.single-repo.20-1776424159.json`
**Trace:** `experiments/out/gh-trace-bench-1776423135.jsonl`

### Key Finding: Sub-Linear Scaling

GraphQL cost barely increased from 10→20 sessions (640→680, +6%). The guard-pr-list check is repo-scoped (constant 30 checks regardless of session count), and graphql-batch stays at 0 during steady state. Most of the per-session cost comes from opaque `gh pr view/checks` subcommands which are individually cheap.

**Revised 50-session projection:** ~800–1,000 GraphQL pts/hr (16–20% of budget). Far better than the earlier 64% estimate. **B2 structural reductions are NOT required for quiet-steady state.** The 50-session target is safely achievable with B1 alone.

**Key harness implementation notes:**
- Creates placeholder tmux sessions with a `claude` symlink → `/bin/sleep 86400` so lifecycle polls sessions instead of short-circuiting to "killed"
- macOS `/bin/sleep` doesn't accept `infinity` — use `86400` (24h)
- Must set `AO_CONFIG_PATH` to the todo-app config when running from the AO repo directory
- The todo-app config auto-infers `scm: { plugin: "github" }` from the `repo` field

---

## Artifacts produced so far

| File | What it is |
|------|-----------|
| `experiments/PLAN.md` | Master plan (Track A/B/C, blockers, decisions) |
| `experiments/baseline.md` | Measured data from two runs (cell S2-T1-5) |
| `experiments/a2-baseline-runbook.md` | Full A2 matrix execution plan |
| `experiments/analyze-trace.mjs` | Detailed trace analyzer (per-window burn) |
| `experiments/summarize-gh-trace.mjs` | Summary trace analyzer |
| `experiments/drill-tracer.mjs` | Standalone tracer exercise script |
| `experiments/benchmark.mjs` | **Repeatable benchmark harness** (setup/measure/report) |
| `experiments/benchmark-spec.md` | Benchmark harness spec |
| `experiments/out/scorecard-*.json` | Benchmark scorecards (JSON) |
| `experiments/out/gh-trace-bench-*.jsonl` | Benchmark trace files |
| `packages/core/src/gh-trace.ts` | The tracer (execGhObserved) |
| `packages/plugins/scm-github/src/graphql-batch.ts` | B1 fix: ETag 304 handling + rateLimit instrumentation |

---

## Open decisions

1. ~~**B1 PR comment to Adil** — drafted, not yet posted.~~ ✅ Posted. Awaiting Adil's independent verification run.
2. **Benchmark with bugbot/CI** — Dhruv enabled bugbot on todo-app. Want to verify empirically that CI/reviews don't change polling cost.
3. **Blocker #5 (sessionId/projectId threading)** — deferred. Needed for per-session attribution in the remaining A2 matrix cells.
4. **Scale-up validation (10, 20 sessions)** — next step. Can run locally now without waiting for Adil. Replaces extrapolation with measured data.
5. **50-session validation** — target tier, not first measurement tier. Get real data at 5/10/20 first.
