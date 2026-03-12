#!/bin/bash
# Steward Habits CLI — habit tracking and check-ins
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

DB="$HOME/.claude/activity.db"
HABITS_FILE="$HOME/projects/work/habits.md"

# Helper: escape single quotes for SQL
esc() {
  echo "$1" | sed "s/'/''/g"
}

# Helper: resolve habit name (case-insensitive partial match)
resolve_habit() {
  local input="$1"
  local hid
  # Try exact match first
  hid=$(sqlite3 "$DB" "SELECT id FROM habits WHERE name = '$(esc "$input")' COLLATE NOCASE LIMIT 1;")
  if [ -n "$hid" ]; then echo "$hid"; return 0; fi
  # Try partial match
  hid=$(sqlite3 "$DB" "SELECT id FROM habits WHERE name LIKE '%$(esc "$input")%' COLLATE NOCASE LIMIT 1;")
  if [ -n "$hid" ]; then echo "$hid"; return 0; fi
  echo ""
  return 1
}

# Helper: get habit name by id
habit_name() {
  sqlite3 "$DB" "SELECT name FROM habits WHERE id=$1;"
}

# Helper: get the Monday of the week containing a date
week_monday() {
  local d="${1:-$(date +%Y-%m-%d)}"
  python3 -c "
from datetime import date, timedelta
d = date.fromisoformat('$d')
monday = d - timedelta(days=d.weekday())
print(monday.isoformat())
"
}

# Helper: get the Sunday of the week containing a date
week_sunday() {
  local d="${1:-$(date +%Y-%m-%d)}"
  python3 -c "
from datetime import date, timedelta
d = date.fromisoformat('$d')
sunday = d + timedelta(days=6 - d.weekday())
print(sunday.isoformat())
"
}

# Helper: format date as "Month Day"
fmt_date() {
  python3 -c "
from datetime import date
d = date.fromisoformat('$1')
print(d.strftime('%B %-d'))
"
}

# Helper: get day of week name
day_name() {
  python3 -c "
from datetime import date
d = date.fromisoformat('$1')
print(d.strftime('%A'))
"
}

# Helper: short day name
short_day() {
  python3 -c "
from datetime import date
d = date.fromisoformat('$1')
print(d.strftime('%a'))
"
}

# Helper: calculate streak for a habit
calc_streak() {
  local hid="$1"
  local freq
  freq=$(sqlite3 "$DB" "SELECT frequency FROM habits WHERE id=$hid;")

  if [ "$freq" = "daily" ]; then
    # Count consecutive days with done='y' going backwards from today
    python3 -c "
import sqlite3, os
from datetime import date, timedelta

db = sqlite3.connect(os.path.expanduser('~/.claude/activity.db'))
today = date.today()
streak = 0
d = today
while True:
    row = db.execute('SELECT done FROM habit_log WHERE habit_id=? AND date=?', ($hid, d.isoformat())).fetchone()
    if row and row[0] == 'y':
        streak += 1
        d -= timedelta(days=1)
    else:
        break
db.close()
print(streak)
"
  else
    # Weekly: count this week's completions vs target
    local monday
    monday=$(week_monday)
    local sunday
    sunday=$(week_sunday)
    local count
    count=$(sqlite3 "$DB" "SELECT COUNT(*) FROM habit_log WHERE habit_id=$hid AND date BETWEEN '$monday' AND '$sunday' AND done='y';")
    echo "$count"
  fi
}

cmd="${1:-help}"
shift 2>/dev/null

