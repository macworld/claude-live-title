# claude-live-title

Claude Code plugin: auto-generate meaningful session titles in real-time.

## Dev Conventions

- Hook scripts are bash, must be compatible with Linux and macOS
- Shared logic lives in hooks/lib/common.sh, entry scripts stay thin
- Zero runtime dependencies: only bash + jq + `claude -p`
- All hooks must use `async: true`, never block the user
- Config location: ${CLAUDE_PLUGIN_DATA}/config.json (fallback: ~/.claude/plugins/claude-live-title/config.json)

## Testing

Manual test with mock transcript:

```bash
# Create test transcript
echo '{"type":"user","message":{"content":"help me fix the login bug"}}' > /tmp/test-transcript.jsonl

# Test live hook
echo '{"session_id":"test-123","transcript_path":"/tmp/test-transcript.jsonl"}' | bash hooks/live-title.sh

# Check result
tail -1 /tmp/test-transcript.jsonl
```

## File Structure

- PLAN.md: planning doc, not committed
- docs/superpowers/: design process docs, not committed
