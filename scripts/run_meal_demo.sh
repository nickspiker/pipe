#!/usr/bin/env bash
# =============================================================================
# run_meal_demo.sh — orchestrates the three-phase Meal Deal demonstration.
#
# Usage:
#   run_meal_demo.sh phase1
#   run_meal_demo.sh phase2 <ira_hex>
#   run_meal_demo.sh phase3 <variant>
#   run_meal_demo.sh expect <ira_hex> <challenge_hex>
#
# Phases:
#   phase1                  Build v1 (no bake), program SRAM. User then presses
#                           Enter on the keypad → ceremony runs → IRA appears
#                           on OLED line 1 (mode 1 IRA HEX, default mode at
#                           boot). Read the 64 hex chars off the screen.
#
#   phase2 <ira_hex>        Build v2 with that IRA baked in, write to flash.
#                           User power-cycles the board (yank cable, replug).
#                           Board boots directly HEALTHY (no ceremony, no LED
#                           busy phase). OLED mode 1 shows the same IRA.
#                           Pull plug, replug again → same IRA persists.
#                           That's the persistence proof.
#
#   phase3 <variant>        Build v3 with a fault-injection fixture
#                           (partial_1 / partial_2 / partial_3 /
#                            single_bit_one_pair / single_bit_two_pairs).
#                           Program SRAM. User observes chip_state on OLED
#                           mode 0 (STATUS) — should match the expected
#                           FUCKED / DEGRADED-2 / DEGRADED-1 verdict.
#
#   expect <ira_hex> <challenge_hex>
#                           Compute the expected BLAKE3 keyed_hash response
#                           via the host's `bridge meal_challenge` command.
#                           Print the expected wire output so user can compare
#                           against captured wire trace (LA / scope / future
#                           wire-driven automation).
# =============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."
HOST="$ROOT/host"

usage() {
    sed -n 's/^# \{0,1\}//p' "$0" | sed -n '/^=/,$p' | head -50
    exit 1
}

PHASE="$1"
shift || true

case "$PHASE" in
    phase1)
        echo "=== PHASE 1: ceremony (v1) ==="
        echo "Building v1 bitstream — no slots baked, boots VIRGIN..."
        "$SCRIPT_DIR/build_pipe_meal_lite.sh" --program
        echo ""
        echo "Board is now programmed in SRAM. On the board:"
        echo "  1. OLED line 0..3 shows all-zero IRA HEX (mode 1 default)."
        echo "  2. LED ext is at ~40 Hz (ring 0 diagnostic, VIRGIN-idle)."
        echo "  3. Press Enter on the keypad → ceremony runs:"
        echo "     - LED transitions to ~12 Hz fast blink (busy)"
        echo "     - After ~3s, transitions to solid (HEALTHY)"
        echo "     - OLED mode 1 now displays the freshly-generated IRA"
        echo "       (64 hex chars across 4 lines, 16 per line)"
        echo "  4. Write down the 64-hex-char IRA. Use it as input to phase2."
        echo ""
        echo "Optional sanity: from another shell, run"
        echo "  cd $HOST && cargo run --bin bridge -- meal_challenge <random_64hex> --expected-ira <IRA from OLED>"
        echo "  This prints the locally-computed BLAKE3(IRA, challenge); the FPGA"
        echo "  wire output for that challenge should match it bit-for-bit."
        ;;
    phase2)
        IRA="$1"
        if [ -z "$IRA" ] || [ ${#IRA} -ne 64 ]; then
            echo "Error: phase2 needs <ira_hex> (64 chars)" >&2
            usage
        fi
        echo "=== PHASE 2: persistence (v2) ==="
        echo "Building v2 bitstream with IRA = $IRA baked at synthesis..."
        "$SCRIPT_DIR/build_pipe_meal_lite.sh" --bake-ira "$IRA" --flash
        echo ""
        echo "Bitstream written to SPI flash. On the board:"
        echo "  1. Power-cycle the board (yank USB cable, replug)."
        echo "  2. Board boots — OLED mode 0 (chip_state) should show HEALTHY."
        echo "     NO ceremony runs (slots are pre-burned); LED goes solid"
        echo "     immediately (~few hundred ms boot time)."
        echo "  3. OLED mode 1 (press '1' key) shows the same IRA = $IRA."
        echo "  4. Pull cable, replug — same IRA, same HEALTHY state."
        echo "     Repeat several times. No drift. That's persistence."
        echo ""
        echo "  5. For challenge-response verification:"
        echo "       cd $HOST && cargo run --bin bridge -- meal_challenge <random_64hex> --expected-ira $IRA"
        echo "     Print the expected wire response. Capture the FPGA's actual"
        echo "     wire output (LA / scope). They must match bit-for-bit."
        ;;
    phase3)
        VARIANT="$1"
        if [ -z "$VARIANT" ]; then
            echo "Error: phase3 needs <variant>" >&2
            usage
        fi
        echo "=== PHASE 3: fault injection (v3 / $VARIANT) ==="
        echo "Building v3 bitstream with fault fixture '$VARIANT' baked at synthesis..."
        "$SCRIPT_DIR/build_pipe_meal_lite.sh" --bake-fault "$VARIANT" --program
        echo ""
        echo "Board is now programmed in SRAM. On the board:"
        case "$VARIANT" in
            partial_1)
                echo "  Expected: chip_state = FUCKED (only 1 valid pair, byzantine threshold not met)."
                echo "  LED: ~1.5 Hz slow blink. Wire output: silent."
                ;;
            partial_2)
                echo "  Expected: chip_state = DEGRADED-2 (2 valid pairs, 2 virgin)."
                echo "  LED: solid (chip_alive). Wire: responds to challenges using IRA from valid pairs."
                ;;
            partial_3)
                echo "  Expected: chip_state = DEGRADED-1 (3 valid pairs, 1 virgin)."
                echo "  LED: solid. Wire: responds, same IRA recovered."
                ;;
            single_bit_one_pair)
                echo "  Expected: chip_state = DEGRADED-1 (1 single-bit-corrupt pair, 3 valid)."
                echo "  LED: solid. Wire: responds, IRA recovered from valid majority."
                ;;
            single_bit_two_pairs)
                echo "  Expected: chip_state = DEGRADED-2 (2 corrupt, 2 valid)."
                echo "  LED: solid. Wire: responds, IRA recovered from valid pairs."
                ;;
            *)
                echo "  (Unknown variant '$VARIANT' — see build script for expected outcome.)"
                ;;
        esac
        echo ""
        echo "Read chip_state from OLED mode 0 (press '0' key). Verify it matches expected."
        echo ""
        echo "The fixed reference IRA used for fault fixtures is:"
        echo "  0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        echo "For DEGRADED variants (chip_alive), this IRA should appear on OLED mode 1"
        echo "(it's recoverable from the valid pairs)."
        ;;
    expect)
        IRA="$1"
        CHAL="$2"
        if [ -z "$IRA" ] || [ -z "$CHAL" ]; then
            echo "Error: expect needs <ira_hex> <challenge_hex>" >&2
            usage
        fi
        cd "$HOST" && cargo run --quiet --bin bridge -- meal_challenge "$CHAL" --expected-ira "$IRA"
        ;;
    ""|help|--help|-h)
        usage
        ;;
    *)
        echo "Unknown phase: $PHASE" >&2
        usage
        ;;
esac
