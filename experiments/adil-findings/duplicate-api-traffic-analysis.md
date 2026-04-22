# Duplicate API Traffic Analysis

**Date:** 2026-04-23
**Branch:** `feat/gh-rate-limiting`
**Trace file:** `experiments/out/gh-trace-real-1776874503.jsonl`

## Discovery

A single 30-second poll window contains **34 gh calls** from **three independent sources**, all hitting the same GitHub API for the same PRs.

## The Three Sources

### Source 1: Dashboard Web API (`serialize.ts`)

**File:** `packages/web/src/lib/serialize.ts:302-311`

```typescript
const results = await Promise.allSettled([
  scm.getPRSummary ? scm.getPRSummary(pr) : scm.getPRState(pr).then(...),
  scm.getCIChecks(pr),
  scm.getCISummary(pr),
  scm.getReviewDecision(pr),
  scm.getMergeability(pr),
  scm.getPendingComments(pr),
]);
```

This runs when the SSE endpoint (`packages/web/src/app/api/events/route.ts`) serves session data to the frontend. The SSE fires every **5 seconds** (`packages/web/src/hooks/useSessionEvents.ts`).

**Per PR, per SSE tick:**
- `getPRSummary` / `getPRState` → 1 `gh pr view` call
- `getCIChecks` → 1 `gh pr checks` call
- `getCISummary` → internally calls `getCIChecks` again → 1 more `gh pr checks`
- `getReviewDecision` → 1 `gh pr view` call
- `getMergeability` → calls `getPRState` + `getCISummary` internally → 2-3 more calls
- `getPendingComments` → 1 `gh api graphql` call

**Total: ~6-8 REST/GraphQL calls per PR per SSE tick.**

With 5 PRs and SSE every 5 seconds: **~6-8 calls × 5 PRs × 12 ticks/min = 360-480 calls/min** (theoretical max, throttled in practice by async settling).

**Key problem:** The dashboard does **not** use the batch enrichment cache. It calls individual REST endpoints for every PR, every time, completely independently from the lifecycle manager.

### Source 2: Lifecycle Manager — CLI (`ao start`)

**Created at:** `packages/cli/src/lib/create-session-manager.ts:74`

```typescript
return createLifecycleManager({ config, registry, sessionManager, projectId });
```

Started by the CLI's `ao start` command. Polls every 30 seconds. Uses the batch enrichment system (Guard 1 → Guard 2 → GraphQL batch).

### Source 3: Lifecycle Manager — Web Dashboard

**Created at:** `packages/web/src/lib/services.ts:92-93`

```typescript
const lifecycleManager = createLifecycleManager({ config, registry, sessionManager });
lifecycleManager.start(30_000);
```

The web dashboard creates its **own** lifecycle manager and starts it at 30-second intervals. This is independent from the CLI lifecycle manager. Both run simultaneously against the same sessions.

## Evidence from Trace

### Single 30s Window (16:19:00–16:19:30): 34 calls

