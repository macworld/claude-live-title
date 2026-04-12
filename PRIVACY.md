# Privacy Policy

**claude-live-title** is an open-source Claude Code plugin that runs entirely on your local machine.

## Data Collection

This plugin does **not** collect, store, or transmit any personal data or usage analytics.

## How It Works

- The plugin reads your local session transcript file to extract conversation messages.
- It calls `claude -p` (Anthropic's CLI) locally to generate a short title from a sample of your messages.
- The generated title is written back to your local session transcript file as a `custom-title` entry.
- A local configuration file may be stored at `~/.claude/plugins/data/claude-live-title/config.json` containing your preferences (language, throttle settings, etc.).

## Third-Party Services

This plugin does **not** communicate with any third-party services. The only external call is to `claude -p`, which is Anthropic's own CLI tool and is subject to [Anthropic's Privacy Policy](https://www.anthropic.com/privacy).

## Local Files

The plugin creates temporary state files in your system's temp directory (`/tmp/` or `$TMPDIR`) for throttling and lock management. These files contain only timestamps and session identifiers (SHA-256 hashed), no conversation content.

## Contact

If you have questions about this privacy policy, please open an issue at [github.com/macworld/claude-live-title](https://github.com/macworld/claude-live-title/issues).
