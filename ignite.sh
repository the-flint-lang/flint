#!/bin/bash
set -e

LIB_DEST_DIR="/usr/share/flint" 

echo "1. Forging Flint's starter engine (Zig)..."
zig build -Doptimize=ReleaseFast -Dcpu=native 

echo "1.5. Injecting fresh runtime into system cache..."
sudo mkdir -p $LIB_DEST_DIR

sudo cp src/core/codegen/runtime/flint_rt.h $LIB_DEST_DIR/flint_rt.h
sudo cp src/core/codegen/runtime/flint_rt.c $LIB_DEST_DIR/flint_rt.c

sudo clang -O3 -flto -ffunction-sections -fdata-sections -march=native -c src/core/codegen/runtime/flint_rt.c -o $LIB_DEST_DIR/flint_rt.o
sudo clang -x c-header src/core/codegen/runtime/flint_rt.h -o $LIB_DEST_DIR/flint_rt.h.pch

echo "2. Building the native installer (Dogfooding)..."
./zig-out/bin/flint build flint_dogfooding/install.fl

echo "3. Running native installer..."
./install