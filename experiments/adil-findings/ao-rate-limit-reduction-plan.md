# AO-Side Rate-Limit Reduction Plan

**Date:** 2026-04-22
**Branch:** `feat/gh-rate-limiting`
**Based on:** [gh-rate-limit-trace-report.md](./gh-rate-limit-trace-report.md)

## Context

5-session, 15-minute trace showed 465 AO-side gh calls. GraphQL budget consumption projected at **41%/hour with just 5 sessions** — the bottleneck that limits scaling to ~12 sessions before exhausting the hourly budget.

The biggest contributors to unnecessary traffic:

| Source | Calls (15 min) | % of Total | Root Cause |
|--------|:--------------:|:----------:|------------|
| Individual `pr view` fallback | 65 | 14% | Batch cache miss → 5 individual REST calls per PR |
| Individual `pr checks` fallback | 45 | 10% | Same — fallback path from batch miss |
| Review threads (GraphQL) | 55 | 12% | Standalone query every 2 min, not in batch |
| Automated comments (REST) | 40 | 9% | Standalone fetch every 2 min, no ETag |

## Step 1: Remove individual REST fallback from `determineStatus()`

### What

Remove the fallback code path at `lifecycle-manager.ts:765-810` that makes individual `getPRState()`, `getCISummary()`, `getReviewDecision()`, and `getMergeability()` REST calls when the batch enrichment cache misses.

### Why

- **110 calls eliminated** (65 `pr view` + 45 `pr checks`) — 24% of all traffic.
- **169 seconds of wall time saved** per 15-minute window.
- The batch enrichment runs every 30 seconds. If it misses a PR in one cycle, it picks it up in the next. A 30-second delay in status detection is acceptable — agents don't operate at sub-minute precision.
- **Zero batch failures occurred** in the real 15-minute trace. All 44 batch calls succeeded. The fallback is insurance for an event that didn't happen once.
- Even if the batch fails, the session status stays at its last known value. The agent keeps working. The next cycle (30s later) retries the batch. The fallback has the same limitation during a GitHub outage — individual REST calls would also fail.

### What happens without fallback

```
Poll cycle N:
  1. Batch enrichment runs → cache populated for PRs
  2. determineStatus() checks cache → hit → uses cached data ✓

Poll cycle N (cache miss — PR just created or batch failed):
  1. Batch enrichment runs → PR not in cache (or batch failed)
  2. determineStatus() checks cache → miss → no fallback
  3. Falls through to agent report path (line 824+)
     - If agent reported state → uses agent report
     - If no agent report → status stays unchanged
  4. Session remains at current status for this cycle

Poll cycle N+1 (30 seconds later):
  1. Batch enrichment runs again → PR now in cache ✓
  2. determineStatus() → cache hit → correct status
```

**Worst case:** 30-second delay in detecting a state change (PR merged, CI failed, review approved). None of these are time-critical.

### Risk assessment

| Scenario | Impact | Likelihood |
|----------|--------|------------|
| Batch fails once, recovers next cycle | 30s delay | Low (0 failures in 15-min trace) |
| Batch fails repeatedly (GitHub outage) | Status stale until recovery | Very low — and fallback would also fail |
| PR just created, not yet in batch | 30s delay on first detection | Expected — happens once per session |
| GraphQL rate limit hit, REST still available | Can't fall back to REST | Unlikely at current volumes |

### Code changes

Remove fallback paths in **all three functions** that fall back to individual REST calls on batch cache miss:

#### 1. `determineStatus()` — lines 765-810

**File:** `packages/core/src/lifecycle-manager.ts`

Remove the individual `getPRState` + `getCISummary` + `getReviewDecision` + `getMergeability` fallback block (~45 lines). When `cachedData` is null, the function falls through to the agent report path (line 824+) or keeps the previous status.

```typescript
if (cachedData) {
  return commit(resolvePREnrichmentDecision(cachedData, { ... }));
}

// No fallback — batch will populate cache on next cycle (30s).
// Status stays unchanged for this cycle.
```

#### 2. `maybeDispatchCIFailureDetails()` — lines 1357-1363

Remove the `scm.getCIChecks(session.pr)` fallback. If `cachedEnrichment?.ciChecks` is undefined, skip the dispatch for this cycle.

```typescript
if (cachedEnrichment?.ciChecks !== undefined) {
  checks = cachedEnrichment.ciChecks;
} else {
  return; // batch will have it next cycle
}
```

#### 3. `maybeDispatchMergeConflicts()` — lines 1486-1492

Remove the `scm.getMergeability(session.pr)` fallback (3-4 REST calls). If `cachedData` is null, skip conflict detection for this cycle.

```typescript
if (cachedData) {
  hasConflicts = cachedData.hasConflicts ?? false;
} else {
  return; // batch will have it next cycle
}
```

### Expected impact

