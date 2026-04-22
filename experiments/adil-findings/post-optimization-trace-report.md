# Post-Optimization Trace Report

**Date:** 2026-04-23
**Branch:** `feat/gh-rate-limiting`
**Trace file:** `experiments/out/gh-trace-real-1776897471.jsonl` ([gist](https://gist.github.com/iamasx/797f36fda8a88f6babad48c735bbea53))
**Applied optimizations:** Step 1 (remove REST fallback), Step 2 (consolidate review comments), Step 3 (remove dead reviews field)

## Test Conditions

| Parameter | Value |
|-----------|-------|
| Sessions | 5 |
| Duration | 17 min 13 sec (22:39 – 22:56 UTC) |
| Repo | iamasx/api-test |
| Issues | #171, #172, #173, #174, #175 |
| PRs created | #183, #184, #185 (2 sessions never created PRs) |
| Poll interval | 30 seconds |

## Rate-Limit Budget Consumed

| Budget | Before | After | Consumed | Projected/hour |
|--------|--------|-------|----------|----------------|
| **GraphQL** (5,000/hr) | 6 used | 501 used | **495** | **~1,727** (35%) |
| **REST** (5,000/hr) | 2 used | 5 used | **3** | **~10** (<1%) |

## Call Summary (442 total)

| Operation | Calls | Total Time | Avg Latency | Source |
|-----------|------:|----------:|------------:|--------|
| `gh pr list` (detectPR) | 200 | 227.7s | 1,138ms | Lifecycle (both) |
| `gh pr view` (individual) | 52 | 94.8s | 1,823ms | Dashboard |
| `gh api guard-commit-status` | 38 | 53.5s | 1,406ms | Lifecycle (both) |
| `gh api guard-pr-list` | 36 | 46.7s | 1,298ms | Lifecycle (both) |
| `gh pr checks` (individual) | 30 | 86.4s | 2,879ms | Dashboard |
| `gh issue view` | 27 | 62.8s | 2,326ms | Tracker |
| `gh api graphql` (review threads) | 27 | 45.3s | 1,677ms | Lifecycle (both) |
| `gh api graphql-batch` | 26 | 37.7s | 1,451ms | Lifecycle (both) |
| `gh pr merge` | 5 | 20.6s | 4,111ms | Lifecycle |
| `gh issue list` | 1 | 1.0s | 957ms | Tracker |

**Total wall time spent in gh calls:** 676.5 seconds (11.3 minutes of the 17.2-minute window).

## Call Attribution by Source

### Source 1: Dashboard (`serialize.ts`) — 82 calls (19%)

The web dashboard's `enrichSessionPR()` at `packages/web/src/lib/serialize.ts:302-311` makes individual REST calls for each PR on every SSE-triggered refresh (~every 15 seconds, gated by 5-minute TTL cache).

| Operation | Calls | What |
|-----------|------:|------|
| `gh pr view` | 52 | PR state, summary, reviewDecision, mergeability |
| `gh pr checks` | 30 | CI check details |

These calls come in bursts at the start of poll windows, before any guard/batch call. The dashboard does not use the lifecycle manager's batch enrichment cache.

### Source 2: Lifecycle Manager A (CLI) — ~155 calls (35%)

Started by `ao start` via `packages/cli/src/lib/lifecycle-service.ts:46`.

| Operation | Calls | What |
|-----------|------:|------|
| `gh pr list` (detectPR) | ~100 | PR discovery for sessions without PRs |
| `gh api guard-pr-list` | ~18 | ETag Guard 1 (per repo per cycle) |
| `gh api guard-commit-status` | ~19 | ETag Guard 2 (per PR when Guard 1 returns 304) |
| `gh api graphql-batch` | ~13 | Batch enrichment when guards detect changes |
| `gh api graphql` (review threads) | ~14 | `getReviewThreads()` every 2 minutes per PR |

### Source 3: Lifecycle Manager B (Web dashboard) — ~155 calls (35%)

Started by `packages/web/src/lib/services.ts:92-93`. Identical to Lifecycle A, offset by ~2-3 seconds.

| Operation | Calls | What |
|-----------|------:|------|
| `gh pr list` (detectPR) | ~100 | Same PRs, same branches, 3 seconds later |
| `gh api guard-pr-list` | ~18 | Same repo, same ETag, redundant |
| `gh api guard-commit-status` | ~19 | Same commits, same ETag, redundant |
| `gh api graphql-batch` | ~13 | Same query, same data, redundant |
| `gh api graphql` (review threads) | ~13 | Same threads, same data, redundant |

### Source 4: Tracker — 28 calls (6%)

| Operation | Calls | What |
|-----------|------:|------|
| `gh issue view` | 27 | Issue context fetches (2 per spawn + restores) |
| `gh issue list` | 1 | One-off issue listing |

### Source 5: Actions — 5 calls (1%)

| Operation | Calls | What |
|-----------|------:|------|
| `gh pr merge` | 5 | PR merge operations (one per merged session) |

## ETag Guard Performance

| Guard | 304 (saved) | 200 (needed) | Failed | Total | Hit Rate |
|-------|:-----------:|:------------:|:------:|:-----:|:--------:|
| PR list (Guard 1) | 16 | 20 | 16 | 36*| 44% |
| Commit status (Guard 2) | 28 | 10 | 28 | 38*| 74% |

*Failed guards: exit code 1 from `gh api` on 304 responses — handled correctly, not actual errors.

**Guard 1** still shows 4 calls per minute (2 per lifecycle manager per 30s cycle). Confirms dual lifecycle is active.

**Guard 2** shows strong 74% hit rate — most CI status checks return unchanged. When Guard 1 returns 304 (no PR list changes), Guard 2 correctly detects CI-only changes.

## detectPR Analysis (200 calls)

`detectPR()` calls `gh pr list --head <branch> --limit 1` every cycle for sessions without PRs.

| Branch | Calls | Created PR? |
|--------|------:|:-----------:|
| feat/issue-174 | 69 | No |
| feat/issue-171 | 69 | No |
| feat/issue-172 | 24 | Yes (later) |
| feat/issue-173 | 13 | Yes (later) |
| feat/issue-175 | 11 | Yes (later) |
| feat/175 | 10 | Alternate branch |
| package-lock.json | 2 | Misdetected branch |
| feat/173 | 2 | Alternate branch |

Two sessions (feat/issue-174, feat/issue-171) never created PRs during the 17-minute window. Each was polled every 30s by both lifecycle managers: 17 min × 2 calls/min × 2 lifecycles ≈ 68 calls each. Matches the observed 69.

**This is the single largest traffic source (200 of 442 calls = 45%)** and is unavoidable until the agent creates a PR. The dual lifecycle doubles it.

## Review Thread Analysis (27 calls)

After Step 2 consolidation, review threads are fetched via a single `getReviewThreads()` GraphQL call (no separate REST `getAutomatedComments`).

- 27 GraphQL calls in 17 minutes = ~1.6 calls/min
- 5 sessions × 2 lifecycles × (17 min / 2 min throttle) ≈ ~42 expected
- Lower than expected because not all sessions had PRs for the full duration and throttle is per-session

**REST automated comment calls: 0** (eliminated by Step 2).

## Duration Analysis

| Operation | Total Time | % of wall time |
|-----------|----------:|:--------------:|
| `gh pr list` (detectPR) | 227.7s | 33.7% |
| `gh pr view` (dashboard) | 94.8s | 14.0% |
| `gh pr checks` (dashboard) | 86.4s | 12.8% |
| `gh issue view` | 62.8s | 9.3% |
| `gh api guard-commit-status` | 53.5s | 7.9% |
| `gh api guard-pr-list` | 46.7s | 6.9% |
| `gh api graphql` (review threads) | 45.3s | 6.7% |
| `gh api graphql-batch` | 37.7s | 5.6% |
| `gh pr merge` | 20.6s | 3.0% |
| `gh issue list` | 1.0s | 0.1% |
| **Total** | **676.5s** | **100%** |

60% of gh wall time is spent on `detectPR` (34%) and dashboard individual calls (27%). Both are targets for the shared enrichment plan.

## Error Analysis

| Error | Count | Cause |
|-------|------:|-------|
| `gh.api.guard-commit-status` | 28 | Exit code 1 on 304 Not Modified (expected, handled correctly) |
| `gh.api.guard-pr-list` | 16 | Same — 304 response exits with code 1 |
| `gh.pr.merge` | 2 | Merge failures (likely branch protection or CI still running) |

No genuine API errors. All guard "failures" are normal 304 handling.

## Traffic Composition

```
                    442 Total AO gh Calls
                           │
     ┌─────────────────────┼─────────────────────┐
     │                     │                     │
 Dashboard             Lifecycle A          Lifecycle B
  82 calls              ~155 calls           ~155 calls
  (19%)                 (35%)                (35%)
     │                     │                     │
 pr view: 52          pr list: ~100         pr list: ~100
 pr checks: 30        guards: ~37          guards: ~37
                      batch: ~13           batch: ~13
                      graphql: ~14         graphql: ~13
                                                 │
                                            ┌────┘
                                         Tracker
                                         28 calls (6%)
                                         Actions: 5 (1%)
```

**Dashboard (19%) + Lifecycle B (35%) = 54% of traffic is redundant.** Lifecycle B is a complete duplicate of Lifecycle A. Dashboard makes individual calls for data that Lifecycle A already has in its batch cache.

## Remaining Reduction Opportunities

| Fix | Calls eliminated | Impact |
|-----|:----------------:|--------|
| Remove web's lifecycle manager (shared enrichment plan) | ~155 | Guards, batch, review threads — all duplicated |
| Dashboard reads from lifecycle cache (shared enrichment plan) | ~82 | Individual pr view/checks eliminated |
| **Total** | **~237** | **54% of all traffic** |

After these fixes, projected traffic: ~205 calls / 17 min, dominated by `detectPR` (unavoidable) and legitimate lifecycle polling.

## Files Referenced

| File | What |
|------|------|
| `packages/web/src/lib/serialize.ts:302-311` | Dashboard individual API calls |
| `packages/web/src/lib/services.ts:92-93` | Web lifecycle manager (duplicate) |
| `packages/core/src/lifecycle-manager.ts:1116` | `getReviewThreads()` call (Step 2) |
| `packages/core/src/lifecycle-manager.ts:755` | Batch cache check (Step 1 — no fallback) |
| `packages/plugins/scm-github/src/graphql-batch.ts:479` | Batch query fields (Step 3 — reviews removed) |
| `packages/plugins/scm-github/src/index.ts:996` | `getReviewThreads()` implementation |
