#!/bin/bash
# Evening steward review — runs via launchd at 5pm
# Accountability check: what moved, what didn't, pattern recognition
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
COMBINED_OUTPUT="/tmp/steward-evening-combined.txt"

echo "$(date): evening-check-dynamodb.sh starting" >> "$LOG"

PERSONA_TEXT=$(cat "$PERSONA" 2>/dev/null)
if [ -z "$PERSONA_TEXT" ]; then
  echo "$(date): ERROR — persona file missing or empty" >> "$LOG"
  exit 1
fi

# --- DynamoDB data gathering ---

# Today's activity + hours + week hours + week breakdown via Python/boto3
PYTHON_OUTPUT=$(python3 - <<'PYEOF'
import boto3
from datetime import datetime, timedelta
from decimal import Decimal
from collections import defaultdict

ddb = boto3.resource('dynamodb', region_name='us-east-1')
table = ddb.Table('steward')

today = datetime.now().strftime('%Y-%m-%d')
week_ago = (datetime.now() - timedelta(days=7)).strftime('%Y-%m-%d')

# Query all activity from last 7 days (includes today)
response = table.query(
    KeyConditionExpression='PK = :pk AND SK >= :cutoff',
    ExpressionAttributeValues={
        ':pk': 'ACTIVITY',
        ':cutoff': week_ago,
    },
)

all_items = response.get('Items', [])
while response.get('LastEvaluatedKey'):
    response = table.query(
        KeyConditionExpression='PK = :pk AND SK >= :cutoff',
        ExpressionAttributeValues={
            ':pk': 'ACTIVITY',
            ':cutoff': week_ago,
        },
        ExclusiveStartKey=response['LastEvaluatedKey'],
    )
    all_items.extend(response.get('Items', []))

# Split into today vs week
today_items = [i for i in all_items if i.get('timestamp', '').startswith(today)]
all_items_sorted = sorted(all_items, key=lambda x: x.get('timestamp', ''))

# Today's activity table
today_min = 0
today_lines = []
if today_items:
    today_lines.append("timestamp|project|category|activity|duration_min|notes")
    for item in sorted(today_items, key=lambda x: x.get('timestamp', '')):
        ts = item.get('timestamp', '')
        proj = item.get('project', '')
        cat = item.get('category', '')
        act = item.get('activity', '')
        dur = int(item.get('duration_min', 0))
        notes = item.get('notes', '')
        today_min += dur
        today_lines.append(f"{ts}|{proj}|{cat}|{act}|{dur}|{notes}")

# Week totals
week_min = sum(int(i.get('duration_min', 0)) for i in all_items)

# Week breakdown by project
project_min = defaultdict(int)
for item in all_items:
    proj = item.get('project', 'unknown')
    project_min[proj] += int(item.get('duration_min', 0))

breakdown_lines = []
for proj, mins in sorted(project_min.items(), key=lambda x: -x[1]):
    breakdown_lines.append(f"{proj}|{mins / 60.0:.1f} hrs")

# Output sections separated by markers
print('\n'.join(today_lines) if today_lines else '')
print('---SEP1---')
print(f"{today_min / 60.0:.1f}")
print('---SEP2---')
print(f"{week_min / 60.0:.1f}")
print('---SEP3---')
print('\n'.join(breakdown_lines) if breakdown_lines else '')
PYEOF
)

TODAY_ACTIVITY=$(echo "$PYTHON_OUTPUT" | sed -n '1,/^---SEP1---$/{ /^---SEP1---$/d; p; }')
TODAY_HOURS=$(echo "$PYTHON_OUTPUT" | sed -n '/^---SEP1---$/,/^---SEP2---$/{ /^---SEP/d; p; }')
WEEK_HOURS=$(echo "$PYTHON_OUTPUT" | sed -n '/^---SEP2---$/,/^---SEP3---$/{ /^---SEP/d; p; }')
WEEK_BREAKDOWN=$(echo "$PYTHON_OUTPUT" | sed -n '/^---SEP3---$/,$ { /^---SEP3---$/d; p; }')

