#!/usr/bin/env bash
# =============================================================================
# test_ira_ceremony.sh — full VIRGIN → HEALTHY ceremony in sim
# =============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."
BUILD="$ROOT/build/ira_ceremony_test"

mkdir -p "$BUILD"

echo "================================================================"
echo " ira ceremony integration test (KOHI → BLAKE3 → TAHU)"
echo "================================================================"

iverilog -g2005-sv -o "$BUILD/sim.vvp" \
    "$ROOT/rtl/blake3/blake3.v" \
    "$ROOT/rtl/blake3_tree.v" \
    "$ROOT/rtl/trng.v" \
    "$ROOT/rtl/otp.v" \
    "$ROOT/rtl/inverted_pair_verify.v" \
    "$ROOT/rtl/ira_fsm.v" \
    "$ROOT/rtl/measure/ira_ceremony_tb.v"

cd "$ROOT" && vvp "$BUILD/sim.vvp"
