---
description: "Cancel an active deep research session"
allowed-tools:
  - Bash(test -f .claude/deep-research.local.md *)
  - Bash(rm -f .claude/deep-research.local.md)
  - Bash(kill *)
  - Read
---

Check if a research session is active:

```bash
test -f .claude/deep-research.local.md && echo "ACTIVE" || echo "NONE"
```

If active, read `.claude/deep-research.local.md` to get the current phase and research ID.

Then remove the state file to cancel:

```bash
rm -f .claude/deep-research.local.md
```

Report: "Research council cancelled (was at phase: X, research ID: Y)"

If no research session was active, report: "No active research session found."
