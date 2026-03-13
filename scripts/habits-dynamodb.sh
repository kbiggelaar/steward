#!/bin/bash
# Steward Habits CLI — DynamoDB backend
# Usage: habits <command> [args...]
#
# Manage:
#   habits add "name" --rule "desc" [--freq daily|weekly] [--target N]
#   habits pause "name"
#   habits retire "name"
#   habits resume "name"
#   habits list                    — list active habits
#
# Daily logging:
#   habits check "name" y|n ["note"]
#   habits today                   — today's check-in status
#   habits miss "name" ["note"]    — shortcut for check "name" n
#
# Views:
#   habits week [YYYY-MM-DD]      — weekly summary
#   habits streak "name"          — current streak for a habit
#   habits streaks                — streaks for all active habits
#   habits history ["name"] [days] — log history
#
# Generate:
#   habits generate               — overwrite work/habits.md

TABLE="${STEWARD_TABLE:-steward}"
HABITS_FILE="${STEWARD_HABITS_FILE:-/Users/koenbiggelaar/projects/work/habits.md}"

# Helper: get next auto-increment ID
next_id() {
  aws dynamodb update-item \
    --table-name "$TABLE" \
    --key '{"PK": {"S": "COUNTER"}, "SK": {"S": "'"$1"'"}}' \
    --update-expression "SET current_value = if_not_exists(current_value, :zero) + :one" \
    --expression-attribute-values '{":zero": {"N": "0"}, ":one": {"N": "1"}}' \
    --return-values UPDATED_NEW \
    --output json 2>&1 | jq -r '.Attributes.current_value.N'
}

now() { date '+%Y-%m-%d %H:%M:%S'; }
today() { date '+%Y-%m-%d'; }
jesc() { echo "$1" | sed 's/"/\\"/g'; }

# Helper: resolve habit name (case-insensitive partial match)
resolve_habit() {
  local input="$1"
  local lower_input
  lower_input=$(echo "$input" | tr '[:upper:]' '[:lower:]')
  aws dynamodb query \
    --table-name "$TABLE" \
    --index-name GSI1 \
    --key-condition-expression "GSI1PK = :pk" \
    --expression-attribute-values '{":pk": {"S": "HABIT_STATUS#active"}}' \
    --output json 2>&1 | jq -r --arg search "$lower_input" '
    .Items[] | select(.name.S | ascii_downcase | contains($search)) | .id.N
  ' | head -1
}

# Helper: get habit name by id
habit_name() {
  aws dynamodb get-item \
    --table-name "$TABLE" \
    --key '{"PK": {"S": "HABIT#'"$1"'"}, "SK": {"S": "META"}}' \
    --projection-expression "#n" \
    --expression-attribute-names '{"#n": "name"}' \
    --output json 2>&1 | jq -r '.Item.name.S // "Unknown"'
}

# Helper: get habit frequency by id
habit_freq() {
  aws dynamodb get-item \
    --table-name "$TABLE" \
    --key '{"PK": {"S": "HABIT#'"$1"'"}, "SK": {"S": "META"}}' \
    --projection-expression "frequency" \
    --output json 2>&1 | jq -r '.Item.frequency.S // "daily"'
}

# Helper: fetch all active habits as JSON
fetch_active_habits() {
  aws dynamodb query \
    --table-name "$TABLE" \
    --index-name GSI1 \
    --key-condition-expression "GSI1PK = :pk" \
    --expression-attribute-values '{":pk": {"S": "HABIT_STATUS#active"}}' \
    --output json 2>&1
}

# Helper: fetch habit logs for a habit between dates
fetch_habit_logs() {
  local hid="$1" from_date="$2" to_date="$3"
  aws dynamodb query \
    --table-name "$TABLE" \
    --key-condition-expression "PK = :pk AND SK BETWEEN :from AND :to" \
    --expression-attribute-values '{":pk": {"S": "HABIT#'"$hid"'"}, ":from": {"S": "LOG#'"$from_date"'"}, ":to": {"S": "LOG#'"$to_date"'~"}}' \
    --output json 2>&1
}

