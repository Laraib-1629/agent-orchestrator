# GH Trace Harness

## Purpose

This harness records every traced `gh` subprocess invocation to a JSONL file so we can measure:

- request count
- request mix by operation
- HTTP status distribution
- exit-code behavior
- rate-limit headers over time

It is measurement only. It does not change AO's GitHub behavior.

## Enable Tracing

Set:

```bash
export AO_GH_TRACE_FILE="$PWD/experiments/out/gh-trace.jsonl"
```

Then run the AO flow you want to observe.

Any GitHub plugin path that uses the current trace wrapper will append one JSON row per `gh` invocation.

## Current Coverage

- `packages/plugins/scm-github/src/index.ts`
- `packages/plugins/scm-github/src/graphql-batch.ts`
- `packages/plugins/tracker-github/src/index.ts`

## Summarize A Trace

```bash
node experiments/summarize-gh-trace.mjs experiments/out/gh-trace.jsonl
```

## Useful First Scenarios

1. Start AO with tracing enabled and let one quiet PR session poll for a few minutes.
2. Spawn several fresh sessions to measure `detectPR` fan-out.
3. Let a PR sit until review-backlog polling fires.
4. Compare before/after any future rate-limit optimization with the same scenario.
