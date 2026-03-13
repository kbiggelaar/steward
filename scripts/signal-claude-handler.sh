#!/bin/bash
# Signal Claude Handler — runs claude -p for a single message
# Called by signal-listener-dynamodb.sh
# Usage: signal-claude-handler.sh "message" > output_file 2> error_file

export HOME="/Users/koenbiggelaar"
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"

# Ensure we're not detected as a nested Claude session
unset CLAUDECODE

MESSAGE="$1"
PROMPT_FILE="$HOME/.claude/signal-claude-prompt.md"
MODEL="${2:-sonnet}"
MAX_BUDGET="${3:-0.50}"

if [ -z "$MESSAGE" ]; then
  echo "Usage: signal-claude-handler.sh \"message\"" >&2
  exit 1
fi

if [ ! -f "$PROMPT_FILE" ]; then
  echo "Prompt file not found: $PROMPT_FILE" >&2
  exit 1
fi

# Build system prompt with current date
SYSTEM_PROMPT=$(sed "s/USE_CURRENT_DATE/$(date '+%Y-%m-%d (%A)')/" "$PROMPT_FILE")

# Run Claude
exec claude -p \
  --system-prompt "$SYSTEM_PROMPT" \
  --model "$MODEL" \
  --permission-mode bypassPermissions \
  --allowedTools "Bash(work:*) Bash(people:*) Bash(habits:*) Bash(aws:*) Read" \
  --max-budget-usd "$MAX_BUDGET" \
  --no-session-persistence \
  "$MESSAGE"
