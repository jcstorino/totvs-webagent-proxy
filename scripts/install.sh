#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/dist/totvs-webagent-proxy"
PLIST="$ROOT/launchd/com.totvs.webagent-proxy.plist"
TARGET_PLIST="$HOME/Library/LaunchAgents/com.totvs.webagent-proxy.plist"
[ -x "$BIN" ] || { echo "Execute ./scripts/build.sh primeiro."; exit 1; }
[ -f "$PLIST" ] || { echo "LaunchAgent não encontrado."; exit 1; }
sudo install -m 755 "$BIN" /usr/local/bin/totvs-webagent-proxy
mkdir -p "$HOME/Library/LaunchAgents"
install -m 644 "$PLIST" "$TARGET_PLIST"
launchctl bootout "gui/$(id -u)/com.totvs.webagent-proxy" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$TARGET_PLIST"
launchctl kickstart -k "gui/$(id -u)/com.totvs.webagent-proxy"
echo "Instalado e iniciado. Log: $HOME/Library/Logs/totvs-webagent-proxy.log"