case "$cmd" in

  add)
    name="$1"
    shift 2>/dev/null
    if [ -z "$name" ]; then
      echo "Usage: habits add \"name\" --rule \"description\" [--freq daily|weekly] [--target N]"
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
    if [ "$freq" = "weekly" ] && [ "$target" = "7" ]; then
      target=1
    fi
    started_clause=""
    if [ -n "$started" ]; then
      started_clause=", started"
    fi
    started_value=""
    if [ -n "$started" ]; then
      started_value=", '$started'"
    fi
    sqlite3 "$DB" "INSERT INTO habits (name, rule, frequency, target_per_week${started_clause}) VALUES ('$(esc "$name")', '$(esc "$rule")', '$freq', $target${started_value});"
    echo "Habit added: $name ($freq, target $target/week)"
    ;;

  pause)
    name="$1"
    if [ -z "$name" ]; then echo "Usage: habits pause \"name\""; exit 1; fi
    hid=$(resolve_habit "$name")
    if [ -z "$hid" ]; then echo "No habit found matching: $name"; exit 1; fi
    sqlite3 "$DB" "UPDATE habits SET status='paused' WHERE id=$hid;"
    echo "Paused: $(habit_name $hid)"
    ;;

  retire)
    name="$1"
    if [ -z "$name" ]; then echo "Usage: habits retire \"name\""; exit 1; fi
    hid=$(resolve_habit "$name")
    if [ -z "$hid" ]; then echo "No habit found matching: $name"; exit 1; fi
    sqlite3 "$DB" "UPDATE habits SET status='retired' WHERE id=$hid;"
    echo "Retired: $(habit_name $hid)"
    ;;

  resume)
    name="$1"
    if [ -z "$name" ]; then echo "Usage: habits resume \"name\""; exit 1; fi
    hid=$(resolve_habit "$name")
    if [ -z "$hid" ]; then echo "No habit found matching: $name"; exit 1; fi
    sqlite3 "$DB" "UPDATE habits SET status='active' WHERE id=$hid;"
    echo "Resumed: $(habit_name $hid)"
    ;;

  list)
    sqlite3 -header -column "$DB" "
      SELECT id, name, frequency, target_per_week as target, status, started
      FROM habits
      WHERE status='active'
      ORDER BY started, name;"
    ;;

  check)
    name="$1"; done_val="$2"; note="$3"
    if [ -z "$name" ] || [ -z "$done_val" ]; then
      echo "Usage: habits check \"name\" y|n [\"note\"]"
      exit 1
    fi
    hid=$(resolve_habit "$name")
    if [ -z "$hid" ]; then echo "No habit found matching: $name"; exit 1; fi
    actual_name=$(habit_name $hid)
    # Upsert: insert or replace on conflict
    sqlite3 "$DB" "INSERT INTO habit_log (habit_id, date, done, note)
      VALUES ($hid, date('now','localtime'), '$done_val', $([ -n "$note" ] && echo "'$(esc "$note")'" || echo "NULL"))
      ON CONFLICT(habit_id, date) DO UPDATE SET done='$done_val', note=$([ -n "$note" ] && echo "'$(esc "$note")'" || echo "note"), logged_at=datetime('now','localtime');"
    if [ "$done_val" = "y" ]; then
      streak=$(calc_streak $hid)
      echo "Done: $actual_name — ${streak}-day streak"
    else
      echo "Missed: $actual_name — logged as missed${note:+ ($note)}"
    fi
    ;;

  miss)
    name="$1"; note="$2"
    if [ -z "$name" ]; then echo "Usage: habits miss \"name\" [\"note\"]"; exit 1; fi
    hid=$(resolve_habit "$name")
    if [ -z "$hid" ]; then echo "No habit found matching: $name"; exit 1; fi
    actual_name=$(habit_name $hid)
    sqlite3 "$DB" "INSERT INTO habit_log (habit_id, date, done, note)
      VALUES ($hid, date('now','localtime'), 'n', $([ -n "$note" ] && echo "'$(esc "$note")'" || echo "NULL"))
      ON CONFLICT(habit_id, date) DO UPDATE SET done='n', note=$([ -n "$note" ] && echo "'$(esc "$note")'" || echo "note"), logged_at=datetime('now','localtime');"
    echo "Missed: $actual_name — logged as missed${note:+ ($note)}"
    ;;

  today)
    python3 -c "
import sqlite3, os
from datetime import date, timedelta

db = sqlite3.connect(os.path.expanduser('~/.claude/activity.db'))
today = date.today()
day_name = today.strftime('%A')
print(f'{today.strftime(\"%B %-d, %Y\")} ({day_name}):')

monday = today - timedelta(days=today.weekday())
sunday = monday + timedelta(days=6)

