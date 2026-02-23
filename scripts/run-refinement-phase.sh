#!/usr/bin/env bash
# Phase 2: Cross-pollination refinement — each agent reads all 3 reports and refines
#
# Usage: run-refinement-phase.sh <research_id> <topic> <max_iters> \
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

# Ensure WORKSPACE is absolute (needed for agents that cd elsewhere)
if [ -d "$WORKSPACE" ]; then
  WORKSPACE="$(cd "$WORKSPACE" && pwd)"
fi
PROGRESS_LOG="${WORKSPACE}/progress.log"

log() {
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" | tee -a "$PROGRESS_LOG"
}

log "Phase 2: Starting cross-pollination refinement"

CLAUDE_REPORT="${WORKSPACE}/claude-report.md"
CODEX_REPORT="${WORKSPACE}/codex-report.md"
GEMINI_REPORT="${WORKSPACE}/gemini-report.md"

CLAUDE_REFINED="${WORKSPACE}/claude-refined.md"
CODEX_REFINED="${WORKSPACE}/codex-refined.md"
GEMINI_REFINED="${WORKSPACE}/gemini-refined.md"

REFINEMENT_PROMPT="$(cat "${PLUGIN_ROOT}/prompts/refinement-system.md")"

# Helper: build refinement prompt for a specific agent
build_refinement_prompt() {
  local OWN_REPORT="$1"
  local OWN_LABEL="$2"
  local OTHER1="$3"
  local OTHER1_LABEL="$4"
  local OTHER2="$5"
  local OTHER2_LABEL="$6"
  local OUTPUT="$7"

  echo "${REFINEMENT_PROMPT}

## Research Topic
${TOPIC}

## Files
- Your original report (${OWN_LABEL}): ${OWN_REPORT}
- Other report (${OTHER1_LABEL}): ${OTHER1}
- Other report (${OTHER2_LABEL}): ${OTHER2}
- Write your REFINED report to: ${OUTPUT}

Read all three reports, then write your refined report to ${OUTPUT}."
}

# ── Launch Claude refinement ──────────────────────────────────────────────
if [ -f "$CLAUDE_REPORT" ] && [ -s "$CLAUDE_REPORT" ]; then
  CLAUDE_STATE="${WORKSPACE}/claude-refine-state.txt"
  CLAUDE_SETTINGS="${WORKSPACE}/claude-refine-settings.json"

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

  CLAUDE_REFINE_PROMPT="$(build_refinement_prompt "$CLAUDE_REPORT" "Claude" "$CODEX_REPORT" "Codex" "$GEMINI_REPORT" "Gemini" "$CLAUDE_REFINED")"

  log "Phase 2: Launching Claude refinement agent"

  (
    RESEARCH_REPORT_PATH="$CLAUDE_REFINED" \
    RESEARCH_STATE_PATH="$CLAUDE_STATE" \
    RESEARCH_MAX_ITERS="$MAX_ITERS" \
    env -u CLAUDECODE claude -p \
      --model "$CLAUDE_MODEL" \
      --dangerously-skip-permissions \
      --settings "$CLAUDE_SETTINGS" \
      --max-turns 200 \
      "$CLAUDE_REFINE_PROMPT" > "${WORKSPACE}/claude-refine-stdout.log" 2>&1
    log "Phase 2: Claude refinement finished (exit $?)"
  ) &
  CLAUDE_PID=$!
else
  log "Phase 2: Skipping Claude refinement (no Phase 1 report)"
  CLAUDE_PID=""
fi

# ── Launch Codex refinement ───────────────────────────────────────────────
if [ -f "$CODEX_REPORT" ] && [ -s "$CODEX_REPORT" ]; then
  # For Codex, we build a combined prompt that includes the refinement instructions
  # and tells it to read all reports
  CODEX_REFINE_PROMPT="$(build_refinement_prompt "$CODEX_REPORT" "Codex" "$CLAUDE_REPORT" "Claude" "$GEMINI_REPORT" "Gemini" "$CODEX_REFINED")"

  log "Phase 2: Launching Codex refinement agent"

  (
    cd "$PROJECT_DIR"
    bash "${PLUGIN_ROOT}/scripts/codex-wrapper.sh" \
      "REFINEMENT TASK: ${CODEX_REFINE_PROMPT}" \
      "$CODEX_REFINED" \
      "$MAX_ITERS" \
      "$CODEX_MODEL" \
      "$CODEX_REASONING" \
      "$PROGRESS_LOG" > "${WORKSPACE}/codex-refine-stdout.log" 2>&1
    log "Phase 2: Codex refinement finished (exit $?)"
  ) &
  CODEX_PID=$!
else
  log "Phase 2: Skipping Codex refinement (no Phase 1 report)"
  CODEX_PID=""
fi

