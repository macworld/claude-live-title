# live-title

Claude Code plugin: auto-generate meaningful session titles in real-time. The plugin is named `live-title` (renamed from `claude-live-title` in 2.0, because `claude-` names are reserved); the repo and marketplace keep the old name.

## Dev Conventions

- Hook scripts are bash, must be compatible with Linux and macOS
- Shared logic lives in hooks/lib/common.sh, entry scripts stay thin
- Zero runtime dependencies: only bash + jq + `claude -p`
- Hooks must never block the user: anything that calls the model runs with `async: true`. The one sync hook (`apply-title.sh`) makes no model call, finishes in milliseconds, prints only its JSON reply and always exits 0
- State, debug log, cooldown markers and the prompt temp file live in `${CLAUDE_PLUGIN_DATA}`, never in `/tmp`
- Config location: ${CLAUDE_PLUGIN_DATA}/config.json (the old ~/.claude/plugins/claude-live-title/config.json is migrated on first load)

## Testing

```bash
# All suites (stubbed `claude`, throwaway data dir, no network)
for t in tests/test-*.sh; do bash "$t"; done

# Fixtures against the real model (SAMPLES=4 runs each 4 times; use it after prompt changes)
RUN_LIVE=1 bash tests/test-fixtures.sh

# Regenerate the prompt snapshot after an intended prompt change
UPDATE_SNAPSHOT=1 bash tests/test-prompt-snapshot.sh
```

Tests must not touch the real config: set `CLAUDE_PLUGIN_DATA` (and `HOME` when legacy migration could kick in) to a temp dir.

Manual test with a mock transcript:

```bash
echo '{"type":"user","message":{"content":"help me fix the login bug"}}' > /tmp/test-transcript.jsonl
echo '{"session_id":"test-123","transcript_path":"/tmp/test-transcript.jsonl"}' \
  | CLAUDE_PLUGIN_DATA=/tmp/clt-data bash hooks/stop-title.sh
tail -1 /tmp/test-transcript.jsonl
```

## File Structure

- PLAN.md: planning doc, not committed
- docs/superpowers/: design process docs, not committed