habits = db.execute('SELECT id, name, frequency, target_per_week FROM habits WHERE status=\"active\" ORDER BY started, name').fetchall()
for hid, name, freq, target in habits:
    log = db.execute('SELECT done FROM habit_log WHERE habit_id=? AND date=?', (hid, today.isoformat())).fetchone()
    week_count = db.execute('SELECT COUNT(*) FROM habit_log WHERE habit_id=? AND date BETWEEN ? AND ? AND done=\"y\"',
                            (hid, monday.isoformat(), sunday.isoformat())).fetchone()[0]

    if freq == 'daily':
        if log and log[0] == 'y':
            print(f'  [x] {name}')
        elif log and log[0] == 'n':
            print(f'  [-] {name}')
        else:
            print(f'  [ ] {name}')
    else:
        # Weekly habit
        if log and log[0] == 'y':
            print(f'  [x] {name} ({week_count}/{target} this week)')
        elif log and log[0] == 'n':
            print(f'  [-] {name} ({week_count}/{target} this week)')
        else:
            print(f'  [ ] {name} ({week_count}/{target} this week)')
db.close()
"
    ;;

  week)
    ref_date="${1:-$(date +%Y-%m-%d)}"
    python3 -c "
import sqlite3, os
from datetime import date, timedelta

db = sqlite3.connect(os.path.expanduser('~/.claude/activity.db'))
ref = date.fromisoformat('$ref_date')
monday = ref - timedelta(days=ref.weekday())
sunday = monday + timedelta(days=6)

print(f'Week of {monday.strftime(\"%B %-d\")}–{sunday.strftime(\"%-d, %Y\")}:')

habits = db.execute('SELECT id, name, frequency, target_per_week FROM habits WHERE status=\"active\" ORDER BY started, name').fetchall()
today = date.today()

for hid, name, freq, target in habits:
    denom = 7 if freq == 'daily' else target
    done_count = db.execute('SELECT COUNT(*) FROM habit_log WHERE habit_id=? AND date BETWEEN ? AND ? AND done=\"y\"',
                            (hid, monday.isoformat(), sunday.isoformat())).fetchone()[0]

    # Calculate streak for daily habits
    streak_str = ''
    if freq == 'daily':
        streak = 0
        d = today
        while True:
            row = db.execute('SELECT done FROM habit_log WHERE habit_id=? AND date=?', (hid, d.isoformat())).fetchone()
            if row and row[0] == 'y':
                streak += 1
                d -= timedelta(days=1)
            else:
                break
        if streak > 0:
            streak_str = f'  {streak}-day streak' if done_count == denom else ''

    # Find missed days for daily habits
    missed_days = []
    if freq == 'daily':
        for i in range(7):
            d = monday + timedelta(days=i)
            if d > today:
                break
            row = db.execute('SELECT done FROM habit_log WHERE habit_id=? AND date=?', (hid, d.isoformat())).fetchone()
            if row and row[0] == 'n':
                missed_days.append(d.strftime('%a'))

    # Determine indicator
    if freq == 'daily':
        ratio = done_count / min(denom, max(1, (min(today, sunday) - monday).days + 1))
        if done_count == denom:
            indicator = f'{streak}-day streak' if freq == 'daily' and streak > 0 else 'complete'
        elif ratio < 0.7:
            missed_str = ', '.join(missed_days)
            indicator = f'missed {missed_str}' if missed_days else 'needs attention'
        else:
            if missed_days:
                missed_str = ', '.join(missed_days)
                indicator = f'missed {missed_str}'
            else:
                indicator = ''
    else:
        if done_count >= target:
            indicator = 'done'
        elif done_count == 0:
            indicator = 'needs attention'
        else:
            indicator = ''

    target_str = f'(target: {target}/week)' if freq == 'weekly' else ''
    line = f'  {name + \":\":<30s} {done_count}/{denom}  {indicator} {target_str}'.rstrip()
    print(line)

db.close()
"
    ;;

  streak)
    name="$1"
    if [ -z "$name" ]; then echo "Usage: habits streak \"name\""; exit 1; fi
    hid=$(resolve_habit "$name")
    if [ -z "$hid" ]; then echo "No habit found matching: $name"; exit 1; fi
    actual_name=$(habit_name $hid)
    freq=$(sqlite3 "$DB" "SELECT frequency FROM habits WHERE id=$hid;")
    s=$(calc_streak $hid)
    if [ "$freq" = "daily" ]; then
      echo "$actual_name: ${s}-day streak"
    else
      target=$(sqlite3 "$DB" "SELECT target_per_week FROM habits WHERE id=$hid;")
      echo "$actual_name: $s/$target this week"
    fi
    ;;

  streaks)
    python3 -c "
