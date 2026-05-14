#!/usr/bin/env bash
# =============================================================================
# build_freq_counter.sh — Phase B/C measurement bitstreams.
# =============================================================================
#
# Builds top_extclk.v on Colorlight 5A-75B v8.0 (ECP5-25F) in one of two modes:
#
#   PHASE B — ring oscillator characterization:
#     ./build_freq_counter.sh --ring=N [--program] [--flash]
#     N-stage internal LUT4 ring (1 NOT + (N-1) BUFs) → frequency counted
#     against the 25 MHz crystal → milli-MHz on OLED.
#
#   PHASE C — BLAKE3 silicon Fmax bench:
#     ./build_freq_counter.sh --blake3            [--program] [--flash]
#     ./build_freq_counter.sh --blake3 --mhz=NN   [--program] [--flash]
#     blake3 hashes continuously on bench_clk; LFSR-driven inputs;
#     32-bit rotate-XOR accumulator over 131072 samples → result_reg
#     displayed on OLED. At any frequency where timing closes, result_reg is
#     deterministic. --mhz=NN engages the PLL for higher frequencies; without
#     it bench_clk = 25 MHz (no PLL — this is the ground-truth baseline).
#
# THIS IS A MEASUREMENT BITSTREAM. It uses the 25 MHz crystal as a reference.
# It is NOT the production PIPE bitstream — that one is built by build_pipe.sh
# and contains zero clock primitives and zero crystal pin mapping.
#
# Files vendored from spirix at commit a23538ee882ef434dd9bb3661e5dc896dce72711:
#   rtl/measure/top_extclk.v        ← spirix/fpga/bench/top_extclk.v (modified)
#   rtl/measure/ssd1306_i2c.v       ← spirix/fpga/bench/ssd1306_i2c.v
#   data/decimal_glyphs.mem         ← spirix/fpga/data/decimal_glyphs.mem
#   constraints/freq_counter.lpf    ← spirix/fpga/constraints/extclk.lpf
#
# =============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."
RTL="$ROOT/rtl/measure"
BLAKE3_RTL="$ROOT/rtl/blake3"
DATA="$ROOT/data"
LPF="$ROOT/constraints/freq_counter.lpf"
BUILD="$ROOT/build_freq_counter"
SEED="${SEED:-4}"

PROGRAM=0
FLASH=0
MODE=""
RING_STAGES=""
PLL_MHZ=""
for arg in "$@"; do
    case "$arg" in
        --program)   PROGRAM=1 ;;
        --flash)     FLASH=1   ;;
        --ring=*)
            MODE="ring"
            RING_STAGES="${arg#--ring=}"
            ;;
        --blake3)
            MODE="blake3"
            ;;
        --mhz=*)
            PLL_MHZ="${arg#--mhz=}"
            ;;
        *)
            echo "unknown arg: $arg" >&2
            echo "usage: $0 (--ring=N | --blake3 [--mhz=NN]) [--program] [--flash]" >&2
            exit 1
            ;;
    esac
done

if [ -z "$MODE" ]; then
    echo "ERROR: must specify --ring=N or --blake3" >&2
    exit 1
fi

# Mode-specific argument validation + yosys defines
YOSYS_DEFINES=""
EXTRA_VERILOG=""
PHASE_LABEL=""

if [ "$MODE" = "ring" ]; then
    if [ -z "$RING_STAGES" ] || [ "$RING_STAGES" -lt 1 ]; then
        echo "ERROR: --ring=N requires N ≥ 1 (got '$RING_STAGES')" >&2
        exit 1
    fi
    YOSYS_DEFINES="-DRING_TEST -DRING_STAGES=$RING_STAGES"
    PHASE_LABEL="Phase B — ring oscillator (RING_STAGES=$RING_STAGES, 1 NOT + $((RING_STAGES-1)) BUFs)"
