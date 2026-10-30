// =============================================================================
// File: hdl/rohd/lib/sdram_controller.dart
// Architecture: ULX3S 16-bit SDRAM Controller PHY & Command FSM
// Framework: Intel ROHD (Dart sdk >= 3.0.0)
// =============================================================================

import 'package:rohd/rohd.dart';

class SdramController extends Module {
  Logic get clk => input('clk');
  Logic get rstN => input('rst_n');
  Logic get cmdReq => input('cmd_req');
  Logic get cmdRw => input('cmd_rw');
  Logic get cmdAddr => input('cmd_addr');
  Logic get cmdBurstLen => input('cmd_burst_len');
  Logic get wdata => input('wdata');
  Logic get wdataValid => input('wdata_valid');
  Logic get sdramDqIn => input('sdram_dq_in');

  Logic get sdramClk => output('sdram_clk');
  Logic get sdramCke => output('sdram_cke');
  Logic get sdramCsN => output('sdram_cs_n');
  Logic get sdramRasN => output('sdram_ras_n');
  Logic get sdramCasN => output('sdram_cas_n');
  Logic get sdramWeN => output('sdram_we_n');
  Logic get sdramDqm => output('sdram_dqm');
  Logic get sdramAddr => output('sdram_addr');
  Logic get sdramBa => output('sdram_ba');
  Logic get sdramDqOut => output('sdram_dq_out');
  Logic get sdramDqOe => output('sdram_dq_oe');

  Logic get busy => output('busy');
  Logic get rdataValid => output('rdata_valid');
  Logic get rdata => output('rdata');

  SdramController({
    required Logic clk,
    required Logic rstN,
    required Logic cmdReq,
    required Logic cmdRw,
    required Logic cmdAddr,
    required Logic cmdBurstLen,
    required Logic wdata,
    required Logic wdataValid,
    required Logic sdramDqIn,
    int clkFreqMhz = 25,
    int casLatency = 2,
    super.name = 'sdram_controller',
  }) {
    addInput('clk', clk);
    addInput('rst_n', rstN);
    addInput('cmd_req', cmdReq);
    addInput('cmd_rw', cmdRw);
    addInput('cmd_addr', cmdAddr, width: 24);
    addInput('cmd_burst_len', cmdBurstLen, width: 8);
    addInput('wdata', wdata, width: 16);
    addInput('wdata_valid', wdataValid);
    addInput('sdram_dq_in', sdramDqIn, width: 16);

    addOutput('sdram_clk');
    addOutput('sdram_cke');
    addOutput('sdram_cs_n');
    addOutput('sdram_ras_n');
    addOutput('sdram_cas_n');
    addOutput('sdram_we_n');
    addOutput('sdram_dqm', width: 2);
    addOutput('sdram_addr', width: 13);
    addOutput('sdram_ba', width: 2);
    addOutput('sdram_dq_out', width: 16);
    addOutput('sdram_dq_oe');

    addOutput('busy');
    addOutput('rdata_valid');
    addOutput('rdata', width: 16);

    _build(casLatency);
  }

  void _build(int casLatency) {
    sdramClk <= ~clk;
    sdramCke <= Const(1);
    sdramDqm <= Const(0, width: 2);

    final reset = ~rstN;
    final state = Logic(name: 'fsmState', width: 4);
    final count = Logic(name: 'burstCount', width: 8);
    final readPipe = List.generate(4, (i) => Logic(name: 'rpipe_$i'));

    final outCsN = Logic(name: 'outCsN');
    final outRasN = Logic(name: 'outRasN');
    final outCasN = Logic(name: 'outCasN');
    final outWeN = Logic(name: 'outWeN');
    final outAddr = Logic(name: 'outAddr', width: 13);
    final outBa = Logic(name: 'outBa', width: 2);
    final outDq = Logic(name: 'outDq', width: 16);
    final outOe = Logic(name: 'outOe');
    final isBusy = Logic(name: 'isBusy');
    final rdValid = Logic(name: 'rdValid');

    Sequential(clk, reset: reset, resetValues: {
      state: Const(0, width: 4),
      count: Const(0, width: 8),
      outCsN: Const(0),
      outRasN: Const(1),
      outCasN: Const(1),
      outWeN: Const(1),
      outAddr: Const(0, width: 13),
      outBa: Const(0, width: 2),
      outDq: Const(0, width: 16),
      outOe: Const(0),
      isBusy: Const(0),
      rdValid: Const(0),
      for (var r in readPipe) r: Const(0),
    }, [
      readPipe[0] < Const(0),
      for (int i = 1; i < 4; i++) readPipe[i] < readPipe[i - 1],
      rdValid < readPipe[casLatency],
      Case(state, [
        // 0: IDLE
        CaseItem(Const(0, width: 4), [
          isBusy < Const(0),
          outOe < Const(0),
          outRasN < Const(1),
          outCasN < Const(1),
          outWeN < Const(1),
          If(cmdReq, then: [
            isBusy < Const(1),
            outRasN < Const(0),
            outCasN < Const(1),
            outWeN < Const(1),
            outBa < cmdAddr.slice(23, 22),
            outAddr < cmdAddr.slice(21, 9),
            count < cmdBurstLen,
            state < mux(cmdRw, Const(2, width: 4), Const(1, width: 4)),
          ]),
        ]),

        // 1: READ
        CaseItem(Const(1, width: 4), [
          outRasN < Const(1),
          outCasN < Const(0),
          outWeN < Const(1),
          outAddr < cmdAddr.slice(8, 0).zeroExtend(13),
          readPipe[0] < Const(1),
          If(count.lte(Const(1, width: 8)), then: [
            state < Const(3, width: 4),
          ], orElse: [
            count < count - Const(1, width: 8),
          ]),
        ]),

        // 2: WRITE
        CaseItem(Const(2, width: 4), [
          outRasN < Const(1),
          outCasN < Const(0),
          outWeN < Const(0),
          outAddr < cmdAddr.slice(8, 0).zeroExtend(13),
          outOe < Const(1),
          outDq < wdata,
          If(count.lte(Const(1, width: 8)), then: [
            state < Const(3, width: 4),
          ], orElse: [
            count < count - Const(1, width: 8),
          ]),
        ]),

        // 3: PRECHARGE
        CaseItem(Const(3, width: 4), [
          outRasN < Const(0),
          outCasN < Const(1),
          outWeN < Const(0),
          outAddr < Const(0x400, width: 13),
          outOe < Const(0),
          state < Const(0, width: 4),
        ]),
      ]),
    ]);

    sdramCsN <= outCsN;
    sdramRasN <= outRasN;
    sdramCasN <= outCasN;
    sdramWeN <= outWeN;
    sdramAddr <= outAddr;
    sdramBa <= outBa;
    sdramDqOut <= outDq;
    sdramDqOe <= outOe;
    busy <= isBusy;
    rdataValid <= rdValid;
    rdata <= sdramDqIn;
  }
}
