#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
swift build -c release --arch arm64 --arch x86_64
mkdir -p dist
cp .build/release/totvs-webagent-proxy dist/totvs-webagent-proxy
file dist/totvs-webagent-proxy
