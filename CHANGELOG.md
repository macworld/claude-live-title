# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Changed
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
