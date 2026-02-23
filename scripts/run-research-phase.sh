#!/usr/bin/env bash
# Phase 1: Launch 3 research agents in parallel and wait for all to complete
#
# Usage: run-research-phase.sh <research_id> <topic> <max_iters> \
#          <claude_model> <codex_model> <codex_reasoning> <gemini_model>

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(dirname "$SCRIPT_DIR")"
PROJECT_DIR="$(pwd)"

RESEARCH_ID="$1"
TOPIC="$2"
MAX_ITERS="$3"
CLAUDE_MODEL="$4"
CODEX_MODEL="$5"
CODEX_REASONING="$6"
GEMINI_MODEL="$7"

WORKSPACE="${PROJECT_DIR}/research/${RESEARCH_ID}"
PROGRESS_LOG="${WORKSPACE}/progress.log"

mkdir -p "$WORKSPACE"

# Ensure WORKSPACE is absolute (needed for agents that cd elsewhere)
WORKSPACE="$(cd "$WORKSPACE" && pwd)"
PROGRESS_LOG="${WORKSPACE}/progress.log"

log() {
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" | tee -a "$PROGRESS_LOG"
}

log "Phase 1: Starting initial research"
log "  Topic: ${TOPIC}"
log "  Max iterations: ${MAX_ITERS}"
log "  Claude: ${CLAUDE_MODEL} | Codex: ${CODEX_MODEL} (${CODEX_REASONING}) | Gemini: ${GEMINI_MODEL}"

# ── Prompt file (shared base, customized per agent) ───────────────────────
RESEARCH_PROMPT="$(cat "${PLUGIN_ROOT}/prompts/research-system.md")

## Your Research Topic

${TOPIC}

## Output

Write your report to the file path specified below. Create or overwrite the file with your full report."

# ── Launch Claude subagent ────────────────────────────────────────────────
CLAUDE_REPORT="${WORKSPACE}/claude-report.md"
CLAUDE_STATE="${WORKSPACE}/claude-state.txt"
CLAUDE_SETTINGS="${WORKSPACE}/claude-settings.json"

echo "1" > "$CLAUDE_STATE"

cat > "$CLAUDE_SETTINGS" << SETTINGS_EOF
{
  "hooks": {
    "Stop": [{
      "hooks": [{
        "type": "command",
        "command": "${PLUGIN_ROOT}/scripts/claude-stop-hook.sh",
        "timeout": 120
      }]
    }]
  }
}
SETTINGS_EOF

log "Phase 1: Launching Claude agent (${CLAUDE_MODEL})"

(
  RESEARCH_REPORT_PATH="$CLAUDE_REPORT" \
  RESEARCH_STATE_PATH="$CLAUDE_STATE" \
  RESEARCH_MAX_ITERS="$MAX_ITERS" \
  env -u CLAUDECODE claude -p \
    --model "$CLAUDE_MODEL" \
    --dangerously-skip-permissions \
    --settings "$CLAUDE_SETTINGS" \
    --max-turns 200 \
    "${RESEARCH_PROMPT}

Write your report to: ${CLAUDE_REPORT}" > "${WORKSPACE}/claude-stdout.log" 2>&1
  log "Phase 1: Claude agent finished (exit $?)"
) &
CLAUDE_PID=$!

# ── Launch Codex subagent ─────────────────────────────────────────────────
CODEX_REPORT="${WORKSPACE}/codex-report.md"

log "Phase 1: Launching Codex agent (${CODEX_MODEL}, reasoning: ${CODEX_REASONING})"

(
  cd "$PROJECT_DIR"
  bash "${PLUGIN_ROOT}/scripts/codex-wrapper.sh" \
    "$TOPIC" \
    "$CODEX_REPORT" \
    "$MAX_ITERS" \
    "$CODEX_MODEL" \
    "$CODEX_REASONING" \
    "$PROGRESS_LOG" > "${WORKSPACE}/codex-stdout.log" 2>&1
  log "Phase 1: Codex agent finished (exit $?)"
) &
CODEX_PID=$!

