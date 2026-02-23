# Deep Research Council - Implementation Plan

## Overview

A Claude Code plugin that orchestrates **deep research** across three AI coding CLIs in parallel: **Claude**, **Codex**, and **Gemini**. Each agent independently researches a topic using iterative loops (via hooks), then cross-pollinates findings, refines, and finally a synthesis agent consolidates everything into one report.

## Architecture

### Why the Stop Hook runs the subagents (not Claude directly)

Claude Code's Bash tool has a **10-minute timeout**. Deep research phases can take 20-60+ minutes.
The Stop hook can have a much longer timeout (we set 2 hours) and runs outside the Bash tool's
constraints. This is the same pattern used by the `review-loop` plugin (which runs Codex
synchronously inside its Stop hook with a 900-second timeout).

The tradeoff: during Phases 1-2, Claude's UI shows a spinner instead of live output.
Users can `tail -f research/<id>/progress.log` in another terminal to monitor progress.

### Flow Diagram

```
User: /deep-research "How do transformer attention mechanisms scale?"
        │
        ▼
┌──────────────────────────────────────────────────────────────┐
│  Main Claude Session                                         │
│                                                              │
│  Step 1: /deep-research command runs setup script            │
│          → creates workspace, state file, validates CLIs     │
│          → tells Claude: "Setup complete. Stop to begin."    │
│                                                              │
│  Step 2: Claude acknowledges and finishes its turn           │
│          → Stop hook fires automatically (this is how        │
│             Claude Code hooks work — they trigger when       │
│             Claude finishes responding, not when you         │
│             manually "stop")                                 │
│                                                              │
│  Step 3: orchestrator-stop-hook.sh takes over:               │
│     ┌─────────────────────────────────────────────────────┐  │
│     │  PHASE 1: Initial Research (3 parallel processes)   │  │
│     │  Hook launches all 3 CLI subagents as child procs:  │  │
│     │  ┌──────────┐ ┌──────────┐ ┌──────────┐            │  │
│     │  │ claude   │ │ codex    │ │ gemini   │            │  │
│     │  │ -p ...   │ │ exec ... │ │ ...      │            │  │
│     │  │ (Stop    │ │ (bash    │ │ (After   │            │  │
│     │  │  hook    │ │  wrapper │ │  Agent   │            │  │
│     │  │  loop)   │ │  loop)   │ │  hook)   │            │  │
│     │  └────┬─────┘ └────┬─────┘ └────┬─────┘            │  │
│     │       ▼            ▼            ▼                   │  │
│     │  claude-report codex-report gemini-report           │  │
│     │  Hook `wait`s for all 3 PIDs                        │  │
│     └─────────────────────────────────────────────────────┘  │
│     ┌─────────────────────────────────────────────────────┐  │
│     │  PHASE 2: Cross-Pollination Refinement (parallel)   │  │
│     │  Hook launches 3 more CLI subagents, each reading   │  │
│     │  all 3 reports and refining with NEW avenues         │  │
│     │  ┌──────────┐ ┌──────────┐ ┌──────────┐            │  │
│     │  │ Claude   │ │ Codex    │ │ Gemini   │            │  │
│     │  │ refine   │ │ refine   │ │ refine   │            │  │
│     │  └────┬─────┘ └────┬─────┘ └────┬─────┘            │  │
│     │       ▼            ▼            ▼                   │  │
│     │  claude-refined codex-refined gemini-refined        │  │
│     │  Hook `wait`s for all 3 PIDs                        │  │
│     └─────────────────────────────────────────────────────┘  │
│     Hook returns: {"decision":"block",                       │
│       "reason":"Synthesize the 3 refined reports..."}        │
│                                                              │
│  Step 4: Claude receives the synthesis prompt, reads all     │
│          3 refined reports, writes final-report.md           │
│                                                              │
│  Step 5: Claude finishes → Stop hook sees phase=synthesis,   │
│          verifies final-report.md exists → allows exit       │
└──────────────────────────────────────────────────────────────┘
        │
        ▼
  research/<id>/final-report.md
```

## Plugin Structure

