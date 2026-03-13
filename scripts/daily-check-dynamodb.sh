#!/bin/bash
# Morning steward review — runs via launchd at 8am
# Deep review of all projects, trajectory check, recommendation
# DynamoDB backend version

export HOME="/Users/koenbiggelaar"
# Include nvm path for claude CLI
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"
unset CLAUDECODE
unset CLAUDE_CODE_ENTRYPOINT

CLAUDE="$(which claude)"
PHONE="+31642152289"
PROJECT_DIR="$HOME/projects"
PERSONA="$HOME/.claude/steward-persona.md"
LOG="$HOME/.claude/cron.log"
COMBINED_OUTPUT="/tmp/steward-morning-combined.txt"

echo "$(date): daily-check-dynamodb.sh starting" >> "$LOG"

PERSONA_TEXT=$(cat "$PERSONA" 2>/dev/null)
if [ -z "$PERSONA_TEXT" ]; then
  echo "$(date): ERROR — persona file missing or empty" >> "$LOG"
  exit 1
fi

# --- DynamoDB data gathering ---

# Activity log (last 3 days) + total hours via Python/boto3
PYTHON_OUTPUT=$(python3 - <<'PYEOF'
import boto3, json, sys
from datetime import datetime, timedelta
from decimal import Decimal

ddb = boto3.resource('dynamodb', region_name='us-east-1')
table = ddb.Table('steward')

cutoff = (datetime.now() - timedelta(days=3)).strftime('%Y-%m-%d')

response = table.query(
    KeyConditionExpression='PK = :pk AND SK >= :cutoff',
    ExpressionAttributeValues={
        ':pk': 'ACTIVITY',
        ':cutoff': cutoff,
    },
)

items = response.get('Items', [])
while response.get('LastEvaluatedKey'):
    response = table.query(
        KeyConditionExpression='PK = :pk AND SK >= :cutoff',
        ExpressionAttributeValues={
            ':pk': 'ACTIVITY',
            ':cutoff': cutoff,
        },
        ExclusiveStartKey=response['LastEvaluatedKey'],
    )
    items.extend(response.get('Items', []))

total_min = 0
lines = []
if items:
    lines.append("timestamp|project|category|activity|duration_min|notes")
    for item in sorted(items, key=lambda x: x.get('timestamp', '')):
        ts = item.get('timestamp', '')
        proj = item.get('project', '')
        cat = item.get('category', '')
        act = item.get('activity', '')
        dur = int(item.get('duration_min', 0))
        notes = item.get('notes', '')
        total_min += dur
        lines.append(f"{ts}|{proj}|{cat}|{act}|{dur}|{notes}")

activity_text = '\n'.join(lines) if lines else ''
total_hours = f"{total_min / 60.0:.1f}"

print(activity_text)
print('---SEPARATOR---')
print(total_hours)
PYEOF
)

RECENT_ACTIVITY=$(echo "$PYTHON_OUTPUT" | sed '/^---SEPARATOR---$/,$d')
TOTAL_HOURS=$(echo "$PYTHON_OUTPUT" | sed -n '/^---SEPARATOR---$/,$ p' | tail -1)

# People who need attention (uses DynamoDB-backed CLI)
PEOPLE_DUE=$(people due 2>/dev/null)

# Upcoming birthdays (uses DynamoDB-backed CLI)
UPCOMING_BIRTHDAYS=$(people birthdays 2>/dev/null)

# People KPI: entries added yesterday + total people
PEOPLE_KPI=$(python3 - <<'PYEOF'
import boto3
from datetime import datetime, timedelta

ddb = boto3.resource('dynamodb', region_name='us-east-1')
table = ddb.Table('steward')

yesterday = (datetime.now() - timedelta(days=1)).strftime('%Y-%m-%d')

# People added yesterday: scan for entity_type=person, added_at starts with yesterday
people_resp = table.scan(
    FilterExpression='entity_type = :et AND begins_with(added_at, :d)',
    ExpressionAttributeValues={
        ':et': 'person',
        ':d': yesterday,
    },
    Select='COUNT',
)
yesterday_people = people_resp.get('Count', 0)

# Interactions logged yesterday: scan for entity_type=interaction, timestamp starts with yesterday
int_resp = table.scan(
    FilterExpression='entity_type = :et AND begins_with(#ts, :d)',
    ExpressionAttributeNames={'#ts': 'timestamp'},
    ExpressionAttributeValues={
        ':et': 'interaction',
        ':d': yesterday,
    },
    Select='COUNT',
)
yesterday_interactions = int_resp.get('Count', 0)

# Total active people: scan for entity_type=person, archived=0
total_resp = table.scan(
    FilterExpression='entity_type = :et AND (attribute_not_exists(archived) OR archived = :z)',
    ExpressionAttributeValues={
        ':et': 'person',
        ':z': 0,
    },
    Select='COUNT',
)
total_people = total_resp.get('Count', 0)

print(f"{yesterday_people}")
print(f"{yesterday_interactions}")
print(f"{total_people}")
PYEOF
)

YESTERDAY_PEOPLE_ADDED=$(echo "$PEOPLE_KPI" | sed -n '1p')
YESTERDAY_INTERACTIONS=$(echo "$PEOPLE_KPI" | sed -n '2p')
TOTAL_PEOPLE=$(echo "$PEOPLE_KPI" | sed -n '3p')

# --- Build prompt ---

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
4. Whether the three institutional threads (HU, IE, TEC) are getting appropriate attention
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
