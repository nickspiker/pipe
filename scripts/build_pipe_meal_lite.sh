#!/usr/bin/env bash
# =============================================================================
# build_pipe_meal_lite.sh — Meal Deal without runtime flash R/W.
#
# Synthesizes top_pipe_meal_lite.v with emulated otp.v. The IRA persistence
# story is delivered by baking the IRA (or a deliberately corrupt fault
# fixture) into the bitstream via $readmemh on a generated init file —
# the FPGA-shaped equivalent of factory-provisioning eFuses.
#
# Flags:
#   --bake-ira <64-hex>     Bake the given IRA into all 4 A slots (slot 0..3)
#                           with its bitwise complement in the 4 B slots
#                           (slot 4..7). The resulting bitstream boots
#                           directly HEALTHY. Used for the v2 persistence
#                           demo: read IRA from v1's OLED, type it here,
#                           flash this bitstream, power-cycle, prove same
#                           challenge-response output.
#
#   --bake-fault <variant>  Bake a corrupt configuration that exercises the
#                           inverted_pair_verify classifier's robustness on a
#                           chip that was successfully provisioned at some
#                           point in the past, then later suffered cell-level
#                           damage (single-event upset, latent defect, etc.).
#                           The energy-budgeted atomic-commit architecture
#                           (see patent Detailed Description) precludes the
#                           "interrupted ceremony" failure mode entirely:
#                           either the burn completes atomically or it never
#                           starts, so partially-burned-but-uncommitted slot
#                           configurations are not reachable in normal
#                           operation. The fault fixtures here therefore
#                           model post-commit damage only.
#                           Variants:
#                             partial_1            → pair 0 valid, 1/2/3 kore
#                                                    (expect NGARO, 1 < byzantine)
#                             partial_2            → pairs 0,1 valid, 2,3 kore
#                                                    (expect WHARA)
#                             partial_3            → pairs 0,1,2 valid, 3 kore
#                                                    (expect HARA)
#                             single_bit_one_pair  → all 4 pairs but slot[0]
#                                                    has one bit flipped
#                                                    (expect HARA)
#                             single_bit_two_pairs → all 4 pairs but slot[0]
#                                                    AND slot[1] each have one
#                                                    bit flipped (expect WHARA)
#
#   --program               openFPGALoader to SRAM (volatile, fast iteration)
#   --flash                 openFPGALoader to SPI flash (non-volatile, survives
#                           power cycle — needed for the v2 persistence demo)
#
# (No flag for OTP_INIT_FILE → bitstream boots VIRGIN, ceremony runs at first
# Enter press. This is the v1 ceremony demo.)
#
# The fixed reference IRA used by all fault-injection fixtures is:
#   0123456789ABCDEF 0123456789ABCDEF 0123456789ABCDEF 0123456789ABCDEF
# Deterministic and easy to recognize on the OLED.
# =============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."
RTL="$ROOT/rtl"
MEASURE="$ROOT/rtl/measure"
LPF="$ROOT/constraints/pipe_meal_lite.lpf"
BUILD="$ROOT/build_pipe_meal_lite"
SEED="${SEED:-4}"

# Fixed reference IRA for all fault fixtures (256 bits = 64 hex chars).
FAULT_IRA="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

# Pre-computed bitwise complement of FAULT_IRA via hex-digit inversion.
FAULT_NOT_IRA="fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"

# Compute bitwise complement of a 64-hex-char string using digit-by-digit
# inversion (0↔F, 1↔E, …, 7↔8). Pure bash, no external deps.
# Source class 0-9a-fA-F (22 chars) maps to target (22 chars, lowercase).
hex_complement() {
    echo -n "$1" | tr '0123456789abcdefABCDEF' 'fedcba9876543210543210'
}

# Flip the LSB (last bit) of a 64-hex-char string by XORing the trailing
# nibble with 1.
flip_lsb() {
    local s="$1"
    local last="${s: -1}"
    local head="${s:0:${#s}-1}"
    local flipped
    case "$last" in
        0) flipped=1 ;; 1) flipped=0 ;; 2) flipped=3 ;; 3) flipped=2 ;;
        4) flipped=5 ;; 5) flipped=4 ;; 6) flipped=7 ;; 7) flipped=6 ;;
        8) flipped=9 ;; 9) flipped=8 ;; a) flipped=b ;; b) flipped=a ;;
        c) flipped=d ;; d) flipped=c ;; e) flipped=f ;; f) flipped=e ;;
        *) echo "flip_lsb: bad hex char '$last'" >&2; exit 1 ;;
    esac
    echo -n "${head}${flipped}"
}

ZERO_SLOT=$(printf '0%.0s' $(seq 1 64))