```
research-council/
├── .claude-plugin/
│   └── plugin.json                    # Plugin metadata
├── commands/
│   ├── deep-research.md               # /deep-research slash command
│   └── cancel-research.md             # /cancel-research slash command
├── hooks/
│   ├── hooks.json                     # Main session Stop hook
│   └── orchestrator-stop-hook.sh      # Orchestration: run phases, check completion
├── scripts/
│   ├── setup-research.sh             # Validates CLIs, creates workspace and state
│   ├── run-research-phase.sh          # Launch 3 agents for initial research
│   ├── run-refinement-phase.sh        # Launch 3 agents for refinement
│   ├── claude-stop-hook.sh            # Stop hook for Claude subagent loop
│   ├── codex-wrapper.sh              # Bash wrapper loop for Codex subagent
│   └── gemini-afteragent-hook.sh      # AfterAgent hook for Gemini subagent loop
├── prompts/
│   ├── research-system.md             # Base research instructions
│   └── refinement-system.md           # Cross-pollination refinement instructions
├── plan.md
└── README.md
```

## Phase-by-Phase Flow

### Phase 0: Setup (`/deep-research <topic>`)

The `commands/deep-research.md` slash command:

1. Validates prerequisites (`claude`, `codex`, `gemini`, `jq` installed)
2. Generates a unique research ID: `YYYYMMDD-HHMMSS-<hex>`
3. Creates workspace: `research/<id>/`
4. Creates state file: `.claude/deep-research.local.md`

```yaml
---
active: true
phase: research
research_id: 20260222-143000-a1b2c3
topic: "How do transformer attention mechanisms scale?"
max_iterations: 10
started_at: "2026-02-22T14:30:00Z"
---
```

5. Tells Claude: "Research council activated. Acknowledge setup and finish your turn — the Stop hook will automatically launch all 3 research agents."

Note: The Stop hook fires whenever Claude "finishes responding" (i.e., completes its turn). This is the normal Claude Code hook lifecycle — Claude doesn't need to do anything special. It just finishes its response after setup, and the hook takes over.

### Phase 1: Initial Research (Stop Hook → Parallel)

Claude finishes its turn → `orchestrator-stop-hook.sh` fires automatically:

1. Reads state file, sees `phase: research`
2. Launches 3 subagent processes **in parallel**:
   - `scripts/claude-subagent.sh` (uses Claude CLI + Stop hook for looping)
   - `scripts/codex-wrapper.sh` (uses Codex CLI + bash loop)
   - `scripts/gemini-subagent.sh` (uses Gemini CLI + AfterAgent hook)
3. `wait` for all 3 PIDs
4. Validates that all 3 report files exist
5. Updates state: `phase: refinement`
6. Falls through to Phase 2 (within the same hook invocation)

### Phase 2: Cross-Pollination Refinement (Still in Stop Hook)

1. Launches 3 refinement processes **in parallel**:
   - Each agent receives: its own report + the other 2 reports
   - Each agent writes a refined report
2. `wait` for all 3 PIDs
3. Updates state: `phase: synthesis`
4. Returns to main Claude with:

```json
{
  "decision": "block",
  "reason": "All research phases complete. Read the 3 refined reports at research/<id>/ and synthesize into research/<id>/final-report.md. Structure it with: Executive Summary, Key Findings, Areas of Consensus, Areas of Disagreement, Recommendations for Further Research, and Sources.",
  "systemMessage": "Research Council: Phase 3/3 — Synthesis"
}
```

### Phase 3: Synthesis (Main Claude)

Main Claude:
1. Reads all 3 refined reports
2. Synthesizes into `research/<id>/final-report.md`
3. Stops → Stop hook sees `phase: synthesis`, checks for final report, allows exit

## Subagent Loop Mechanisms

### Claude Subagent (Stop Hook)

**How it works**: Claude Code's Stop hook can return `{"decision": "block", "reason": "..."}` to prevent exit and feed a new prompt back to Claude. This is the native loop mechanism.

**Implementation**: We launch `claude -p` with a `--settings` file that contains a Stop hook pointing to `claude-stop-hook.sh`.