elif [ "$MODE" = "blake3" ]; then
    EXTRA_VERILOG="$BLAKE3_RTL/blake3.v"
    if [ -n "$PLL_MHZ" ]; then
        # Compute PLL params via ecppll (CLKI = 25 MHz, CLKOP = PLL_MHZ)
        PLL_OUT=$(ecppll -i 25 -o "$PLL_MHZ" -f /dev/null 2>&1)
        CLKI=$(echo "$PLL_OUT"  | awk '/Refclk divisor:/  {print $3}')
        CLKFB=$(echo "$PLL_OUT" | awk '/Feedback divisor:/ {print $3}')
        CLKOP=$(echo "$PLL_OUT" | awk '/clkout0 divisor:/  {print $3}')
        ACTUAL_MHZ=$(echo "$PLL_OUT" | awk '/clkout0 frequency:/ {print $3}')
        FVCO=$(echo "$PLL_OUT"  | awk '/VCO frequency:/    {print $3}')
        if [ -z "$CLKI" ] || [ -z "$CLKFB" ] || [ -z "$CLKOP" ]; then
            echo "ERROR: ecppll failed for ${PLL_MHZ} MHz" >&2
            echo "$PLL_OUT" >&2
            exit 1
        fi
        CPHASE=$(( (CLKOP - 1) / 2 ))
        YOSYS_DEFINES="-DDUT_BLAKE3 -DPLL_TEST"
        YOSYS_DEFINES="$YOSYS_DEFINES -DPLL_CLKI_DIV=$CLKI"
        YOSYS_DEFINES="$YOSYS_DEFINES -DPLL_CLKFB_DIV=$CLKFB"
        YOSYS_DEFINES="$YOSYS_DEFINES -DPLL_CLKOP_DIV=$CLKOP"
        YOSYS_DEFINES="$YOSYS_DEFINES -DPLL_CLKOP_CPHASE=$CPHASE"
        PHASE_LABEL="Phase C — blake3 bench @ ${ACTUAL_MHZ} MHz (PLL CLKI=$CLKI CLKFB=$CLKFB CLKOP=$CLKOP, VCO=$FVCO MHz)"
    else
        YOSYS_DEFINES="-DDUT_BLAKE3"
        PHASE_LABEL="Phase C — blake3 bench @ 25 MHz (no PLL, baseline)"
    fi
fi

mkdir -p "$BUILD"

# Stage glyph ROM in build dir for $readmemh
cp -f "$DATA/decimal_glyphs.mem" "$BUILD/decimal_glyphs.mem"

echo "================================================================"
echo " $PHASE_LABEL"
echo "================================================================"

echo ""
echo "--- Synthesise ---"
cd "$BUILD"
yosys -p "
    read_verilog $ROOT/rtl/ssd1306_i2c.v
    ${EXTRA_VERILOG:+read_verilog $EXTRA_VERILOG}
    read_verilog $YOSYS_DEFINES $RTL/top_extclk.v
    synth_ecp5 -nowidelut -abc2 -top top_extclk -json $BUILD/freq_counter.json
    stat
" 2>&1 | tee "$BUILD/freq_counter_yosys.log" | grep -E "(LUT4|CCU2C|TRELLIS_FF|EHXPLLL|Warning|Error)" | head -15
cd - > /dev/null

if grep -q 'ERROR' "$BUILD/freq_counter_yosys.log"; then
    echo "YOSYS ERROR — see $BUILD/freq_counter_yosys.log"
    exit 1
fi

echo ""
echo "--- Place & Route ---"
nextpnr-ecp5 --25k --package CABGA256 --speed 6 --seed "$SEED" \
    --lpf "$LPF" \
    --json "$BUILD/freq_counter.json" \
    --textcfg "$BUILD/freq_counter.config" \
    --ignore-loops --timing-allow-fail \
    2>&1 | tee "$BUILD/freq_counter_pnr.log" | grep -E "(Max frequency|Total LUT4|Warning|Error|Info: Device utilisation)" | head -15

if grep -q 'ERROR' "$BUILD/freq_counter_pnr.log"; then
    echo "PNR ERROR — see $BUILD/freq_counter_pnr.log"
    exit 1
fi

echo ""
echo "--- Pack bitstream ---"
ecppack --svf "$BUILD/freq_counter.svf" "$BUILD/freq_counter.config" "$BUILD/freq_counter.bit"
echo "Bitstream: $BUILD/freq_counter.bit ($(stat -c%s "$BUILD/freq_counter.bit") bytes)"

if [ "$PROGRAM" -eq 1 ]; then
    echo ""
    echo "--- Program SRAM ---"
    openFPGALoader -c ft232 "$BUILD/freq_counter.svf"
fi

if [ "$FLASH" -eq 1 ]; then
    echo ""
    echo "--- Write flash ---"
    openFPGALoader -c ft232 --write-flash "$BUILD/freq_counter.bit"
fi

echo ""
if [ "$MODE" = "ring" ]; then
    echo "Done. Read milli-MHz off the OLED."
    echo "Append result to phase_b_results.csv:"
    echo "  echo '$RING_STAGES,<MHz>,,N=$RING_STAGES from build_freq_counter.sh' >> phase_b_results.csv"
else
    if [ -n "$PLL_MHZ" ]; then
        TARGET_MHZ="$PLL_MHZ"
    else
        TARGET_MHZ="25"
    fi
    echo "Done. Read result_reg signature off the OLED (NOT actually MHz in this mode)."
    echo "Append result to phase_c_results.csv:"
    echo "  echo '$TARGET_MHZ,<displayed>,blake3 @ $TARGET_MHZ MHz' >> phase_c_results.csv"
fi
