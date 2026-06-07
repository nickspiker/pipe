// =============================================================================
// otp.v — 8-slot one-time-programmable storage (FPGA emulator)
// =============================================================================
//
// Storage primitive for the 8-slot inverted-pair `ira` eFuse described in IRA.md §"OTP geometry — 8 slots, 4 inverted pairs". Each slot holds 256 bits; the 8 slots are organized as 4 pairs by the caller:
//
//   slot 0 = pair 0 A (ira)        slot 4 = pair 0 B (~ira)
//   slot 1 = pair 1 A (ira)        slot 5 = pair 1 B (~ira)
//   slot 2 = pair 2 A (ira)        slot 6 = pair 2 B (~ira)
//   slot 3 = pair 3 A (ira)        slot 7 = pair 3 B (~ira)
//
// This module is the pure storage layer. It knows nothing about pair geometry, `ira`/`~ira` inversion semantics, the 5-state classifier, or the TAHU burn sequence — those live in `ira_fsm.v` and the shared `inverted_pair_verify.v`.
// The interface (8-slot byte-flat memory + per-slot burned flag + write-once enforcement) is identical between this FPGA emulator and the silicon eFuse macro that replaces it at tapeout — only the storage backend changes.
//
// Persistence: by default FPGA emulation does NOT persist across power cycles.
// Every power-on starts with all slots in the KORE state (all zeros, all burned flags clear).
//
// The `INIT_FILE` parameter provides a synthesis-time alternative: the bitstream itself carries pre-burned slot contents. This is the FPGA-shaped equivalent of factory-provisioning eFuses: once baked into the bitstream, the slots come up populated at every power-on, just as eFuses come up already-burned every power-on. Used to demonstrate persistence (bake the IRA that came out of one boot's ceremony, then prove identical challenge-response across power cycles) and fault injection (bake deliberately corrupt configurations to exercise the inverted_pair_verify classifier — partial burns, single-bit errors, etc.).
//
// When INIT_FILE is set:
//   - $readmemh loads 8 lines × 64 hex chars (256 bits/slot) from the file into slot_data at synthesis time
//   - slot_burned[i] is derived as (slot_data[i] != 0) — non-zero slots are considered already-burned (write-rejected), all-zero slots remain write-eligible (so partial-burn fixtures can populate only some pairs)
//   - The reset path no longer clears slot_data / slot_burned, matching eFuse semantics (the fuses are already in their final state and don't un-burn on reset)
//
// When INIT_FILE is empty (default): original behavior — slot_data starts all-zero, slot_burned all-clear, ceremony runs at every boot.
//
// Reads are combinational — same cycle as the address presents. Writes pulse `write_enable` for one cycle; the result (success or rejected-because-burned) is signalled the following cycle via `write_done` / `write_rejected`.
//
// =============================================================================

