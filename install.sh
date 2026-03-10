#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)

DEST_DIR="/usr/local/bin"
DEST_BIN="$DEST_DIR/flint"
BIN_SRC="$SCRIPT_DIR/zig-out/bin/flint"

if ! command -v zig &> /dev/null; then
  echo "Zig is not installed or could not be found."
  echo "Zig 0.15.2 is recommended."
  exit 1
fi

echo "Compiling flint..."
cd "$SCRIPT_DIR"
# zig build -Doptimize=ReleaseFast
zig build -Doptimize=ReleaseFast -Dcpu=native

echo "Binary compiled: $BIN_SRC"

echo "Installing to $DEST_BIN"
sudo install -m 0755 "$BIN_SRC" "$DEST_BIN"

if ! "$DEST_BIN" --version &> /dev/null; then
  echo "An error occurred while executing '$DEST_BIN --version'"
  exit 1
fi

echo "Installation completed successfully!"