# Parse args
PROGRAM=0
FLASH=0
BAKE_IRA=""
BAKE_FAULT=""

while [ $# -gt 0 ]; do
    case "$1" in
        --program)    PROGRAM=1 ;;
        --flash)      FLASH=1   ;;
        --bake-ira)   BAKE_IRA="$2"; shift ;;
        --bake-fault) BAKE_FAULT="$2"; shift ;;
        *)            echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
    shift
done

if [ -n "$BAKE_IRA" ] && [ -n "$BAKE_FAULT" ]; then
    echo "Error: --bake-ira and --bake-fault are mutually exclusive" >&2
    exit 1
fi

mkdir -p "$BUILD"
cp "$ROOT/rtl/glyph_atlas.mem"    "$BUILD/"
cp "$ROOT/rtl/glyph_advance.mem"  "$BUILD/"

# ---------------------------------------------------------------------------
# Generate otp_init.mem if needed.
# Format: 8 lines of 64 hex chars each. Line N = slot[N] (256-bit slot value).
# Lines 0..3 = A slots (IRA), lines 4..7 = B slots (complement of IRA).
# ---------------------------------------------------------------------------
OTP_DEFINE=""
INIT_MEM="$BUILD/otp_init.mem"

if [ -n "$BAKE_IRA" ]; then
    # Validate length
    if [ ${#BAKE_IRA} -ne 64 ]; then
        echo "Error: --bake-ira expects exactly 64 hex chars (got ${#BAKE_IRA})" >&2
        exit 1
    fi
    BAKE_IRA_LOWER=$(echo -n "$BAKE_IRA" | tr 'A-F' 'a-f')
    NOT_IRA=$(hex_complement "$BAKE_IRA_LOWER")
    {
        for _ in 1 2 3 4; do echo "$BAKE_IRA_LOWER"; done
        for _ in 1 2 3 4; do echo "$NOT_IRA";        done
    } > "$INIT_MEM"
    OTP_DEFINE='-DOTP_INIT_FILE="otp_init.mem"'
    echo "Baked IRA → $INIT_MEM"
    echo "  slots 0..3: $BAKE_IRA_LOWER"
    echo "  slots 4..7: $NOT_IRA"
elif [ -n "$BAKE_FAULT" ]; then
    case "$BAKE_FAULT" in
        partial_1)
            # Pair 0 valid; pairs 1,2,3 virgin (slots 1,2,3,5,6,7 all zero).
            {
                echo "$FAULT_IRA"
                echo "$ZERO_SLOT"
                echo "$ZERO_SLOT"
                echo "$ZERO_SLOT"
                echo "$FAULT_NOT_IRA"
                echo "$ZERO_SLOT"
                echo "$ZERO_SLOT"
                echo "$ZERO_SLOT"
            } > "$INIT_MEM"
            ;;
        partial_2)
            # Pairs 0,1 valid; pairs 2,3 virgin.
            {
                echo "$FAULT_IRA"
                echo "$FAULT_IRA"
                echo "$ZERO_SLOT"
                echo "$ZERO_SLOT"
                echo "$FAULT_NOT_IRA"
                echo "$FAULT_NOT_IRA"
                echo "$ZERO_SLOT"
                echo "$ZERO_SLOT"
            } > "$INIT_MEM"
            ;;
        partial_3)
            # Pairs 0,1,2 valid; pair 3 virgin.
            {
                echo "$FAULT_IRA"
                echo "$FAULT_IRA"
                echo "$FAULT_IRA"
                echo "$ZERO_SLOT"
                echo "$FAULT_NOT_IRA"
                echo "$FAULT_NOT_IRA"
                echo "$FAULT_NOT_IRA"
                echo "$ZERO_SLOT"
            } > "$INIT_MEM"
            ;;
        single_bit_one_pair)
            # All 4 pairs but slot[0] has its LSB flipped (so slot[0] XOR slot[4]
            # is not all-1s → pair 0 corrupt, pairs 1/2/3 valid → DEGRADED-1).
            FLIPPED=$(flip_lsb "$FAULT_IRA")
            {
                echo "$FLIPPED"
                echo "$FAULT_IRA"
                echo "$FAULT_IRA"
                echo "$FAULT_IRA"
                echo "$FAULT_NOT_IRA"
                echo "$FAULT_NOT_IRA"
                echo "$FAULT_NOT_IRA"
                echo "$FAULT_NOT_IRA"
            } > "$INIT_MEM"
            ;;
        single_bit_two_pairs)
            # slot[0] and slot[1] each have LSB flipped → pairs 0,1 corrupt,
            # pairs 2,3 valid → DEGRADED-2.
            FLIPPED=$(flip_lsb "$FAULT_IRA")
            {
                echo "$FLIPPED"
                echo "$FLIPPED"
                echo "$FAULT_IRA"
                echo "$FAULT_IRA"
                echo "$FAULT_NOT_IRA"
                echo "$FAULT_NOT_IRA"
                echo "$FAULT_NOT_IRA"
                echo "$FAULT_NOT_IRA"
            } > "$INIT_MEM"
            ;;
        *)
            echo "Error: unknown fault variant '$BAKE_FAULT'" >&2
            echo "  expected one of: partial_1 partial_2 partial_3 single_bit_one_pair single_bit_two_pairs" >&2
            exit 1
            ;;
    esac
    OTP_DEFINE='-DOTP_INIT_FILE="otp_init.mem"'
    echo "Baked fault fixture '$BAKE_FAULT' → $INIT_MEM"