# ── Launch Gemini refinement ──────────────────────────────────────────────
if [ -f "$GEMINI_REPORT" ] && [ -s "$GEMINI_REPORT" ]; then
  GEMINI_STATE="${WORKSPACE}/gemini-refine-state.txt"
  GEMINI_WORKSPACE="${WORKSPACE}/gemini-refine-workspace"
  GEMINI_LOCAL_REFINED="refined-report.md"

  echo "1" > "$GEMINI_STATE"
  mkdir -p "${GEMINI_WORKSPACE}/.gemini"

  # Copy input reports INTO Gemini workspace (sandbox can't read outside)
  cp "$GEMINI_REPORT" "${GEMINI_WORKSPACE}/own-report.md" 2>/dev/null || true
  cp "$CLAUDE_REPORT" "${GEMINI_WORKSPACE}/claude-report.md" 2>/dev/null || true
  cp "$CODEX_REPORT" "${GEMINI_WORKSPACE}/codex-report.md" 2>/dev/null || true

  cat > "${GEMINI_WORKSPACE}/.gemini/settings.json" << GEMINI_SETTINGS_EOF
{
  "hooksConfig": {"enabled": true},
  "hooks": {
    "AfterAgent": [{
      "matcher": "*",
      "hooks": [{
        "name": "refinement-loop",
        "type": "command",
        "command": "${PLUGIN_ROOT}/scripts/gemini-afteragent-hook.sh",
        "timeout": 30000
      }]
    }]
  }
}
GEMINI_SETTINGS_EOF

  # Build prompt with LOCAL paths (relative to Gemini workspace)
  GEMINI_REFINE_PROMPT="${REFINEMENT_PROMPT}

## Research Topic
${TOPIC}

## Files
- Your original report (Gemini): own-report.md
- Other report (Claude): claude-report.md
- Other report (Codex): codex-report.md
- Write your REFINED report to: ${GEMINI_LOCAL_REFINED}

Read all three reports, then write your refined report to ${GEMINI_LOCAL_REFINED}."

  cat > "${GEMINI_WORKSPACE}/GEMINI.md" << GEMINI_MD_EOF
${REFINEMENT_PROMPT}
GEMINI_MD_EOF

  log "Phase 2: Launching Gemini refinement agent"

  (
    cd "$GEMINI_WORKSPACE"
    RESEARCH_REPORT_PATH="${GEMINI_WORKSPACE}/${GEMINI_LOCAL_REFINED}" \
    RESEARCH_STATE_PATH="$GEMINI_STATE" \
    RESEARCH_MAX_ITERS="$MAX_ITERS" \
    RESEARCH_PROGRESS_LOG="$PROGRESS_LOG" \
    gemini --model "$GEMINI_MODEL" --approval-mode=yolo \
      "$GEMINI_REFINE_PROMPT" > "${WORKSPACE}/gemini-refine-stdout.log" 2>&1
    GEMINI_EXIT=$?
    # Copy refined report from workspace to expected location
    if [ -f "${GEMINI_LOCAL_REFINED}" ] && [ -s "${GEMINI_LOCAL_REFINED}" ]; then
      cp "${GEMINI_LOCAL_REFINED}" "${GEMINI_REFINED}"
    fi
    log "Phase 2: Gemini refinement finished (exit $GEMINI_EXIT)"
  ) &
  GEMINI_PID=$!
else
  log "Phase 2: Skipping Gemini refinement (no Phase 1 report)"
  GEMINI_PID=""
fi

# ── Wait for all agents ──────────────────────────────────────────────────
PIDS_TO_WAIT=()
[ -n "${CLAUDE_PID:-}" ] && PIDS_TO_WAIT+=("$CLAUDE_PID")
[ -n "${CODEX_PID:-}" ] && PIDS_TO_WAIT+=("$CODEX_PID")
[ -n "${GEMINI_PID:-}" ] && PIDS_TO_WAIT+=("$GEMINI_PID")

log "Phase 2: Waiting for ${#PIDS_TO_WAIT[@]} refinement agents"

FAILURES=0
for pid in "${PIDS_TO_WAIT[@]}"; do
  wait "$pid" || FAILURES=$((FAILURES + 1))
done

# ── Report results ────────────────────────────────────────────────────────
REFINED_FOUND=0
for f in "$CLAUDE_REFINED" "$CODEX_REFINED" "$GEMINI_REFINED"; do
  if [ -f "$f" ] && [ -s "$f" ]; then
    REFINED_FOUND=$((REFINED_FOUND + 1))
    log "Phase 2: Refined report found: $(basename "$f") ($(wc -l < "$f") lines)"
  else
    # Fall back to original report if refinement failed
    ORIGINAL="${f//-refined/-report}"
    if [ -f "$ORIGINAL" ] && [ -s "$ORIGINAL" ]; then
      cp "$ORIGINAL" "$f"
      log "Phase 2: WARNING — refinement failed for $(basename "$f"), using original report as fallback"
      REFINED_FOUND=$((REFINED_FOUND + 1))
    else
      log "Phase 2: WARNING — no refined report: $(basename "$f")"
    fi
  fi
done

log "Phase 2: Complete (${REFINED_FOUND}/3 refined reports, ${FAILURES} failures)"
