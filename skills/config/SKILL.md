---
name: config
description: "Use when the user asks to \"view live-title settings\", \"change title language\", \"configure live title\", \"set a title format\", \"adjust throttle interval\", or \"update live-title config\". Manage plugin configuration for session title generation."
model: haiku
allowed-tools: ["Bash", "Read", "Edit", "Write", "AskUserQuestion"]
---

# live-title Configuration

Help the user view or modify their live-title plugin configuration (called claude-live-title before 2.0).

## Config file location

`${CLAUDE_PLUGIN_DATA}/config.json`

Use exactly this path for reading and writing. Don't guess other locations: the directory name depends on the marketplace the plugin was installed from.

## Available settings

Most users only set `language` or `style`. The rest are advanced.

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| language | string | "auto" | Title language: "auto" (the language the user writes in), "zh", "en", "ja", "ko", etc. |
| style | string | "" | Naming rules in plain words, e.g. "Start the title with the ticket ID in square brackets, like [PROJ-123], when the user mentions one." Up to 1000 characters; maxLength still applies. Empty means plain short titles. |
| maxLength | number | 30 | Maximum title width in display columns (CJK = 2, Latin = 1). Titles aim for about 70% of it; a longer result is shortened with up to two extra calls. |
| liveUpdate | boolean | true | Update the title as the conversation moves on. When false, the session gets one title after Claude's first reply and keeps it. |
| model | string | "haiku" | Advanced. Model used for title generation (e.g., "haiku", "sonnet") |
| throttleInterval | number | 60 | Advanced. Minimum seconds between title updates while the user sends messages. Messages skipped this way are picked up after Claude's reply. |
| contextMessages.head | number | 1 | Advanced. How many of the user's first messages the model sees |
| contextMessages.tail | number | 5 | Advanced. How many of the user's most recent messages the model sees |
| debug | boolean | false | Advanced. Write a debug log to `${CLAUDE_PLUGIN_DATA}/debug.log` (contains conversation excerpts, rotated at 1 MB) |

Any other key is ignored by the plugin; `throttleMessages` from versions before 1.4 is one of those.

## Behavior

1. Read the current config file. If it does not exist, show the default values and offer to create it.
2. If the user hasn't said what to change, ask which setting they want to change.
3. Update the config file, creating the directory and file if needed. Write valid JSON with only the fields the user set.
4. Show the updated configuration and confirm the changes.

## Notes

- All fields are optional. Omitted fields use their default values.
- The config file persists across plugin updates.
- Changes take effect on the next message (no restart needed).
- If the file holds a key that isn't in the table (a typo, or a retired setting), say so and offer to remove it; the plugin ignores it.
- For `language`, "auto" follows the language of the user's own messages, even when code and Claude's replies are in English. Set it explicitly to always get one language.
- A session the user named with `/rename` or `--name` is never renamed by the plugin.
- For `style`, write the user's rule as one plain instruction, in their words. Rules for a single project go in `.claude/live-title.md` at that project's root instead; that file replaces `style` for the project's sessions and can be committed for the team. Offer it when the user wants a format only for the current project.
- A greeting or a test message gets no title; the session is named once the user asks for something.
