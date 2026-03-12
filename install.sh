#!/bin/bash
# Steward Installer
# Sets up the Steward personal life OS on your machine.

set -e

echo "=== Steward Installer ==="
echo ""

# --- Determine bin directory ---
if [ -d "/opt/homebrew/bin" ]; then
  BIN_DIR="/opt/homebrew/bin"
elif [ -d "/usr/local/bin" ]; then
  BIN_DIR="/usr/local/bin"
else
  echo "ERROR: Neither /opt/homebrew/bin nor /usr/local/bin found."
  echo "Please create one of these directories or modify this script."
  exit 1
fi

STEWARD_DIR="$HOME/.claude"
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)/scripts"

# --- Create directories ---
echo "Creating $STEWARD_DIR..."
mkdir -p "$STEWARD_DIR"

# --- Prompt for phone number ---
echo ""
read -p "Enter your Signal phone number (e.g., +15551234567): " PHONE_NUMBER
if [ -z "$PHONE_NUMBER" ]; then
  echo "No phone number provided. Signal integration will need manual configuration."
  PHONE_NUMBER="YOUR_PHONE_NUMBER"
fi

# --- Copy scripts ---
echo ""
echo "Copying scripts to $STEWARD_DIR..."
for script in work.sh people.sh habits.sh signal-listener.sh signal-send.sh signal-ctl.sh daily-check.sh midday-check.sh evening-check.sh; do
  if [ -f "$SCRIPTS_DIR/$script" ]; then
    cp "$SCRIPTS_DIR/$script" "$STEWARD_DIR/$script"
    chmod +x "$STEWARD_DIR/$script"
    echo "  Installed: $script"
  else
    echo "  WARNING: $script not found in $SCRIPTS_DIR"
  fi
done

# --- Write phone number into scripts ---
if [ "$PHONE_NUMBER" != "YOUR_PHONE_NUMBER" ]; then
  echo ""
  echo "Configuring phone number..."
  # Add STEWARD_PHONE to shell profile
  SHELL_RC="$HOME/.zshrc"
  if [ ! -f "$SHELL_RC" ]; then
    SHELL_RC="$HOME/.bashrc"
  fi
  if ! grep -q "STEWARD_PHONE" "$SHELL_RC" 2>/dev/null; then
    echo "" >> "$SHELL_RC"
    echo "# Steward phone number for Signal integration" >> "$SHELL_RC"
    echo "export STEWARD_PHONE=\"$PHONE_NUMBER\"" >> "$SHELL_RC"
    echo "  Added STEWARD_PHONE to $SHELL_RC"
  else
    echo "  STEWARD_PHONE already in $SHELL_RC"
  fi
  export STEWARD_PHONE="$PHONE_NUMBER"
fi

# --- Create symlinks ---
echo ""
echo "Creating symlinks in $BIN_DIR..."
for cmd in work people habits signal-ctl; do
  script="${cmd}.sh"
  if [ "$cmd" = "signal-ctl" ]; then
    script="signal-ctl.sh"
  fi
  target="$STEWARD_DIR/$script"
  link="$BIN_DIR/$cmd"
  if [ -L "$link" ] || [ -f "$link" ]; then
    echo "  $cmd already exists at $link — skipping (remove manually to update)"
  else
    ln -s "$target" "$link"
    echo "  Linked: $cmd -> $target"
  fi
done

# --- Initialize SQLite database ---
DB="$STEWARD_DIR/activity.db"
echo ""
echo "Initializing SQLite database at $DB..."

sqlite3 "$DB" << 'EOSQL'
-- Activity log
CREATE TABLE IF NOT EXISTS activity_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  timestamp TEXT DEFAULT (datetime('now','localtime')),
  project TEXT,
  category TEXT,
  activity TEXT,
  duration_min INTEGER DEFAULT 0,
  notes TEXT
);

-- Projects
CREATE TABLE IF NOT EXISTS projects (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  institution TEXT,
  description TEXT,
  status TEXT DEFAULT 'active',
  target_date TEXT,
  created TEXT DEFAULT (datetime('now','localtime')),
  updated TEXT DEFAULT (datetime('now','localtime'))
);

