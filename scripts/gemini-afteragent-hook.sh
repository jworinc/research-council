#!/usr/bin/env bash
# Gemini Subagent AfterAgent Hook — keeps Gemini researching until complete
#
# Environment variables (set by the caller):
#   RESEARCH_REPORT_PATH  — path to the report file
#   RESEARCH_STATE_PATH   — path to iteration state file
#   RESEARCH_MAX_ITERS    — maximum iterations (default: 10)
#   RESEARCH_PROGRESS_LOG — path to progress log

set -uo pipefail

# Consume stdin (hook input JSON)
HOOK_INPUT=$(cat)

REPORT="${RESEARCH_REPORT_PATH:-}"
STATE="${RESEARCH_STATE_PATH:-}"
MAX_ITERS="${RESEARCH_MAX_ITERS:-10}"
PROGRESS_LOG="${RESEARCH_PROGRESS_LOG:-/dev/null}"

log() {
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] Gemini hook: $*" >> "$PROGRESS_LOG"
}

# Safety: if no report path, allow exit
if [ -z "$REPORT" ] || [ -z "$STATE" ]; then
  echo '{"decision": "allow"}'
  exit 0
fi

# Read current iteration
ITERATION=1
if [ -f "$STATE" ]; then
  ITERATION=$(cat "$STATE" 2>/dev/null || echo "1")
fi

if ! [[ "$ITERATION" =~ ^[0-9]+$ ]]; then
  ITERATION=1
fi

# Check completion marker
if [ -f "$REPORT" ] && grep -q "RESEARCH_COMPLETE" "$REPORT" 2>/dev/null; then
  log "Research complete (marker found) at iteration ${ITERATION}"
  echo '{"decision": "allow"}'
  exit 0
fi

# Check max iterations
if [ "$ITERATION" -ge "$MAX_ITERS" ]; then
  log "Max iterations (${MAX_ITERS}) reached"
  echo '{"decision": "allow"}'
  exit 0
fi

# Increment and save
NEXT=$((ITERATION + 1))
echo "$NEXT" > "$STATE"

log "Requesting iteration ${NEXT}/${MAX_ITERS}"

# Deny (reject response, force retry with reason as new prompt)
jq -n \
  --arg reason "Continue your research. Read your current report at ${REPORT}. Identify gaps, unexplored angles, and areas needing more depth. Conduct additional web searches. Update the report with substantial new findings. When you have exhausted all productive avenues, add <!-- RESEARCH_COMPLETE --> as the very last line." \
  --arg msg "Research iteration ${NEXT}/${MAX_ITERS}" \
  '{decision: "deny", reason: $reason, systemMessage: $msg}'