import sqlite3, os
from datetime import date, timedelta

db = sqlite3.connect(os.path.expanduser('~/.claude/activity.db'))
today = date.today()
monday = today - timedelta(days=today.weekday())
sunday = monday + timedelta(days=6)

habits = db.execute('SELECT id, name, frequency, target_per_week FROM habits WHERE status=\"active\" ORDER BY started, name').fetchall()
for hid, name, freq, target in habits:
    if freq == 'daily':
        streak = 0
        d = today
        while True:
            row = db.execute('SELECT done FROM habit_log WHERE habit_id=? AND date=?', (hid, d.isoformat())).fetchone()
            if row and row[0] == 'y':
                streak += 1
                d -= timedelta(days=1)
            else:
                break
        print(f'  {name}: {streak}-day streak')
    else:
        count = db.execute('SELECT COUNT(*) FROM habit_log WHERE habit_id=? AND date BETWEEN ? AND ? AND done=\"y\"',
                           (hid, monday.isoformat(), sunday.isoformat())).fetchone()[0]
        print(f'  {name}: {count}/{target} this week')
db.close()
"
    ;;

  history)
    # Parse args: optional name, optional days
    name=""
    days=14
    if [ -n "$1" ]; then
      # Check if first arg is a number (days only)
      if [[ "$1" =~ ^[0-9]+$ ]]; then
        days="$1"
      else
        name="$1"
        if [ -n "$2" ] && [[ "$2" =~ ^[0-9]+$ ]]; then
          days="$2"
        fi
      fi
    fi

    habit_clause=""
    if [ -n "$name" ]; then
      hid=$(resolve_habit "$name")
      if [ -z "$hid" ]; then echo "No habit found matching: $name"; exit 1; fi
      habit_clause="AND hl.habit_id = $hid"
    fi

    sqlite3 -header -column "$DB" "
      SELECT hl.date, h.name as habit, hl.done, hl.note
      FROM habit_log hl
      JOIN habits h ON h.id = hl.habit_id
      WHERE hl.date >= date('now', 'localtime', '-${days} days')
        $habit_clause
      ORDER BY hl.date DESC, h.name;"
    ;;

  generate)
    python3 -c "
import sqlite3, os
from datetime import date, timedelta, datetime

db = sqlite3.connect(os.path.expanduser('~/.claude/activity.db'))
today = date.today()
monday = today - timedelta(days=today.weekday())
sunday = monday + timedelta(days=6)
now_str = datetime.now().strftime('%Y-%m-%d %H:%M:%S')

lines = []
lines.append('# Habit Tracker')
lines.append('')
lines.append(f'**Last updated**: {today.isoformat()}')
lines.append('')
lines.append('## Active Habits')
lines.append('')
lines.append('| Habit | Rule | Frequency | Target | Streak | Started |')
lines.append('|-------|------|-----------|--------|--------|---------|')

habits = db.execute('SELECT id, name, rule, frequency, target_per_week, started FROM habits WHERE status=\"active\" ORDER BY started, name').fetchall()
for hid, name, rule, freq, target, started in habits:
    if freq == 'daily':
        streak = 0
        d = today
        while True:
            row = db.execute('SELECT done FROM habit_log WHERE habit_id=? AND date=?', (hid, d.isoformat())).fetchone()
            if row and row[0] == 'y':
                streak += 1
                d -= timedelta(days=1)
            else:
                break
        streak_str = f'{streak}-day streak'
    else:
        count = db.execute('SELECT COUNT(*) FROM habit_log WHERE habit_id=? AND date BETWEEN ? AND ? AND done=\"y\"',
                           (hid, monday.isoformat(), sunday.isoformat())).fetchone()[0]
        streak_str = f'{count}/{target} this week'
    target_str = f'{target}/week' if freq == 'weekly' else f'{target}/week'
    lines.append(f'| {name} | {rule or \"\"} | {freq} | {target_str} | {streak_str} | {started} |')