-- Actions (tasks within projects)
CREATE TABLE IF NOT EXISTS actions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  project_id INTEGER REFERENCES projects(id),
  description TEXT NOT NULL,
  status TEXT DEFAULT 'open',
  owner TEXT,
  due_date TEXT,
  waiting_on TEXT,
  notes TEXT,
  created TEXT DEFAULT (datetime('now','localtime')),
  updated TEXT DEFAULT (datetime('now','localtime')),
  completed TEXT
);

-- Action status history
CREATE TABLE IF NOT EXISTS action_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  action_id INTEGER REFERENCES actions(id),
  old_status TEXT,
  new_status TEXT,
  note TEXT,
  timestamp TEXT DEFAULT (datetime('now','localtime'))
);

-- People
CREATE TABLE IF NOT EXISTS people (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  context TEXT,
  relationship TEXT,
  contact_method TEXT,
  contact_frequency_days INTEGER DEFAULT 30,
  birthday TEXT,
  notes TEXT,
  archived INTEGER DEFAULT 0,
  added_at TEXT DEFAULT (datetime('now','localtime'))
);

-- Interactions
CREATE TABLE IF NOT EXISTS interactions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  person_id INTEGER REFERENCES people(id),
  type TEXT,
  direction TEXT DEFAULT 'outgoing',
  summary TEXT,
  follow_up TEXT,
  timestamp TEXT DEFAULT (datetime('now','localtime'))
);

-- Habits
CREATE TABLE IF NOT EXISTS habits (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  rule TEXT,
  frequency TEXT DEFAULT 'daily',
  target_per_week INTEGER DEFAULT 7,
  status TEXT DEFAULT 'active',
  started TEXT DEFAULT (date('now','localtime'))
);

-- Habit log
CREATE TABLE IF NOT EXISTS habit_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  habit_id INTEGER REFERENCES habits(id),
  date TEXT NOT NULL,
  done TEXT NOT NULL,
  note TEXT,
  logged_at TEXT DEFAULT (datetime('now','localtime')),
  UNIQUE(habit_id, date)
);

-- Signal queue
CREATE TABLE IF NOT EXISTS signal_queue (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  sender TEXT,
  message TEXT,
  received_at TEXT DEFAULT (datetime('now','localtime')),
  processed INTEGER DEFAULT 0,
  processed_at TEXT,
  response TEXT
);

-- Reading log
CREATE TABLE IF NOT EXISTS reading_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  title TEXT NOT NULL,
  url TEXT,
  type TEXT DEFAULT 'article',
  tags TEXT,
  reflection TEXT,
  read_date TEXT DEFAULT (date('now','localtime')),
  added_at TEXT DEFAULT (datetime('now','localtime'))
);

-- View: people who need attention
CREATE VIEW IF NOT EXISTS v_reach_out AS
SELECT
  p.name,
  p.context,
  p.relationship,
  p.contact_method,
  CAST(julianday('now','localtime') - julianday(COALESCE(MAX(i.timestamp), p.added_at)) AS INTEGER) as days_since,
  p.contact_frequency_days - CAST(julianday('now','localtime') - julianday(COALESCE(MAX(i.timestamp), p.added_at)) AS INTEGER) as days_until_due,
  p.notes
FROM people p
LEFT JOIN interactions i ON i.person_id = p.id
WHERE p.archived = 0
GROUP BY p.id
HAVING days_until_due <= 7
ORDER BY days_until_due ASC;

-- View: upcoming birthdays
CREATE VIEW IF NOT EXISTS v_upcoming_dates AS
SELECT
  name,
  birthday,
  CASE
    WHEN strftime('%m-%d', 'now', 'localtime') <= substr(birthday, -5)
    THEN CAST(julianday(strftime('%Y', 'now', 'localtime') || '-' || substr(birthday, -5)) - julianday('now', 'localtime') AS INTEGER)
    ELSE CAST(julianday(strftime('%Y', 'now', 'localtime', '+1 year') || '-' || substr(birthday, -5)) - julianday('now', 'localtime') AS INTEGER)
  END as days_until
FROM people
WHERE birthday IS NOT NULL AND archived = 0
HAVING days_until <= 14
ORDER BY days_until ASC;
EOSQL