```
16:19:03.575  scm-github       graphql       ← Dashboard: review threads PR 178
16:19:03.820  scm-github       pr view       ← Dashboard: PR 179 state
16:19:04.013  scm-github       graphql       ← Dashboard: review threads PR 179
16:19:04.038  scm-github       pr view       ← Dashboard: PR 179 reviewDecision
16:19:04.164  scm-github       pr view       ← Dashboard: PR 178 state
16:19:04.241  scm-github       pr view       ← Dashboard: PR 178 reviewDecision
16:19:04.252  scm-github       pr view       ← Dashboard: PR 179 summary
16:19:04.298  scm-github       pr view       ← Dashboard: PR 178 summary
16:19:04.503  scm-github       pr checks     ← Dashboard: PR 179 CI
16:19:04.558  scm-github       pr checks     ← Dashboard: PR 178 CI
16:19:04.704  scm-github-batch guard-pr-list  ← Lifecycle A: Guard 1
16:19:04.774  scm-github       pr checks     ← Dashboard/Lifecycle fallback
16:19:04.876  scm-github       pr view       ← Dashboard: PR 179 mergeability
16:19:04.876  scm-github       pr view       ← Dashboard: PR 178 mergeability
16:19:05.273  scm-github       pr checks     ← Lifecycle fallback
16:19:06.289  scm-github-batch graphql-batch  ← Lifecycle A: batch query
16:19:06.663  scm-github       pr checks     ← Lifecycle fallback
16:19:06.738  scm-github       pr checks     ← Lifecycle fallback
16:19:07.101  scm-github-batch guard-pr-list  ← Lifecycle B: Guard 1 (3s later)
16:19:07.522  scm-github       repos         ← Lifecycle A: automated comments PR 179
16:19:07.528  scm-github       repos         ← Lifecycle A: automated comments PR 178
16:19:07.535  scm-github       pr list       ← Lifecycle: detectPR
16:19:07.538  scm-github       pr list       ← Lifecycle: detectPR
16:19:07.574  scm-github       graphql       ← Lifecycle A: review threads
16:19:07.585  scm-github       pr list       ← Lifecycle: detectPR
16:19:07.596  scm-github       graphql       ← Lifecycle: review threads
16:19:08.324  scm-github-batch graphql-batch  ← Lifecycle B: batch query
16:19:09.303  scm-github       repos         ← Lifecycle B: automated comments
16:19:09.350  scm-github       repos         ← Lifecycle B: automated comments
16:19:09.382  scm-github       graphql       ← Lifecycle B: review threads
16:19:09.709  scm-github       pr list       ← Lifecycle: detectPR
16:19:09.713  scm-github       graphql       ← Lifecycle B: review threads
16:19:09.714  scm-github       pr list       ← Lifecycle: detectPR
16:19:09.748  scm-github       pr list       ← Lifecycle: detectPR
```

### Guard 1 Pairing Pattern

Guard 1 calls consistently come in **pairs 3 seconds apart** throughout the entire 15-minute trace:

```
16:19:04.704  guard-pr-list  ← Lifecycle A
16:19:07.101  guard-pr-list  ← Lifecycle B (3s later)

16:19:34.539  guard-pr-list  ← Lifecycle A
16:19:37.004  guard-pr-list  ← Lifecycle B (3s later)

16:20:04.530  guard-pr-list  ← Lifecycle A
16:20:06.709  guard-pr-list  ← Lifecycle B (2s later)
```

**54 Guard 1 calls = 27 pairs = 27 cycles.** Should be 27 calls (one per cycle) if only one lifecycle manager existed.

### Aggregate Impact

| Source | Calls / 15 min | % of Total | Uses Batch? | Uses Cache? |
|--------|:--------------:|:----------:|:-----------:|:-----------:|
| Dashboard (`serialize.ts`) | ~150+ | ~32% | No | No |
| Lifecycle Manager A (CLI) | ~155 | ~33% | Yes | Yes |
| Lifecycle Manager B (Web) | ~155 | ~33% | Yes | Yes |
| Tracker | 28 | 6% | No | No |

**~50% of all API traffic is pure duplication** — the second lifecycle manager and the dashboard's individual calls.

## Root Causes

### 1. Dashboard makes its own API calls instead of reading lifecycle cache

**Location:** `packages/web/src/lib/serialize.ts:302-311`

The dashboard's `enrichSessionPR()` function calls `scm.getPRState()`, `scm.getCIChecks()`, `scm.getReviewDecision()`, `scm.getMergeability()`, `scm.getPendingComments()` individually for each PR. It does not read from the lifecycle manager's `prEnrichmentCache`.

**Fix:** The dashboard should read PR enrichment data from the lifecycle manager's cache (which is already populated every 30s by the batch system) instead of making its own API calls.

### 2. Two lifecycle managers poll simultaneously

