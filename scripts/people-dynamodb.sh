#!/bin/bash
# Steward People CLI — DynamoDB backend
# Usage:
#   people add "Name" context relationship [frequency_days] [contact_method]
#   people log "Name" type "summary" [direction] [follow_up]
#   people list [context]
#   people info "Name"
#   people due                  — who needs attention
#   people birthdays            — upcoming birthdays
#   people note "Name" "note"   — update notes for a person
#   people birthday "Name" "MM-DD" or "YYYY-MM-DD"
#   people freq "Name" days     — set contact frequency
#   people search "term"        — search across names and notes

TABLE="${STEWARD_TABLE:-steward}"

# Helper: get next auto-increment ID
next_id() {
  local entity="$1"
  aws dynamodb update-item \
    --table-name "$TABLE" \
    --key '{"PK": {"S": "COUNTER"}, "SK": {"S": "'"$entity"'"}}' \
    --update-expression "SET current_value = if_not_exists(current_value, :zero) + :one" \
    --expression-attribute-values '{":zero": {"N": "0"}, ":one": {"N": "1"}}' \
    --return-values UPDATED_NEW \
    --output json 2>&1 | jq -r '.Attributes.current_value.N'
}

now() { date '+%Y-%m-%d %H:%M:%S'; }

# Helper: escape double quotes for JSON
jesc() { echo "$1" | sed 's/"/\\"/g'; }

# Helper: resolve person name to ID (case-insensitive partial match)
resolve_person() {
  local input="$1"
  local lower_input
  lower_input=$(echo "$input" | tr '[:upper:]' '[:lower:]')
  aws dynamodb query \
    --table-name "$TABLE" \
    --index-name GSI1 \
    --key-condition-expression "GSI1PK = :pk" \
    --expression-attribute-values '{":pk": {"S": "PERSON_ACTIVE"}}' \
    --output json 2>&1 | jq -r --arg search "$lower_input" '
    .Items[] | select(.name.S | ascii_downcase | contains($search)) | .id.N
  ' | head -1
}

# Helper: get person name by ID
person_name() {
  aws dynamodb get-item \
    --table-name "$TABLE" \
    --key '{"PK": {"S": "PERSON#'"$1"'"}, "SK": {"S": "META"}}' \
    --projection-expression "#n" \
    --expression-attribute-names '{"#n": "name"}' \
    --output json 2>&1 | jq -r '.Item.name.S // "Unknown"'
}

cmd="${1:-help}"
shift

case "$cmd" in
  add)
    name="$1"; context="$2"; relationship="$3"
    freq="${4:-30}"; method="${5:-}"
    if [ -z "$name" ] || [ -z "$context" ]; then
      echo "Usage: people add \"Name\" context relationship [frequency_days] [contact_method]"
      echo "  context: hu, ie, tec, personal, family, friend"
      echo "  relationship: colleague, student, mentor, friend, family, collaborator"
      exit 1
    fi
    pid=$(next_id "person")
    ts=$(now)
    item='{
      "PK": {"S": "PERSON#'"$pid"'"},
      "SK": {"S": "META"},
      "entity_type": {"S": "person"},
      "id": {"N": "'"$pid"'"},
      "name": {"S": "'"$(jesc "$name")"'"},
      "context": {"S": "'"$context"'"},
      "relationship": {"S": "'"$relationship"'"},
      "contact_frequency_days": {"N": "'"$freq"'"},
      "archived": {"N": "0"},
      "added_at": {"S": "'"$ts"'"},
      "GSI1PK": {"S": "PERSON_ACTIVE"},
      "GSI1SK": {"S": "'"$(jesc "$name")"'"}'
    [ -n "$method" ] && item="$item"', "contact_method": {"S": "'"$method"'"}'
    item="$item"'}'
    aws dynamodb put-item --table-name "$TABLE" --item "$item" > /dev/null 2>&1
    echo "Added: $name ($context / $relationship, every ${freq}d)"
    ;;

  log)
    name="$1"; type="$2"; summary="$3"
    direction="${4:-outgoing}"; follow_up="${5:-}"
    if [ -z "$name" ] || [ -z "$type" ]; then
      echo "Usage: people log \"Name\" type \"summary\" [direction] [follow_up]"
      echo "  type: message, call, meeting, email, coffee, lunch, video"
      echo "  direction: outgoing, incoming, mutual"
      exit 1
    fi
    pid=$(resolve_person "$name")
    if [ -z "$pid" ]; then echo "No person found matching: $name"; exit 1; fi
    actual_name=$(person_name "$pid")
    iid=$(next_id "interaction")
    ts=$(now)
    item='{
      "PK": {"S": "PERSON#'"$pid"'"},
      "SK": {"S": "INT#'"$ts"'#'"$iid"'"},
      "entity_type": {"S": "interaction"},
      "id": {"N": "'"$iid"'"},
      "person_id": {"N": "'"$pid"'"},
      "timestamp": {"S": "'"$ts"'"},
      "type": {"S": "'"$type"'"},
      "direction": {"S": "'"$direction"'"}'
    [ -n "$summary" ] && item="$item"', "summary": {"S": "'"$(jesc "$summary")"'"}'
    [ -n "$follow_up" ] && item="$item"', "follow_up": {"S": "'"$(jesc "$follow_up")"'"}'
    item="$item"'}'
    aws dynamodb put-item --table-name "$TABLE" --item "$item" > /dev/null 2>&1
    echo "Logged $type with $actual_name: $summary"
    ;;

  list)
    context="$1"
    tmp_people=$(mktemp)
    tmp_ints=$(mktemp)
    trap "rm -f $tmp_people $tmp_ints" EXIT

    aws dynamodb query \
      --table-name "$TABLE" \
      --index-name GSI1 \
      --key-condition-expression "GSI1PK = :pk" \
      --expression-attribute-values '{":pk": {"S": "PERSON_ACTIVE"}}' \
      --output json > "$tmp_people" 2>&1

    aws dynamodb scan \
      --table-name "$TABLE" \
      --filter-expression "entity_type = :et" \
      --expression-attribute-values '{":et": {"S": "interaction"}}' \
      --projection-expression "person_id, #ts" \
      --expression-attribute-names '{"#ts": "timestamp"}' \
      --output json > "$tmp_ints" 2>&1

    python3 - "$tmp_people" "$tmp_ints" "$context" <<'PYEOF'
