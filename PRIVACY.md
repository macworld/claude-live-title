# Privacy Policy

**live-title** (formerly claude-live-title) is an open-source Claude Code plugin that runs entirely on your local machine.

## Data Collection

This plugin does **not** collect, store, or transmit any personal data or usage analytics.

## How It Works

- The plugin reads your local session transcript file to extract conversation messages.
- It calls `claude -p` (Anthropic's CLI) locally to generate a short title from a sample of your messages and an excerpt of Claude's latest reply. The call runs with `--no-session-persistence`, so it is not saved as a session.
- The generated title is written back to your local session transcript file as a `custom-title` entry.
- A local configuration file may be stored in the plugin's data directory (`~/.claude/plugins/data/live-title-*/config.json`) containing your preferences (language, throttle settings, etc.).

## Third-Party Services

This plugin does **not** communicate with any third-party services. The only external call is to `claude -p`, which is Anthropic's own CLI tool and is subject to [Anthropic's Privacy Policy](https://www.anthropic.com/privacy).

## Local Files

All files live in the plugin's data directory (`~/.claude/plugins/data/live-title-*/`):

- `sessions/` — one small state file per session, named by a SHA-256 hash of the session ID. It holds the titles generated for that session, timestamps and a message count, no conversation content. Files older than 30 days are deleted automatically.
- `cooldown-until`, `lean-flags-unsupported` — timestamps that pause title generation after errors.
- `debug.log` — only when `debug` is turned on. It contains excerpts of your conversations, is readable only by your user account, and is rotated at 1 MB.

The prompt for each title is written to a temporary file in the same directory (mode 600) and deleted right after the call.

## Contact

If you have questions about this privacy policy, please open an issue at [github.com/macworld/claude-live-title](https://github.com/macworld/claude-live-title/issues).
