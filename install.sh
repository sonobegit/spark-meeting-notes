#!/bin/bash
#
# install.sh — deploy the Spark transcripts launchd job for the current user.
#
# Usage:
#   ./install.sh [/path/to/element-research]
#
# - Copies the script to ~/.local/bin
# - Generates ~/Library/LaunchAgents/nl.sonobe.spark-transcripts.plist with
#   absolute paths for THIS user (launchd does not expand ~ or $HOME)
# - (Re)loads the launchd agent
#
# Idempotent: safe to re-run. Pass a repo path (or set SPARK_TRANSCRIPTS_REPO)
# only if your element-research clone is NOT at the default location below.

set -euo pipefail

readonly LABEL="nl.sonobe.spark-transcripts"
readonly SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly BIN_DIR="$HOME/.local/bin"
readonly SCRIPT_DST="$BIN_DIR/transfer-spark-transcripts.sh"
readonly PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
readonly LOG="$HOME/Library/Logs/spark-transcripts.log"
readonly DEFAULT_REPO="$HOME/Development/sonobe-element-root/element-research"
readonly REPO="${1:-${SPARK_TRANSCRIPTS_REPO:-$DEFAULT_REPO}}"

echo "Installing $LABEL for $(id -un)"
echo "  script : $SCRIPT_DST"
echo "  plist  : $PLIST"
echo "  log    : $LOG"
echo "  repo   : $REPO"

[ -d "$REPO/.git" ] || echo "WARNING: $REPO is not a git clone yet — clone element-research there before the first run."

mkdir -p "$BIN_DIR" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
install -m 0755 "$SRC_DIR/transfer-spark-transcripts.sh" "$SCRIPT_DST"

# Only pin the repo via an env override when it isn't the default location.
env_block=""
if [ "$REPO" != "$DEFAULT_REPO" ]; then
  env_block="
    <key>EnvironmentVariables</key>
    <dict>
        <key>SPARK_TRANSCRIPTS_REPO</key>
        <string>$REPO</string>
    </dict>"
fi

cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>

    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$SCRIPT_DST</string>
    </array>$env_block

    <!-- Daily at 22:00 system-local time -->
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>22</integer>
        <key>Minute</key>
        <integer>0</integer>
    </dict>

    <!-- Don't run when the agent is (re)loaded, only on schedule -->
    <key>RunAtLoad</key>
    <false/>

    <key>StandardOutPath</key>
    <string>$LOG</string>
    <key>StandardErrorPath</key>
    <string>$LOG</string>
</dict>
</plist>
PLISTEOF

launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"

echo
echo "Done. Agent loaded. Verify with a manual run:"
echo "  bash \"$SCRIPT_DST\" && tail -n 20 \"$LOG\""
