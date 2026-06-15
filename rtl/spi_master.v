// =============================================================================
// spi_master.v — Single-target SPI flash controller for the GD25Q32 on the
// Colorlight 5A-75B v8.0 dev board.
//
// Purpose: give the running bitstream a way to read/write the same external
// SPI flash chip that the ECP5 configures from at power-on, so that IRA slots
// burned by ira_fsm.v survive a power cycle. This replaces the FPGA-emulated
// otp.v with a flash-backed equivalent (otp_persistent.v wraps this).
//
// Targets the industry-standard SPI flash command set used by both Winbond
// W25Q and GigaDevice GD25Q families:
//   0x03 READ            — read N bytes starting at 24-bit address
//   0x06 WRITE_ENABLE    — latch required before any program/erase
//   0x02 PAGE_PROGRAM    — program up to 256 bytes within a 256-byte page
//   0x20 SECTOR_ERASE    — erase the 4 KB sector containing the 24-bit address
//   0x05 READ_STATUS_REG — read SR1 (WIP bit = bit 0, polled during P/E)
//   0x9F READ_JEDEC_ID   — return manufacturer + memory type + capacity
//
// SPI mode 0: CPOL=0 (SCK idles low), CPHA=0 (MISO sampled on rising edge of
// SCK, MOSI updated on falling edge). MSB-first within each byte.
//
// SCK rate = clk / 2 (one full SCK period per 2 clk cycles). At the typical
// enclave_clk ≈ 3 MHz this gives ~1.5 MHz SCK — well under the GD25Q32's
// 33 MHz standard-read ceiling.
//
// SCK is driven thru the USRMCLK ECP5 primitive, which gives user logic
// access to the dedicated CCLK config pin after the bitstream is loaded.
// CS, MOSI, MISO are on regular GPIO and located in the .lpf constraints.
//
// =============================================================================

`timescale 1ns / 1ps
`default_nettype none