import json, sys
from datetime import datetime

with open(sys.argv[1]) as f: people = json.load(f)
with open(sys.argv[2]) as f: ints = json.load(f)
context_filter = sys.argv[3] if sys.argv[3] else None

last_contact = {}
for i in ints.get('Items', []):
    pid = i['person_id']['N']
    ts = i['timestamp']['S']
    if pid not in last_contact or ts > last_contact[pid]:
        last_contact[pid] = ts

rows = []
for p in people.get('Items', []):
    ctx = p.get('context', {}).get('S', '-')
    if context_filter and ctx != context_filter:
        continue
    pid = p['id']['N']
    lc = last_contact.get(pid, '')
    days_ago = '-'
    if lc:
        try:
            diff = (datetime.now() - datetime.fromisoformat(lc)).days
            days_ago = str(diff)
        except:
            pass
    rows.append((p['name']['S'], ctx, p.get('relationship', {}).get('S', '-'),
                 p.get('contact_frequency_days', {}).get('N', '30'), lc[:16] if lc else '-', days_ago))

rows.sort(key=lambda r: (r[1], r[0]))
print(f"{'Name':<25s} {'Context':<10s} {'Role':<15s} {'Freq':>4s} {'Last Contact':<18s} {'Days':>4s}")
print(f"{'-'*25} {'-'*10} {'-'*15} {'-'*4} {'-'*18} {'-'*4}")
for r in rows:
    print(f'{r[0]:<25s} {r[1]:<10s} {r[2]:<15s} {r[3]:>4s} {r[4]:<18s} {r[5]:>4s}')
