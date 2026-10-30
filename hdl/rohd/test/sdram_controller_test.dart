// =============================================================================
// File: hdl/rohd/test/sdram_controller_test.dart
// Architecture: Particle 32-bit RISC / ULX3S SDRAM Controller Verification
// =============================================================================

import 'package:rohd/rohd.dart';
import 'package:test/test.dart';
import '../lib/sdram_controller.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('SDRAM Controller Tests (ULX3S 16-bit PHY)', () {
    late SimpleClockGenerator clk;
    late Logic rstN;
    late Logic cmdReq;
    late Logic cmdRw;
    late Logic cmdAddr;
    late Logic cmdBurstLen;
    late Logic wdata;
    late Logic wdataValid;
    late Logic sdramDqIn;
    late SdramController controller;

    setUp(() async {
      clk = SimpleClockGenerator(40);
      rstN = Logic(name: 'rstN');
      cmdReq = Logic(name: 'cmdReq');
      cmdRw = Logic(name: 'cmdRw');
      cmdAddr = Logic(name: 'cmdAddr', width: 24);
      cmdBurstLen = Logic(name: 'cmdBurstLen', width: 8);
      wdata = Logic(name: 'wdata', width: 16);
      wdataValid = Logic(name: 'wdataValid');
      sdramDqIn = Logic(name: 'sdramDqIn', width: 16);

      rstN.put(0);
      cmdReq.put(0);
      cmdRw.put(0);
      cmdAddr.put(0);
      cmdBurstLen.put(8);
      wdata.put(0);
      wdataValid.put(0);
      sdramDqIn.put(0);

      controller = SdramController(
        clk: clk.clk,
        rstN: rstN,
        cmdReq: cmdReq,
        cmdRw: cmdRw,
        cmdAddr: cmdAddr,
        cmdBurstLen: cmdBurstLen,
        wdata: wdata,
        wdataValid: wdataValid,
        sdramDqIn: sdramDqIn,
      );

      await controller.build();
    });

    test('Power-On Initialization drives default inactive states', () async {
      Simulator.registerAction(80, () => rstN.put(1));
      Simulator.registerAction(160, () {
        expect(controller.sdramCke.value.toInt(), equals(1));
        expect(controller.sdramDqm.value.toInt(), equals(0));
        expect(controller.busy.value.toInt(), equals(0));
      });
      Simulator.registerAction(200, () => Simulator.endSimulation());
      await Simulator.run();
    });
  });
}
