#!/bin/bash
# Steward Installer — DynamoDB backend
# Sets up the Steward personal life OS on your machine.

set -e

echo "=== Steward Installer ==="
echo ""

# --- Determine directories ---
if [ -d "/opt/homebrew/bin" ]; then
  BIN_DIR="/opt/homebrew/bin"
elif [ -d "/usr/local/bin" ]; then
  BIN_DIR="/usr/local/bin"
else
  echo "ERROR: Neither /opt/homebrew/bin nor /usr/local/bin found."
  exit 1
fi

STEWARD_DIR="$HOME/.claude"
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)/scripts"
PROJECT_DIR="$HOME/projects"
CONFIG_TEMPLATES="$(cd "$(dirname "$0")" && pwd)/config-templates"

# --- Prerequisites check ---
echo "Checking prerequisites..."
for cmd in aws python3 jq curl; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "  ERROR: $cmd not found. Please install it first."
    exit 1
  fi
done
echo "  All prerequisites found."

# --- Check AWS credentials ---
echo ""
echo "Checking AWS credentials..."
AWS_ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)
if [ -z "$AWS_ACCOUNT" ]; then
  echo "  ERROR: AWS credentials not configured. Run 'aws configure' first."
  exit 1
fi
AWS_REGION=$(aws configure get region 2>/dev/null || echo "us-east-1")
echo "  Account: $AWS_ACCOUNT, Region: $AWS_REGION"

# --- Install boto3 ---
echo ""
echo "Ensuring boto3 is installed..."
if ! python3 -c "import boto3" 2>/dev/null; then
  pip3 install --user --break-system-packages boto3 2>/dev/null || pip3 install --user boto3 2>/dev/null
  echo "  boto3 installed."
else
  echo "  boto3 already available."
fi

# --- Create directories ---
echo ""
echo "Creating directories..."
mkdir -p "$STEWARD_DIR"
mkdir -p "$PROJECT_DIR/work"
echo "  $STEWARD_DIR"
echo "  $PROJECT_DIR/work"

# --- Prompt for configuration ---
echo ""
read -p "Enter your Signal phone number (e.g., +15551234567): " PHONE_NUMBER
if [ -z "$PHONE_NUMBER" ]; then
  echo "  No phone number provided. Signal integration will need manual configuration."
  PHONE_NUMBER="YOUR_PHONE_NUMBER"
fi

# --- Create DynamoDB table ---
echo ""
echo "Setting up DynamoDB table..."
TABLE_EXISTS=$(aws dynamodb describe-table --table-name steward 2>/dev/null && echo "yes" || echo "no")
if [ "$TABLE_EXISTS" = "no" ]; then
  echo "  Creating DynamoDB table 'steward'..."
  aws dynamodb create-table \
    --table-name steward \
    --attribute-definitions \
      AttributeName=PK,AttributeType=S \
      AttributeName=SK,AttributeType=S \
      AttributeName=GSI1PK,AttributeType=S \
      AttributeName=GSI1SK,AttributeType=S \
    --key-schema \
      AttributeName=PK,KeyType=HASH \
      AttributeName=SK,KeyType=RANGE \
    --global-secondary-indexes \
      '[{
        "IndexName": "GSI1",
        "KeySchema": [
          {"AttributeName": "GSI1PK", "KeyType": "HASH"},
          {"AttributeName": "GSI1SK", "KeyType": "RANGE"}
        ],
        "Projection": {"ProjectionType": "ALL"}
      }]' \
    --billing-mode PAY_PER_REQUEST \
    --tags Key=project,Value=steward > /dev/null

  echo "  Waiting for table to be active..."
  aws dynamodb wait table-exists --table-name steward
  echo "  Table created."
else
  echo "  Table 'steward' already exists."
fi

# --- Create S3 config bucket ---
S3_BUCKET="steward-config-${AWS_ACCOUNT}"
echo ""
echo "Setting up S3 config bucket..."
if aws s3 ls "s3://$S3_BUCKET" 2>/dev/null; then
  echo "  Bucket $S3_BUCKET already exists."
else
  aws s3 mb "s3://$S3_BUCKET" --region "$AWS_REGION" > /dev/null
  echo "  Created bucket: $S3_BUCKET"
fi

# --- Pull config from S3 or create from templates ---
echo ""
echo "Setting up configuration files..."

pull_or_template() {
  local filename="$1"
  local s3_path="s3://$S3_BUCKET/config/$filename"
  local local_path="$2"

  if aws s3 ls "$s3_path" 2>/dev/null; then
    aws s3 cp "$s3_path" "$local_path" > /dev/null 2>&1
    echo "  Pulled from S3: $filename"
  elif [ -f "$CONFIG_TEMPLATES/${filename}.template" ]; then
    cp "$CONFIG_TEMPLATES/${filename}.template" "$local_path"
    echo "  Created from template: $filename (customize it!)"
  else
    echo "  WARNING: No S3 config or template found for $filename"
  fi
}

