# GH ETag Verification Experiment

## Goal

Verify whether AO's current `gh api -H "If-None-Match: ..."` path actually delivers usable conditional-request behavior in practice.

This experiment is intentionally narrow. We are **not** optimizing AO yet. We are trying to answer one binary question first:

- Does `gh api` produce a real `304 Not Modified` when we replay a valid `ETag` via `If-None-Match`?

If the answer is **yes**, AO's ETag guard strategy is viable and we can optimize around it.

If the answer is **no**, the current polling cost model is unreliable and any deeper optimization work needs to assume the `gh` transport layer is suspect.

## Why This Matters

AO's current GitHub polling design depends heavily on these two assumptions:

1. `gh api -i` exposes enough HTTP status/header data for AO to distinguish `200` vs `304`.
2. `gh api -H "If-None-Match: ..."` correctly forwards conditional-request headers to GitHub.

If either assumption fails, the current "ETag guard" logic can silently degrade into full-cost polling.

## What We Are Observing

For each endpoint we test, we want to observe:

- Initial HTTP status
- Returned `etag`
- Replay HTTP status when the same `etag` is sent back via `If-None-Match`
- Whether `gh api` and direct `curl` behave the same way
- Whether `x-ratelimit-*` headers are visible and parseable in both cases

## Endpoints To Test

We should test at least these two AO-relevant read paths:

1. Repo PR list guard

```bash
repos/{owner}/{repo}/pulls?state=open&sort=updated&direction=desc&per_page=1
```

2. Commit status guard

```bash
repos/{owner}/{repo}/commits/{sha}/status
```

Optional follow-up:

3. A GraphQL request with stable data, only to verify header visibility and rate-limit introspection on the GraphQL path.

## What I Need From You

I can start with a public repository immediately, but for a meaningful AO validation I need one of these from you:

- Preferred test repo in `owner/repo` format
- Preferred PR number in that repo
- Preferred commit SHA for the commit-status endpoint

If you do not care which repo we use, I will choose a stable public repo with at least one open PR and document exactly which repo/PR/SHA were used.

## Local Prerequisites Already Verified

- `gh` installed: `2.86.0`
- `gh auth status`: authenticated to `github.com`
- Token scopes visible: `gist`, `read:org`, `repo`, `workflow`

## Experiment Method

### Step 1 — Baseline with `gh api`

Run the endpoint once with `-i` and capture:

- status line
- `etag`
- `x-ratelimit-limit`
- `x-ratelimit-remaining`
- `x-ratelimit-reset`

### Step 2 — Replay with `If-None-Match`

Run the same endpoint again via `gh api -i -H "If-None-Match: <etag>"`.

Expected result:

- `304 Not Modified`

Unexpected result:

- `200 OK`
- missing status line
- missing/changed `etag` handling

### Step 3 — Compare Against `curl`

Run the same conditional-request flow directly against `api.github.com` using the same token.

Purpose:

- separate GitHub server behavior from `gh` CLI behavior

If `curl` returns `304` and `gh api` does not, that strongly suggests the CLI path is the problem.

### Step 4 — Repeat on Commit Status Endpoint

The PR-list endpoint is AO Guard 1.
The commit-status endpoint is AO Guard 2.

We need both to behave correctly before trusting the current AO design.

## Success Criteria

We can say the current `gh`-based ETag guard is empirically valid only if all of the following are true:

- `gh api` returns `200` + `etag` on the first request
- `gh api` returns `304` on replay with the same `etag`
- `curl` matches `gh api`
- status/header parsing is stable enough for AO to automate

## Failure Criteria

Any of the following counts as a failure or design risk:

- replayed `If-None-Match` still returns `200`
- `etag` is absent or malformed
- `gh api` hides status/header semantics AO needs
- `curl` and `gh api` disagree

## Implication Matrix

| Result | Meaning | Next move |
| --- | --- | --- |
| `gh` and `curl` both return `304` reliably | Current ETag guard is real | Build harness and optimize around current transport |
| `curl` returns `304`, `gh` does not | `gh` transport path is suspect | Design around replacing or wrapping `gh` |
| Neither returns `304` | Endpoint/test assumptions are wrong | Fix experiment inputs, then retest |

## Logging Template

### Run Metadata

- Date: `2026-04-14T12:33:20Z`
- Repo: `ComposioHQ/agent-orchestrator`
- PR number: `1236`
- Commit SHA: `7638871b545239c81f6240669c11ad1bfaab0289`
- Tester: Codex

### Observation Log

