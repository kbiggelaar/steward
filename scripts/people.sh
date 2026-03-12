#!/bin/bash
# Steward People CLI — quick commands for relationship tracking
# Usage:
#   people.sh add "Name" context relationship [frequency_days] [contact_method]
#   people.sh log "Name" type "summary" [direction] [follow_up]
#   people.sh list [context]
#   people.sh info "Name"
#   people.sh due                  — who needs attention
#   people.sh birthdays            — upcoming birthdays
#   people.sh note "Name" "note"   — update notes for a person
#   people.sh birthday "Name" "MM-DD" or "YYYY-MM-DD"
#   people.sh freq "Name" days     — set contact frequency
#   people.sh search "term"        — fuzzy search across names and notes

DB="$HOME/.claude/activity.db"

cmd="${1:-help}"
shift

case "$cmd" in
  add)
    name="$1"; context="$2"; relationship="$3"
    freq="${4:-30}"; method="${5:-}"
    if [ -z "$name" ] || [ -z "$context" ]; then
      echo "Usage: people.sh add \"Name\" context relationship [frequency_days] [contact_method]"
      echo "  context: work, personal, family, friend (customize as needed)"
      echo "  relationship: colleague, student, mentor, friend, family, collaborator"
      exit 1
    fi
    sqlite3 "$DB" "INSERT INTO people (name, context, relationship, contact_frequency_days, contact_method) VALUES ('$(echo "$name" | sed "s/'/''/g")', '$context', '$relationship', $freq, '$method');"
    echo "Added: $name ($context / $relationship, every ${freq}d)"
    ;;

  log)
    name="$1"; type="$2"; summary="$3"
    direction="${4:-outgoing}"; follow_up="${5:-}"
    if [ -z "$name" ] || [ -z "$type" ]; then
      echo "Usage: people.sh log \"Name\" type \"summary\" [direction] [follow_up]"
      echo "  type: message, call, meeting, email, coffee, lunch, video"
      echo "  direction: outgoing, incoming, mutual"
      exit 1
    fi
    person_id=$(sqlite3 "$DB" "SELECT id FROM people WHERE name LIKE '%$(echo "$name" | sed "s/'/''/g")%' AND archived=0 LIMIT 1;")
    if [ -z "$person_id" ]; then
      echo "No person found matching: $name"
      exit 1
    fi
    actual_name=$(sqlite3 "$DB" "SELECT name FROM people WHERE id=$person_id;")
    sqlite3 "$DB" "INSERT INTO interactions (person_id, type, direction, summary, follow_up) VALUES ($person_id, '$type', '$direction', '$(echo "$summary" | sed "s/'/''/g")', '$(echo "$follow_up" | sed "s/'/''/g")');"
    echo "Logged $type with $actual_name: $summary"
    ;;

  list)
    context="$1"
    if [ -n "$context" ]; then
      sqlite3 -header -column "$DB" "
        SELECT p.name, p.context, p.relationship, p.contact_frequency_days as freq,
               MAX(i.timestamp) as last_contact,
               COALESCE(CAST(julianday('now','localtime') - julianday(MAX(i.timestamp)) AS INTEGER), '—') as days_ago
        FROM people p LEFT JOIN interactions i ON i.person_id = p.id
        WHERE p.archived=0 AND p.context='$context'
        GROUP BY p.id ORDER BY p.name;"
    else
      sqlite3 -header -column "$DB" "
        SELECT p.name, p.context, p.relationship, p.contact_frequency_days as freq,
               MAX(i.timestamp) as last_contact,
               COALESCE(CAST(julianday('now','localtime') - julianday(MAX(i.timestamp)) AS INTEGER), '—') as days_ago
        FROM people p LEFT JOIN interactions i ON i.person_id = p.id
        WHERE p.archived=0
        GROUP BY p.id ORDER BY p.context, p.name;"
    fi
    ;;

  info)
    name="$1"
    if [ -z "$name" ]; then echo "Usage: people.sh info \"Name\""; exit 1; fi
    person_id=$(sqlite3 "$DB" "SELECT id FROM people WHERE name LIKE '%$(echo "$name" | sed "s/'/''/g")%' AND archived=0 LIMIT 1;")
    if [ -z "$person_id" ]; then echo "No person found matching: $name"; exit 1; fi
    echo "=== Profile ==="
    sqlite3 -header -column "$DB" "SELECT name, context, relationship, contact_method, contact_frequency_days as freq, birthday, notes FROM people WHERE id=$person_id;"
    echo ""
    echo "=== Recent Interactions ==="
    sqlite3 -header -column "$DB" "SELECT timestamp, type, direction, summary, follow_up FROM interactions WHERE person_id=$person_id ORDER BY timestamp DESC LIMIT 10;"
    ;;

  due)
    echo "=== People to reach out to ==="
    sqlite3 -header -column "$DB" "SELECT * FROM v_reach_out;"
    ;;

  birthdays)
    echo "=== Upcoming birthdays (next 14 days) ==="
    sqlite3 -header -column "$DB" "SELECT * FROM v_upcoming_dates;"
    ;;

  note)
    name="$1"; note="$2"
    if [ -z "$name" ] || [ -z "$note" ]; then echo "Usage: people.sh note \"Name\" \"note text\""; exit 1; fi
    person_id=$(sqlite3 "$DB" "SELECT id FROM people WHERE name LIKE '%$(echo "$name" | sed "s/'/''/g")%' AND archived=0 LIMIT 1;")
    if [ -z "$person_id" ]; then echo "No person found matching: $name"; exit 1; fi
    # Append to existing notes
    sqlite3 "$DB" "UPDATE people SET notes = COALESCE(notes || char(10), '') || '$(echo "$note" | sed "s/'/''/g")' WHERE id=$person_id;"
    actual_name=$(sqlite3 "$DB" "SELECT name FROM people WHERE id=$person_id;")
    echo "Note added for $actual_name"
    ;;

  birthday)
    name="$1"; bday="$2"
    if [ -z "$name" ] || [ -z "$bday" ]; then echo "Usage: people.sh birthday \"Name\" \"MM-DD\""; exit 1; fi
    person_id=$(sqlite3 "$DB" "SELECT id FROM people WHERE name LIKE '%$(echo "$name" | sed "s/'/''/g")%' AND archived=0 LIMIT 1;")
    if [ -z "$person_id" ]; then echo "No person found matching: $name"; exit 1; fi
    sqlite3 "$DB" "UPDATE people SET birthday='$bday' WHERE id=$person_id;"
    actual_name=$(sqlite3 "$DB" "SELECT name FROM people WHERE id=$person_id;")
    echo "Birthday set for $actual_name: $bday"
    ;;

  freq)
    name="$1"; days="$2"
    if [ -z "$name" ] || [ -z "$days" ]; then echo "Usage: people.sh freq \"Name\" days"; exit 1; fi
    person_id=$(sqlite3 "$DB" "SELECT id FROM people WHERE name LIKE '%$(echo "$name" | sed "s/'/''/g")%' AND archived=0 LIMIT 1;")
    if [ -z "$person_id" ]; then echo "No person found matching: $name"; exit 1; fi
    sqlite3 "$DB" "UPDATE people SET contact_frequency_days=$days WHERE id=$person_id;"
    actual_name=$(sqlite3 "$DB" "SELECT name FROM people WHERE id=$person_id;")
    echo "Contact frequency for $actual_name set to every ${days} days"
    ;;

  search)
    term="$1"
    if [ -z "$term" ]; then echo "Usage: people.sh search \"term\""; exit 1; fi
    sqlite3 -header -column "$DB" "
      SELECT p.name, p.context, p.relationship, p.notes,
             MAX(i.timestamp) as last_contact
      FROM people p LEFT JOIN interactions i ON i.person_id = p.id
      WHERE p.archived=0 AND (p.name LIKE '%$term%' OR p.notes LIKE '%$term%' OR p.context LIKE '%$term%')
      GROUP BY p.id ORDER BY p.name;"
    ;;

  help|*)
    echo "Steward People CLI"
    echo ""
    echo "Commands:"
    echo "  add \"Name\" context relationship [freq] [method]  — add a person"
    echo "  log \"Name\" type \"summary\" [direction] [follow_up] — log interaction"
    echo "  list [context]                                     — list people"
    echo "  info \"Name\"                                        — full profile + history"
    echo "  due                                                — who needs attention"
    echo "  birthdays                                          — upcoming birthdays"
    echo "  note \"Name\" \"note\"                                 — add a note"
    echo "  birthday \"Name\" \"MM-DD\"                            — set birthday"
    echo "  freq \"Name\" days                                   — set contact frequency"
    echo "  search \"term\"                                      — search names & notes"
    echo ""
    echo "Contexts: work, personal, family, friend (customize as needed)"
    echo "Types: message, call, meeting, email, coffee, lunch, video"
    ;;
esac
