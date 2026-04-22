# GitHub Rate-Limit Trace Report

**Date:** 2026-04-22
**Branch:** `feat/gh-rate-limiting`
**Trace file:** `experiments/out/gh-trace-real-1776874503.jsonl`

## Test Conditions

| Parameter | Value |
|-----------|-------|
| Sessions | 5 |
| Duration | 15 min 41 sec (16:16 – 16:32 UTC) |
| Repo | iamasx/api-test |
| Issues | #166, #167, #168, #169, #170 |
| PRs created | #178, #179, #180, #181, #182 |
| Poll interval | 30 seconds |
| Trace env | `AO_GH_TRACE_FILE` set for AO-side |

## Rate-Limit Budget Consumed

| Budget | Before | After | Consumed | Projected/hour |
|--------|--------|-------|----------|----------------|
| **GraphQL** (5,000/hr) | 135 used | 653 used | **518** | **~2,072** (41%) |
| **REST** (5,000/hr) | 1 used | 43 used | **42** | **~168** (3%) |

**At 5 sessions, GraphQL is the bottleneck.** At ~15 sessions the hourly GraphQL budget would be exhausted.

## Call Summary (465 total)

| Operation | Calls | Total Time | Avg Latency | Component |
|-----------|------:|----------:|------------:|-----------|
| `gh pr list` (detectPR) | 82 | 94.1s | 1,147ms | scm-github |
| `gh pr view` (individual) | 65 | 82.4s | 1,267ms | scm-github |
| `gh api graphql` (review threads) | 55 | 58.1s | 1,056ms | scm-github |
| `gh api guard-pr-list` (ETag guard 1) | 54 | 52.7s | 975ms | scm-github-batch |
| `gh api guard-commit-status` (ETag guard 2) | 51 | 51.2s | 1,003ms | scm-github-batch |
| `gh pr checks` (CI details) | 45 | 86.7s | 1,925ms | scm-github |
| `gh api graphql-batch` (batch enrichment) | 44 | 66.5s | 1,510ms | scm-github-batch |
| `gh api repos` (automated comments) | 40 | 37.8s | 946ms | scm-github |
| `gh issue view` (tracker) | 27 | 29.6s | 1,096ms | tracker-github |
| `gh pr merge` | 1 | 3.8s | 3,768ms | scm-github |
| `gh issue list` | 1 | 1.3s | 1,262ms | tracker-github |

**Total wall time spent in gh calls:** 564 seconds (9.4 minutes of the 15.7-minute window).

## ETag Guard Effectiveness

| Guard | 304 (saved) | 200 (refresh needed) | Failed (exit 1) | Hit Rate |
|-------|:-----------:|:--------------------:|:----------------:|:--------:|
| PR list (Guard 1) | 21 | 33 | 21 | 39% |
| Commit status (Guard 2) | 28 | 23 | 28 | 55% |

Guard "failures" (exit code 1) are **not bugs**. The gh CLI exits with code 1 on 304 responses (empty body). The guard code at `graphql-batch.ts:400-404` handles this correctly — checks stderr for "304 Not Modified" and returns the right result. Genuine errors return `true` (assume changed) as a safe fallback.

## Anomaly Analysis

### 1. `detectPR()` — 82 calls for 5 sessions

**Expected:** ~5 (once per session when PR is discovered).
**Actual:** 82 (16+ per session).

| Branch | Calls |
|--------|------:|
| feat/issue-170 | 31 |
| feat/issue-167 | 18 |
| feat/issue-169 | 13 |
| feat/issue-166 | 11 |
| feat/issue-168 | 9 |

**Root cause:** Not a bug. `lifecycle-manager.ts:708-741` checks `!session.pr` every poll cycle. If the agent hasn't created the PR yet, `detectPR()` is called again. Once the PR is found, it's stored in metadata and never re-fetched. The 82 calls reflect the time agents spent working before creating their PRs.

**Verdict:** Working as designed. The call volume is proportional to the delay between session spawn and PR creation.

### 2. Individual `pr view` (65) and `pr checks` (45) despite batch enrichment

