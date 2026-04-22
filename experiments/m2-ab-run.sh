#!/usr/bin/env bash
# m2-ab-run.sh — M2 n=2 A/B comparison: feat/gh-rate-limiting vs probe/main-gh-trace.
#
# Runs 4 tier-5 × 600s sessions alternating feat → main-probe → feat → main-probe,
# each with a fresh issue batch. Gated by a smoke check on both branches
# (tier=1, 420s) requiring AO_ROWS>0 (AO-side instrumentation healthy).
# AGENT_ROWS is not gated for claude-code (native hooks bypass the PATH wrapper).
# Aggregates into a comparison report with full per-run metadata.
#
# Usage:
#   ./experiments/m2-ab-run.sh \
#     --project-dir /Users/dhruvsharma/Development/todo-app \
#     --feat-dir    /Users/dhruvsharma/Development/agent-orchestrator-gh-rate-limiting \
#     --main-dir    /Users/dhruvsharma/Development/ao-main-baseline
#
# Prereqs:
#   - Both AO builds up to date (pnpm build on each)
#   - gh auth covers the test repo
#   - No other `ao start` running
#   - GraphQL bucket <50% used (wrapper aborts otherwise)

set -euo pipefail

# ─── Config ────────────────────────────────────────────────────────────────────
PROJECT_DIR=""
FEAT_DIR=""
MAIN_DIR=""
TIER=5
DURATION=600              # seconds per real run
SMOKE_TIER=1
SMOKE_DURATION=420        # seconds per smoke (Claude cold-start tolerance)
RUNS=4                    # total alternating runs
AGENT="claude-code"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project-dir)  PROJECT_DIR="$2"; shift 2 ;;
    --feat-dir)     FEAT_DIR="$2"; shift 2 ;;
    --main-dir)     MAIN_DIR="$2"; shift 2 ;;
    --tier)         TIER="$2"; shift 2 ;;
    --duration)     DURATION="$2"; shift 2 ;;
    --runs)         RUNS="$2"; shift 2 ;;
    --agent)        AGENT="$2"; shift 2 ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

: "${PROJECT_DIR:?--project-dir required}"
: "${FEAT_DIR:?--feat-dir required}"
: "${MAIN_DIR:?--main-dir required}"

CONFIG_FILE="$PROJECT_DIR/agent-orchestrator.yaml"
FEAT_CLI="$FEAT_DIR/packages/cli/dist/index.js"
MAIN_CLI="$MAIN_DIR/packages/cli/dist/index.js"
LF_SCRIPT="$FEAT_DIR/experiments/limit-finder.sh"

for f in "$FEAT_CLI" "$MAIN_CLI" "$LF_SCRIPT" "$CONFIG_FILE"; do
  [ -f "$f" ] || { echo "ERROR: missing $f" >&2; exit 1; }
done

FEAT_SHA=$(cd "$FEAT_DIR" && git rev-parse HEAD)
MAIN_SHA=$(cd "$MAIN_DIR" && git rev-parse HEAD)

BATCH_TS=$(date +%s)
BATCH_DIR="$FEAT_DIR/experiments/out/m2-ab-$BATCH_TS"
COMPARE_MD="$BATCH_DIR/m2-comparison.md"
mkdir -p "$BATCH_DIR"

echo "════════════════════════════════════════════════════════════"
echo "  M2 A/B Batch"
echo "  Repo:       $REPO"
echo "  Project:    $PROJECT_DIR"
echo "  Feat SHA:   $FEAT_SHA"
echo "  Main SHA:   $MAIN_SHA"
echo "  Tier:       $TIER × ${DURATION}s × $RUNS runs (alternating)"
echo "  Smoke:      tier=$SMOKE_TIER × ${SMOKE_DURATION}s on each branch"
echo "  Out:        $BATCH_DIR"
echo "════════════════════════════════════════════════════════════"

# ─── Helpers ───────────────────────────────────────────────────────────────────
rate_used_pct() {
  gh api rate_limit 2>/dev/null \
    | jq 'if .resources.graphql.limit == 0 then 0 else ((.resources.graphql.used * 100) / .resources.graphql.limit | floor) end'
}

config_sha256() {
  shasum -a 256 "$1" | awk '{print $1}'
}

