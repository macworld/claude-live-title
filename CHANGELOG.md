# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [2.1.3] - 2026-10-17

### Fixed
- The Stop hook takes Claude's latest reply from the hook input (`last_assistant_message`) instead of the transcript, which Claude Code doesn't guarantee to hold the final message at Stop time. The transcript is still read when the input carries no reply or Claude Code's own error text.
- One hook run spends at most 60 s on model calls in all (the title plus up to two shortening calls), well inside the 90 s after which another hook treats the session lock as stale, so a hung call can no longer let two generations run at once. A call that times out is no longer retried with the basic flag set.
- The prompt is written to a temporary file in the plugin's data directory instead of `/tmp`.

### Changed
- Config keys the plugin doesn't know are named in the debug log instead of being ignored silently.
- `hooks/hooks.json` no longer sets `matcher`, which Claude Code ignores on UserPromptSubmit and Stop, or a `timeout` on the async hooks, which it doesn't enforce.
- README: a shorter feature list, the hook and prompt internals folded into a details block, a configuration table with the four settings most people use and the rest folded away, and the note about the tab updating one message late made once instead of three times. The plugin description is the same sentence in `plugin.json` and `marketplace.json`.
- Windows support is stated as WSL only; Git Bash was never tested.

## [2.1.2] - 2026-10-17

### Fixed
- After `/clear`, the first turn no longer shows the previous task's title. `/clear` starts a new session but carries the old title over, and Claude Code keeps showing it in the terminal tab and the statusline, writing it back into the transcript after every request, until a hook hands it another one. The plugin could only do that with your next message, so the whole first turn kept the old name. Now your first message after `/clear` stands in as the title right away, cut to `maxLength` (at a word for Latin text), and the generated title replaces it with your next message. In Claude Code 2.1.302 nothing earlier works: an empty `sessionTitle` is ignored, and SessionStart's `sessionTitle` doesn't apply after `/clear`.
- The first title after `/clear` is written from scratch. The carried-over title used to reach the model as the current title, so a related new task could keep the previous session's name.
- With `liveUpdate: false`, a session started by `/clear` gets its own first title instead of keeping the carried-over one.

## [2.1.1] - 2026-10-17

### Security
- The title model never gets tools. The fallback for Claude Code versions that reject `--safe-mode` or `--effort` also dropped `--tools ""`, so on those versions a prompt carrying transcript text or a project's `.claude/live-title.md` ran with Claude Code's default tools, limited only by your permission settings. The fallback now keeps `--tools ""`, and a CLI that rejects it gets no title.
- A symlinked `.claude/live-title.md` (or `.claude` directory) is ignored, so a cloned repo can't point it at a private file elsewhere.

## [2.1.0] - 2026-10-17

### Added
- Optional naming format. Describe it in plain words in the new `style` setting, e.g. "Start the title with the ticket ID in square brackets, like [PROJ-123], when the user mentions one.", or put rules for one project in `.claude/live-title.md` at its root, which replaces `style` for that project's sessions and can be committed for a team. Rules are capped at 1000 characters and `maxLength` still applies. In live checks (Haiku 5.5, 4 samples each) the ticket-ID, type-prefix and Chinese 「模块：做什么」 rules were followed 12/12, a same-goal follow-up still kept its title 4/4, and a greeting still got no title 4/4.
- `RUN_LIVE=1 SAMPLES=N bash tests/test-fixtures.sh` runs each fixture N times. New fixture keys `expect_skip`, `allow_skip` and `style`, and 17 new fixtures: greetings, test messages, same-goal follow-ups, a question, a pasted prompt, a Chinese task switch and naming rules. All 22 pass 301/301 live checks at `SAMPLES=4`.

