#!/bin/bash
# Steward Work CLI — DynamoDB backend
# Usage: work <command> [args...]
#
# Projects:
#   work add-project "name" institution "description" [target_date]
#   work projects                         — list active projects
#   work project-status ID status         — change project status
#
# Actions:
#   work add "PROJECT" "description" [--status s] [--owner o] [--due DATE] [--waiting "who"] [--notes "text"]
#   work list [PROJECT]                   — open/waiting/in_progress actions
#   work list --all                       — include done/killed
#   work done ID [note]                   — mark action done
#   work kill ID [note]                   — mark action killed
#   work waiting ID "waiting on"          — set to waiting
#   work start ID                         — set to in_progress
#   work update ID "new notes"            — add notes
#   work due ID YYYY-MM-DD               — set/change due date
#
# Views:
#   work status                           — print status.md content to stdout
#   work overdue                          — show overdue actions
#   work history [PROJECT]                — show action history
#
# Generate:
#   work generate                         — overwrite work/status.md

TABLE="${STEWARD_TABLE:-steward}"
STATUS_FILE="${STEWARD_STATUS_FILE:-/Users/koenbiggelaar/projects/work/status.md}"

# Helper: get next auto-increment ID for an entity type
next_id() {
  local entity="$1"
  local result
  result=$(aws dynamodb update-item \
    --table-name "$TABLE" \
    --key '{"PK": {"S": "COUNTER"}, "SK": {"S": "'"$entity"'"}}' \
    --update-expression "SET current_value = if_not_exists(current_value, :zero) + :one" \
    --expression-attribute-values '{":zero": {"N": "0"}, ":one": {"N": "1"}}' \
    --return-values UPDATED_NEW \
    --output json 2>&1)
  echo "$result" | jq -r '.Attributes.current_value.N'
}

# Helper: get current timestamp
now() {
  date '+%Y-%m-%d %H:%M:%S'
}

today() {
  date '+%Y-%m-%d'
}

