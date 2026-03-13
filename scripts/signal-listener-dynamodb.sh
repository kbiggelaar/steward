#!/bin/bash
# Signal Listener (DynamoDB) — connects to signal-cli daemon SSE endpoint, routes commands
# Uses DynamoDB for queue storage and PATH-based commands (work, people, habits).
#
# Architecture:
#   - Connects to signal-cli daemon HTTP SSE endpoint
#   - Parses JSON-RPC notifications for incoming messages
#   - Routes recognized commands to CLI tools (fast path)
#   - Unrecognized messages go to Claude AI via `claude -p` (smart path)
#   - Sends replies via HTTP JSON-RPC

export HOME="/Users/koenbiggelaar"
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"

# --- Configuration ---
PHONE="+31642152289"
ALLOWED_SENDERS=("$PHONE")
LOG="$HOME/.claude/signal-listener.log"
PID_FILE="$HOME/.claude/signal-listener.pid"
DAEMON_URL="http://localhost:8080"
SSE_URL="${DAEMON_URL}/api/v1/events"
RPC_URL="${DAEMON_URL}/api/v1/rpc"
HEALTH_URL="${DAEMON_URL}/api/v1/check"

# DynamoDB configuration
DYNAMODB_TABLE="steward"
AWS_REGION="${AWS_REGION:-us-east-1}"

# Claude AI configuration
CLAUDE_HANDLER="$HOME/.claude/signal-claude-handler.sh"
CLAUDE_TIMEOUT=90
CLAUDE_MODEL="sonnet"
CLAUDE_MAX_BUDGET="0.50"

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

# --- Database setup (no-op for DynamoDB — table already exists) ---
init_db() {
  log "DynamoDB mode — table '$DYNAMODB_TABLE' assumed to exist"
}

# --- JSON escape for sending messages ---
json_escape() {
  local text="$1"
  # Use python3 for reliable JSON string escaping
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

# --- DynamoDB helper: get next signal message ID ---
get_next_signal_id() {
  local result
  result=$(aws dynamodb update-item \
    --table-name "$DYNAMODB_TABLE" \
    --key '{"PK": {"S": "COUNTER"}, "SK": {"S": "signal"}}' \
    --update-expression "SET current_value = if_not_exists(current_value, :zero) + :inc" \
    --expression-attribute-values '{":zero": {"N": "0"}, ":inc": {"N": "1"}}' \
    --return-values UPDATED_NEW \
    --region "$AWS_REGION" \
    --output json 2>>"$LOG")

  if [ $? -ne 0 ]; then
    log_error "Failed to get next signal ID from DynamoDB"
    echo "0"
    return 1
  fi

  echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin)['Attributes']['current_value']['N'])" 2>/dev/null
}

# --- DynamoDB helper: queue a message ---
queue_message() {
  local sender="$1"
  local message="$2"
  local received_at
  received_at=$(date '+%Y-%m-%dT%H:%M:%S')

  local msg_id
  msg_id=$(get_next_signal_id)
  if [ "$msg_id" = "0" ] || [ -z "$msg_id" ]; then
    log_error "Could not obtain message ID, using timestamp fallback"
    msg_id=$(date +%s)
  fi

  aws dynamodb put-item \
    --table-name "$DYNAMODB_TABLE" \
    --item "{
      \"PK\": {\"S\": \"SIGNAL\"},
      \"SK\": {\"S\": \"MSG#${msg_id}\"},
      \"entity_type\": {\"S\": \"signal_message\"},
      \"sender\": {\"S\": \"${sender}\"},
      \"message\": {\"S\": $(python3 -c "import json; print(json.dumps('$message'.replace(\"'\", \"'\")))") },
      \"received_at\": {\"S\": \"${received_at}\"},
      \"processed\": {\"N\": \"0\"},
      \"GSI1PK\": {\"S\": \"SIGNAL_PROCESSED#0\"},
      \"GSI1SK\": {\"S\": \"${received_at}\"}
    }" \
    --region "$AWS_REGION" 2>>"$LOG"

  if [ $? -ne 0 ]; then
    log_error "Failed to queue message in DynamoDB"
  fi
}

