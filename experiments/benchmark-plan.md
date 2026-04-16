# Benchmark Harness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement `experiments/benchmark.mjs` — a repeatable benchmark harness that measures AO's GitHub API consumption and produces a scorecard for before/after comparison of rate-limiting fixes.

**Architecture:** Single Node.js ESM script with three CLI modes (`setup`, `measure`, `report`). Shells out to `ao` CLI and `gh` CLI via `child_process`. No external dependencies — Node.js stdlib only. Reads `agent-orchestrator.yaml` for project config (YAML parsed with a minimal inline parser). All output artifacts go to `experiments/out/`.

**Tech Stack:** Node.js 20+, ESM (`import`), `node:child_process`, `node:fs`, `node:path`, `node:timers/promises`

---

## File Structure

| File | Responsibility |
|------|---------------|
| `experiments/benchmark.mjs` | The entire harness — CLI parsing, all three modes, scorecard computation, console output |

No other files created or modified. This is a standalone experiment script.

---

### Task 1: CLI Skeleton + Arg Parsing + Dispatch

**Files:**
- Create: `experiments/benchmark.mjs`

Sets up the entry point: shebang, imports, CLI arg parser, mode dispatch, and usage/error helpers.

- [ ] **Step 1: Create file with shebang, imports, and constants**

```javascript
#!/usr/bin/env node

import { execFile, spawn as spawnChild } from "node:child_process";
import { readFileSync, writeFileSync, existsSync, mkdirSync, readdirSync } from "node:fs";
import { resolve, dirname, join, basename } from "node:path";
import { promisify } from "node:util";
import { setTimeout as sleep } from "node:timers/promises";
import { homedir } from "node:os";

const execFileAsync = promisify(execFile);

const BENCHMARK_VERSION = "0.1.0";
const SCHEMA_VERSION = 1;
const OUT_DIR = resolve(dirname(new URL(import.meta.url).pathname), "out");
const AO_CLI = resolve(dirname(new URL(import.meta.url).pathname), "..", "packages", "cli", "dist", "index.js");
```

- [ ] **Step 2: Add CLI arg parser**

```javascript
/** Parse CLI args into { mode, flags }. No libraries — just process.argv. */
function parseArgs() {
  const args = process.argv.slice(2);
  const mode = args[0];
  const flags = {};
  for (let i = 1; i < args.length; i++) {
    const arg = args[i];
    if (arg.startsWith("--")) {
      const key = arg.slice(2);
      const next = args[i + 1];
      if (next && !next.startsWith("--")) {
        flags[key] = next;
        i++;
      } else {
        flags[key] = true;
      }
    }
  }
  return { mode, flags };
}
```

- [ ] **Step 3: Add usage function and mode dispatch**