PYEOF
    ;;

  info)
    name="$1"
    if [ -z "$name" ]; then echo "Usage: people info \"Name\""; exit 1; fi
    pid=$(resolve_person "$name")
    if [ -z "$pid" ]; then echo "No person found matching: $name"; exit 1; fi

    # Get person data
    person=$(aws dynamodb get-item \
      --table-name "$TABLE" \
      --key '{"PK": {"S": "PERSON#'"$pid"'"}, "SK": {"S": "META"}}' \
      --output json 2>&1)

    # Get interactions
    ints=$(aws dynamodb query \
      --table-name "$TABLE" \
      --key-condition-expression "PK = :pk AND begins_with(SK, :sk)" \
      --expression-attribute-values '{":pk": {"S": "PERSON#'"$pid"'"}, ":sk": {"S": "INT#"}}' \
      --no-scan-index-forward \
      --limit 10 \
      --output json 2>&1)

    echo "=== Profile ==="
    echo "$person" | jq -r '.Item | "Name: \(.name.S)\nContext: \(.context.S // "-")\nRelationship: \(.relationship.S // "-")\nContact method: \(.contact_method.S // "-")\nFrequency: \(.contact_frequency_days.N // "30") days\nBirthday: \(.birthday.S // "-")\nNotes: \(.notes.S // "-")"'
    echo ""
    echo "=== Recent Interactions ==="
    echo "$ints" | jq -r '
      .Items | sort_by(.timestamp.S) | reverse |
      if length == 0 then "  No interactions logged." else
        .[] | "  \(.timestamp.S[:16])  \(.type.S)  \(.direction.S // "")  \(.summary.S // "")"
      end'
    ;;

  due)
    echo "=== People to reach out to ==="
    tmp_people=$(mktemp)
    tmp_ints=$(mktemp)
    trap "rm -f $tmp_people $tmp_ints" EXIT

    aws dynamodb query \
      --table-name "$TABLE" \
      --index-name GSI1 \
      --key-condition-expression "GSI1PK = :pk" \
      --expression-attribute-values '{":pk": {"S": "PERSON_ACTIVE"}}' \
      --output json > "$tmp_people" 2>&1

    aws dynamodb scan \
      --table-name "$TABLE" \
      --filter-expression "entity_type = :et" \
      --expression-attribute-values '{":et": {"S": "interaction"}}' \
      --projection-expression "person_id, #ts" \
      --expression-attribute-names '{"#ts": "timestamp"}' \
      --output json > "$tmp_ints" 2>&1

    python3 - "$tmp_people" "$tmp_ints" <<'PYEOF'
import json, sys
from datetime import datetime

with open(sys.argv[1]) as f: people = json.load(f)
with open(sys.argv[2]) as f: ints = json.load(f)

last_contact = {}
for i in ints.get('Items', []):
    pid = i['person_id']['N']
    ts = i['timestamp']['S']
    if pid not in last_contact or ts > last_contact[pid]:
        last_contact[pid] = ts

now = datetime.now()
due = []
for p in people.get('Items', []):
    pid = p['id']['N']
    freq = int(p.get('contact_frequency_days', {}).get('N', '30'))
    lc = last_contact.get(pid)
    if lc:
        days_since = (now - datetime.fromisoformat(lc)).days
        days_until = freq - days_since
    else:
        days_since = 999
        days_until = -999

    if days_until <= 7:
        due.append((p['name']['S'], p.get('context', {}).get('S', '-'),
                     p.get('relationship', {}).get('S', '-'),
                     p.get('contact_method', {}).get('S', '-'),
                     freq, lc[:16] if lc else 'never', days_since, days_until))

due.sort(key=lambda r: r[7])
if not due:
    print('  All caught up!')
else:
    print(f"{'Name':<22s} {'Context':<10s} {'Role':<12s} {'Method':<10s} {'Freq':>4s} {'Last':>6s} {'Due in':>6s}")
    print(f"{'-'*22} {'-'*10} {'-'*12} {'-'*10} {'-'*4} {'-'*6} {'-'*6}")
    for r in due:
        due_str = f'{r[7]}d' if r[7] >= 0 else f'{abs(r[7])}d ago'
        print(f'{r[0]:<22s} {r[1]:<10s} {r[2]:<12s} {r[3]:<10s} {r[4]:>4d} {r[6]:>5d}d {due_str:>6s}')
PYEOF
    ;;

  birthdays)
    echo "=== Upcoming birthdays (next 14 days) ==="
    tmp_people=$(mktemp)
    trap "rm -f $tmp_people" EXIT

    aws dynamodb query \
      --table-name "$TABLE" \
      --index-name GSI1 \
      --key-condition-expression "GSI1PK = :pk" \
      --expression-attribute-values '{":pk": {"S": "PERSON_ACTIVE"}}' \
      --output json > "$tmp_people" 2>&1

    python3 - "$tmp_people" <<'PYEOF'
import json, sys
from datetime import date

with open(sys.argv[1]) as f: people = json.load(f)
today = date.today()

upcoming = []
for p in people.get('Items', []):
    bday = p.get('birthday', {}).get('S')
    if not bday:
        continue
    mm_dd = bday[-5:]
    try:
        this_year = date.fromisoformat(f'{today.year}-{mm_dd}')
        diff = (this_year - today).days
        if -1 <= diff <= 14:
            upcoming.append((p['name']['S'], bday, diff))
    except:
        pass

upcoming.sort(key=lambda r: r[2])
if not upcoming:
    print('  No upcoming birthdays.')
else:
    for name, bday, diff in upcoming:
        if diff == 0:
            print(f'  \U0001f382 {name} — TODAY! ({bday})')
        elif diff < 0:
            print(f'  \U0001f382 {name} — yesterday ({bday})')
        else:
            print(f'  {name} — in {diff} days ({bday})')