validate_project_config() {
  local file="$1"
  [ -f "$file" ] || { echo "missing file" >&2; return 1; }

  local size
  size=$(wc -c < "$file" | tr -d ' ')
  [ "${size:-0}" -ge 100 ] || { echo "too small (${size} bytes)" >&2; return 1; }

  grep -qE '^[[:space:]]*defaults:[[:space:]]*$' "$file" || { echo "missing defaults:" >&2; return 1; }
  grep -qE '^[[:space:]]*projects:[[:space:]]*$' "$file" || { echo "missing projects:" >&2; return 1; }
  grep -qE '^[[:space:]]*repo:[[:space:]]*' "$file" || { echo "missing repo:" >&2; return 1; }
}

snapshot_project_config() {
  local label="$1"
  local snap="$BATCH_DIR/${label}.agent-orchestrator.yaml"
  local meta="$BATCH_DIR/${label}.agent-orchestrator.meta"

  if [ -f "$CONFIG_FILE" ]; then
    cp "$CONFIG_FILE" "$snap"
    {
      echo "path: $CONFIG_FILE"
      echo "size_bytes: $(wc -c < "$CONFIG_FILE" | tr -d ' ')"
      echo "mtime_epoch: $(stat -f %m "$CONFIG_FILE" 2>/dev/null || echo 0)"
      echo "sha256: $(config_sha256 "$CONFIG_FILE")"
    } > "$meta"
  else
    {
      echo "path: $CONFIG_FILE"
      echo "missing: true"
    } > "$meta"
  fi
}

guard_project_config() {
  local phase="$1"
  snapshot_project_config "$phase-before"
  if ! validate_project_config "$CONFIG_FILE" 2>"$BATCH_DIR/${phase}.config-error"; then
    echo "ERROR: invalid agent-orchestrator.yaml before $phase" >&2
    cat "$BATCH_DIR/${phase}.config-error" >&2
    echo "Snapshot: $BATCH_DIR/${phase}-before.agent-orchestrator.yaml" >&2
    return 1
  fi
}

guard_project_config_after() {
  local phase="$1"
  snapshot_project_config "$phase-after"
  if ! validate_project_config "$CONFIG_FILE" 2>"$BATCH_DIR/${phase}.config-error"; then
    echo "ERROR: invalid agent-orchestrator.yaml after $phase" >&2
    cat "$BATCH_DIR/${phase}.config-error" >&2
    echo "Before: $BATCH_DIR/${phase}-before.agent-orchestrator.yaml" >&2
    echo "After:  $BATCH_DIR/${phase}-after.agent-orchestrator.yaml" >&2
    return 1
  fi

  local before_sha after_sha
  before_sha=$(awk '/^sha256:/ {print $2}' "$BATCH_DIR/${phase}-before.agent-orchestrator.meta" 2>/dev/null || true)
  after_sha=$(awk '/^sha256:/ {print $2}' "$BATCH_DIR/${phase}-after.agent-orchestrator.meta" 2>/dev/null || true)
  if [ -n "$before_sha" ] && [ -n "$after_sha" ] && [ "$before_sha" != "$after_sha" ]; then
    echo "ERROR: agent-orchestrator.yaml changed during $phase" >&2
    echo "Before: $before_sha" >&2
    echo "After:  $after_sha" >&2
    echo "Before snapshot: $BATCH_DIR/${phase}-before.agent-orchestrator.yaml" >&2
    echo "After snapshot:  $BATCH_DIR/${phase}-after.agent-orchestrator.yaml" >&2
    return 1
  fi
}

stop_ao() {
  pkill -f "ao start" 2>/dev/null || true
  pkill -f "packages/cli/dist/index.js start" 2>/dev/null || true
  sleep 2
}

close_benchmark_issues() {
  # Close every open issue on the test repo with the 'benchmark' label so each
  # run starts with an empty benchmark backlog.
  local opens
  opens=$(gh issue list --repo "$REPO" --state open --label benchmark --json number --jq '.[].number' 2>/dev/null || true)
  for n in $opens; do
    gh issue close "$n" --repo "$REPO" --reason "not planned" >/dev/null 2>&1 || true
  done
  local count
  count=$(printf '%s\n' "$opens" | grep -c . || true)
  echo "  Closed $count open benchmark issues."
}

archive_stale_sessions() {
  # Archive any session metadata dirs we find — best-effort, don't fail the run.
  local cli="$1"
  ( cd "$PROJECT_DIR" && node "$cli" status 2>/dev/null ) | awk 'NR>1 {print $1}' | while read -r sid; do
    [ -z "$sid" ] && continue
    ( cd "$PROJECT_DIR" && node "$cli" archive "$sid" 2>/dev/null ) || true
  done
}