# Helper: resolve project name or ID to project ID
resolve_project() {
  local input="$1"
  # Try as integer ID first
  if [[ "$input" =~ ^[0-9]+$ ]]; then
    local result
    result=$(aws dynamodb get-item \
      --table-name "$TABLE" \
      --key '{"PK": {"S": "PROJECT#'"$input"'"}, "SK": {"S": "META"}}' \
      --output json 2>&1)
    local id
    id=$(echo "$result" | jq -r '.Item.id.N // empty')
    if [ -n "$id" ]; then echo "$id"; return 0; fi
  fi
  # Search by name (case-insensitive substring match via GSI scan)
  local lower_input
  lower_input=$(echo "$input" | tr '[:upper:]' '[:lower:]')
  local result
  result=$(aws dynamodb query \
    --table-name "$TABLE" \
    --index-name GSI1 \
    --key-condition-expression "GSI1PK = :pk" \
    --expression-attribute-values '{":pk": {"S": "PROJECT_STATUS#active"}}' \
    --output json 2>&1)
  local id
  id=$(echo "$result" | jq -r --arg search "$lower_input" '
    .Items[] | select(.name.S | ascii_downcase | contains($search)) | .id.N
  ' | head -1)
  if [ -n "$id" ]; then echo "$id"; return 0; fi
  echo ""
  return 1
}

# Helper: get project name by ID
project_name() {
  local pid="$1"
  aws dynamodb get-item \
    --table-name "$TABLE" \
    --key '{"PK": {"S": "PROJECT#'"$pid"'"}, "SK": {"S": "META"}}' \
    --projection-expression "#n" \
    --expression-attribute-names '{"#n": "name"}' \
    --output json 2>&1 | jq -r '.Item.name.S // "Unknown"'
}

# Helper: log status change
log_status_change() {
  local action_id="$1" old_status="$2" new_status="$3" note="$4"
  local log_id
  log_id=$(next_id "action_log")
  local ts
  ts=$(now)
  local item='{
    "PK": {"S": "ACTION#'"$action_id"'"},
    "SK": {"S": "LOG#'"$ts"'#'"$log_id"'"},
    "entity_type": {"S": "action_log"},
    "id": {"N": "'"$log_id"'"},
    "action_id": {"N": "'"$action_id"'"},
    "old_status": {"S": "'"$old_status"'"},
    "new_status": {"S": "'"$new_status"'"},
    "timestamp": {"S": "'"$ts"'"}'
  if [ -n "$note" ]; then
    item="$item"', "note": {"S": "'"$(echo "$note" | sed 's/"/\\"/g')"'"}'
  fi
  item="$item"'}'
  aws dynamodb put-item --table-name "$TABLE" --item "$item" > /dev/null 2>&1
}

# Helper: get action by ID (scans — actions are under PROJECT# partitions)
get_action() {
  local aid="$1"
  aws dynamodb query \
    --table-name "$TABLE" \
    --index-name GSI1 \
    --key-condition-expression "begins_with(GSI1PK, :prefix)" \
    --filter-expression "id = :id AND entity_type = :et" \
    --expression-attribute-values '{":prefix": {"S": "ACTION_STATUS#"}, ":id": {"N": "'"$aid"'"}, ":et": {"S": "action"}}' \
    --output json 2>&1 | jq -r '.Items[0] // empty'
}

# Helper: find action's PK and SK by ID (needed for updates)
find_action_keys() {
  local aid="$1"
  # Scan for the action — small table, this is fine
  aws dynamodb scan \
    --table-name "$TABLE" \
    --filter-expression "entity_type = :et AND id = :id" \
    --expression-attribute-values '{":et": {"S": "action"}, ":id": {"N": "'"$aid"'"}}' \
    --projection-expression "PK, SK, #s, description, project_id" \
    --expression-attribute-names '{"#s": "status"}' \
    --output json 2>&1 | jq -r '.Items[0] // empty'
}

# Helper: update action status
set_action_status() {
  local action_id="$1" new_status="$2" note="$3"
  local action_data
  action_data=$(find_action_keys "$action_id")
  if [ -z "$action_data" ] || [ "$action_data" = "null" ]; then
    echo "Action #$action_id not found."
    exit 1
  fi
  local pk sk old_status desc project_id
  pk=$(echo "$action_data" | jq -r '.PK.S')
  sk=$(echo "$action_data" | jq -r '.SK.S')
  old_status=$(echo "$action_data" | jq -r '.status.S')
  desc=$(echo "$action_data" | jq -r '.description.S')
  project_id=$(echo "$action_data" | jq -r '.project_id.N')

  local ts
  ts=$(now)
  local update_expr="SET #s = :ns, updated = :ts, GSI1PK = :gsi1pk"
  local attr_values='{":ns": {"S": "'"$new_status"'"}, ":ts": {"S": "'"$ts"'"}, ":gsi1pk": {"S": "ACTION_STATUS#'"$new_status"'"}}'

  if [ "$new_status" = "done" ] || [ "$new_status" = "killed" ]; then
    update_expr="$update_expr, completed = :comp"
    attr_values=$(echo "$attr_values" | jq '. + {":comp": {"S": "'"$ts"'"}}')
  fi

  aws dynamodb update-item \
    --table-name "$TABLE" \
    --key '{"PK": {"S": "'"$pk"'"}, "SK": {"S": "'"$sk"'"}}' \
    --update-expression "$update_expr" \
    --expression-attribute-values "$attr_values" \
    --expression-attribute-names '{"#s": "status"}' > /dev/null 2>&1

  log_status_change "$action_id" "$old_status" "$new_status" "$note"
  echo "Action #$action_id → $new_status: $desc"
}

cmd="${1:-help}"
shift 2>/dev/null

case "$cmd" in

  add-project)
    name="$1"; institution="$2"; description="$3"; target_date="$4"
    if [ -z "$name" ] || [ -z "$institution" ]; then
      echo "Usage: work add-project \"name\" institution \"description\" [target_date]"
      echo "  institution: hu, ie, tec, personal, kai, bitb"
      exit 1
    fi
    pid=$(next_id "project")
    ts=$(now)
    item='{
      "PK": {"S": "PROJECT#'"$pid"'"},
      "SK": {"S": "META"},
      "entity_type": {"S": "project"},
      "id": {"N": "'"$pid"'"},
      "name": {"S": "'"$(echo "$name" | sed 's/"/\\"/g')"'"},
      "institution": {"S": "'"$institution"'"},
      "status": {"S": "active"},
      "description": {"S": "'"$(echo "$description" | sed 's/"/\\"/g')"'"},
      "created": {"S": "'"$ts"'"},
      "updated": {"S": "'"$ts"'"},
      "GSI1PK": {"S": "PROJECT_STATUS#active"},
      "GSI1SK": {"S": "'"$(echo "$name" | sed 's/"/\\"/g')"'"}'
    if [ -n "$target_date" ]; then
      item="$item"', "target_date": {"S": "'"$target_date"'"}'
    fi
    item="$item"'}'
    aws dynamodb put-item --table-name "$TABLE" --item "$item" > /dev/null 2>&1
    echo "Project #$pid added: $name ($institution)"
    ;;

  projects)
    filter="${1:-active}"
    local_status="active"
    if [ "$filter" = "--all" ]; then local_status=""; fi

    if [ -n "$local_status" ]; then
      result=$(aws dynamodb query \
        --table-name "$TABLE" \
        --index-name GSI1 \
        --key-condition-expression "GSI1PK = :pk" \
        --expression-attribute-values '{":pk": {"S": "PROJECT_STATUS#active"}}' \
        --output json 2>&1)
    else
      result=$(aws dynamodb scan \
        --table-name "$TABLE" \
        --filter-expression "entity_type = :et" \
        --expression-attribute-values '{":et": {"S": "project"}}' \
        --output json 2>&1)
    fi

    echo "$result" | jq -r '
      .Items | sort_by(.institution.S // "", .name.S) |
      ["ID", "Name", "Institution", "Status", "Target"],
      ["--", "----", "-----------", "------", "------"],
      (.[] | [.id.N, .name.S, .institution.S // "-", .status.S, .target_date.S // "-"]) |
      @tsv' | column -t -s $'\t'
    ;;

  project-status)
    pid="$1"; new_status="$2"
    if [ -z "$pid" ] || [ -z "$new_status" ]; then
      echo "Usage: work project-status ID status"
      echo "  status: active, paused, completed, killed"
      exit 1
    fi
    ts=$(now)
    aws dynamodb update-item \
      --table-name "$TABLE" \
      --key '{"PK": {"S": "PROJECT#'"$pid"'"}, "SK": {"S": "META"}}' \
      --update-expression "SET #s = :ns, updated = :ts, GSI1PK = :gsi1pk" \
      --expression-attribute-values '{":ns": {"S": "'"$new_status"'"}, ":ts": {"S": "'"$ts"'"}, ":gsi1pk": {"S": "PROJECT_STATUS#'"$new_status"'"}}' \
      --expression-attribute-names '{"#s": "status"}' > /dev/null 2>&1
    pname=$(project_name "$pid")
    echo "Project #$pid ($pname) → $new_status"
    ;;

  add)
    project_input="$1"; description="$2"
    shift 2 2>/dev/null
    if [ -z "$project_input" ] || [ -z "$description" ]; then
      echo 'Usage: work add "PROJECT" "description" [--status s] [--owner o] [--due DATE] [--waiting "who"] [--notes "text"]'
      exit 1
    fi
    pid=$(resolve_project "$project_input")
    if [ -z "$pid" ]; then
      echo "No project found matching: $project_input"
      exit 1
    fi
    # Parse optional flags
    status="open"; owner=""; due_date=""; waiting_on=""; notes=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --status)  status="$2"; shift 2 ;;
        --owner)   owner="$2"; shift 2 ;;
        --due)     due_date="$2"; shift 2 ;;
        --waiting) waiting_on="$2"; shift 2 ;;
        --notes)   notes="$2"; shift 2 ;;
        *) shift ;;
      esac
    done
    aid=$(next_id "action")
    ts=$(now)
    gsi1sk="${due_date:-9999-12-31}"
    item='{
      "PK": {"S": "PROJECT#'"$pid"'"},
      "SK": {"S": "ACTION#'"$aid"'"},
      "entity_type": {"S": "action"},
      "id": {"N": "'"$aid"'"},
      "project_id": {"N": "'"$pid"'"},
      "description": {"S": "'"$(echo "$description" | sed 's/"/\\"/g')"'"},
      "status": {"S": "'"$status"'"},
      "created": {"S": "'"$ts"'"},
      "updated": {"S": "'"$ts"'"},
      "GSI1PK": {"S": "ACTION_STATUS#'"$status"'"},
      "GSI1SK": {"S": "'"$gsi1sk"'"}'
    [ -n "$owner" ] && item="$item"', "owner": {"S": "'"$owner"'"}'
    [ -n "$due_date" ] && item="$item"', "due_date": {"S": "'"$due_date"'"}'
    [ -n "$waiting_on" ] && item="$item"', "waiting_on": {"S": "'"$(echo "$waiting_on" | sed 's/"/\\"/g')"'"}'
    [ -n "$notes" ] && item="$item"', "notes": {"S": "'"$(echo "$notes" | sed 's/"/\\"/g')"'"}'
    item="$item"'}'
    aws dynamodb put-item --table-name "$TABLE" --item "$item" > /dev/null 2>&1
    log_status_change "$aid" "" "$status" "Created"
    pname=$(project_name "$pid")
    echo "Action #$aid added to $pname: $description"
    ;;

  list)
    arg1="$1"
    show_all=0
    project_filter=""
    if [ "$arg1" = "--all" ]; then
      show_all=1
    elif [ -n "$arg1" ]; then
      project_filter="$arg1"
      if [ "$2" = "--all" ]; then show_all=1; fi
    fi

    if [ -n "$project_filter" ]; then
      pid=$(resolve_project "$project_filter")
      if [ -z "$pid" ]; then
        echo "No project found matching: $project_filter"
        exit 1
      fi
      # Query actions for this project
      result=$(aws dynamodb query \
        --table-name "$TABLE" \
        --key-condition-expression "PK = :pk AND begins_with(SK, :sk)" \
        --expression-attribute-values '{":pk": {"S": "PROJECT#'"$pid"'"}, ":sk": {"S": "ACTION#"}}' \
        --output json 2>&1)
    else
      # Scan all actions
      result=$(aws dynamodb scan \
        --table-name "$TABLE" \
        --filter-expression "entity_type = :et" \
        --expression-attribute-values '{":et": {"S": "action"}}' \
        --output json 2>&1)
    fi

    local_show_all="$show_all"
    echo "$result" | jq -r --arg show_all "$local_show_all" '
      .Items
      | if $show_all == "0" then
          [.[] | select(.status.S == "open" or .status.S == "waiting" or .status.S == "in_progress")]
        else . end
      | sort_by(
          (if .status.S == "in_progress" then "1"
           elif .status.S == "waiting" then "2"
           elif .status.S == "open" then "3"
           elif .status.S == "done" then "4"
           else "5" end),
          (.due_date.S // "9999-12-31"))
      | ["ID", "Description", "Status", "Owner", "Due", "Waiting On"],
        ["--", "-----------", "------", "-----", "---", "----------"],
        (.[] | [.id.N, .description.S, .status.S, .owner.S // "-", .due_date.S // "-", .waiting_on.S // "-"]) |
      @tsv' | column -t -s $'\t'
    ;;

  done)
    aid="$1"; note="$2"
    if [ -z "$aid" ]; then echo "Usage: work done ID [note]"; exit 1; fi
    set_action_status "$aid" "done" "$note"
    ;;

  kill)
    aid="$1"; note="$2"
    if [ -z "$aid" ]; then echo "Usage: work kill ID [note]"; exit 1; fi
    set_action_status "$aid" "killed" "$note"
    ;;

  waiting)
    aid="$1"; waiting_on="$2"
    if [ -z "$aid" ] || [ -z "$waiting_on" ]; then echo 'Usage: work waiting ID "waiting on"'; exit 1; fi
    # First update waiting_on field
    action_data=$(find_action_keys "$aid")
    if [ -z "$action_data" ] || [ "$action_data" = "null" ]; then
      echo "Action #$aid not found."
      exit 1
    fi
    pk=$(echo "$action_data" | jq -r '.PK.S')
    sk=$(echo "$action_data" | jq -r '.SK.S')
    aws dynamodb update-item \
      --table-name "$TABLE" \
      --key '{"PK": {"S": "'"$pk"'"}, "SK": {"S": "'"$sk"'"}}' \
      --update-expression "SET waiting_on = :wo" \
      --expression-attribute-values '{":wo": {"S": "'"$(echo "$waiting_on" | sed 's/"/\\"/g')"'"}}' > /dev/null 2>&1
    set_action_status "$aid" "waiting" "Waiting on: $waiting_on"
    ;;

  start)
    aid="$1"
    if [ -z "$aid" ]; then echo "Usage: work start ID"; exit 1; fi
    set_action_status "$aid" "in_progress" ""
    ;;

  update)
    aid="$1"; new_notes="$2"
    if [ -z "$aid" ] || [ -z "$new_notes" ]; then echo 'Usage: work update ID "new notes"'; exit 1; fi
    action_data=$(find_action_keys "$aid")
    if [ -z "$action_data" ] || [ "$action_data" = "null" ]; then
      echo "Action #$aid not found."
      exit 1
    fi
    pk=$(echo "$action_data" | jq -r '.PK.S')
    sk=$(echo "$action_data" | jq -r '.SK.S')
    desc=$(echo "$action_data" | jq -r '.description.S')
    ts=$(now)
    # Get existing notes and append
    existing=$(aws dynamodb get-item \
      --table-name "$TABLE" \
      --key '{"PK": {"S": "'"$pk"'"}, "SK": {"S": "'"$sk"'"}}' \
      --projection-expression "notes" \
      --output json 2>&1 | jq -r '.Item.notes.S // ""')
    if [ -n "$existing" ]; then
      combined="$existing
