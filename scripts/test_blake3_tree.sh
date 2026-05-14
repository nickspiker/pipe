#!/usr/bin/env bash
# =============================================================================
# test_blake3_tree.sh — differential test of blake3_tree.v vs. reference BLAKE3
# =============================================================================
# 1. Builds and runs the Rust generator → writes test_input.hex + expected.hex
# 2. Compiles the iverilog testbench against blake3.v + blake3_tree.v
# 3. Runs the sim, which $readmemh's the hex files, drives the DUT, and prints
#    PASS or FAIL based on whether ira matches the Rust BLAKE3 reference.
# =============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."
BUILD="$ROOT/build/blake3_tree_test"

mkdir -p "$BUILD"

echo "================================================================"
echo " blake3_tree.v differential test"
echo "================================================================"

echo ""
echo "--- Generate test vector + reference hash ---"
cargo run -p pipe-host --bin blake3_tree_gen --release -- "$BUILD"

echo ""
echo "--- Compile iverilog sim ---"
iverilog -g2005-sv -o "$BUILD/sim.vvp" \
    "$ROOT/rtl/blake3/blake3.v" \
    "$ROOT/rtl/blake3_tree.v" \
    "$ROOT/rtl/measure/blake3_tree_tb.v"

echo ""
echo "--- Run sim ---"
cd "$ROOT" && vvp "$BUILD/sim.vvp"