wait_for_graphql_reset() {
  # If we're ≥50% used, wait for the reset window (capped at 25 min).
  local used; used=$(rate_used_pct)
  if [ "$used" -lt 50 ]; then
    echo "  GraphQL used=${used}% — proceeding."
    return 0
  fi
  local reset_ts wait_s
  reset_ts=$(gh api rate_limit 2>/dev/null | jq -r '.resources.graphql.reset')
  wait_s=$(( reset_ts - $(date +%s) + 30 ))
  [ "$wait_s" -lt 0 ] && wait_s=0
  [ "$wait_s" -gt 1500 ] && wait_s=1500
  echo "  GraphQL used=${used}% ≥ 50% — waiting ${wait_s}s for reset..."
  sleep "$wait_s"
}

REPO=$(grep -E '^\s*repo:' "$CONFIG_FILE" | head -1 | awk '{print $2}' | tr -d '"')
[ -n "$REPO" ] || { echo "ERROR: could not parse repo from yaml" >&2; exit 1; }

# run_one <label> <cli> <tier> <duration> <require_ao_trace:0|1> <issue_capture_path>
# Returns directory path of the limit-finder run via stdout. Captures "✓ issue
# #X → <sid>" lines from stdout for issue-number tracking.
run_one() {
  local label="$1" cli="$2" tier="$3" duration="$4" require_ao_trace="$5" issue_capture="$6"
  local extra=()
  [ "$require_ao_trace" = "0" ] && extra+=(--no-require-ao-trace)
  # claude-code uses native PostToolUse hooks (.claude/settings.json) and bypasses
  # the ~/.ao/bin/gh PATH wrapper, so the agent-side trace file stays empty even
  # when Claude makes gh calls. Disable the agent-trace integrity check for claude.
  [ "$AGENT" = "claude-code" ] && extra+=(--no-require-agent-trace)

  echo
  echo "────────── Run: $label  (tier=$tier, duration=${duration}s) ──────────"
  stop_ao
  guard_project_config "${label}-pre-cleanup"
  close_benchmark_issues
  guard_project_config_after "${label}-close-benchmark-issues" || return 1
  guard_project_config "${label}-pre-archive"
  archive_stale_sessions "$cli"
  guard_project_config_after "${label}-archive-stale-sessions" || return 1

  local stdout_file="$BATCH_DIR/${label}.stdout"
  AO_BIN="node $cli" bash "$LF_SCRIPT" \
    --project-dir "$PROJECT_DIR" \
    --tiers "$tier" \
    --tier-duration "$duration" \
    --agent "$AGENT" \
    "${extra[@]}" 2>&1 | tee "$stdout_file"

  # Resolve the limit-finder output dir (latest one under experiments/out/)
  local lf_dir
  lf_dir=$(ls -1dt "$FEAT_DIR"/experiments/out/limit-finder-* 2>/dev/null | head -1)
  echo "$lf_dir" > "$BATCH_DIR/${label}.lf-dir"

  # Capture exact agent-trace path that limit-finder used for THIS run.
  # limit-finder logs "Trace (agent): /path/agent-gh-limitfinder-<ts>.jsonl".
  # Without this we'd `ls -1t | head -1` later and always pick the last batch's
  # trace — corrupting per-run rows in the comparison table.
  local agent_trace_path
  agent_trace_path=$(grep -oE 'Trace \(agent\): [^[:space:]]+' "$stdout_file" | head -1 | awk '{print $3}')
  echo "${agent_trace_path:-}" > "$BATCH_DIR/${label}.agent-trace"

  # Extract "✓ issue #X → <sid>" lines
  grep -E '✓ issue #[0-9]+ →' "$stdout_file" | awk '{print $3}' | tr -d '#' > "$issue_capture" || true
}