```javascript
function usage() {
  console.error(`Usage:
  node experiments/benchmark.mjs setup   --project <name> --sessions <n> --issues <1,2,3,...>
  node experiments/benchmark.mjs measure --project <name> --sessions <n> --duration <15m> [--warmup <2m>]
  node experiments/benchmark.mjs report  --trace <path> [--warmup-end <ISO timestamp>]`);
  process.exit(1);
}

function die(msg) {
  console.error(`\x1b[31mError: ${msg}\x1b[0m`);
  process.exit(1);
}

const { mode, flags } = parseArgs();
if (!mode || !["setup", "measure", "report"].includes(mode)) usage();
```

- [ ] **Step 4: Add mode dispatch at bottom of file**

```javascript
// Mode dispatch (at end of file, after all function definitions)
if (mode === "setup") {
  await runSetup(flags);
} else if (mode === "measure") {
  await runMeasure(flags);
} else if (mode === "report") {
  await runReport(flags);
}
```

- [ ] **Step 5: Verify the skeleton runs**

Run: `node experiments/benchmark.mjs`
Expected: prints usage and exits with code 1

Run: `node experiments/benchmark.mjs setup`
Expected: errors about missing flags (once Task 3 is implemented — for now, add stub functions)

Add temporary stubs so the file parses:
```javascript
async function runSetup(flags) { die("setup not implemented"); }
async function runMeasure(flags) { die("measure not implemented"); }
async function runReport(flags) { die("report not implemented"); }
```

---

### Task 2: Shared Utilities

**Files:**
- Modify: `experiments/benchmark.mjs`

Add all shared helpers used across modes. Place these between the arg parser and the mode implementations.

- [ ] **Step 1: Add parseDuration**

Parses strings like `"2m"`, `"15m"`, `"1h"` into milliseconds.

```javascript
/** Parse duration string (e.g. "2m", "15m", "1h") to milliseconds. */
function parseDuration(str) {
  const match = str.match(/^(\d+)(s|m|h)$/);
  if (!match) die(`Invalid duration: "${str}". Use format like 2m, 15m, 1h.`);
  const value = parseInt(match[1], 10);
  const unit = match[2];
  if (unit === "s") return value * 1000;
  if (unit === "m") return value * 60_000;
  if (unit === "h") return value * 3_600_000;
}
```

- [ ] **Step 2: Add exec helpers**

```javascript
/** Run a command and return stdout. Throws on non-zero exit. */
async function run(cmd, args, opts = {}) {
  const { stdout } = await execFileAsync(cmd, args, {
    maxBuffer: 10 * 1024 * 1024,
    timeout: opts.timeout ?? 30_000,
    cwd: opts.cwd,
    env: opts.env ?? process.env,
  });
  return stdout.trim();
}

/** Run `gh` CLI without the trace env var (benchmark-control call). */
async function ghControl(args, opts = {}) {
  const env = { ...process.env };
  delete env.AO_GH_TRACE_FILE;
  return run("gh", args, { ...opts, env });
}

/** Get current git SHA (short). */
function gitSha() {
  try {
    const { execSync } = await import("node:child_process");
    // Can't use async here easily, use execFileSync instead
    return require("node:child_process").execFileSync("git", ["rev-parse", "--short", "HEAD"], {
      encoding: "utf-8",
    }).trim();
  } catch {
    return "unknown";
  }
}
```

Wait — this is ESM, we can't use `require`. Let me fix:

```javascript
import { execFileSync } from "node:child_process";

/** Get current git SHA (short). */
function gitSha() {
  try {
    return execFileSync("git", ["rev-parse", "--short", "HEAD"], {
      encoding: "utf-8",
      timeout: 5000,
    }).trim();
  } catch {
    return "unknown";
  }
}

/** Get current git branch. */
function gitBranch() {
  try {
    return execFileSync("git", ["branch", "--show-current"], {
      encoding: "utf-8",
      timeout: 5000,
    }).trim();
  } catch {
    return "unknown";
  }
}
```

Update imports at top of file to include `execFileSync`:

```javascript
import { execFile, execFileSync, spawn as spawnChild } from "node:child_process";
```

- [ ] **Step 3: Add YAML config loader**

The benchmark needs to read `agent-orchestrator.yaml` to find `repo` and `path` for a project. We use a minimal approach — parse just enough YAML to extract what we need. The config uses simple key-value YAML without advanced features.

```javascript
/**
 * Minimal YAML parser — handles the flat project config we need.
 * Reads agent-orchestrator.yaml via AO's config search logic:
 * AO_CONFIG_PATH env, then search up from cwd, then ~/agent-orchestrator.yaml.
 */
function findConfig() {
  if (process.env.AO_CONFIG_PATH && existsSync(process.env.AO_CONFIG_PATH)) {
    return process.env.AO_CONFIG_PATH;
  }
  const names = ["agent-orchestrator.yaml", "agent-orchestrator.yml"];
  let dir = process.cwd();
  while (true) {
    for (const name of names) {
      const p = join(dir, name);
      if (existsSync(p)) return p;
    }
    const parent = dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  const home = homedir();
  for (const name of names) {
    const p = join(home, name);
    if (existsSync(p)) return p;
  }
  return null;
}

/**
 * Extract project config from agent-orchestrator.yaml.
 * Returns { repo, path, defaultBranch, sessionPrefix }.
 * Uses a line-based parser — sufficient for the flat structure we need.
 */
function loadProjectConfig(projectName) {
  const configPath = findConfig();
  if (!configPath) die("Cannot find agent-orchestrator.yaml");

  const raw = readFileSync(configPath, "utf-8");
  const lines = raw.split("\n");

  // Find the project block: "  projectName:" under "projects:"
  let inProjects = false;
  let inTarget = false;
  let indent = 0;
  const config = {};

  for (const line of lines) {
    const trimmed = line.trimStart();
    const currentIndent = line.length - trimmed.length;

    if (trimmed === "projects:" || trimmed === "projects: ") {
      inProjects = true;
      continue;
    }

    if (inProjects && !inTarget) {
      if (trimmed === `${projectName}:` || trimmed.startsWith(`${projectName}: `)) {
        inTarget = true;
        indent = currentIndent;
        continue;
      }
    }

    if (inTarget) {
      // If we've de-dented back to or past the project key level, we're done
      if (currentIndent <= indent && trimmed.length > 0) break;

      const kvMatch = trimmed.match(/^(\w[\w-]*)\s*:\s*(.+)$/);
      if (kvMatch) {
        config[kvMatch[1]] = kvMatch[2].replace(/^["']|["']$/g, "");
      }
    }
  }

  if (!config.repo) die(`Project "${projectName}" not found in config or missing repo field`);
  if (!config.path) die(`Project "${projectName}" missing path field in config`);

  return {
    repo: config.repo,
    path: config.path.replace(/^~/, homedir()),
    defaultBranch: config.defaultBranch || "main",
    sessionPrefix: config.sessionPrefix || projectName.replace(/[^a-zA-Z0-9]/g, "").slice(0, 4).toLowerCase(),
  };
}
```

- [ ] **Step 4: Add percentile and formatting helpers**

```javascript
/** Compute percentile from sorted array. */
function percentile(sortedArr, p) {
  if (sortedArr.length === 0) return 0;
  const idx = Math.min(sortedArr.length - 1, Math.floor(sortedArr.length * p));
  return sortedArr[idx];
}

/** Format number with commas. */
function fmt(n) {
  return n.toLocaleString("en-US");
}

/** Ensure output directory exists. */
function ensureOutDir() {
  mkdirSync(OUT_DIR, { recursive: true });
}
```

- [ ] **Step 5: Verify utilities work**

Run: `node -e "import('./experiments/benchmark.mjs')"`
Expected: prints usage (since no mode given) — confirms the file parses without syntax errors.

---

### Task 3: Scorecard Computation Engine

**Files:**
- Modify: `experiments/benchmark.mjs`

The core math that turns trace rows + optional rate-limit snapshots into a scorecard object. Used by both `measure` and `report` modes.

- [ ] **Step 1: Add trace reader**

```javascript
/** Read and parse a JSONL trace file. Returns array of entry objects. */
function readTrace(tracePath) {
  if (!existsSync(tracePath)) die(`Trace file not found: ${tracePath}`);
  const raw = readFileSync(tracePath, "utf-8");
  return raw.split("\n").filter(Boolean).map((line) => JSON.parse(line));
}
```

- [ ] **Step 2: Add per-window burn rate computation**

This is the authoritative method — groups trace rows by `rateLimitReset` value for each resource, computes delta within each window, sums across windows, normalizes to per-hour.

```javascript
/**
 * Compute per-hour burn rate from trace rows using per-window method.
 * Groups rows by rateLimitReset, computes remaining delta per window,
 * sums across windows, normalizes to 1 hour.
 *
 * Returns { pointsPerHr, estimated: false, straddled, windows } or null if no data.
 */
function computeBurnRate(rows, resource, windowDurationMs) {
  const withRL = rows.filter(
    (r) =>
      typeof r.rateLimitRemaining === "number" &&
      r.rateLimitResource === resource,
  );
  if (withRL.length < 2) return null;

  // Group by rateLimitReset
  const windowMap = new Map();
  for (const r of withRL) {
    const key = r.rateLimitReset ?? "unknown";
    if (!windowMap.has(key)) windowMap.set(key, []);
    windowMap.get(key).push(r);
  }

  let totalDelta = 0;
  const windows = [];
  for (const [resetEpoch, windowRows] of windowMap.entries()) {
    if (windowRows.length < 2) continue;
    const first = windowRows[0];
    const last = windowRows[windowRows.length - 1];
    const delta = first.rateLimitRemaining - last.rateLimitRemaining;
    totalDelta += Math.max(0, delta); // ignore negative deltas (refills)
    windows.push({
      resetAt: typeof resetEpoch === "number"
        ? new Date(resetEpoch * 1000).toISOString()
        : "unknown",
      delta,
      rows: windowRows.length,
    });
  }

  const durationHr = windowDurationMs / 3_600_000;
  return {
    pointsPerHr: durationHr > 0 ? Math.round(totalDelta / durationHr) : 0,
    estimated: false,
    straddled: windowMap.size > 1,
    windows,
  };
}
```

- [ ] **Step 3: Add computeScorecard function**

```javascript
/**
 * Compute scorecard from trace rows and optional rate-limit snapshots.
 *
 * @param {object[]} allRows - All trace rows (including warmup)
 * @param {string} windowStart - ISO timestamp of measurement window start
 * @param {string} windowEnd - ISO timestamp of measurement window end
 * @param {object|null} snapshots - { before, after } rate-limit snapshots, or null
 * @param {number} benchmarkControlCalls - Count of GH calls made by the harness
 * @returns {object} Scorecard object matching the spec schema
 */
function computeScorecard(allRows, windowStart, windowEnd, snapshots, benchmarkControlCalls) {
  const startMs = new Date(windowStart).getTime();
  const endMs = new Date(windowEnd).getTime();
  const windowDurationMs = endMs - startMs;
  const windowDurationMin = windowDurationMs / 60_000;

  // Filter to measurement window only, exclude benchmark-control rows
  const rows = allRows.filter((r) => {
    const ts = new Date(r.timestamp).getTime();
    if (ts < startMs || ts > endMs) return false;
    if (r.component === "benchmark-control") return false;
    return true;
  });

  const totalCalls = rows.length;
  const callsPerMin = windowDurationMin > 0 ? +(totalCalls / windowDurationMin).toFixed(1) : 0;

  // GraphQL burn rate (per-window method)
  const graphqlBurn = computeBurnRate(rows, "graphql", windowDurationMs);
  // REST core burn rate (per-window method)
  const coreBurn = computeBurnRate(rows, "core", windowDurationMs);

  // Bracket delta from snapshots (fallback source)
  let bracketDelta = { core: null, graphql: null };
  if (snapshots) {
    bracketDelta = {
      core: (snapshots.before.core?.remaining ?? 0) - (snapshots.after.core?.remaining ?? 0),
      graphql: (snapshots.before.graphql?.remaining ?? 0) - (snapshots.after.graphql?.remaining ?? 0),
    };
  }

  // GraphQL points/hr — prefer per-row, fallback to bracket delta
  let graphqlPointsPerHr = 0;
  let graphqlPointsPerHrEstimated = false;
  if (graphqlBurn) {
    graphqlPointsPerHr = graphqlBurn.pointsPerHr;
  } else if (bracketDelta.graphql !== null && bracketDelta.graphql > 0) {
    const durationHr = windowDurationMs / 3_600_000;
    graphqlPointsPerHr = durationHr > 0 ? Math.round(bracketDelta.graphql / durationHr) : 0;
    graphqlPointsPerHrEstimated = true;
  }

  // REST core requests/hr — same logic
  let restCoreRequestsPerHr = 0;
  let restCoreRequestsPerHrEstimated = false;
  if (coreBurn) {
    restCoreRequestsPerHr = coreBurn.pointsPerHr;
  } else if (bracketDelta.core !== null && bracketDelta.core > 0) {
    const durationHr = windowDurationMs / 3_600_000;
    restCoreRequestsPerHr = durationHr > 0 ? Math.round(bracketDelta.core / durationHr) : 0;
    restCoreRequestsPerHrEstimated = true;
  }

  // Operation counts
  const graphqlBatchCount = rows.filter((r) => r.operation === "gh.api.graphql-batch").length;

  const guardPrListRows = rows.filter((r) => r.operation === "gh.api.guard-pr-list");
  const guardPrList304Count = guardPrListRows.filter((r) => r.httpStatus === 304).length;
  const guardPrListSuccessCount = guardPrListRows.filter((r) => r.ok && r.httpStatus !== 304).length;
  const guardPrListErrorCount = guardPrListRows.filter((r) => !r.ok && r.httpStatus !== 304).length;
  const guardPrListTotal = guardPrList304Count + guardPrListSuccessCount + guardPrListErrorCount;
  const guardPrList304Rate = guardPrListTotal > 0 ? +(guardPrList304Count / guardPrListTotal).toFixed(3) : 0;

  // Opaque calls (no HTTP status)
  const opaqueCallCount = rows.filter((r) => r.httpStatus === undefined || r.httpStatus === null).length;
  const opaqueCallPct = totalCalls > 0 ? +(opaqueCallCount / totalCalls).toFixed(2) : 0;

  // Duration percentiles
  const durations = rows.map((r) => Number(r.durationMs) || 0).sort((a, b) => a - b);

  // Resource windows
  const resourceWindows = {
    graphql: graphqlBurn
      ? { resetAt: graphqlBurn.windows[0]?.resetAt ?? null, straddled: graphqlBurn.straddled }
      : { resetAt: null, straddled: false },
    core: coreBurn
      ? { resetAt: coreBurn.windows[0]?.resetAt ?? null, straddled: coreBurn.straddled }
      : { resetAt: null, straddled: false },
  };

  return {
    totalCalls,
    callsPerMin,
    graphqlPointsPerHr,
    graphqlPointsPerHrEstimated,
    restCoreRequestsPerHr,
    restCoreRequestsPerHrEstimated,
    graphqlBatchCount,
    guardPrList304Count,
    guardPrListErrorCount,
    guardPrList304Rate,
    opaqueCallCount,
    opaqueCallPct,
    bracketDelta,
    p50DurationMs: percentile(durations, 0.5),
    p95DurationMs: percentile(durations, 0.95),
    p99DurationMs: percentile(durations, 0.99),
    benchmarkControlCalls: benchmarkControlCalls ?? null,
    resourceWindows,
  };
}
```

- [ ] **Step 4: Verify scorecard computation with existing trace**

Run: `node -e "
import { readFileSync } from 'node:fs';
// Quick inline test — will be replaced by report mode
"` (or just verify the file still parses: `node experiments/benchmark.mjs`)

Expected: exits with usage message (no mode given), confirming no syntax errors.

- [ ] **Step 5: Commit**

```bash
git add experiments/benchmark.mjs
git commit -m "feat(experiments): add benchmark harness skeleton with scorecard engine

Implements CLI parsing, shared utilities, and scorecard computation
for the rate-limit benchmark harness (experiments/benchmark.mjs).
Three modes stubbed: setup, measure, report."
```

---

### Task 4: Console Output (printScorecard)

**Files:**
- Modify: `experiments/benchmark.mjs`

Implements the formatted console output with budget progress bars matching the spec.

- [ ] **Step 1: Add progress bar renderer**

```javascript
/** Render a budget progress bar. Green <50%, yellow 50-80%, red >80%. */
function budgetBar(used, budget, width = 20) {
  const pct = budget > 0 ? used / budget : 0;
  const filled = Math.round(pct * width);
  const empty = width - filled;
  const bar = "\u2588".repeat(filled) + "\u2591".repeat(empty);

  const isTTY = process.stdout.isTTY;
  const pctStr = `${(pct * 100).toFixed(0)}%`;

  if (!isTTY) return `${bar}  ${pctStr}`;

  let color;
  if (pct < 0.5) color = "\x1b[32m";       // green
  else if (pct < 0.8) color = "\x1b[33m";   // yellow
  else color = "\x1b[31m";                   // red

  return `${color}${bar}\x1b[0m  ${pctStr}`;
}
```

- [ ] **Step 2: Add printScorecard function**

```javascript
/**
 * Print formatted scorecard to stdout.
 * Matches the console output format from the spec.
 */
function printScorecard(envelope) {
  const sc = envelope.scorecard;
  const w = envelope.window;
  const warmupStr = envelope.warmup?.requested ?? "none";
  const durationStr = w.durationActual ?? w.durationRequested;
  const sessions = envelope.sessionCount;

  const line = "=".repeat(59);
  console.log(`\n${line}`);
  console.log(`  GH Rate-Limit Benchmark`);
  console.log(`  ${envelope.scenarioId} | ${envelope.gitSha} | ${envelope.branch}`);
  console.log(`  ${envelope.measuredAt} | warmup ${warmupStr} | measured ${durationStr} | ${sessions} sessions`);
  console.log(line);

  console.log();
  console.log(`  Total GH calls:          ${fmt(sc.totalCalls).padStart(6)}`);
  console.log(`  Calls/min:               ${String(sc.callsPerMin).padStart(6)}`);

  console.log();
  const gqlStr = fmt(sc.graphqlPointsPerHr).padStart(6);
  const gqlEst = sc.graphqlPointsPerHrEstimated ? " (estimated)" : "";
  console.log(`  GraphQL points/hr:     ${gqlStr}  / 5,000  ${budgetBar(sc.graphqlPointsPerHr, 5000)}${gqlEst}`);

  const coreStr = fmt(sc.restCoreRequestsPerHr).padStart(6);
  const coreEst = sc.restCoreRequestsPerHrEstimated ? " (estimated)" : "";
  console.log(`  REST core requests/hr: ${coreStr}  / 5,000  ${budgetBar(sc.restCoreRequestsPerHr, 5000)}${coreEst}`);

  console.log();
  console.log(`  graphql-batch count:     ${fmt(sc.graphqlBatchCount).padStart(6)}`);
  console.log(`  guard-pr-list 304s:      ${fmt(sc.guardPrList304Count).padStart(6)}  (${(sc.guardPrList304Rate * 100).toFixed(1)}%)`);
  console.log(`  guard-pr-list errors:    ${fmt(sc.guardPrListErrorCount).padStart(6)}`);

  console.log();
  console.log(`  Opaque calls:            ${fmt(sc.opaqueCallCount).padStart(6)}  (${(sc.opaqueCallPct * 100).toFixed(1)}%)`);
  if (sc.bracketDelta.core !== null) {
    console.log(`  Bracket delta (core):    ${fmt(sc.bracketDelta.core).padStart(6)}`);
  }
  if (sc.bracketDelta.graphql !== null) {
    console.log(`  Bracket delta (graphql): ${fmt(sc.bracketDelta.graphql).padStart(6)}`);
  }

  console.log();
  console.log(`  p50 / p95 / p99:     ${fmt(sc.p50DurationMs)} / ${fmt(sc.p95DurationMs)} / ${fmt(sc.p99DurationMs)} ms`);

  console.log();
  if (envelope.trace) {
    console.log(`  Trace:     ${envelope.trace}`);
  }
  if (envelope.scorecardPath) {
    console.log(`  Scorecard: ${envelope.scorecardPath}`);
  }
  console.log(line);
  console.log();
}
```

- [ ] **Step 3: Commit**

```bash
git add experiments/benchmark.mjs
git commit -m "feat(experiments): add scorecard console output with budget bars"
```

---

### Task 5: Report Mode

**Files:**
- Modify: `experiments/benchmark.mjs`

Implement `report` first since it's the simplest mode and lets us verify scorecard computation against existing trace data.

- [ ] **Step 1: Implement runReport**

Replace the stub with the full implementation:

```javascript
async function runReport(flags) {
  const tracePath = flags.trace;
  if (!tracePath) die("--trace is required for report mode");

  const warmupEnd = flags["warmup-end"] ?? null;
  const resolvedTrace = resolve(tracePath);

  console.error(`Reading trace: ${resolvedTrace}`);
  const allRows = readTrace(resolvedTrace);
  console.error(`Loaded ${allRows.length} trace entries`);

  if (allRows.length === 0) die("Trace file is empty");

  // Determine window boundaries
  const timestamps = allRows.map((r) => new Date(r.timestamp).getTime()).sort((a, b) => a - b);
  const windowStart = warmupEnd ?? new Date(timestamps[0]).toISOString();
  const windowEnd = new Date(timestamps[timestamps.length - 1]).toISOString();

  const scorecard = computeScorecard(allRows, windowStart, windowEnd, null, null);

  // Null out fields unavailable in report mode
  scorecard.bracketDelta = { core: null, graphql: null };
  scorecard.benchmarkControlCalls = null;

  const windowDurationMs = timestamps[timestamps.length - 1] - (warmupEnd ? new Date(warmupEnd).getTime() : timestamps[0]);
  const durationMin = windowDurationMs / 60_000;

  const envelope = {
    schemaVersion: SCHEMA_VERSION,
    benchmarkVersion: BENCHMARK_VERSION,
    scenarioId: "report",
    gitSha: gitSha(),
    branch: gitBranch(),
    measuredAt: new Date().toISOString(),
    sessionCount: "?",
    warmup: warmupEnd ? { requested: "?", actualEnd: warmupEnd } : null,
    window: {
      start: windowStart,
      end: windowEnd,
      durationRequested: "?",
      durationActual: `${durationMin.toFixed(0)}m ${Math.round((durationMin % 1) * 60)}s`,
    },
    resourceWindows: scorecard.resourceWindows,
    rateLimitSnapshots: null,
    scorecard,
    trace: resolvedTrace,
    supplemental: null,
  };

  // Write scorecard
  ensureOutDir();
  const ts = Math.floor(Date.now() / 1000);
  const scorecardPath = join(OUT_DIR, `scorecard-report-${ts}.json`);
  writeFileSync(scorecardPath, JSON.stringify(envelope, null, 2) + "\n");
  envelope.scorecardPath = scorecardPath;

  printScorecard(envelope);
  console.error(`Scorecard written to: ${scorecardPath}`);
}
```

- [ ] **Step 2: Test report mode with existing trace**

Run: `node experiments/benchmark.mjs report --trace experiments/out/gh-trace-verify-1776345900.jsonl`

Expected: prints a scorecard with the numbers we already know from baseline.md:
- ~234 total calls
- ~10.5 calls/min
- 27 guard-pr-list 304s
- graphql burn rate (may be estimated from bracket delta since this is report mode)

Verify the output looks reasonable and matches the known data.

- [ ] **Step 3: Commit**

```bash
git add experiments/benchmark.mjs
git commit -m "feat(experiments): implement report mode for benchmark harness

Validates scorecard computation against existing trace data."
```

---

### Task 6: Setup Mode

**Files:**
- Modify: `experiments/benchmark.mjs`

Implements the full setup flow: start AO, spawn sessions, wait for PRs, write setup artifact.

- [ ] **Step 1: Add AO process management helpers**

```javascript
/**
 * Start AO as a child process. Returns the ChildProcess.
 * Does NOT set AO_GH_TRACE_FILE — setup calls must not pollute traces.
 */
function startAO(project, opts = {}) {
  const args = ["start", project, "--no-dashboard"];
  if (opts.noOrchestrator) args.push("--no-orchestrator");
  const env = { ...process.env };
  if (opts.traceFile) {
    env.AO_GH_TRACE_FILE = opts.traceFile;
  } else {
    delete env.AO_GH_TRACE_FILE;
  }

  console.error(`Starting AO: node ${AO_CLI} ${args.join(" ")}`);
  const child = spawnChild("node", [AO_CLI, ...args], {
    stdio: ["ignore", "pipe", "pipe"],
    env,
    detached: false,
  });

  // Log AO output to stderr for debugging
  child.stdout?.on("data", (chunk) => {
    for (const line of chunk.toString().split("\n").filter(Boolean)) {
      console.error(`  [ao] ${line}`);
    }
  });
  child.stderr?.on("data", (chunk) => {
    for (const line of chunk.toString().split("\n").filter(Boolean)) {
      console.error(`  [ao:err] ${line}`);
    }
  });

  return child;
}

/**
 * Stop AO process. SIGTERM first, SIGKILL after timeout.
 */
async function stopAO(child, timeoutMs = 10_000) {
  if (!child || child.exitCode !== null) return;
  console.error("Stopping AO...");
  child.kill("SIGTERM");
  const deadline = Date.now() + timeoutMs;
  while (child.exitCode === null && Date.now() < deadline) {
    await sleep(500);
  }
  if (child.exitCode === null) {
    console.error("AO did not exit in time, sending SIGKILL");
    child.kill("SIGKILL");
    await sleep(1000);
  }
  console.error(`AO exited with code ${child.exitCode}`);
}
```

- [ ] **Step 2: Add scenarioId builder and artifact path helpers**

```javascript
/** Build scenarioId from components. v1 hardcodes scenario=quiet-steady, topology=single-repo. */
function buildScenarioId(sessionCount) {
  return `quiet-steady.single-repo.${sessionCount}`;
}

/** Path to setup artifact. */
function setupArtifactPath(project, scenarioId) {
  return join(OUT_DIR, `setup-${project}-${scenarioId}.json`);
}
```

- [ ] **Step 3: Add session discovery helpers**

```javascript
/**
 * List worktrees for a project and extract session mappings.
 * Returns Map<sessionId, worktreePath>.
 */
async function discoverWorktrees(projectPath) {
  const output = await run("git", ["-C", projectPath, "worktree", "list", "--porcelain"]);
  const worktrees = new Map();
  let currentPath = null;
  for (const line of output.split("\n")) {
    if (line.startsWith("worktree ")) {
      currentPath = line.slice(9);
    } else if (line === "" && currentPath) {
      // Extract session ID from worktree path (last component)
      const name = basename(currentPath);
      worktrees.set(name, currentPath);
      currentPath = null;
    }
  }
  // Handle last entry if no trailing newline
  if (currentPath) {
    worktrees.set(basename(currentPath), currentPath);
  }
  return worktrees;
}

/**
 * Get branch for a worktree path.
 */
async function getWorktreeBranch(worktreePath) {
  try {
    return await run("git", ["-C", worktreePath, "branch", "--show-current"]);
  } catch {
    return null;
  }
}
```

- [ ] **Step 4: Implement runSetup**

Replace the stub:

```javascript
async function runSetup(flags) {
  const project = flags.project;
  const sessionCount = parseInt(flags.sessions, 10);
  const issuesRaw = flags.issues;

  if (!project) die("--project is required");
  if (!sessionCount || sessionCount < 1) die("--sessions must be a positive integer");
  if (!issuesRaw) die("--issues is required (comma-separated issue numbers)");

  const issues = issuesRaw.split(",").map((s) => s.trim()).filter(Boolean);
  if (issues.length !== sessionCount) {
    die(`Issue count (${issues.length}) must equal session count (${sessionCount})`);
  }

  const scenarioId = buildScenarioId(sessionCount);
  const artifactPath = setupArtifactPath(project, scenarioId);
  const projectConfig = loadProjectConfig(project);

  console.error(`\n=== Benchmark Setup ===`);
  console.error(`Project:   ${project}`);
  console.error(`Repo:      ${projectConfig.repo}`);
  console.error(`Sessions:  ${sessionCount}`);
  console.error(`Issues:    ${issues.join(", ")}`);
  console.error(`Scenario:  ${scenarioId}`);
  console.error();

  // Check for existing setup artifact
  if (existsSync(artifactPath)) {
    console.error(`Found existing setup artifact: ${artifactPath}`);
    try {
      const existing = JSON.parse(readFileSync(artifactPath, "utf-8"));
      // Validate it's still usable
      let allValid = true;
      for (const s of existing.sessions || []) {
        if (!existsSync(s.worktreePath)) {
          console.error(`  Stale: worktree missing for ${s.sessionId} at ${s.worktreePath}`);
          allValid = false;
          break;
        }
      }
      if (allValid && existing.ready) {
        console.error(`Setup already exists and is valid. Reusing.`);
        console.error(`To force re-setup, delete: ${artifactPath}`);
        return;
      }
      console.error(`Existing setup is stale, running fresh.`);
    } catch {
      console.error(`Existing artifact is corrupt, running fresh.`);
    }
  }

  ensureOutDir();

  // Start AO (no trace, no dashboard)
  const aoProcess = startAO(project);
  await sleep(5000); // Give AO time to initialize

  try {
    // Run batch-spawn
    console.error(`Spawning ${sessionCount} sessions...`);
    const spawnOutput = await run("node", [AO_CLI, "batch-spawn", ...issues], {
      timeout: 120_000,
    });
    console.error(spawnOutput);

    // Wait for sessions to stabilize
    await sleep(5000);

    // Discover sessions: worktrees and branches
    console.error(`Discovering session worktrees and branches...`);
    const worktrees = await discoverWorktrees(projectConfig.path);
    console.error(`Found ${worktrees.size} worktrees`);

    // Match sessions to issues. Session IDs typically follow the pattern: {prefix}-{n}
    // We discover all sessions, then poll for PRs on their branches.
    const sessions = [];
    for (const [sessionId, worktreePath] of worktrees) {
      // Skip the main worktree
      if (worktreePath === projectConfig.path) continue;

      const branch = await getWorktreeBranch(worktreePath);
      if (!branch) {
        console.error(`  Warning: no branch for ${sessionId} at ${worktreePath}`);
        continue;
      }

      sessions.push({
        sessionId,
        issue: null, // Will be filled if we can match
        branch,
        worktreePath,
        prNumber: null,
        prUrl: null,
      });
    }

    console.error(`Discovered ${sessions.length} session worktrees`);

    // Poll for PR readiness
    console.error(`Waiting for PRs (timeout: 10 minutes)...`);
    const prDeadline = Date.now() + 10 * 60_000;
    let controlCalls = 0;
    while (Date.now() < prDeadline) {
      let allReady = true;
      for (const s of sessions) {
        if (s.prNumber) continue; // Already found
        try {
          const prJson = await ghControl([
            "pr", "list",
            "--head", s.branch,
            "--repo", projectConfig.repo,
            "--json", "number,url",
            "--limit", "1",
          ]);
          controlCalls++;
          const prs = JSON.parse(prJson);
          if (prs.length > 0) {
            s.prNumber = prs[0].number;
            s.prUrl = prs[0].url;
            console.error(`  PR found: ${s.sessionId} → #${s.prNumber}`);
          } else {
            allReady = false;
          }
        } catch {
          allReady = false;
        }
      }
      if (allReady) break;
      console.error(`  ${sessions.filter((s) => s.prNumber).length}/${sessions.length} PRs ready, waiting 30s...`);
      await sleep(30_000);
    }

    const readySessions = sessions.filter((s) => s.prNumber);
    const ready = readySessions.length === sessions.length;
    console.error(`\n${readySessions.length}/${sessions.length} sessions have PRs. Ready: ${ready}`);

    // Kill agent tmux sessions (agents have done their job)
    console.error(`Killing agent tmux sessions...`);
    for (const s of sessions) {
      try {
        await run("tmux", ["kill-session", "-t", s.sessionId], { timeout: 5000 }).catch(() => {});
      } catch {
        // Best effort — session may already be dead
      }
    }

    // Write setup artifact
    const artifact = {
      schemaVersion: SCHEMA_VERSION,
      benchmarkVersion: BENCHMARK_VERSION,
      scenarioId,
      createdAt: new Date().toISOString(),
      gitSha: gitSha(),
      branch: gitBranch(),
      project,
      repo: projectConfig.repo,
      scenario: "quiet-steady",
      topology: "single-repo",
      sessionCount,
      ready,
      sessions: sessions.map((s) => ({
        sessionId: s.sessionId,
        issue: s.issue,
        branch: s.branch,
        worktreePath: s.worktreePath,
        prNumber: s.prNumber,
        prUrl: s.prUrl,
      })),
    };

    writeFileSync(artifactPath, JSON.stringify(artifact, null, 2) + "\n");
    console.error(`\nSetup artifact written: ${artifactPath}`);
    console.error(`Benchmark control calls (not traced): ${controlCalls}`);

  } finally {
    await stopAO(aoProcess);
  }
}
```

- [ ] **Step 5: Commit**

```bash
git add experiments/benchmark.mjs
git commit -m "feat(experiments): implement setup mode for benchmark harness

