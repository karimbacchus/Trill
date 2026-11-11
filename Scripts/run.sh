#!/bin/bash
# Builds Trill.app and opens it.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$ROOT/Scripts/build-app.sh"
pkill -x Trill 2>/dev/null || true
open "$ROOT/build/Trill.app"