# parse_run <label> <lf-dir> → emits a YAML-ish metadata block
parse_run() {
  local label="$1" lf_dir="$2"
  local tier_dir="$lf_dir/tier-$TIER"
  [ ! -d "$tier_dir" ] && tier_dir="$lf_dir/tier-$SMOKE_TIER"
  local rb="$tier_dir/ratelimit-before.json"
  local ra="$tier_dir/ratelimit-after.json"

  local gq_before gq_after core_before core_after delta_gq delta_core ao_rows agent_rows terminal_pct supported
  gq_before=$(jq -r '.resources.graphql.used' "$rb" 2>/dev/null || echo 0)
  gq_after=$(jq -r '.resources.graphql.used' "$ra" 2>/dev/null || echo 0)
  core_before=$(jq -r '.resources.core.used' "$rb" 2>/dev/null || echo 0)
  core_after=$(jq -r '.resources.core.used' "$ra" 2>/dev/null || echo 0)
  delta_gq=$((gq_after - gq_before))
  delta_core=$((core_after - core_before))
  ao_rows=0; agent_rows=0
  [ -f "$tier_dir/gh-trace-ao.jsonl" ] && ao_rows=$(wc -l < "$tier_dir/gh-trace-ao.jsonl" | tr -d ' ')
  local agent_trace
  agent_trace=$(cat "$BATCH_DIR/${label}.agent-trace" 2>/dev/null || true)
  [ -n "$agent_trace" ] && [ -f "$agent_trace" ] && agent_rows=$(wc -l < "$agent_trace" | tr -d ' ')

  # Pull summary fields
  local summary="$tier_dir/summary.md"
  terminal_pct=$(grep -E '^- Sessions in terminal state' "$summary" 2>/dev/null | grep -oE '[0-9]+%' | head -1 || echo "?")
  supported=$(grep -E '\*\*Supported:' "$summary" 2>/dev/null | sed 's/.*Supported: //' | sed 's/\*\*//g' | tr -d '\n' || echo "?")

  echo "branch: $label"
  echo "tier_dir: $tier_dir"
  echo "graphql_before: $gq_before"
  echo "graphql_after:  $gq_after"
  echo "graphql_delta:  $delta_gq"
  echo "core_before:    $core_before"
  echo "core_after:     $core_after"
  echo "core_delta:     $delta_core"
  echo "ao_rows:        $ao_rows"
  echo "agent_rows:     $agent_rows"
  echo "terminal_pct:   $terminal_pct"
  echo "supported:      $supported"
  echo "top10:"
  [ -f "$tier_dir/top10-agent-subcommands.txt" ] && sed 's/^/  /' "$tier_dir/top10-agent-subcommands.txt" || echo "  (no trace)"
}

trap 'stop_ao' EXIT INT TERM

# ─── Pre-flight ───────────────────────────────────────────────────────────────
echo
echo "Pre-flight: budget check"
USED_PCT=$(rate_used_pct)
if [ "$USED_PCT" -ge 50 ]; then
  echo "ERROR: GraphQL bucket is ${USED_PCT}% used. Run again after reset." >&2
  exit 2
fi
echo "  GraphQL used=${USED_PCT}% — OK to proceed."

echo
echo "Pre-flight: stopping any running AO and cleaning stale sessions"
stop_ao
guard_project_config "preflight-pre-archive"
archive_stale_sessions "$FEAT_CLI"
guard_project_config_after "preflight-archive-stale-sessions"
guard_project_config "preflight-pre-close"
close_benchmark_issues
guard_project_config_after "preflight-close-benchmark-issues"

# ─── Smoke tests ───────────────────────────────────────────────────────────────
# Gate: AO_ROWS>0 on both smokes (AO-side instrumentation healthy).
#
# AGENT_ROWS is recorded but NOT gated for claude-code: Claude uses native
# PostToolUse hooks (.claude/settings.json) and bypasses the ~/.ao/bin/gh PATH
# wrapper, so AGENT_ROWS is always 0 regardless of how many gh calls the agent
# made. For B1 A/B validation this is fine — the fix lives in scm-github (AO
# daemon), measured by AO-side execGhObserved. For codex/aider/opencode, the
# wrapper IS exercised and AGENT_ROWS would be meaningful; keep that gate if/when
# we re-run with those agents.
#   - AO_ROWS=0 → abort immediately (instrumentation failure, no retry)
# Writes the final successful label to "$BATCH_DIR/<base-label>.final-label".
smoke_check() {
  local base_label="$1" cli="$2"
  local lbl="$base_label"
  run_one "$lbl" "$cli" "$SMOKE_TIER" "$SMOKE_DURATION" "1" "$BATCH_DIR/${lbl}.issues"

  local lf_dir; lf_dir=$(cat "$BATCH_DIR/${lbl}.lf-dir")
  local tier_dir="$lf_dir/tier-$SMOKE_TIER"
  local ao_rows=0 agent_rows=0
  [ -f "$tier_dir/gh-trace-ao.jsonl" ] && ao_rows=$(wc -l < "$tier_dir/gh-trace-ao.jsonl" | tr -d ' ')
  local agent_trace; agent_trace=$(cat "$BATCH_DIR/${lbl}.agent-trace" 2>/dev/null || true)
  [ -n "$agent_trace" ] && [ -f "$agent_trace" ] && agent_rows=$(wc -l < "$agent_trace" | tr -d ' ')

  echo "  [$lbl] AO_ROWS=$ao_rows AGENT_ROWS=$agent_rows (agent gate disabled for $AGENT)"

  if [ "$ao_rows" -lt 1 ]; then
    echo "  🚨 AO_ROWS=0 on $base_label — instrumentation failure, aborting." >&2
    return 1
  fi

  echo "$lbl" > "$BATCH_DIR/${base_label}.final-label"
  echo "$ao_rows" > "$BATCH_DIR/${base_label}.smoke-ao-rows"
  echo "$agent_rows" > "$BATCH_DIR/${base_label}.smoke-agent-rows"
  return 0
}