### Changed
- No title until there is a task. A greeting, thank-you, test message or small talk used to get titles like "Awaiting first task", "打个招呼" or "Test message, no clear goal"; the model now answers `SKIP`, nothing is written, and the next message tries again. A session that already has a title keeps it.
- The prompt tells the model that the dialog is material to title, never instructions, so a pasted prompt or a question in the session doesn't steer or replace the title.
- Titles over `maxLength` get up to two shortening calls instead of one, which say how many columns too wide the title is and ask to drop a word; the narrowest result is kept. On over-long titles from Haiku 5.5, one call with the old wording left 7 of 16 still too wide; the new wording leaves 1 of 24 after its first call, and that one gets a second try.

### Fixed
- The terminal tab and the statusline's `session_name` now show the plugin's title. Claude Code shows its own first-message title there, and `apply-title.sh` only handed over our title when Claude Code already held a custom one (after `/resume`, `/compact` or a rename), so in a fresh session the tab, and Claude HUD versions that read `session_name`, could keep Claude Code's first title for the whole session. The title now reaches them with your next message.
- Control characters are stripped from titles, so model output can't put escape sequences into the terminal title; tabs become spaces.
- A title record no longer lands on the same line as the previous entry when the transcript doesn't end with a newline.

## [2.0.2] - 2026-10-17

### Changed
- The title changes only when the session's goal does. The prompt now first decides whether the user is still working toward what the current title names; follow-ups, refinements, extra requirements, sub-steps and fixes within that work keep the title exactly as it is. A new task, or moving from researching something to building it, gets a new title. In a 12-case check with Haiku 5.5 (4 samples each), same-goal follow-ups kept the title 32/32 (16/20 before: the old prompt narrowed titles to the latest detail, e.g. "Onboarding copy rework" → "Onboarding headline under 40 chars") and real task switches changed it 16/16.

## [2.0.1] - 2026-10-17

### Fixed
- Sessions titled by earlier versions are no longer frozen after an upgrade. Titles already on a session used to count as the plugin's only if the old `/tmp` markers were still there; `/tmp` is wiped on reboot, so most older sessions were treated as user-named and never updated again. Existing titles are now adopted unless the transcript shows that the user chose one: a `/rename`, or a title present before the first message (`--name`) in a session that wasn't started with `/clear`.
- After `/clear`, the title carried over from the previous session is replaced once you start the new task.

## [2.0.0] - 2026-10-17

### Changed
- **Renamed from `claude-live-title` to `live-title`.** Claude Code now reserves plugin names starting with `claude-` for Anthropic's own plugins, and `claude plugin validate` rejects the old name. The plugin ID becomes `live-title@<marketplace>` and the config command `/live-title:config`. The GitHub repo and the `claude-live-title` marketplace keep their names.
- To upgrade: `claude plugin uninstall claude-live-title@<marketplace> --keep-data`, then `claude plugin install live-title@<marketplace>` and restart. On first run the config and session state are copied from the old data directory, so sessions titled before the rename keep updating.

## [1.4.0] - 2026-10-17

### Fixed
- Usage-limit and API error text no longer becomes the session title. The model call now uses `--output-format json` and checks `is_error`; Claude Code's own error text is rejected even if a CLI version forgets the flag. After a usage-limit error the plugin pauses for 10 minutes (2 minutes after other errors) instead of retrying on every message.
- Long sessions no longer drift to stale or wrong titles:
  - Only messages you typed reach the model. Task notifications, subagent hand-backs, messages from other sessions, skill bodies, compaction summaries, slash-command noise and hook feedback are skipped, based on the transcript's `origin` / `isMeta` / `isCompactSummary` / `isSidechain` fields with text rules as a fallback.
  - Claude Code's synthetic error replies (`isApiErrorMessage`, model `<synthetic>`) and subagent replies are no longer used as the Claude excerpt.
  - Each message is capped on its own (head and tail kept), so one long paste can't crowd out the latest request.
- Titles no longer revert after `/resume`, `/compact` or attaching a session. Once Claude Code holds a title it re-appends it to the transcript after every API request; a new sync UserPromptSubmit hook (`apply-title.sh`) hands it the latest title through the official `sessionTitle` field, and the Stop hook restores the latest title when the transcript ends with an older one.
- Titles you set yourself (`/rename`, `--name`, another tool) are detected and the session is left alone from then on.
- `liveUpdate: false` in the config was read as `true` (jq `//` treats `false` as missing).
- The test suite no longer overwrites the real config file.

