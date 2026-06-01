#!/usr/bin/env bash
# =============================================================================
# run_l3_tb.sh — compile + run l3_session_fsm_tb
# =============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."
BUILD="$ROOT/build/l3_session_fsm_test"

mkdir -p "$BUILD"

echo "================================================================"
echo " l3_session_fsm.v testbench (PROTOCOL.md Layer 3 validation)"
echo "================================================================"

iverilog -g2012 -o "$BUILD/sim.vvp" \
    "$ROOT/rtl/blake3/blake3.v" \
    "$ROOT/rtl/l3_session_fsm.v" \
    "$ROOT/rtl/measure/l3_session_fsm_tb.v"

cd "$ROOT" && vvp "$BUILD/sim.vvp"
