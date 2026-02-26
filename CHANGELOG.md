# Deepsearch Vibeproxy Adaptation

## Date
2026-02-26

## Changes

### 1. Model Update: GLM-4.7 Replacement (2026-02-26)
- **Replaced Claude**: Claude slot now uses `vibeproxy/glm-4.7`
- **Reasoning**: Better reasoning-to-cost ratio than Claude Opus
- **Other agents unchanged**: Codex and Gemini remain on their vibeproxy models

### 2. Plugin Identity
- **Name changed**: `research-council` → `deepsearch`
- **Version**: `0.1.0-vibeproxy`
- **Repository**: Still points to upstream (hamelsmu/research-council)

### 2. Model Routing (Vibeproxy Integration)

All model names have been updated to use vibeproxy aliases for unified access:

| Phase | Original | Updated |
|-------|----------|----------|
| **Production** | | |
| - Claude | `claude-opus-4-6` | `vibeproxy/claude-opus-4-6` |
| - Codex | `gpt-5.3-codex` | `vibeproxy/gpt-5.3-codex` |
| - Gemini | `gemini-2.5-pro` | `vibeproxy/gemini-3-pro-high` |
| **Test Mode** | | |
| - Claude | `claude-haiku-4-5-20251001` | `vibeproxy/claude-opus-4-6` |
| - Codex | `gpt-5.1-codex-mini` | `vibeproxy/gpt-5.3-codex` |
| - Gemini | `gemini-2.5-flash-lite` | `vibeproxy/gemini-3-pro-high` |

### 3. File Changes
- `scripts/setup-research.sh`: Lines 77-84 — Model configuration updated
- `.claude-plugin/plugin.json`: Name, version, description updated
- `README.md`: Documentation updated with vibeproxy references

### 4. Benefits of Vibeproxy Integration
- **Unified model access**: All 3 providers route through single proxy
- **Cost management**: Centralized API key and usage tracking
- **Model consistency**: Vibeproxy ensures model aliases resolve correctly
- **Future-proof**: Easy to switch providers or models without code changes

### 5. Installation for Use
This project is hosted at:
```
/Users/anton/.openclaw/workspace-dev/deepsearch
```

To use in Claude Code:
```bash
claude --plugin-dir /Users/anton/.openclaw/workspace-dev/deepsearch
```

## Notes
- No changes to core orchestration logic (cross-pollination remains intact)
- Loop mechanisms (Claude Stop hook, Codex wrapper, Gemini AfterAgent hook) unchanged
- Only model string references modified — all other functionality preserved