### Changed
- Default model alias `haiku` now resolves to Claude Haiku 5.5.
- New prompt and dialog format: `CURRENT_TITLE` / `FIRST` / `EARLIER` / `LATEST` / `CLAUDE`. The latest message is the strongest signal, a different task replaces the old title instead of being merged into it, and the current title is kept unless the focus or the kind of work changed, so titles don't churn. `language: "auto"` follows the language you write in, not the language of the code or Claude's reply.
- Bare acknowledgements ("ok", "继续", "yes go ahead") no longer trigger a new title.
- Titles wider than `maxLength` get one follow-up call asking for a shorter version; the prompt now gives worked examples of column widths.
- Model calls run with `--tools "" --effort low --safe-mode` (about 1.5K input tokens instead of ~25K), falling back to the basic flag set on CLIs that reject them.
- Trigger rules: the live hook generates at most once per `throttleInterval` (default 60 s, was 240 s); the Stop hook catches up on skipped messages and refreshes every 15 minutes during long autonomous runs. `throttleMessages` is retired and ignored.
- `contextMessages.head` defaults to 1 (was 3).
- State, locks, cooldown markers and the debug log moved from `/tmp` to the plugin data directory. The debug log is mode 600 and rotated at 1 MB; old session state is cleaned up after 30 days. Sessions titled by 1.3 and earlier are picked up through their `/tmp` markers.
- `clean_title` also strips markdown headings, bold wrapping and curly quotes, and joins multi-line output with spaces.

### Added
- `tests/test-config.sh` and regression fixtures for the usage-limit, task-switch, system-noise, mixed-language and research-to-implementation cases. `tests/test-entry.sh` now covers the three hooks end to end (76 cases). `UPDATE_SNAPSHOT=1` regenerates the prompt snapshot.
- `bin/promote-fixture.sh` reads the debug log from the plugin data directory and understands both the new and the pre-1.4 dialog format.

## [1.3.0] - 2026-04-25