# Helper: fetch ALL habit logs (for generate/today/week)
fetch_all_habit_logs() {
  aws dynamodb scan \
    --table-name "$TABLE" \
    --filter-expression "entity_type = :et" \
    --expression-attribute-values '{":et": {"S": "habit_log"}}' \
    --output json 2>&1
}

cmd="${1:-help}"
shift 2>/dev/null

case "$cmd" in

  add)
    name="$1"
    shift 2>/dev/null
    if [ -z "$name" ]; then
      echo 'Usage: habits add "name" --rule "description" [--freq daily|weekly] [--target N]'
      exit 1
    fi
    rule=""; freq="daily"; target=7; started=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --rule)    rule="$2"; shift 2 ;;
        --freq)    freq="$2"; shift 2 ;;
        --target)  target="$2"; shift 2 ;;
        --started) started="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    [ "$freq" = "weekly" ] && [ "$target" = "7" ] && target=1
    hid=$(next_id "habit")
    ts_started="${started:-$(today)}"
    item='{
      "PK": {"S": "HABIT#'"$hid"'"},
      "SK": {"S": "META"},
      "entity_type": {"S": "habit"},
      "id": {"N": "'"$hid"'"},
      "name": {"S": "'"$(jesc "$name")"'"},
      "frequency": {"S": "'"$freq"'"},
      "target_per_week": {"N": "'"$target"'"},
      "status": {"S": "active"},
      "started": {"S": "'"$ts_started"'"},
      "GSI1PK": {"S": "HABIT_STATUS#active"},
      "GSI1SK": {"S": "'"$(jesc "$name")"'"}'
    [ -n "$rule" ] && item="$item"', "rule": {"S": "'"$(jesc "$rule")"'"}'
    item="$item"'}'
    aws dynamodb put-item --table-name "$TABLE" --item "$item" > /dev/null 2>&1
    echo "Habit added: $name ($freq, target $target/week)"
    ;;

  pause|retire|resume)
    name="$1"
    if [ -z "$name" ]; then echo "Usage: habits $cmd \"name\""; exit 1; fi
    hid=$(resolve_habit "$name")
    if [ -z "$hid" ]; then echo "No habit found matching: $name"; exit 1; fi
    actual_name=$(habit_name "$hid")
    case "$cmd" in
      pause)  new_status="paused" ;;
      retire) new_status="retired" ;;
      resume) new_status="active" ;;
    esac
    aws dynamodb update-item \
      --table-name "$TABLE" \
      --key '{"PK": {"S": "HABIT#'"$hid"'"}, "SK": {"S": "META"}}' \
      --update-expression "SET #s = :ns, GSI1PK = :gsi" \
      --expression-attribute-values '{":ns": {"S": "'"$new_status"'"}, ":gsi": {"S": "HABIT_STATUS#'"$new_status"'"}}' \
      --expression-attribute-names '{"#s": "status"}' > /dev/null 2>&1
    echo "${cmd^}: $actual_name"
    ;;

  list)
    habits=$(fetch_active_habits)
    echo "$habits" | jq -r '
      .Items | sort_by(.started.S // "", .name.S) |
      ["ID", "Name", "Frequency", "Target", "Started"],
      ["--", "----", "---------", "------", "-------"],
      (.[] | [.id.N, .name.S, .frequency.S, .target_per_week.N + "/week", .started.S // "-"]) |
      @tsv' | column -t -s $'\t'
    ;;

  check)
    name="$1"; done_val="$2"; note="$3"
    if [ -z "$name" ] || [ -z "$done_val" ]; then
      echo 'Usage: habits check "name" y|n ["note"]'
      exit 1
    fi
    hid=$(resolve_habit "$name")
    if [ -z "$hid" ]; then echo "No habit found matching: $name"; exit 1; fi
    actual_name=$(habit_name "$hid")
    today_str=$(today)
    ts=$(now)
    # Upsert: just put (overwrites if exists for same date)
    lid=$(next_id "habit_log")
    item='{
      "PK": {"S": "HABIT#'"$hid"'"},
      "SK": {"S": "LOG#'"$today_str"'"},
      "entity_type": {"S": "habit_log"},
      "id": {"N": "'"$lid"'"},
      "habit_id": {"N": "'"$hid"'"},
      "date": {"S": "'"$today_str"'"},
      "done": {"S": "'"$done_val"'"},
      "logged_at": {"S": "'"$ts"'"}'
    [ -n "$note" ] && item="$item"', "note": {"S": "'"$(jesc "$note")"'"}'
    item="$item"'}'
    aws dynamodb put-item --table-name "$TABLE" --item "$item" > /dev/null 2>&1
    if [ "$done_val" = "y" ]; then
      echo "✓ $actual_name — logged"
    else
      echo "✗ $actual_name — logged as missed${note:+ ($note)}"
    fi
    ;;

  miss)
    name="$1"; note="$2"
    if [ -z "$name" ]; then echo 'Usage: habits miss "name" ["note"]'; exit 1; fi
    # Delegate to check
    "$0" check "$name" n "$note"
    ;;

  today|week|streaks|generate)
    # All these commands need habits + logs — use temp files for JSON
    tmp_habits=$(mktemp)
    tmp_logs=$(mktemp)
    trap "rm -f $tmp_habits $tmp_logs" EXIT

    fetch_active_habits > "$tmp_habits"
    fetch_all_habit_logs > "$tmp_logs"

    ref_date="${1:-$(today)}"

    python3 - "$tmp_habits" "$tmp_logs" "$cmd" "$ref_date" "$HABITS_FILE" <<'PYEOF'
