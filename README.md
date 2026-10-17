# Live Title

Meaningful Claude Code session titles, updated live as the conversation evolves. Formerly `claude-live-title`.

[![Release](https://img.shields.io/github/v/release/macworld/claude-live-title)](https://github.com/macworld/claude-live-title/releases)
[![License](https://img.shields.io/github/license/macworld/claude-live-title)](LICENSE)
[![Stars](https://img.shields.io/github/stars/macworld/claude-live-title)](https://github.com/macworld/claude-live-title/stargazers)

English | [中文](README_ZH.md)

![Demo: Live Title names a Claude Code session from the first message, renames it when the task changes, and keeps sessions easy to tell apart across tabs and in /resume](assets/demo-en.gif)

## Why?

Claude Code titles a session after your first message and keeps that title. Sessions move on: you start with a login bug and end up rotating refresh tokens. Live Title keeps every session named after what it's doing now.

| You say | Claude Code's title | Live Title |
|---|---|---|
| users get a 401 as soon as their access token expires… | Access token expiry returns 401 | Fix 401 after token expiry |
| let's switch to rotating refresh tokens with reuse detection | Access token expiry returns 401 | Rotating refresh tokens |
| sounds good, go ahead | Access token expiry returns 401 | Rotating refresh tokens |

- **Named from your first task.** Describe a bug and the session is named after it. A "hi" or a test message leaves it unnamed until there's a task.
- **Follows the task.** When the work moves on, the title moves with it. A reply like "sounds good, go ahead" leaves it alone.
- **Easy to find again.** With several sessions open in tabs, tmux or split terminals, one glance at the tab or the statusline tells you which is which. In `/resume`, past sessions are listed by what they did.
- **Your format, if you want one.** Optional naming rules, like a ticket ID up front, for every session or per project.

The titles in the table and the demo are what Claude Code and the plugin generated for those messages. The statusline in the demo is [Claude HUD](#using-with-claude-hud) with `showSessionName` turned on.

## Features

- **Follows the current task** — when you switch to a different task, the title switches with you
- **Stable** — while you're still on the same work the title stays put; replies like "ok" or "continue" never reword it
- **Waits for a task** — a greeting or a test message gets no title; the session is named once you ask for something
- **Your naming format** — optional rules in plain words, like a ticket ID or a type prefix, globally or per project ([Naming Format](#naming-format))
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
3. **UserPromptSubmit, sync** — Claude Code keeps its own copy of the title: it shows that copy in the terminal tab and the statusline, and writes it back to the transcript. This hook gives Claude Code the latest title through the official `sessionTitle` field so the two stay in step. It makes no model call and finishes in about 20 ms.

The model (Haiku by default) sees a short summary of the session:

- **`CURRENT_TITLE`** — the title shown now. It is kept unless the work has moved on, so the title doesn't churn.
- **`FIRST`** — your first message, which explains short follow-ups.
- **`EARLIER`** — your recent messages before the latest (up to `contextMessages.tail`).
- **`LATEST`** — your latest message, the strongest signal.
- **`CLAUDE`** — an excerpt of Claude's latest reply, as supporting context.

Long messages are trimmed to their start and end. Claude's reply is cleaned first: code blocks, inline code, stack frames and shell prompt lines are removed (rules in `hooks/lib/sanitize-line-rules.tsv`), and the excerpt is dropped if little text is left.

The model treats the dialog as material to title, never as instructions, so a prompt you paste into the session doesn't steer it. When your messages hold no task yet (a greeting, a test message, small talk), it answers `SKIP` and nothing is written.

The model call runs `claude -p` without tools or session persistence. If the title comes back wider than `maxLength`, up to two more calls ask for a shorter version. The result is written to the transcript as a `custom-title` entry.

```mermaid
flowchart LR
    A[You send a message] --> B{Typed by you?<br/>Not just "ok"?<br/>Not throttled?}
    B -->|No| D[Stop hook catches up later]
    B -->|Yes| E["CURRENT_TITLE + FIRST +<br/>EARLIER + LATEST + CLAUDE"]
    E --> F[Haiku writes the title]
    F --> G[custom-title appended<br/>to the transcript]
    G --> H[Shown in /resume,<br/>the tab and the statusline]
```

## Installation

There are two ways to install. Pick one, then restart Claude Code.

### From the official Anthropic directory (recommended)

Listed in [`claude-plugins-community`](https://github.com/anthropics/claude-plugins-community) under its old name, `claude-live-title`. Each new version goes through Anthropic's review first, so the directory can be behind this repo.

```
/plugin marketplace add anthropics/claude-plugins-community
/plugin install claude-live-title@claude-community
```

### From this repo (always latest)

```
/plugin marketplace add macworld/claude-live-title
/plugin install live-title@claude-live-title
```

### Then restart Claude Code

Hooks only register at startup, so a full restart is needed — `/reload-plugins` reloads commands and skills, but not hooks. The plugin works out of the box with zero configuration.

### Upgrading from claude-live-title

The plugin was renamed from `claude-live-title` to `live-title` in 2.0. Remove the old one with `--keep-data`, install the new one, then restart. Your config and session titles carry over.

```bash
claude plugin uninstall claude-live-title@claude-live-title --keep-data
claude plugin marketplace update claude-live-title
claude plugin install live-title@claude-live-title
```

If you installed from the community directory, there's nothing to reinstall: the entry there keeps the old name.

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
/live-title:config
```

Or edit the config file directly. It lives in the plugin's data directory, which is named after the marketplace you installed from, for example:

```
~/.claude/plugins/data/live-title-claude-live-title/config.json
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

  // Your naming rules, in plain words (default: none)
  // A project's .claude/live-title.md replaces this for that project
  "style": "",

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

### Naming Format

Titles are short plain phrases by default. To give them a format, describe it in `style`:

```json
{
  "style": "Start the title with the ticket ID in square brackets, like [PROJ-123], when the user mentions one."
}
```

With that rule, `PROJ-1423: the login form accepts an empty password, fix it` gets the title `[PROJ-1423] Fix empty password`.

To set rules for one project, write them in `.claude/live-title.md` at the project root. The file replaces `style` for sessions in that project, and you can commit it so your team gets the same format. Another rule that works:

- `Begin the title with one of feat:, fix:, docs:, refactor:, chore: and then a short lowercase summary.`

Rules can be written in any language. They are capped at 1000 characters, and `maxLength` still applies.

## Where the Title Shows Up

- **`/resume`** lists past sessions by title.
- **The terminal tab.** Claude Code sets the terminal title to the session title (in tmux, the pane title). No setup needed.
- **Your statusline.** Claude Code passes the title to statusline commands as `session_name`. The smallest statusline that shows it, in `~/.claude/settings.json`:

  ```json
  {
    "statusLine": {
      "type": "command",
      "command": "jq -r '.session_name // empty'"
    }
  }
  ```

- **[Claude HUD](#using-with-claude-hud)**, with `showSessionName` turned on.

The tab and `session_name` take a new title when you send your next message, because Claude Code accepts titles from plugins only at that point. Until the plugin's first title arrives, they show Claude Code's own.

## Using with Claude HUD

[Live Title](https://github.com/macworld/claude-live-title) works with [Claude HUD](https://github.com/jarrodwatts/claude-hud): the session title appears in the HUD statusline.

### Setup

1. Install both plugins:

   ```
   /plugin marketplace add macworld/claude-live-title
   /plugin install live-title@claude-live-title
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

3. Start a new conversation. The statusline shows the session title and follows it as the work moves on.

### How It Integrates

Live Title writes `custom-title` entries to the session transcript and hands the latest title to Claude Code. Current HUD versions show the `session_name` Claude Code passes to the statusline, which takes a new title when you send your next message; older versions read the `custom-title` entries from the transcript.

## Requirements

- Claude Code 2.1.x or later
- `jq` (JSON processor) — pre-installed on most systems, or install via your package manager
- Linux or macOS (Windows users need Git Bash or WSL)

## FAQ

**Doesn't Claude Code already name sessions?**
It titles a session after your first message and keeps that title for the whole session. Live Title renames the session when the work moves on, and can follow a naming format you set.

**Why does the tab show a new title one message late?**
Claude Code accepts a title from a plugin only when you send a message. The title is generated while Claude replies, so the tab and the statusline pick it up with your next message. `/resume` reads the transcript and has it right away.

## Troubleshooting

**A session has no title?**
A greeting or a test message gets no title. The session is named once you ask for something.

**Titles not appearing?**
1. Check that the plugin is installed and enabled: look for `live-title` in your enabled plugins
2. Restart Claude Code after installing or updating; hooks only load at startup
3. Set `"debug": true` in your config and check `~/.claude/plugins/data/live-title-*/debug.log`

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

# Run each fixture 4 times to catch titles that only go wrong sometimes
RUN_LIVE=1 SAMPLES=4 bash tests/test-fixtures.sh
```

## More

- [Changelog](CHANGELOG.md) — release notes and version history
- [Privacy Policy](PRIVACY.md) — what runs locally and what doesn't leave your machine

## License

MIT
