#!/bin/bash
# Steward Work CLI — project and action tracking
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

DB="$HOME/.claude/activity.db"
STATUS_FILE="$HOME/projects/work/status.md"

# Helper: escape single quotes for SQL
esc() {
  echo "$1" | sed "s/'/''/g"
}

# Helper: resolve project name or ID to project ID
resolve_project() {
  local input="$1"
  local pid
  # Try as integer ID first
  if [[ "$input" =~ ^[0-9]+$ ]]; then
    pid=$(sqlite3 "$DB" "SELECT id FROM projects WHERE id=$input;")
    if [ -n "$pid" ]; then echo "$pid"; return 0; fi
  fi
  # Try case-insensitive LIKE match
  pid=$(sqlite3 "$DB" "SELECT id FROM projects WHERE name LIKE '%$(esc "$input")%' COLLATE NOCASE LIMIT 1;")
  if [ -n "$pid" ]; then echo "$pid"; return 0; fi
  echo ""
  return 1
}

# Helper: log status change
log_status_change() {
  local action_id="$1" old_status="$2" new_status="$3" note="$4"
  sqlite3 "$DB" "INSERT INTO action_log (action_id, old_status, new_status, note) VALUES ($action_id, '$(esc "$old_status")', '$(esc "$new_status")', '$(esc "$note")');"
}

# Helper: update action status
set_action_status() {
  local action_id="$1" new_status="$2" note="$3"
  local old_status
  old_status=$(sqlite3 "$DB" "SELECT status FROM actions WHERE id=$action_id;")
  if [ -z "$old_status" ]; then
    echo "Action #$action_id not found."
    exit 1
  fi
  local completed_clause=""
  if [ "$new_status" = "done" ] || [ "$new_status" = "killed" ]; then
    completed_clause=", completed=datetime('now','localtime')"
  fi
  sqlite3 "$DB" "UPDATE actions SET status='$(esc "$new_status")', updated=datetime('now','localtime')${completed_clause} WHERE id=$action_id;"
  log_status_change "$action_id" "$old_status" "$new_status" "$note"
  local desc
  desc=$(sqlite3 "$DB" "SELECT description FROM actions WHERE id=$action_id;")
  echo "Action #$action_id → $new_status: $desc"
}

cmd="${1:-help}"
shift 2>/dev/null