module spi_master (
    input  wire        clk,
    input  wire        reset_n,

    // -------------------------------------------------------------------------
    // Command interface
    // -------------------------------------------------------------------------
    input  wire        cmd_start,         // 1-cycle pulse to begin a transaction
    input  wire [2:0]  cmd_op,            // 0=READ, 1=WRITE_ENABLE, 2=PAGE_PROGRAM,
                                          // 3=SECTOR_ERASE, 4=READ_STATUS, 5=JEDEC_ID
    input  wire [23:0] cmd_addr,          // address for ops that consume one
    input  wire [8:0]  cmd_byte_count,    // 0..256 bytes of data phase
    output reg         cmd_busy,
    output reg         cmd_done,          // 1-cycle pulse at end of transaction

    // -------------------------------------------------------------------------
    // Streaming write data (consumed during PROGRAM data phase)
    // -------------------------------------------------------------------------
    input  wire [7:0]  wdata,
    output reg         wdata_take,        // 1-cycle pulse when master consumes wdata

    // -------------------------------------------------------------------------
    // Streaming read data (produced during READ / READ_STATUS / JEDEC data phase)
    // -------------------------------------------------------------------------
    output reg  [7:0]  rdata,
    output reg         rdata_valid,       // 1-cycle pulse per byte received

    // -------------------------------------------------------------------------
    // Physical SPI bus to GD25Q32
    // -------------------------------------------------------------------------
    output reg         flash_cs_n,        // active-low chip select
    output wire        flash_sck,         // routed thru USRMCLK primitive
    output reg         flash_mosi,
    input  wire        flash_miso
);

    // -------------------------------------------------------------------------
    // Opcodes
    // -------------------------------------------------------------------------
    localparam [7:0] OP_READ      = 8'h03;
    localparam [7:0] OP_WRITE_EN  = 8'h06;
    localparam [7:0] OP_PROGRAM   = 8'h02;
    localparam [7:0] OP_ERASE     = 8'h20;
    localparam [7:0] OP_STATUS    = 8'h05;
    localparam [7:0] OP_JEDEC     = 8'h9F;

    // cmd_op enum
    localparam [2:0]
        CMD_READ      = 3'd0,
        CMD_WRITE_EN  = 3'd1,
        CMD_PROGRAM   = 3'd2,
        CMD_ERASE     = 3'd3,
        CMD_STATUS    = 3'd4,
        CMD_JEDEC     = 3'd5;

    // -------------------------------------------------------------------------
    // FSM states
    // -------------------------------------------------------------------------
    localparam [3:0]
        ST_IDLE     = 4'd0,
        ST_CS_FALL  = 4'd1,   // hold CS low for 1 cycle before clocking
        ST_CMD      = 4'd2,   // shift out 8-bit opcode
        ST_ADDR     = 4'd3,   // shift out 24-bit address (READ/PROGRAM/ERASE)
        ST_TX_DATA  = 4'd4,   // shift out wdata bytes (PROGRAM)
        ST_RX_DATA  = 4'd5,   // shift in rdata bytes (READ/STATUS/JEDEC)
        ST_CS_RISE  = 4'd6,   // deassert CS for 1 cycle before next op
        ST_DONE     = 4'd7;   // pulse cmd_done, return to IDLE

    reg [3:0]  state;
    reg [7:0]  shift_out;     // MOSI shift register, MSB first
    reg [7:0]  shift_in;      // MISO shift register, MSB first
    reg [2:0]  bit_idx;       // 0..7 within current byte (counts down: 7..0)
    reg [8:0]  byte_idx;      // counter for ADDR (3 bytes) and DATA (cmd_byte_count)
    reg [8:0]  total_bytes;   // latched cmd_byte_count
    reg [2:0]  latched_op;
    reg [23:0] latched_addr;

    // -------------------------------------------------------------------------
    // SCK generation: two-cycle period.
    //   sck_phase = 0  → SCK low half  (MOSI update happens here)
    //   sck_phase = 1  → SCK high half (MISO sample happens here)
    // SCK only toggles while sck_active is asserted (during CMD/ADDR/DATA states).
    // -------------------------------------------------------------------------
    reg sck_phase;
    reg sck_active;
    // Register the SCK signal so USRMCLKI is driven from a registered output.
    // The ECP5 USRMCLK primitive doesn't reliably release the dedicated CCLK
    // pad to user logic when USRMCLKI is combinational (LUT output): the pad
    // can stay stuck at the configuration-mode level. Driving USRMCLKI from
    // a flip-flop output forces the proper post-config release sequence.
    reg sck_reg;
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) sck_reg <= 1'b0;
        else          sck_reg <= sck_active & sck_phase;
    end

    // -------------------------------------------------------------------------
    // USRMCLK: ECP5 primitive that lets user logic drive the dedicated CCLK pin
    // after configuration completes. USRMCLKTS = 0 means "drive" (1 = tristate).
    // syn_noprune ensures the primitive survives any optimization pass.
    // -------------------------------------------------------------------------
    (* keep *)
    USRMCLK usrmclk_inst (
        .USRMCLKI  (sck_reg),
        .USRMCLKTS (1'b0)
    ) /* synthesis syn_noprune=1 */;
    assign flash_sck = sck_reg;   // also drive output port for visibility

    // -------------------------------------------------------------------------
    // FSM
    // -------------------------------------------------------------------------
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            state         <= ST_IDLE;
            cmd_busy      <= 1'b0;
            cmd_done      <= 1'b0;
            wdata_take    <= 1'b0;
            rdata         <= 8'h00;
            rdata_valid   <= 1'b0;
            flash_cs_n    <= 1'b1;
            flash_mosi    <= 1'b0;
            shift_out     <= 8'h00;
            shift_in      <= 8'h00;
            bit_idx       <= 3'd7;
            byte_idx      <= 9'd0;
            total_bytes   <= 9'd0;
            latched_op    <= 3'd0;
            latched_addr  <= 24'd0;
            sck_phase     <= 1'b0;
            sck_active    <= 1'b0;
        end else begin
            // Default deassertions (one-cycle strobes)
            cmd_done    <= 1'b0;
            wdata_take  <= 1'b0;
            rdata_valid <= 1'b0;

            case (state)
                // -----------------------------------------------------------
                // ST_IDLE: CS high, SCK off, wait for cmd_start.
                // -----------------------------------------------------------
                ST_IDLE: begin
                    flash_cs_n <= 1'b1;
                    sck_active <= 1'b0;
                    sck_phase  <= 1'b0;
                    cmd_busy   <= 1'b0;
                    if (cmd_start) begin
                        latched_op   <= cmd_op;
                        latched_addr <= cmd_addr;
                        total_bytes  <= cmd_byte_count;
                        cmd_busy     <= 1'b1;

                        // Select the opcode byte into shift_out
                        case (cmd_op)
                            CMD_READ:     shift_out <= OP_READ;
                            CMD_WRITE_EN: shift_out <= OP_WRITE_EN;
                            CMD_PROGRAM:  shift_out <= OP_PROGRAM;
                            CMD_ERASE:    shift_out <= OP_ERASE;
                            CMD_STATUS:   shift_out <= OP_STATUS;
                            CMD_JEDEC:    shift_out <= OP_JEDEC;
                            default:      shift_out <= 8'h00;
                        endcase
                        bit_idx <= 3'd7;
                        state   <= ST_CS_FALL;
                    end
                end

                // -----------------------------------------------------------
                // ST_CS_FALL: assert CS low one cycle before clocking starts.
                // Gives the flash chip its tCSS setup time (typ. 5 ns,
                // way under our 333 ns clk period).
                // -----------------------------------------------------------
                ST_CS_FALL: begin
                    flash_cs_n <= 1'b0;
                    flash_mosi <= shift_out[7];   // pre-load MOSI before first SCK rising edge
                    sck_active <= 1'b1;
                    sck_phase  <= 1'b0;           // start at SCK-low half
                    state      <= ST_CMD;
                end

                // -----------------------------------------------------------
                // ST_CMD: shift the 8-bit opcode out MSB-first.
                //   sck_phase=0 (SCK low):  update flash_mosi to next bit
                //   sck_phase=1 (SCK high): sample flash_miso into shift_in
                // -----------------------------------------------------------
                ST_CMD: begin
                    sck_phase <= ~sck_phase;
                    if (sck_phase == 1'b1) begin
                        // Just transitioned high→low. Sample MISO already
                        // happened at the previous rising edge.
                        shift_in <= {shift_in[6:0], flash_miso};
                    end else begin
                        // sck_phase was 0, will go to 1. Update MOSI for the
                        // bit that will be clocked in on the rising edge we're
                        // about to drive.
                        if (bit_idx == 3'd0) begin
                            // Just shifted the last bit (LSB) of the opcode.
                            // Decide next phase based on op.
                            case (latched_op)
                                CMD_WRITE_EN: state <= ST_CS_RISE;
                                CMD_STATUS,
                                CMD_JEDEC:    begin
                                    state    <= ST_RX_DATA;
                                    byte_idx <= 9'd0;
                                    bit_idx  <= 3'd7;
                                end
                                default: begin   // READ / PROGRAM / ERASE need address
                                    state     <= ST_ADDR;
                                    byte_idx  <= 9'd0;
                                    bit_idx   <= 3'd7;
                                    shift_out <= latched_addr[23:16];
                                    flash_mosi <= latched_addr[23];
                                end
                            endcase
                        end else begin
                            shift_out  <= {shift_out[6:0], 1'b0};
                            flash_mosi <= shift_out[6];
                            bit_idx    <= bit_idx - 3'd1;
                        end
                    end
                end

                // -----------------------------------------------------------
                // ST_ADDR: shift 24-bit address MSB-first across 3 bytes.
                // -----------------------------------------------------------
                ST_ADDR: begin
                    sck_phase <= ~sck_phase;
                    if (sck_phase == 1'b1) begin
                        shift_in <= {shift_in[6:0], flash_miso};
                    end else begin
                        if (bit_idx == 3'd0) begin
                            // End of a byte
                            if (byte_idx == 9'd2) begin
                                // End of address (byte 0, 1, 2 done)
                                case (latched_op)
                                    CMD_ERASE: state <= ST_CS_RISE;
                                    CMD_READ: begin
                                        state    <= ST_RX_DATA;
                                        byte_idx <= 9'd0;
                                        bit_idx  <= 3'd7;
                                    end
                                    CMD_PROGRAM: begin
                                        state      <= ST_TX_DATA;
                                        byte_idx   <= 9'd0;
                                        bit_idx    <= 3'd7;
                                        wdata_take <= 1'b1;   // request first byte
                                    end
                                    default: state <= ST_CS_RISE;
                                endcase
                            end else begin
                                // Next address byte
                                if (byte_idx == 9'd0) begin
                                    shift_out  <= latched_addr[15:8];
                                    flash_mosi <= latched_addr[15];
                                end else begin
                                    shift_out  <= latched_addr[7:0];
                                    flash_mosi <= latched_addr[7];
                                end
                                bit_idx  <= 3'd7;
                                byte_idx <= byte_idx + 9'd1;
                            end
                        end else begin
                            shift_out  <= {shift_out[6:0], 1'b0};
                            flash_mosi <= shift_out[6];
                            bit_idx    <= bit_idx - 3'd1;
                        end
                    end
                end

                // -----------------------------------------------------------
                // ST_TX_DATA: shift wdata out across cmd_byte_count bytes.
                // wdata_take pulsed at the end of address; each subsequent
                // byte's wdata_take fires one cycle before its first SCK edge.
                // -----------------------------------------------------------
                ST_TX_DATA: begin
                    sck_phase <= ~sck_phase;
                    if (sck_phase == 1'b1) begin
                        shift_in <= {shift_in[6:0], flash_miso};
                    end else begin
                        if (bit_idx == 3'd7 && byte_idx == 9'd0) begin
                            // Very first SCK rising edge of data — wdata is
                            // valid this cycle (we pulsed wdata_take last cycle).
                            shift_out  <= {wdata[6:0], 1'b0};
                            flash_mosi <= wdata[7];
                            bit_idx    <= 3'd6;
                            byte_idx   <= 9'd1;
                        end else if (bit_idx == 3'd0) begin
                            // End of a byte
                            if (byte_idx == total_bytes) begin
                                state <= ST_CS_RISE;
                            end else begin
                                // Need next byte
                                shift_out  <= {wdata[6:0], 1'b0};
                                flash_mosi <= wdata[7];
                                bit_idx    <= 3'd7;
                                byte_idx   <= byte_idx + 9'd1;
                                wdata_take <= 1'b1;
                            end
                        end else begin
                            shift_out  <= {shift_out[6:0], 1'b0};
                            flash_mosi <= shift_out[6];
                            bit_idx    <= bit_idx - 3'd1;
                        end
                    end
                end

                // -----------------------------------------------------------
                // ST_RX_DATA: shift in cmd_byte_count bytes from MISO.
                // -----------------------------------------------------------
                ST_RX_DATA: begin
                    sck_phase <= ~sck_phase;
                    if (sck_phase == 1'b1) begin
                        // Sample MISO into LSB
                        shift_in <= {shift_in[6:0], flash_miso};
                    end else begin
                        // sck just went 1→0. If bit_idx == 0 we just clocked
                        // in the last bit of a byte — emit rdata.
                        if (bit_idx == 3'd0) begin
                            rdata       <= {shift_in[6:0], flash_miso};
                            rdata_valid <= 1'b1;
                            if (byte_idx == (total_bytes - 9'd1)) begin
                                state <= ST_CS_RISE;
                            end else begin
                                byte_idx <= byte_idx + 9'd1;
                                bit_idx  <= 3'd7;
                            end
                        end else begin
                            bit_idx <= bit_idx - 3'd1;
                        end
                    end
                end

                // -----------------------------------------------------------
                // ST_CS_RISE: stop clocking, release CS.
                // -----------------------------------------------------------
                ST_CS_RISE: begin
                    sck_active <= 1'b0;
                    sck_phase  <= 1'b0;
                    flash_cs_n <= 1'b1;
                    flash_mosi <= 1'b0;
                    state      <= ST_DONE;
                end

                // -----------------------------------------------------------
                // ST_DONE: pulse cmd_done, return to IDLE.
                // -----------------------------------------------------------
                ST_DONE: begin
                    cmd_done <= 1'b1;
                    cmd_busy <= 1'b0;
                    state    <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
