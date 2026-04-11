---
name: config
description: "Use when the user asks to \"view claude-live-title settings\", \"change title language\", \"configure live title\", \"adjust throttle interval\", or \"update claude-live-title config\". Manage plugin configuration for session title generation."
model: haiku
allowed-tools: ["Bash", "Read", "Edit", "Write", "AskUserQuestion"]
---

# claude-live-title Configuration

Help the user view or modify their claude-live-title plugin configuration.

## Config file location

`${CLAUDE_PLUGIN_DATA}/config.json` (typically `~/.claude/plugins/data/claude-live-title/config.json`)

> Legacy path `~/.claude/plugins/claude-live-title/config.json` is auto-migrated on first load.

## Available settings

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| model | string | "haiku" | Model used for title generation (e.g., "haiku", "sonnet") |
| language | string | "auto" | Title language: "auto" (detect from conversation), "zh", "en", "ja", "ko", etc. |
| maxLength | number | 30 | Target title length in display columns (CJK=2, Latin=1), passed to the AI prompt |
| contextMessages | number | 8 | Number of user messages sampled for title generation (split ~3:5 head/tail) |
| throttleInterval | number | 240 | Minimum seconds between live title updates |
| throttleMessages | number | 2 | Minimum new user messages before live title update |
| liveUpdate | boolean | true | Enable real-time title updates during conversation. When false, titles are only generated when the session ends. |
| debug | boolean | false | Enable debug logging to /tmp/claude-live-title-debug.log |

## Behavior

1. Read the current config file. If it does not exist, show the default values and offer to create it.
2. Ask the user which setting they want to change.
3. Update the config file, creating the directory and file if needed. Use `${CLAUDE_PLUGIN_DATA}/config.json` as the path; fall back to `~/.claude/plugins/claude-live-title/config.json` if `CLAUDE_PLUGIN_DATA` is not set.
4. Show the updated configuration and confirm the changes.

## Notes

- All fields are optional. Omitted fields use their default values.
- The config file is user-local and persists across plugin updates.
- Changes take effect on the next hook invocation (no restart needed).
- For `language`, "auto" detects the conversation language automatically. Set explicitly if you always want titles in a specific language (e.g., "zh" for Chinese even when coding discussions are in English).
