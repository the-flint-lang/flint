#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)

DEST_DIR="/usr/local/bin"
DEST_BIN="$DEST_DIR/flint"
BIN_SRC="$SCRIPT_DIR/zig-out/bin/flint"

LIB_DEST_DIR="/usr/local/lib/flint"
STD_SRC_DIR="$SCRIPT_DIR/std"

if ! command -v zig &> /dev/null; then
  echo "Zig is not installed or could not be found."
  echo "Zig 0.15.2 is recommended."
  exit 1
fi

echo "Compiling Flint (AOT Compiler)..."
cd "$SCRIPT_DIR"
zig build -Doptimize=ReleaseFast -Dcpu=native

echo "Binary compiled: $BIN_SRC"

echo "Installing binary to $DEST_BIN..."
sudo install -m 0755 "$BIN_SRC" "$DEST_BIN"

echo "Installing Standard Library to $LIB_DEST_DIR..."
sudo mkdir -p "$LIB_DEST_DIR"

if [ -d "$STD_SRC_DIR" ]; then
  sudo cp -r "$STD_SRC_DIR" "$LIB_DEST_DIR/"
  
  sudo chown -R root:root "$LIB_DEST_DIR"
  sudo chmod -R 755 "$LIB_DEST_DIR"
else
  echo "AVISO: Pasta '$STD_SRC_DIR' não encontrada no repositório."
  echo "O Flint foi instalado, mas a Standard Library estará ausente."
fi

if ! "$DEST_BIN" --version &> /dev/null; then
  echo "FATAL: An error occurred while executing '$DEST_BIN --version'"
  exit 1
fi

echo "Installation completed successfully!"