echo "  Database initialized with all tables and views."

# --- Create template LaunchAgent plists ---
PLIST_DIR="$HOME/Library/LaunchAgents"
mkdir -p "$PLIST_DIR"

echo ""
echo "Creating template LaunchAgent plists in $PLIST_DIR..."

# Morning check-in (8:00 AM)
cat > "$PLIST_DIR/com.steward.daily-check.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.steward.daily-check</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${STEWARD_DIR}/daily-check.sh</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key>
    <integer>8</integer>
    <key>Minute</key>
    <integer>0</integer>
  </dict>
  <key>StandardOutPath</key>
  <string>${STEWARD_DIR}/cron.log</string>
  <key>StandardErrorPath</key>
  <string>${STEWARD_DIR}/cron.log</string>
</dict>
</plist>
EOF

# Midday check-in (1:00 PM)
cat > "$PLIST_DIR/com.steward.midday-check.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.steward.midday-check</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${STEWARD_DIR}/midday-check.sh</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key>
    <integer>13</integer>
    <key>Minute</key>
    <integer>0</integer>
  </dict>
  <key>StandardOutPath</key>
  <string>${STEWARD_DIR}/cron.log</string>
  <key>StandardErrorPath</key>
  <string>${STEWARD_DIR}/cron.log</string>
</dict>
</plist>
EOF

# Evening check-in (7:30 PM)
cat > "$PLIST_DIR/com.steward.evening-check.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.steward.evening-check</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${STEWARD_DIR}/evening-check.sh</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key>
    <integer>19</integer>
    <key>Minute</key>
    <integer>30</integer>
  </dict>
  <key>StandardOutPath</key>
  <string>${STEWARD_DIR}/cron.log</string>
  <key>StandardErrorPath</key>
  <string>${STEWARD_DIR}/cron.log</string>
</dict>
</plist>
EOF

# Signal listener
cat > "$PLIST_DIR/com.steward.signal-listener.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.steward.signal-listener</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${STEWARD_DIR}/signal-listener.sh</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${STEWARD_DIR}/signal-listener.log</string>
  <key>StandardErrorPath</key>
  <string>${STEWARD_DIR}/signal-listener.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>STEWARD_PHONE</key>
    <string>${PHONE_NUMBER}</string>
  </dict>
</dict>
</plist>
EOF

echo "  Created: com.steward.daily-check.plist (8:00 AM)"
echo "  Created: com.steward.midday-check.plist (1:00 PM)"
echo "  Created: com.steward.evening-check.plist (7:30 PM)"
echo "  Created: com.steward.signal-listener.plist (always-on)"

# --- Done ---
echo ""
echo "=== Installation Complete ==="
echo ""
echo "Next steps:"
echo ""
echo "1. Reload your shell:  source ~/.zshrc  (or ~/.bashrc)"
echo ""
echo "2. Test CLIs:"
echo "   work help"
echo "   people help"
echo "   habits help"
echo ""
echo "3. Set up Signal (if using Signal integration):"
echo "   a. Install signal-cli: brew install signal-cli"
echo "   b. Register/link your phone number with signal-cli"
echo "   c. Start: signal-ctl start"
echo ""
echo "4. Enable LaunchAgents (for automated check-ins):"
echo "   launchctl load ~/Library/LaunchAgents/com.steward.daily-check.plist"
echo "   launchctl load ~/Library/LaunchAgents/com.steward.midday-check.plist"
echo "   launchctl load ~/Library/LaunchAgents/com.steward.evening-check.plist"
echo "   launchctl load ~/Library/LaunchAgents/com.steward.signal-listener.plist"
echo ""
echo "5. Create a steward-persona.md in ~/.claude/ for AI check-in personality."
echo "   This file is read by the morning/midday/evening check-in scripts."
echo ""
echo "6. Create a work/ directory in your projects folder for status.md and habits.md:"
echo "   mkdir -p ~/projects/work"
echo ""
echo "Data is stored in: $DB"
echo "Scripts are in:    $STEWARD_DIR"
echo "Logs will be at:   $STEWARD_DIR/cron.log"
