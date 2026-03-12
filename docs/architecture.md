# Steward Architecture — Design Decisions & Knowledge

## Current Stack
- **Database**: SQLite at `~/.claude/activity.db` (single file, all tables)
- **CLIs**: work.sh, people.sh, habits.sh (bash, symlinked to /opt/homebrew/bin)
- **Signal**: signal-cli 0.14.0 in HTTP daemon mode (localhost:8080), SSE listener, FIFO-based
- **Check-ins**: LaunchAgents (morning 8am, midday 1pm, evening 7:30pm)
- **AI backbone**: Claude Code (interactive sessions) + `claude -p` (headless/one-shot)

## Signal Architecture

- signal-cli runs as persistent JVM daemon: `signal-cli daemon --http=localhost:8080`
- Three HTTP endpoints: `/api/v1/events` (SSE), `/api/v1/rpc` (JSON-RPC), `/api/v1/check` (health)
- Listener reads SSE via FIFO (macOS has no stdbuf — pipe buffering workaround)
- SSE data format: raw envelope JSON (not JSON-RPC wrapped) — parser must handle both
- Sends via `curl POST` to `/api/v1/rpc` — no lock files needed
- Key debug lesson: `curl | while read` creates subshell buffering issues. FIFO fixes this.

## Multi-Device Architecture (planned)

### The Session Routing Problem
Claude Code sessions are terminal processes — interactive, stateful, no external API.
Multiple sessions can run simultaneously across devices. Signal is a single channel.
Question: how does a Signal approval route back to the correct session?

### Three Levels of Signal Integration
1. **CLI commands** (done): Signal -> listener -> runs work.sh/habits.sh/people.sh directly. No session.
2. **AI responses** (next): Signal -> listener -> `claude -p` one-shot invocation. Stateless, no routing needed.
3. **Approval flow** (future): Requires middleware.

### Approval Flow Design
```
DynamoDB: approvals table (id, session_id, device, action, status, response)

Claude Code hooks (pre-tool):
  -> INSERT approval request with unique ID
  -> Signal message: "Session A wants to git push. Reply: approve 7a3f"
  -> Poll DynamoDB for response (timeout 60s)

Signal listener:
  -> User replies "approve 7a3f"
  -> UPDATE approvals SET status=approved WHERE id=7a3f

Hook reads approval -> proceeds or blocks
```

Session routing solved by unique approval IDs — no need to know which session, just match the ID.

### Cloud Migration (decision pending)
- Needed for: multi-device sync, approval flow, redundancy
- Options: DynamoDB (clean, native multi-device) vs SQLite sync (simpler)
- All CLIs would need to switch from `sqlite3` calls to AWS SDK/API
- Cost: pennies at current volume (<$0.50/month)

## Target State: Stateless Devices, Stateful Cloud

**Principle: devices are stateless workers, cloud is the single source of truth.**

```
Cloud (stateful):
  DynamoDB: all tables (activity_log, people, interactions, projects,
            actions, habits, habit_log, reading_log, signal_queue, approvals)
  S3: backups, documents, generated files (status.md, habits.md)

Devices (stateless):
  CLI tools -> talk to DynamoDB (not local sqlite3)
  Signal daemon + listener -> talk to DynamoDB
  Claude Code sessions -> talk to DynamoDB via hooks
  Nothing stored locally that can't be rebuilt
```

Any device can die — pick up from another without losing anything.

## Key Technical Lessons
- signal-cli `--output=json` is a global flag, must go BEFORE subcommand
- SSE data from signal-cli HTTP mode is raw envelope, NOT JSON-RPC wrapped
- macOS has no `stdbuf` — use FIFO for unbuffered curl-to-read pipe
- `claude -p` cannot run inside another Claude Code session (unset CLAUDECODE env var)
- `claude -p` latency: ~3.7s for Sonnet — acceptable for Signal responses
- `local` keyword in bash only works inside functions, not in `case` blocks
