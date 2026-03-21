#!/bin/bash
set -e

echo "1. Forging Flint's starter engine..."
zig build -Doptimize=ReleaseFast -Dcpu=native

echo "2. Building the native installer (Dogfooding)..."
./zig-out/bin/flint build flint_dogfooding/install.fl

echo "3. Running native installer"
./install