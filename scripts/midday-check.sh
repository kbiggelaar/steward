#!/bin/bash
# Midday steward review — runs via launchd at 1pm
# Progress check: what's done, what needs attention, course-correct

# Include nvm path for claude CLI
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"
unset CLAUDECODE
unset CLAUDE_CODE_ENTRYPOINT

CLAUDE="$(which claude)"
PROJECT_DIR="$HOME/projects"
PERSONA="$HOME/.claude/steward-persona.md"
LOG="$HOME/.claude/cron.log"
COMBINED_OUTPUT="/tmp/steward-midday-combined.txt"

echo "$(date): midday-check.sh starting" >> "$LOG"

PERSONA_TEXT=$(cat "$PERSONA" 2>/dev/null)
if [ -z "$PERSONA_TEXT" ]; then
  echo "$(date): ERROR — persona file missing or empty" >> "$LOG"
  exit 1
fi

ACTIVITY_DB="$HOME/.claude/activity.db"
PEOPLE_DUE=""
if [ -f "$ACTIVITY_DB" ]; then
  TODAY_ACTIVITY=$(sqlite3 -header "$ACTIVITY_DB" "
    SELECT timestamp, project, category, activity, duration_min, notes
    FROM activity_log
    WHERE date(timestamp) = date('now', 'localtime')
    ORDER BY timestamp;
  " 2>/dev/null)
  TODAY_HOURS=$(sqlite3 "$ACTIVITY_DB" "
    SELECT printf('%.1f', COALESCE(SUM(duration_min), 0)/60.0)
    FROM activity_log
    WHERE date(timestamp) = date('now', 'localtime');
  " 2>/dev/null)
  # People overdue — quick reminder at midday
  PEOPLE_DUE=$(sqlite3 -header "$ACTIVITY_DB" "SELECT name, context, days_since FROM v_reach_out WHERE days_until_due <= 0;" 2>/dev/null)
fi

PROMPT_FILE=$(mktemp)
cat > "$PROMPT_FILE" << ENDOFPROMPT
$PERSONA_TEXT

---

MIDDAY CHECK-IN — $(date '+%A, %B %d, %Y')

## TODAY'S ACTIVITY LOG (so far)
Hours logged today: ${TODAY_HOURS:-0}

${TODAY_ACTIVITY:-No activity logged today yet.}

## PEOPLE — Overdue for contact
${PEOPLE_DUE:-No one overdue.}

---

This is the midday check-in. Read work/status.md and any project files in work/. Check today's git log. Read the activity log above.

Then write your midday message. Focus on:
1. What has been accomplished so far today — check BOTH the activity log AND git commits
2. What's the most important thing to focus on for the rest of the day
3. Any deadlines that need attention today or tomorrow
4. If the morning was scattered or unfocused, name it and suggest a reset
5. If anyone is overdue for contact, suggest a quick reach-out — even a short message counts
6. A short, direct nudge — not a recap

CRITICAL OUTPUT INSTRUCTIONS:
- Your FINAL response must be ONLY the plain text message to send. No preamble. Just the message itself.
- Do NOT try to send the message yourself. Do NOT use any tools in your final response.
- If nothing useful to say, output exactly: SKIP
- Plain text only. No markdown. No asterisks. No headers.
ENDOFPROMPT

$CLAUDE -p "$(cat "$PROMPT_FILE")" \
  --allowedTools "Read,Glob,Grep,Bash" \
  --max-turns 25 \
  -d "$PROJECT_DIR" > "$COMBINED_OUTPUT" 2>&1

EXIT_CODE=$?
DIGEST=$(cat "$COMBINED_OUTPUT" 2>/dev/null)
echo "$(date): claude exit code: $EXIT_CODE, output length: ${#DIGEST}" >> "$LOG"
echo "$(date): === FULL OUTPUT ===" >> "$LOG"
echo "$DIGEST" >> "$LOG"
echo "$(date): === END OUTPUT ===" >> "$LOG"

if [ $EXIT_CODE -ne 0 ]; then
  echo "$(date): SKIPPED — claude exited with error code $EXIT_CODE" >> "$LOG"
  rm -f "$PROMPT_FILE" "$COMBINED_OUTPUT"
  exit 1
fi

if [ -z "$DIGEST" ]; then
  echo "$(date): SKIPPED — empty output" >> "$LOG"
  rm -f "$PROMPT_FILE" "$COMBINED_OUTPUT"
  exit 0
fi

if echo "$DIGEST" | grep -qi "API Error\|Internal server error\|api_error\|rate_limit"; then
  echo "$(date): SKIPPED — output contains API error" >> "$LOG"
  rm -f "$PROMPT_FILE" "$COMBINED_OUTPUT"
  exit 1
fi

if echo "$DIGEST" | grep -q "^---$"; then
  MESSAGE=$(echo "$DIGEST" | awk '/^---$/{buf=""; next} {buf=buf"\n"$0} END{print buf}' | sed '/^$/d' | sed 's/^[[:space:]]*//')
else
  MESSAGE="$DIGEST"
fi

MESSAGE=$(echo "$MESSAGE" | grep -v "^Here's the midday" | grep -v "^Want me to send" | grep -v "^I've now read" | grep -v "^Let me compose" | sed '/^$/{ N; /^\n$/d; }')
MESSAGE=$(echo "$MESSAGE" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

if [ -z "$MESSAGE" ]; then
  echo "$(date): SKIPPED — message empty after parsing" >> "$LOG"
  rm -f "$PROMPT_FILE" "$COMBINED_OUTPUT"
  exit 0
fi

if [ "$MESSAGE" = "SKIP" ]; then
  echo "$(date): SKIPPED — steward said SKIP" >> "$LOG"
  rm -f "$PROMPT_FILE" "$COMBINED_OUTPUT"
  exit 0
fi

echo "$MESSAGE" | "$HOME/.claude/signal-send.sh" 2>>"$LOG"
echo "$(date): Signal sent OK" >> "$LOG"

rm -f "$PROMPT_FILE" "$COMBINED_OUTPUT"