# ── Launch Gemini subagent ────────────────────────────────────────────────
GEMINI_REPORT="${WORKSPACE}/gemini-report.md"
GEMINI_STATE="${WORKSPACE}/gemini-state.txt"
GEMINI_WORKSPACE="${WORKSPACE}/gemini-workspace"

echo "1" > "$GEMINI_STATE"
mkdir -p "${GEMINI_WORKSPACE}/.gemini"

# Create isolated Gemini settings with AfterAgent hook
cat > "${GEMINI_WORKSPACE}/.gemini/settings.json" << GEMINI_SETTINGS_EOF
{
  "hooksConfig": {"enabled": true},
  "hooks": {
    "AfterAgent": [{
      "matcher": "*",
      "hooks": [{
        "name": "research-loop",
        "type": "command",
        "command": "${PLUGIN_ROOT}/scripts/gemini-afteragent-hook.sh",
        "timeout": 30000
      }]
    }]
  }
}
GEMINI_SETTINGS_EOF

# Gemini writes to a local file in its workspace (sandbox restriction),
# then we copy it to the expected location after Gemini finishes.
GEMINI_LOCAL_REPORT="report.md"

# Create GEMINI.md in the workspace with research instructions
cat > "${GEMINI_WORKSPACE}/GEMINI.md" << GEMINI_MD_EOF
$(cat "${PLUGIN_ROOT}/prompts/research-system.md")

## Your Research Topic

${TOPIC}

## Output

Write your report to: ${GEMINI_LOCAL_REPORT}
GEMINI_MD_EOF

log "Phase 1: Launching Gemini agent (${GEMINI_MODEL})"

(
  cd "$GEMINI_WORKSPACE"
  RESEARCH_REPORT_PATH="${GEMINI_WORKSPACE}/${GEMINI_LOCAL_REPORT}" \
  RESEARCH_STATE_PATH="$GEMINI_STATE" \
  RESEARCH_MAX_ITERS="$MAX_ITERS" \
  RESEARCH_PROGRESS_LOG="$PROGRESS_LOG" \
  gemini --model "$GEMINI_MODEL" --approval-mode=yolo \
    "Conduct deep research on: ${TOPIC}. Write your comprehensive report to ${GEMINI_LOCAL_REPORT}." \
    > "${WORKSPACE}/gemini-stdout.log" 2>&1
  GEMINI_EXIT=$?
  # Copy report from Gemini workspace to expected location
  if [ -f "${GEMINI_LOCAL_REPORT}" ] && [ -s "${GEMINI_LOCAL_REPORT}" ]; then
    cp "${GEMINI_LOCAL_REPORT}" "${GEMINI_REPORT}"
  fi
  log "Phase 1: Gemini agent finished (exit $GEMINI_EXIT)"
) &
GEMINI_PID=$!

# ── Wait for all agents ──────────────────────────────────────────────────
log "Phase 1: Waiting for all 3 agents (PIDs: Claude=${CLAUDE_PID}, Codex=${CODEX_PID}, Gemini=${GEMINI_PID})"

FAILURES=0

wait $CLAUDE_PID || { log "Phase 1: Claude agent failed"; FAILURES=$((FAILURES + 1)); }
wait $CODEX_PID || { log "Phase 1: Codex agent failed"; FAILURES=$((FAILURES + 1)); }
wait $GEMINI_PID || { log "Phase 1: Gemini agent failed"; FAILURES=$((FAILURES + 1)); }

# ── Report results ────────────────────────────────────────────────────────
REPORTS_FOUND=0
for f in "$CLAUDE_REPORT" "$CODEX_REPORT" "$GEMINI_REPORT"; do
  if [ -f "$f" ] && [ -s "$f" ]; then
    REPORTS_FOUND=$((REPORTS_FOUND + 1))
    log "Phase 1: Report found: $(basename "$f") ($(wc -l < "$f") lines)"
  else
    log "Phase 1: WARNING — missing report: $(basename "$f")"
  fi
done

if [ "$REPORTS_FOUND" -eq 0 ]; then
  log "Phase 1: FATAL — no reports produced by any agent"
  exit 1
fi

log "Phase 1: Complete (${REPORTS_FOUND}/3 reports produced, ${FAILURES} agent failures)"
