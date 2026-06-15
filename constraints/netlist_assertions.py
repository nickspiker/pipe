#!/usr/bin/env python3
# =============================================================================
# netlist_assertions.py — Post-synthesis invariant checks for PIPE.
# =============================================================================
#
# Run via build_pipe.sh after yosys synth_ecp5 produces build/pipe.json.
# Exit 0 on success, non-zero on any assertion failure.
#
# These five assertions are the structural backbone of the PIPE security claim.
# Any change that breaks one of them changes the threat model.
#
# Phase A status: stub. The functions parse pipe.json (yosys "write_json" output
# format) and run the checks. Real implementations come during module work
# (Phases F+); for now they all pass-thru with TODO markers so build_pipe.sh
# can wire them in without failing trivially.
#
# Reference for the .json format:
#   https://yosyshq.readthedocs.io/projects/yosys/en/latest/cmd/write_json.html
# =============================================================================

import json
import sys
from pathlib import Path


# -----------------------------------------------------------------------------
# 1. key_register output has exactly one consumer, and it is blake3.i_chain
# -----------------------------------------------------------------------------
def test_key_register_fanout(netlist):
    """The 256b key_out net must connect to exactly one sink: blake3.i_chain.

    No path to any IOB. No path to any RAM/ROM. No second blake3 instance.
    If this fails, the secret has more than one place to leak from.
    """
    # TODO: walk netlist, find all sinks of key_register.key_out, assert
    # len(sinks) == 1 and sinks[0] is blake3.i_chain.
    pass


# -----------------------------------------------------------------------------
# 2. Zero external clock sources (no PCLKT pad usage)
# -----------------------------------------------------------------------------
def test_no_external_clock(netlist):
    """No FPGA clock-capable input pad (PCLKT) is connected to a clock net."""
    # TODO: scan port assignments, fail if any PCLKT-class pad reaches a clock.
    pass


# -----------------------------------------------------------------------------
# 3. Exactly one bidirectional IO pin (pipe_pad)
# -----------------------------------------------------------------------------
def test_single_io_pin(netlist):
    """The design exposes exactly one IO_PORT (excluding power/ground)."""
    # TODO: count top-level ports, assert 1 (pipe_pad).
    pass


# -----------------------------------------------------------------------------
# 4. boot_fsm OPERATIONAL state has no exit transitions
# -----------------------------------------------------------------------------
def test_boot_fsm_trap(netlist):
    """OPERATIONAL is a trap state: once entered, no edge leaves except POR."""
    # TODO: extract FSM transition table from boot_fsm.v (yosys preserves FSM
    # info with -keep), assert no outgoing edges from OPERATIONAL.
    pass


# -----------------------------------------------------------------------------
# 5. Zero forbidden clock primitives in the synthesized cell list
# -----------------------------------------------------------------------------
def test_no_clock_primitives(netlist):
    """No EHXPLLL, EHXPLLL_CORE, OSCG, or PLLREFCS instances anywhere."""
    forbidden = {"EHXPLLL", "EHXPLLL_CORE", "OSCG", "PLLREFCS"}
    instances = set()
    for module in netlist.get("modules", {}).values():
        for cell in module.get("cells", {}).values():
            instances.add(cell.get("type", ""))
    bad = forbidden & instances
    assert not bad, f"Forbidden clock primitives in netlist: {sorted(bad)}"


# -----------------------------------------------------------------------------
# Driver
# -----------------------------------------------------------------------------
def main():
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} build/pipe.json", file=sys.stderr)
        return 2
    netlist_path = Path(sys.argv[1])
    if not netlist_path.exists():
        print(f"netlist not found: {netlist_path}", file=sys.stderr)
        return 2
    with netlist_path.open() as f:
        netlist = json.load(f)

    checks = [
        ("key_register fanout == 1",      test_key_register_fanout),
        ("no external clock sources",     test_no_external_clock),
        ("exactly one bidir IO pin",      test_single_io_pin),
        ("boot_fsm OPERATIONAL trap",     test_boot_fsm_trap),
        ("no clock primitives",           test_no_clock_primitives),
    ]
    failures = 0
    for name, fn in checks:
        try:
            fn(netlist)
            print(f"  PASS  {name}")
        except AssertionError as e:
            print(f"  FAIL  {name}: {e}", file=sys.stderr)
            failures += 1
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