case "$cmd" in

  add-project)
    name="$1"; institution="$2"; description="$3"; target_date="$4"
    if [ -z "$name" ] || [ -z "$institution" ]; then
      echo "Usage: work add-project \"name\" institution \"description\" [target_date]"
      echo "  institution: work, personal, side-project (customize as needed)"
      exit 1
    fi
    sqlite3 "$DB" "INSERT INTO projects (name, institution, description, target_date) VALUES ('$(esc "$name")', '$(esc "$institution")', '$(esc "$description")', $([ -n "$target_date" ] && echo "'$target_date'" || echo "NULL"));"
    pid=$(sqlite3 "$DB" "SELECT last_insert_rowid();")
    echo "Project #$pid added: $name ($institution)"
    ;;

  projects)
    filter="${1:-active}"
    if [ "$filter" = "--all" ]; then
      sqlite3 -header -column "$DB" "
        SELECT p.id, p.name, p.institution, p.status, p.target_date,
               COUNT(CASE WHEN a.status IN ('open','waiting','in_progress') THEN 1 END) as open_actions
        FROM projects p
        LEFT JOIN actions a ON a.project_id = p.id
        GROUP BY p.id
        ORDER BY p.institution, p.name;"
    else
      sqlite3 -header -column "$DB" "
        SELECT p.id, p.name, p.institution, p.status, p.target_date,
               COUNT(CASE WHEN a.status IN ('open','waiting','in_progress') THEN 1 END) as open_actions
        FROM projects p
        LEFT JOIN actions a ON a.project_id = p.id
        WHERE p.status = 'active'
        GROUP BY p.id
        ORDER BY p.institution, p.name;"
    fi
    ;;

  project-status)
    pid="$1"; new_status="$2"
    if [ -z "$pid" ] || [ -z "$new_status" ]; then
      echo "Usage: work project-status ID status"
      echo "  status: active, paused, completed, killed"
      exit 1
    fi
    sqlite3 "$DB" "UPDATE projects SET status='$(esc "$new_status")', updated=datetime('now','localtime') WHERE id=$pid;"
    pname=$(sqlite3 "$DB" "SELECT name FROM projects WHERE id=$pid;")
    echo "Project #$pid ($pname) → $new_status"
    ;;

  add)
    project_input="$1"; description="$2"
    shift 2 2>/dev/null
    if [ -z "$project_input" ] || [ -z "$description" ]; then
      echo "Usage: work add \"PROJECT\" \"description\" [--status s] [--owner o] [--due DATE] [--waiting \"who\"] [--notes \"text\"]"
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
    sqlite3 "$DB" "INSERT INTO actions (project_id, description, status, owner, due_date, waiting_on, notes) VALUES ($pid, '$(esc "$description")', '$(esc "$status")', $([ -n "$owner" ] && echo "'$(esc "$owner")'" || echo "NULL"), $([ -n "$due_date" ] && echo "'$due_date'" || echo "NULL"), $([ -n "$waiting_on" ] && echo "'$(esc "$waiting_on")'" || echo "NULL"), $([ -n "$notes" ] && echo "'$(esc "$notes")'" || echo "NULL"));"
    aid=$(sqlite3 "$DB" "SELECT last_insert_rowid();")
    log_status_change "$aid" "" "$status" "Created"
    pname=$(sqlite3 "$DB" "SELECT name FROM projects WHERE id=$pid;")
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
      # Check for --all as second arg
      if [ "$2" = "--all" ]; then show_all=1; fi
    fi
    status_filter="AND a.status IN ('open','waiting','in_progress')"
    if [ "$show_all" = "1" ]; then
      status_filter=""
    fi
    project_clause=""
    if [ -n "$project_filter" ]; then
      pid=$(resolve_project "$project_filter")
      if [ -z "$pid" ]; then
        echo "No project found matching: $project_filter"
        exit 1
      fi
      project_clause="AND a.project_id = $pid"
    fi
    sqlite3 -header -column "$DB" "
      SELECT a.id, p.name as project, a.description, a.status, a.owner, a.due_date, a.waiting_on, a.notes
      FROM actions a
      JOIN projects p ON p.id = a.project_id
      WHERE 1=1 $status_filter $project_clause
      ORDER BY p.institution, p.name,
        CASE a.status
          WHEN 'in_progress' THEN 1
          WHEN 'waiting' THEN 2
          WHEN 'open' THEN 3
          WHEN 'done' THEN 4
          WHEN 'killed' THEN 5
        END,
        a.due_date NULLS LAST;"
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
    if [ -z "$aid" ] || [ -z "$waiting_on" ]; then echo "Usage: work waiting ID \"waiting on\""; exit 1; fi
    sqlite3 "$DB" "UPDATE actions SET waiting_on='$(esc "$waiting_on")', updated=datetime('now','localtime') WHERE id=$aid;"
    set_action_status "$aid" "waiting" "Waiting on: $waiting_on"
    ;;

  start)
    aid="$1"
    if [ -z "$aid" ]; then echo "Usage: work start ID"; exit 1; fi
    set_action_status "$aid" "in_progress" ""
    ;;

  update)
    aid="$1"; new_notes="$2"
    if [ -z "$aid" ] || [ -z "$new_notes" ]; then echo "Usage: work update ID \"new notes\""; exit 1; fi
    sqlite3 "$DB" "UPDATE actions SET notes = COALESCE(notes || char(10), '') || '$(esc "$new_notes")', updated=datetime('now','localtime') WHERE id=$aid;"
    desc=$(sqlite3 "$DB" "SELECT description FROM actions WHERE id=$aid;")
    echo "Notes updated for action #$aid: $desc"
    ;;

  due)
    aid="$1"; due_date="$2"
    if [ -z "$aid" ] || [ -z "$due_date" ]; then echo "Usage: work due ID YYYY-MM-DD"; exit 1; fi
    sqlite3 "$DB" "UPDATE actions SET due_date='$due_date', updated=datetime('now','localtime') WHERE id=$aid;"
    desc=$(sqlite3 "$DB" "SELECT description FROM actions WHERE id=$aid;")
    echo "Due date set for action #$aid ($desc): $due_date"
    ;;

  overdue)
    sqlite3 -header -column "$DB" "
      SELECT a.id, p.name as project, a.description, a.status, a.due_date, a.owner, a.waiting_on
      FROM actions a
      JOIN projects p ON p.id = a.project_id
      WHERE a.status IN ('open','waiting','in_progress')
        AND a.due_date IS NOT NULL
        AND a.due_date < date('now','localtime')
      ORDER BY a.due_date;"
    ;;

  history)
    project_filter="$1"
    project_clause=""
    if [ -n "$project_filter" ]; then
      pid=$(resolve_project "$project_filter")
      if [ -z "$pid" ]; then
        echo "No project found matching: $project_filter"
        exit 1
      fi
      project_clause="AND a.project_id = $pid"
    fi
    sqlite3 -header -column "$DB" "
      SELECT al.timestamp, p.name as project, a.description, al.old_status, al.new_status, al.note
      FROM action_log al
      JOIN actions a ON a.id = al.action_id
      JOIN projects p ON p.id = a.project_id
      WHERE 1=1 $project_clause
      ORDER BY al.timestamp DESC
      LIMIT 50;"
    ;;

  status)
    # Print status.md content to stdout
    _generate_status() {
      echo "# Status Dashboard"
      echo ""
      echo "**Last updated**: $(date +%Y-%m-%d)"
      echo ""
      echo "---"
      echo ""

      # Deadlines section
      echo "## Deadlines"
      echo ""
      local deadlines
      deadlines=$(sqlite3 -separator '|' "$DB" "
        SELECT a.due_date, a.description, p.name
        FROM actions a
        JOIN projects p ON p.id = a.project_id
        WHERE a.status IN ('open','waiting','in_progress')
          AND a.due_date IS NOT NULL
          AND a.due_date >= date('now','localtime')
        ORDER BY a.due_date
        LIMIT 20;")
      local proj_deadlines
      proj_deadlines=$(sqlite3 -separator '|' "$DB" "
        SELECT target_date, name || ' (project deadline)', institution
        FROM projects
        WHERE status = 'active'
          AND target_date IS NOT NULL
          AND target_date >= date('now','localtime')
        ORDER BY target_date;")
      if [ -n "$deadlines" ] || [ -n "$proj_deadlines" ]; then
        echo "| Date | Item | Project |"
        echo "|------|------|---------|"
        # Combine and sort
        { [ -n "$deadlines" ] && echo "$deadlines"; [ -n "$proj_deadlines" ] && echo "$proj_deadlines"; } | sort | while IFS='|' read -r dt item proj; do
          echo "| **$dt** | $item | $proj |"
        done
      else
        echo "*No upcoming deadlines.*"
      fi
      echo ""
      echo "---"
      echo ""

      # Active projects
      echo "## Active Projects"
      echo ""
      sqlite3 -separator '|' "$DB" "
        SELECT p.id, p.name, p.institution, p.description, p.target_date
        FROM projects p
        WHERE p.status = 'active'
        ORDER BY p.institution, p.name;" | while IFS='|' read -r pid pname inst pdesc ptarget; do
        echo "### $pname"
        if [ -n "$pdesc" ]; then
          echo "**$pdesc**"
        fi
        if [ -n "$ptarget" ]; then
          echo "**Target date: $ptarget**"
        fi
        echo ""
        local actions
        actions=$(sqlite3 -separator '|' "$DB" "
          SELECT a.id, a.description, a.status, a.owner, a.due_date, a.waiting_on, a.notes
          FROM actions a
          WHERE a.project_id = $pid AND a.status IN ('open','waiting','in_progress')
          ORDER BY
            CASE a.status
              WHEN 'in_progress' THEN 1
              WHEN 'waiting' THEN 2
              WHEN 'open' THEN 3
            END,
            a.due_date NULLS LAST;")
        if [ -n "$actions" ]; then
          echo "| # | Thread | Status | Owner | Due | Notes |"
          echo "|---|--------|--------|-------|-----|-------|"
          echo "$actions" | while IFS='|' read -r aid adesc astatus aowner adue awaiting anotes; do
            local display_notes=""
            [ -n "$awaiting" ] && display_notes="Waiting on: $awaiting"
            [ -n "$anotes" ] && display_notes="${display_notes:+$display_notes. }$anotes"
            echo "| $aid | $adesc | $astatus | ${aowner:-—} | ${adue:-—} | ${display_notes:-—} |"
          done
        else
          echo "*No open actions.*"
        fi
        echo ""
      done

      echo "---"
      echo ""
    }
    _generate_status
    ;;

  generate)
    # Generate status.md and write to file
    # First, extract the Work Log section from existing file
    work_log=""
    if [ -f "$STATUS_FILE" ]; then
      work_log=$(sed -n '/^## Work Log/,$p' "$STATUS_FILE")
    fi

    # Generate the top part
    {
      # Reuse the status command output
      "$0" status

      # Append work log
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
      echo "*Auto-generated on $(date '+%Y-%m-%d %H:%M:%S') by work.sh*"
    } > "$STATUS_FILE"

    echo "Generated: $STATUS_FILE"
    ;;

  help|*)
    echo "Steward Work CLI — project and action tracking"
    echo ""
    echo "Projects:"
    echo "  add-project \"name\" inst \"desc\" [date]    — add a project"
    echo "  projects [--all]                          — list projects"
    echo "  project-status ID status                  — change project status"
    echo ""
    echo "Actions:"
    echo "  add \"PROJECT\" \"desc\" [--status s] [--owner o] [--due DATE] [--waiting \"who\"] [--notes \"text\"]"
    echo "  list [PROJECT] [--all]                    — list actions"
    echo "  done ID [note]                            — mark done"
    echo "  kill ID [note]                            — mark killed"
    echo "  waiting ID \"waiting on\"                   — set waiting"
    echo "  start ID                                  — set in_progress"
    echo "  update ID \"notes\"                         — add notes"
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
    echo "Institutions: customize as needed (e.g., work, personal, side-project)"
    echo "Action statuses: open, waiting, in_progress, done, killed"
    echo "Project statuses: active, paused, completed, killed"
    ;;
esac
