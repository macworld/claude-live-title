# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/),
and this project adheres to [Semantic Versioning](https://semver.org/).

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
