#!/bin/bash
# Signal Controller — manages signal-cli daemon + listener
# Usage: signal-ctl <start|stop|status|logs|daemon-logs|restart|health|queue|process|help>

export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"

LISTENER="$HOME/.claude/signal-listener.sh"
LISTENER_PID_FILE="$HOME/.claude/signal-listener.pid"
LISTENER_LOG="$HOME/.claude/signal-listener.log"

DAEMON_LOG="$HOME/.claude/signal-cli-daemon.log"

SIGNAL_CLI="/opt/homebrew/bin/signal-cli"
# Set STEWARD_PHONE in your environment or via install.sh
PHONE="${STEWARD_PHONE:-YOUR_PHONE_NUMBER}"

DAEMON_URL="http://localhost:8080"
HEALTH_URL="${DAEMON_URL}/api/v1/check"

DB="$HOME/.claude/activity.db"

cmd="${1:-status}"

# --- Process checks ---
is_listener_running() {
  if [ -f "$LISTENER_PID_FILE" ]; then
    local pid
    pid=$(cat "$LISTENER_PID_FILE")
    if kill -0 "$pid" 2>/dev/null; then
      return 0
    else
      rm -f "$LISTENER_PID_FILE"
      return 1
    fi
  fi
  return 1
}

is_daemon_running() {
  # Check if signal-cli daemon is running by looking for the process
  pgrep -f "signal-cli.*daemon.*--http" >/dev/null 2>&1
}

is_daemon_healthy() {
  curl -s --max-time 3 "$HEALTH_URL" >/dev/null 2>&1
}

# --- Start daemon ---
start_daemon() {
  if is_daemon_running; then
    echo "signal-cli daemon already running"
    return 0
  fi
  echo "Starting signal-cli daemon..."
  nohup "$SIGNAL_CLI" -a "$PHONE" daemon --http=localhost:8080 --receive-mode=on-start --send-read-receipts >> "$DAEMON_LOG" 2>&1 &
  disown

  # Wait for health check
  echo -n "Waiting for daemon to be ready"
  local waited=0
  while [ "$waited" -lt 60 ]; do
    if is_daemon_healthy; then
      echo " OK"
      return 0
    fi
    echo -n "."
    sleep 2
    waited=$((waited + 2))
  done
  echo " TIMEOUT"
  echo "ERROR: Daemon did not become healthy within 60s. Check $DAEMON_LOG"
  return 1
}

# --- Stop daemon ---
stop_daemon() {
  if ! is_daemon_running; then
    echo "signal-cli daemon is not running."
    return 0
  fi
  echo "Stopping signal-cli daemon..."
  pkill -f "signal-cli.*daemon.*--http" 2>/dev/null
  # Wait for clean shutdown
  local waited=0
  while [ "$waited" -lt 15 ]; do
    if ! is_daemon_running; then
      echo "Daemon stopped."
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  echo "Force killing daemon..."
  pkill -9 -f "signal-cli.*daemon.*--http" 2>/dev/null
  sleep 1
  echo "Daemon killed."
}

# --- Start listener ---
start_listener() {
  if is_listener_running; then
    echo "Listener already running (PID: $(cat "$LISTENER_PID_FILE"))"
    return 0
  fi
  echo "Starting signal listener..."
  nohup /bin/bash "$LISTENER" >> "$LISTENER_LOG" 2>&1 &
  disown
  sleep 2
  if is_listener_running; then
    echo "Listener started (PID: $(cat "$LISTENER_PID_FILE"))"
  else
    echo "ERROR: Listener failed to start. Check $LISTENER_LOG"
    return 1
  fi
}

# --- Stop listener ---
stop_listener() {
  if ! is_listener_running; then
    echo "Listener is not running."
    rm -f "$LISTENER_PID_FILE"
    return 0
  fi
  local pid
  pid=$(cat "$LISTENER_PID_FILE")
  echo "Stopping listener (PID: $pid)..."
  kill "$pid" 2>/dev/null
  # Also kill any child curl processes
  pkill -P "$pid" 2>/dev/null
  local waited=0
  while [ "$waited" -lt 10 ]; do
    if ! kill -0 "$pid" 2>/dev/null; then
      echo "Listener stopped."
      rm -f "$LISTENER_PID_FILE"
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  echo "Force killing listener..."
  kill -9 "$pid" 2>/dev/null
  pkill -9 -P "$pid" 2>/dev/null
  rm -f "$LISTENER_PID_FILE"
  echo "Listener killed."
}