```bash
# scripts/run-claude-research.sh (simplified)
SETTINGS_FILE="research/$ID/claude-settings.json"
cat > "$SETTINGS_FILE" << EOF
{
  "hooks": {
    "Stop": [{
      "hooks": [{
        "type": "command",
        "command": "$PLUGIN_ROOT/scripts/claude-stop-hook.sh",
        "timeout": 120
      }]
    }]
  }
}
EOF

claude -p \
  --model claude-opus-4-6 \
  --dangerously-skip-permissions \
  --settings "$SETTINGS_FILE" \
  --max-turns 200 \
  "$(cat prompts/research-system.md) TOPIC: $TOPIC REPORT: $REPORT_PATH"
```

**`claude-stop-hook.sh`** logic:
```
1. Read state file (research/<id>/claude-state.txt) for iteration count
2. If report contains "<!-- RESEARCH_COMPLETE -->" → exit 0 (allow stop)
3. If iteration >= MAX_ITERATIONS → exit 0 (allow stop)
4. Increment iteration
5. Output: {"decision": "block", "reason": "Continue researching. Read your report, identify gaps, deepen analysis. Add <!-- RESEARCH_COMPLETE --> when truly comprehensive.", "systemMessage": "Research iteration N/MAX"}
```

**Environment variables passed to hook**:
- `RESEARCH_REPORT_PATH` - path to the report file
- `RESEARCH_STATE_PATH` - path to iteration state file
- `RESEARCH_MAX_ITERS` - maximum iterations (default: 10)

### Codex Subagent (Bash Wrapper Loop)

**Why a wrapper**: Codex CLI does NOT have Stop hooks (as of Feb 2026). OpenAI has confirmed they're designing a hook system but it hasn't shipped. The community workaround is an external bash loop.

**Implementation**: `scripts/codex-wrapper.sh`

```bash
#!/bin/bash
# codex-wrapper.sh <topic> <report_path> <max_iterations>

TOPIC="$1"
REPORT="$2"
MAX_ITERS="${3:-10}"

# Initial prompt
PROMPT="You are a deep research agent. Conduct thorough research on: $TOPIC
Write findings to $REPORT with: Executive Summary, Key Findings, Sources, Areas for Further Investigation.
Use web search extensively. When comprehensive, add <!-- RESEARCH_COMPLETE --> at the end."

# First iteration
codex exec \
  --model gpt-5.3-codex \
  -c model_reasoning_effort="xhigh" \
  --full-auto \
  --skip-git-repo-check \
  "$PROMPT"

# Subsequent iterations (resume to preserve context)
for i in $(seq 2 $MAX_ITERS); do
  if [ -f "$REPORT" ] && grep -q "RESEARCH_COMPLETE" "$REPORT"; then
    echo "Codex research complete after $((i-1)) iterations"
    break
  fi

  codex exec resume --last \
    "Read your report at $REPORT. Identify gaps and unexplored angles. \
     Deepen analysis with more web searches. Update the report. \
     Add <!-- RESEARCH_COMPLETE --> when truly comprehensive."
done
```

**Key Codex flags**:
- `--model gpt-5.3-codex`: Latest flagship Codex model (strongest reasoning + 25% faster)
- `-c model_reasoning_effort="xhigh"`: Maximum reasoning depth (supported by gpt-5.3-codex, gpt-5.2-codex, gpt-5.2, gpt-5.1-codex-max)
- `--full-auto`: Workspace-write sandbox + auto-approvals
- `--skip-git-repo-check`: Research workspace may not be a git repo
- `codex exec resume --last`: Preserves conversation context between iterations

### Gemini Subagent (AfterAgent Hook)

**How it works**: Gemini CLI's `AfterAgent` hook fires after the agent loop completes. Returning `{"decision": "deny", "reason": "..."}` rejects the response and forces a retry with the reason as the new prompt.

**Implementation**: We create a temporary `.gemini/settings.json` in a subdirectory workspace, then launch Gemini from there.