Spawns sessions, waits for PR readiness, writes setup artifact."
```

---

### Task 7: Measure Mode

**Files:**
- Modify: `experiments/benchmark.mjs`

Implements the repeatable measurement flow: validate setup, start AO with trace, warmup, snapshot, measure, snapshot, stop, compute scorecard.

- [ ] **Step 1: Add rate-limit snapshot helper**

```javascript
/**
 * Capture a rate-limit snapshot via `gh api rate_limit`.
 * Called without AO_GH_TRACE_FILE to avoid polluting the trace.
 */
async function captureRateLimitSnapshot() {
  const raw = await ghControl(["api", "rate_limit"]);
  const data = JSON.parse(raw);
  return {
    capturedAt: new Date().toISOString(),
    core: data.resources?.core ?? null,
    graphql: data.resources?.graphql ?? null,
  };
}
```

- [ ] **Step 2: Implement runMeasure**

Replace the stub:

```javascript
async function runMeasure(flags) {
  const project = flags.project;
  const sessionCount = parseInt(flags.sessions, 10);
  const warmupStr = flags.warmup ?? "2m";
  const durationStr = flags.duration;

  if (!project) die("--project is required");
  if (!sessionCount || sessionCount < 1) die("--sessions must be a positive integer");
  if (!durationStr) die("--duration is required (e.g. 15m)");

  const warmupMs = parseDuration(warmupStr);
  const durationMs = parseDuration(durationStr);
  const scenarioId = buildScenarioId(sessionCount);
  const artifactPath = setupArtifactPath(project, scenarioId);
  const projectConfig = loadProjectConfig(project);

  // 1. Load and validate setup artifact
  if (!existsSync(artifactPath)) {
    die(`Setup artifact not found: ${artifactPath}\nRun setup first: node experiments/benchmark.mjs setup --project ${project} --sessions ${sessionCount} --issues ...`);
  }
  const setup = JSON.parse(readFileSync(artifactPath, "utf-8"));

  console.error(`\n=== Benchmark Measure ===`);
  console.error(`Project:   ${project}`);
  console.error(`Scenario:  ${scenarioId}`);
  console.error(`Warmup:    ${warmupStr}`);
  console.error(`Duration:  ${durationStr}`);
  console.error(`Sessions:  ${setup.sessions.length}`);
  console.error();

  // 2. Validate setup — worktrees exist, PRs still open
  let controlCalls = 0;
  console.error(`Validating setup...`);
  const invalid = [];
  for (const s of setup.sessions) {
    if (!existsSync(s.worktreePath)) {
      invalid.push(`${s.sessionId}: worktree missing at ${s.worktreePath}`);
      continue;
    }
    if (s.prNumber) {
      try {
        const prJson = await ghControl([
          "pr", "view", String(s.prNumber),
          "--repo", projectConfig.repo,
          "--json", "state",
        ]);
        controlCalls++;
        const pr = JSON.parse(prJson);
        if (pr.state !== "OPEN") {
          invalid.push(`${s.sessionId}: PR #${s.prNumber} is ${pr.state}, not OPEN`);
        }
      } catch (err) {
        invalid.push(`${s.sessionId}: cannot verify PR #${s.prNumber}: ${err.message}`);
        controlCalls++;
      }
    }
  }
  if (invalid.length > 0) {
    console.error(`\nSetup validation failed:`);
    for (const msg of invalid) console.error(`  - ${msg}`);
    die(`${invalid.length} sessions failed validation. Re-run setup or fix manually.`);
  }
  console.error(`All ${setup.sessions.length} sessions validated OK`);

  // 3. Set up trace file
  const ts = Math.floor(Date.now() / 1000);
  ensureOutDir();
  const traceFile = join(OUT_DIR, `gh-trace-bench-${ts}.jsonl`);

  // 4. Start AO with trace
  const aoProcess = startAO(project, { traceFile });

  try {
    // 5. Warmup phase
    console.error(`\nWarmup phase: ${warmupStr}...`);
    const warmupStart = Date.now();
    const warmupInterval = setInterval(() => {
      const elapsed = Math.round((Date.now() - warmupStart) / 1000);
      const total = Math.round(warmupMs / 1000);
      process.stderr.write(`\r  Warmup: ${elapsed}s / ${total}s`);
    }, 5000);
    await sleep(warmupMs);
    clearInterval(warmupInterval);
    process.stderr.write("\n");

    // 6. Record warmup end
    const warmupEnd = new Date().toISOString();
    console.error(`Warmup ended: ${warmupEnd}`);

    // 7. Before rate-limit snapshot
    console.error(`Capturing rate-limit before-snapshot...`);
    const snapshotBefore = await captureRateLimitSnapshot();
    controlCalls++;
    console.error(`  core: ${snapshotBefore.core?.remaining}/${snapshotBefore.core?.limit}`);
    console.error(`  graphql: ${snapshotBefore.graphql?.remaining}/${snapshotBefore.graphql?.limit}`);

    // 8. Measurement window
    const measureStart = new Date().toISOString();
    console.error(`\nMeasurement window: ${durationStr}...`);
    const measureStartMs = Date.now();
    const measureInterval = setInterval(() => {
      const remainMs = durationMs - (Date.now() - measureStartMs);
      const remainMin = Math.ceil(remainMs / 60_000);
      process.stderr.write(`\r  Measuring: ${remainMin}m remaining  `);
    }, 60_000);
    await sleep(durationMs);
    clearInterval(measureInterval);
    process.stderr.write("\n");

    const measureEnd = new Date().toISOString();

    // 9. After rate-limit snapshot
    console.error(`Capturing rate-limit after-snapshot...`);
    const snapshotAfter = await captureRateLimitSnapshot();
    controlCalls++;
    console.error(`  core: ${snapshotAfter.core?.remaining}/${snapshotAfter.core?.limit}`);
    console.error(`  graphql: ${snapshotAfter.graphql?.remaining}/${snapshotAfter.graphql?.limit}`);

    // 10. Stop AO
    await stopAO(aoProcess);

    // 11. Compute scorecard
    console.error(`\nComputing scorecard from trace...`);
    const allRows = readTrace(traceFile);
    console.error(`Trace entries: ${allRows.length}`);

    const snapshots = { before: snapshotBefore, after: snapshotAfter };
    const scorecard = computeScorecard(allRows, measureStart, measureEnd, snapshots, controlCalls);

    // 12. Build envelope
    const windowDurationMs = new Date(measureEnd).getTime() - new Date(measureStart).getTime();
    const durationMin = windowDurationMs / 60_000;

    const envelope = {
      schemaVersion: SCHEMA_VERSION,
      benchmarkVersion: BENCHMARK_VERSION,
      scenarioId,
      gitSha: gitSha(),
      branch: gitBranch(),
      measuredAt: measureEnd,
      sessionCount: setup.sessions.length,
      warmup: { requested: warmupStr, actualEnd: warmupEnd },
      window: {
        start: measureStart,
        end: measureEnd,
        durationRequested: durationStr,
        durationActual: `${Math.floor(durationMin)}m ${Math.round((durationMin % 1) * 60)}s`,
      },
      resourceWindows: scorecard.resourceWindows,
      rateLimitSnapshots: snapshots,
      scorecard,
      trace: traceFile,
      supplemental: null,
    };

    // 13. Write scorecard
    const scorecardPath = join(OUT_DIR, `scorecard-${scenarioId}-${ts}.json`);
    writeFileSync(scorecardPath, JSON.stringify(envelope, null, 2) + "\n");
    envelope.scorecardPath = scorecardPath;

    // 14. Print scorecard
    printScorecard(envelope);
    console.error(`Trace written to: ${traceFile}`);
    console.error(`Scorecard written to: ${scorecardPath}`);

  } catch (err) {
    // Ensure AO is stopped even on error
    await stopAO(aoProcess).catch(() => {});
    throw err;
  }
}
```

- [ ] **Step 3: Commit**

```bash
git add experiments/benchmark.mjs
git commit -m "feat(experiments): implement measure mode for benchmark harness

