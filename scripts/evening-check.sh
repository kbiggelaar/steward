#!/bin/bash
# Evening steward review — runs via launchd at 5pm
# Accountability check: what moved, what didn't, pattern recognition

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
COMBINED_OUTPUT="/tmp/steward-evening-combined.txt"

echo "$(date): evening-check.sh starting" >> "$LOG"

PERSONA_TEXT=$(cat "$PERSONA" 2>/dev/null)
if [ -z "$PERSONA_TEXT" ]; then
  echo "$(date): ERROR — persona file missing or empty" >> "$LOG"
  exit 1
fi

ACTIVITY_DB="$HOME/.claude/activity.db"
TODAY_INTERACTIONS=""
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
  WEEK_HOURS=$(sqlite3 "$ACTIVITY_DB" "
    SELECT printf('%.1f', COALESCE(SUM(duration_min), 0)/60.0)
    FROM activity_log
    WHERE timestamp >= datetime('now', '-7 days', 'localtime');
  " 2>/dev/null)
  WEEK_BREAKDOWN=$(sqlite3 "$ACTIVITY_DB" "
    SELECT project, printf('%.1f hrs', SUM(duration_min)/60.0) as hours
    FROM activity_log
    WHERE timestamp >= datetime('now', '-7 days', 'localtime')
    GROUP BY project ORDER BY SUM(duration_min) DESC;
  " 2>/dev/null)
  # Today's people interactions
  TODAY_INTERACTIONS=$(sqlite3 -header "$ACTIVITY_DB" "
    SELECT p.name, i.type, i.summary
    FROM interactions i JOIN people p ON p.id = i.person_id
    WHERE date(i.timestamp) = date('now', 'localtime')
    ORDER BY i.timestamp;
  " 2>/dev/null)
  # People still overdue
  PEOPLE_DUE=$(sqlite3 -header "$ACTIVITY_DB" "SELECT name, context, days_since, days_until_due FROM v_reach_out;" 2>/dev/null)
  # People KPI: today's entries
  TODAY_PEOPLE_ADDED=$(sqlite3 "$ACTIVITY_DB" "SELECT COUNT(*) FROM people WHERE date(added_at) = date('now', 'localtime');" 2>/dev/null)
  TODAY_INTERACTIONS_COUNT=$(sqlite3 "$ACTIVITY_DB" "SELECT COUNT(*) FROM interactions WHERE date(timestamp) = date('now', 'localtime');" 2>/dev/null)
  TOTAL_PEOPLE=$(sqlite3 "$ACTIVITY_DB" "SELECT COUNT(*) FROM people WHERE archived=0;" 2>/dev/null)
fi

PROMPT_FILE=$(mktemp)
cat > "$PROMPT_FILE" << ENDOFPROMPT
$PERSONA_TEXT

---

EVENING REVIEW — $(date '+%A, %B %d, %Y')

## TODAY'S ACTIVITY LOG
Hours logged today: ${TODAY_HOURS:-0}
Hours logged this week: ${WEEK_HOURS:-0}

${TODAY_ACTIVITY:-No activity logged today.}

Weekly breakdown by project:
${WEEK_BREAKDOWN:-No data.}

## PEOPLE — Today's interactions
${TODAY_INTERACTIONS:-No interactions logged today.}

## PEOPLE — Still overdue
${PEOPLE_DUE:-No one overdue.}

## PEOPLE KPI — Target: 2 new entries daily (people or interactions)
Today: ${TODAY_PEOPLE_ADDED:-0} people added, ${TODAY_INTERACTIONS_COUNT:-0} interactions logged
Total network: ${TOTAL_PEOPLE:-0} people tracked

---

This is the evening accountability review. Read work/status.md and project files in work/. Read the activity log above first — it captures work that git misses. Then check git log for today.

Then write your evening message. Focus on:
1. What actually moved today — check BOTH the activity log AND git commits
2. What was supposed to happen but didn't
3. Pattern recognition: is this part of a streak (good or bad)? How is this week looking across all active projects?
4. The single most important thing for tomorrow
5. Check the practice dimension — if healthy routines are being skipped, name it
6. People: note who was reached out to today. If people are overdue and weren't contacted, mention it briefly. If no interactions were logged at all, gently remind to log any conversations that happened today.
7. People KPI: the target is minimum 2 new entries per day (new people added OR interactions logged). Check today's numbers. If under target, name it directly. This is a daily practice, not optional.

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

MESSAGE=$(echo "$MESSAGE" | grep -v "^Here's the evening" | grep -v "^Want me to send" | grep -v "^I've now read" | grep -v "^Let me compose" | sed '/^$/{ N; /^\n$/d; }')
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
