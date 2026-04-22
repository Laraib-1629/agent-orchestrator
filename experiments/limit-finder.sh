#!/usr/bin/env bash
# limit-finder.sh — Find the practical real-flow session ceiling for AO on a live repo.
#
# Runs a tiered sweep of concurrent AO sessions against a real GitHub repo using real
# Claude Code agents. Each tier covers the full lifecycle (working → pr_open → ci_* →
# mergeable/merged). Captures rate-limit deltas, agent-side gh trace (with cache
# hit/miss), top subcommands, and session outcomes. Produces a scorecard that names
# the highest "supported" tier — supported = ≥70% sessions reach terminal state AND
# the GraphQL bucket does not exhaust AND poll cycle stays under the ceiling.
#
# Usage:
#   ./experiments/limit-finder.sh \
#     --project-dir /abs/path/to/todo-app \
#     --tiers "5 10 15 20" \
#     --tier-duration 1800 \
#     --agent claude-code
#
# Prerequisites:
#   - AO built from feat/gh-rate-limiting (pnpm build in AO repo)
#   - `ao` CLI in PATH (or set AO_BIN)
#   - `gh` authenticated against the test repo's owner
#   - `claude` CLI in PATH
#   - agent-orchestrator.yaml in --project-dir pointing at the test repo
#   - No other `ao start` running
#
# Between tiers the script: stops AO, closes/archives any live sessions it spawned,
# seeds a fresh batch of issues, then starts the next tier.

set -euo pipefail

# ─── Config ────────────────────────────────────────────────────────────────────
PROJECT_DIR=""
TIERS="5 10 15 20"
TIER_DURATION=1800          # seconds per tier (30 min)
AGENT="claude-code"
TERMINAL_THRESHOLD=70       # % sessions in terminal state for "supported"
POLL_CEILING_MS=60000       # poll cycle ceiling for "supported"
BUDGET_GUARDRAIL=90         # abort a tier if GraphQL used% >= this
SPAWN_STAGGER=3             # seconds between ao spawn calls
REQUIRE_AO_TRACE=1          # require AO-side trace rows >0 (set 0 on main where gh-trace.ts is absent)
REQUIRE_AGENT_TRACE=1       # require ~/.ao/bin/gh wrapper rows >0 (set 0 for claude-code: uses native hooks, bypasses wrapper)
AO_REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# Default to the local branch build, not the global `ao` shim (which points at
# a different worktree and may be missing build artifacts).
LOCAL_CLI="$AO_REPO_DIR/packages/cli/dist/index.js"
if [ -z "${AO_BIN:-}" ] && [ -f "$LOCAL_CLI" ]; then
  AO_BIN="node $LOCAL_CLI"
else
  AO_BIN="${AO_BIN:-ao}"
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-dir)    PROJECT_DIR="$2"; shift 2 ;;
    --tiers)          TIERS="$2"; shift 2 ;;
    --tier-duration)  TIER_DURATION="$2"; shift 2 ;;
    --agent)          AGENT="$2"; shift 2 ;;
    --terminal-threshold) TERMINAL_THRESHOLD="$2"; shift 2 ;;
    --budget-guardrail)   BUDGET_GUARDRAIL="$2"; shift 2 ;;
    --require-ao-trace)   REQUIRE_AO_TRACE="$2"; shift 2 ;;
    --no-require-ao-trace) REQUIRE_AO_TRACE=0; shift 1 ;;
    --require-agent-trace) REQUIRE_AGENT_TRACE="$2"; shift 2 ;;
    --no-require-agent-trace) REQUIRE_AGENT_TRACE=0; shift 1 ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$PROJECT_DIR" ]; then
  cat >&2 <<USAGE
Usage: $0 --project-dir /abs/path/to/repo [--tiers "5 10 20"] [--tier-duration 1800]
          [--agent claude-code|codex] [--terminal-threshold 70] [--budget-guardrail 90]
USAGE
  exit 1
