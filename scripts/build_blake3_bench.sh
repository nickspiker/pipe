#!/usr/bin/env bash
# =============================================================================
# build_blake3_bench.sh — Phase C/D: BLAKE3 silicon Fmax via dual-CE 256:1
# =============================================================================
#
# Runs blake3 under spirix-style PH_GOLD (CE=1/256) → PH_SWITCH → PH_TEST (CE=1)
# → PH_DONE harness. Compares accumulated 32-bit XOR-folds. Live PASS/FAIL on
# the keypad LED (T2). Geiger LED on T6 (lfsr advance signal). When run with
# RING=N, sys_clk = N-stage single-NOT ring oscillator (DCCA-buffered for
# distribution); without RING, PLL-driven at the requested MHz.
#
# Self-contained — no dependency on /mnt/Octopus/Code/spirix.
#
# Usage:
#   ./build_blake3_bench.sh 100 --program          # PLL @ 100 MHz
#   RING=12 ./build_blake3_bench.sh --program       # 12-stage ring (~123 MHz)
#   RING=5  ./build_blake3_bench.sh --program       # 5-stage ring (~290 MHz)
#   ./build_blake3_bench.sh                         # default: 25 MHz raw
#
# OLED layout:
#   Top band (rows 0..15)  : ring frequency (NNN.NNN MHz, RING mode only)
#   Band 1   (rows 16..31) : gold_reg (slow-CE accumulated hash, 32 cells)
#   Band 2   (rows 32..47) : test_reg (full-speed accumulated hash, 32 cells)
#   Band 3   (rows 48..63) : gold_reg ^ test_reg (lit cells = bits that differ)
#
# =============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."
RTL="$ROOT/rtl/measure"
BLAKE3_RTL="$ROOT/rtl/blake3"
DATA="$ROOT/data"
LPF="$ROOT/constraints/blake3_bench.lpf"
BUILD="$ROOT/build_blake3_bench"
SEED="${SEED:-4}"

FREQ="${1:-25}"
PROGRAM=""
for arg in "$@"; do
    case "$arg" in
        --program) PROGRAM=1 ;;
    esac
done

mkdir -p "$BUILD"
cp -f "$DATA/decimal_glyphs.mem" "$BUILD/decimal_glyphs.mem"

# -----------------------------------------------------------------------------
# Clock source: PLL (default) or internal ring oscillator (RING=N).
# -----------------------------------------------------------------------------
DEFINES="-DDUT_BLAKE3 -DNO_NTSC"

if [ -n "${RING:-}" ]; then
    if [ "$RING" -lt 1 ]; then
        echo "ERROR: RING=$RING must be ≥ 1" >&2
        exit 1
    fi
    DEFINES="$DEFINES -DRING_STAGES=$RING"
    PNR_EXTRA="--ignore-loops --timing-allow-fail"
    echo "================================================================"
    echo " blake3 bench on internal ring oscillator: 1 NOT + $((RING-1)) BUFs"
    echo " sys_clk = ring output via DCCA. Frequency on OLED top row."
    echo "================================================================"
elif [ "$FREQ" != "25" ]; then
    PLL_OUT=$(ecppll -i 25 -o "$FREQ" -f /dev/null 2>&1)
    CLKI=$(echo "$PLL_OUT"  | awk '/Refclk divisor:/  {print $3}')
    CLKFB=$(echo "$PLL_OUT" | awk '/Feedback divisor:/ {print $3}')
    CLKOP=$(echo "$PLL_OUT" | awk '/clkout0 divisor:/  {print $3}')
    ACTUAL_FREQ=$(echo "$PLL_OUT" | awk '/clkout0 frequency:/ {print $3}')
    if [ -z "$CLKI" ] || [ -z "$CLKFB" ] || [ -z "$CLKOP" ]; then
        echo "ERROR: ecppll failed for ${FREQ} MHz" >&2
        echo "$PLL_OUT" >&2
        exit 1
    fi
    CPHASE=$(( (CLKOP - 1) / 2 ))
    DEFINES="$DEFINES -DPLL_CLKI_DIV=$CLKI -DPLL_CLKFB_DIV=$CLKFB"
    DEFINES="$DEFINES -DPLL_CLKOP_DIV=$CLKOP -DPLL_CLKOP_CPHASE=$CPHASE"
    PNR_EXTRA="--timing-allow-fail"
    echo "================================================================"
    echo " blake3 bench @ ${ACTUAL_FREQ} MHz (PLL CLKI=$CLKI CLKFB=$CLKFB CLKOP=$CLKOP)"
    echo "================================================================"
