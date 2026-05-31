// =============================================================================
// otp_persistent.v — flash-backed twin of otp.v, persists across power cycles
// =============================================================================
//
// PRESERVES the otp.v interface bit-for-bit so it slots into ira_fsm,
// inverted_pair_verify, top_pipe_ira, and the rest of the existing pipeline
// without any caller-side changes. The only difference: slot data lives in
// external SPI flash (region 0x100000+) and survives power cycles, instead
// of dying every time the FPGA's internal registers clear at POR.
//
// Layout in flash (4 KB sector at 0x100000):
//   slot 0 → 0x100000..0x10001F  (32 bytes = 256 bits)
//   slot 1 → 0x100020..0x10003F
//   slot 2 → 0x100040..0x10005F
//   ...
//   slot 7 → 0x1000E0..0x1000FF
//   (0x100100..0x100FFF unused, available for future state)
//
// Byte ordering within a slot: byte 0 = bits [7:0], byte 31 = bits [255:248]
// — little-endian per-byte, MSB-first within each byte on the SPI wire.
//
// Behaviour:
//
//   POR → drive spi_master with READ at 0x100000 for 256 bytes → fill
//   slot_data registers as bytes arrive → set boot_loaded high → enter IDLE.
//   The whole boot read takes ~5 µs at 1.5 MHz SCK; the top-level POR counter
//   in top_pipe_meal.v is ~100 ms, so this completes well before reset_n
//   releases to the rest of the design.
//
//   write_enable + slot not yet burned → drive WRITE_ENABLE → PAGE_PROGRAM
//   (32 bytes at slot's address) → poll READ_STATUS until WIP bit clears →
//   commit slot_data internally and assert write_done. Slots are write-once
//   per sector lifetime; re-programming a burned slot requires a sector erase
//   (--wipe-slots in the build script) before re-provisioning. This matches
//   the otp.v "burned" semantic exactly.
//
//   write_enable + slot already burned → assert write_rejected, no flash op.
//
// A slot is considered "burned" if any byte read on boot is not 0xFF (the
// erased-flash value). This matches NOR-flash semantics: an unwritten slot
// reads 0xFFFF...FF; any program-pass leaves at least one bit at 0.
//
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module otp_persistent #(
    parameter integer SLOT_BITS    = 256,
    parameter integer N_SLOTS      = 8,
    parameter [23:0]  SLOTS_BASE   = 24'h100000   // 1 MB offset
) (
    input  wire                          clk,
    input  wire                          reset_n,

    // -------------------------------------------------------------------------
    // otp.v interface (preserved exactly)
    // -------------------------------------------------------------------------
    input  wire [$clog2(N_SLOTS)-1:0]    read_addr,
    output wire [SLOT_BITS-1:0]          read_data,
    output wire                          read_burned,

    input  wire [$clog2(N_SLOTS)-1:0]    write_addr,
    input  wire [SLOT_BITS-1:0]          write_data,
    input  wire                          write_enable,
    output reg                           write_done,
    output reg                           write_rejected,

    output wire [N_SLOTS-1:0]            burned_mask,
    output wire [N_SLOTS*SLOT_BITS-1:0]  all_slots_flat,

    // -------------------------------------------------------------------------
    // boot_loaded — high once the on-boot flash read has populated all slots.
    // The top-level can AND this with its POR counter to delay system reset_n
    // release until consumers see fully-loaded slot data.
    // -------------------------------------------------------------------------
    output reg                           boot_loaded,

    // -------------------------------------------------------------------------
    // spi_master interface (drives one shared instance)
    // -------------------------------------------------------------------------
    output reg                           spi_cmd_start,
    output reg  [2:0]                    spi_cmd_op,
    output reg  [23:0]                   spi_cmd_addr,
    output reg  [8:0]                    spi_cmd_byte_count,
    input  wire                          spi_cmd_busy,
    input  wire                          spi_cmd_done,
    output reg  [7:0]                    spi_wdata,
    input  wire                          spi_wdata_take,
    input  wire [7:0]                    spi_rdata,
    input  wire                          spi_rdata_valid
);

    // -------------------------------------------------------------------------
    // spi_master cmd_op constants (match spi_master.v)
    // -------------------------------------------------------------------------
    localparam [2:0]
        SPI_READ      = 3'd0,
        SPI_WRITE_EN  = 3'd1,
        SPI_PROGRAM   = 3'd2,
        SPI_ERASE     = 3'd3,
        SPI_STATUS    = 3'd4,
        SPI_JEDEC     = 3'd5;

    localparam integer BYTES_PER_SLOT = SLOT_BITS / 8;          // = 32
    localparam integer TOTAL_BOOT_BYTES = N_SLOTS * BYTES_PER_SLOT;  // = 256

    // -------------------------------------------------------------------------
    // Storage. Same shape as otp.v.
    // -------------------------------------------------------------------------
    reg [SLOT_BITS-1:0] slot_data [0:N_SLOTS-1];
    reg [N_SLOTS-1:0]   slot_burned;

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
    // FSM states
    // -------------------------------------------------------------------------
    localparam [3:0]
        ST_BOOT_KICK     = 4'd0,   // pulse READ at SLOTS_BASE for 256 bytes
        ST_BOOT_RX       = 4'd1,   // collect rdata bytes into slot_data
        ST_BOOT_COMMIT   = 4'd2,   // post-read: compute burned mask, raise boot_loaded
        ST_IDLE          = 4'd3,   // wait for write_enable
        ST_WE_KICK       = 4'd4,   // pulse WRITE_ENABLE
        ST_WE_WAIT       = 4'd5,   // wait spi_cmd_done
        ST_PROG_KICK     = 4'd6,   // pulse PAGE_PROGRAM
        ST_PROG_TX       = 4'd7,   // stream 32 bytes via wdata
        ST_PROG_WAIT     = 4'd8,   // wait spi_cmd_done after last byte
        ST_POLL_KICK     = 4'd9,   // pulse READ_STATUS
        ST_POLL_RX       = 4'd10,  // wait for status byte, check WIP
        ST_COMMIT        = 4'd11,  // update slot_data + slot_burned, pulse write_done
        ST_REJECT        = 4'd12;  // pulse write_rejected

    reg [3:0]   state;
    reg [7:0]   boot_byte_cnt;       // 0..255 during boot read
    reg [5:0]   prog_byte_cnt;       // 0..31 during program (just past 31 = "done streaming")
    reg [2:0]   pending_write_addr;
    reg [SLOT_BITS-1:0] pending_write_data;
    reg         slot_was_nonff;      // accumulates whether the current slot has any non-0xFF byte

    integer i;

    // -------------------------------------------------------------------------
    // Combinational extraction of the byte the program FSM needs to stream.
    // -------------------------------------------------------------------------
    wire [7:0] prog_byte_value =
        pending_write_data[ (prog_byte_cnt) * 8 +: 8 ];

    // -------------------------------------------------------------------------
    // FSM body
    // -------------------------------------------------------------------------
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state               <= ST_BOOT_KICK;
            spi_cmd_start       <= 1'b0;
            spi_cmd_op          <= 3'd0;
            spi_cmd_addr        <= 24'd0;
            spi_cmd_byte_count  <= 9'd0;
            spi_wdata           <= 8'h00;
            write_done          <= 1'b0;
            write_rejected      <= 1'b0;
            boot_loaded         <= 1'b0;
            boot_byte_cnt       <= 8'd0;
            prog_byte_cnt       <= 6'd0;
            pending_write_addr  <= 3'd0;
            pending_write_data  <= {SLOT_BITS{1'b0}};
            slot_was_nonff      <= 1'b0;
            slot_burned         <= {N_SLOTS{1'b0}};
            for (i = 0; i < N_SLOTS; i = i + 1) slot_data[i] <= {SLOT_BITS{1'b0}};
        end else begin
            // Default deassertions
            spi_cmd_start  <= 1'b0;
            write_done     <= 1'b0;
            write_rejected <= 1'b0;

            case (state)

                // -----------------------------------------------------------
                // ST_BOOT_KICK: launch READ of 256 bytes at SLOTS_BASE.
                // -----------------------------------------------------------
                ST_BOOT_KICK: begin
                    if (!spi_cmd_busy) begin
                        spi_cmd_op         <= SPI_READ;
                        spi_cmd_addr       <= SLOTS_BASE;
                        spi_cmd_byte_count <= TOTAL_BOOT_BYTES[8:0];
                        spi_cmd_start      <= 1'b1;
                        boot_byte_cnt      <= 8'd0;
                        slot_was_nonff     <= 1'b0;
                        state              <= ST_BOOT_RX;
                    end
                end

                // -----------------------------------------------------------
                // ST_BOOT_RX: capture each incoming byte into the right slot.
                //   slot_idx     = boot_byte_cnt[7:5]   (0..7)
                //   byte_in_slot = boot_byte_cnt[4:0]   (0..31)
                //
                // Erased-flash convention: a slot whose 32 bytes are all 0xFF
                // (= sector erased, never written) must be reported to
                // inverted_pair_verify.v as all-zero, because that classifier
                // was written against otp.v which uses 0 as the "unburned"
                // sentinel. Without this translation an erased chip reads as
                // some non-VIRGIN state and the ceremony silently no-ops on
                // provision_request.
                //
                // Detection: track slot_was_nonff across the 32 bytes; on the
                // last byte, if neither prior bytes nor the last byte are
                // non-0xFF, overwrite slot_data with zero. Programmed slots
                // (any non-0xFF byte) keep their actual bytes.
                // -----------------------------------------------------------
                ST_BOOT_RX: begin
                    if (spi_rdata_valid) begin
                        slot_data[boot_byte_cnt[7:5]][boot_byte_cnt[4:0]*8 +: 8] <= spi_rdata;

                        // Track whether the current slot has any non-0xFF byte
                        if (spi_rdata != 8'hFF) slot_was_nonff <= 1'b1;

                        // End of a slot? Decide burned/unburned + maybe zero it.
                        if (boot_byte_cnt[4:0] == 5'd31) begin
                            if (!slot_was_nonff && spi_rdata == 8'hFF) begin
                                // All 32 bytes were 0xFF → erased → unburned
                                // → translate to all-zero so inverted_pair_verify
                                // classifies as VIRGIN.
                                slot_data[boot_byte_cnt[7:5]]   <= {SLOT_BITS{1'b0}};
                                slot_burned[boot_byte_cnt[7:5]] <= 1'b0;
                            end else begin
                                // Slot has at least one non-0xFF byte → burned.
                                // slot_data was already populated byte-by-byte
                                // above (last byte will be written this cycle).
                                slot_burned[boot_byte_cnt[7:5]] <= 1'b1;
                            end
                            slot_was_nonff <= 1'b0;
                        end

                        boot_byte_cnt <= boot_byte_cnt + 8'd1;
                    end
                    if (spi_cmd_done) begin
                        state <= ST_BOOT_COMMIT;
                    end
                end

                // -----------------------------------------------------------
                // ST_BOOT_COMMIT: raise boot_loaded, settle in IDLE.
                // -----------------------------------------------------------
                ST_BOOT_COMMIT: begin
                    boot_loaded <= 1'b1;
                    state       <= ST_IDLE;
                end

                // -----------------------------------------------------------
                // ST_IDLE: wait for write_enable. Honor "already burned" by
                // rejecting fast. Otherwise launch the WE→PROG→POLL sequence.
                // -----------------------------------------------------------
                ST_IDLE: begin
                    if (write_enable) begin
                        if (slot_burned[write_addr]) begin
                            state <= ST_REJECT;
                        end else begin
                            pending_write_addr <= write_addr;
                            pending_write_data <= write_data;
                            state              <= ST_WE_KICK;
                        end
                    end
                end

                // -----------------------------------------------------------
                // ST_WE_KICK: pulse WRITE_ENABLE command.
                // -----------------------------------------------------------
                ST_WE_KICK: begin
                    if (!spi_cmd_busy) begin
                        spi_cmd_op         <= SPI_WRITE_EN;
                        spi_cmd_byte_count <= 9'd0;
                        spi_cmd_start      <= 1'b1;
                        state              <= ST_WE_WAIT;
                    end
                end

                ST_WE_WAIT: begin
                    if (spi_cmd_done) state <= ST_PROG_KICK;
                end

                // -----------------------------------------------------------
                // ST_PROG_KICK: launch PAGE_PROGRAM at slot's address.
                // -----------------------------------------------------------
                ST_PROG_KICK: begin
                    if (!spi_cmd_busy) begin
                        spi_cmd_op         <= SPI_PROGRAM;
                        spi_cmd_addr       <= SLOTS_BASE +
                                              (pending_write_addr * BYTES_PER_SLOT[23:0]);
                        spi_cmd_byte_count <= BYTES_PER_SLOT[8:0];
                        spi_cmd_start      <= 1'b1;
                        prog_byte_cnt      <= 6'd0;
                        spi_wdata          <= pending_write_data[7:0];   // pre-load first byte
                        state              <= ST_PROG_TX;
                    end
                end

                // -----------------------------------------------------------
                // ST_PROG_TX: when the spi_master pulls wdata_take, advance to
                // the next byte. After the 32nd byte is consumed, wait for
                // spi_cmd_done in ST_PROG_WAIT.
                // -----------------------------------------------------------
                ST_PROG_TX: begin
                    if (spi_wdata_take) begin
                        if (prog_byte_cnt == 6'd31) begin
                            // Last byte was just taken; wait for done.
                            state <= ST_PROG_WAIT;
                        end else begin
                            prog_byte_cnt <= prog_byte_cnt + 6'd1;
                            spi_wdata <=
                                pending_write_data[ (prog_byte_cnt + 6'd1) * 8 +: 8 ];
                        end
                    end
                end

                ST_PROG_WAIT: begin
                    if (spi_cmd_done) state <= ST_POLL_KICK;
                end

                // -----------------------------------------------------------
                // ST_POLL_KICK / ST_POLL_RX: poll READ_STATUS_REGISTER until
                // the WIP bit (SR1[0]) clears. Page program takes <1 ms on
                // GD25Q32; at 1.5 MHz SCK each poll is ~16 µs.
                // -----------------------------------------------------------
                ST_POLL_KICK: begin
                    if (!spi_cmd_busy) begin
                        spi_cmd_op         <= SPI_STATUS;
                        spi_cmd_byte_count <= 9'd1;
                        spi_cmd_start      <= 1'b1;
                        state              <= ST_POLL_RX;
                    end
                end

                ST_POLL_RX: begin
                    if (spi_rdata_valid) begin
                        if (spi_rdata[0] == 1'b0) begin
                            // WIP clear → program complete
                            state <= ST_COMMIT;
                        end else begin
                            // Still busy → loop back, issue another STATUS read
                            state <= ST_POLL_KICK;
                        end
                    end
                end

                // -----------------------------------------------------------
                // ST_COMMIT: update internal slot_data + slot_burned to
                // match what's now in flash, pulse write_done.
                // -----------------------------------------------------------
                ST_COMMIT: begin
                    slot_data[pending_write_addr]   <= pending_write_data;
                    slot_burned[pending_write_addr] <= 1'b1;
                    write_done                      <= 1'b1;
                    state                           <= ST_IDLE;
                end

                ST_REJECT: begin
                    write_rejected <= 1'b1;
                    state          <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
