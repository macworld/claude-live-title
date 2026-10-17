---
name: config
description: "Use when the user asks to \"view claude-live-title settings\", \"change title language\", \"configure live title\", \"adjust throttle interval\", or \"update claude-live-title config\". Manage plugin configuration for session title generation."
model: haiku
allowed-tools: ["Bash", "Read", "Edit", "Write", "AskUserQuestion"]
---

# claude-live-title Configuration

Help the user view or modify their claude-live-title plugin configuration.

## Config file location

`${CLAUDE_PLUGIN_DATA}/config.json`

Use exactly this path for reading and writing. Don't guess other locations: the directory name depends on the marketplace the plugin was installed from.

## Available settings

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| model | string | "haiku" | Model used for title generation (e.g., "haiku", "sonnet") |
| language | string | "auto" | Title language: "auto" (the language the user writes in), "zh", "en", "ja", "ko", etc. |
| maxLength | number | 30 | Maximum title width in display columns (CJK = 2, Latin = 1). Titles aim for about 70% of it; a longer result is shortened with one extra call. |
| contextMessages.head | number | 1 | How many of the user's first messages the model sees |
| contextMessages.tail | number | 5 | How many of the user's most recent messages the model sees |
| throttleInterval | number | 60 | Minimum seconds between title updates while the user sends messages. Messages skipped this way are picked up after Claude's reply. |
| liveUpdate | boolean | true | Update the title as the conversation moves on. When false, the session gets one title after Claude's first reply and keeps it. |
| debug | boolean | false | Write a debug log to `${CLAUDE_PLUGIN_DATA}/debug.log` (contains conversation excerpts, rotated at 1 MB) |

`throttleMessages` from versions before 1.4 is no longer used and can be removed.

## Behavior

1. Read the current config file. If it does not exist, show the default values and offer to create it.
2. Ask the user which setting they want to change.
3. Update the config file, creating the directory and file if needed. Write valid JSON with only the fields the user set.
4. Show the updated configuration and confirm the changes.

## Notes

- All fields are optional. Omitted fields use their default values.
- The config file persists across plugin updates.
- Changes take effect on the next message (no restart needed).
- For `language`, "auto" follows the language of the user's own messages, even when code and Claude's replies are in English. Set it explicitly to always get one language.
- A session the user named with `/rename` or `--name` is never renamed by the plugin.
