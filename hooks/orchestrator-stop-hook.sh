#!/usr/bin/env bash
# Deep Research Council — Orchestrator Stop Hook
#
# Phase state machine:
#   research   → run 3 parallel research agents → refinement
#   refinement → run 3 parallel refinement agents → synthesis
#   synthesis  → check for final report → allow exit
#
# Fail-open: on any unexpected error, allow exit (never trap the user).

LOG_FILE=".claude/deep-research.log"

log() {
  mkdir -p "$(dirname "$LOG_FILE")"
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] orchestrator: $*" >> "$LOG_FILE"
}

# On any error, allow exit
trap 'log "ERROR: hook exited via ERR trap (line $LINENO)"; printf "{\"decision\":\"approve\"}\n"; exit 0' ERR

# Consume stdin
HOOK_INPUT=$(cat)

STATE_FILE=".claude/deep-research.local.md"

# No active session → allow exit
if [ ! -f "$STATE_FILE" ]; then
  exit 0
fi

# ── Parse state file fields ──────────────────────────────────────────────
parse_field() {
  sed -n "s/^${1}: *//p" "$STATE_FILE" | head -1
}

ACTIVE=$(parse_field "active")
PHASE=$(parse_field "phase")
RESEARCH_ID=$(parse_field "research_id")
TEST_MODE=$(parse_field "test_mode")
MAX_ITERS=$(parse_field "max_iterations")
CLAUDE_MODEL=$(parse_field "claude_model")
CODEX_MODEL=$(parse_field "codex_model")
CODEX_REASONING=$(parse_field "codex_reasoning")
GEMINI_MODEL=$(parse_field "gemini_model")

# Not active → clean up
if [ "$ACTIVE" != "true" ]; then
  rm -f "$STATE_FILE"
  exit 0
fi

# Validate research_id format
if ! echo "$RESEARCH_ID" | grep -qE '^[0-9]{8}-[0-9]{6}-[0-9a-f]{6}$'; then
  log "ERROR: invalid research_id format: $RESEARCH_ID"
  rm -f "$STATE_FILE"
  exit 0
fi

# Extract topic (everything after closing --- in the markdown)
TOPIC=$(awk '/^---$/{i++; next} i>=2' "$STATE_FILE" | sed '/^$/d')

if [ -z "$TOPIC" ]; then
  log "ERROR: no topic found in state file"
  rm -f "$STATE_FILE"
  exit 0
fi

