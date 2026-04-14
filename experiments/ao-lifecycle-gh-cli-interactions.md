# AO Lifecycle Manager — Every `gh` CLI Interaction Per Poll Cycle

> Complete reference of every GitHub API call the lifecycle manager makes during a single poll loop.
> Source: `packages/core/src/lifecycle-manager.ts` + `packages/plugins/scm-github/src/`

---

## Architecture Overview

```
pollAll()
  │
  ├── Phase 1: populatePREnrichmentCache()     ← ONCE for all sessions
  │     ├── ETag Guard 1 (per repo)
  │     ├── ETag Guard 2 (per PR)
  │     └── GraphQL Batch Query
  │
  ├── Phase 2: checkSession() × N              ← per session
  │     └── determineStatus()
  │           ├── PR Auto-Detect
  │           └── Fallback Individual Calls
  │
  ├── Phase 3: maybeDispatchReviewBacklog() × N ← per session (throttled 2min)
  │     ├── getPendingComments (GraphQL)
  │     └── getAutomatedComments (REST paginated)
  │
  ├── Phase 4: maybeDispatchCIFailureDetails() × N  ← per session (ci_failed only)
  │
  └── Phase 5: maybeDispatchMergeConflicts() × N    ← per session (open PRs)
```

---

## Phase 1 — Batch PR Enrichment

**Runs:** Once per poll cycle, across ALL sessions.

**Goal:** Fetch PR state, CI status, review decision, and merge readiness for every active PR in as few API calls as possible.

---

### Call 1 — ETag Guard 1: PR List Check

```
gh api --method GET \
  "repos/{owner}/{repo}/pulls?state=open&sort=updated&direction=desc&per_page=1" \
  -i \
  [-H "If-None-Match: {cached_etag}"]
```

| Field | Value |
|-------|-------|
| **When** | Once per repo per poll |
| **Purpose** | Detect if any PR in the repo changed (new commits, reviews, title edits, state changes) |
| **304 response** | Nothing changed → skip GraphQL entirely. Cost: 0 points |
| **200 response** | Something changed → proceed to GraphQL batch. Cost: 1 REST point |
| **Source** | `graphql-batch.ts:336-381` |

**What it catches:** PR metadata changes (commits, reviews, labels, state)  
**What it misses:** CI status changes (handled by Guard 2)

---

### Call 2 — ETag Guard 2: Commit Status Check

```
gh api --method GET \
  "repos/{owner}/{repo}/commits/{sha}/status" \
  -i \
  [-H "If-None-Match: {cached_etag}"]
```

| Field | Value |
|-------|-------|
| **When** | Per PR, only when Guard 1 returned 304 (no PR changes) AND we have a cached head SHA |
| **Purpose** | Detect CI status transitions (failing→passing, passing→failing, pending→done) |
| **304 response** | CI unchanged → skip GraphQL. Cost: 0 points |
| **200 response** | CI changed → proceed to GraphQL batch. Cost: 1 REST point |
| **Source** | `graphql-batch.ts:394-440` |

---

### Call 3 — GraphQL Batch Query

```
gh api graphql \
  -f pr0Owner={owner} -f pr0Name={repo} -F pr0Number={num} \
  -f pr1Owner={owner} -f pr1Name={repo} -F pr1Number={num} \
  ... \
  -f query="query BatchPRs(...) {
    pr0: repository(owner: $pr0Owner, name: $pr0Name) {
      ... on Repository {
        pullRequest(number: $pr0Number) {
          state, title, additions, deletions, isDraft,
          mergeable, mergeStateStatus, reviewDecision,
          headRefName, headRefOid,
          reviews(last: 5) { nodes { author { login }, state, submittedAt } }
          commits(last: 1) { nodes { commit { statusCheckRollup {
            state, contexts(first: 20) { nodes {
              ... on CheckRun { name, status, conclusion, detailsUrl }
              ... on StatusContext { context, state, targetUrl }
            } }
          } } } }
        }
      }
    }
    ...
  }"
```

| Field | Value |
|-------|-------|
| **When** | Only when Guard 1 or Guard 2 detected changes |
| **Batch size** | Max 25 PRs per query. If more, splits into multiple batches |
| **Timeout** | 30s base + 2s per PR beyond first 10 |
| **What it fetches** | PR state, CI status + individual checks, review decision, merge readiness, head SHA — all in ONE call |
| **Source** | `graphql-batch.ts:500-594` |

