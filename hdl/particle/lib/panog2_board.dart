// =============================================================================
// File: hdl/particle/lib/panog2_board.dart
// Architecture: Particle 32-bit RISC on the Pano Logic G2 (Spartan-6)
// Description: Verilog-2001 board wrapper for the Pano G2 (rev C): the
//              board's pins (boards/panog2/panog2_uart.ucf) to
//              ParticleSingleCoreTop or Parcore's top (ParcoreUlx3sTop), the
//              Pano button as reset, and the LED.
// =============================================================================
//
// Written as text, like lib/ulx3s_board.dart, and as plain Verilog-2001 so
// that it goes to ISE as it is (only ROHD's SystemVerilog goes through sv2v).
//
// Pins:
//   clk      Y13  25 MHz (the Ethernet PHY's clock output, with the PHY held
//                 in reset). At 25 MHz the design runs on it directly;
//                 otherwise a Spartan-6 PLL_BASE (Spartan6PllSettings) makes
//                 the clock, through a BUFG, and the core is held in reset
//                 until the PLL locks
//   uart_rx  C17  the console UART's receive (DVI DDC SDA): FIFO channel 0
//   uart_tx  C14  the console UART's transmit (DVI DDC SCL)
//   button   H12  the Pano button: reset. Its polarity isn't known, so its
//                 level about 10 ms after configuration is taken as "not
//                 pressed", and the other level, held for 10 ms, as pressed
//   led_red  E12  the core is held in reset (by the button, or in those first
//                 10 ms)
//   led_green F13 blinks (about 0.7 s on, 0.7 s off) while the core runs
//   led_blue H13  console traffic: lit for about 50 ms after either line
//                 is low (a character's start bit)
// With [coreLeds] (Parcore) the light shows the core's LEDs instead: red its
// LED 7 (the conductor's fault flasher), green LED 0 (booting, then the
// guest's LED 0) and blue LED 1. The second UART (Particle: FIFO channel 1;
// Parcore: the pmon console) has its receive held idle and its transmit
// left unconnected. With [buttons] (Parcore) the core's six-bit buttons
// input is held at zero (none pressed).

/// The Pano G2's oscillator, as it reaches pin Y13 (the PHY held in reset).
const panoG2ClockPinHz = 25000000;

/// Spartan-6 PLL_BASE settings for one output clock (CLKOUT0), with
/// CLKFBOUT fed straight back: output = input * mult / (divclk * out).
class Spartan6PllSettings {
  final int divclkDivide;
  final int clkfboutMult;
  final int clkout0Divide;
  final int inputHz;
  final int outputHz;

  const Spartan6PllSettings(this.divclkDivide, this.clkfboutMult,
      this.clkout0Divide, this.inputHz, this.outputHz);

  int get vcoHz => outputHz * clkout0Divide;

  /// Finds settings that give exactly [outputHz] from [inputHz], within the
  /// Spartan-6 limits (taken a little inside the -3 part's): PFD (input /
  /// DIVCLK_DIVIDE) 19–400 MHz, VCO 400–1000 MHz, CLKFBOUT_MULT 1–64,
  /// DIVCLK_DIVIDE 1–52, CLKOUT0_DIVIDE 1–128. Of those, the one whose VCO
  /// is nearest 700 MHz, the middle of the range (the higher on a tie).
  /// Throws if the frequency can't be made exactly.
  static Spartan6PllSettings find(int inputHz, int outputHz) {
    Spartan6PllSettings? best;
    int distance(Spartan6PllSettings p) => (p.vcoHz - 700000000).abs();
    for (var d = 1; d <= 52; d++) {
      if (inputHz % d != 0) continue;
      final pfd = inputHz ~/ d;
      if (pfd < 19000000 || pfd > 400000000) continue;
      for (var m = 1; m <= 64; m++) {
        final vco = pfd * m;
        if (vco < 400000000 || vco > 1000000000) continue;
        if (vco % outputHz != 0) continue;
        final o = vco ~/ outputHz;
        if (o < 1 || o > 128) continue;
        final p = Spartan6PllSettings(d, m, o, inputHz, outputHz);
        if (best == null ||
            distance(p) < distance(best) ||
            (distance(p) == distance(best) && p.vcoHz > best.vcoHz)) {
          best = p;
        }
      }
    }
    if (best == null) {
      throw ArgumentError(
          'The Spartan-6 PLL can\'t make exactly $outputHz Hz from $inputHz Hz');
    }
    return best;
  }
}