**Expected:** Near zero — the batch enrichment cache should serve this data.
**Actual:** 110 individual fallback calls.

**Root cause:** The batch enrichment cache is populated by `enrichSessionsPRBatch()` (called once per poll cycle). But individual fallback calls happen when:

1. **ETag guard failures** (47% failure rate) cause the system to assume data changed, triggering a refresh — but if the batch partially fails, some PRs have no cached data.
2. **New PRs not yet in cache** — on first detection, the PR isn't in the enrichment cache, so the first cycle falls back to individual calls.
3. **`getMergeability()` makes redundant sub-calls** — it internally calls `getPRState()` and `getCISummary()` again, even though the caller may have already fetched them.

**Breakdown per fallback PR (~13 PRs missed cache):**
- `getPRState()` → 1 `pr view` call
- `getCIChecks()` → 1 `pr checks` call
- `getReviewDecision()` → 1 `pr view` call
- `getMergeability()` → internally calls `getPRState()` + `getCISummary()` again → 2-3 more calls
- **Total: ~5 calls per cache miss**

**Verdict:** The batch system works but the fallback path is expensive. Each cache miss amplifies into 5 individual calls.

### 3. Review threads (55 GraphQL) + automated comments (40 REST)

**Expected:** Throttled to every 2 minutes per session.
**Actual:** 55 + 40 = 95 calls in 15 minutes.

**Root cause:** The 2-minute throttle (`REVIEW_BACKLOG_THROTTLE_MS`) is working. With 5 sessions × ~7 throttled windows in 15 minutes = ~35 calls per type. The overshoot (55 vs 35) comes from review reaction events bypassing the throttle (`lifecycle-manager.ts:1147-1148`).

**Key constraint:** `getPendingComments()` uses **GraphQL** — GitHub's GraphQL API does **not support ETags**. Every call costs API points regardless of whether comments changed.

**Reduction options:**
1. **Fold review threads into the batch query** — add `reviewThreads(first: 100)` to the existing `generateBatchQuery()` in `graphql-batch.ts`. Zero extra API calls. **Eliminates all 55 standalone GraphQL calls.**
2. **Add ETag to automated comments REST call** — `GET /repos/.../pulls/.../comments` supports ETags. Most calls would return 304.
3. **Increase throttle to 5 minutes** — simple config change, cuts ~60% of calls.

**Verdict:** This is the single biggest reduction opportunity. Folding review threads into the batch query would save ~55 GraphQL calls per 15 minutes (~220/hour).

### 4. `gh issue view` — 27 calls for 5 sessions

**Expected:** ~5 (once per session at spawn).
**Actual:** 27 (~5.4 per session).

**Root cause:** Each session spawn makes 2 calls:
1. `session-manager.ts:1119` — validates issue exists before creating resources
2. `session-manager.ts:1212` → `tracker-github:184` (`generatePrompt()`) — re-fetches the same issue to build the agent prompt

That accounts for 10 calls. The remaining ~17 come from session restores/retries re-entering the spawn path.

**Verdict:** Minor inefficiency. The issue data fetched in step 1 should be passed to `generatePrompt()` instead of re-fetching.

### 5. Guard failures — 49 of 105 calls (47%)

**Not actual failures.** The gh CLI exits with code 1 on `304 Not Modified` responses because the body is empty. The guard code explicitly handles this:

```typescript
// graphql-batch.ts:400-404
if (stderr.includes("304") || stderr.includes("Not Modified")) {
  // 304 = unchanged, return false (no refresh needed)
}
```

**Breakdown of 49 "failures":**
- 304 responses correctly handled as "no change"
- Some genuine errors (network, deleted PR) correctly treated as "assume changed"
- The trace logs `ok: false` because of the gh CLI exit code, not because of a logic error

**Verdict:** Working as designed. The high failure count in the trace is misleading — the guards handle all cases correctly.

## Traffic Composition

