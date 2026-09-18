#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export MACOSX_DEPLOYMENT_TARGET=13.0
if [ -d /Applications/Xcode.app/Contents/Developer ] && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -license check >/dev/null 2>&1; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
else
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi
swift build -c release --arch arm64 --arch x86_64
BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
mkdir -p dist
cp "$BIN_DIR/totvs-webagent-proxy" dist/totvs-webagent-proxy
file dist/totvs-webagent-proxy
