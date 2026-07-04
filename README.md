# Claude Menu Bar

A native macOS menu bar app for monitoring Claude Code usage, written in Swift.

> **Note:** Uses unofficial Anthropic API endpoints. May break without notice. Not affiliated with or endorsed by Anthropic.

## Features

- **Donut icon** — dual-ring visualization of session (5h) and weekly token usage at a glance
- **Session monitoring** — see active Claude Code sessions with busy/idle status per project
- **Usage thresholds** — system notifications at 25/50/75/90% session usage
- **Idle notifications** — notified when a Claude Code session finishes a task
- **Model tracking** — last used and most used model across all projects
- **Plan detection** — auto-detects Pro/Max plan

## Requirements

- macOS 13+
- Claude Code installed and logged in
- Xcode Command Line Tools (`xcode-select --install`)

## Install

```bash
# Build
bash build.sh

# Run
open ClaudeMenuBar.app

# Auto-start at login (recommended)
bash install.sh
```

## How it works

Reads the Claude Code OAuth token from Keychain (`Claude Code-credentials`) and calls:
- `https://api.anthropic.com/api/oauth/usage` — token usage
- `https://api.anthropic.com/api/oauth/account` — plan info

Session data is read from `~/.claude/sessions/*.json` (local files written by Claude Code).
Model history is parsed from `~/.claude/projects/**/*.jsonl`.

## Uninstall

```bash
launchctl unload ~/Library/LaunchAgents/com.kota.claude-menu-bar.plist
rm ~/Library/LaunchAgents/com.kota.claude-menu-bar.plist
```

## Disclaimer

This project uses undocumented Anthropic API endpoints that may change or be removed at any time. Use at your own risk.

## License

MIT