| Step | Tool | Endpoint | Request headers | Response status | ETag seen | Rate-limit headers seen | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | `gh api` | PR list | none | `HTTP/2.0 200 OK` | `W/"afb0be63d36ad6eac4c6d2a141c56b0a0a940995798b8d0b75d2e4399ac761f0"` | `x-ratelimit-limit=5000`, `x-ratelimit-remaining=4982`, `x-ratelimit-reset=1776170523` | `gh api -i` prints status and headers correctly |
| 2 | `gh api` | PR list | `If-None-Match: W/"afb0be63d36ad6eac4c6d2a141c56b0a0a940995798b8d0b75d2e4399ac761f0"` | `HTTP/2.0 304 Not Modified` | same weak ETag returned | `5000 / 4982 / 1776170523` | **Important:** `gh` exits with code `1` on `304` even though the conditional request succeeded |
| 3 | `curl` | PR list | none | `HTTP/2 200` | `"e54c00e380ff044905564442d5f2306872ceedaad06cc7c352cc1947de01f4ec"` | `5000 / 4981 / 1776170523` | Direct API baseline |
| 4 | `curl` | PR list | `If-None-Match: "e54c00e380ff044905564442d5f2306872ceedaad06cc7c352cc1947de01f4ec"` | `HTTP/2 304` | unchanged | `5000 / 4981 / 1776170523` | Primary rate-limit remaining stayed constant across `200 -> 304` |
| 5 | `gh api` | commit status | none | `HTTP/2.0 200 OK` | `W/"0d0e6a1704888202d250b6e96f0d54ebe50e7ccd817cecfb4420b1a09030a15a"` | `5000 / 4980 / 1776170523` | Guard 2 baseline |
| 6 | `gh api` | commit status | `If-None-Match: W/"0d0e6a1704888202d250b6e96f0d54ebe50e7ccd817cecfb4420b1a09030a15a"` | `HTTP/2.0 304 Not Modified` | same weak ETag returned | `5000 / 4980 / 1776170523` | Again, `gh` exits with code `1` on `304` |
| 7 | `curl` | commit status | none | `HTTP/2 200` | `"a155cdd431bce6999da58359061ef8f852ae7cca587214a4716b4a6ca943d173"` | `5000 / 4979 / 1776170523` | Direct API baseline |
| 8 | `curl` | commit status | `If-None-Match: "a155cdd431bce6999da58359061ef8f852ae7cca587214a4716b4a6ca943d173"` | `HTTP/2 304` | unchanged | `5000 / 4979 / 1776170523` | Same primary-limit behavior as PR-list endpoint |

## Findings

1. `gh api` **does** support AO's conditional-request path for both tested endpoints.
   It returned real `304 Not Modified` responses for:
   - repo PR list guard
   - commit status guard

2. The real integration hazard is not header forwarding. It is **process exit behavior**.
   `gh api` exited with code `1` on both successful `304` responses.

3. This matters directly for AO because the current implementation uses `execFileAsync("gh", ...)`.
   In Node, a non-zero subprocess exit rejects the promise.
   That means AO can easily misclassify a successful `304` as an error unless it handles this case explicitly.

4. `gh api -i` exposes the headers AO needs.
   Observed:
   - status line
   - `etag`
   - `x-ratelimit-limit`
   - `x-ratelimit-remaining`
   - `x-ratelimit-reset`

5. For both `gh` and `curl`, `x-ratelimit-remaining` stayed unchanged across the `200 -> 304` replay pair.
   This is consistent with GitHub's documented primary-rate-limit behavior for authorized conditional requests.

6. `gh` and `curl` produced **different ETag strings** for the same endpoint.
   Observed example on the PR-list endpoint:
   - `gh`: weak ETag `W/"afb0be63..."`
   - `curl`: strong ETag `"e54c00e3..."`

7. Those ETags are **not interchangeable across clients**.
   Cross-check on the PR-list endpoint:
   - `gh` with `curl`'s ETag -> `HTTP/2.0 200 OK`
   - `curl` with `gh`'s ETag -> `HTTP/2 200`

## Interpretation

- AO's current `gh`-based ETag guard is **viable**, but only if the subprocess layer treats `304` as a success path instead of a failure path.
- Any future migration from `gh` to a direct HTTP client should assume cached ETags are transport-specific and should not be reused blindly.
- The next harness should record both:
  - HTTP status semantics
  - subprocess exit semantics

Because with `gh`, those are not the same thing.

## Notes For AO Follow-up

If this experiment passes, the next build target should be a request harness that records:

- request count by AO phase
- request count by session
- peak concurrency
- `200` vs `304` rate
- `x-ratelimit-remaining` over time
- secondary-limit responses and `retry-after`

That harness will be the basis for validating all future rate-limit optimizations.
