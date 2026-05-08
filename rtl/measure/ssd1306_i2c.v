// I2C bit-bang driver (write-only, no ACK check)
// Clocked at 25 MHz, generates ~390 kHz SCL (divide by 64)
//
// Interface: load a byte into `data`, pulse `start`. Driver shifts it out
// MSB-first with proper I2C framing. `busy` high while transmitting.
// `send_start`/`send_stop` control I2C START/STOP conditions.
//
// Between bytes (no STOP), SCL stays low and `busy` drops so the next
// byte can be loaded. This avoids spurious STOP/START glitches.

module ssd1306_i2c #(
    parameter CLK_DIV = 64   // 25 MHz / 64 = ~390 kHz SCL
)(
    input  wire       clk,
    input  wire       rst,

    // command interface
    input  wire [7:0] data,
    input  wire       start,       // pulse to begin sending `data`
    input  wire       send_start,  // issue I2C START before byte
    input  wire       send_stop,   // issue I2C STOP after byte

    output reg        busy,
    output reg        scl,
    output reg        sda
);

    localparam HALF = CLK_DIV / 2;

    // States
    localparam [2:0]
        S_IDLE  = 3'd0,  // bus released (SCL=1, SDA=1)
        S_START = 3'd1,  // START hold (SDA low, SCL high → SCL low)
        S_BIT   = 3'd2,  // clock out data bit
        S_ACK   = 3'd3,  // clock ACK bit (ignored)
        S_STOP  = 3'd4,  // STOP condition
        S_READY = 3'd5;  // between bytes: SCL low, waiting for next byte

    reg [2:0]  state = S_IDLE;
    reg [$clog2(CLK_DIV)-1:0] clk_cnt = 0;
    reg [2:0]  bit_idx = 0;
    reg [7:0]  shift = 0;
    reg        do_stop = 0;

    always @(posedge clk) begin
        if (rst) begin
            state   <= S_IDLE;
            scl     <= 1;
            sda     <= 1;
            busy    <= 0;
            clk_cnt <= 0;
        end else begin
            case (state)

                // Bus idle: both lines high
                S_IDLE: begin
                    scl  <= 1;
                    sda  <= 1;
                    busy <= 0;
                    if (start) begin
                        shift   <= data;
                        do_stop <= send_stop;
                        busy    <= 1;
                        clk_cnt <= 0;
                        // Must have send_start for first byte
                        sda   <= 0;        // SDA falls while SCL high = START
                        state <= S_START;
                    end
                end

                // Hold START condition, then pull SCL low
                S_START: begin
                    clk_cnt <= clk_cnt + 1;
                    if (clk_cnt == HALF - 1) begin
                        scl     <= 0;
                        clk_cnt <= 0;
                        bit_idx <= 7;
                        state   <= S_BIT;
                    end
                end

                // Clock out one bit: set SDA while SCL low, raise SCL, lower SCL
                S_BIT: begin
                    clk_cnt <= clk_cnt + 1;
                    if (clk_cnt == 0) begin
                        sda <= shift[7];       // MSB first
                    end else if (clk_cnt == HALF) begin
                        scl <= 1;              // SCL rises (data sampled)
                    end else if (clk_cnt == CLK_DIV - 1) begin
                        scl     <= 0;
                        shift   <= {shift[6:0], 1'b0};
                        clk_cnt <= 0;
                        if (bit_idx == 0)
                            state <= S_ACK;
                        else
                            bit_idx <= bit_idx - 1;
                    end
                end

                // ACK bit: release SDA, clock SCL, ignore response
                S_ACK: begin
                    clk_cnt <= clk_cnt + 1;
                    if (clk_cnt == 0) begin
                        sda <= 0;              // drive ACK low (prevent bus contention with push-pull buffer)
                    end else if (clk_cnt == HALF) begin
                        scl <= 1;
                    end else if (clk_cnt == CLK_DIV - 1) begin
                        scl     <= 0;          // SCL low — always
                        clk_cnt <= 0;
                        if (do_stop) begin
                            sda   <= 0;        // prep for STOP (SDA low before SCL rises)
                            state <= S_STOP;
                        end else begin
                            // Stay on bus, SCL low, wait for next byte
                            state <= S_READY;
                        end
                    end
                end

                // Between bytes: SCL stays low, SDA released, not busy
                S_READY: begin
                    busy <= 0;
                    // SCL stays low (no assignment)
                    if (start) begin
                        shift   <= data;
                        do_stop <= send_stop;
                        busy    <= 1;
                        clk_cnt <= 0;
                        bit_idx <= 7;
                        state   <= S_BIT;
                    end
                end

                // STOP: SDA rises while SCL high
                S_STOP: begin
                    clk_cnt <= clk_cnt + 1;
                    if (clk_cnt == HALF) begin
                        scl <= 1;
                    end else if (clk_cnt == CLK_DIV - 1) begin
                        sda     <= 1;          // SDA rises = STOP
                        clk_cnt <= 0;
                        state   <= S_IDLE;
                    end
                end

            endcase
        end
    end

endmodule
