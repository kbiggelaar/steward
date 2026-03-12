# Steward

A personal AI-powered life operating system built on SQLite, bash, Signal, and Claude Code.

Steward is an opinionated system for managing projects, actions, people, habits, and daily accountability — all from your terminal or phone via Signal.

## Architecture

- **Database**: SQLite (single file, all tables)
- **CLIs**: Bash scripts for work/project tracking, relationship management, habit tracking
- **Signal Integration**: Bidirectional messaging via signal-cli HTTP daemon + SSE
- **AI Backbone**: Claude Code for interactive sessions, `claude -p` for headless/one-shot responses
- **Check-ins**: Automated morning/midday/evening accountability via LaunchAgents (macOS)

## Features

- **Work tracking**: Projects, actions, deadlines, status history, auto-generated status dashboard
- **People**: Contact management, interaction logging, follow-up reminders, relationship frequency
- **Habits**: Daily/weekly habit tracking, streaks, weekly summaries
- **Signal**: Send commands from your phone (`habits today`, `work overdue`, `people due`), get instant responses
- **Accountability**: Automated daily check-ins that review what moved, what didn't, and what's next
- **Reading log**: Track articles/papers with reflections and monthly summaries

## Prerequisites

- macOS (uses LaunchAgents for scheduling)
- sqlite3
- python3
- signal-cli >= 0.14.0 (for Signal integration)
- Claude CLI (for AI-powered check-ins and responses)
- bash/zsh

## Quick Start

```bash
git clone https://github.com/YOUR_USER/steward.git
cd steward
./install.sh
```

## CLI Reference

### work
```bash
work projects                    # list active projects
work add "PROJECT" "description" # add action
work list [PROJECT] [--all]      # list actions
work done ID [note]              # mark done
work overdue                     # overdue actions
work generate                    # regenerate status.md
```

### people
```bash
people add "Name" context relationship [freq_days] [contact_method]
people log "Name" type "summary" [direction] [follow_up]
people due                       # who needs attention
people info "Name"               # full profile
```

### habits
```bash
habits add "name" --rule "desc" [--freq daily|weekly] [--target N]
habits check "name" y|n ["note"]
habits today                     # today's status
habits week                      # weekly summary
habits streaks                   # all active streaks
```

### Signal commands
Send any of these from Signal:
- `habits today` / `work list` / `work overdue` / `people due`
- `habits check "name" y` / `work done ID`
- `ping` / `help` / `status`
- Anything else gets queued for next session

## Philosophy

Steward is built on a few principles:
- **Local-first**: Your data lives on your machine in a single SQLite file
- **Shell scripts over frameworks**: Simple, readable, modifiable
- **AI as steward, not assistant**: It tracks commitments, names what's stalled, and pushes back
- **Practice-integrated**: Designed for people who take inner work seriously alongside outer work

## Built with

[Claude Code](https://claude.com/claude-code) by Anthropic

## License

MIT
