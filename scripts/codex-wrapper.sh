#!/usr/bin/env bash
# Codex Subagent Wrapper — runs Codex in a bash loop since Codex lacks hooks
#
# Usage: codex-wrapper.sh <topic> <report_path> <max_iterations> <model> <reasoning_effort> <progress_log>

set -uo pipefail

TOPIC="$1"
REPORT="$2"
MAX_ITERS="${3:-10}"
MODEL="${4:-gpt-5.3-codex}"
REASONING="${5:-xhigh}"
PROGRESS_LOG="${6:-/dev/null}"

log() {
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] Codex: $*" >> "$PROGRESS_LOG"
}

REPORT_ABS="$(cd "$(dirname "$REPORT")" && pwd)/$(basename "$REPORT")"

# Build the initial research prompt
read -r -d '' INITIAL_PROMPT << PROMPT_EOF || true
You are a deep research agent. Conduct thorough, comprehensive research on the following topic:

${TOPIC}

## Instructions

1. Use web search extensively to find current, authoritative information
2. Write your findings as a well-structured markdown report to: ${REPORT_ABS}
3. Include: Executive Summary, Key Findings (with citations), Methodology, Open Questions, Sources
4. Go deep — surface-level summaries are not acceptable
5. When your research is truly comprehensive, add this marker as the VERY LAST LINE:
   <!-- RESEARCH_COMPLETE -->
6. Do NOT add the marker prematurely — only when you have exhausted productive research avenues
PROMPT_EOF

# Build the continuation prompt
read -r -d '' CONTINUE_PROMPT << PROMPT_EOF || true
Continue your deep research on: ${TOPIC}

Read your current report at ${REPORT_ABS}. Identify:
- Gaps in coverage that need filling
- Angles you haven't explored yet
- Claims that need better evidence or more sources
- Areas where you were shallow and should go deeper

Conduct additional web searches and update the report with substantial new content.
When truly comprehensive, add <!-- RESEARCH_COMPLETE --> as the very last line.
PROMPT_EOF

log "Starting research (model: ${MODEL}, reasoning: ${REASONING}, max_iters: ${MAX_ITERS})"

# First iteration
log "Iteration 1/${MAX_ITERS}"
codex exec \
  --model "$MODEL" \
  -c model_reasoning_effort="$REASONING" \
  --full-auto \
  --skip-git-repo-check \
  "$INITIAL_PROMPT" 2>>"$PROGRESS_LOG" || {
    log "ERROR: Codex iteration 1 failed (exit $?)"
  }

# Subsequent iterations
for i in $(seq 2 "$MAX_ITERS"); do
  # Check completion
  if [ -f "$REPORT" ] && grep -q "RESEARCH_COMPLETE" "$REPORT" 2>/dev/null; then
    log "Research complete after $((i-1)) iterations"
    break
  fi

  log "Iteration ${i}/${MAX_ITERS}"
  codex exec resume --last \
    "$CONTINUE_PROMPT" 2>>"$PROGRESS_LOG" || {
      log "ERROR: Codex iteration ${i} failed (exit $?)"
    }
done

# Final check
if [ -f "$REPORT" ]; then
  log "Report written to ${REPORT} ($(wc -l < "$REPORT") lines)"
else
  log "WARNING: No report file produced at ${REPORT}"
fi
