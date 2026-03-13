# Steward

A personal AI-powered life operating system built on DynamoDB, bash, Signal, and Claude Code.

Steward is an opinionated system for managing projects, actions, people, habits, and daily accountability — all from your terminal or phone via Signal.

## Architecture

- **Database**: AWS DynamoDB (single-table design, pay-per-request)
- **Config storage**: AWS S3 (personal config files, separate from code)
- **CLIs**: Bash scripts for work/project tracking, relationship management, habit tracking
- **Signal Integration**: Bidirectional messaging via signal-cli HTTP daemon + SSE
- **AI Backbone**: Claude Code for interactive sessions, `claude -p` for headless check-ins
- **Check-ins**: Automated morning/midday/evening accountability via LaunchAgents (macOS)

### Data separation

```
GitHub (this repo)             S3 (your config)             DynamoDB (your data)
──────────────────             ────────────────             ──────────────────
scripts/                       CLAUDE.md                    single table: steward
config-templates/              UPEKHA.md                    all entities via PK/SK
install.sh                     steward-persona.md           GSI1 for cross-queries
docs/
README.md
```

- **This repo**: shareable framework — no personal data
- **S3**: your personal config files, pulled during install
- **DynamoDB**: all structured data, accessible from any device

### DynamoDB single-table design

| Entity | PK | SK |
|--------|----|----|
| Project | `PROJECT#id` | `META` |
| Action | `PROJECT#id` | `ACTION#id` |
| Action Log | `ACTION#id` | `LOG#timestamp#id` |
| Person | `PERSON#id` | `META` |
| Interaction | `PERSON#id` | `INT#timestamp#id` |
| Activity | `ACTIVITY` | `timestamp#id` |
| Habit | `HABIT#id` | `META` |
| Habit Log | `HABIT#id` | `LOG#date` |
| Signal Queue | `SIGNAL` | `MSG#id` |
| Reading | `READING` | `ENTRY#id` |
| Counter | `COUNTER` | `entity_name` |

GSI1 enables cross-partition queries (e.g., all open actions, all active people).

## Features

- **Work tracking**: Projects, actions, deadlines, status history, auto-generated status dashboard
- **People**: Contact management, interaction logging, follow-up reminders, relationship frequency
- **Habits**: Daily/weekly habit tracking, streaks, weekly summaries
- **Signal**: Send commands from your phone (`habits today`, `work overdue`, `people due`), get instant responses
- **Accountability**: Automated daily check-ins that review what moved, what didn't, and what's next
- **Reading log**: Track articles/papers with reflections and monthly summaries
- **Multi-device**: DynamoDB backend means any device with AWS credentials can read/write

## Prerequisites

- macOS (uses LaunchAgents for scheduling)
- AWS CLI + credentials (IAM user with DynamoDB + S3 access)
- python3 + boto3
- jq
- signal-cli >= 0.14.0 (for Signal integration)
- Claude CLI (for AI-powered check-ins)

## Quick Start

```bash
git clone https://github.com/YOUR_USER/steward.git
cd steward
./install.sh
```

The installer will:
1. Create a DynamoDB table (`steward`) and S3 config bucket
2. Pull personal config from S3 (or create from templates)
3. Install CLI scripts and create symlinks
4. Set up LaunchAgent plists for automated check-ins

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

## Cost

At typical personal usage (~100-500 DynamoDB requests/day):
- **DynamoDB**: Free tier covers 25 RCU + 25 WCU. On-demand: ~$0.01-0.05/day
- **S3**: ~$0.01/month (a few KB of config files)
- **Total**: Under $2/month

## Philosophy

- **Cloud-native**: Your data syncs across devices via DynamoDB
- **Shell scripts over frameworks**: Simple, readable, modifiable
- **AI as steward, not assistant**: It tracks commitments, names what's stalled, and pushes back
- **Practice-integrated**: Designed for people who take inner work seriously alongside outer work
- **Data separation**: Personal data never touches the repo

## Built with

[Claude Code](https://claude.com/claude-code) by Anthropic

## License

MIT