# Today's people interactions via Python/boto3
TODAY_INTERACTIONS=$(python3 - <<'PYEOF'
import boto3
from datetime import datetime

ddb = boto3.resource('dynamodb', region_name='us-east-1')
table = ddb.Table('steward')

today = datetime.now().strftime('%Y-%m-%d')

# Scan for all interactions today
# Interactions have PK=PERSON#id, SK=INT#timestamp#id
response = table.scan(
    FilterExpression='entity_type = :et AND begins_with(#ts, :d)',
    ExpressionAttributeNames={'#ts': 'timestamp'},
    ExpressionAttributeValues={
        ':et': 'interaction',
        ':d': today,
    },
)

items = response.get('Items', [])
while response.get('LastEvaluatedKey'):
    response = table.scan(
        FilterExpression='entity_type = :et AND begins_with(#ts, :d)',
        ExpressionAttributeNames={'#ts': 'timestamp'},
        ExpressionAttributeValues={
            ':et': 'interaction',
            ':d': today,
        },
        ExclusiveStartKey=response['LastEvaluatedKey'],
    )
    items.extend(response.get('Items', []))

if not items:
    print('')
else:
    lines = ["name|type|summary"]
    for item in sorted(items, key=lambda x: x.get('timestamp', '')):
        name = item.get('person_name', item.get('name', ''))
        itype = item.get('type', '')
        summary = item.get('summary', '')
        lines.append(f"{name}|{itype}|{summary}")
    print('\n'.join(lines))
PYEOF
)

# People still overdue (uses DynamoDB-backed CLI)
PEOPLE_DUE=$(people due 2>/dev/null)

# People KPI: today's entries + total
PEOPLE_KPI=$(python3 - <<'PYEOF'
import boto3
from datetime import datetime

ddb = boto3.resource('dynamodb', region_name='us-east-1')
table = ddb.Table('steward')

today = datetime.now().strftime('%Y-%m-%d')

# People added today
people_resp = table.scan(
    FilterExpression='entity_type = :et AND begins_with(added_at, :d)',
    ExpressionAttributeValues={
        ':et': 'person',
        ':d': today,
    },
    Select='COUNT',
)
today_people = people_resp.get('Count', 0)

# Interactions logged today
int_resp = table.scan(
    FilterExpression='entity_type = :et AND begins_with(#ts, :d)',
    ExpressionAttributeNames={'#ts': 'timestamp'},
    ExpressionAttributeValues={
        ':et': 'interaction',
        ':d': today,
    },
    Select='COUNT',
)
today_interactions = int_resp.get('Count', 0)

# Total active people
total_resp = table.scan(
    FilterExpression='entity_type = :et AND (attribute_not_exists(archived) OR archived = :z)',
    ExpressionAttributeValues={
        ':et': 'person',
        ':z': 0,
    },
    Select='COUNT',
)
total_people = total_resp.get('Count', 0)

print(f"{today_people}")
print(f"{today_interactions}")
print(f"{total_people}")
PYEOF
)

TODAY_PEOPLE_ADDED=$(echo "$PEOPLE_KPI" | sed -n '1p')
TODAY_INTERACTIONS_COUNT=$(echo "$PEOPLE_KPI" | sed -n '2p')
TOTAL_PEOPLE=$(echo "$PEOPLE_KPI" | sed -n '3p')

# --- Build prompt ---

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
3. Pattern recognition: is this part of a streak (good or bad)? How is this week looking across all three projects (HU, IE, TEC)?
4. The single most important thing for tomorrow
5. Check the practice dimension — if sits are being skipped, name it
6. People: note who was reached out to today. If people are overdue and weren't contacted, mention it briefly. If no interactions were logged at all, gently remind to log any conversations that happened today.
7. People KPI: the target is minimum 2 new entries per day (new people added OR interactions logged). Check today's numbers. If under target, name it directly — "you talked to people today, log them" or "add 2 people from your network before bed." This is a daily practice, not optional.

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