/// The `panog2_board` top level around [coreModule] (ParticleSingleCoreTop's
/// definition name, or Parcore's), whose clock is [clockHz]: the clock pin's
/// own 25 MHz, or a PLL's (throws ArgumentError if the PLL can't make it).
String panoG2BoardVerilog({
  required int clockHz,
  String coreModule = 'particle_single_core_top',
  bool buttons = false,
  bool coreLeds = false,
}) {
  final debounce = clockHz ~/ 100; // 10 ms
  final flash = clockHz ~/ 20; // 50 ms
  String mhzOf(int hz) => (hz / 1e6).toString().replaceAll(RegExp(r'\.0$'), '');
  final mhz = mhzOf(clockHz);
  final pll = clockHz == panoG2ClockPinHz
      ? null
      : Spartan6PllSettings.find(panoG2ClockPinHz, clockHz);
  // The design's clock: the pin's, or the PLL's through a BUFG
  final ck = pll == null ? 'clk' : 'clk_sys';
  final pllText = pll == null
      ? ''
      : '''
  // ---- The clock: ${mhzOf(pll.inputHz)} MHz on Y13 -> $mhz MHz (VCO ${mhzOf(pll.vcoHz)} MHz) ----
  wire pll_fb, pll_clk0, pll_locked, clk_sys;
  PLL_BASE #(
    .BANDWIDTH("OPTIMIZED"),
    .CLK_FEEDBACK("CLKFBOUT"),
    .COMPENSATION("INTERNAL"),
    .DIVCLK_DIVIDE(${pll.divclkDivide}),
    .CLKFBOUT_MULT(${pll.clkfboutMult}),
    .CLKFBOUT_PHASE(0.0),
    .CLKOUT0_DIVIDE(${pll.clkout0Divide}),
    .CLKOUT0_PHASE(0.0),
    .CLKOUT0_DUTY_CYCLE(0.5),
    .CLKIN_PERIOD(${(1e9 / pll.inputHz).toStringAsFixed(1)}),
    .REF_JITTER(0.010)
  ) pll (
    .CLKIN(clk),
    .CLKFBIN(pll_fb),
    .RST(1'b0),
    .CLKFBOUT(pll_fb),
    .CLKOUT0(pll_clk0),
    .CLKOUT1(),
    .CLKOUT2(),
    .CLKOUT3(),
    .CLKOUT4(),
    .CLKOUT5(),
    .LOCKED(pll_locked)
  );
  BUFG clk_bufg (.I(pll_clk0), .O(clk_sys));

''';
  final locked = pll == null ? '' : ' || !pll_locked';
  return '''
// =============================================================================
// panog2_board: Pano Logic G2 top level (generated by
// hdl/particle/bin/generate_panog2.dart), $mhz MHz${pll == null ? ' on Y13' : ' from a PLL'}
// =============================================================================
module panog2_board (
  input  wire clk,
  input  wire uart_rx,
  output wire uart_tx,
  input  wire button,
  output wire led_red,
  output wire led_green,
  output wire led_blue
);
$pllText  // ---- The button: its idle level, then debounced presses ----
  reg        btn_s1 = 1'b0, btn_s2 = 1'b0;
  reg        btn_known = 1'b0;
  reg        btn_idle = 1'b0;
  reg        btn_pressed = 1'b0;
  reg [23:0] btn_count = 24'd0;
  always @(posedge $ck) begin
    btn_s1 <= button;
    btn_s2 <= btn_s1;
    if (!btn_known) begin
      if (btn_count == 24'd$debounce) begin
        btn_known <= 1'b1;
        btn_idle  <= btn_s2;
        btn_count <= 24'd0;
      end else begin
        btn_count <= btn_count + 24'd1;
      end
    end else if ((btn_s2 != btn_idle) != btn_pressed) begin
      if (btn_count == 24'd$debounce) begin
        btn_pressed <= ~btn_pressed;
        btn_count   <= 24'd0;
      end else begin
        btn_count <= btn_count + 24'd1;
      end
    end else begin
      btn_count <= 24'd0;
    end
  end
  wire in_reset = !btn_known || btn_pressed$locked;

  // ---- The core ----
  wire [7:0] core_leds;
  $coreModule core_top (
    .clk($ck),
    .reset_n(~in_reset),
    .ftdi_rx_pin(uart_rx),
    .gpio_rx_pin(1'b1),
    .ftdi_tx_pin(uart_tx),
    .gpio_tx_pin(),${buttons ? "\n    .buttons(6'b000000)," : ''}
    .leds(core_leds)
  );

  // ---- The LED ----
${coreLeds ? _coreLeds : _boardLeds(flash, ck)}
endmodule
''';
}

/// The light from the core's LEDs (Parcore)
const _coreLeds = '''  assign led_red   = core_leds[7];
  assign led_green = core_leds[0];
  assign led_blue  = core_leds[1];''';

/// The light from the wrapper's own state (one Particle core)
String _boardLeds(int flash, String ck) => '''  reg [24:0] beat = 25'd0;
  always @(posedge $ck)
    beat <= beat + 25'd1;
  reg        rx_s1 = 1'b1, rx_s2 = 1'b1;
  reg [23:0] traffic = 24'd0;
  always @(posedge $ck) begin
    rx_s1 <= uart_rx;
    rx_s2 <= rx_s1;
    if (!rx_s2 || !uart_tx)
      traffic <= 24'd$flash;
    else if (traffic != 24'd0)
      traffic <= traffic - 24'd1;
  end
  assign led_red   = in_reset;
  assign led_green = !in_reset && beat[24];
  assign led_blue  = (traffic != 24'd0);''';
