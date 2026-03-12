#!/bin/bash
# Morning steward review — runs via launchd at 8am
# Deep review of all projects, trajectory check, recommendation

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
COMBINED_OUTPUT="/tmp/steward-morning-combined.txt"

echo "$(date): daily-check.sh starting" >> "$LOG"

PERSONA_TEXT=$(cat "$PERSONA" 2>/dev/null)
if [ -z "$PERSONA_TEXT" ]; then
  echo "$(date): ERROR — persona file missing or empty" >> "$LOG"
  exit 1
fi

ACTIVITY_DB="$HOME/.claude/activity.db"
RECENT_ACTIVITY=""
PEOPLE_DUE=""
UPCOMING_BIRTHDAYS=""
if [ -f "$ACTIVITY_DB" ]; then
  RECENT_ACTIVITY=$(sqlite3 -header "$ACTIVITY_DB" "
    SELECT timestamp, project, category, activity, duration_min, notes
    FROM activity_log
    WHERE timestamp >= datetime('now', '-3 days', 'localtime')
    ORDER BY timestamp;
  " 2>/dev/null)
  TOTAL_HOURS=$(sqlite3 "$ACTIVITY_DB" "
    SELECT printf('%.1f', COALESCE(SUM(duration_min), 0)/60.0)
    FROM activity_log
    WHERE timestamp >= datetime('now', '-3 days', 'localtime');
  " 2>/dev/null)
  # People who need attention (overdue or due within 7 days)
  PEOPLE_DUE=$(sqlite3 -header "$ACTIVITY_DB" "SELECT name, context, relationship, contact_method, days_since, days_until_due, notes FROM v_reach_out;" 2>/dev/null)
  # Upcoming birthdays
  UPCOMING_BIRTHDAYS=$(sqlite3 -header "$ACTIVITY_DB" "SELECT * FROM v_upcoming_dates;" 2>/dev/null)
  # People KPI: entries added yesterday
  YESTERDAY_PEOPLE_ADDED=$(sqlite3 "$ACTIVITY_DB" "SELECT COUNT(*) FROM people WHERE date(added_at) = date('now', '-1 day', 'localtime');" 2>/dev/null)
  YESTERDAY_INTERACTIONS=$(sqlite3 "$ACTIVITY_DB" "SELECT COUNT(*) FROM interactions WHERE date(timestamp) = date('now', '-1 day', 'localtime');" 2>/dev/null)
  TOTAL_PEOPLE=$(sqlite3 "$ACTIVITY_DB" "SELECT COUNT(*) FROM people WHERE archived=0;" 2>/dev/null)
fi

PROMPT_FILE=$(mktemp)
cat > "$PROMPT_FILE" << ENDOFPROMPT
$PERSONA_TEXT

---

MORNING REVIEW — $(date '+%A, %B %d, %Y')

## ACTIVITY LOG (last 3 days)
Total hours logged (last 3 days): ${TOTAL_HOURS:-0}

${RECENT_ACTIVITY:-No activity logged in the database.}

## PEOPLE — Who needs attention
${PEOPLE_DUE:-No one overdue right now.}

## UPCOMING BIRTHDAYS
${UPCOMING_BIRTHDAYS:-None in the next 14 days.}

## PEOPLE KPI — Target: 2 new entries daily (people or interactions)
Yesterday: ${YESTERDAY_PEOPLE_ADDED:-0} people added, ${YESTERDAY_INTERACTIONS:-0} interactions logged
Total network: ${TOTAL_PEOPLE:-0} people tracked

---

This is the morning review. Read work/status.md and any project files in work/. Also check the git log for the past 3 days. Read the activity log above — it captures work that git misses (meetings, writing, planning, travel).

Then write your morning message. Focus on:
1. What deserves energy TODAY specifically — the highest-leverage move, not a recap of everything open
2. Anything slipping or sitting too long — be specific
3. Any deadlines in the next 7 days
4. Whether all active projects are getting appropriate attention
5. People: if anyone is overdue for contact or has a birthday coming up, mention it naturally — suggest who to reach out to today and why
6. People KPI: the target is minimum 2 new entries per day (new people added OR interactions logged). Check yesterday's numbers and hold accountable. Growing the network is a daily practice.
7. One clear recommendation

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

MESSAGE=$(echo "$MESSAGE" | grep -v "^Here's the morning message" | grep -v "^Want me to send" | grep -v "^I've now read" | grep -v "^Let me compose" | sed '/^$/{ N; /^\n$/d; }')
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