`timescale 1ns / 1ps

// OTP_INIT_FILE may be set via `read_verilog -DOTP_INIT_FILE="<path>"` from the build script to bake slot contents at synthesis. The presence of the define selects the $readmemh path; absence leaves slots at the original KORE-at-boot zero state. The two init paths are mutually exclusive at preprocessor time so yosys's init pass sees only one set of constants.

module otp #(
    parameter integer SLOT_BITS = 256,
    parameter integer N_SLOTS   = 8
) (
    input  wire                          clk,
    input  wire                          reset_n,
    input  wire                          wipe,     // 1 = force-clear slot_data this cycle (dev convenience)

    // Combinational read port — read_data reflects slot_data[read_addr] in the same cycle the address is presented.
    input  wire [$clog2(N_SLOTS)-1:0]    read_addr,
    output wire [SLOT_BITS-1:0]          read_data,
    output wire                          read_burned,

    // Write/burn port — pulse write_enable for one cycle. On the next cycle, exactly one of write_done or write_rejected pulses high.
    input  wire [$clog2(N_SLOTS)-1:0]    write_addr,
    input  wire [SLOT_BITS-1:0]          write_data,
    input  wire                          write_enable,
    output reg                           write_done,
    output reg                           write_rejected,

    // Inspection: bitmap of slots that have been burned (1 = burned).
    output wire [N_SLOTS-1:0]            burned_mask,

    // Parallel-slot read port — all 8 slots concatenated (slot 0 in low bits, slot 7 in high). Continuously valid. Used by inverted_pair_verify in top.v without needing hierarchical references.
    output wire [N_SLOTS*SLOT_BITS-1:0]  all_slots_flat
);

    // -------------------------------------------------------------------------
    // Storage. With 8 slots of 256 bits = 2048 bits, yosys typically infers distributed RAM / registers rather than block RAM (BRAM minimum is 18 Kbit on ECP5, which would be 89% wasted). Either is fine.
    // -------------------------------------------------------------------------
    reg [SLOT_BITS-1:0] slot_data [0:N_SLOTS-1];

    // -------------------------------------------------------------------------
    // Synthesis-time initialization of slot_data — mutually exclusive paths selected at preprocessor time. With OTP_INIT_FILE defined the bitstream GSR/power-on state is loaded from the hex file (baked IRA or fault fixture); otherwise all slots come up zero (KORE).
    // -------------------------------------------------------------------------
`ifdef OTP_INIT_FILE
    initial begin
        $readmemh(`OTP_INIT_FILE, slot_data);
    end
`else
    integer init_i;
    initial begin
        for (init_i = 0; init_i < N_SLOTS; init_i = init_i + 1) begin
            slot_data[init_i] = {SLOT_BITS{1'b0}};
        end
    end
`endif

    // slot_burned is derived combinationally from slot_data. A slot is "burned" iff any of its bits is set. This matches the original semantics (slot_burned was set in the same cycle slot_data was written) while allowing yosys's init pass to compute the burned-mask directly from the constant slot_data values without needing a separate reg with its own complex init dependency. The only edge case is writing all-zero data, which leaves the slot looking KORE — but real IRA values from BLAKE3 are astronomically unlikely to be all-zero, and fault fixtures that want zero slots also want them to look unburned.
    wire [N_SLOTS-1:0] slot_burned;
    genvar gb;
    generate
        for (gb = 0; gb < N_SLOTS; gb = gb + 1) begin : slot_burned_fanout
            assign slot_burned[gb] = |slot_data[gb];
        end
    endgenerate

    assign read_data   = slot_data[read_addr];
    assign read_burned = slot_burned[read_addr];
    assign burned_mask = slot_burned;

    genvar gs;
    generate
        for (gs = 0; gs < N_SLOTS; gs = gs + 1) begin : slot_fanout
            assign all_slots_flat[gs*SLOT_BITS +: SLOT_BITS] = slot_data[gs];
        end
    endgenerate

    // -------------------------------------------------------------------------
    // Write logic. write_enable is sampled on the rising edge; the result pulses one cycle later.
    //   - If the target slot is already burned, write is silently dropped and write_rejected pulses (write_done stays low).
    //   - Otherwise the slot is written, the burned flag is set, and write_done pulses.
    // -------------------------------------------------------------------------
    // The reset path intentionally does NOT clear slot_data — that's initialized by the `initial` block (above) and must persist across reset to match eFuse semantics (a real eFuse can't be "un-burned" by pulsing a reset line). Reset only clears the single-cycle handshake strobes.
    //
    // The `wipe` input IS allowed to clear slot_data — this is the dev- convenience escape hatch driven from the board's user button at top level. It models "you broke open the chip with a needle and zeroed the fuses"; not something the protocol exposes to external attackers.
    // Asserting wipe drops the chip back to KORE so a fresh ceremony can run without a full power cycle.
    // Single-write-port slot_data update. The wipe-clear-all is implemented by gating each slot's clock-enable individually, avoiding the multi-write-port memory inference that yosys does when a `for`-loop unrolled all-slot wipe coexists with the dynamic-index slot write (observed to corrupt the high bits of slot 0 on this codebase + yosys version). Explicit per-slot if-trees keep everything as plain regs.
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            write_done     <= 1'b0;
            write_rejected <= 1'b0;
        end else begin
            write_done     <= 1'b0;
            write_rejected <= 1'b0;
            if (write_enable && !wipe) begin
                if (slot_burned[write_addr]) begin
                    write_rejected <= 1'b1;
                end else begin
                    write_done <= 1'b1;
                end
            end
        end
    end

    // Per-slot clock-enabled storage. Single write port per register:
    // either wipe forces zero, or write_enable lands write_data when this slot is the addressed one and is currently unburned.
    genvar gw;
    generate
        for (gw = 0; gw < N_SLOTS; gw = gw + 1) begin : slot_writes
            always @(posedge clk) begin
                if (wipe) begin
                    slot_data[gw] <= {SLOT_BITS{1'b0}};
                end else if (write_enable
                             && (write_addr == gw[$clog2(N_SLOTS)-1:0])
                             && !slot_burned[gw]) begin
                    slot_data[gw] <= write_data;
                end
            end
        end
    endgenerate

endmodule
