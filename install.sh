#!/bin/bash
# litespeed-optimizer installer — symlinks the entrypoint into PATH
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${1:-/usr/local/bin}"

if [ ! -d "$TARGET" ]; then
    echo "Target directory not found: $TARGET" >&2
    exit 1
fi

LINK="$TARGET/litespeed-optimizer"
if [ -w "$TARGET" ]; then
    ln -sf "$SCRIPT_DIR/litespeed-optimizer.sh" "$LINK"
else
    sudo ln -sf "$SCRIPT_DIR/litespeed-optimizer.sh" "$LINK"
fi

chmod +x "$SCRIPT_DIR/litespeed-optimizer.sh"
echo "Installed: $LINK -> $SCRIPT_DIR/litespeed-optimizer.sh"
echo "Run: litespeed-optimizer detect"