import json, sys
from datetime import date, timedelta, datetime

with open(sys.argv[1]) as f: habits_data = json.load(f)
with open(sys.argv[2]) as f: logs_data = json.load(f)
cmd = sys.argv[3]
ref_date_str = sys.argv[4]
habits_file = sys.argv[5]

habits = []
for h in habits_data.get('Items', []):
    habits.append({
        'id': h['id']['N'],
        'name': h['name']['S'],
        'frequency': h.get('frequency', {}).get('S', 'daily'),
        'target': int(h.get('target_per_week', {}).get('N', '7')),
        'started': h.get('started', {}).get('S', ''),
        'rule': h.get('rule', {}).get('S', ''),
    })
habits.sort(key=lambda h: (h['started'], h['name']))

# Build log lookup: {habit_id: {date_str: done_val}}
log_map = {}
log_notes = {}
for l in logs_data.get('Items', []):
    hid = l['habit_id']['N']
    d = l['date']['S']
    done = l['done']['S']
    note = l.get('note', {}).get('S', '')
    log_map.setdefault(hid, {})[d] = done
    if note:
        log_notes.setdefault(hid, {})[d] = note

today = date.today()
ref = date.fromisoformat(ref_date_str) if ref_date_str else today
monday = ref - timedelta(days=ref.weekday())
sunday = monday + timedelta(days=6)

def calc_streak(hid):
    streak = 0
    d = today
    logs = log_map.get(hid, {})
    while True:
        if logs.get(d.isoformat()) == 'y':
            streak += 1
            d -= timedelta(days=1)
        else:
            break
    return streak

def week_count(hid, mon, sun):
    logs = log_map.get(hid, {})
    count = 0
    d = mon
    while d <= sun:
        if logs.get(d.isoformat()) == 'y':
            count += 1
        d += timedelta(days=1)
    return count