```bash
# scripts/run-gemini-research.sh (simplified)
WORKSPACE="research/$ID/gemini-workspace"
mkdir -p "$WORKSPACE/.gemini"

cat > "$WORKSPACE/.gemini/settings.json" << EOF
{
  "hooksConfig": {"enabled": true},
  "hooks": {
    "AfterAgent": [{
      "matcher": "*",
      "hooks": [{
        "name": "research-loop",
        "type": "command",
        "command": "$PLUGIN_ROOT/scripts/gemini-afteragent-hook.sh",
        "timeout": 30000
      }]
    }]
  }
}
EOF

# Also create a GEMINI.md with research instructions
cp prompts/research-system.md "$WORKSPACE/GEMINI.md"

cd "$WORKSPACE"
RESEARCH_REPORT_PATH="$REPORT_PATH" \
RESEARCH_STATE_PATH="$STATE_PATH" \
RESEARCH_MAX_ITERS="$MAX_ITERS" \
  gemini --model gemini-2.5-pro --approval-mode=yolo \
    "Research: $TOPIC. Write report to $REPORT_PATH."
```

**`gemini-afteragent-hook.sh`** logic:
```
1. Read JSON from stdin (includes prompt_response)
2. Read state file for iteration count
3. If report contains "<!-- RESEARCH_COMPLETE -->" → output {"decision": "allow"}
4. If iteration >= MAX_ITERATIONS → output {"decision": "allow"}
5. Increment iteration
6. Output: {"decision": "deny", "reason": "Continue researching...", "systemMessage": "Research iteration N/MAX"}
```

**Key differences from Claude's hook**:
- Uses `"decision": "deny"` (not `"block"`)
- The `reason` field becomes the new prompt (same behavior as Claude)
- Can optionally set `hookSpecificOutput.clearContext: true` to reset conversation (we keep context for research continuity)

## Research Prompts

### Initial Research Prompt (`prompts/research-system.md`)

```markdown
You are a deep research agent conducting comprehensive investigation on a topic.

## Your Approach
1. **Breadth first**: Identify all major subtopics and angles
2. **Depth second**: Deep-dive into each subtopic with web searches and analysis
3. **Cross-reference**: Verify claims across multiple sources
4. **Synthesize**: Connect findings into a coherent narrative

## Report Structure
Write your report as markdown with these sections:
- **Executive Summary**: 2-3 paragraph overview
- **Key Findings**: Detailed sections with evidence and citations
- **Methodology**: What sources and approaches you used
- **Open Questions**: What remains uncertain or debated
- **Sources**: URLs and references

## Rules
- Use web search extensively - do NOT rely solely on training data
- Cite sources with URLs where possible
- Be honest about uncertainty and conflicting evidence
- Go deep - surface-level summaries are not sufficient
- When you believe your research is truly comprehensive, add <!-- RESEARCH_COMPLETE --> as the very last line of your report
- Do NOT add this marker prematurely - only when you've exhausted productive research avenues
```

### Refinement Prompt (`prompts/refinement-system.md`)

```markdown
You previously conducted deep research and produced a report. Two other AI agents
independently researched the same topic. You now have access to all three reports.

## Your Task
1. Read YOUR report carefully
2. Read the OTHER TWO reports
3. Identify:
   - NEW research directions inspired by their findings that you didn't explore
   - Contradictions between reports that need resolution via additional research
   - Areas where your report lacks depth compared to theirs
4. Conduct ADDITIONAL research (web searches) on the new avenues
5. Write a REFINED version of your report that is strictly better than your original

## Critical Rule
Do NOT simply copy from other reports. Use them as SPRINGBOARDS for NEW investigation.
The goal is to explore territory that NONE of the three reports adequately covered,
inspired by the unique perspectives each agent brought.

## Files
- Your original report: {own_report}
- Other report 1: {report_2}
- Other report 2: {report_3}
- Write refined report to: {refined_report}

When your refined report is comprehensive, add <!-- RESEARCH_COMPLETE --> at the end.
```

### Synthesis Prompt (returned by Stop Hook to main Claude)