**Locations:**
- CLI: `packages/cli/src/lib/create-session-manager.ts:74`
- Web: `packages/web/src/lib/services.ts:92-93`

Both create independent `LifecycleManager` instances with separate poll timers, separate ETag caches, and separate batch systems. They poll the same sessions at the same 30s interval, offset by ~3 seconds.

**Fix:** Either:
- The web dashboard should not create its own lifecycle manager — it should reuse the one from the CLI process (if they share a process)
- Or if they're separate processes, only one should run the lifecycle poll loop. The other reads state from shared storage (session metadata files).

### 3. Dashboard `getPendingComments` is an additional GraphQL call

**Location:** `packages/web/src/lib/serialize.ts:310`

```typescript
scm.getPendingComments(pr),
```

This is the same GraphQL review threads query that the lifecycle manager already runs every 2 minutes. The dashboard calls it on every SSE tick (5s), multiplied by number of PRs.

## Full Cache Architecture — Three Caches, Zero Shared State

The CLI and web dashboard run as **separate Node.js processes**. Each creates its own full plugin stack. No cache is shared across processes.

### Cache Layer 1: Batch Enrichment (per lifecycle manager)

**Files:**
- `packages/plugins/scm-github/src/graphql-batch.ts` — ETag caches + PR enrichment data cache
- `packages/core/src/lifecycle-manager.ts:322` — `prEnrichmentCache` (cleared and rebuilt every poll cycle)

| Cache | What | Scope |
|-------|------|-------|
| `etagCache.prList` | ETag strings per repo | LRU, 100 entries |
| `etagCache.commitStatus` | ETag strings per commit SHA | LRU, 500 entries |
| `prMetadataCache` | headSha + ciStatus per PR | LRU, 200 entries |
| `prEnrichmentDataCache` | Full PR enrichment data | LRU, 200 entries |
| `prEnrichmentCache` | Map rebuilt from above each cycle | Cleared every 30s |

**CLI process has one copy. Web process has another. They never share.**

### Cache Layer 2: SCM Plugin Per-Method TTL Cache

**File:** `packages/plugins/scm-github/src/index.ts:464-476`

Each `createGitHubSCM()` call creates an isolated `prCache` Map (line 483). Every method (`getPRState`, `getCIChecks`, etc.) is wrapped with `withPRCache()` (line 518) that checks/writes this cache.

| Method | TTL |
|--------|-----|
| `getPRState` | 5s |
| `getPRSummary` | 5s |
| `getCIChecks` | 5s |
| `getMergeability` | 5s |
| `getReviewDecision` | 10s |
| `getPendingComments` | 10s |
| `getReviews` | 10s |
| `detectPR` | 30s |
| `resolvePR` | 60s |

**The web process registers its own SCM plugin** (`packages/web/src/lib/services.ts:84`) which creates a separate `createGitHubSCM()` instance with its own `prCache`. The CLI's SCM plugin cache is invisible to the web process and vice versa.

### Cache Layer 3: Dashboard PR Cache

**File:** `packages/web/src/lib/cache.ts:109`

| Cache | What | TTL |
|-------|------|-----|
| `prCache` | PR enrichment data for dashboard display | 5 min (default), 60 min if rate-limited |
| `issueTitleCache` | Issue titles | 5 min |

Only exists in the web process. Fills by calling the web process's SCM plugin (which calls GitHub API independently). Every 5 minutes, all entries expire and trigger a burst of API calls.

### The Duplication

