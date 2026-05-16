#!/usr/bin/env bash
# =============================================================================
# run.sh — pipe sim runner. Compile + execute one tb_*.v with iverilog.
# =============================================================================
#
# Each testbench instantiates its DUT directly (no ring_osc, no DCCA — those
# are FPGA primitives iverilog can't model). TBs supply a behavioral clock.
#
# Usage:
#   ./run.sh tb_key_register          # compile rtl/key_register.v + sim/tb_key_register.v
#   ./run.sh tb_boot                  # ditto for boot_fsm
#   ./run.sh                          # run all tb_*.v in this directory
#
# Per-TB convention: tb_NAME.v exercises rtl/NAME.v. The runner figures out the
# DUT source from the testbench filename.
#
# Exits non-zero if any test reports OVERALL FAIL or if iverilog/vvp errors.
# =============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."
RTL="$ROOT/rtl"
SIM="$SCRIPT_DIR"
WORK="$SIM/work"
mkdir -p "$WORK"

run_one () {
    local tb="$1"   # e.g. tb_key_register
    local dut="${tb#tb_}"   # strip tb_ prefix → key_register
    local tb_v="$SIM/${tb}.v"
    local dut_v="$RTL/${dut}.v"

    if [ ! -f "$tb_v" ];  then echo "missing TB: $tb_v"; exit 2; fi
    if [ ! -f "$dut_v" ]; then echo "missing DUT: $dut_v"; exit 2; fi

    # Optional extra RTL dependencies declared in the TB as `// deps: foo.v bar.v`
    local extra_rtl=""
    local deps_line
    deps_line=$(grep -E "^// deps:" "$tb_v" | head -1 || true)
    if [ -n "$deps_line" ]; then
        # extract file list after the colon
        local deps_files="${deps_line#// deps:}"
        for f in $deps_files; do
            if [ -f "$RTL/$f" ]; then
                extra_rtl="$extra_rtl $RTL/$f"
            else
                echo "missing dep: $RTL/$f"; exit 2
            fi
        done
    fi

    echo "=== $tb ==="
    iverilog -g2012 -o "$WORK/${tb}" $extra_rtl "$dut_v" "$tb_v"
    OUTPUT=$(vvp "$WORK/${tb}")
    echo "$OUTPUT"
    echo ""

    if echo "$OUTPUT" | grep -q "^OVERALL FAIL"; then
        echo "→ $tb FAILED"
        return 1
    elif echo "$OUTPUT" | grep -q "^OVERALL PASS"; then
        echo "→ $tb passed"
        return 0
    else
        echo "→ $tb produced no PASS/FAIL summary line — check the testbench"
        return 1
    fi
}

if [ -n "$1" ]; then
    run_one "$1"
else
    failures=0
    for tb_v in "$SIM"/tb_*.v; do
        tb_name="$(basename "$tb_v" .v)"
        run_one "$tb_name" || failures=$((failures + 1))
    done
    echo ""
    if [ "$failures" -eq 0 ]; then
        echo "ALL SIMS PASS"
    else
        echo "$failures sim(s) FAILED"
        exit 1
    fi
fi