lines.append('')
lines.append('## This Week')
lines.append('')

# Weekly summary
lines.append(f'Week of {monday.strftime(\"%B %-d\")}–{sunday.strftime(\"%-d, %Y\")}:')
lines.append('')
for hid, name, rule, freq, target, started in habits:
    denom = 7 if freq == 'daily' else target
    done_count = db.execute('SELECT COUNT(*) FROM habit_log WHERE habit_id=? AND date BETWEEN ? AND ? AND done=\"y\"',
                            (hid, monday.isoformat(), sunday.isoformat())).fetchone()[0]
    if freq == 'daily':
        streak = 0
        d = today
        while True:
            row = db.execute('SELECT done FROM habit_log WHERE habit_id=? AND date=?', (hid, d.isoformat())).fetchone()
            if row and row[0] == 'y':
                streak += 1
                d -= timedelta(days=1)
            else:
                break
        ratio = done_count / max(1, min(denom, (min(today, sunday) - monday).days + 1))
        if done_count == denom:
            indicator = f'{streak}-day streak'
        elif ratio < 0.7:
            missed = []
            for i in range(7):
                dd = monday + timedelta(days=i)
                if dd > today: break
                row = db.execute('SELECT done FROM habit_log WHERE habit_id=? AND date=?', (hid, dd.isoformat())).fetchone()
                if row and row[0] == 'n':
                    missed.append(dd.strftime('%a'))
            indicator = 'missed ' + ', '.join(missed) if missed else 'needs attention'
        else:
            indicator = ''
    else:
        if done_count >= target:
            indicator = 'done'
        else:
            indicator = f'(target: {target}/week)'
    lines.append(f'  {name + \":\":<30s} {done_count}/{denom}  {indicator}')

lines.append('')
lines.append('## Recent Log (14 days)')
lines.append('')
lines.append('| Date | Habit | Done | Note |')
lines.append('|------|-------|------|------|')

logs = db.execute('''
    SELECT hl.date, h.name, hl.done, hl.note
    FROM habit_log hl
    JOIN habits h ON h.id = hl.habit_id
    WHERE hl.date >= date('now', 'localtime', '-14 days')
    ORDER BY hl.date DESC, h.name
''').fetchall()
for log_date, hname, done, note in logs:
    lines.append(f'| {log_date} | {hname} | {done} | {note or \"\"} |')

lines.append('')
lines.append('## How This Works')
lines.append('')
lines.append('- First 7 days of a new habit: check in every session')
lines.append('- After 7 consecutive days: reduce to periodic check-ins')
lines.append('- If a streak breaks: reset to daily check-ins for 7 days')
lines.append('- Weekly summary every Monday')
lines.append('')
lines.append('---')
lines.append(f'*Auto-generated on {now_str} by habits.sh*')

habits_file = os.path.expanduser('$HABITS_FILE')
output = '\n'.join(lines) + '\n'
with open(habits_file, 'w') as f:
    f.write(output)
print(f'Generated: {habits_file}')
db.close()
"
    ;;

  help|*)
    echo "Steward Habits CLI — habit tracking and check-ins"
    echo ""
    echo "Manage:"
    echo "  add \"name\" --rule \"desc\" [--freq daily|weekly] [--target N]"
    echo "  pause \"name\"                          — pause a habit"
    echo "  retire \"name\"                         — retire a habit"
    echo "  resume \"name\"                         — resume a paused habit"
    echo "  list                                   — list active habits"
    echo ""
    echo "Daily logging:"
    echo "  check \"name\" y|n [\"note\"]              — log today's check-in"
    echo "  today                                  — today's status for all habits"
    echo "  miss \"name\" [\"note\"]                   — shortcut for check name n"
    echo ""
    echo "Views:"
    echo "  week [YYYY-MM-DD]                      — weekly summary"
    echo "  streak \"name\"                          — current streak"
    echo "  streaks                                — all active streaks"
    echo "  history [\"name\"] [days]                — log history (default 14 days)"
    echo ""
    echo "Generate:"
    echo "  generate                               — write work/habits.md"
    echo ""
    echo "Frequencies: daily, weekly"
    echo "Statuses: active, paused, retired"
    ;;

esac