if cmd == 'today':
    day_name = today.strftime('%A')
    date_str = today.strftime("%B %-d, %Y")
    print(f'{date_str} ({day_name}):')
    for h in habits:
        logs = log_map.get(h['id'], {})
        today_log = logs.get(today.isoformat())
        wc = week_count(h['id'], monday, sunday)
        n = h['name']
        t = h['target']
        if h['frequency'] == 'daily':
            if today_log == 'y':
                print(f'  \u2713 {n}')
            elif today_log == 'n':
                print(f'  \u2717 {n}')
            else:
                print(f'  \u00b7 {n}')
        else:
            if today_log == 'y':
                print(f'  \u2713 {n} ({wc}/{t} this week)')
            elif today_log == 'n':
                print(f'  \u2717 {n} ({wc}/{t} this week)')
            else:
                print(f'  \u00b7 {n} ({wc}/{t} this week)')

elif cmd == 'week':
    mon_str = monday.strftime("%B %-d")
    sun_str = sunday.strftime("%-d, %Y")
    print(f'Week of {mon_str}\u2013{sun_str}:')
    for h in habits:
        n = h['name']
        t = h['target']
        denom = 7 if h['frequency'] == 'daily' else t
        wc = week_count(h['id'], monday, sunday)
        if h['frequency'] == 'daily':
            streak = calc_streak(h['id'])
            days_so_far = min(denom, max(1, (min(today, sunday) - monday).days + 1))
            ratio = wc / days_so_far
            if wc == denom:
                indicator = f'\U0001f525 {streak}-day streak'
            elif ratio < 0.7:
                missed = []
                d = monday
                while d <= min(today, sunday):
                    if log_map.get(h['id'], {}).get(d.isoformat()) == 'n':
                        missed.append(d.strftime('%a'))
                    d += timedelta(days=1)
                indicator = '\u26a0\ufe0f  missed ' + ', '.join(missed) if missed else '\u26a0\ufe0f'
            else:
                indicator = ''
        else:
            indicator = '\u2713' if wc >= t else f'(target: {t}/week)' if wc == 0 else ''
        target_str = f'(target: {t}/week)' if h['frequency'] == 'weekly' else ''
        label = n + ':'
        print(f'  {label:<30s} {wc}/{denom}  {indicator} {target_str}'.rstrip())

elif cmd == 'streaks':
    for h in habits:
        n = h['name']
        t = h['target']
        if h['frequency'] == 'daily':
            streak = calc_streak(h['id'])
            print(f'  {n}: {streak}-day streak')
        else:
            wc = week_count(h['id'], monday, sunday)
            print(f'  {n}: {wc}/{t} this week')

