// =============================================================================
// File: hdl/parcore/lib/spi_controller.dart
// Architecture: Lightweight MMIO SPI Master Controller for Parcore Conductor
// Framework: Intel ROHD (Dart sdk >= 3.0.0)
// =============================================================================

import 'package:rohd/rohd.dart';

class SpiController extends Module {
  Logic get clk => input('clk');
  Logic get reset => input('reset');

  // MMIO Bus Interface
  Logic get addr => input('addr');
  Logic get wData => input('wData');
  Logic get wEn => input('wEn');
  Logic get rEn => input('rEn');
  Logic get rData => output('rData');

  // Physical SPI Flash Pins (ULX3S)
  Logic get spiCsN => output('spi_cs_n');
  Logic get spiSck => output('spi_sck');
  Logic get spiMosi => output('spi_mosi');
  Logic get spiMiso => input('spi_miso');

  SpiController({
    required Logic clk,
    required Logic reset,
    required Logic addr,
    required Logic wData,
    required Logic wEn,
    required Logic rEn,
    required Logic spiMiso,
    super.name = 'spi_controller',
  }) {
    addInput('clk', clk);
    addInput('reset', reset);
    addInput('addr', addr, width: 32);
    addInput('wData', wData, width: 32);
    addInput('wEn', wEn);
    addInput('rEn', rEn);
    addInput('spi_miso', spiMiso);

    addOutput('rData', width: 32);
    addOutput('spi_cs_n');
    addOutput('spi_sck');
    addOutput('spi_mosi');

    _build();
  }

  void _build() {
    // Register Map:
    // 0xF000_0010 (+0x0): SPI_CTRL  [Bit 0: CS_N override, Bit 1: START strobe, Bit 2: BUSY (RO)]
    // 0xF000_0014 (+0x4): SPI_DATA  [7:0 TX/RX shift register]
    // 0xF000_0018 (+0x8): SPI_DIV   [15:0 clock divider, default 1]

    final regCsN = Logic(name: 'reg_cs_n');
    final regDiv = Logic(name: 'reg_div', width: 16);
    final divCnt = Logic(name: 'div_cnt', width: 16);
    final bitCnt = Logic(name: 'bit_cnt', width: 4);
    final busy = Logic(name: 'spi_busy');
    final sckReg = Logic(name: 'sck_reg');
    final shiftReg = Logic(name: 'shift_reg', width: 8);

    final isCtrlSel = addr.eq(Const(0xF0000010, width: 32));
    final isDataSel = addr.eq(Const(0xF0000014, width: 32));
    final isDivSel  = addr.eq(Const(0xF0000018, width: 32));

    Sequential(clk, reset: reset, resetValues: {
      regCsN: Const(1),
      regDiv: Const(1, width: 16),
      divCnt: Const(0, width: 16),
      bitCnt: Const(0, width: 4),
      busy: Const(0),
      sckReg: Const(0),
      shiftReg: Const(0, width: 8),
    }, [
      // Control & Divider Writes
      If(wEn & isCtrlSel, then: [
        regCsN < wData.slice(0, 0),
        If(wData.slice(1, 1) & ~busy, then: [
          busy < Const(1),
          bitCnt < Const(8, width: 4),
          divCnt < regDiv,
          sckReg < Const(0),
        ]),
      ]),
      If(wEn & isDivSel, then: [
        regDiv < wData.slice(15, 0),
      ]),
      // Writing SPI_DATA loads TX byte and auto-starts transfer if idle
      If(wEn & isDataSel & ~busy, then: [
        shiftReg < wData.slice(7, 0),
        busy < Const(1),
        bitCnt < Const(8, width: 4),
        divCnt < regDiv,
        sckReg < Const(0),
      ]),

      // SPI Mode 0 Shift FSM
      If(busy, then: [
        If(divCnt.eq(Const(0, width: 16)), then: [
          divCnt < regDiv,
          If(~sckReg, then: [
            // Rising edge of SCK: sample MISO into LSB
            sckReg < Const(1),
            shiftReg < [shiftReg.slice(6, 0), spiMiso].swizzle(),
          ], orElse: [
            // Falling edge of SCK: advance bit counter
            sckReg < Const(0),
            If(bitCnt.eq(Const(1, width: 4)), then: [
              busy < Const(0),
              bitCnt < Const(0, width: 4),
            ], orElse: [
              bitCnt < bitCnt - Const(1, width: 4),
            ]),
          ]),
        ], orElse: [
          divCnt < divCnt - Const(1, width: 16),
        ]),
      ]),
    ]);

    spiCsN <= regCsN;
    spiSck <= sckReg;
    spiMosi <= shiftReg.slice(7, 7);

    // Readback Mux
    final ctrlRead = [Const(0, width: 29), busy, Const(0, width: 1), regCsN].swizzle();
    final dataRead = shiftReg.zeroExtend(32);
    final divRead  = regDiv.zeroExtend(32);

    rData <= mux(
      isCtrlSel,
      ctrlRead,
      mux(isDataSel, dataRead, mux(isDivSel, divRead, Const(0, width: 32))),
    );
  }
}