PYEOF
    ;;

  note)
    name="$1"; note="$2"
    if [ -z "$name" ] || [ -z "$note" ]; then echo 'Usage: people note "Name" "note text"'; exit 1; fi
    pid=$(resolve_person "$name")
    if [ -z "$pid" ]; then echo "No person found matching: $name"; exit 1; fi
    actual_name=$(person_name "$pid")
    # Get existing notes and append
    existing=$(aws dynamodb get-item \
      --table-name "$TABLE" \
      --key '{"PK": {"S": "PERSON#'"$pid"'"}, "SK": {"S": "META"}}' \
      --projection-expression "notes" \
      --output json 2>&1 | jq -r '.Item.notes.S // ""')
    if [ -n "$existing" ]; then
      combined="$existing
$note"
    else
      combined="$note"
    fi
    aws dynamodb update-item \
      --table-name "$TABLE" \
      --key '{"PK": {"S": "PERSON#'"$pid"'"}, "SK": {"S": "META"}}' \
      --update-expression "SET notes = :n" \
      --expression-attribute-values '{":n": {"S": "'"$(echo "$combined" | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')"'"}}' > /dev/null 2>&1
    echo "Note added for $actual_name"
    ;;

  birthday)
    name="$1"; bday="$2"
    if [ -z "$name" ] || [ -z "$bday" ]; then echo 'Usage: people birthday "Name" "MM-DD"'; exit 1; fi
    pid=$(resolve_person "$name")
    if [ -z "$pid" ]; then echo "No person found matching: $name"; exit 1; fi
    actual_name=$(person_name "$pid")
    aws dynamodb update-item \
      --table-name "$TABLE" \
      --key '{"PK": {"S": "PERSON#'"$pid"'"}, "SK": {"S": "META"}}' \
      --update-expression "SET birthday = :b" \
      --expression-attribute-values '{":b": {"S": "'"$bday"'"}}' > /dev/null 2>&1
    echo "Birthday set for $actual_name: $bday"
    ;;

  freq)
    name="$1"; days="$2"
    if [ -z "$name" ] || [ -z "$days" ]; then echo 'Usage: people freq "Name" days'; exit 1; fi
    pid=$(resolve_person "$name")
    if [ -z "$pid" ]; then echo "No person found matching: $name"; exit 1; fi
    actual_name=$(person_name "$pid")
    aws dynamodb update-item \
      --table-name "$TABLE" \
      --key '{"PK": {"S": "PERSON#'"$pid"'"}, "SK": {"S": "META"}}' \
      --update-expression "SET contact_frequency_days = :d" \
      --expression-attribute-values '{":d": {"N": "'"$days"'"}}' > /dev/null 2>&1
    echo "Contact frequency for $actual_name set to every ${days} days"
    ;;

  search)
    term="$1"
    if [ -z "$term" ]; then echo 'Usage: people search "term"'; exit 1; fi
    lower_term=$(echo "$term" | tr '[:upper:]' '[:lower:]')
    aws dynamodb query \
      --table-name "$TABLE" \
      --index-name GSI1 \
      --key-condition-expression "GSI1PK = :pk" \
      --expression-attribute-values '{":pk": {"S": "PERSON_ACTIVE"}}' \
      --output json 2>&1 | jq -r --arg term "$lower_term" '
      .Items[] |
      select(
        (.name.S | ascii_downcase | contains($term)) or
        (.notes.S // "" | ascii_downcase | contains($term)) or
        (.context.S // "" | ascii_downcase | contains($term))
      ) |
      "\(.name.S) | \(.context.S // "-") | \(.relationship.S // "-") | \(.notes.S // "-" | .[0:60])"'
    ;;

  help|*)
    echo "Steward People CLI (DynamoDB)"
    echo ""
    echo "Commands:"
    echo '  add "Name" context relationship [freq] [method]  — add a person'
    echo '  log "Name" type "summary" [direction] [follow_up] — log interaction'
    echo "  list [context]                                     — list people"
    echo '  info "Name"                                        — full profile + history'
    echo "  due                                                — who needs attention"
    echo "  birthdays                                          — upcoming birthdays"
    echo '  note "Name" "note"                                 — add a note'
    echo '  birthday "Name" "MM-DD"                            — set birthday'
    echo '  freq "Name" days                                   — set contact frequency'
    echo '  search "term"                                      — search names & notes'
    echo ""
    echo "Contexts: hu, ie, tec, personal, family, friend"
    echo "Types: message, call, meeting, email, coffee, lunch, video"
    echo ""
    echo "Backend: DynamoDB table '$TABLE'"
    ;;
esac
