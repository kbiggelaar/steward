#!/bin/bash
# Signal Send — sends a message via signal-cli daemon HTTP API
# Used by cron check-in scripts and manual sends.
#
# Usage:
#   echo "message" | signal-send
#   signal-send "message text"

export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"

# Set STEWARD_PHONE in your environment or via install.sh
PHONE="${STEWARD_PHONE:-YOUR_PHONE_NUMBER}"
RPC_URL="http://localhost:8080/api/v1/rpc"
LOG="$HOME/.claude/cron.log"

# Get message from args or stdin
if [ -n "$1" ]; then
  MESSAGE="$1"
else
  MESSAGE=$(cat)
fi

if [ -z "$MESSAGE" ]; then
  echo "$(date): signal-send: no message to send" >> "$LOG"
  exit 1
fi

# JSON-escape the message using python3 for reliability
ESCAPED=$(python3 -c "
import json, sys
text = sys.stdin.read()
# json.dumps produces a quoted string; strip the outer quotes
print(json.dumps(text)[1:-1])
" <<< "$MESSAGE")

RESPONSE=$(curl -s -X POST "$RPC_URL" \
  -H "content-type: application/json" \
  -d "{\"jsonrpc\":\"2.0\",\"method\":\"send\",\"id\":\"$(date +%s)\",\"params\":{\"recipients\":[\"$PHONE\"],\"message\":\"$ESCAPED\"}}" 2>>"$LOG")

EXIT_CODE=$?

if [ $EXIT_CODE -ne 0 ]; then
  echo "$(date): signal-send: ERROR — curl failed (exit code: $EXIT_CODE)" >> "$LOG"
  exit 1
fi

# Check for JSON-RPC error in response
if echo "$RESPONSE" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); sys.exit(0 if 'error' not in d else 1)" 2>/dev/null; then
  echo "$(date): signal-send: sent OK (${#MESSAGE} chars)" >> "$LOG"
else
  echo "$(date): signal-send: ERROR — RPC error: $RESPONSE" >> "$LOG"
  exit 1
fi
