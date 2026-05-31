#!/usr/bin/env bash
# =============================================================================
# build_pipe_meal.sh — Full Meal Deal bitstream + flash provisioning helper
# =============================================================================
# Builds top_pipe_meal.v (ira ceremony + flash-backed OTP slots + PIPE wire
# challenge-response). Default action: synthesise + pack + program SRAM for
# bring-up. Use --flash to also write to non-volatile SPI flash. Use
# --wipe-slots to erase the OTP slot sector (0x100000, 4 KB) before flashing,
# which returns the chip to VIRGIN state and forces a fresh ceremony on the
# next power-up. Without --wipe-slots, the existing IRA is preserved across
# bitstream re-flashes (only the bitstream region 0x000000..0x0FFFFF is
# overwritten).
# =============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."
RTL="$ROOT/rtl"
MEASURE="$ROOT/rtl/measure"
LPF="$ROOT/constraints/pipe_meal.lpf"
BUILD="$ROOT/build_pipe_meal"
SEED="${SEED:-4}"

PROGRAM=0
FLASH=0
WIPE=0
for arg in "$@"; do
    case "$arg" in
        --program)     PROGRAM=1 ;;
        --flash)       FLASH=1   ;;
        --wipe-slots)  WIPE=1    ;;
    esac
done

mkdir -p "$BUILD"
cp "$ROOT/rtl/glyph_atlas.mem"    "$BUILD/"
cp "$ROOT/rtl/glyph_advance.mem"  "$BUILD/"

echo "================================================================"
echo " PIPE Full Meal Deal — ceremony + flash slots + challenge/response"
echo "================================================================"

echo ""
echo "--- Synthesise ---"
(cd "$BUILD" && yosys -p "
    read_verilog -I $RTL $RTL/blake3/blake3.v
    read_verilog -I $RTL $RTL/blake3_tree_shared.v
    read_verilog -I $RTL $RTL/ring_health.v
    read_verilog -I $RTL $RTL/ring_scheduler.v
    read_verilog -I $RTL $RTL/trng.v
    read_verilog -I $RTL $RTL/spi_master.v
    read_verilog -I $RTL $RTL/otp_persistent.v
    read_verilog -I $RTL $RTL/inverted_pair_verify.v
    read_verilog -I $RTL $RTL/ira_fsm.v
    read_verilog -I $RTL $RTL/wire_io.v
    read_verilog -I $RTL $RTL/chal_resp_fsm.v
    read_verilog -I $RTL $RTL/ssd1306_i2c.v
    read_verilog -I $RTL $RTL/oled_greyscale_driver.v
    read_verilog -I $RTL $RTL/oled_text_renderer.v
    read_verilog -I $RTL $RTL/oled_mode_fsm.v
    read_verilog -I $RTL $RTL/keypad.v
    read_verilog -I $RTL $MEASURE/top_pipe_meal.v
    synth_ecp5 -nowidelut -abc2 -top top_pipe_meal -json pipe_meal.json
    stat
") > "$BUILD/yosys.log" 2>&1

if grep -q 'ERROR' "$BUILD/yosys.log"; then
    echo "YOSYS ERROR — see $BUILD/yosys.log"
    tail -40 "$BUILD/yosys.log"
    exit 1
fi
grep -E '^\s+[0-9]+ +(LUT4|TRELLIS_FF|CCU2C|DP16KD)' "$BUILD/yosys.log" | tail -10

echo ""
echo "--- Place & Route ---"
nextpnr-ecp5 --25k --package CABGA256 --speed 6 --seed "$SEED" \
    --lpf "$LPF" \
    --json "$BUILD/pipe_meal.json" \
    --textcfg "$BUILD/pipe_meal.config" \
    --ignore-loops --timing-allow-fail \
    > "$BUILD/pnr.log" 2>&1

if grep -q 'ERROR' "$BUILD/pnr.log"; then
    echo "PNR ERROR — see $BUILD/pnr.log"
    tail -40 "$BUILD/pnr.log"
    exit 1
fi
grep -E "(Max frequency|Total LUT4|Info: Device utilisation)" "$BUILD/pnr.log" | head -8

echo ""
echo "--- Pack bitstream ---"
ecppack --svf "$BUILD/pipe_meal.svf" "$BUILD/pipe_meal.config" "$BUILD/pipe_meal.bit"
echo "Bitstream: $BUILD/pipe_meal.bit ($(stat -c%s "$BUILD/pipe_meal.bit") bytes)"

# -----------------------------------------------------------------------------
# Flash slot sector wipe — clears the OTP region (0x100000, 4 KB), returning
# the chip to VIRGIN state. Issued BEFORE bitstream flash so the order of
# operations is: erase slots → flash bitstream → reset → boot → VIRGIN.
# -----------------------------------------------------------------------------
if [ "$WIPE" -eq 1 ]; then
    echo ""
    echo "--- Wipe OTP slot sector (0x100000, 4 KB) ---"
    # openFPGALoader doesn't expose a single-sector erase directly. The
    # simplest portable wipe is to write a 4 KB block of 0xFF to 0x100000
    # via the --offset + raw-bin path. Build a 4 KB all-0xFF blob and write.
    WIPE_BIN="$BUILD/wipe_4k.bin"
    head -c 4096 /dev/zero | tr '\0' '\377' > "$WIPE_BIN"
    openFPGALoader -c ft232 --write-flash --offset 0x100000 --file-type raw "$WIPE_BIN"
fi

if [ "$PROGRAM" -eq 1 ]; then
    echo ""
    echo "--- Program SRAM (volatile) ---"
    openFPGALoader -c ft232 "$BUILD/pipe_meal.svf"
fi

if [ "$FLASH" -eq 1 ]; then
    echo ""
    echo "--- Write flash (non-volatile, survives power cycles) ---"
    openFPGALoader -c ft232 --write-flash "$BUILD/pipe_meal.bit"
fi

echo ""
echo "Done."
echo ""
echo "Demo loop:"
echo "  1. $0 --flash --wipe-slots    (fresh provisioning state)"
echo "  2. Power-cycle the board"
echo "  3. T6 LED OFF on boot (VIRGIN — slots all 0xFF in flash)"
echo "  4. Press Enter on the dozenal keypad → ceremony → T6 solid (HEALTHY)"
echo "  5. \`bridge meal_dump_ira\` to read the just-committed IRA from flash"
echo "  6. \`bridge wire_meal_challenge <256-bit hex>\` → response = BLAKE3(IRA‖challenge)"
echo "  7. Pull cable, replug — boot reads IRA from flash, T6 immediately solid"
echo "  8. Repeat the same challenge → same bit-identical response (persistence proof)"