else
    PNR_EXTRA="--timing-allow-fail"
    echo "================================================================"
    echo " blake3 bench @ 25 MHz (no PLL — baseline / debug only)"
    echo "================================================================"
fi

# -----------------------------------------------------------------------------
# Synthesize. Self-contained: only blake3 + i2c + bench top.
# -----------------------------------------------------------------------------
echo ""
echo "--- Synthesise ---"
cd "$BUILD"
yosys -p "
    read_verilog $BLAKE3_RTL/blake3.v
    read_verilog $RTL/ssd1306_i2c.v
    read_verilog $DEFINES $RTL/top_blake3_bench.v
    synth_ecp5 -nowidelut -abc2 -top top_ntsc -json $BUILD/blake3_bench.json
    stat
" > "$BUILD/blake3_bench_yosys.log" 2>&1
cd - > /dev/null

if grep -q 'ERROR' "$BUILD/blake3_bench_yosys.log"; then
    echo "YOSYS ERROR — see $BUILD/blake3_bench_yosys.log"
    tail -30 "$BUILD/blake3_bench_yosys.log"
    exit 1
fi
grep -E '^\s+[0-9]+ +(LUT4|TRELLIS_FF|CCU2C|EHXPLLL|DP16KD)' "$BUILD/blake3_bench_yosys.log" | tail -10

# -----------------------------------------------------------------------------
# Place + route. --ignore-loops needed when ring osc is in the design.
# -----------------------------------------------------------------------------
echo ""
echo "--- Place & Route ---"
# 5-minute timeout — most seeds finish in 30-60s; pathological seeds (e.g. 42)
# can loop in placement-convergence indefinitely. Better to abort and retry a
# different seed than to hang overnight.
PNR_TIMEOUT="${PNR_TIMEOUT:-300}"
timeout "$PNR_TIMEOUT" nextpnr-ecp5 --25k --package CABGA256 --speed 6 --seed "$SEED" \
    $PNR_EXTRA \
    --json "$BUILD/blake3_bench.json" \
    --lpf "$LPF" \
    --textcfg "$BUILD/blake3_bench.config" \
    > "$BUILD/blake3_bench_pnr.log" 2>&1
PNR_RC=$?
if [ "$PNR_RC" -eq 124 ]; then
    echo "PNR TIMEOUT after ${PNR_TIMEOUT}s — seed $SEED hit a placement pathology, try another"
    exit 1
fi

grep -E "(Max frequency|Total LUT4|Info: Device utilisation)" "$BUILD/blake3_bench_pnr.log" | head -8
# With --timing-allow-fail nextpnr emits "ERROR: Max frequency ..." lines for
# clocks that miss target but still exits 0. Only bail on a non-zero nextpnr
# exit (genuine PnR / routing failure).
if [ "$PNR_RC" -ne 0 ]; then
    echo "PNR exited with rc=$PNR_RC — see $BUILD/blake3_bench_pnr.log"
    exit 1
fi

# -----------------------------------------------------------------------------
# Pack + program
# -----------------------------------------------------------------------------
echo ""
echo "--- Pack ---"
ecppack --svf "$BUILD/blake3_bench.svf" "$BUILD/blake3_bench.config" "$BUILD/blake3_bench.bit"
echo "Bitstream: $BUILD/blake3_bench.bit ($(stat -c%s "$BUILD/blake3_bench.bit") bytes)"

if [ "$PROGRAM" = "1" ]; then
    echo ""
    echo "--- Program (SVF/SRAM) ---"
    openFPGALoader -c ft232 "$BUILD/blake3_bench.svf"
fi

echo ""
echo "Done."