```
All research phases are complete. Three AI agents (Claude, Codex, Gemini) independently
researched the topic, then each refined their findings after reviewing the others' work.

Read all 3 refined reports:
- research/<id>/claude-refined.md
- research/<id>/codex-refined.md
- research/<id>/gemini-refined.md

Synthesize into: research/<id>/final-report.md

Structure:
1. Executive Summary
2. Key Findings (organized by theme, not by source agent)
3. Areas of Strong Consensus (all 3 agents agree)
4. Areas of Disagreement or Nuance (agents differed)
5. Novel Insights (unique findings from the cross-pollination round)
6. Remaining Open Questions
7. Comprehensive Source List (deduplicated across all reports)
8. Methodology Note (describe the multi-agent research process)
```

## Model Configuration

### Available Codex Models (verified Feb 2026)

Source: [Codex Models](https://developers.openai.com/codex/models/)

| Model | Description | xhigh reasoning? |
|-------|-------------|-------------------|
| `gpt-5.3-codex` | Latest flagship. 25% faster than 5.2. Strongest reasoning. | Yes |
| `gpt-5.3-codex-spark` | Near-instant real-time coding. Pro only, research preview. | ? |
| `gpt-5.2-codex` | Previous flagship. `xhigh` is default reasoning effort. | Yes |
| `gpt-5.2` | General agentic model. `xhigh` is default reasoning effort. | Yes |
| `gpt-5.1-codex-max` | Long-horizon tasks via "compaction" across context windows. | Yes |
| `gpt-5.1-codex` | Long-running agentic coding. | No |
| `gpt-5.1` | General coding and agentic work. | No |
| `gpt-5-codex` | Original GPT-5 coding tuned. | No |
| `gpt-5-codex-mini` | Cost-effective smaller variant. | No |
| `gpt-5` | Original GPT-5 reasoning model. | No |

Reasoning effort levels: `minimal`, `low`, `medium` (default), `high`, `xhigh`.
The `xhigh` level is supported by `gpt-5.1-codex-max`, `gpt-5.2`, `gpt-5.2-codex`, `gpt-5.3-codex`.

Source: [Configuration Reference](https://developers.openai.com/codex/config-reference/), [Config Sample](https://developers.openai.com/codex/config-sample/)

### Production (Maximum Depth)

| Agent | Model | Reasoning Config | CLI Command |
|-------|-------|-----------------|-------------|
| Claude | `claude-opus-4-6` | effort: max | `claude -p --model claude-opus-4-6` + env `CLAUDE_CODE_EFFORT_LEVEL=max` |
| Codex | `gpt-5.3-codex` | reasoning_effort: xhigh | `codex exec --model gpt-5.3-codex -c model_reasoning_effort="xhigh"` |
| Gemini | `gemini-2.5-pro` | thinkingBudget: 24576 | `gemini --model gemini-2.5-pro` + settings.json thinkingConfig |

### Testing (Fast & Cheap)

| Agent | Model | CLI Command |
|-------|-------|-------------|
| Claude | `claude-haiku-4-5-20251001` | `claude -p --model claude-haiku-4-5-20251001` |
| Codex | `gpt-5.1-codex-mini` | `codex exec --model gpt-5.1-codex-mini -c model_reasoning_effort="low"` |
| Gemini | `gemini-2.5-flash-lite` | `gemini --model gemini-2.5-flash-lite` |

The `/deep-research` command should accept a `--test` flag that switches to cheap models and reduces max iterations to 2.

### API Keys Required

- `ANTHROPIC_API_KEY` (for Claude subagent — or existing Claude Code auth)
- `OPENAI_API_KEY` or Codex auth (for Codex subagent)
- `GEMINI_API_KEY` or Google OAuth (for Gemini subagent)

## Main Session Stop Hook Design

### `hooks/hooks.json`

```json
{
  "description": "Deep Research Council orchestration hook",
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/hooks/orchestrator-stop-hook.sh",
            "timeout": 7200,
            "statusMessage": "Research Council: running..."
          }
        ]
      }
    ]
  }
}
```

Note: 7200 second (2 hour) timeout to allow for extended research phases.

### `orchestrator-stop-hook.sh` Logic

```
1. Read stdin (hook input JSON)
2. Check for state file .claude/deep-research.local.md
   - Not found → exit 0 (allow normal exit, no active research)
3. Parse phase from state file

case $PHASE in
  "research")
    - Log: "Starting Phase 1: Initial Research"
    - Launch 3 research subagents in parallel (background processes)
    - Wait for all to complete
    - Validate all 3 reports exist
    - Update state: phase=refinement
    - Fall through to refinement phase
    ;;

  "refinement")  [also reached by fall-through from research]
    - Log: "Starting Phase 2: Cross-Pollination Refinement"
    - Launch 3 refinement subagents in parallel
    - Wait for all to complete
    - Validate all 3 refined reports exist
    - Update state: phase=synthesis
    - Return: {"decision": "block", "reason": "<synthesis prompt>", "systemMessage": "Research Council: Phase 3/3 — Synthesis"}
    ;;

  "synthesis")
    - Check if research/<id>/final-report.md exists and is non-empty
    - If yes: clean up state file, return exit 0 (allow exit)
    - If no: return {"decision": "block", "reason": "Please write the synthesis report"}
    ;;
esac
```

### Progress Logging

Since the Stop hook blocks Claude's UI with a spinner during Phases 1-2, we log progress to a file that users can tail:

```
research/<id>/progress.log
```

Each subagent wrapper logs to this file:
```
[2026-02-22T14:31:00Z] Phase 1: Claude research starting (iteration 1/10)
[2026-02-22T14:32:15Z] Phase 1: Codex research starting (iteration 1/10)
[2026-02-22T14:32:16Z] Phase 1: Gemini research starting (iteration 1/10)
[2026-02-22T14:35:00Z] Phase 1: Claude iteration 2/10
[2026-02-22T14:38:00Z] Phase 1: Codex iteration 2/10
...
[2026-02-22T14:45:00Z] Phase 1: All agents complete
[2026-02-22T14:45:01Z] Phase 2: Starting refinement...
```

The `/deep-research` command prompt will tell the user: "Tail progress with: `tail -f research/<id>/progress.log`"

## Testing Strategy

### 1. Unit Test: Individual Hook Scripts

Test each hook script in isolation:

```bash
# Test claude-stop-hook.sh
echo '{"session_id":"test","stop_hook_active":false}' | \
  RESEARCH_REPORT_PATH=/tmp/test-report.md \
  RESEARCH_STATE_PATH=/tmp/test-state.txt \
  RESEARCH_MAX_ITERS=3 \
  ./scripts/claude-stop-hook.sh

# Verify output is valid JSON with decision field
```

### 2. Unit Test: Subagent Wrappers with Cheap Models

```bash
# Test codex wrapper with 2 iterations, cheap model
./scripts/codex-wrapper.sh \
  "What is 2+2? Explain in detail." \
  /tmp/test-codex-report.md \
  2 \
  "gpt-4.1-mini" \
  "low"

# Test claude research with cheap model
CLAUDE_MODEL=claude-haiku-4-5-20251001 \
  ./scripts/run-claude-research.sh \
  "What is 2+2?" \
  /tmp/test-claude-report.md \
  2

# Test gemini research with cheap model
GEMINI_MODEL=gemini-2.5-flash-lite \
  ./scripts/run-gemini-research.sh \
  "What is 2+2?" \
  /tmp/test-gemini-report.md \
  2
```

### 3. Integration Test: Full Pipeline (Cheap Models)

```bash
# /deep-research --test "What is the history of the Python programming language?"
```

The `--test` flag:
- Uses cheap models (haiku, gpt-4.1-mini, flash-lite)
- Limits to 2 iterations per agent per phase
- Reduces thinking budgets
- Total cost should be < $1

### 4. Smoke Test: Verify CLI Availability

```bash
# Run at setup time
command -v claude || echo "MISSING: claude"
command -v codex || echo "MISSING: codex"
command -v gemini || echo "MISSING: gemini"
command -v jq || echo "MISSING: jq"
```

## Implementation Steps

### Step 1: Plugin Skeleton
- Create `.claude-plugin/plugin.json`
- Create `commands/deep-research.md` (basic structure)
- Create `commands/cancel-research.md`

### Step 2: Subagent Hook Scripts
- Implement `scripts/claude-stop-hook.sh` (Claude loop via Stop hook)
- Implement `scripts/codex-wrapper.sh` (Codex loop via bash wrapper)
- Implement `scripts/gemini-afteragent-hook.sh` (Gemini loop via AfterAgent)
- Unit test each in isolation

### Step 3: Phase Runner Scripts
- Implement `scripts/run-research-phase.sh` (launch 3 agents, wait)
- Implement `scripts/run-refinement-phase.sh` (launch 3 agents with cross-reports)
- Test with cheap models

### Step 4: Main Orchestrator Hook
- Implement `hooks/hooks.json`
- Implement `hooks/orchestrator-stop-hook.sh` (phase state machine)
- Test full pipeline with `--test` flag

### Step 5: Research Prompts
- Write `prompts/research-system.md`
- Write `prompts/refinement-system.md`
- Tune prompts based on test results

### Step 6: Polish
- Error handling (agent failures, missing reports, timeouts)
- Progress logging
- `--test` flag implementation
- `cancel-research` command
- README documentation

## Key Tradeoffs & Decisions

### 1. Why does the Stop hook launch the subagents (instead of Claude running them directly)?

Claude Code's Bash tool has a **10-minute max timeout**. Deep research phases can easily take 20-60+ minutes (3 agents x multiple iterations each). The Stop hook runs as a shell process with its own timeout (we set 2 hours), outside the Bash tool's constraints. This is the same pattern the `review-loop` plugin uses to run Codex synchronously within its Stop hook.

The Stop hook fires automatically whenever Claude finishes responding — it's not something the user or Claude "triggers" manually. So the flow is: the `/deep-research` command sets up state, Claude acknowledges setup and finishes its turn, the Stop hook sees the state file and takes over to run all the research phases, then returns control to Claude with the synthesis prompt.

### 2. Why bash wrapper for Codex instead of hooks?

Codex CLI does NOT have Stop hooks or any equivalent lifecycle hook system as of Feb 2026. OpenAI is actively designing one but it hasn't shipped. The bash wrapper with `codex exec resume --last` is the only reliable approach. This preserves conversation context between iterations.

### 3. Why a subdirectory workspace for Gemini?

Gemini's AfterAgent hooks are configured in `settings.json`. To avoid polluting the user's project-level or global Gemini config, we create an isolated workspace subdirectory with its own `.gemini/settings.json`. The hook script paths are absolute, so it can still read/write to the main research directory.

### 4. Why `<!-- RESEARCH_COMPLETE -->` as the completion marker?

- It's an HTML comment, so it's invisible in rendered markdown
- It's unlikely to appear naturally in research content
- It's easy to grep for programmatically
- Each agent explicitly decides when it's satisfied (not a fixed iteration count)

### 5. Why both phases run in a single Stop hook invocation?

If the Stop hook returned after Phase 1 with a "block" decision, Claude would need to do something (like run Phase 2 scripts) before stopping again. But we want the orchestrator hook to handle both phases autonomously without requiring Claude to take action between them. By running both phases in one hook invocation, we avoid the complexity of multi-phase stop-hook handoffs and ensure the refinement phase always runs.

### 6. Context preservation vs. fresh starts

- **Claude subagent**: Stop hook preserves full conversation context between iterations (Claude sees its prior work)
- **Codex subagent**: `codex exec resume --last` preserves context
- **Gemini subagent**: AfterAgent hook without `clearContext` preserves context
- **Refinement round**: Fresh start (each agent reads reports from files, not conversation history)

## Error Handling

- If a subagent fails (non-zero exit), log the error and continue with remaining agents
- If ALL agents in a phase fail, clean up state file and return error to main Claude
- If an agent produces no report file, skip it in refinement (degrade gracefully)
- Use `trap` in all scripts for cleanup on SIGINT/SIGTERM
- The orchestrator hook defaults to `exit 0` (allow exit) on any unexpected error — never trap the user
