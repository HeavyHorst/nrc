#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_PATH="$SCRIPT_DIR/uwebsockets-bench-server"

"$SCRIPT_DIR/build-server.sh"
exec "$BIN_PATH"
