// =============================================================================
// File: hdl/particle/boards/panog2/panog2_uart.v
// Description: A serial console test for the Pano Logic G2 (rev C): a UART
//              on the DVI connector's DDC pins that echoes what it receives,
//              and sends a banner after configuration and each time the Pano
//              button is pressed. The LED shows green for a byte received and
//              blue for one sent.
//
// 8 data bits, no parity, 1 stop bit, at BAUD from a CLK_HZ clock (make
// pano-uart passes PANO_CLOCK_HZ and PANO_BAUD as XST generics). The DDC
// lines idle at 5 V on the board side, so the host's adapter must take
// 5 V logic.
//
// Plain Verilog-2001, as ISE's XST reads no SystemVerilog.
// =============================================================================

module panog2_uart #(
    parameter CLK_HZ = 25000000,
    parameter BAUD   = 1000000
) (
    input  wire clk,        // Y13
    input  wire uart_rx,    // C17: DVI pin 7 (DDC SDA), host -> Pano
    output wire uart_tx,    // C14: DVI pin 6 (DDC SCL), Pano -> host
    input  wire button,     // H12: the Pano button
    output wire led_red,    // E12
    output wire led_green,  // F13
    output wire led_blue    // H13
);

    localparam integer DIV = (CLK_HZ + BAUD / 2) / BAUD;  // clocks a bit

    // -------------------------------------------------------------------------
    // Receiver: the line through two flip-flops; a start bit is checked at
    // its middle, then each bit is sampled one bit time later
    // -------------------------------------------------------------------------
    reg        rx_s1 = 1'b1, rx_s2 = 1'b1;
    reg        rx_busy = 1'b0;
    reg [15:0] rx_count = 16'd0;
    reg [3:0]  rx_bit = 4'd0;      // 0: start bit, 1-8: data, 9: stop
    reg [7:0]  rx_shift = 8'd0;
    reg [7:0]  rx_data = 8'd0;
    reg        rx_valid = 1'b0;    // one clock when rx_data is new

    always @(posedge clk) begin
        rx_s1 <= uart_rx;
        rx_s2 <= rx_s1;
        rx_valid <= 1'b0;
        if (!rx_busy) begin
            if (!rx_s2) begin
                rx_busy  <= 1'b1;
                rx_count <= DIV / 2;
                rx_bit   <= 4'd0;
            end
        end else if (rx_count != 16'd0) begin
            rx_count <= rx_count - 16'd1;
        end else begin
            rx_count <= DIV - 1;
            if (rx_bit == 4'd0) begin
                if (rx_s2)
                    rx_busy <= 1'b0;            // a glitch, not a start bit
                else
                    rx_bit <= 4'd1;
            end else if (rx_bit != 4'd9) begin
                rx_shift <= {rx_s2, rx_shift[7:1]};
                rx_bit   <= rx_bit + 4'd1;
            end else begin
                rx_busy <= 1'b0;
                if (rx_s2) begin                // a good stop bit
                    rx_data  <= rx_shift;
                    rx_valid <= 1'b1;
                end
            end
        end
    end

    // -------------------------------------------------------------------------
    // Transmitter: tx_start with tx_byte sends one character
    // -------------------------------------------------------------------------
    reg        tx_busy = 1'b0;
    reg [15:0] tx_count = 16'd0;
    reg [3:0]  tx_bit = 4'd0;
    reg [9:0]  tx_shift = 10'h3FF;  // stop, data, start (sent from bit 0)
    reg        tx_start = 1'b0;
    reg [7:0]  tx_byte = 8'd0;

    assign uart_tx = tx_shift[0];

    always @(posedge clk) begin
        if (!tx_busy) begin
            if (tx_start) begin
                tx_shift <= {1'b1, tx_byte, 1'b0};
                tx_busy  <= 1'b1;
                tx_count <= DIV - 1;
                tx_bit   <= 4'd0;
            end
        end else if (tx_count != 16'd0) begin
            tx_count <= tx_count - 16'd1;
        end else begin
            tx_count <= DIV - 1;
            tx_shift <= {1'b1, tx_shift[9:1]};
            if (tx_bit == 4'd9)
                tx_busy <= 1'b0;
            else
                tx_bit <= tx_bit + 4'd1;
        end
    end

    // -------------------------------------------------------------------------
    // The banner
    // -------------------------------------------------------------------------
    // "\r\nPano G2: UART echo test\r\n" (Verilog-2001 strings have no \r)
    localparam [4:0] BANNER_LAST = 5'd26;
    function [7:0] banner_char;
        input [4:0] i;
        case (i)
            5'd0:  banner_char = 8'h0D;
            5'd1:  banner_char = 8'h0A;
            5'd2:  banner_char = "P";
            5'd3:  banner_char = "a";
            5'd4:  banner_char = "n";
            5'd5:  banner_char = "o";
            5'd6:  banner_char = " ";
            5'd7:  banner_char = "G";
            5'd8:  banner_char = "2";
            5'd9:  banner_char = ":";
            5'd10: banner_char = " ";
            5'd11: banner_char = "U";
            5'd12: banner_char = "A";
            5'd13: banner_char = "R";
            5'd14: banner_char = "T";
            5'd15: banner_char = " ";
            5'd16: banner_char = "e";
            5'd17: banner_char = "c";
            5'd18: banner_char = "h";
            5'd19: banner_char = "o";
            5'd20: banner_char = " ";
            5'd21: banner_char = "t";
            5'd22: banner_char = "e";
            5'd23: banner_char = "s";
            5'd24: banner_char = "t";
            5'd25: banner_char = 8'h0D;
            default: banner_char = 8'h0A;
        endcase
    endfunction

    // -------------------------------------------------------------------------
    // The button: its level about 10 ms after configuration is taken as "not
    // pressed" (its polarity isn't known yet); a banner each time it changes
    // to the other level and stays there for 10 ms
    // -------------------------------------------------------------------------
    localparam integer DEBOUNCE = CLK_HZ / 100;
    reg        btn_s1 = 1'b0, btn_s2 = 1'b0;
    reg        btn_idle = 1'b0;     // the level read as "not pressed"
    reg        btn_known = 1'b0;
    reg        btn_state = 1'b0;    // debounced: 1 pressed
    reg [23:0] btn_count = 24'd0;
    reg        banner_req = 1'b1;   // one banner after configuration
    reg        banner_on = 1'b0;    // the banner is going out
    reg [4:0]  banner_i = 5'd0;
    wire       banner_go = banner_req && !banner_on;
    reg        echo_pending = 1'b0;
    reg [7:0]  echo_byte = 8'd0;

    always @(posedge clk) begin
        btn_s1 <= button;
        btn_s2 <= btn_s1;
        if (!btn_known) begin
            if (btn_count == DEBOUNCE) begin
                btn_known <= 1'b1;
                btn_idle  <= btn_s2;
                btn_count <= 24'd0;
            end else begin
                btn_count <= btn_count + 24'd1;
            end
        end else if ((btn_s2 != btn_idle) != btn_state) begin
            if (btn_count == DEBOUNCE) begin
                btn_state <= ~btn_state;
                btn_count <= 24'd0;
                if (!btn_state)
                    banner_req <= 1'b1;         // pressed
            end else begin
                btn_count <= btn_count + 24'd1;
            end
        end else begin
            btn_count <= 24'd0;
        end
        if (banner_go)
            banner_req <= 1'b0;
    end

    // -------------------------------------------------------------------------
    // What to send: the banner while one is going out (received characters
    // are dropped meanwhile), otherwise each character received
    // -------------------------------------------------------------------------

    always @(posedge clk) begin
        tx_start <= 1'b0;
        if (rx_valid && !banner_on) begin
            echo_pending <= 1'b1;
            echo_byte    <= rx_data;
        end
        if (banner_go) begin
            banner_on <= 1'b1;
            banner_i  <= 5'd0;
        end else if (!tx_busy && !tx_start) begin
            if (banner_on) begin
                tx_byte  <= banner_char(banner_i);
                tx_start <= 1'b1;
                if (banner_i == BANNER_LAST)
                    banner_on <= 1'b0;
                else
                    banner_i <= banner_i + 5'd1;
            end else if (echo_pending) begin
                tx_byte      <= echo_byte;
                tx_start     <= 1'b1;
                echo_pending <= 1'b0;
            end
        end
    end

    // -------------------------------------------------------------------------
    // The LED: each byte received or sent lights it for about 50 ms
    // -------------------------------------------------------------------------
    localparam integer FLASH = CLK_HZ / 20;
    reg [23:0] green_count = 24'd0, blue_count = 24'd0;
    always @(posedge clk) begin
        if (rx_valid)
            green_count <= FLASH;
        else if (green_count != 24'd0)
            green_count <= green_count - 24'd1;
        if (tx_start)
            blue_count <= FLASH;
        else if (blue_count != 24'd0)
            blue_count <= blue_count - 24'd1;
    end
    assign led_green = (green_count != 24'd0);
    assign led_blue  = (blue_count != 24'd0) && (green_count == 24'd0);
    assign led_red   = 1'b0;

endmodule