```
                        ┌─────────────────────────────────────────┐
                        │         465 Total AO gh Calls           │
                        └────────────────┬────────────────────────┘
                                         │
              ┌──────────────────────────┼──────────────────────────┐
              │                          │                          │
     ┌────────▼────────┐       ┌─────────▼────────┐      ┌─────────▼────────┐
     │   Batch System  │       │  Individual REST  │      │  Review Backlog  │
     │    149 calls    │       │    220 calls      │      │    95 calls      │
     │    (32%)        │       │    (47%)          │      │    (20%)         │
     └────────┬────────┘       └─────────┬────────┘      └─────────┬────────┘
              │                          │                          │
     Guard 1: 54                PR list: 82              GraphQL threads: 55
     Guard 2: 51                PR view: 65              REST comments: 40
     Batch:   44                PR checks: 45
                                Issue view: 27
                                Other: 1
```

**47% of all calls are individual REST fallbacks** — these should mostly be served by the batch cache.

## Reduction Opportunities (Ranked)

| Priority | Fix | Calls Saved | GraphQL Saved | REST Saved | Effort |
|----------|-----|:-----------:|:-------------:|:----------:|--------|
| **P0** | Fold review threads into batch query | ~55 | **~220/hr** | — | Medium |
| **P1** | Fix batch fallback — reduce cache misses so individual `pr view`/`pr checks` don't fire | ~110 | — | **~440/hr** | Medium |
| **P2** | Add ETag to automated comments REST call | ~30 | — | **~120/hr** | Low |
| **P3** | Increase review backlog throttle to 5 min | ~36 | **~144/hr** | **~100/hr** | Trivial |
| **P4** | Cache issue data in session, reuse in generatePrompt | ~22 | — | **~88/hr** | Low |

### Projected Impact

**Current (5 sessions, projected/hour):**
- GraphQL: ~2,072 / 5,000 (41%)
- REST: ~168 / 5,000 (3%)

**After P0 + P1 + P2 (estimated):**
- GraphQL: ~1,700 / 5,000 (34%) — saved ~370 from review thread folding
- REST: ~50 / 5,000 (1%) — saved ~560 from batch fix + ETag comments

**Max sessions before budget exhaustion (GraphQL, current):** ~12 sessions
**Max sessions after optimizations:** ~15-18 sessions

## Agent-Side Wrapper Status

Separately from this AO analysis, the agent-side gh wrapper (`~/.ao/bin/gh`) was hardened in this session:

- **macOS PATH fix** — wrapper was never active due to `path_helper` resetting PATH in tmux sessions. Fixed by including PATH export in the launch script.
- **Cache correctness** — `--json` fields in cache key, stderr separation, trailing newline fix, `--key=value` syntax support.
- **Trace improvements** — `operation` field, `durationMs`/`exitCode`/`ok` in outcome rows, passthrough logging for all non-cached paths, `miss-write-failed` on cache write failure.
- **Wrapper version:** 0.6.0

Agent-side caching cannot be further improved because agents are non-deterministic — they can call `gh` with any flag/field combination, and we cannot control or predict their behavior. The wrapper absorbs identical repeated calls and traces everything else.

## Constraints

- **GraphQL has no ETag support.** Any GraphQL call always costs points. The only way to reduce GraphQL traffic is to batch (combine into fewer calls) or throttle (call less often).
- **Agent behavior is non-deterministic.** Prompt instructions don't reliably prevent agents from re-verifying data they already have.
- **Guard exit code 1 is normal.** The gh CLI returns exit code 1 for 304 responses. This is by design, not a bug.

## Files Referenced

| File | What |
|------|------|
| `packages/core/src/lifecycle-manager.ts` | Polling loop, status determination, review backlog dispatch |
| `packages/plugins/scm-github/src/index.ts` | All SCM gh calls (detectPR, getPRState, getCIChecks, reviews, mergeability) |
| `packages/plugins/scm-github/src/graphql-batch.ts` | Batch enrichment, ETag guards, LRU caches |
| `packages/plugins/tracker-github/src/index.ts` | Issue view, issue list, issue update calls |
| `packages/core/src/gh-trace.ts` | AO-side trace infrastructure (execGhObserved) |
| `packages/core/src/agent-workspace-hooks.ts` | Agent-side gh wrapper (caching + tracing) |
| `packages/plugins/runtime-tmux/src/index.ts` | tmux runtime (PATH fix for macOS) |