fi

if [ ! -f "$PROJECT_DIR/agent-orchestrator.yaml" ]; then
  echo "ERROR: $PROJECT_DIR/agent-orchestrator.yaml not found" >&2
  exit 1
fi

REPO=$(grep -E '^\s*repo:' "$PROJECT_DIR/agent-orchestrator.yaml" | head -1 | awk '{print $2}' | tr -d '"')
if [ -z "$REPO" ]; then
  echo "ERROR: could not parse 'repo:' from agent-orchestrator.yaml" >&2
  exit 1
fi

RUN_TS=$(date +%s)
OUT_DIR="$AO_REPO_DIR/experiments/out/limit-finder-$RUN_TS"
SCORECARD="$OUT_DIR/scorecard.md"
mkdir -p "$OUT_DIR"

echo "═══════════════════════════════════════════════════════════"
echo "  AO Real-Flow Limit Finder"
echo "  Repo:      $REPO"
echo "  Agent:     $AGENT"
echo "  Tiers:     $TIERS"
echo "  Duration:  ${TIER_DURATION}s per tier"
echo "  Out:       $OUT_DIR"
echo "═══════════════════════════════════════════════════════════"

# ─── Helpers ───────────────────────────────────────────────────────────────────
rate_snapshot() {
  local raw
  raw=$(gh api rate_limit 2>/dev/null)
  echo "graphql remaining=$(echo "$raw" | jq -r '.resources.graphql.remaining') used=$(echo "$raw" | jq -r '.resources.graphql.used') limit=$(echo "$raw" | jq -r '.resources.graphql.limit')"
  echo "core    remaining=$(echo "$raw" | jq -r '.resources.core.remaining') used=$(echo "$raw" | jq -r '.resources.core.used') limit=$(echo "$raw" | jq -r '.resources.core.limit')"
}

rate_used_pct() {
  gh api rate_limit 2>/dev/null \
    | jq 'if .resources.graphql.limit == 0 then 0 else ((.resources.graphql.used * 100) / .resources.graphql.limit | floor) end'
}

stop_ao() {
  if [ -n "${AO_PID:-}" ] && kill -0 "$AO_PID" 2>/dev/null; then
    echo "  Stopping AO (PID $AO_PID)..."
    kill "$AO_PID" 2>/dev/null || true
    wait "$AO_PID" 2>/dev/null || true
  fi
  # Stragglers: any other `ao start` (global shim or local node CLI) left running
  pkill -f "ao start" 2>/dev/null || true
  pkill -f "packages/cli/dist/index.js start" 2>/dev/null || true
  sleep 2
}

archive_tier_sessions() {
  # Archive the sessions we spawned this tier so the next tier starts clean.
  local sids=("$@")
  for sid in "${sids[@]}"; do
    ( cd "$PROJECT_DIR" && $AO_BIN archive "$sid" 2>/dev/null ) || true
  done
}

trap 'stop_ao' EXIT INT TERM

