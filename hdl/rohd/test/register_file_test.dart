// =============================================================================
// File: hdl/rohd/test/register_file_test.dart
// Architecture: Particle 32-bit RISC
// Description: Unit testbench for 16x32 Register File, hardwired R0, and
//              single-cycle hardware shadow bank context switching.
// =============================================================================

import 'dart:async';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';
import '../lib/constants.dart';
import '../lib/register_file.dart';

void main() {
  tearDown(() async {
    await Simulator.endSimulation();
    await Simulator.reset();
  });

  group('RegisterFile & Shadow Bank Tests', () {
    late SimpleClockGenerator clkGen;
    late Logic reset;
    late Logic rAddrA, rAddrB, wAddr, wData, wEn;
    late Logic xchgEn, xchgAllEn, xchgMostEn, xchgRegIdx;
    late RegisterFile rf;

    Future<void> stepClocks(int cycles) async {
      for (int i = 0; i < cycles; i++) {
        await clkGen.clk.nextPosedge;
      }
    }

    setUp(() async {
      clkGen = SimpleClockGenerator(10);
      reset = Logic(name: 'reset');
      rAddrA = Logic(name: 'rAddrA', width: 4);
      rAddrB = Logic(name: 'rAddrB', width: 4);
      wAddr = Logic(name: 'wAddr', width: 4);
      wData = Logic(name: 'wData', width: ParticleWidths.word);
      wEn = Logic(name: 'wEn');
      xchgEn = Logic(name: 'xchgEn');
      xchgAllEn = Logic(name: 'xchgAllEn');
      xchgMostEn = Logic(name: 'xchgMostEn');
      xchgRegIdx = Logic(name: 'xchgRegIdx', width: 4);

      rf = RegisterFile(
        clk: clkGen.clk,
        reset: reset,
        rAddrA: rAddrA,
        rAddrB: rAddrB,
        wAddr: wAddr,
        wData: wData,
        wEn: wEn,
        xchgEn: xchgEn,
        xchgAllEn: xchgAllEn,
        xchgMostEn: xchgMostEn,
        xchgRegIdx: xchgRegIdx,
      );
      await rf.build();

      unawaited(Simulator.run());

      reset.put(1);
      wEn.put(0);
      xchgEn.put(0);
      xchgAllEn.put(0);
      xchgMostEn.put(0);
      rAddrA.put(0);
      rAddrB.put(0);
      wAddr.put(0);
      wData.put(0);
      xchgRegIdx.put(0);

      await stepClocks(2);
      reset.put(0);
    });

    test('Hardwired R0 Discards Writes and Reads Zero', () async {
      wAddr.put(0);
      wData.put(0xDEADBEEF);
      wEn.put(1);
      await stepClocks(1);
      wEn.put(0);

      rAddrA.put(0);
      expect(rf.rDataA.value.toInt(), equals(0));
    });

    test('Synchronous Write & Asynchronous Dual Read', () async {
      wAddr.put(1);
      wData.put(0x12345678);
      wEn.put(1);
      await stepClocks(1);

      wAddr.put(2);
      wData.put(0x87654321);
      await stepClocks(1);
      wEn.put(0);

      rAddrA.put(1);
      rAddrB.put(2);
      expect(rf.rDataA.value.toInt(), equals(0x12345678));
      expect(rf.rDataB.value.toInt(), equals(0x87654321));
    });

    test('XCHGMOST Preserves R15 Stack Pointer across Context Switches',
        () async {
      // Setup R1 = 0xAA, R15 = 0x10000
      wAddr.put(1);
      wData.put(0x000000AA);
      wEn.put(1);
      await stepClocks(1);

      wAddr.put(15);
      wData.put(0x00010000);
      await stepClocks(1);
      wEn.put(0);

      // Perform XCHGMOST (Enter Trap)
      xchgMostEn.put(1);
      await stepClocks(1);
      xchgMostEn.put(0);

      // Active R1 reads shadow bank default (0), R15 preserved at 0x10000
      rAddrA.put(1);
      rAddrB.put(15);
      expect(rf.rDataA.value.toInt(), equals(0));
      expect(rf.rDataB.value.toInt(), equals(0x00010000));

      // Modify R1 in trap context
      wAddr.put(1);
      wData.put(0x000000BB);
      wEn.put(1);
      await stepClocks(1);
      wEn.put(0);

      // Exit Trap: XCHGMOST restores original state
      xchgMostEn.put(1);
      await stepClocks(1);
      xchgMostEn.put(0);

      // R1 restored to 0xAA, R15 remains 0x10000
      rAddrA.put(1);
      rAddrB.put(15);
      expect(rf.rDataA.value.toInt(), equals(0x000000AA));
      expect(rf.rDataB.value.toInt(), equals(0x00010000));
    });
  });
}