# --- DynamoDB helper: query queued messages ---
query_queued_messages() {
  aws dynamodb query \
    --table-name "$DYNAMODB_TABLE" \
    --index-name GSI1 \
    --key-condition-expression "GSI1PK = :pk" \
    --expression-attribute-values '{":pk": {"S": "SIGNAL_PROCESSED#0"}}' \
    --region "$AWS_REGION" \
    --output json 2>>"$LOG"
}

# --- Claude AI handler ---
handle_with_claude() {
  local message="$1"
  log "Routing to Claude AI: '${message:0:100}'"

  if [ ! -f "$CLAUDE_HANDLER" ]; then
    log_error "Claude handler not found: $CLAUDE_HANDLER"
    return 1
  fi

  # Run handler as separate script (clean env, avoids nested session detection)
  local tmp_response
  tmp_response=$(mktemp)

  log "Starting Claude handler (model: $CLAUDE_MODEL, timeout: ${CLAUDE_TIMEOUT}s)"
  /bin/bash "$CLAUDE_HANDLER" "$message" "$CLAUDE_MODEL" "$CLAUDE_MAX_BUDGET" < /dev/null > "$tmp_response" 2>>"$LOG" &
  local claude_pid=$!
  log "Claude handler started (PID: $claude_pid)"

  # Wait up to CLAUDE_TIMEOUT seconds
  local waited=0
  while [ "$waited" -lt "$CLAUDE_TIMEOUT" ] && kill -0 "$claude_pid" 2>/dev/null; do
    sleep 1
    waited=$((waited + 1))
  done

  if kill -0 "$claude_pid" 2>/dev/null; then
    log_error "Claude timed out after ${CLAUDE_TIMEOUT}s — killing"
    kill "$claude_pid" 2>/dev/null
    sleep 1
    kill -9 "$claude_pid" 2>/dev/null
    rm -f "$tmp_response"
    return 1
  fi

  wait "$claude_pid"
  local exit_code=$?

  local response
  response=$(cat "$tmp_response")
  rm -f "$tmp_response"

  if [ $exit_code -ne 0 ]; then
    log_error "Claude exited with code $exit_code"
    return 1
  fi

  if [ -z "$response" ]; then
    log_error "Claude returned empty response"
    return 1
  fi

  # Strip any markdown formatting that Claude might add despite instructions
  response=$(echo "$response" | sed 's/\*\*//g; s/^## //; s/^# //')

  log "Claude response (${#response} chars)"
  echo "$response"
  return 0
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
      output=$(habits today 2>&1)
      ;;

    habits\ check\ *)
      # Extract args: habits check "name" y
      local args="${cmd#habits check }"
      if [[ "$args" =~ ^\"(.+)\"[[:space:]]+(y|n)(.*)$ ]]; then
        local habit_name="${BASH_REMATCH[1]}"
        local done_val="${BASH_REMATCH[2]}"
        local note="${BASH_REMATCH[3]}"
        note=$(echo "$note" | sed 's/^[[:space:]]*//')
        output=$(habits check "$habit_name" "$done_val" "$note" 2>&1)
      elif [[ "$args" =~ ^([^[:space:]]+)[[:space:]]+(y|n)(.*)$ ]]; then
        local habit_name="${BASH_REMATCH[1]}"
        local done_val="${BASH_REMATCH[2]}"
        local note="${BASH_REMATCH[3]}"
        note=$(echo "$note" | sed 's/^[[:space:]]*//')
        output=$(habits check "$habit_name" "$done_val" "$note" 2>&1)
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
        output=$(habits miss "$habit_name" "$note" 2>&1)
      else
        local habit_name=$(echo "$args" | awk '{print $1}')
        local note=$(echo "$args" | awk '{$1=""; print}' | sed 's/^[[:space:]]*//')
        output=$(habits miss "$habit_name" "$note" 2>&1)
      fi
      ;;

    "habits streaks")
      output=$(habits streaks 2>&1)
      ;;

    "habits week")
      output=$(habits week 2>&1)
      ;;

    "habits list")
      output=$(habits list 2>&1)
      ;;

    "work list")
      output=$(work list 2>&1)
      ;;

    "work overdue")
      output=$(work overdue 2>&1)
      ;;

    "work projects")
      output=$(work projects 2>&1)
      ;;

    "status")
      output=$(work status 2>&1)
      output=$(echo "$output" | sed 's/\*\*//g; s/^#\+[[:space:]]*//' | head -60)
      ;;

    "people due")
      output=$(people due 2>&1)
      ;;

    "people list")
      output=$(people list 2>&1)
      ;;

    "people birthdays")
      output=$(people birthdays 2>&1)
      ;;

    people\ info\ *)
      local name="${cmd#people info }"
      name=$(echo "$name" | sed 's/^"//;s/"$//')
      output=$(people info "$name" 2>&1)
      ;;

    people\ log\ *)
      local args="${cmd#people log }"
      if [[ "$args" =~ ^\"(.+)\"[[:space:]]+([^[:space:]]+)[[:space:]]+\"(.+)\"(.*)$ ]]; then
        local name="${BASH_REMATCH[1]}"
        local type="${BASH_REMATCH[2]}"
        local summary="${BASH_REMATCH[3]}"
        output=$(people log "$name" "$type" "$summary" 2>&1)
      else
        output="Usage: people log \"Name\" type \"summary\""
      fi
      ;;

    work\ done\ *)
      local args="${cmd#work done }"
      local aid=$(echo "$args" | awk '{print $1}')
      local note=$(echo "$args" | awk '{$1=""; print}' | sed 's/^[[:space:]]*//')
      output=$(work done "$aid" "$note" 2>&1)
      ;;

    work\ start\ *)
      local aid="${cmd#work start }"
      aid=$(echo "$aid" | awk '{print $1}')
      output=$(work start "$aid" 2>&1)
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
      local result
      result=$(query_queued_messages)
      if [ $? -ne 0 ] || [ -z "$result" ]; then
        output="Error querying queued messages."
      else
        local count
        count=$(echo "$result" | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(data.get('Count', 0))
" 2>/dev/null)
        if [ "$count" -gt 0 ]; then
          output=$(echo "$result" | python3 -c "
import json, sys
data = json.load(sys.stdin)
items = data.get('Items', [])
lines = []
for item in sorted(items, key=lambda x: x.get('GSI1SK', {}).get('S', '')):
    sk = item.get('SK', {}).get('S', '')
    msg_id = sk.replace('MSG#', '') if sk.startswith('MSG#') else sk
    received = item.get('received_at', {}).get('S', '?')
    message = item.get('message', {}).get('S', '?')
    lines.append(f'{msg_id}. [{received}] {message}')
print(f'{len(items)} queued message(s):')
print('\n'.join(lines))
" 2>/dev/null)
        else
          output="No queued messages."
        fi
      fi
      ;;

    "ping")
      output="Steward listener is running (HTTP/SSE mode, DynamoDB backend)."
      ;;

    *)
      # Unrecognized — route to Claude AI
      local ai_response
      ai_response=$(handle_with_claude "$cmd")
      if [ $? -eq 0 ] && [ -n "$ai_response" ]; then
        output="$ai_response"
      else
        # Fallback: queue for next interactive session
        queue_message "$sender" "$cmd"
        output="Couldn't process that right now — queued for next session."
        log "Claude failed, queued message: '$cmd'"
      fi
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
                source = envelope.get('source', '') or '+31642152289'
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
  log "=== Signal listener starting (PID: $$, DynamoDB backend) ==="

  # Write PID file
  echo $$ > "$PID_FILE"

  # Initialize database (no-op for DynamoDB)
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