WORKSPACE="research/${RESEARCH_ID}"
SCRIPT_DIR="$(cd "$(dirname "$0")/../scripts" && pwd)"
PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Safety: prevent re-entrant loops
STOP_HOOK_ACTIVE=$(echo "$HOOK_INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null || echo "false")
if [ "$STOP_HOOK_ACTIVE" = "true" ] && [ "$PHASE" = "research" ]; then
  log "WARN: stop_hook_active=true during research phase, possible loop — aborting"
  rm -f "$STATE_FILE"
  exit 0
fi

# ── Phase: research ──────────────────────────────────────────────────────
run_research() {
  log "Starting Phase 1: Initial Research"

  bash "${PLUGIN_ROOT}/scripts/run-research-phase.sh" \
    "$RESEARCH_ID" \
    "$TOPIC" \
    "$MAX_ITERS" \
    "$CLAUDE_MODEL" \
    "$CODEX_MODEL" \
    "$CODEX_REASONING" \
    "$GEMINI_MODEL"

  RESULT=$?
  log "Phase 1 finished (exit $RESULT)"

  # Check if any reports were produced
  REPORTS_FOUND=0
  for f in "${WORKSPACE}/claude-report.md" "${WORKSPACE}/codex-report.md" "${WORKSPACE}/gemini-report.md"; do
    [ -f "$f" ] && [ -s "$f" ] && REPORTS_FOUND=$((REPORTS_FOUND + 1))
  done

  if [ "$REPORTS_FOUND" -eq 0 ]; then
    log "FATAL: No reports produced in Phase 1"
    rm -f "$STATE_FILE"
    REASON="ERROR: No research reports were produced by any agent. Check ${WORKSPACE}/progress.log and the agent stdout logs for errors. Common issues:
- CLI authentication not set up (run 'codex login', 'gemini' to auth)
- API keys not configured
- Model names not available on your subscription tier

Review the logs and try again with /deep-research"
    jq -n --arg r "$REASON" '{decision:"block", reason:$r}'
    return
  fi

  # Update state to refinement
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' 's/^phase: research$/phase: refinement/' "$STATE_FILE"
  else
    sed -i 's/^phase: research$/phase: refinement/' "$STATE_FILE"
  fi
}

# ── Phase: refinement ────────────────────────────────────────────────────
run_refinement() {
  log "Starting Phase 2: Cross-Pollination Refinement"

  bash "${PLUGIN_ROOT}/scripts/run-refinement-phase.sh" \
    "$RESEARCH_ID" \
    "$TOPIC" \
    "$MAX_ITERS" \
    "$CLAUDE_MODEL" \
    "$CODEX_MODEL" \
    "$CODEX_REASONING" \
    "$GEMINI_MODEL"

  log "Phase 2 finished (exit $?)"

  # Update state to synthesis
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' 's/^phase: refinement$/phase: synthesis/' "$STATE_FILE"
  else
    sed -i 's/^phase: refinement$/phase: synthesis/' "$STATE_FILE"
  fi

  # Build list of available refined reports and track which agents succeeded
  REPORT_LIST=""
  MISSING_LIST=""
  AGENT_NAMES=("Claude" "Codex" "Gemini")
  AGENT_FILES=("${WORKSPACE}/claude-refined.md" "${WORKSPACE}/codex-refined.md" "${WORKSPACE}/gemini-refined.md")
  AVAILABLE_COUNT=0

  for i in 0 1 2; do
    f="${AGENT_FILES[$i]}"
    name="${AGENT_NAMES[$i]}"
    if [ -f "$f" ] && [ -s "$f" ]; then
      REPORT_LIST="${REPORT_LIST}
- ${f} (${name})"
      AVAILABLE_COUNT=$((AVAILABLE_COUNT + 1))
    else
      MISSING_LIST="${MISSING_LIST}
- ${name}: no report produced (check ${WORKSPACE}/${name,,}-stdout.log for errors)"
    fi
  done

  COVERAGE_NOTE=""
  if [ -n "$MISSING_LIST" ]; then
    COVERAGE_NOTE="
NOTE: Not all agents produced reports. Missing:${MISSING_LIST}

Your synthesis should note this reduced coverage in the Methodology section."
  fi

  SYNTHESIS_PROMPT="Research and refinement phases are complete. ${AVAILABLE_COUNT} of 3 AI agents produced refined reports.

Topic: ${TOPIC}
${COVERAGE_NOTE}
Read the available refined reports:${REPORT_LIST}

Synthesize everything into: ${WORKSPACE}/final-report.md

Structure the synthesis as:
1. **Executive Summary** — the most important findings across all investigations
2. **Key Findings** — organized by THEME (not by source agent), combining the strongest evidence
3. **Areas of Consensus** — where agents agree, with combined supporting evidence
4. **Areas of Disagreement** — where agents differed, with analysis of why and which view is better supported
5. **Novel Insights** — unique findings that emerged from the cross-pollination refinement round
6. **Open Questions** — what remains uncertain even after three independent investigations
7. **Sources** — comprehensive, deduplicated list of all URLs and references from all reports
8. **Methodology** — brief description of the multi-agent research process

Be thorough. This is the final deliverable."

  SYS_MSG="Research Council [${RESEARCH_ID}] — Phase 3/3: Synthesis"

  jq -n --arg r "$SYNTHESIS_PROMPT" --arg s "$SYS_MSG" \
    '{decision:"block", reason:$r, systemMessage:$s}'
}

# ── Phase: synthesis ─────────────────────────────────────────────────────
check_synthesis() {
  FINAL="${WORKSPACE}/final-report.md"
  if [ -f "$FINAL" ] && [ -s "$FINAL" ]; then
    log "Synthesis complete: ${FINAL} ($(wc -l < "$FINAL") lines)"
    rm -f "$STATE_FILE"
    printf '{"decision":"approve"}\n'
  else
    REASON="Please write the synthesis report to ${WORKSPACE}/final-report.md by reading all refined reports in ${WORKSPACE}/. See the instructions above."
    jq -n --arg r "$REASON" '{decision:"block", reason:$r}'
  fi
}

# ── State machine ────────────────────────────────────────────────────────
case "$PHASE" in
  research)
    run_research
    # Fall through to refinement if research succeeded
    if [ "$(parse_field "phase")" = "refinement" ]; then
      run_refinement
    fi
    ;;

  refinement)
    run_refinement
    ;;

  synthesis)
    check_synthesis
    ;;

  *)
    log "WARN: unknown phase '$PHASE', cleaning up"
    rm -f "$STATE_FILE"
    exit 0
    ;;
esac