case "$cmd" in
  start)
    start_daemon
    if [ $? -ne 0 ]; then
      echo "Aborting — daemon failed to start"
      exit 1
    fi
    start_listener
    ;;

  stop)
    stop_listener
    stop_daemon
    ;;

  restart)
    stop_listener
    stop_daemon
    sleep 2
    start_daemon
    if [ $? -ne 0 ]; then
      echo "Aborting — daemon failed to start"
      exit 1
    fi
    start_listener
    ;;

  status)
    echo "=== Signal System Status ==="
    echo ""

    # Daemon status
    if is_daemon_running; then
      _daemon_pid=$(pgrep -f "signal-cli.*daemon.*--http" | head -1)
      echo "signal-cli daemon: RUNNING (PID: $_daemon_pid)"
    else
      echo "signal-cli daemon: STOPPED"
    fi

    # Health check
    if is_daemon_healthy; then
      echo "HTTP health check:  OK"
    else
      echo "HTTP health check:  FAIL"
    fi

    echo ""

    # Listener status
    if is_listener_running; then
      _listener_pid=$(cat "$LISTENER_PID_FILE")
      echo "Signal listener:    RUNNING (PID: $_listener_pid)"
    else
      echo "Signal listener:    STOPPED"
    fi

    # Last log line
    if [ -f "$LISTENER_LOG" ]; then
      echo ""
      echo "Last listener log: $(tail -1 "$LISTENER_LOG")"
    fi

    # Queue count
    if [ -f "$DB" ]; then
      _queued=$(sqlite3 "$DB" "SELECT COUNT(*) FROM signal_queue WHERE processed=0;" 2>/dev/null)
      echo "Queued messages:   ${_queued:-0}"
    fi
    ;;

  logs)
    if [ ! -f "$LISTENER_LOG" ]; then
      echo "No listener log file found at $LISTENER_LOG"
      exit 1
    fi
    shift
    _lines="${1:-50}"
    tail -n "$_lines" "$LISTENER_LOG"
    ;;

  daemon-logs)
    if [ ! -f "$DAEMON_LOG" ]; then
      echo "No daemon log file found at $DAEMON_LOG"
      exit 1
    fi
    shift
    _lines="${1:-50}"
    tail -n "$_lines" "$DAEMON_LOG"
    ;;

  tail)
    if [ ! -f "$LISTENER_LOG" ]; then
      echo "No listener log file found at $LISTENER_LOG"
      exit 1
    fi
    tail -f "$LISTENER_LOG"
    ;;

  health)
    echo -n "Health check: "
    _result=""
    _result=$(curl -s --max-time 5 "$HEALTH_URL" 2>/dev/null)
    if [ $? -eq 0 ]; then
      echo "OK — $_result"
    else
      echo "FAIL — daemon not responding"
      exit 1
    fi
    ;;

  queue)
    if [ ! -f "$DB" ]; then
      echo "No database found."
      exit 1
    fi
    _count=""
    _count=$(sqlite3 "$DB" "SELECT COUNT(*) FROM signal_queue WHERE processed=0;" 2>/dev/null)
    if [ "$_count" -gt 0 ]; then
      echo "$_count unprocessed message(s):"
      echo ""
      sqlite3 -header -column "$DB" "
        SELECT id, sender, message, received_at
        FROM signal_queue
        WHERE processed=0
        ORDER BY received_at;" 2>/dev/null
    else
      echo "No queued messages."
    fi
    ;;

  process)
    _qid="$2"
    _response="$3"
    if [ -z "$_qid" ]; then
      echo "Usage: signal-ctl process ID [response]"
      exit 1
    fi
    sqlite3 "$DB" "UPDATE signal_queue SET processed=1, processed_at=datetime('now','localtime'), response='$(echo "$_response" | sed "s/'/''/g")' WHERE id=$_qid;"
    echo "Queue item #$_qid marked as processed."
    ;;

  help|*)
    echo "Signal System Controller (HTTP/SSE mode)"
    echo ""
    echo "Usage: signal-ctl <command>"
    echo ""
    echo "Commands:"
    echo "  start       — start daemon + listener"
    echo "  stop        — stop listener + daemon"
    echo "  restart     — stop both, start both"
    echo "  status      — check both processes + health"
    echo "  health      — hit daemon health endpoint"
    echo "  logs [N]    — show last N listener log lines (default 50)"
    echo "  daemon-logs [N] — show last N daemon log lines (default 50)"
    echo "  tail        — follow listener logs live"
    echo "  queue       — show unprocessed queued messages"
    echo "  process ID [response] — mark queue item processed"
    echo "  help        — this message"
    ;;
esac
