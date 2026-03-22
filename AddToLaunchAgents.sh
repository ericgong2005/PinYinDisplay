#!/bin/bash
set -euo pipefail

BIN_PATH="$(pwd)/PinYinDisplay"
LABEL="com.user.pinyindisplay"
DEST="$HOME/Library/LaunchAgents/$LABEL.plist"

cat > ./LaunchAgentCommand.xml <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>

  <key>Label</key>
  <string>$LABEL</string>

  <key>ProgramArguments</key>
  <array>
    <string>$BIN_PATH</string>
  </array>

  <key>RunAtLoad</key>
  <true/>

  <key>KeepAlive</key>
  <true/>

  <key>StandardOutPath</key>
  <string>/tmp/pinyindisplay.out</string>

  <key>StandardErrorPath</key>
  <string>/tmp/pinyindisplay.err</string>

</dict>
</plist>
EOF

mkdir -p ~/Library/LaunchAgents
cp ./LaunchAgentCommand.xml "$DEST"

launchctl unload "$DEST" 2>/dev/null || true
launchctl load "$DEST"