elif cmd == 'generate':
    lines = []
    lines.append('# Habit Tracker')
    lines.append('')
    lines.append(f'**Last updated**: {today.isoformat()}')
    lines.append('')
    lines.append('## Active Habits')
    lines.append('')
    lines.append('| Habit | Rule | Frequency | Target | Streak | Started |')
    lines.append('|-------|------|-----------|--------|--------|---------|')

    for h in habits:
        n, r, f, t, s = h['name'], h['rule'], h['frequency'], h['target'], h['started']
        if f == 'daily':
            streak = calc_streak(h['id'])
            streak_str = f'{streak}-day streak'
        else:
            wc = week_count(h['id'], monday, sunday)
            streak_str = f'{wc}/{t} this week'
        lines.append(f'| {n} | {r} | {f} | {t}/week | {streak_str} | {s} |')

    lines.append('')
    lines.append('## This Week')
    lines.append('')
    mon_str = monday.strftime("%B %-d")
    sun_str = sunday.strftime("%-d, %Y")
    lines.append(f'Week of {mon_str}\u2013{sun_str}:')
    lines.append('')

    for h in habits:
        n, t = h['name'], h['target']
        denom = 7 if h['frequency'] == 'daily' else t
        wc = week_count(h['id'], monday, sunday)
        if h['frequency'] == 'daily':
            streak = calc_streak(h['id'])
            days_so_far = min(denom, max(1, (min(today, sunday) - monday).days + 1))
            ratio = wc / days_so_far
            if wc == denom:
                indicator = f'\U0001f525 {streak}-day streak'
            elif ratio < 0.7:
                missed = []
                d = monday
                while d <= min(today, sunday):
                    if log_map.get(h['id'], {}).get(d.isoformat()) == 'n':
                        missed.append(d.strftime('%a'))
                    d += timedelta(days=1)
                indicator = '\u26a0\ufe0f  missed ' + ', '.join(missed) if missed else '\u26a0\ufe0f'
            else:
                indicator = ''
        else:
            indicator = '\u2713' if wc >= t else f'(target: {t}/week)' if wc == 0 else ''
        label = n + ':'
        lines.append(f'  {label:<30s} {wc}/{denom}  {indicator}')

    lines.append('')
    lines.append('## Recent Log (14 days)')
    lines.append('')
    lines.append('| Date | Habit | Done | Note |')
    lines.append('|------|-------|------|------|')

    name_map = {h['id']: h['name'] for h in habits}
    cutoff = (today - timedelta(days=14)).isoformat()
    recent_logs = []
    for l in logs_data.get('Items', []):
        d = l['date']['S']
        if d >= cutoff:
            recent_logs.append((d, name_map.get(l['habit_id']['N'], '?'),
                               l['done']['S'], l.get('note', {}).get('S', '')))
    recent_logs.sort(key=lambda r: (r[0], r[1]), reverse=True)
    for d, hname, done, note in recent_logs:
        lines.append(f'| {d} | {hname} | {done} | {note} |')

    lines.append('')
    lines.append('## How This Works')
    lines.append('')
    lines.append('- First 7 days of a new habit: check in every session')
    lines.append('- After 7 consecutive days: reduce to periodic check-ins')
    lines.append('- If a streak breaks: reset to daily check-ins for 7 days')
    lines.append('- Weekly summary every Monday')
    lines.append('')
    lines.append('---')
    now_str = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    lines.append(f'*Auto-generated on {now_str} by habits.sh (DynamoDB)*')

    output = '\n'.join(lines) + '\n'
    with open(habits_file, 'w') as f:
        f.write(output)
    print(f'Generated: {habits_file}')