| Metric | Before | After |
|--------|--------|-------|
| Individual `pr view` calls / 15 min | 65 | 0 |
| Individual `pr checks` calls / 15 min | 45 | 0 |
| Total calls / 15 min | 465 | ~355 |
| REST consumed / 15 min | 42 | ~20 |
| Wall time in gh calls | 564s | ~395s |

---

## Step 2: Eliminate REST automated comments call — use single GraphQL for all review comments

### What

Remove `getAutomatedComments()` (REST call) entirely. The existing `getPendingComments()` GraphQL call already fetches **all** review threads (human + bot) via `reviewThreads(first: 100)`. Both calls currently fetch overlapping data and filter to opposite sides:

- `getPendingComments` (GraphQL) → fetches all threads → keeps human, discards bot
- `getAutomatedComments` (REST) → fetches all comments → keeps bot, discards human

Replace with a single GraphQL call that returns both, split locally in the lifecycle manager.

### Why

- **40 REST calls eliminated** per 15 minutes (the entire `getAutomatedComments` REST pagination loop).
- **No data loss.** The GraphQL `reviewThreads` query returns the same fields the REST call provides (author, body, path, line, url), plus `isResolved` which REST doesn't have.
- The REST call fetches ALL comments (human + bot) just to keep bots — wasteful for PRs with many human comments.

### How

1. **Modify `getPendingComments()`** to return both human and bot comments (or split into two arrays). Currently filters out bots at line 971:
   ```typescript
   return !BOT_AUTHORS.has(author);  // ← remove this filter
   ```

2. **Lifecycle manager splits locally** — the consumer at `lifecycle-manager.ts:1157-1160` receives one response and partitions by author:
   - `BOT_AUTHORS.has(author)` → automated comments pipeline (fingerprint + reaction)
   - `!BOT_AUTHORS.has(author)` → human comments pipeline (fingerprint + reaction)

3. **Remove `getAutomatedComments()`** from `scm-github/index.ts` and its REST pagination loop (lines 992-1066).

4. **Update the SCM interface** in `types.ts` if `getAutomatedComments` is part of the interface contract.

### Include comment data in agent reaction message

Currently the reaction messages are static strings that **tell the agent to call `gh`** to fetch comments:

```
"There are review comments on your PR. Check with `gh pr view --comments`
and `gh api` for inline comments. Address each one, push fixes, and reply."
```

This causes the agent to make redundant `gh` read calls for data AO already has.

**Fix:** Construct the reaction message with actual comment data inline:

```
The following review comments are unresolved on your PR (as of just now).
You should not need to re-fetch this data unless you need additional context.

1. src/auth.ts:42 (@reviewer): "Fix error handling here"
   https://github.com/org/repo/pull/57#discussion_r12345

2. src/utils.ts:15 (@reviewer): "This should be async"
   https://github.com/org/repo/pull/57#discussion_r12346
```

**Key design decisions:**
- Provide thread URL so the agent can reply/interact if it chooses to
- Don't prescribe response behavior (e.g., "reply to each thread") — let the agent decide how to acknowledge the review
- Don't block the agent from calling `gh` — just say "you should not need to" in case something breaks or it needs additional context
- Same approach for bot comments — include the bot findings inline

### Code changes

| File | Change |
|------|--------|
| `packages/plugins/scm-github/src/index.ts` | Modify `getPendingComments()` to return all threads (human + bot). Remove `getAutomatedComments()`. |
| `packages/core/src/types.ts` | Update SCM interface if `getAutomatedComments` is in the contract |
| `packages/core/src/lifecycle-manager.ts` | Split combined response into human/bot locally. Build reaction message with comment data instead of static string. |
| `packages/core/src/config.ts` | Update default reaction messages (remove "check with `gh pr view`" instruction) |

### Expected impact

| Metric | Before | After Step 1+2 |
|--------|--------|----------------|
| REST automated comment calls / 15 min | 40 | 0 |
| GraphQL review thread calls / 15 min | 55 | 55 (unchanged — same call, now serves both) |
| Agent-side `gh` read calls for reviews | ~10-20 per session | ~0 (data provided inline) |
| Total calls / 15 min | ~355 (after Step 1) | ~315 |

---

## Future Steps (not yet planned in detail)

### Step 3: Increase review backlog throttle
Change `REVIEW_BACKLOG_THROTTLE_MS` from 2 minutes to 5 minutes. Simple config change, cuts ~60% of review backlog traffic. Would reduce the 55 GraphQL calls to ~22.

### Step 4: Cache issue data in session metadata
Pass issue data from initial fetch to `generatePrompt()` instead of re-fetching. Saves ~22 `gh issue view` calls per 15 minutes.

### Step 5: Remove unused `reviews(last: 5)` from batch query
The batch GraphQL query fetches `reviews(last: 5)` with author, state, submittedAt — but this data is never consumed after a validation check. The `reviewDecision` scalar field already provides what AO needs. Removing it reduces GraphQL complexity cost per batch call.
