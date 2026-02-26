#!/usr/bin/env bash
set -euo pipefail

# Deep Research Council — Setup Script
# Validates prerequisites, creates workspace, and prepares the research lifecycle.

# ── Parse arguments ───────────────────────────────────────────────────────
TEST_MODE=false
ARGS=()

while [[ $# -gt 0 ]]; do
  case $1 in
    --test)
      TEST_MODE=true
      shift
      ;;
    --help|-h)
      cat << 'HELP'
Usage: /deep-research [--test] <research topic>

Launches deep research across Claude, Codex, and Gemini in parallel.

Phases:
  1. Three agents independently research the topic (with iterative loops)
  2. Each agent reads all 3 reports and refines with new avenues
  3. Main Claude synthesizes everything into a final report

Options:
  --test    Use cheap/fast models and 2 iterations (for testing the pipeline)

Prerequisites:
  - claude CLI (Claude Code)
  - codex CLI (OpenAI Codex)
  - gemini CLI (Google Gemini)
  - jq (JSON processor)

Example:
  /deep-research How do transformer attention mechanisms scale with sequence length?
  /deep-research --test What is the history of the Python programming language?
HELP
      exit 0
      ;;
    *)
      ARGS+=("$1")
      shift
      ;;
  esac
done

TOPIC="${ARGS[*]:-}"

if [ -z "$TOPIC" ]; then
  echo "Error: No research topic provided."
  echo "Usage: /deep-research [--test] <research topic>"
  echo ""
  echo "Example: /deep-research How do LLMs handle long-context reasoning?"
  exit 1
fi

# ── Check for existing session ────────────────────────────────────────────
if [ -f ".claude/deep-research.local.md" ]; then
  echo "Error: A research session is already active."
  echo "Use /cancel-research to abort it first, or wait for it to complete."
  exit 1
fi

# ── Check dependencies ───────────────────────────────────────────────────
MISSING=()

if ! command -v claude &>/dev/null; then
  MISSING+=("claude (Claude Code CLI — https://docs.anthropic.com/en/docs/claude-code)")
fi
if ! command -v codex &>/dev/null; then
  MISSING+=("codex (OpenAI Codex CLI — npm install -g @openai/codex)")
fi
if ! command -v gemini &>/dev/null; then
  MISSING+=("gemini (Google Gemini CLI — npm install -g @google/gemini-cli)")
fi
if ! command -v jq &>/dev/null; then
  MISSING+=("jq (JSON processor — brew install jq)")
fi

if [ ${#MISSING[@]} -gt 0 ]; then
  echo "Error: Missing required CLI tools:"
  echo ""
  for dep in "${MISSING[@]}"; do
    echo "  ✗ $dep"
  done
  echo ""
  echo "Install the missing tools and try again."
  exit 1
fi

# ── Verify CLI auth (best-effort checks) ─────────────────────────────────
WARNINGS=()

# Check Codex auth
if ! codex --version &>/dev/null 2>&1; then
  WARNINGS+=("codex may not be authenticated — run 'codex login' if research fails")
fi

# Check Gemini auth
if [ -z "${GEMINI_API_KEY:-}" ] && [ -z "${GOOGLE_API_KEY:-}" ]; then
  # Check if OAuth is configured
  if [ ! -f "${HOME}/.gemini/oauth_creds.json" ] && [ ! -f "${HOME}/.config/gemini/oauth_creds.json" ]; then
    WARNINGS+=("gemini may not be authenticated — run 'gemini' once to set up auth, or set GEMINI_API_KEY")
  fi
fi

if [ ${#WARNINGS[@]} -gt 0 ]; then
  echo "Warnings:"
  for w in "${WARNINGS[@]}"; do
    echo "  ⚠ $w"
  done
  echo ""
fi

# ── Generate unique research ID ──────────────────────────────────────────
if command -v openssl &>/dev/null; then
  RAND_HEX=$(openssl rand -hex 3)
else
  RAND_HEX=$(head -c 3 /dev/urandom | od -An -tx1 | tr -d ' \n')
fi
RESEARCH_ID="$(date +%Y%m%d-%H%M%S)-${RAND_HEX}"

# ── Determine model configuration ────────────────────────────────────────
# Vibeproxy aliases for enhanced model routing
if [ "$TEST_MODE" = true ]; then
  MAX_ITERS=2
  CLAUDE_MODEL="vibeproxy/glm-4.7"
  CODEX_MODEL="vibeproxy/gpt-5.3-codex"
  CODEX_REASONING="xhigh"
  GEMINI_MODEL="vibeproxy/gemini-3-pro-high"
  MODE_LABEL="TEST MODE (cheap models, 2 iterations)"
else
  MAX_ITERS=10
  CLAUDE_MODEL="vibeproxy/glm-4.7"
  CODEX_MODEL="vibeproxy/gpt-5.3-codex"
  CODEX_REASONING="xhigh"
  GEMINI_MODEL="vibeproxy/gemini-3-pro-high"
  MODE_LABEL="PRODUCTION (maximum reasoning depth)"
fi

# ── Create workspace ─────────────────────────────────────────────────────
WORKSPACE="research/${RESEARCH_ID}"
mkdir -p "$WORKSPACE" .claude

# ── Create state file ────────────────────────────────────────────────────
cat > .claude/deep-research.local.md << STATE_EOF
---
active: true
phase: research
research_id: ${RESEARCH_ID}
test_mode: ${TEST_MODE}
max_iterations: ${MAX_ITERS}
claude_model: ${CLAUDE_MODEL}
codex_model: ${CODEX_MODEL}
codex_reasoning: ${CODEX_REASONING}
gemini_model: ${GEMINI_MODEL}
started_at: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
---

${TOPIC}
STATE_EOF

# ── Report success ───────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  Deep Research Council activated"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "  Research ID:  ${RESEARCH_ID}"
echo "  Mode:         ${MODE_LABEL}"
echo "  Topic:        ${TOPIC}"
echo ""
echo "  Agents:"
echo "    Claude  →  ${CLAUDE_MODEL}"
echo "    Codex   →  ${CODEX_MODEL} (reasoning: ${CODEX_REASONING})"
echo "    Gemini  →  ${GEMINI_MODEL}"
echo ""
echo "  Max iterations per agent: ${MAX_ITERS}"
echo "  Workspace: ${WORKSPACE}/"
echo ""
echo "  Monitor progress in another terminal:"
echo "    tail -f ${WORKSPACE}/progress.log"
echo ""
echo "  Cancel with: /cancel-research"
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo ""