PYEOF
    ;;

  streak)
    name="$1"
    if [ -z "$name" ]; then echo 'Usage: habits streak "name"'; exit 1; fi
    hid=$(resolve_habit "$name")
    if [ -z "$hid" ]; then echo "No habit found matching: $name"; exit 1; fi
    actual_name=$(habit_name "$hid")
    freq=$(habit_freq "$hid")

    # Fetch logs for this habit (last 60 days for streak calc)
    from_date=$(python3 -c "from datetime import date, timedelta; print((date.today() - timedelta(days=60)).isoformat())")
    to_date=$(today)
    logs=$(fetch_habit_logs "$hid" "$from_date" "$to_date")

    if [ "$freq" = "daily" ]; then
      streak=$(echo "$logs" | python3 -c "
import json, sys
from datetime import date, timedelta
data = json.load(sys.stdin)
log_map = {i['date']['S']: i['done']['S'] for i in data.get('Items', [])}
streak = 0
d = date.today()
while True:
    if log_map.get(d.isoformat()) == 'y':
        streak += 1
        d -= timedelta(days=1)
    else:
        break
print(streak)
")
      echo "$actual_name: ${streak}-day streak"
    else
      target=$(aws dynamodb get-item \
        --table-name "$TABLE" \
        --key '{"PK": {"S": "HABIT#'"$hid"'"}, "SK": {"S": "META"}}' \
        --projection-expression "target_per_week" \
        --output json 2>&1 | jq -r '.Item.target_per_week.N // "1"')
      monday=$(python3 -c "from datetime import date, timedelta; d=date.today(); print((d - timedelta(days=d.weekday())).isoformat())")
      count=$(echo "$logs" | jq --arg mon "$monday" '[.Items[] | select(.date.S >= $mon and .done.S == "y")] | length')
      echo "$actual_name: $count/$target this week"
    fi
    ;;

  history)
    name=""
    days=14
    if [ -n "$1" ]; then
      if [[ "$1" =~ ^[0-9]+$ ]]; then
        days="$1"
      else
        name="$1"
        [[ -n "$2" && "$2" =~ ^[0-9]+$ ]] && days="$2"
      fi
    fi

    from_date=$(python3 -c "from datetime import date, timedelta; print((date.today() - timedelta(days=$days)).isoformat())")
    to_date=$(today)

    if [ -n "$name" ]; then
      hid=$(resolve_habit "$name")
      if [ -z "$hid" ]; then echo "No habit found matching: $name"; exit 1; fi
      logs=$(fetch_habit_logs "$hid" "$from_date" "$to_date")
      hname=$(habit_name "$hid")
      echo "$logs" | jq -r --arg hname "$hname" '
        .Items | sort_by(.date.S) | reverse |
        ["Date", "Habit", "Done", "Note"],
        ["----", "-----", "----", "----"],
        (.[] | [.date.S, $hname, .done.S, .note.S // ""]) | @tsv' | column -t -s $'\t'
    else
      # All habits — fetch all logs and join with names
      tmp_h=$(mktemp)
      tmp_l=$(mktemp)
      trap "rm -f $tmp_h $tmp_l" EXIT
      fetch_active_habits > "$tmp_h"
      fetch_all_habit_logs > "$tmp_l"
      python3 - "$tmp_h" "$tmp_l" "$days" <<'PYEOF'
import json, sys
from datetime import date, timedelta

with open(sys.argv[1]) as f: habits = json.load(f)
with open(sys.argv[2]) as f: logs = json.load(f)
days = int(sys.argv[3])

name_map = {h['id']['N']: h['name']['S'] for h in habits.get('Items', [])}
cutoff = (date.today() - timedelta(days=days)).isoformat()
rows = []
for l in logs.get('Items', []):
    d = l['date']['S']
    if d >= cutoff:
        rows.append((d, name_map.get(l['habit_id']['N'], '?'), l['done']['S'], l.get('note', {}).get('S', '')))

rows.sort(key=lambda r: (r[0], r[1]), reverse=True)
print(f"{'Date':<12s} {'Habit':<35s} {'Done':>4s} {'Note'}")
print(f"{'-'*12} {'-'*35} {'-'*4} {'-'*20}")
for d, h, done, note in rows:
    print(f'{d:<12s} {h:<35s} {done:>4s} {note}')
PYEOF
    fi
    ;;

  help|*)
    echo "Steward Habits CLI — habit tracking (DynamoDB)"
    echo ""
    echo "Manage:"
    echo '  add "name" --rule "desc" [--freq daily|weekly] [--target N]'
    echo '  pause "name"                          — pause a habit'
    echo '  retire "name"                         — retire a habit'
    echo '  resume "name"                         — resume a paused habit'
    echo "  list                                   — list active habits"
    echo ""
    echo "Daily logging:"
    echo '  check "name" y|n ["note"]              — log today'\''s check-in'
    echo "  today                                  — today's status for all habits"
    echo '  miss "name" ["note"]                   — shortcut for check name n'
    echo ""
    echo "Views:"
    echo "  week [YYYY-MM-DD]                      — weekly summary"
    echo '  streak "name"                          — current streak'
    echo "  streaks                                — all active streaks"
    echo '  history ["name"] [days]                — log history (default 14 days)'
    echo ""
    echo "Generate:"
    echo "  generate                               — write work/habits.md"
    echo ""
    echo "Backend: DynamoDB table '$TABLE'"
    ;;

esac
