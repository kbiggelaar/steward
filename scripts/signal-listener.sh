#!/bin/bash
# Signal Listener — connects to signal-cli daemon SSE endpoint, routes commands
# Replaces the polling-based signal-daemon.sh
# Managed by signal-ctl.sh and LaunchAgent
#
# Architecture:
#   - Connects to signal-cli daemon HTTP SSE endpoint
#   - Parses JSON-RPC notifications for incoming messages
#   - Routes recognized commands to CLI tools
#   - Queues unrecognized messages for next Claude Code session
#   - Sends replies via HTTP JSON-RPC

export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"

# --- Configuration ---
# Set STEWARD_PHONE in your environment or via install.sh
PHONE="${STEWARD_PHONE:-YOUR_PHONE_NUMBER}"
ALLOWED_SENDERS=("$PHONE")
DB="$HOME/.claude/activity.db"
LOG="$HOME/.claude/signal-listener.log"
PID_FILE="$HOME/.claude/signal-listener.pid"
DAEMON_URL="http://localhost:8080"
SSE_URL="${DAEMON_URL}/api/v1/events"
RPC_URL="${DAEMON_URL}/api/v1/rpc"
HEALTH_URL="${DAEMON_URL}/api/v1/check"
WORK="$HOME/.claude/work.sh"
PEOPLE="$HOME/.claude/people.sh"
HABITS="$HOME/.claude/habits.sh"

# Reconnect delay in seconds
RECONNECT_DELAY=5
# Health check timeout before starting SSE
HEALTH_TIMEOUT=60

# --- Logging ---
log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') [listener] $1" >> "$LOG"
}

log_error() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') [listener] ERROR: $1" >> "$LOG"
}

# --- Database setup ---
init_db() {
  sqlite3 "$DB" "CREATE TABLE IF NOT EXISTS signal_queue (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    sender TEXT,
    message TEXT,
    received_at TEXT DEFAULT (datetime('now','localtime')),
    processed INTEGER DEFAULT 0,
    processed_at TEXT,
    response TEXT
  );"
  log "Database table signal_queue ensured"
}

# --- JSON escape for sending messages ---
json_escape() {
  local text="$1"
  python3 -c "
import json, sys
print(json.dumps(sys.stdin.read())[1:-1])
" <<< "$text"
}

# --- Sender validation ---
is_allowed_sender() {
  local sender="$1"
  for allowed in "${ALLOWED_SENDERS[@]}"; do
    if [ "$sender" = "$allowed" ]; then
      return 0
    fi
  done
  return 1
}

