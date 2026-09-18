#!/bin/bash
set -euo pipefail
TARGET_PLIST="$HOME/Library/LaunchAgents/com.totvs.webagent-proxy.plist"
launchctl bootout "gui/$(id -u)/com.totvs.webagent-proxy" 2>/dev/null || true
rm -f "$TARGET_PLIST"
sudo rm -f /usr/local/bin/totvs-webagent-proxy
echo "Proxy removido. O log foi preservado em $HOME/Library/Logs/totvs-webagent-proxy.log"