echo
echo "════ Smoke: feat ($FEAT_SHA) ════"
if ! smoke_check "smoke-feat" "$FEAT_CLI"; then
  echo "ABORTING: feat smoke failed. Inspect $BATCH_DIR/smoke-feat*.stdout" >&2
  exit 3
fi

echo
echo "════ Smoke: main-probe ($MAIN_SHA) ════"
if ! smoke_check "smoke-main" "$MAIN_CLI"; then
  echo "ABORTING: main-probe smoke failed. Inspect $BATCH_DIR/smoke-main*.stdout" >&2
  exit 3
fi

SMOKE_FEAT_LABEL=$(cat "$BATCH_DIR/smoke-feat.final-label")
SMOKE_MAIN_LABEL=$(cat "$BATCH_DIR/smoke-main.final-label")
SM_FEAT_AO=$(cat "$BATCH_DIR/smoke-feat.smoke-ao-rows")
SM_FEAT_AG=$(cat "$BATCH_DIR/smoke-feat.smoke-agent-rows")
SM_MAIN_AO=$(cat "$BATCH_DIR/smoke-main.smoke-ao-rows")
SM_MAIN_AG=$(cat "$BATCH_DIR/smoke-main.smoke-agent-rows")

echo
echo "Smoke summary:"
echo "  feat       ($SMOKE_FEAT_LABEL) AO_ROWS=$SM_FEAT_AO  AGENT_ROWS=$SM_FEAT_AG"
echo "  main-probe ($SMOKE_MAIN_LABEL) AO_ROWS=$SM_MAIN_AO  AGENT_ROWS=$SM_MAIN_AG"
echo "  ✅ Both smokes trustworthy. Proceeding to main A/B batch."

# ─── Main A/B batch: alternating feat → main → feat → main ─────────────────────
RUN_LABELS=()
RUN_BRANCH=()
for i in $(seq 1 "$RUNS"); do
  if (( i % 2 == 1 )); then
    label="run${i}-feat"
    RUN_BRANCH+=("feat")
  else
    label="run${i}-main"
    RUN_BRANCH+=("main-probe")
  fi
  RUN_LABELS+=("$label")
done

for i in "${!RUN_LABELS[@]}"; do
  label="${RUN_LABELS[$i]}"
  branch="${RUN_BRANCH[$i]}"
  cli=$([ "$branch" = "feat" ] && echo "$FEAT_CLI" || echo "$MAIN_CLI")

  echo
  echo "════ $label ($branch) ════"
  wait_for_graphql_reset
  run_one "$label" "$cli" "$TIER" "$DURATION" "1" "$BATCH_DIR/${label}.issues"
done

# ─── Build comparison report ──────────────────────────────────────────────────
echo
echo "Aggregating results into $COMPARE_MD"