### Added
- `bin/promote-fixture.sh` and a structured replay log entry: when `DEBUG=true`, every generated title now appends one JSON event to `/tmp/claude-live-title-debug.log` capturing `{ts, session_id, dialog, title}`. The promote helper pulls the most recent (or `--grep`'d) event and writes a minimal transcript `.jsonl` plus a stub `.expected.yaml` under `tests/fixtures/transcripts/`, so a user who notices a bad title can turn it into a regression fixture in one command.
- `tests/test-fixtures.sh` — fixture replay harness. Lints fixtures by default (dialog non-empty, `must_not_contain` strings absent from the dialog Haiku sees); with `RUN_LIVE=1` also calls the real model and checks the resulting title against `must_contain_any` / `must_not_contain`.
- `hooks/lib/sanitize-line-rules.tsv` — data-driven catalog for the line-level drop rules in `sanitize_ai_text` step 3. Adding a noise pattern (Rust panic, Go panic, Ruby backtrace, Java inner-class frame, Node `UnhandledPromiseRejection`) is now one TSV row. Stateful logic (fence toggle, blank collapse, substance gate, length cap) deliberately stays in code per the design plan's D3 boundary.
- `CLAUDE_LIVE_TITLE_PRINT_DIALOG=1` dry-run mode in `generate_title`: prints the rendered system + task prompt + dialog to stdout and skips the model call. Backs `tests/test-prompt-snapshot.sh`, which diffs against `tests/snapshots/prompt.txt` so prompt drift becomes a visible review diff.
- `tests/test-clean-title.sh`, `tests/test-entry.sh`, `tests/test-promote-fixture.sh` — three new test suites covering title post-processing (28 cases including combined-wrapping shapes), end-to-end hook wiring with stubbed `claude` (9 scenarios spanning fresh-session GOAL fallback, throttle, lock contention, marker dedup), and the promote helper (8 cases).

### Changed
- `clean_title` rewritten as a fixed-point loop using `sed -E`: combined-wrapping shapes like `"Title: Fix."` and `标题：「修复」。` now peel fully, and multiple trailing punctuation (`修登录。！`) collapses in one shot. No new behaviour for normal one-layer titles.

## [1.2.1] - 2026-04-25

### Fixed
- Multi-line first user prompts no longer get truncated to their first physical line as the `GOAL:` anchor. `extract_goal_message` now returns the whole first user message, and `format_dialog` plus `extract_user_messages` all flatten via a shared `_flatten_oneline` helper so each tier of the dialog is exactly one labeled line. Restores GOAL as a reliable session-intent anchor for sessions that start with a multi-paragraph prompt (pasted stack traces, numbered requirements, etc.).
- `<system-reminder>`, `<local-command-stdout>`, and `<local-command-stderr>` blocks are now stripped as full multi-line regions from user content. The previous line-mode strip only removed the open/close tag lines and let the body leak into `USER:` / `GOAL:` lines.
- 300-char `STATE:` cap and `MAX_INPUT_CHARS` extraction cap are UTF-8 character-aware via a new portable `_cap_chars` helper (`LC_ALL=C awk`, manual UTF-8 lead-byte detection). Previously `${var:0:N}` was char-based on Linux bash 5+ but byte-based on macOS system bash 3.2, and `head -c` was always byte-based — both could leave dangling bytes mid-CJK character.
- Sanitize pipeline strips carriage returns up front, so Windows-origin transcripts (CRLF) no longer leak `\r` bytes into `STATE:`.
- Stop-hook dedup marker is now a directory created via `mkdir` (atomic) rather than a `touch` file with a check-then-touch window. Concurrent Stop invocations can no longer both proceed past the dedup check.
- Stop hook detects existing `custom-title` records via `jq -e 'select(.type=="custom-title")'` instead of substring `grep`. Removes a theoretical false positive on user content quoting the type tag.

## [1.2.0] - 2026-04-25

### Changed
- Dialog format for title generation moved from flat `USER:` / `AI:` to three-tier `GOAL:` / `USER:` / `STATE:`. `GOAL` is the first user message (session's original intent); `STATE` is the sanitized last AI text. Prompt rules now treat STATE as background context except when the last USER message is a short filler reply (ok, 好, continue, 嗯, go, yes, 行, sure, do it).
- AI context is now sanitized before reaching Haiku: fenced code blocks, inline backticks, Python / JS stack frames, and `$`/`>` prompt lines are stripped. If under 30 bytes of substance remain, the `STATE:` line is dropped entirely. Fixes titles that previously copied `Traceback` lines or shell-output fragments from the last AI paragraph.
- Dropped the "weight later messages heavier" rule from the prompt — replaced with a tiered hierarchy anchoring on GOAL and weighting the last substantive USER message. Prevents title drift toward mid-task AI content during long sessions.

### Added
- `tests/test-sanitize.sh` — unit coverage for the new `sanitize_ai_text` pipeline (11 cases: fenced blocks, indented fences, inline backticks, Python stack frames, shell prompt lines, blank-line handling around fences, substance threshold, CJK cap behaviour).
- `extract_goal_message` helper in `common.sh` for the new GOAL label.

## [1.1.0] - 2026-04-18

### Changed
- Title generation now samples a mixed USER + latest-AI dialog instead of user-only. The last AI text block (first paragraph, ≤300 chars) is appended as a single `AI:` line — resolves two long-standing title-quality issues: intent ambiguity after short user replies (ok/继续/好), and stale titles on long multi-task sessions that drift away from the initial request.
- Title prompt rewritten to target roughly 70% of the length budget and to handle the USER:/AI: label convention. Short user replies now route intent lookup to the AI line; unrelated topics are no longer merged into nonsense compound phrases.
- Hook timeout raised from 30s to 60s for both hooks. Absorbs Haiku latency variance up to ~40s observed in validation; aligns with the Stop hook's existing 60s stale-lock recovery.

### Added
- `tests/test-extract.sh` — unit coverage for the new `extract_last_ai_text` and `format_dialog` helpers in `common.sh` (11 cases including truncation, multi-paragraph handling, tool-only-last fallback, and dialog formatting edge cases).

## [1.0.4] - 2026-04-12

### Fixed
- First-prompt title not generated on brand-new sessions: `UserPromptSubmit` fires ~100ms before Claude Code creates the transcript file on turn 1 of a fresh session, so the live hook's `! -f "$TRANSCRIPT_PATH"` check silently bailed before reaching any debug log. The fix polls up to 1s for the transcript to appear (observed as `transcript_wait=1x100ms` in logs) and records the wait count in the log line so future regressions are visible. Result: turn 1 now gets a real-time title instead of falling through to the Stop-hook fallback, which previously made the title appear only starting from turn 2 with what looked like the previous turn's content.
- Live/Stop race: if the Stop hook fired while the live hook was still calling `claude -p` (transcript did not yet contain a `custom-title`), both hooks could generate and write a title concurrently. The live hook now acquires its lock before the transcript wait, and the Stop hook defers when it sees the lock (with a 60s stale-lock recovery path).

## [1.0.3] - 2026-04-12

### Fixed
- Resume Session list pollution: every `claude -p` call used to generate the title was persisted as its own session under the user's project directory, so the `/resume` picker filled up with dozens of sidecar entries whose first message was the raw title-generation prompt (`<task>Generate a concise title…`). Fixed by adding `--no-session-persistence` to the `claude -p` invocation — the helper call now runs entirely in memory and leaves no trace in the project's session history.

## [1.0.2] - 2026-04-12

### Fixed
- Config fallback path: when `CLAUDE_PLUGIN_DATA` is not exported to plugin hooks, fall back to the canonical `~/.claude/plugins/data/claude-live-title/` instead of the legacy `~/.claude/plugins/claude-live-title/`. Previous behavior caused config edits made via the standard data path to be silently ignored on installations where the env var isn't propagated, leaving the plugin running with stale defaults from the legacy file.
- First-turn title not visible in HUD: switched the live hook from `PreToolUse` to `UserPromptSubmit`. The previous `PreToolUse` trigger only fired when Claude used a tool, so for text-only replies the title was only generated by the `Stop` hook — which fires after Claude finishes, after the HUD has already rendered. The user therefore had to send a second message before the first title appeared. `UserPromptSubmit` fires the moment the user presses Enter, so title generation runs in parallel with Claude's reply and is usually written to the transcript before the HUD renders the end-of-turn statusline.

### Changed
- Hook architecture: `PreToolUse` → `UserPromptSubmit` for the live hook. `Stop` hook retained as defensive fallback.
- README: refreshed title and tagline for clarity
- README: added "Why?" section explaining how dynamic titles help with topic drift in long conversations, session `resume`, and tmux / multi-window workflows
- README: added Mermaid flow diagram illustrating the live-title pipeline (hook → throttle → sampling → Haiku → transcript → HUD)

## [1.0.1] - 2026-04-11

### Changed
- Throttle defaults: interval 300s → 240s, messages 3 → 2
- `contextMessages` is now an object with `head` and `tail` fields, allowing independent control over earliest and most recent message sampling

### Added
- `contextMessages.head` / `contextMessages.tail` configuration for fine-grained context sampling

## [1.0.0] - 2026-04-11

First stable release.

### Changed
- Promote to v1.0.0 as first production-ready release
- Adopt Keep a Changelog format for CHANGELOG

## [0.1.0] - 2026-04-11

Initial release.

### Added
- Real-time title generation via `PreToolUse` hook with smart throttling
- Final title refinement via `Stop` hook with deduplication
- Multilingual support (auto-detect or manual `language` setting)
- `/claude-live-title:config` slash command for runtime configuration
- Configurable throttle interval and context message count
- Smart message sampling with noise filtering
- Temporal weighting for recent context prioritization
- Cross-platform support (Linux + macOS)
- Claude HUD integration support

### Fixed
- Session ID handling and config validation hardening
- Cross-language title length consistency
