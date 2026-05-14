// =============================================================================
// otp.v — 8-slot one-time-programmable storage (FPGA emulator)
// =============================================================================
//
// Storage primitive for the 8-slot inverted-pair `ira` eFuse described in
// IRA.md §"OTP geometry — 8 slots, 4 inverted pairs". Each slot holds 256
// bits; the 8 slots are organized as 4 pairs by the caller:
//
//   slot 0 = pair 0 A (ira)        slot 4 = pair 0 B (~ira)
//   slot 1 = pair 1 A (ira)        slot 5 = pair 1 B (~ira)
//   slot 2 = pair 2 A (ira)        slot 6 = pair 2 B (~ira)
//   slot 3 = pair 3 A (ira)        slot 7 = pair 3 B (~ira)
//
// This module is the pure storage layer. It knows nothing about pair geometry,
// `ira`/`~ira` inversion semantics, the 5-state classifier, or the TAHU burn
// sequence — those live in `ira_fsm.v` and the shared `inverted_pair_verify.v`.
// The interface (8-slot byte-flat memory + per-slot burned flag + write-once
// enforcement) is identical between this FPGA emulator and the silicon eFuse
// macro that replaces it at tapeout — only the storage backend changes.
//
// Persistence: FPGA emulation does NOT persist across power cycles. Every
// power-on starts with all slots in the VIRGIN state (all zeros, all burned
// flags clear). On silicon, eFuses physically retain their state after power
// loss — that's the whole point of OTP. For FPGA development, the price of
// non-persistence is having to re-run KOHI→TATARI→TAHU on every boot to get
// to an operating state; the upside is unambiguous VIRGIN-state testing
// without any "clear the chip" affordance (which would itself violate Claim 6
// indestructible-from-outside).
//
// Reads are combinational — same cycle as the address presents. Writes pulse
// `write_enable` for one cycle; the result (success or rejected-because-burned)
// is signalled the following cycle via `write_done` / `write_rejected`.
//
// =============================================================================

`timescale 1ns / 1ps

module otp #(
    parameter integer SLOT_BITS = 256,
    parameter integer N_SLOTS   = 8
) (
    input  wire                          clk,
    input  wire                          reset_n,

    // Combinational read port — read_data reflects slot_data[read_addr] in
    // the same cycle the address is presented.
    input  wire [$clog2(N_SLOTS)-1:0]    read_addr,
    output wire [SLOT_BITS-1:0]          read_data,
    output wire                          read_burned,

    // Write/burn port — pulse write_enable for one cycle. On the next cycle,
    // exactly one of write_done or write_rejected pulses high.
    input  wire [$clog2(N_SLOTS)-1:0]    write_addr,
    input  wire [SLOT_BITS-1:0]          write_data,
    input  wire                          write_enable,
    output reg                           write_done,
    output reg                           write_rejected,

    // Inspection: bitmap of slots that have been burned (1 = burned).
    output wire [N_SLOTS-1:0]            burned_mask
);

    // -------------------------------------------------------------------------
    // Storage. With 8 slots of 256 bits = 2048 bits, yosys typically infers
    // distributed RAM / registers rather than block RAM (BRAM minimum is 18
    // Kbit on ECP5, which would be 89% wasted). Either is fine.
    // -------------------------------------------------------------------------
    reg [SLOT_BITS-1:0] slot_data [0:N_SLOTS-1];
    reg [N_SLOTS-1:0]   slot_burned;

    assign read_data   = slot_data[read_addr];
    assign read_burned = slot_burned[read_addr];
    assign burned_mask = slot_burned;

    // -------------------------------------------------------------------------
    // Write logic. write_enable is sampled on the rising edge; the result
    // pulses one cycle later.
    //   - If the target slot is already burned, write is silently dropped
    //     and write_rejected pulses (write_done stays low).
    //   - Otherwise the slot is written, the burned flag is set, and
    //     write_done pulses.
    // -------------------------------------------------------------------------
    integer i;
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            slot_burned    <= {N_SLOTS{1'b0}};
            write_done     <= 1'b0;
            write_rejected <= 1'b0;
            for (i = 0; i < N_SLOTS; i = i + 1)
                slot_data[i] <= {SLOT_BITS{1'b0}};
        end else begin
            write_done     <= 1'b0;
            write_rejected <= 1'b0;
            if (write_enable) begin
                if (slot_burned[write_addr]) begin
                    write_rejected <= 1'b1;
                end else begin
                    slot_data[write_addr]   <= write_data;
                    slot_burned[write_addr] <= 1'b1;
                    write_done              <= 1'b1;
                end
            end
        end
    end

endmodule
