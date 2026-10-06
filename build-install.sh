#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"

"$ROOT/scripts/build.sh"
"$ROOT/scripts/install.sh"