# --- Send reply via HTTP JSON-RPC ---
send_reply() {
  local message="$1"
  if [ -z "$message" ]; then return; fi

  # Truncate very long messages for Signal (max ~2000 chars)
  if [ ${#message} -gt 2000 ]; then
    message="${message:0:1950}

[truncated — run full command in terminal]"
  fi

  local escaped
  escaped=$(json_escape "$message")

  local response
  response=$(curl -s -X POST "$RPC_URL" \
    -H "content-type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"send\",\"id\":\"$(date +%s)\",\"params\":{\"recipients\":[\"$PHONE\"],\"message\":\"$escaped\"}}" 2>>"$LOG")

  if [ $? -ne 0 ]; then
    log_error "Failed to send reply via HTTP"
  else
    log "Reply sent (${#message} chars)"
  fi
}

# --- Command routing ---
route_command() {
  local message="$1"
  local sender="$2"

  # Normalize: trim whitespace, lowercase for matching
  local cmd
  cmd=$(echo "$message" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  local cmd_lower
  cmd_lower=$(echo "$cmd" | tr '[:upper:]' '[:lower:]')

  log "Routing command: '$cmd' from $sender"

  local output=""

  case "$cmd_lower" in
    "habits today")
      output=$($HABITS today 2>&1)
      ;;

    habits\ check\ *)
      # Extract args: habits check "name" y
      local args="${cmd#habits check }"
      if [[ "$args" =~ ^\"(.+)\"[[:space:]]+(y|n)(.*)$ ]]; then
        local habit_name="${BASH_REMATCH[1]}"
        local done_val="${BASH_REMATCH[2]}"
        local note="${BASH_REMATCH[3]}"
        note=$(echo "$note" | sed 's/^[[:space:]]*//')
        output=$($HABITS check "$habit_name" "$done_val" "$note" 2>&1)
      elif [[ "$args" =~ ^([^[:space:]]+)[[:space:]]+(y|n)(.*)$ ]]; then
        local habit_name="${BASH_REMATCH[1]}"
        local done_val="${BASH_REMATCH[2]}"
        local note="${BASH_REMATCH[3]}"
        note=$(echo "$note" | sed 's/^[[:space:]]*//')
        output=$($HABITS check "$habit_name" "$done_val" "$note" 2>&1)
      else
        output="Usage: habits check \"name\" y|n [\"note\"]"
      fi
      ;;

    habits\ miss\ *)
      local args="${cmd#habits miss }"
      if [[ "$args" =~ ^\"(.+)\"(.*)$ ]]; then
        local habit_name="${BASH_REMATCH[1]}"
        local note="${BASH_REMATCH[2]}"
        note=$(echo "$note" | sed 's/^[[:space:]]*//')
        output=$($HABITS miss "$habit_name" "$note" 2>&1)
      else
        local habit_name=$(echo "$args" | awk '{print $1}')
        local note=$(echo "$args" | awk '{$1=""; print}' | sed 's/^[[:space:]]*//')
        output=$($HABITS miss "$habit_name" "$note" 2>&1)
      fi
      ;;

    "habits streaks")
      output=$($HABITS streaks 2>&1)
      ;;

    "habits week")
      output=$($HABITS week 2>&1)
      ;;

    "habits list")
      output=$($HABITS list 2>&1)
      ;;

    "work list")
      output=$($WORK list 2>&1)
      ;;

    "work overdue")
      output=$($WORK overdue 2>&1)
      ;;

    "work projects")
      output=$($WORK projects 2>&1)
      ;;

    "status")
      output=$($WORK status 2>&1)
      output=$(echo "$output" | sed 's/\*\*//g; s/^#\+[[:space:]]*//' | head -60)
      ;;

    "people due")
      output=$($PEOPLE due 2>&1)
      ;;

    "people list")
      output=$($PEOPLE list 2>&1)
      ;;

    "people birthdays")
      output=$($PEOPLE birthdays 2>&1)
      ;;

    people\ info\ *)
      local name="${cmd#people info }"
      name=$(echo "$name" | sed 's/^"//;s/"$//')
      output=$($PEOPLE info "$name" 2>&1)
      ;;

    people\ log\ *)
      local args="${cmd#people log }"
      if [[ "$args" =~ ^\"(.+)\"[[:space:]]+([^[:space:]]+)[[:space:]]+\"(.+)\"(.*)$ ]]; then
        local name="${BASH_REMATCH[1]}"
        local type="${BASH_REMATCH[2]}"
        local summary="${BASH_REMATCH[3]}"
        output=$($PEOPLE log "$name" "$type" "$summary" 2>&1)
      else
        output="Usage: people log \"Name\" type \"summary\""
      fi
      ;;

    work\ done\ *)
      local args="${cmd#work done }"
      local aid=$(echo "$args" | awk '{print $1}')
      local note=$(echo "$args" | awk '{$1=""; print}' | sed 's/^[[:space:]]*//')
      output=$($WORK done "$aid" "$note" 2>&1)
      ;;

    work\ start\ *)
      local aid="${cmd#work start }"
      aid=$(echo "$aid" | awk '{print $1}')
      output=$($WORK start "$aid" 2>&1)
      ;;

    "help"|"commands"|"?")
      output="Signal Steward Commands:

habits today — today's habit status
habits check \"name\" y|n — log habit
habits miss \"name\" — log miss
habits streaks — all streaks
habits week — weekly summary

work list — open actions
work overdue — overdue actions
work projects — active projects
work done ID — mark action done
work start ID — start action
status — full status summary

people due — who needs attention
people list — all people
people birthdays — upcoming birthdays
people info \"name\" — person details
people log \"name\" type \"summary\"

help — this message

Anything else gets queued for next session."
      ;;

    "queue"|"queued")
      local count
      count=$(sqlite3 "$DB" "SELECT COUNT(*) FROM signal_queue WHERE processed=0;" 2>/dev/null)
      if [ "$count" -gt 0 ]; then
        output="$count queued message(s):
$(sqlite3 "$DB" "SELECT id || '. [' || received_at || '] ' || message FROM signal_queue WHERE processed=0 ORDER BY received_at;" 2>/dev/null)"
      else
        output="No queued messages."
      fi
      ;;

    "ping")
      output="Steward listener is running (HTTP/SSE mode)."
      ;;

    *)
      # Unrecognized — queue for next session
      sqlite3 "$DB" "INSERT INTO signal_queue (sender, message) VALUES ('$(echo "$sender" | sed "s/'/''/g")', '$(echo "$cmd" | sed "s/'/''/g")');"
      output="Noted — will pick up in next session."
      log "Queued message: '$cmd'"
      ;;
  esac

  # Send the response
  if [ -n "$output" ]; then
    send_reply "$output"
  fi
}