# ─── Scorecard header ──────────────────────────────────────────────────────────
{
  echo "# AO Real-Flow Limit Finder — Scorecard"
  echo
  echo "- **Run:** $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "- **Repo:** \`$REPO\`"
  echo "- **Agent:** $AGENT"
  echo "- **Tiers:** $TIERS"
  echo "- **Tier duration:** ${TIER_DURATION}s"
  echo "- **Supported criteria:** ≥${TERMINAL_THRESHOLD}% terminal-state sessions AND GraphQL <${BUDGET_GUARDRAIL}% used AND poll cycle <${POLL_CEILING_MS}ms"
  echo
  echo "| Tier | Sessions | Duration | GraphQL used | pts/hr | Core used | AO rows | Agent rows | Cache hit% | Terminal% | Supported? |"
  echo "|-----:|---------:|---------:|-------------:|-------:|----------:|--------:|-----------:|-----------:|----------:|:-----------|"
} > "$SCORECARD"

HIGHEST_SUPPORTED=0

# ─── Per-tier loop ─────────────────────────────────────────────────────────────
for N in $TIERS; do
  TIER_TS=$(date +%s)
  TIER_DIR="$OUT_DIR/tier-$N"
  mkdir -p "$TIER_DIR"
  TRACE_AO="$TIER_DIR/gh-trace-ao.jsonl"
  TRACE_AGENT="$HOME/.ao/traces/agent-gh-limitfinder-$TIER_TS.jsonl"
  AO_LOG="$TIER_DIR/ao.log"

  echo
  echo "───────────────────────────────────────────────────────────"
  echo "  Tier: $N sessions"
  echo "  Trace (AO):    $TRACE_AO"
  echo "  Trace (agent): $TRACE_AGENT"
  echo "───────────────────────────────────────────────────────────"

  # 0. Pre-flight: refuse to start a tier if the bucket is already half-empty.
  PRE_USED_PCT=$(rate_used_pct)
  if [ "$PRE_USED_PCT" -ge 50 ]; then
    RESET_TS=$(gh api rate_limit 2>/dev/null | jq -r '.resources.graphql.reset')
    WAIT_SEC=$(( RESET_TS - $(date +%s) ))
    [ "$WAIT_SEC" -lt 0 ] && WAIT_SEC=0
    echo "  ⚠️  GraphQL used=${PRE_USED_PCT}% — refusing to start tier."
    echo "     Bucket resets in ${WAIT_SEC}s. Re-run after that."
    exit 2
  fi

  # 1. Seed fresh issues
  echo "  [1/6] Seeding $N issues..."
  bash "$AO_REPO_DIR/experiments/seed-issues.sh" --repo "$REPO" --count "$N" >> "$TIER_DIR/seed.log" 2>&1

  # 2. Snapshot rate limit BEFORE
  echo "  [2/6] Rate-limit snapshot (before)..."
  RATE_BEFORE_FILE="$TIER_DIR/ratelimit-before.json"
  gh api rate_limit > "$RATE_BEFORE_FILE" 2>/dev/null
  rate_snapshot | sed 's/^/    /'

  USED_START=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["resources"]["graphql"]; print(d["used"])' "$RATE_BEFORE_FILE")
  LIMIT=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["resources"]["graphql"]; print(d["limit"])' "$RATE_BEFORE_FILE")
  CORE_START=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["resources"]["core"]; print(d["used"])' "$RATE_BEFORE_FILE")

  # 3. Start AO with BOTH trace envs
  # Export so subsequent `ao spawn` CLI processes inherit them. ao spawn runs
  # session-manager.spawn() locally and reads process.env["AO_AGENT_GH_TRACE"]
  # to forward into the tmux env (session-manager.ts:1266). Without export, the
  # spawn process sees no env var, so the wrapper at ~/.ao/bin/gh has nowhere
  # to write and every agent trace file ends up 0 bytes.
  export AO_GH_TRACE_FILE="$TRACE_AO"
  export AO_AGENT_GH_TRACE="$TRACE_AGENT"
  echo "  [3/6] Starting AO (traces enabled)..."
  mkdir -p "$(dirname "$TRACE_AGENT")"
  : > "$TRACE_AGENT"
  (
    cd "$PROJECT_DIR"
    AO_CONFIG_PATH="$PROJECT_DIR/agent-orchestrator.yaml" \
    $AO_BIN start > "$AO_LOG" 2>&1
  ) &
  AO_PID=$!

  # Wait for AO to start polling (look for the first batch line)
  echo "    Waiting for AO to warm up..."
  for i in $(seq 1 20); do
    if grep -q "GraphQL Batch" "$AO_LOG" 2>/dev/null; then
      break
    fi
    sleep 1
  done

  # 4. Spawn N sessions
  echo "  [4/6] Spawning $N sessions (stagger ${SPAWN_STAGGER}s)..."
  ISSUES=$(gh issue list --repo "$REPO" --state open --label benchmark --json number --jq '.[].number' 2>/dev/null | head -"$N")
  AVAIL=$(printf '%s\n' "$ISSUES" | grep -c . || true)
  if [ "$AVAIL" -lt "$N" ]; then
    ISSUES=$(gh issue list --repo "$REPO" --state open --json number --jq '.[].number' 2>/dev/null | head -"$N")
  fi
  SPAWNED=()
  for ISSUE in $ISSUES; do
    SESSION_LINE=$(cd "$PROJECT_DIR" && $AO_BIN spawn "$ISSUE" --agent "$AGENT" 2>&1 | tee -a "$TIER_DIR/spawn.log" | grep "^SESSION=" || true)
    SID="${SESSION_LINE#SESSION=}"
    if [ -n "$SID" ]; then
      SPAWNED+=("$SID")
      echo "    ✓ issue #$ISSUE → $SID"
    else
      echo "    ✗ spawn failed for issue #$ISSUE"
    fi
    sleep "$SPAWN_STAGGER"
  done
  echo "    Spawned ${#SPAWNED[@]}/$N sessions."

  # 5. Monitor until all terminal or timeout — also trip the budget guardrail.
  echo "  [5/6] Monitoring for ${TIER_DURATION}s..."
  START=$(date +%s)
  END=$((START + TIER_DURATION))
  TIER_ABORTED=0
  TERMINAL_REGEX='(merged|done|mergeable)'

  while true; do
    NOW=$(date +%s)
    if [ "$NOW" -ge "$END" ]; then
      echo "    ⏰ Tier duration elapsed."
      break
    fi

    # Guardrail: stop early if we're about to torch the bucket
    USED_PCT=$(rate_used_pct || echo 0)
    if [ "$USED_PCT" -ge "$BUDGET_GUARDRAIL" ]; then
      echo "    🚨 GraphQL used=${USED_PCT}% ≥ ${BUDGET_GUARDRAIL}% — aborting tier."
      TIER_ABORTED=1
      break
    fi

    # Count terminal sessions
    TERMINAL=0
    for SID in "${SPAWNED[@]}"; do
      STATUS=$(cd "$PROJECT_DIR" && $AO_BIN status 2>/dev/null | awk -v s="$SID" '$0 ~ s {print $NF; exit}')
      if [[ "$STATUS" =~ $TERMINAL_REGEX ]]; then
        TERMINAL=$((TERMINAL + 1))
      fi
    done

    ELAPSED=$(( (NOW - START) / 60 ))
    echo "    [${ELAPSED}m] terminal=$TERMINAL/${#SPAWNED[@]}  graphql_used=${USED_PCT}%"

    if [ "$TERMINAL" -ge "${#SPAWNED[@]}" ] && [ "${#SPAWNED[@]}" -gt 0 ]; then
      echo "    ✓ All sessions terminal."
      break
    fi

    sleep 30
  done

  # 6. Collect outcomes BEFORE stopping AO (stop_ao overwrites status to "killed").
  echo "  [6/6] Collecting tier results..."
  TERMINAL_FINAL=0
  OUTCOMES_FILE="$TIER_DIR/outcomes.txt"
  : > "$OUTCOMES_FILE"
  for SID in "${SPAWNED[@]}"; do
    STATUS_FILE=$(ls -1 "$HOME"/.agent-orchestrator/*/sessions/"$SID" 2>/dev/null | head -1 || true)
    if [ -n "$STATUS_FILE" ] && [ -f "$STATUS_FILE" ]; then
      STATUS=$(grep '^status=' "$STATUS_FILE" | head -1 | cut -d= -f2)
    else
      STATUS="unknown"
    fi
    echo "$SID $STATUS" >> "$OUTCOMES_FILE"
    if [[ "$STATUS" =~ ^${TERMINAL_REGEX}$ ]]; then
      TERMINAL_FINAL=$((TERMINAL_FINAL + 1))
    fi
  done
  TOTAL=${#SPAWNED[@]}
  TERMINAL_PCT=0
  [ "$TOTAL" -gt 0 ] && TERMINAL_PCT=$(( 100 * TERMINAL_FINAL / TOTAL ))

  stop_ao

  RATE_AFTER_FILE="$TIER_DIR/ratelimit-after.json"
  gh api rate_limit > "$RATE_AFTER_FILE" 2>/dev/null
  USED_END=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["resources"]["graphql"]; print(d["used"])' "$RATE_AFTER_FILE")
  CORE_END=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))["resources"]["core"]; print(d["used"])' "$RATE_AFTER_FILE")

  GRAPHQL_DELTA=$((USED_END - USED_START))
  CORE_DELTA=$((CORE_END - CORE_START))
  DUR_SEC=$(( $(date +%s) - START ))
  [ "$DUR_SEC" -lt 1 ] && DUR_SEC=1
  PTS_PER_HR=$(( GRAPHQL_DELTA * 3600 / DUR_SEC ))

  AO_ROWS=0
  AGENT_ROWS=0
  [ -f "$TRACE_AO" ] && AO_ROWS=$(wc -l < "$TRACE_AO" | tr -d ' ')
  [ -f "$TRACE_AGENT" ] && AGENT_ROWS=$(wc -l < "$TRACE_AGENT" | tr -d ' ')

  # Hard-fail trace integrity check. The B1/B2 A/B comparison is only meaningful
  # if both probes wrote rows. Without this, an empty trace silently masquerades
  # as "zero gh calls" and any conclusion is junk. We do NOT exit — we mark the
  # tier UNTRUSTWORTHY in the scorecard so a glance reveals the failure.
  TRACE_OK=1
  TRACE_FAIL_REASON=""
  if [ "$REQUIRE_AGENT_TRACE" -eq 1 ] && [ "$AGENT_ROWS" -eq 0 ]; then
    TRACE_OK=0
    TRACE_FAIL_REASON="agent_rows=0"
  fi
  if [ "$REQUIRE_AO_TRACE" -eq 1 ] && [ "$AO_ROWS" -eq 0 ]; then
    TRACE_OK=0
    if [ -n "$TRACE_FAIL_REASON" ]; then
      TRACE_FAIL_REASON="$TRACE_FAIL_REASON, ao_rows=0"
    else
      TRACE_FAIL_REASON="ao_rows=0"
    fi
  fi
  if [ "$TRACE_OK" -eq 0 ]; then
    echo "    🚨 TRACE INTEGRITY FAILURE ($TRACE_FAIL_REASON) — tier results UNTRUSTWORTHY" >&2
    echo "       AO_GH_TRACE_FILE=$TRACE_AO" >&2
    echo "       AO_AGENT_GH_TRACE=$TRACE_AGENT" >&2
    echo "       Verify: env vars exported before \`ao start\`; ~/.ao/bin/gh exists; jq installed" >&2
  fi

  # Cache hit% (requires v0.4.1+ wrapper that logs cacheResult)
  CACHE_HIT_PCT="—"
  if [ "$AGENT_ROWS" -gt 0 ] && [ -f "$TRACE_AGENT" ]; then
    CACHE_HIT_PCT=$(python3 <<PY
import json
hits = misses = 0
for line in open("$TRACE_AGENT"):
    try: r = json.loads(line)
    except: continue
    cr = r.get("cacheResult")
    if cr == "hit": hits += 1
    elif cr == "miss": misses += 1
total = hits + misses
print("—" if total == 0 else f"{int(100*hits/total)}")
PY
    )
  fi

  # Top-10 agent subcommands
  TOP10_FILE="$TIER_DIR/top10-agent-subcommands.txt"
  if [ -f "$TRACE_AGENT" ] && [ "$AGENT_ROWS" -gt 0 ]; then
    python3 - "$TRACE_AGENT" > "$TOP10_FILE" <<'PY'
import json, sys, collections
c = collections.Counter()
for line in open(sys.argv[1]):
    try: r = json.loads(line)
    except: continue
    args = r.get("args") or []
    key = " ".join(args[:3]) if args else "(no args)"
    c[key] += 1
for k,v in c.most_common(10):
    print(f"{v:5d}  {k}")
PY
  fi

  # Supported? Trace failure disqualifies the tier — junk data can't prove anything.
  SUPPORTED="NO"
  USED_END_PCT=$(( 100 * USED_END / LIMIT ))
  if [ "$TRACE_OK" -eq 0 ]; then
    SUPPORTED="UNTRUSTWORTHY"
  elif [ "$TIER_ABORTED" -eq 0 ] \
     && [ "$TERMINAL_PCT" -ge "$TERMINAL_THRESHOLD" ] \
     && [ "$USED_END_PCT" -lt "$BUDGET_GUARDRAIL" ]; then
    SUPPORTED="YES"
    HIGHEST_SUPPORTED=$N
  fi

  # Archive this tier's sessions before next tier
  archive_tier_sessions "${SPAWNED[@]}"

  # Append row
  printf '| %d | %d | %ds | %d | %d | %d | %d | %d | %s | %d%% | %s |\n' \
    "$N" "$TOTAL" "$DUR_SEC" "$GRAPHQL_DELTA" "$PTS_PER_HR" "$CORE_DELTA" \
    "$AO_ROWS" "$AGENT_ROWS" "$CACHE_HIT_PCT" "$TERMINAL_PCT" "$SUPPORTED" >> "$SCORECARD"

  # Write per-tier summary
  cat > "$TIER_DIR/summary.md" <<MD
# Tier $N — summary

- Sessions spawned: $TOTAL
- Duration: ${DUR_SEC}s ($(printf '%.1f' "$(python3 -c "print($DUR_SEC/60)")") min)
- GraphQL used: $GRAPHQL_DELTA points (${PTS_PER_HR} pts/hr)
- Core used: $CORE_DELTA requests
- AO-side trace rows: $AO_ROWS
- Agent-side trace rows: $AGENT_ROWS
- Cache hit%: $CACHE_HIT_PCT
- Sessions in terminal state: $TERMINAL_FINAL/$TOTAL (${TERMINAL_PCT}%)
- Tier aborted by guardrail: $TIER_ABORTED
- **Supported: $SUPPORTED**

## Top-10 agent gh subcommands

\`\`\`
$([ -f "$TOP10_FILE" ] && cat "$TOP10_FILE" || echo "(no trace)")
\`\`\`

## Session outcomes

\`\`\`
$(cat "$OUTCOMES_FILE")
\`\`\`
MD

  echo "  Tier $N: $SUPPORTED  (terminal=${TERMINAL_PCT}%, pts/hr=$PTS_PER_HR, cache hit%=$CACHE_HIT_PCT)"

  # Stop sweeping if a tier was aborted by the guardrail — higher tiers will also fail.
  if [ "$TIER_ABORTED" -eq 1 ]; then
    echo "  Aborting sweep: guardrail fired at tier $N."
    break
  fi
done

# ─── Final verdict ─────────────────────────────────────────────────────────────
{
  echo
  echo "## Verdict"
  echo
  if [ "$HIGHEST_SUPPORTED" -gt 0 ]; then
    echo "**Highest supported tier: $HIGHEST_SUPPORTED sessions.**"
  else
    echo "**No tier met the supported bar.** Lower \`--terminal-threshold\` or investigate per-tier summaries."
  fi
  echo
  echo "Per-tier artefacts: \`$OUT_DIR/tier-*/\`"
} >> "$SCORECARD"

echo
echo "═══════════════════════════════════════════════════════════"
cat "$SCORECARD"
echo "═══════════════════════════════════════════════════════════"
echo "Scorecard: $SCORECARD"