**This replaces 3 individual REST calls per PR** (getPRState + getCISummary + getReviewDecision).

---

## Phase 2 — Per-Session Status Detection

**Runs:** For each active session via `determineStatus()`.

These calls are the **fallback path** — only execute when Phase 1's batch enrichment didn't return data for this PR.

---

### Call 4 — PR Auto-Detect

```
gh pr list \
  --repo {owner}/{repo} \
  --head {branch} \
  --json number,url,title,headRefName,baseRefName,isDraft \
  --limit 1
```

| Field | Value |
|-------|-------|
| **When** | Session has NO PR metadata + has a branch + not an orchestrator session |
| **Purpose** | Find if a PR exists for this session's branch name |
| **Runs once** | Once detected, PR URL is persisted to session metadata — never called again |
| **Source** | `scm-github/src/index.ts:517-549` |

---

### Calls 5–8 — Individual Fallback (only when batch cache miss)

These only run when `prEnrichmentCache` has no data for this PR.

---

#### Call 5 — Get PR State

```
gh pr view {number} \
  --repo {owner}/{repo} \
  --json state
```

| Field | Value |
|-------|-------|
| **When** | No batch data for this PR |
| **Purpose** | Is PR open, merged, or closed? |
| **Returns** | `merged` → session done. `closed` → session killed. `open` → continue checks |
| **Source** | `scm-github/src/index.ts:593-608` |

---

#### Call 6 — Get CI Summary

```
gh pr checks {number} \
  --repo {owner}/{repo} \
  --json name,state,link,startedAt,completedAt
```

| Field | Value |
|-------|-------|
| **When** | PR is open, no batch data |
| **Purpose** | Are CI checks passing, failing, or pending? |
| **Fallback** | If `gh pr checks` fails with "unknown json field", falls back to: |
| | `gh pr view {number} --repo {owner}/{repo} --json statusCheckRollup` |
| **Source** | `scm-github/src/index.ts:646-684` |

---

#### Call 7 — Get Review Decision

```
gh pr view {number} \
  --repo {owner}/{repo} \
  --json reviewDecision
```

| Field | Value |
|-------|-------|
| **When** | PR is open, no batch data |
| **Purpose** | Is PR approved, changes requested, or pending review? |
| **Returns** | `APPROVED`, `CHANGES_REQUESTED`, `REVIEW_REQUIRED`, or `NONE` |
| **Source** | `scm-github/src/index.ts:757-774` |

---

#### Call 8 — Get Merge Readiness

```
gh pr view {number} \
  --repo {owner}/{repo} \
  --json mergeable,reviewDecision,mergeStateStatus,isDraft
```

| Field | Value |
|-------|-------|
| **When** | PR is approved or no reviews required + CI is passing, no batch data |
| **Purpose** | Can this PR actually merge? Checks for conflicts, behind, blocked, draft |
| **Also calls** | Internally calls `getPRState()` (Call 5) first to skip merged PRs |
| **Also calls** | Internally calls `getCISummary()` (Call 6) for CI check within merge readiness |
| **Source** | `scm-github/src/index.ts:945-1026` |

> ⚠️ **Note:** `getMergeability()` internally re-calls `getPRState()` + `getCISummary()`, meaning Calls 5 & 6 can execute again inside Call 8. This is a known redundancy.

---

## Phase 3 — Review Backlog Dispatch

**Runs:** For each session with a PR.  
**Throttled:** At most once every **2 minutes** per session.

---

### Call 9 — Get Pending Review Comments

```
gh api graphql \
  -f owner={owner} -f name={repo} -F number={pr_number} \
  -f query="query($owner: String!, $name: String!, $number: Int!) {
    repository(owner: $owner, name: $name) {
      pullRequest(number: $number) {
        reviewThreads(first: 100) {
          nodes {
            isResolved
            comments(first: 1) {
              nodes {
                id, author { login }, body, path, line, url, createdAt
              }
            }
          }
        }
      }
    }
  }"
```

| Field | Value |
|-------|-------|
| **When** | Every 2 min per session with a PR |
| **Purpose** | Get unresolved review threads — human comments that need agent attention |
| **Filters** | Excludes resolved threads and bot authors |
| **Source** | `scm-github/src/index.ts:776-864` |

