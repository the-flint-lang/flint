#!/usr/bin/env bash

set -e

TEST="test.fl"

echo "=================================="
echo " Flint Benchmark"
echo "=================================="

echo ""
echo "== Baseline (compiler atual) =="

echo ""
echo "-- Build time --"
for i in {1..10}; do
    rm -f test
    time flint build $TEST
done

echo ""
echo "-- Run time --"
for i in {1..10}; do
    time ./test
done

echo ""
echo "Binary size:"
ls -lh test

rm test