$new_notes"
    else
      combined="$new_notes"
    fi
    aws dynamodb update-item \
      --table-name "$TABLE" \
      --key '{"PK": {"S": "'"$pk"'"}, "SK": {"S": "'"$sk"'"}}' \
      --update-expression "SET notes = :n, updated = :ts" \
      --expression-attribute-values '{":n": {"S": "'"$(echo "$combined" | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')"'"}, ":ts": {"S": "'"$ts"'"}}' > /dev/null 2>&1
    echo "Notes updated for action #$aid: $desc"
    ;;

  due)
    aid="$1"; due_date="$2"
    if [ -z "$aid" ] || [ -z "$due_date" ]; then echo "Usage: work due ID YYYY-MM-DD"; exit 1; fi
    action_data=$(find_action_keys "$aid")
    if [ -z "$action_data" ] || [ "$action_data" = "null" ]; then
      echo "Action #$aid not found."
      exit 1
    fi
    pk=$(echo "$action_data" | jq -r '.PK.S')
    sk=$(echo "$action_data" | jq -r '.SK.S')
    desc=$(echo "$action_data" | jq -r '.description.S')
    ts=$(now)
    aws dynamodb update-item \
      --table-name "$TABLE" \
      --key '{"PK": {"S": "'"$pk"'"}, "SK": {"S": "'"$sk"'"}}' \
      --update-expression "SET due_date = :dd, updated = :ts, GSI1SK = :gsi1sk" \
      --expression-attribute-values '{":dd": {"S": "'"$due_date"'"}, ":ts": {"S": "'"$ts"'"}, ":gsi1sk": {"S": "'"$due_date"'"}}' > /dev/null 2>&1
    echo "Due date set for action #$aid ($desc): $due_date"
    ;;

  overdue)
    today_str=$(today)
    # Query open actions, then filter overdue client-side
    for status in open waiting in_progress; do
      aws dynamodb query \
        --table-name "$TABLE" \
        --index-name GSI1 \
        --key-condition-expression "GSI1PK = :pk AND GSI1SK < :today" \
        --expression-attribute-values '{":pk": {"S": "ACTION_STATUS#'"$status"'"}, ":today": {"S": "'"$today_str"'"}}' \
        --output json 2>&1
    done | jq -s -r '
      [.[].Items[]] |
      sort_by(.due_date.S // "9999-12-31") |
      if length == 0 then "No overdue actions." else
        (["ID", "Project", "Description", "Status", "Due", "Owner"],
         ["--", "-------", "-----------", "------", "---", "-----"],
         (.[] | [.id.N, .project_id.N, .description.S, .status.S, .due_date.S // "-", .owner.S // "-"])) | @tsv
      end' | column -t -s $'\t'
    ;;

  history)
    # Scan action_log entries — for now scan all, filter by project if specified
    project_filter="$1"
    if [ -n "$project_filter" ]; then
      echo "History filtering by project not yet implemented in DynamoDB version."
      echo "Showing all recent history:"
    fi
    aws dynamodb scan \
      --table-name "$TABLE" \
      --filter-expression "entity_type = :et" \
      --expression-attribute-values '{":et": {"S": "action_log"}}' \
      --output json 2>&1 | jq -r '
      .Items | sort_by(.timestamp.S) | reverse | .[0:50] |
      ["Timestamp", "Action#", "Old", "New", "Note"],
      ["---------", "-------", "---", "---", "----"],
      (.[] | [.timestamp.S, .action_id.N, .old_status.S // "-", .new_status.S, .note.S // "-"]) |
      @tsv' | column -t -s $'\t'
    ;;

  status)
    echo "# Status Dashboard"
    echo ""
    echo "**Last updated**: $(today)"
    echo ""
    echo "---"
    echo ""

    # Fetch all active projects
    projects_json=$(aws dynamodb query \
      --table-name "$TABLE" \
      --index-name GSI1 \
      --key-condition-expression "GSI1PK = :pk" \
      --expression-attribute-values '{":pk": {"S": "PROJECT_STATUS#active"}}' \
      --output json 2>&1)

    # Fetch all non-done actions
    actions_json=$(jq -n '[]')
    for status in open waiting in_progress; do
      batch=$(aws dynamodb query \
        --table-name "$TABLE" \
        --index-name GSI1 \
        --key-condition-expression "GSI1PK = :pk" \
        --expression-attribute-values '{":pk": {"S": "ACTION_STATUS#'"$status"'"}}' \
        --output json 2>&1)
      actions_json=$(echo "$actions_json" "$batch" | jq -s '.[0] + (.[1].Items // [])')
    done

    # Deadlines
    echo "## Deadlines"
    echo ""
    today_str=$(today)
    echo "$actions_json" | jq -r --arg today "$today_str" '
      [.[] | select(.due_date.S != null and .due_date.S >= $today)] |
      sort_by(.due_date.S) |
      if length > 0 then
        "| Date | Item | Project |",
        "|------|------|---------|",
        (.[] | "| **\(.due_date.S)** | \(.description.S) | \(.project_id.N) |")
      else
        "*No upcoming deadlines.*"
      end'

    # Also show project deadlines
    echo "$projects_json" | jq -r --arg today "$today_str" '
      [.Items[] | select(.target_date.S != null and .target_date.S >= $today)] |
      sort_by(.target_date.S) |
      .[] | "| **\(.target_date.S)** | \(.name.S) (project deadline) | \(.institution.S // "-") |"'

    echo ""
    echo "---"
    echo ""

    # Active projects with their actions
    echo "## Active Projects"
    echo ""
    echo "$projects_json" | jq -r '.Items | sort_by(.institution.S // "", .name.S) | .[].id.N' | while read -r pid; do
      pdata=$(echo "$projects_json" | jq -r --arg pid "$pid" '.Items[] | select(.id.N == $pid)')
      pname=$(echo "$pdata" | jq -r '.name.S')
      pdesc=$(echo "$pdata" | jq -r '.description.S // empty')
      ptarget=$(echo "$pdata" | jq -r '.target_date.S // empty')

      echo "### $pname"
      [ -n "$pdesc" ] && echo "**$pdesc**"
      [ -n "$ptarget" ] && echo "**Target date: $ptarget**"
      echo ""

      # Get actions for this project
      project_actions=$(echo "$actions_json" | jq -r --arg pid "$pid" '
        [.[] | select(.project_id.N == $pid)] |
        sort_by(
          (if .status.S == "in_progress" then "1"
           elif .status.S == "waiting" then "2"
           else "3" end),
          (.due_date.S // "9999-12-31"))')

      action_count=$(echo "$project_actions" | jq 'length')
      if [ "$action_count" -gt 0 ]; then
        echo "| # | Thread | Status | Owner | Due | Notes |"
        echo "|---|--------|--------|-------|-----|-------|"
        echo "$project_actions" | jq -r '.[] |
          "| \(.id.N) | \(.description.S) | \(.status.S) | \(.owner.S // "—") | \(.due_date.S // "—") | \(
            (if .waiting_on.S then "Waiting on: \(.waiting_on.S)" else "" end) +
            (if .notes.S then (if .waiting_on.S then ". " else "" end) + .notes.S else "" end) // "—"
          ) |"'
      else
        echo "*No open actions.*"
      fi
      echo ""
    done

    echo "---"
    echo ""
    ;;

  generate)
    # Extract existing Work Log
    work_log=""
    if [ -f "$STATUS_FILE" ]; then
      work_log=$(sed -n '/^## Work Log/,$p' "$STATUS_FILE")
    fi

    {
      "$0" status

      if [ -n "$work_log" ]; then
        echo "$work_log"
      else
        echo "## Work Log"
        echo ""
        echo "Permanent record. One line per accomplishment."
        echo ""
      fi

      echo ""
      echo "---"
      echo ""
      echo "*Auto-generated on $(date '+%Y-%m-%d %H:%M:%S') by work.sh (DynamoDB)*"
    } > "$STATUS_FILE"

    echo "Generated: $STATUS_FILE"
    ;;

  help|*)
    echo "Steward Work CLI — project and action tracking (DynamoDB)"
    echo ""
    echo "Projects:"
    echo "  add-project \"name\" inst \"desc\" [date]    — add a project"
    echo "  projects [--all]                          — list projects"
    echo "  project-status ID status                  — change project status"
    echo ""
    echo "Actions:"
    echo '  add "PROJECT" "desc" [--status s] [--owner o] [--due DATE] [--waiting "who"] [--notes "text"]'
    echo "  list [PROJECT] [--all]                    — list actions"
    echo "  done ID [note]                            — mark done"
    echo "  kill ID [note]                            — mark killed"
    echo '  waiting ID "waiting on"                   — set waiting'
    echo "  start ID                                  — set in_progress"
    echo '  update ID "notes"                         — add notes'
    echo "  due ID YYYY-MM-DD                         — set due date"
    echo ""
    echo "Views:"
    echo "  status                                    — print status to stdout"
    echo "  overdue                                   — show overdue actions"
    echo "  history [PROJECT]                         — action history"
    echo ""
    echo "Generate:"
    echo "  generate                                  — write work/status.md"
    echo ""
    echo "Institutions: hu, ie, tec, personal, kai, bitb"
    echo "Action statuses: open, waiting, in_progress, done, killed"
    echo "Project statuses: active, paused, completed, killed"
    echo ""
    echo "Backend: DynamoDB table '$TABLE'"
    ;;
esac