```
┌─────────────────────────────────────────────────────────┐
│                    GitHub API                            │
└────────────────────────┬────────────────────────────────┘
                         │
         ┌───────────────┴───────────────┐
         │                               │
   SCM Plugin Cache              SCM Plugin Cache
   (5-30s TTL)                   (5-30s TTL)
   OWN INSTANCE                  OWN INSTANCE
         │                               │
   ┌─────┴─────┐                   ┌─────┴─────┐
   │           │                   │           │
Batch LRU   LC enrichment      Batch LRU   Dashboard
+ ETag      cache               + ETag      TTL cache
caches      (per cycle)         caches      (5 min)
   │           │                   │           │
Lifecycle   Lifecycle           Lifecycle   Dashboard
Manager     Manager             Manager     serialize.ts
(CLI)       (ignored -          (Web)
            web has own)
```

**Every component in the right column is a complete duplicate of the left column**, hitting the same GitHub API for the same PRs with the same fields. The web process creates:
- Its own plugin registry (`services.ts:75`)
- Its own SCM plugin instance (`services.ts:84`)
- Its own lifecycle manager (`services.ts:92`)
- Its own session manager (`services.ts:88`)
- Plus the dashboard's own `prCache` on top

**Total independent plugin stacks:**

| Component | CLI Process | Web Process |
|-----------|:-----------:|:-----------:|
| Plugin registry | Own instance | Own instance |
| SCM plugin + prCache | Own instance | Own instance |
| Lifecycle manager + batch caches | Own instance | Own instance |
| Session manager | Own instance | Own instance |
| Dashboard prCache | — | Own instance |

Two processes, two full stacks, zero shared state, double the API traffic.

## Revised Call Attribution (465 total)

| Operation | Dashboard | Lifecycle A | Lifecycle B | Total |
|-----------|:---------:|:-----------:|:-----------:|:-----:|
| `gh pr view` | ~30 | ~18 | ~17 | 65 |
| `gh pr checks` | ~20 | ~13 | ~12 | 45 |
| `gh pr list` | 0 | ~41 | ~41 | 82 |
| `gh api graphql` (review threads) | ~15 | ~20 | ~20 | 55 |
| `gh api repos` (automated comments) | 0 | ~20 | ~20 | 40 |
| `gh api guard-pr-list` | 0 | ~27 | ~27 | 54 |
| `gh api guard-commit-status` | 0 | ~26 | ~25 | 51 |
| `gh api graphql-batch` | 0 | ~22 | ~22 | 44 |
| `gh issue view` | ~10 | ~9 | ~8 | 27 |
| Other | 0 | 1 | 1 | 2 |
| **Total** | **~75** | **~197** | **~193** | **465** |

## Impact on Rate Limit Budget

**Current (all three sources):**
- GraphQL: 518 consumed / 15 min → **2,072/hr** (41% of 5,000)
- REST: 42 consumed / 15 min → **168/hr** (3% of 5,000)

**If deduplicated (single lifecycle + dashboard reads cache):**
- GraphQL: ~260 / 15 min → **~1,040/hr** (21% of 5,000) — **50% reduction**
- REST: ~21 / 15 min → **~84/hr** (2% of 5,000) — **50% reduction**

## Files Referenced

| File | Line | What |
|------|------|------|
| `packages/web/src/lib/serialize.ts` | 302-311 | Dashboard PR enrichment — individual API calls per PR |
| `packages/web/src/lib/services.ts` | 92-93 | Web lifecycle manager creation + start |
| `packages/web/src/app/api/events/route.ts` | — | SSE endpoint serving session data |
| `packages/web/src/hooks/useSessionEvents.ts` | — | SSE consumer (5s interval) |
| `packages/cli/src/lib/create-session-manager.ts` | 74 | CLI lifecycle manager creation |
| `packages/core/src/lifecycle-manager.ts` | 341-389 | `populatePREnrichmentCache` + batch call |
| `packages/core/src/lifecycle-manager.ts` | 1862-1886 | `pollAll()` main loop |
| `packages/plugins/scm-github/src/graphql-batch.ts` | 925-1053 | `enrichSessionsPRBatch` |
| `packages/plugins/scm-github/src/graphql-batch.ts` | 187-265 | `shouldRefreshPREnrichment` (Guard 1 + Guard 2) |