Validates setup, runs AO with trace, captures rate-limit snapshots,
computes and prints scorecard."
```

---

### Task 8: Integration Verification

**Files:**
- No modifications — verification only

Verify the complete harness works end-to-end with the existing trace data.

- [ ] **Step 1: Verify report mode with the existing verification trace**

Run:
```bash
node experiments/benchmark.mjs report --trace experiments/out/gh-trace-verify-1776345900.jsonl
```

Expected output should show:
- ~234 total calls
- ~10.5 calls/min
- 27 guard-pr-list 304s
- bracket delta fields null (report mode)
- Duration matching the trace span (~22 min)
- Progress bars for GraphQL and REST core

- [ ] **Step 2: Verify report mode with warmup-end filter**

Run (using a timestamp ~5 minutes into the trace as warmup cutoff):
```bash
node experiments/benchmark.mjs report \
  --trace experiments/out/gh-trace-verify-1776345900.jsonl \
  --warmup-end 2026-04-16T13:33:00Z
```

Expected: fewer total calls (rows before the warmup-end timestamp are excluded from the scorecard). The burn rates should still be reasonable.

- [ ] **Step 3: Verify CLI error handling**

Run these and verify each gives a clear error message:
```bash
node experiments/benchmark.mjs                                    # → usage
node experiments/benchmark.mjs measure                            # → missing --project
node experiments/benchmark.mjs measure --project x                # → missing --sessions
node experiments/benchmark.mjs measure --project x --sessions 5   # → missing --duration
node experiments/benchmark.mjs report                             # → missing --trace
node experiments/benchmark.mjs report --trace nonexistent.jsonl   # → file not found
```

- [ ] **Step 4: Verify setup mode arg validation**

```bash
node experiments/benchmark.mjs setup                               # → missing --project
node experiments/benchmark.mjs setup --project x                   # → missing --sessions
node experiments/benchmark.mjs setup --project x --sessions 5      # → missing --issues
node experiments/benchmark.mjs setup --project x --sessions 5 --issues 1,2,3  # → count mismatch
```

- [ ] **Step 5: Final commit**

```bash
git add experiments/benchmark.mjs
git commit -m "feat(experiments): complete benchmark harness v1

Three modes: setup (spawn sessions), measure (capture trace + scorecard),
report (recompute scorecard from existing trace).

Spec: docs/superpowers/specs/2026-04-16-benchmark-harness-design.md"
```

---

## Verification Checklist

After all tasks are complete, verify:

1. `node experiments/benchmark.mjs` prints usage
2. `node experiments/benchmark.mjs report --trace experiments/out/gh-trace-verify-1776345900.jsonl` produces a valid scorecard matching known baseline numbers
3. All three modes have proper arg validation with clear error messages
4. The scorecard JSON is valid and matches the schema from the spec
5. Budget progress bars render correctly in terminal (green/yellow/red colors)
6. The harness does not import any external packages — stdlib only