pull_or_template "CLAUDE.md" "$PROJECT_DIR/CLAUDE.md"
pull_or_template "UPEKHA.md" "$PROJECT_DIR/UPEKHA.md"
pull_or_template "steward-persona.md" "$STEWARD_DIR/steward-persona.md"

# --- Copy scripts ---
echo ""
echo "Installing scripts..."
SCRIPT_MAP=(
  "work-dynamodb.sh"
  "people-dynamodb.sh"
  "habits-dynamodb.sh"
  "signal-listener-dynamodb.sh"
  "signal-send.sh"
  "signal-ctl.sh"
  "daily-check-dynamodb.sh"
  "midday-check-dynamodb.sh"
  "evening-check-dynamodb.sh"
)

for script in "${SCRIPT_MAP[@]}"; do
  if [ -f "$SCRIPTS_DIR/$script" ]; then
    cp "$SCRIPTS_DIR/$script" "$STEWARD_DIR/$script"
    chmod +x "$STEWARD_DIR/$script"
    echo "  Installed: $script"
  else
    echo "  WARNING: $script not found in $SCRIPTS_DIR"
  fi
done

# Also copy non-DynamoDB scripts that don't need migration
for script in signal-send.sh signal-ctl.sh; do
  if [ -f "$SCRIPTS_DIR/$script" ]; then
    cp "$SCRIPTS_DIR/$script" "$STEWARD_DIR/$script"
    chmod +x "$STEWARD_DIR/$script"
  fi
done

# --- Create symlinks ---
echo ""
echo "Creating symlinks in $BIN_DIR..."
declare -A LINK_MAP=(
  [work]="work-dynamodb.sh"
  [people]="people-dynamodb.sh"
  [habits]="habits-dynamodb.sh"
  [signal-ctl]="signal-ctl.sh"
)

for cmd in "${!LINK_MAP[@]}"; do
  script="${LINK_MAP[$cmd]}"
  target="$STEWARD_DIR/$script"
  link="$BIN_DIR/$cmd"
  if [ -L "$link" ] || [ -f "$link" ]; then
    echo "  $cmd already exists at $link — updating"
    ln -sf "$target" "$link"
  else
    ln -s "$target" "$link"
  fi
  echo "  Linked: $cmd -> $script"
done

# --- Configure phone number ---
if [ "$PHONE_NUMBER" != "YOUR_PHONE_NUMBER" ]; then
  echo ""
  echo "Configuring phone number..."
  SHELL_RC="$HOME/.zshrc"
  [ ! -f "$SHELL_RC" ] && SHELL_RC="$HOME/.bashrc"
  if ! grep -q "STEWARD_PHONE" "$SHELL_RC" 2>/dev/null; then
    echo "" >> "$SHELL_RC"
    echo "# Steward phone number for Signal integration" >> "$SHELL_RC"
    echo "export STEWARD_PHONE=\"$PHONE_NUMBER\"" >> "$SHELL_RC"
    echo "  Added STEWARD_PHONE to $SHELL_RC"
  fi
fi

# --- Create LaunchAgent plists ---
PLIST_DIR="$HOME/Library/LaunchAgents"
mkdir -p "$PLIST_DIR"

echo ""
echo "Creating LaunchAgent plists..."

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
    <string>${STEWARD_DIR}/daily-check-dynamodb.sh</string>
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
    <string>${STEWARD_DIR}/midday-check-dynamodb.sh</string>
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
    <string>${STEWARD_DIR}/evening-check-dynamodb.sh</string>
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
    <string>${STEWARD_DIR}/signal-listener-dynamodb.sh</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${STEWARD_DIR}/signal-listener.log</string>
  <key>StandardErrorPath</key>
  <string>${STEWARD_DIR}/signal-listener.log</string>
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
echo "Architecture:"
echo "  Data:    DynamoDB table 'steward' ($AWS_REGION)"
echo "  Config:  S3 bucket '$S3_BUCKET'"
echo "  Scripts: $STEWARD_DIR"
echo "  CLIs:    work, people, habits, signal-ctl"
echo ""
echo "Next steps:"
echo ""
echo "1. Reload your shell:  source ~/.zshrc"
echo ""
echo "2. Test CLIs:"
echo "   work help"
echo "   people help"
echo "   habits help"
echo ""
echo "3. Customize config files:"
echo "   $PROJECT_DIR/CLAUDE.md"
echo "   $PROJECT_DIR/UPEKHA.md"
echo "   $STEWARD_DIR/steward-persona.md"
echo ""
echo "4. Set up Signal (optional):"
echo "   a. Install signal-cli: brew install signal-cli"
echo "   b. Register/link your phone number"
echo "   c. Start: signal-ctl start"
echo ""
echo "5. Enable LaunchAgents (for automated check-ins):"
echo "   launchctl load ~/Library/LaunchAgents/com.steward.daily-check.plist"
echo "   launchctl load ~/Library/LaunchAgents/com.steward.midday-check.plist"
echo "   launchctl load ~/Library/LaunchAgents/com.steward.evening-check.plist"
echo "   launchctl load ~/Library/LaunchAgents/com.steward.signal-listener.plist"