---

### Call 10 — Get Automated (Bot) Comments

```
gh api --method GET \
  "repos/{owner}/{repo}/pulls/{number}/comments?per_page=100&page={page}"
```

| Field | Value |
|-------|-------|
| **When** | Every 2 min per session with a PR (runs in parallel with Call 9) |
| **Purpose** | Get bot/linter comments (cursor[bot], codecov, dependabot, sonarcloud, etc.) |
| **Pagination** | Loops pages of 100 until empty response |
| **Severity** | Parses comment body for keywords (error/warning) to classify severity |
| **Source** | `scm-github/src/index.ts:866-943` |

---

## Phase 4 — CI Failure Details

**Runs:** Only when session status is `ci_failed`.

---

### Call 11 — Get Individual Failing Checks

```
gh pr checks {number} \
  --repo {owner}/{repo} \
  --json name,state,link,startedAt,completedAt
```

| Field | Value |
|-------|-------|
| **When** | Session is `ci_failed` AND batch enrichment didn't include individual check data |
| **Purpose** | Get names + URLs of failing CI checks to send to agent |
| **Skipped when** | Batch GraphQL (Call 3) already returned `ciChecks` in enrichment data |
| **Source** | `lifecycle-manager.ts:941-1066` |

---

## Phase 5 — Merge Conflict Dispatch

**Runs:** For each session with an open-ish PR.

---

### Call 12 — Detect Merge Conflicts

Same as Call 8 (`getMergeability()`).

| Field | Value |
|-------|-------|
| **When** | PR is in open/ci_failed/review_pending/etc. AND batch didn't run for this PR |
| **Purpose** | Detect merge conflicts and notify agent to rebase |
| **Skipped when** | Batch enrichment data has `hasConflicts` field |
| **Source** | `lifecycle-manager.ts:1074-1169` |

---

## Cost Summary

### Happy Path (all caches hit, nothing changed)

| Phase | Calls | API Points |
|-------|-------|-----------|
| 1. ETag Guards | R (one per repo) | 0 (all 304) |
| 2. Status Detection | 0 | 0 |
| 3. Review Backlog | 0 (throttled) | 0 |
| 4. CI Details | 0 (batch has checks) | 0 |
| 5. Merge Conflicts | 0 (batch has data) | 0 |
| **Total** | **R** | **0** |

### Typical Poll (some changes, batch hit)

| Phase | Calls | API Points |
|-------|-------|-----------|
| 1. ETag + GraphQL Batch | R + ⌈N/25⌉ | R + ⌈N/25⌉ |
| 2. PR Auto-Detect | ≤N (only new sessions) | ≤N |
| 3. Review Backlog | 2N (every 2 min) | 2N |
| 4–5. CI/Conflicts | 0 (batch covers it) | 0 |
| **Total** | **~R + ⌈N/25⌉ + 3N** | **~R + ⌈N/25⌉ + 3N** |

### Worst Case (all caches miss, all fallbacks)

| Phase | Calls | API Points |
|-------|-------|-----------|
| 1. ETag + GraphQL | R + ⌈N/25⌉ | R + ⌈N/25⌉ |
| 2. Fallback (5–8 per session) | Up to 4N | 4N |
| 3. Review Backlog (9–10) | 2N | 2N |
| 4. CI Details (11) | N | N |
| 5. Merge Conflicts (12) | N | N |
| **Total** | **~R + ⌈N/25⌉ + 8N** | **~R + ⌈N/25⌉ + 8N** |

> Where R = number of repos, N = number of active sessions with PRs.

---

## Known Redundancies

1. **`getMergeability()` internally calls `getPRState()` + `getCISummary()`** — same data fetched in Call 5 & 6 gets fetched again in Call 8. The batch enrichment eliminates this redundancy.

2. **`getCISummary()` internally calls `getCIChecks()`** — so checking CI summary already fetches individual check details.

3. **ETag Guard 2 checks ALL PRs** (not just pending CI) — this is intentional to catch CI transitions like `passing → failing`.

---

*Generated from AO source: `lifecycle-manager.ts` (1435 lines) + `scm-github/src/index.ts` (1062 lines) + `scm-github/src/graphql-batch.ts` (1025 lines)*
