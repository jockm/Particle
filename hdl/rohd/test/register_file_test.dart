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
  
    test('Option 2 RBASE windowing shifts R1-R15 while keeping R0 zero', () async {
      final clk = SimpleClockGenerator(10).clk;
      final reset = Logic(name: 'reset');
      final rAddrA = Logic(name: 'rAddrA', width: 4);
      final rAddrB = Logic(name: 'rAddrB', width: 4);
      final wAddr = Logic(name: 'wAddr', width: 4);
      final wData = Logic(name: 'wData', width: 32);
      final wEn = Logic(name: 'wEn');
      final rbaseEn = Logic(name: 'rbaseEn');
      final rbaseIn = Logic(name: 'rbaseIn', width: 5);

      final rf = RegisterFile(
        clk: clk,
        reset: reset,
        rAddrA: rAddrA,
        rAddrB: rAddrB,
        wAddr: wAddr,
        wData: wData,
        wEn: wEn,
        xchgEn: Const(0),
        xchgAllEn: Const(0),
        xchgMostEn: Const(0),
        xchgRegIdx: Const(0, width: 4),
        rbaseEn: rbaseEn,
        rbaseIn: rbaseIn,
      );

      await rf.build();

      // Reset
      rAddrA.inject(0);
      rAddrB.inject(0);
      wAddr.inject(0);
      wData.inject(0);
      wEn.inject(0);
      rbaseIn.inject(0);
      rbaseEn.inject(0);
      reset.inject(1);
      await clk.nextPosedge;
      reset.inject(0);
      await clk.nextPosedge;

      // 1. With RBASE=0: Write 0xAAAA to R1 (physical 1)
      wAddr.inject(1);
      wData.inject(0xAAAA);
      wEn.inject(1);
      await clk.nextPosedge;
      wEn.inject(0);
      wAddr.inject(0);
      wData.inject(0);
      await clk.nextPosedge;

      // Read back R1 (physical 1)
      rAddrA.inject(1);
      await clk.nextPosedge;
      expect(rf.rDataA.value.toInt(), equals(0xAAAA));

      // 2. Switch RBASE to 16
      rbaseIn.inject(16);
      rbaseEn.inject(1);
      await clk.nextPosedge;
      rbaseEn.inject(0);
      await clk.nextPosedge;

      // With RBASE=16, virtual R1 addresses physical 17 (should be initial 0)
      rAddrA.inject(0);
      await clk.nextPosedge;
      rAddrA.inject(1);
      await clk.nextPosedge;
      expect(rf.rDataA.value.toInt(), equals(0));

      // Write 0xBBBB to virtual R1 (physical 17)
      wAddr.inject(1);
      wData.inject(0xBBBB);
      wEn.inject(1);
      await clk.nextPosedge;
      wEn.inject(0);
      wAddr.inject(0);
      wData.inject(0);
      await clk.nextPosedge;

      // Verify physical 17 has 0xBBBB
      rAddrA.inject(1);
      await clk.nextPosedge;
      expect(rf.rDataA.value.toInt(), equals(0xBBBB));

      // 3. Virtual R0 must ALWAYS be 0 even when RBASE=16
      rAddrB.inject(0);
      await clk.nextPosedge;
      expect(rf.rDataB.value.toInt(), equals(0));

      // 4. Switch back to RBASE=0
      rbaseIn.inject(0);
      rbaseEn.inject(1);
      await clk.nextPosedge;
      rbaseEn.inject(0);
      await clk.nextPosedge;

      // Virtual R1 now points to physical 1 again (should still be 0xAAAA)
      rAddrA.inject(0);
      await clk.nextPosedge;
      rAddrA.inject(1);
      await clk.nextPosedge;
      expect(rf.rDataA.value.toInt(), equals(0xAAAA));
    });
});
}
