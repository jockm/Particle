// =============================================================================
// File: hdl/particle/boards/panog2/panog2_blink.v
// Description: First light on the Pano Logic G2 (rev C, XC6SLX100): the three
//              LEDs light one at a time, in turn. Proves the build flow in the
//              ISE VM (make pano-blink, make pano-prog), the clock pin and the
//              LED pins.
//
// The clock on Y13 comes from the Ethernet PHY: 25 MHz while the PHY is in
// reset, 125 MHz once it is out. This design leaves the PHY alone, so the
// step rate shows which clock arrives: a step every 2^24 cycles is about
// 0.67 s at 25 MHz and 0.13 s at 125 MHz.
//
// Plain Verilog-2001, as ISE's XST reads no SystemVerilog.
// =============================================================================

module panog2_blink (
    input  wire clk,        // Y13
    output wire led_red,    // E12 (red is a guess: no source names it)
    output wire led_green,  // F13
    output wire led_blue    // H13
);

    reg [23:0] count = 24'd0;
    reg [1:0]  step  = 2'd0;    // 0, 1, 2: which LED is lit

    always @(posedge clk) begin
        count <= count + 24'd1;
        if (count == 24'hFFFFFF)
            step <= (step == 2'd2) ? 2'd0 : step + 2'd1;
    end

    assign led_red   = (step == 2'd0);
    assign led_green = (step == 2'd1);
    assign led_blue  = (step == 2'd2);

endmodule