fi

echo "================================================================"
if   [ -n "$BAKE_IRA" ];   then echo " MEAL LITE v2: baked IRA, boots ORA"
elif [ -n "$BAKE_FAULT" ]; then echo " MEAL LITE v3: post-commit fault fixture '$BAKE_FAULT'"
else                            echo " MEAL LITE v1: KORE boot, ceremony runs"
fi
echo "================================================================"

echo ""
echo "--- Synthesise ---"
# The OTP_INIT_FILE define is scoped to otp.v's read_verilog call so the
# `\`define` survives only inside otp.v's preprocessor pass. Other files
# don't need to know about it.
(cd "$BUILD" && yosys -p "
    read_verilog -I $RTL $RTL/blake3/blake3.v
    read_verilog -I $RTL $RTL/blake3_tree_shared.v
    read_verilog -I $RTL $RTL/ring_health.v
    read_verilog -I $RTL $RTL/ring_scheduler.v
    read_verilog -I $RTL $RTL/trng.v
    read_verilog -I $RTL $OTP_DEFINE $RTL/otp.v
    read_verilog -I $RTL $RTL/inverted_pair_verify.v
    read_verilog -I $RTL $RTL/ira_fsm.v
    read_verilog -I $RTL $RTL/l3_session_fsm.v
    read_verilog -I $RTL $RTL/wire_io.v
    read_verilog -I $RTL $RTL/ssd1306_i2c.v
    read_verilog -I $RTL $RTL/oled_greyscale_driver.v
    read_verilog -I $RTL $RTL/oled_text_renderer.v
    read_verilog -I $RTL $RTL/oled_mode_fsm.v
    read_verilog -I $RTL $RTL/keypad.v
    read_verilog -I $RTL $MEASURE/top_pipe_meal_lite.v
    synth_ecp5 -nowidelut -abc2 -top top_pipe_meal_lite -json pipe_meal_lite.json
    stat
") > "$BUILD/yosys.log" 2>&1

if grep -q 'ERROR' "$BUILD/yosys.log"; then
    echo "YOSYS ERROR — see $BUILD/yosys.log"; tail -40 "$BUILD/yosys.log"; exit 1
fi
grep -E '^\s+[0-9]+ +(LUT4|TRELLIS_FF|CCU2C|DP16KD)' "$BUILD/yosys.log" | tail -10

echo ""
echo "--- Place & Route ---"
nextpnr-ecp5 --25k --package CABGA256 --speed 6 --seed "$SEED" \
    --lpf "$LPF" \
    --json "$BUILD/pipe_meal_lite.json" \
    --textcfg "$BUILD/pipe_meal_lite.config" \
    --ignore-loops --timing-allow-fail \
    > "$BUILD/pnr.log" 2>&1

if grep -q 'ERROR' "$BUILD/pnr.log"; then
    echo "PNR ERROR — see $BUILD/pnr.log"; tail -40 "$BUILD/pnr.log"; exit 1
fi
grep -E "(Max frequency|Total LUT4|Info: Device utilisation)" "$BUILD/pnr.log" | head -8

echo ""
echo "--- Pack bitstream ---"
ecppack --svf "$BUILD/pipe_meal_lite.svf" "$BUILD/pipe_meal_lite.config" "$BUILD/pipe_meal_lite.bit"
echo "Bitstream: $BUILD/pipe_meal_lite.bit ($(stat -c%s "$BUILD/pipe_meal_lite.bit") bytes)"

if [ "$FLASH" -eq 1 ]; then
    echo ""
    echo "--- Write flash (non-volatile) ---"
    openFPGALoader -c ft232 --write-flash "$BUILD/pipe_meal_lite.bit"
fi

if [ "$PROGRAM" -eq 1 ]; then
    echo ""
    echo "--- Program SRAM (volatile) ---"
    openFPGALoader -c ft232 "$BUILD/pipe_meal_lite.svf"
fi

echo ""
echo "Done."
