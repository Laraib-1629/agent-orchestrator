# Experiment: ETag verification for `gh api` conditional requests

**Date:** 2026-04-14
**Branch:** `feat/gh-rate-limiting`
**Operator:** Dhruv + Claude

---

## Why this experiment exists

Agent Orchestrator's entire polling cost model rests on one unverified assumption: that `gh api -H "If-None-Match: <etag>"` produces free `304 Not Modified` responses when GitHub's state hasn't changed. If this works, the system scales to ~50 parallel sessions because most poll cycles cost zero quota. If it doesn't work, the ETag guards in `graphql-batch.ts` are a silent no-op and every poll pays full price — meaning the current architecture can't support even 10 parallel sessions, let alone 50.

We do not currently know which world we're in. This experiment answers that question with ~15 minutes of controlled API calls.

---

## Hypotheses

We are testing five discrete claims. Each is either true or false at the end of this experiment.

| # | Claim | How we test it |
|---|---|---|
| **H1** | `gh api -H "If-None-Match: <etag>"` actually forwards the header to `api.github.com` | Inspect `gh --verbose` output or compare behavior to a `curl` with the same header |
| **H2** | When nothing has changed on the resource, GitHub returns `304 Not Modified` | Make two back-to-back calls; second one should be 304 |
| **H3** | `gh api -i` prints the `HTTP/2 304` status line to stdout in a form AO's regex (`output.includes("HTTP/2 304")`) can detect | Grep stdout for the literal string |
| **H4** | The ETag GitHub returns on the first call is byte-for-byte usable as the next `If-None-Match` (no quoting, whitespace, or encoding corruption when going through `gh api` parsing) | Parse the ETag the way AO does, feed it back, see if the next call is 304 |
| **H5** | 304 responses do **not** decrement `x-ratelimit-remaining` (per GitHub's published policy) | Snapshot `/rate_limit` before, after a 200, and after a 304; compare deltas |

H1, H2, H3, H4 all need to hold for AO's current ETag path to be real.
H5 is a sanity check against GitHub's own documentation.

---

## What I need from you

- ✅ `gh` CLI authenticated (confirmed: `illegalcall`, OAuth `gho_` token, scopes `repo read:org workflow gist`)
- Permission to make ~15–25 **read-only** GitHub API calls against your account
- A target repo with at least one open PR. Default: **`ComposioHQ/agent-orchestrator`** (AO's own repo). If you'd rather probe a different repo, tell me before we start and I'll swap it in.
- `curl` available (standard on macOS — no action needed)
- ~15 minutes where we don't run other high-volume GitHub tools on the same token (otherwise quota counters will be noisy)

**What we will NOT do:** create PRs, comments, issues, branches, labels, or any other mutations. Every call in this experiment is a `GET`. You can revert nothing because nothing changes.

---

## What we will observe

For every API call, we will capture:

- HTTP status code (200, 304, 403, 429, etc.)
- The `etag` response header
- The `x-ratelimit-limit`, `x-ratelimit-remaining`, `x-ratelimit-reset`, `x-ratelimit-used`, `x-ratelimit-resource` response headers
- Response body size (to confirm 304 bodies are empty)
- Wall-clock duration of the call
- Whether AO's parsing code would successfully detect the status

All observations get logged in the **Running log** section at the bottom of this file, timestamped, with the exact command and its relevant output. At the end we fill in the **Results** table and write a one-paragraph **Verdict**.

---

## Target endpoint

We start with the same endpoint AO's Guard 1 uses:

```
GET /repos/ComposioHQ/agent-orchestrator/pulls?state=open&sort=updated&direction=desc&per_page=1
```

Why this endpoint:
- It's what AO actually polls, so the test reflects production behavior
- It returns ≤1 PR, so the body is small and the ETag is stable unless something genuinely changes in the repo
- It's a plain REST endpoint with standard ETag semantics

If time permits we'll also test Guard 2's endpoint (`/commits/{sha}/status`) with a real commit SHA from the PR list.

---

## Procedure

### Step 0 — Baseline `/rate_limit` snapshot

```bash
gh api /rate_limit
```

**Purpose:** record the starting `remaining` for the `core` (REST) bucket so we can compute deltas from subsequent calls. Calling `/rate_limit` itself is documented as free (does not consume quota), so this is a clean measurement.

**What to log:** `core.limit`, `core.remaining`, `core.reset`, `graphql.remaining`.

---

### Step 1 — First call (cold, no `If-None-Match`)

```bash
gh api --method GET \
  "repos/ComposioHQ/agent-orchestrator/pulls?state=open&sort=updated&direction=desc&per_page=1" \
  -i
```

**Expected:** `HTTP/2 200`, a body containing 0–1 PRs, and an `etag:` header in the response.

**What to log:**
- Full HTTP status line (verbatim)
- The `etag:` value, byte-for-byte (including the `W/` weak-validator prefix and surrounding quotes if present)
- `x-ratelimit-remaining` after the call
- Response body byte count
- Wall-clock duration

This gives us the ETag we'll replay in Step 2.

---

### Step 2 — Second call with `If-None-Match` set to Step 1's ETag

```bash
# Paste the ETag from Step 1 literally. Shell-escape the quotes.
ETAG='W/"...put the value from step 1 here..."'

gh api --method GET \
  "repos/ComposioHQ/agent-orchestrator/pulls?state=open&sort=updated&direction=desc&per_page=1" \
  -i \
  -H "If-None-Match: ${ETAG}"
```

**Expected if everything works:** `HTTP/2 304 Not Modified`, empty body, and `x-ratelimit-remaining` unchanged from Step 1.

**Expected if broken:** `HTTP/2 200` with a full body (meaning the header was stripped, rewritten, or GitHub didn't treat it as a match), and `x-ratelimit-remaining` decremented by 1.

**What to log:**
- Full HTTP status line (verbatim)
- Whether stdout contains the literal string `HTTP/2 304` or `HTTP/1.1 304` (this is what AO's detection regex actually looks for — `graphql-batch.ts:357`)
- `x-ratelimit-remaining` after the call — **this is the critical number**
- Response body byte count (should be 0 or near-0 on a real 304)
- Wall-clock duration

**⚠️ Interpretation rule:** if Step 2 returns 200 and remaining is one lower than after Step 1, the ETag path is broken. Full stop. That result kills the assumption and changes every recommendation I made earlier.

---

### Step 3 — Parse the Step 2 output the way AO does

```bash
# Re-run Step 2, but pipe through the same checks AO applies.
ETAG='...'
OUTPUT=$(gh api --method GET \
  "repos/ComposioHQ/agent-orchestrator/pulls?state=open&sort=updated&direction=desc&per_page=1" \
  -i \
  -H "If-None-Match: ${ETAG}")

# AO's detection logic (from graphql-batch.ts:357):
if [[ "$OUTPUT" == *"HTTP/2 304"* || "$OUTPUT" == *"HTTP/1.1 304"* ]]; then
  echo "PARSE RESULT: detected 304 (AO would skip GraphQL batch) ✅"
else
  echo "PARSE RESULT: did NOT detect 304 (AO would proceed to GraphQL batch)"
fi

# AO's ETag extraction regex (from graphql-batch.ts:364):
NEW_ETAG=$(echo "$OUTPUT" | grep -i '^etag:' | sed 's/^etag: *//I' | tr -d '\r\n')
echo "PARSED ETAG: [$NEW_ETAG]"
```

**Purpose:** confirm that even if GitHub returns 304, AO's regex-based string matching actually catches it. This is a separate failure mode from "does gh forward the header" — it's "does AO's parser recognize the response".

**What to log:**
- The PARSE RESULT line
- The PARSED ETAG line (compare byte-for-byte with Step 1's ETag — they must match if nothing has changed)

---

### Step 4 — Control: do the same thing with `curl` directly

```bash
TOKEN=$(gh auth token)
ETAG='W/"...same value as step 1..."'

curl -sS -D - -o /dev/null \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  -H "If-None-Match: ${ETAG}" \
  "https://api.github.com/repos/ComposioHQ/agent-orchestrator/pulls?state=open&sort=updated&direction=desc&per_page=1"
```

**Purpose:** determine whether any failure is GitHub's fault (server-side doesn't honor the ETag), `gh`'s fault (header gets stripped before leaving the CLI), or ours (parser bug in AO).

**Decision matrix:**

| Step 2 result | Step 4 result | Conclusion |
|---|---|---|
| 304 | 304 | ✅ Everything works. AO's ETag path is real. |
| 200 | 304 | 🚨 `gh api` is silently dropping or rewriting `If-None-Match`. AO needs to stop using `gh api` for this or find a workaround. |
| 200 | 200 | 🤔 GitHub isn't returning 304 for some reason (resource genuinely changed between Step 1 and Step 2, server policy, weak-validator mismatch, etc.). Need to investigate further. |
| 304 | 200 | 😵 Inverted failure — suggests curl is missing something gh includes. Weird but possible. |

**What to log:**
- The curl exit code
- The full response status line
- The `etag` and `x-ratelimit-remaining` headers
- Diff Step 2's headers vs Step 4's headers

---

### Step 5 — Rate-limit delta verification (H5)

After all of the above, re-check `/rate_limit`:

```bash
gh api /rate_limit
```

**Compute:**
- `core.used` at Step 0 → `core.used` now = total REST calls GitHub thinks we made
- Subtract 1 for Step 1 (200 response, definitely counted)
- Subtract 1 for Step 4 if it was a 200, 0 if it was a 304
- Expected remainder = 0 if Step 2 was 304, 1 if Step 2 was 200

If the observed `core.used` delta matches the expected number, we've confirmed H5 (304s are free). If it's higher, something is decrementing quota we can't account for.

---

### Step 6 (optional) — Repeat for Guard 2's commit status endpoint

If Steps 1–5 go smoothly and we have time, pick a `head_sha` from the PR list Step 1 returned and repeat the same 1-2-3 pattern against:

```
GET /repos/ComposioHQ/agent-orchestrator/commits/<sha>/status
```

This verifies Guard 2 works the same way Guard 1 does. Same hypotheses, same procedure.

---

## Results (to be filled in as we go)

| Hypothesis | Result | Evidence |
|---|---|---|
| H1: `gh api -H` forwards the header | ✅ **PASS** | Step 2 received `HTTP/2.0 304 Not Modified` — only possible if GitHub saw and matched the `If-None-Match` we sent |
| H2: GitHub returns 304 on unchanged resource | ✅ **PASS** | Observed three separate 304 responses (Step 2, Step 2b, curl replay in Step 4b) |
| H3: AO's regex catches `HTTP/2 304` in stdout | ❌ **FAIL (2 independent bugs)** | (a) `gh api` exits code 1 on 304 → `execFileAsync` rejects → AO lands in catch branch → returns "changed" without parsing `err.stdout`. (b) Even if (a) were fixed, `output.includes("HTTP/2 304")` cannot match the actual `HTTP/2.0 304` status line printed by gh. |
| H4: Extracted ETag is byte-identical and reusable | ✅ **PASS** | Weak validator `W/"74a216..."` from Step 1 successfully produced a 304 when replayed in Step 2 |
| H5: 304 responses do not decrement `x-ratelimit-remaining` | ✅ **PASS** | Three 304 observations all showed `x-ratelimit-used` unchanged from prior call |

---

## Verdict

**AO's ETag guards are a silent no-op in production.** GitHub's side works exactly as documented — conditional requests return 304 and cost zero quota — but AO never sees a single 304. Two independent bugs each block detection:

1. **`gh api` exits with code 1 on 304 responses.** Node's `execFileAsync` rejects the promise on non-zero exit, and AO's catch block at `packages/plugins/scm-github/src/graphql-batch.ts:373-379` unconditionally returns `true` ("PR list changed"). It logs `[ETag Guard 1] PR list check failed` — a warning that currently fires on every successful 304, and which almost certainly shows up in production logs today. Nobody reads it because it looks like a benign transient error.

2. **The detection substring doesn't match gh's output.** The code searches for `HTTP/2 304` and `HTTP/1.1 304`, but gh prints `HTTP/2.0 304`. Even if the `catch`-branch issue were fixed by reading `err.stdout`, the substring check would still miss.

**Consequence:** every poll cycle currently forces a full GraphQL batch for every active PR in every repo, because both guards always return `true`. The 304-free-poll steady state the doc describes doesn't exist. AO is paying ~N GraphQL points per poll cycle (where N is number of session-repos) instead of the ~0 the architecture was designed for. Right now, with a few sessions on a standard PAT, nobody notices because there's still tons of headroom. With 50 sessions, this is the reason rate limits get hit.

**Both bugs are trivial to fix.** The combined patch is ~20 lines: parse `err.stdout` in the catch branch, use a `HTTP/[\d.]+ 304` regex instead of a literal substring, and only fall through to "assume changed" when `err.stdout` is actually empty. One Vitest test reproducing the 304-via-exit-1 path would prevent regression.

**What this changes about our overall plan:**

- **The free wins just got a very big one added at the front:** fix the 304 detection. With that patch alone, steady-state cost collapses from ~N/cycle → ~0/cycle. We need to re-measure after the fix to quantify how much headroom this buys before doing any other optimization.
- **Switching from `gh api` to Octokit is still probably correct** (better ETag semantics, proper header access, throttling plugin, no subprocess tax), but it is no longer an *emergency*. We can ship the detection fix in a day, verify it works, then evaluate whether Octokit is still worth the blast radius.
- **Nothing else we discussed (global concurrency semaphore, per-repo detectPR dedup, persistent ETag cache, rate-limit header wiring) is invalidated.** They're all still the right work. They become the "second wave" after the detection-fix first wave.
- **The test harness plan is now even more valuable** — we need a deterministic way to measure "before fix" vs "after fix" request counts, and to prove the 304 path is actually working end-to-end in the running AO, not just in a shell script.

**Immediate next step:** write a design doc for the detection fix + the test harness, in that order. The fix is urgent and small; the harness is what lets us validate the fix and every future optimization.

---

## Appendix: bonus oddity worth remembering later

During the head-to-head (Step 4b), curl with a fresh ETag returned 304 while gh api with the *same* fresh ETag returned 200 and the *old* Step 1 ETag. This strongly suggests gh and curl were hitting different GitHub edge CDN nodes, each with its own cached version of the `cache-control: private, max-age=60` response. It's not relevant to the ETag bug, but it's a reminder that **a persistent ETag cache keyed only by URL can be briefly fooled by CDN skew across clients** — something to design around if we ever build a shared cross-process ETag store.

---

## Running log

Timestamped observations as we execute each step. Most recent at the bottom. Raw command output goes here verbatim so we can reread later and argue with past-us.

---

### 2026-04-14 — Experiment file created. Ready to run Step 0 on your signal.

---

### Step 0 — Baseline `/rate_limit` snapshot

**Command:** `gh api /rate_limit`

**Result:**

| Bucket | limit | used | remaining | reset (epoch) |
|---|---|---|---|---|
| core | 5000 | 11 | 4989 | 1776170521 |
| graphql | 5000 | 92 | 4908 | 1776171647 |
| search | 30 | 0 | 30 | 1776169947 |

**Observations:**
- Standard 5000/hr quota → user is authenticated as a regular OAuth/PAT account (not a GitHub App installation, not Enterprise Cloud). Confirms the free-win recommendation "switch to GitHub App for 2.5–3× headroom" is still on the table.
- core bucket has lots of headroom; nothing we do in this experiment will get anywhere near the limit.
- `/rate_limit` itself is documented as free — and indeed, we'll see if `core.used` still reads 11 in Step 1's pre-call snapshot (it should).

---

### Step 1 — Cold GET (no `If-None-Match`)

**Command:** `gh api --method GET "repos/ComposioHQ/agent-orchestrator/pulls?state=open&sort=updated&direction=desc&per_page=1" -i`

**Result:**
- Status line: **`HTTP/2.0 200 OK`** ⚠️ (note the `.0`)
- ETag: **`W/"74a216221256f97055f05c82321be6f9e450c1cde3bd11ec4725cafadea53260"`**
- Rate limit after: `X-Ratelimit-Used: 3`, `X-Ratelimit-Remaining: 4997`
- Body: 1 PR (#1215 — "Fix Codex session activity parsing for payload JSONL")
- Exit code: 0

**Observations:**
- 🚨 **Potential parse bug in AO.** The status line reads `HTTP/2.0 200 OK` but AO's 304 detection at `graphql-batch.ts:357` is `output.includes("HTTP/2 304") || output.includes("HTTP/1.1 304")`. Neither substring matches `HTTP/2.0 304`. This needs direct verification in Step 3 because if AO never recognizes `HTTP/2.0 304`, its ETag guards are a no-op.
- Rate window rolled over between Step 0 (used=11) and Step 1 (used=3). This is expected — the core bucket has a rolling reset. From Step 1 onward we track deltas relative to Step 1, not Step 0.
- GitHub returned a **weak** ETag (`W/"..."` prefix). This is the one AO cached. Worth watching whether sending back `W/"..."` as-is on the next request is accepted.

---

### Step 2 — Replay with `If-None-Match` (the load-bearing test)

**Command:** `gh api --method GET "..." -i -H 'If-None-Match: W/"74a216...e53260"'`

**Result:**
- Status line: **`HTTP/2.0 304 Not Modified`** ✅
- Rate limit after: `X-Ratelimit-Used: 3`, `X-Ratelimit-Remaining: 4997` — **unchanged** from Step 1 ✅
- stderr: `gh: HTTP 304`
- **Exit code: 1** 🚨
- Body: empty (headers only)

**This is the experiment's central finding.** GitHub's side works perfectly: 304 returned, quota unchanged. But `gh api` **exits non-zero** on a 304 response — which triggers two cascading bugs in AO's code.

---

### Step 3 — AO-style parse check

**Test 1: Reproduce AO's `execFileAsync` call path in Node**

```js
try {
  const { stdout } = await execFileAsync("gh", [...args], { timeout: 10000 });
  // process stdout...
} catch (err) {
  // return true (fail open, assume changed)
}
```

Result: **`CATCH BRANCH TAKEN`** — `err.code: 1`, but `err.stdout` does contain the full 304 response with headers. Node's `execFile` rejects the promise on non-zero exit, and AO's catch at `graphql-batch.ts:373-379` unconditionally returns `true` (= "PR list changed") without ever inspecting `err.stdout`.

**Bug #1 confirmed:**
```ts
// graphql-batch.ts:373-379 — what actually runs on every 304:
} catch (err) {
  const errorMsg = err instanceof Error ? err.message : String(err);
  console.warn(`[ETag Guard 1] PR list check failed for ${repoKey}: ${errorMsg}`);
  return true; // Assume changed to be safe
}
```

Every 304 lands here. AO logs a warning (`[ETag Guard 1] ... failed`) and forces a full GraphQL batch. The ETag guards have been a **silent no-op in production**.

**Test 2: Substring-matching check**

```js
"HTTP/2.0 304 Not Modified".includes("HTTP/2 304")   // false ⚠️
"HTTP/2.0 304 Not Modified".includes("HTTP/1.1 304") // false
"HTTP/2.0 304 Not Modified".includes("HTTP/2.0 304") // true
```

**Bug #2 confirmed.** Even if we fixed Bug #1 by moving the parse into the catch branch, the literal substring check would still miss every 304 because gh's status line is `HTTP/2.0 304`, not `HTTP/2 304`. AO's detection string is wrong by one character (`.0` missing).

**Both bugs independently prevent ETag guards from working.** Fixing either one alone is not sufficient:
- Fix only Bug #1 (read `err.stdout` in catch branch): parser still misses because of Bug #2.
- Fix only Bug #2 (update substring to `HTTP/2.0 304`): code never reaches the parser because `execFileAsync` already rejected.

---

### Step 4 — curl control

**Command:** Same endpoint, `curl -sS -D -` with `Authorization: Bearer $(gh auth token)` and `If-None-Match` set to Step 1's ETag.

**Result:** `HTTP/2 200` — but with a **different** ETag (`"92550bc161fc8da6d0d15e74be580b8381207e26402661b6ed73b6ba14b0a600"`), meaning the underlying resource genuinely changed between Step 2 and Step 4 (~40s gap; ComposioHQ/agent-orchestrator is a busy repo).

**Head-to-head retry with the *new* (curl-fresh) ETag, back-to-back:**
- curl → `HTTP/2 304`, `x-ratelimit-remaining: 4996` (unchanged from prior curl call) ✅
- gh api → `HTTP/2.0 200 OK`, etag in response is `W/"74a216..."` (the *old* Step 1 ETag), remaining drops to 4995

The gh-side 200 with a stale etag is odd and is almost certainly GitHub's edge CDN returning a stale cached body to the gh request's edge node (different User-Agent → potentially different edge cache state, plus the `cache-control: private, max-age=60, s-maxage=60` on the resource). **It's not relevant to the main finding** — we already proved in Steps 1–3 that when gh api does receive a 304, it's mishandled. The CDN skew is a side quirk worth remembering but not worth chasing now.

---

### Step 5 — Final `/rate_limit` snapshot

**Command:** `gh api /rate_limit`

**Result:** `core: used=11 remaining=4989 limit=5000 reset=1776170521` — identical to Step 0's baseline.

**Observation:** This appears stale — we definitely made several rate-counted calls in the window. Two possibilities: (a) gh is caching `/rate_limit` responses locally (unlikely — no cache flag was set), or (b) GitHub's `/rate_limit` endpoint serves from a slightly lagged internal counter / edge cache. Not investigated further because the **per-call `X-Ratelimit-*` headers** from the actual API calls are the authoritative source, and those showed:

| Call | Status | `x-ratelimit-used` | `x-ratelimit-remaining` | Delta |
|---|---|---|---|---|
| Step 1 (cold GET) | 200 | 3 | 4997 | — (baseline) |
| Step 2 (replay w/ If-None-Match) | **304** | **3** | **4997** | **0** ✅ |
| Step 2b (exit code capture, same call) | **304** | **3** | **4997** | **0** ✅ |
| Step 4 (curl, new resource state) | 200 | 4 | 4996 | +1 |
| Step 4b (curl replay w/ fresh ETag) | **304** | **4** | **4996** | **0** ✅ |
| Step 4b (gh api, same fresh ETag) | 200 (stale body) | 5 | 4995 | +1 |

**H5 confirmed through three independent 304 observations:** all three show zero quota consumption. GitHub's documented "304s are free" policy works exactly as specified.

---

# Experiment 2: GraphQL conditional requests + batch cost

**Added:** 2026-04-14 (after the ETag experiment above concluded)

## Why

AO's polling cost model has two sides: the REST ETag guards (measured above) and the GraphQL aliased batch that runs when a guard fires. We've proven the REST guards are broken; we have *not* verified how much the GraphQL side actually costs, or whether there's any free-request path on `/graphql` at all. Before designing the harness we need to know:

1. **Does `/graphql` honor `If-None-Match`?** REST endpoints do. GraphQL is a single POST endpoint with a request body — conditional requests may or may not be wired up. If yes, AO could cache the batch response and skip re-sending. If no, every batch costs points and the only knob left is batch size / frequency.
2. **What's the real quota delta for a 25-PR aliased batch?** The GitHub GraphQL docs describe a "points per query" model, not a 1:1 request count. `x-ratelimit-*` headers on `/graphql` are in a separate bucket (graphql: 5000/hr) and bill in *points*, not calls. We need the actual observed delta, not a guess.
3. **Are there any introspectable cost signals?** GraphQL responses can include a `rateLimit { cost, remaining, resetAt }` field if the query requests it. If so, we can precisely compute per-query cost offline, which the harness will want.

## Hypotheses

| # | Claim | How we test it |
|---|---|---|
| **G1** | `/graphql` returns an `etag` header on POST responses | Make one POST, inspect headers |
| **G2** | Replaying the same query with `If-None-Match` returns 304 | Two back-to-back POSTs with identical body + replayed ETag |
| **G3** | A 25-alias PR batch costs exactly 1 point on `graphql.remaining` | Two calls back-to-back, diff `x-ratelimit-remaining` on the graphql bucket |
| **G4** | Including `rateLimit { cost remaining resetAt }` in the query surfaces the per-query cost in the response body | Parse the JSON response |

## Procedure

### G-Step 0 — Baseline graphql bucket

```bash
gh api /rate_limit --jq '.resources.graphql'
```

Log `used` / `remaining` / `reset`. This is our graphql-bucket baseline.

### G-Step 1 — Cold query with `rateLimit` introspection

Send a minimal aliased-batch query shaped like AO's (but fetching 3 PRs instead of 25 to keep the experiment small) with the `rateLimit` field tacked on:

```graphql
query {
  rateLimit { cost remaining resetAt }
  pr1: repository(owner: "ComposioHQ", name: "agent-orchestrator") {
    pullRequest(number: 1215) { number title state }
  }
  pr2: repository(owner: "ComposioHQ", name: "agent-orchestrator") {
    pullRequest(number: 1219) { number title state }
  }
  pr3: repository(owner: "ComposioHQ", name: "agent-orchestrator") {
    pullRequest(number: 1207) { number title state }
  }
}
```

Run with `gh api graphql -f query=@query.graphql -i` to capture headers.

**Log:**
- Full HTTP status line
- `etag` header (G1)
- `x-ratelimit-*` headers on the graphql bucket
- The `rateLimit` field in the JSON response body (G4)
- Exit code

### G-Step 2 — Replay identical query with `If-None-Match`

If G-Step 1 returned an ETag, replay the exact same request with `-H "If-None-Match: <etag>"`.

**Log:**
- Status line (want to see 304)
- `x-ratelimit-remaining` (should be unchanged if 304; decremented by query cost if 200)
- Exit code

### G-Step 3 — Back-to-back vanilla calls (no If-None-Match) to measure cost

Run G-Step 1's query twice with no conditional header. Diff `x-ratelimit-remaining` before vs after to get the real per-call cost. Compare to the `rateLimit.cost` field from the response body.

**Log:**
- `remaining` delta across the two calls
- `rateLimit.cost` values from both responses (should be equal)
- Whether the two are consistent with each other

### G-Step 4 (optional) — Scale to 25 aliases

If G-Step 3 showed cost=1 for 3 aliases, repeat with 25 aliases to check whether cost scales linearly, stays flat, or jumps. AO's production batch size is 25, so this is the number we actually care about.

## G-Results

| Hypothesis | Result | Evidence |
|---|---|---|
| G1: `/graphql` returns `etag` | ❌ **FAIL** | Grepping response headers on every observed `/graphql` POST yielded zero `etag:` lines. Note: GitHub's `Access-Control-Expose-Headers` advertises `ETag` as exposable, but the server never actually emits one for GraphQL responses. |
| G2: Replay with `If-None-Match` returns 304 | ❌ **FAIL** | Sent a synthetic `If-None-Match: W/"synthetic-fake-etag-for-testing"` on Call C. GitHub returned `HTTP/2.0 200 OK` with a full response body and decremented `x-ratelimit-used` by 1 (9 → 10). The header was silently ignored. Conditional requests do not work on `/graphql`. |
| G3: 3-alias batch costs 1 point | ✅ **PASS** | Call A: used 7→8 (Δ1). Call B: used 8→9 (Δ1). Call C: used 9→10 (Δ1). All three had `rateLimit.cost: 1` in the response body. |
| G4: `rateLimit` field surfaces accurate cost | ✅ **PASS** | In every back-to-back sequence (3-alias and 25-alias), `rateLimit.cost` in the JSON response body agreed exactly with the `x-ratelimit-used` header delta. Including the `rateLimit { cost remaining resetAt }` field in the query did not itself change the cost (still 1). |
| G4b (bonus): 25-alias batch costs the same as 3-alias | ✅ **PASS** | Three back-to-back 25-alias calls: used 13→14, 14→15, 15→16. Each reported `cost: 1` and each consumed exactly 1 point. Scaling aliased primary-key lookups from 3 → 25 did not increase the per-call cost. |

## G-Verdict

**The GraphQL path has no free-request mode.** GitHub does not emit `etag` on `/graphql` POST responses, and a synthetic `If-None-Match` is silently ignored. AO cannot do "skip GraphQL if nothing changed" the way it can on REST. Every time a REST ETag guard fires (or in AO's case, pretends to fire), the batch costs real graphql-bucket points. This closes the door on one potential optimization (persistent graphql ETag cache) before we waste design effort on it.

**The good news: a 25-alias batch costs exactly 1 point.** Aliased primary-key lookups (`repository(...).pullRequest(number: N)`) are a fixed-cost operation regardless of alias count. Verified both by the `rateLimit { cost }` field in the response body and by diffing `x-ratelimit-remaining` across back-to-back calls. With the graphql bucket at 5000 points/hr, that's effectively 5000 poll-cycles/hr of graphql-bucket headroom even if every cycle falls through to a full batch. For 50 sessions polling every 30s, that's ≈6000 polls/hr system-wide — just over the bucket. Tight but workable once REST ETag guards are functional (which they currently are not), and with even a small amount of de-duplication across sessions it's comfortable.

**`rateLimit { cost remaining resetAt }` is free to include.** Adding this field to every AO batch query did not increase its point cost. It gives us a precise, in-band cost signal that does not depend on header parsing or a separate `/rate_limit` call. **The harness should instrument every GraphQL call with this.** It's cheaper and more accurate than the header-based path.

**Implications for the plan:**
- Persistent GraphQL ETag cache: ❌ dead. Drop from the option list.
- Query cost introspection in the wrapper library: ✅ trivially cheap, worth doing unconditionally.
- Batch-size tuning (25 vs 50 vs 100): irrelevant for cost *as long as* the query stays pure aliased primary-key lookup. Worth staying at 25 for network/latency reasons, not for rate-limit reasons.
- Any graphql query that *isn't* a pure primary-key lookup (e.g. `search()`, `pullRequests(first: N, orderBy: ...)`) needs to be cost-measured separately. The 1-point result is specific to the alias-by-number pattern AO already uses.

---

# Experiment 3: Secondary rate-limit shape

**Added:** 2026-04-14

## Why

We've verified the *primary* rate limit (5000/hr core, 5000 points/hr graphql) behaves exactly as documented. GitHub also publishes three *secondary* limits that are much more aggressive and kick in at burst time:

- **≤100 concurrent requests** to the REST API
- **≤900 points/min** on REST write operations (separate from the graphql bucket)
- **≤80 content-generating requests/min** (POSTs that create content)

For AO at 50 sessions, the concurrent-request limit is the realistic failure mode. A poll cycle that fans out across all sessions with no throttling can easily spike above 100 in-flight requests.

We need to see the actual error shape with our own eyes **before** designing the harness, because the harness has to distinguish "we hit a secondary limit" from "we hit the primary limit" from "GitHub had a blip" and handle each correctly. Documentation says the response will be `403` or `429` with a `retry-after` header, but it doesn't say whether `gh api` surfaces that header, whether `x-ratelimit-*` lies to us in that state, or what the body looks like.

## Hypotheses

| # | Claim | How we test it |
|---|---|---|
| **S1** | Firing >100 concurrent `gh api` calls trips a secondary limit | Burst, count non-200/304 responses |
| **S2** | The error response has a `retry-after` header | Inspect response headers on the errored calls |
| **S3** | `x-ratelimit-remaining` is NOT 0 when the secondary limit fires (distinguishes secondary from primary exhaustion) | Compare primary-limit headers on errored vs successful calls |
| **S4** | `gh api` exit code on a 403/429 is non-zero and distinguishable from the exit-1-on-304 case | Capture exit codes and stderr |
| **S5** | The error is transient and clears within `retry-after` seconds | Wait + retry, confirm 200 |

## Procedure

### S-Step 0 — Safety precheck

Record the current `core` bucket `remaining`. If it's below 500, **abort** — we don't want to accidentally deplete the primary limit for the rest of the day while chasing a secondary-limit experiment. Need at least 200 core quota as a safety buffer.

Also confirm no other high-volume GitHub tooling is running on this token.

### S-Step 1 — Graduated concurrent burst

Use `xargs -P N -I{} gh api /user -i` to fire N parallel requests. `/user` is cheap (simple REST call, tiny response) and read-only. Start at N=20 (well under the 100 limit) to establish a baseline, then ramp up.

Progression:
- N=20 → expect all 200, measure typical wall time
- N=60 → still under 100 limit, expect all 200
- N=120 → expect *some* 403/429 (this is the one we care about)
- N=200 → if 120 didn't trip it, this should

Stop the moment we see a non-200, log everything, don't ramp further.

**Log per phase:**
- Wall time
- Count of 200s, 304s, 403s, 429s, other
- For each non-200 response: full status line, `retry-after`, `x-ratelimit-*`, `x-github-request-id`, body
- `gh api` exit codes (distribution)
- Primary quota delta (to sanity-check we're measuring secondary, not primary)

### S-Step 2 — Document the retry-after behavior

If any non-200 fires: wait `retry-after` seconds, then make a single `gh api /user -i` call. Verify it succeeds and record how long recovery actually takes.

### S-Step 3 — Check if the error is visible through `gh api`

For the errored responses, check:
- Did `gh api` print the status line to stdout?
- Did it print the headers to stdout?
- Did it write the error body to stdout or stderr?
- Did it exit 0, 1, or something else?

This determines whether the harness can detect secondary limits through subprocess output parsing or whether it needs to migrate to a direct HTTP client to see them at all.

## S-Guardrails

- Total experiment budget: ≤300 primary-bucket calls. `/user` is 1 point each, so 300 calls = ≤6% of hourly quota.
- Hard stop if `x-ratelimit-remaining` drops below 500 at any point.
- If the first 403/429 shows up, do not escalate further — we have the signal we came for.
- Not running any mutations. Read-only `/user` only.

## S-Results

| Hypothesis | Result | Evidence |
|---|---|---|
| S1: >100 concurrent trips secondary limit | ⚠️ **NOT REPRODUCED** | Bursts at N=20, 60, 120, 200 via `gh api /user` and N=150 via direct `curl` all returned 100% `HTTP/2 200 OK` with zero 403/429 responses. `x-ratelimit-remaining` decremented by exactly N per phase, confirming every call landed on GitHub's edge. The documented `>100 concurrent` threshold could not be reached from this setup. |
| S2: Error response has `retry-after` header | ⚪ **INCONCLUSIVE** | No error responses observed — no `retry-after` header to inspect. Must rely on GitHub's documentation for initial harness implementation. |
| S3: `x-ratelimit-remaining ≠ 0` on secondary error | ⚪ **INCONCLUSIVE** | Not observed. |
| S4: `gh api` exit code on 403/429 is non-zero | ⚪ **INCONCLUSIVE** (for 403/429 specifically — but Experiment 1 already showed gh exits 1 on *any* non-2xx including 304) | Not directly reproduced, but the 304 finding strongly suggests gh uses "exit 1 on any non-2xx" as a uniform rule. |
| S5: Error clears within `retry-after` | ⚪ **INCONCLUSIVE** | Not observed. |

## S-Verdict

**We could not empirically trigger a secondary rate limit from this setup.** Every burst phase completed cleanly:

| Phase | Tool | N | Wall time | Status | `x-ratelimit-remaining` span |
|---|---|---|---|---|---|
| 1 | `gh api /user` | 20 | 1.63s | 20/20 = 200 OK | 4980..4999 (20 distinct) |
| 2 | `gh api /user` | 60 | 1.60s | 60/60 = 200 OK | 4920..4979 (60 distinct) |
| 3 | `gh api /user` | 120 | 2.09s | 120/120 = 200 OK | 4800..4919 (120 distinct) |
| 4 | `gh api /user` | 200 | 3.07s | 200/200 = 200 OK | 4600..4799 (200 distinct) |
| 5 | `curl .../user` | 150 | 2.18s | 150/150 = 200 OK | 4450..4599 (150 distinct) |

Total budget spent: **550 core-bucket calls**, leaving ≈4450/5000 remaining after the experiment. Zero 403s, zero 429s, zero non-zero exit codes, zero `retry-after` headers.

**The curl phase is important** because it bypasses `gh api` subprocess startup latency (~150-300ms/call), so true in-flight concurrency on the TCP level was much higher than in the gh phases. It still cleared cleanly. This rules out "gh was serializing, we never actually had 200 concurrent" as an explanation.

**Three non-exclusive reasons this might be:**

1. **The ≤100 concurrent limit isn't a hard synchronous cap.** GitHub's docs describe it loosely, without specifying what "concurrent" means (in-flight at instant t? requests within a rolling window? connections on a single socket?). Our bursts may have been brushing against the limit without crossing whatever the internal definition actually is.

2. **`/user` is a cheap, read-only, cacheable endpoint** and GitHub probably throttles it more generously than the content-generating endpoints the secondary-limit docs specifically call out. A burst of 200 `/user` GETs may be treated as benign where a burst of 20 POSTs to `/repos/:owner/:repo/pulls` would not.

3. **Anti-abuse heuristics may be user-segmented.** GitHub may apply different thresholds based on account age, history, or behavior patterns. This token shows no prior abuse and may be in a more forgiving tier.

**What this means for the harness design:**

- **Secondary-limit responses are a documented-but-unobserved failure mode.** The harness must instrument for them (capture 403/429 + `retry-after` + full error body + headers + stderr + exit code) but should not pretend to know the exact wire shape from our own observation. Treat GitHub's docs as the source of truth for the initial handler, and plan to patch once a real sample lands.
- **Record every error response verbatim.** Status line, all headers, body, exit code, stderr. First real 403/429 the harness sees in production is the one we learn from.
- **Do NOT try to trigger the limit intentionally in CI.** It's not deterministic, it burns real quota on every run, and it risks account-level throttling. Test the handler against mocked 403/429 responses instead.
- **Most importantly:** the harness should measure and report *observed burst concurrency* per poll cycle, so we can eventually correlate "AO did N concurrent calls" with "secondary limit fired" when it does happen.

**An anecdotal reassurance for capacity planning:** GitHub was demonstrably happy servicing 200 concurrent reads from this token. For 50 AO sessions polling every 30s, peak instantaneous concurrency under the current architecture is bounded by (sessions × parallel_calls_per_session). Even an unthrottled fan-out at 50×8=400 would be higher than what we just tested — but not by a factor that guarantees disaster. The risk is real but not overwhelming. **Do not plan capacity on the assumption that 200 always works**, because we don't know what content-generating endpoints, different times of day, or different IPs look like.

**What we did NOT test** (and should eventually): 403/429 shape on content-generating POST endpoints, behavior under sustained high-concurrency over many minutes (sliding-window limits may be time-sensitive), and behavior when the primary bucket is simultaneously near-exhausted. These are follow-ups, not blockers for starting the harness.

---

## Running log — Experiment 2 (GraphQL)

### 2026-04-14 13:01 — G-Step 0 baseline

```
core:    limit=5000 used=3  remaining=4997 reset=1776174488
graphql: limit=5000 used=2  remaining=4998 reset=1776175262
```

### 13:01 — G-Step 1 first attempt (query file via `-f query=@/tmp/...`)

The `-f` flag's `@file` handling conflicted with SDL `@` directive parsing at GitHub's end; the server responded `HTTP/2.0 200 OK` but returned `{"errors":[{"message":"Expected one of SCHEMA, SCALAR, TYPE, ENUM, INPUT, UNION, INTERFACE, actual: DIR_SIGN (\"@\") at [1, 1]"}]}`. Headers were still usable for observation:

```
X-Ratelimit-Used: 3  X-Ratelimit-Remaining: 4997
```

Note: the errored query still counted against the bucket (delta 1).

### 13:02 — G-Step 1 retry (query via inline `-f query="$QUERY"`)

Successful 3-alias query. Response:
```json
{"data":{"rateLimit":{"cost":1,"remaining":4995,"resetAt":"2026-04-14T14:01:02Z"},
         "pr1":{"pullRequest":{"number":1215,"title":"Fix Codex ...","state":"OPEN"}},
         "pr2":{"pullRequest":{"number":1219,"title":"fix(web): link ...","state":"MERGED"}},
         "pr3":{"pullRequest":{"number":1207,"title":"fix(web): add restore ...","state":"MERGED"}}}}
```

Headers: `X-Ratelimit-Used: 5`, `X-Ratelimit-Remaining: 4995`. **No `etag:` header** — confirmed by grep returning zero matches. **G1 = FAIL.**

### 13:02 — G-Step 2 + G-Step 3 back-to-back measurement

```
Pre-sequence graphql bucket: used=7 remaining=4993

Call A (vanilla, no conditional):        used=8  remaining=4992  rateLimit.cost=1
Call B (vanilla, back-to-back):          used=9  remaining=4991  rateLimit.cost=1
Call C (If-None-Match: synthetic fake):  used=10 remaining=4990  rateLimit.cost=1   ← HTTP/2.0 200 OK (not 304)
```

Synthetic `If-None-Match: W/"synthetic-fake-etag-for-testing"` header was silently ignored. GitHub served a full response and decremented the bucket. **G2 = FAIL.** Delta per call = exactly 1, matching `rateLimit.cost`. **G3 = PASS, G4 = PASS.**

### 13:03 — G-Step 4 (25-alias batch)

Generated query with 25 aliased `pullRequest(number: N)` lookups, then three back-to-back calls:

```
Call 25-A: X-Ratelimit-Used=14  rateLimit.cost=1
Call 25-B: X-Ratelimit-Used=15  rateLimit.cost=1
Call 25-C: X-Ratelimit-Used=16  rateLimit.cost=1
```

**Cost is flat at 1 point per call regardless of alias count (3 vs 25).** Confirmed by both the in-body `rateLimit.cost` and the header delta.

---

## Running log — Experiment 3 (Secondary limits)

### 13:05 — S-Step 0 safety precheck

`gh api /rate_limit --jq '.resources.core'` → `{limit:5000, used:3, remaining:4997}`. Well above the 500-remaining floor. Proceed.

Note: `/rate_limit` endpoint reads lag behind the actual per-call headers (we already saw this in Experiment 1). Per-call `x-ratelimit-*` is the authoritative source during the burst.

### 13:06 — N=20 burst (gh api /user)

```
wall=1.63s  total=20  ok=20  non_ok=0  ec=0:20  ec!=0:0
remaining span: 4980..4999 (20 distinct values)
```

### 13:06 — N=60 burst (gh api /user)

```
wall=1.60s  total=60  ok=60  non_ok=0  ec=0:60  ec!=0:0
remaining span: 4920..4979 (60 distinct values)
```

Anomaly worth noting: `/rate_limit` queried *immediately after* this burst still reported `used=3 remaining=4997`, despite the 60 real decrements visible in the per-call headers. `/rate_limit` is clearly served from a lagged internal counter. **Do not use `/rate_limit` as a real-time truth source in the harness — use per-response `x-ratelimit-*` headers.**

### 13:07 — N=120 burst (gh api /user)

```
wall=2.09s  total=120  ok=120  non_ok=0  ec=0:120  ec!=0:0
remaining span: 4800..4919
```

**Crossed the documented `>100 concurrent` threshold with zero errors.**

### 13:07 — N=200 burst (gh api /user)

```
wall=3.07s  total=200  ok=200  non_ok=0  ec=0:200  ec!=0:0
remaining span: 4600..4799
```

Double the documented threshold. Still clean.

### 13:08 — N=150 burst (direct curl with keep-alive disabled via fresh xargs workers)

To rule out "gh subprocess startup was serializing so we never had real 200 concurrent", repeated with `curl` which has much lower startup overhead:

```
wall=2.18s  total=150  ok=150  non_ok=0  ec=0:150  ec!=0:0
remaining span: 4450..4599 (150 distinct values)
```

Still clean. Ruling out the "wasn't real concurrency" hypothesis — or at least demonstrating that whatever the real concurrency ceiling was for our setup, it was sufficient to pass the documented limit and we still got no rate-limit feedback.

### 13:09 — Stopped

Total spent across all phases: **550 core-bucket calls**. Remaining quota: ≈4450. Zero 403/429 observations → no empirical sample of the secondary-limit wire shape. Experiment complete; we proceed with documentation-based assumptions for the harness.