{
  echo "# M2 A/B Comparison — feat vs probe/main-gh-trace"
  echo
  echo "- **Generated:** $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "- **Repo:** \`$REPO\`"
  echo "- **Project:** \`$PROJECT_DIR\`"
  echo "- **Feat SHA:** \`$FEAT_SHA\`"
  echo "- **Main SHA:** \`$MAIN_SHA\` (probe/main-gh-trace)"
  echo "- **Per-run:** tier=$TIER, duration=${DURATION}s, agent=$AGENT"
  echo "- **Smokes:** tier=$SMOKE_TIER × ${SMOKE_DURATION}s on each branch (required AO>0; AGENT not gated for $AGENT)"
  echo
  echo "## Smoke integrity"
  echo
  echo "Smoke gate: AO_ROWS>0 (no retry). AGENT_ROWS not gated for $AGENT."
  echo
  echo "| Branch | Final attempt | AO rows | Agent rows | Trustworthy |"
  echo "|--------|---------------|--------:|-----------:|:------------|"
  echo "| feat       | $SMOKE_FEAT_LABEL | $SM_FEAT_AO | $SM_FEAT_AG | ✅ |"
  echo "| main-probe | $SMOKE_MAIN_LABEL | $SM_MAIN_AO | $SM_MAIN_AG | ✅ |"
  echo
  echo "## Per-run metadata"
  echo

  for i in "${!RUN_LABELS[@]}"; do
    label="${RUN_LABELS[$i]}"
    branch="${RUN_BRANCH[$i]}"
    lf_dir=$(cat "$BATCH_DIR/${label}.lf-dir")
    issues=$(cat "$BATCH_DIR/${label}.issues" 2>/dev/null | tr '\n' ',' | sed 's/,$//')
    sha=$([ "$branch" = "feat" ] && echo "$FEAT_SHA" || echo "$MAIN_SHA")

    echo "### $label — $branch @ \`${sha:0:12}\`"
    echo
    echo "- **Issues:** ${issues:-(none captured)}"
    echo "- **LF dir:** \`$lf_dir\`"
    echo
    echo "\`\`\`yaml"
    parse_run "$label" "$lf_dir"
    echo "\`\`\`"
    echo
  done

  echo "## Summary table"
  echo
  echo "| Run | Branch | GraphQL Δ | pts/hr | Core Δ | AO rows | Agent rows | Terminal % | Supported |"
  echo "|-----|--------|----------:|-------:|-------:|--------:|-----------:|-----------:|:----------|"
  for i in "${!RUN_LABELS[@]}"; do
    label="${RUN_LABELS[$i]}"
    branch="${RUN_BRANCH[$i]}"
    lf_dir=$(cat "$BATCH_DIR/${label}.lf-dir")
    tier_dir="$lf_dir/tier-$TIER"
    [ ! -d "$tier_dir" ] && tier_dir="$lf_dir/tier-$SMOKE_TIER"

    gq_before=$(jq -r '.resources.graphql.used' "$tier_dir/ratelimit-before.json" 2>/dev/null || echo 0)
    gq_after=$(jq -r '.resources.graphql.used' "$tier_dir/ratelimit-after.json" 2>/dev/null || echo 0)
    core_before=$(jq -r '.resources.core.used' "$tier_dir/ratelimit-before.json" 2>/dev/null || echo 0)
    core_after=$(jq -r '.resources.core.used' "$tier_dir/ratelimit-after.json" 2>/dev/null || echo 0)
    dgq=$((gq_after - gq_before))
    dcore=$((core_after - core_before))
    pph=$(( dgq * 3600 / DURATION ))
    aor=0; agr=0
    [ -f "$tier_dir/gh-trace-ao.jsonl" ] && aor=$(wc -l < "$tier_dir/gh-trace-ao.jsonl" | tr -d ' ')
    agent_trace=$(cat "$BATCH_DIR/${label}.agent-trace" 2>/dev/null || true)
    [ -n "$agent_trace" ] && [ -f "$agent_trace" ] && agr=$(wc -l < "$agent_trace" | tr -d ' ')
    term_pct=$(grep -E '^- Sessions in terminal state' "$tier_dir/summary.md" 2>/dev/null | grep -oE '[0-9]+%' | head -1 || echo "?")
    supp=$(grep -E '\*\*Supported:' "$tier_dir/summary.md" 2>/dev/null | sed 's/.*Supported: //' | sed 's/\*\*//g' | tr -d '\n' || echo "?")

    echo "| $label | $branch | $dgq | $pph | $dcore | $aor | $agr | $term_pct | $supp |"
  done
  echo
  echo "## Notes"
  echo
  echo "- Agent-trace path is captured per-run from limit-finder's stdout (\`Trace (agent): ...\` line)"
  echo "  and stored in \`<batch-dir>/<label>.agent-trace\`. No \`ls -1t\` ambiguity."
  echo "- GraphQL Δ is raw \`gh api rate_limit\` delta (includes wrapper overhead)."
  echo "- Any run with \`Supported: UNTRUSTWORTHY\` is disqualified from the comparison."
} > "$COMPARE_MD"

echo
echo "════════════════════════════════════════════════════════════"
echo "  M2 batch complete."
echo "  Comparison: $COMPARE_MD"
echo "════════════════════════════════════════════════════════════"
