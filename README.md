# Claude Live Title

Meaningful Claude Code session titles, updated live as the conversation evolves.

[![License](https://img.shields.io/github/license/macworld/claude-live-title)](LICENSE)
[![Stars](https://img.shields.io/github/stars/macworld/claude-live-title)](https://github.com/macworld/claude-live-title/stargazers)

English | [中文](README_ZH.md)

## Why?

Claude Code names sessions with random slugs like `elegant-chasing-eich`. A title based on the first message helps, but sessions move on: you start with a login bug and end up refactoring the auth middleware.

claude-live-title keeps the title on what the session is doing now. If you run several sessions side by side in tmux or split terminals, one glance at the statusline tells you which is which and where you left off. Pair it with [Claude HUD](#using-with-claude-hud) to show the title in the statusline.

## Features

- **Follows the current task** — when you switch to a different task, the title switches with you
- **Stable** — while you're still on the same work the title stays put; replies like "ok" or "continue" never reword it
- **Only your messages count** — background task notifications, subagent results, skill instructions and compaction summaries are ignored
- **Safe on errors** — when your account hits its usage limit or the API fails, nothing is written; the plugin pauses and tries again later
- **Respects your names** — a session you named with `/rename` or `--name` is left alone
- **Multilingual** — titles in the language you write in, or a language you choose
- **Light** — one small Haiku call per update (about 1.5K tokens, $0.0001), always in the background
- **Cross-platform** — Linux and macOS

## How It Works

Three hooks:

1. **UserPromptSubmit, async** — when you send a message, a new title is generated while Claude works on the reply. At most once per `throttleInterval`; anything skipped is picked up by the Stop hook.
2. **Stop, async** — after each reply. Names the session if it has no title yet, catches up on skipped messages, refreshes the title every 15 minutes during long autonomous runs, and restores the title if Claude Code wrote back an older one.
3. **UserPromptSubmit, sync** — after `/resume`, `/compact` or a rename, Claude Code keeps its own copy of the title and writes it back to the transcript. This hook gives Claude Code the latest title through the official `sessionTitle` field so the two stay in step. It makes no model call and finishes in about 20 ms.

The model (Haiku by default) sees a short summary of the session:

- **`CURRENT_TITLE`** — the title shown now. It is kept unless the work has moved on, so the title doesn't churn.
- **`FIRST`** — your first message, which explains short follow-ups.
- **`EARLIER`** — your recent messages before the latest (up to `contextMessages.tail`).
- **`LATEST`** — your latest message, the strongest signal.
- **`CLAUDE`** — an excerpt of Claude's latest reply, as supporting context.

Long messages are trimmed to their start and end. Claude's reply is cleaned first: code blocks, inline code, stack frames and shell prompt lines are removed (rules in `hooks/lib/sanitize-line-rules.tsv`), and the excerpt is dropped if little text is left.

The model call runs `claude -p` without tools or session persistence. If the title comes back wider than `maxLength`, one more call asks for a shorter version. The result is written to the transcript as a `custom-title` entry.

```mermaid
flowchart LR
    A[You send a message] --> B{Typed by you?<br/>Not just "ok"?<br/>Not throttled?}
    B -->|No| D[Stop hook catches up later]
    B -->|Yes| E["CURRENT_TITLE + FIRST +<br/>EARLIER + LATEST + CLAUDE"]
    E --> F[Haiku writes the title]
    F --> G[custom-title appended<br/>to the transcript]
    G --> H[HUD shows it<br/>in the statusline]
```

## Installation

There are two ways to install. Pick one, then restart Claude Code.

### From the official Anthropic directory (recommended)

Listed in [`claude-plugins-community`](https://github.com/anthropics/claude-plugins-community). The directory syncs in weekly batches, so the version there may be a few days behind this repo.

```
/plugin marketplace add anthropics/claude-plugins-community
/plugin install claude-live-title@claude-plugins-community
```

### From this repo (always latest)

```
/plugin marketplace add macworld/claude-live-title
/plugin install claude-live-title@claude-live-title
```

### Then restart Claude Code

Hooks only register at startup, so a full restart is needed — `/reload-plugins` reloads commands and skills, but not hooks. The plugin works out of the box with zero configuration.

<details>
<summary><strong>Linux: install fails with <code>EXDEV: cross-device link not permitted</code>?</strong></summary>

`/tmp` is on a separate tmpfs filesystem on many Linux setups, which breaks the plugin install. Point TMPDIR at your home directory before launching Claude Code:

```bash
mkdir -p ~/.cache/tmp && TMPDIR=~/.cache/tmp claude
```

Then run the install commands inside that session.

</details>

## Configuration

Configuration is optional. All settings have sensible defaults.

Use the slash command to configure interactively:

```
/claude-live-title:config
```

Or edit the config file directly. It lives in the plugin's data directory, which is named after the marketplace you installed from, for example:

```
~/.claude/plugins/data/claude-live-title-claude-live-title/config.json
```

```jsonc
{
  // Model for title generation (default: "haiku")
  "model": "haiku",

  // Title language (default: "auto", the language you write in)
  // Set to "zh", "en", "ja", "ko", etc. for a specific language
  "language": "auto",

  // Maximum title width in display columns (default: 30)
  // CJK characters count as 2 columns, Latin as 1
  "maxLength": 30,

  // How many of your messages the model sees
  "contextMessages": {
    "head": 1,  // first messages (default: 1)
    "tail": 5   // most recent messages (default: 5)
  },

  // Min seconds between updates while you send messages (default: 60)
  "throttleInterval": 60,

  // Update the title as the session moves on (default: true)
  // false: name the session once, after the first reply
  "liveUpdate": true,

  // Debug log in the plugin data directory (default: false)
  "debug": false
}
```

### Language Setting

By default (`"auto"`), titles use the language of your own messages, even when the code and Claude's replies are in English.

If you always want titles in a specific language regardless of conversation language, set it explicitly:

```json
{
  "language": "en"
}
```

## Using with Claude HUD

[claude-live-title](https://github.com/macworld/claude-live-title) works seamlessly with [Claude HUD](https://github.com/jarrodwatts/claude-hud). Titles generated by this plugin are automatically displayed in the HUD statusline.

### Setup

1. Install both plugins:

   ```
   /plugin marketplace add macworld/claude-live-title
   /plugin install claude-live-title
   /plugin marketplace add jarrodwatts/claude-hud
   /plugin install claude-hud
   ```

2. Enable session name display in HUD (disabled by default):

   ```
   /claude-hud:configure
   ```

   Set `showSessionName` to `true`. Or edit the config manually:

   ```json
   // ~/.claude/plugins/claude-hud/config.json
   {
     "display": {
       "showSessionName": true
     }
   }
   ```

3. Start a new conversation — the title will appear in your statusline after your first message and update as the conversation evolves.

### How It Integrates

claude-live-title writes `custom-title` entries to the session transcript file. Claude HUD reads these entries and displays the latest title in the statusline, replacing the default random slug. The title updates in real-time as your conversation progresses.

## Requirements

- Claude Code 2.1.x or later
- `jq` (JSON processor) — pre-installed on most systems, or install via your package manager
- Linux or macOS (Windows users need Git Bash or WSL)

## Troubleshooting

**Titles not appearing?**
1. Check that the plugin is installed and enabled: look for `claude-live-title` in your enabled plugins
2. Restart Claude Code after installing or updating; hooks only load at startup
3. Set `"debug": true` in your config and check `~/.claude/plugins/data/claude-live-title-*/debug.log`

**A session stopped updating?**
- If you renamed it (`/rename`, `--name`), the plugin leaves your name alone on purpose.
- After a usage-limit error the plugin pauses for 10 minutes (2 minutes after other errors), so it doesn't keep hitting the limit.

**Titles in the wrong language?**
Set `language` explicitly in your config.

**Too many / too few updates?**
Adjust `throttleInterval` (seconds) in your config.

**Caught a bad title? Help improve it.**
With `"debug": true`, every generated title adds an event to the debug log with the exact input the model saw. Run `bin/promote-fixture.sh <slug>` to turn the latest one into a regression fixture under `tests/fixtures/transcripts/`, then open an issue or PR with it.

## Development

```bash
git clone https://github.com/macworld/claude-live-title
cd claude-live-title

# Load plugin from source for development
claude --plugin-dir .
```

For local development, `--plugin-dir` loads the plugin directly from your working copy — no install or cache involved. Hook changes require a session restart; use `/reload-plugins` for command/skill changes.

Run the tests with:

```bash
for t in tests/test-*.sh; do bash "$t"; done

# Also check the fixtures against the real model (well under one cent)
RUN_LIVE=1 bash tests/test-fixtures.sh
```

## More

- [Changelog](CHANGELOG.md) — release notes and version history
- [Privacy Policy](PRIVACY.md) — what runs locally and what doesn't leave your machine

## License

MIT