# --- Process an SSE event ---
process_event() {
  local json_data="$1"

  if [ -z "$json_data" ]; then return; fi

  # Parse the JSON-RPC notification using python3
  local parsed
  parsed=$(python3 -c "
import json, sys
try:
    data = json.loads(sys.stdin.read())
    # SSE data can be either:
    # 1. Raw envelope: {\"envelope\": {...}, \"account\": ...}
    # 2. JSON-RPC notification: {\"jsonrpc\":\"2.0\", \"method\":\"receive\", \"params\":{\"envelope\":...}}
    if 'params' in data:
        envelope = data['params'].get('envelope', {})
    elif 'envelope' in data:
        envelope = data['envelope']
    else:
        sys.exit(0)
    source = envelope.get('source', '') or envelope.get('sourceNumber', '')
    # Try dataMessage first
    msg_data = envelope.get('dataMessage', {})
    body = msg_data.get('message', '') if msg_data else ''
    # Try syncMessage if no dataMessage
    if not body:
        sync = envelope.get('syncMessage', {})
        if sync:
            sent = sync.get('sentMessage', {})
            body = sent.get('message', '') if sent else ''
            if body:
                source = envelope.get('source', '') or os.environ.get('STEWARD_PHONE', '')
    if source and body:
        print(f'{source}|{body}')
except Exception:
    pass
" <<< "$json_data" 2>/dev/null)

  if [ -z "$parsed" ]; then return; fi

  local sender="${parsed%%|*}"
  local body="${parsed#*|}"

  if [ -z "$sender" ] || [ -z "$body" ]; then return; fi

  log "Received message from $sender: ${body:0:100}"

  # Check whitelist
  if ! is_allowed_sender "$sender"; then
    log "Ignoring message from unauthorized sender: $sender"
    return
  fi

  # Route the command
  route_command "$body" "$sender"
}

# --- Wait for daemon health ---
wait_for_daemon() {
  log "Waiting for signal-cli daemon to be healthy..."
  local waited=0
  while [ "$waited" -lt "$HEALTH_TIMEOUT" ]; do
    if curl -s --max-time 2 "$HEALTH_URL" >/dev/null 2>&1; then
      log "Daemon is healthy"
      return 0
    fi
    sleep 2
    waited=$((waited + 2))
  done
  log_error "Daemon not healthy after ${HEALTH_TIMEOUT}s"
  return 1
}

# --- Main loop ---
main() {
  log "=== Signal listener starting (PID: $$) ==="

  # Write PID file
  echo $$ > "$PID_FILE"

  # Initialize database
  init_db

  # Trap for clean shutdown
  trap 'log "Listener stopping (PID: $$)"; rm -f "$PID_FILE"; exit 0' SIGTERM SIGINT SIGHUP

  # Wait for the daemon to be ready
  if ! wait_for_daemon; then
    log_error "Exiting — daemon not available"
    rm -f "$PID_FILE"
    exit 1
  fi

  # Main reconnect loop
  while true; do
    log "Connecting to SSE endpoint: $SSE_URL"

    # Connect to SSE and process events
    # Use a FIFO to avoid pipe buffering issues on macOS (no stdbuf)
    local fifo="/tmp/signal-sse-fifo.$$"
    rm -f "$fifo"
    mkfifo "$fifo"

    # Start curl in background writing to FIFO
    curl -N -s "$SSE_URL" > "$fifo" 2>>"$LOG" &
    local curl_pid=$!

    # Read from FIFO in foreground
    while IFS= read -r line; do
      # Strip carriage return if present
      line="${line%$'\r'}"
      # SSE format: lines starting with "data:" contain JSON payload
      if [[ "$line" == data:* ]]; then
        local json_data="${line#data:}"
        json_data="${json_data# }"

        if [ -n "$json_data" ]; then
          log "SSE event received (${#json_data} bytes)"
          process_event "$json_data"
        fi
      fi
    done < "$fifo"

    # Clean up
    kill "$curl_pid" 2>/dev/null
    rm -f "$fifo"

    # If we get here, curl exited (connection lost)
    log "SSE connection lost. Reconnecting in ${RECONNECT_DELAY}s..."
    sleep "$RECONNECT_DELAY"

    # Re-check daemon health before reconnecting
    if ! wait_for_daemon; then
      log_error "Daemon not available after reconnect wait, retrying..."
    fi
  done
}

# Run
main
