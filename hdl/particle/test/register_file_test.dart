// =============================================================================
// File: hdl/particle/test/register_file_test.dart
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
    late Logic rAddrA, rAddrB, wAddr, wData, wEn, wAddr2, wData2, wEn2;
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
      wAddr2 = Logic(name: 'wAddr2', width: 4);
      wData2 = Logic(name: 'wData2', width: ParticleWidths.word);
      wEn2 = Logic(name: 'wEn2');
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
        wAddr2: wAddr2,
        wData2: wData2,
        wEn2: wEn2,
        xchgEn: xchgEn,
        xchgAllEn: xchgAllEn,
        xchgMostEn: xchgMostEn,
        xchgRegIdx: xchgRegIdx,
      );
      await rf.build();

      unawaited(Simulator.run());

      reset.put(1);
      wEn.put(0);
      wEn2.put(0);
      wAddr2.put(0);
      wData2.put(0);
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
      // The LUT RAM clear after reset
      await stepClocks(16);
      expect(rf.clearing.value.toInt(), equals(0));
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

    Future<void> write(int reg, int value) async {
      wAddr.put(reg);
      wData.put(value);
      wEn.put(1);
      await stepClocks(1);
      wEn.put(0);
    }

    int read(int reg) {
      rAddrA.put(reg);
      return rf.rDataA.value.toInt();
    }

    test('XCHG Swaps One Register with Its Shadow', () async {
      await write(5, 0x55);
      await write(6, 0x66);
      await write(14, 0xEE);
      xchgRegIdx.put(5);
      xchgEn.put(1);
      await stepClocks(1);
      xchgRegIdx.put(14);
      await stepClocks(1);
      xchgEn.put(0);
      expect(read(5), equals(0));
      expect(read(6), equals(0x66));
      expect(read(14), equals(0));
      expect(rf.shadowValue(5), equals(0x55));
      expect(rf.shadowValue(14), equals(0xEE));
      // Writes go to the active register
      await write(5, 0x5A);
      xchgRegIdx.put(5);
      xchgEn.put(1);
      await stepClocks(1);
      xchgEn.put(0);
      expect(read(5), equals(0x55));
      expect(rf.shadowValue(5), equals(0x5A));
    });

    test('XCHGALL Swaps R1-R15, Including R14 and R15', () async {
      for (var i = 1; i < 16; i++) {
        await write(i, 0x100 + i);
      }
      xchgAllEn.put(1);
      await stepClocks(1);
      xchgAllEn.put(0);
      for (var i = 1; i < 16; i++) {
        expect(read(i), equals(0), reason: 'R$i');
        expect(rf.shadowValue(i), equals(0x100 + i), reason: 'S$i');
      }
      expect(read(0), equals(0));
    });

    test('Both Write Ports in One Cycle (Port 2 to R14)', () async {
      wAddr.put(3);
      wData.put(0x33);
      wEn.put(1);
      wAddr2.put(14);
      wData2.put(0x1);
      wEn2.put(1);
      await stepClocks(1);
      wEn.put(0);
      wEn2.put(0);
      expect(read(3), equals(0x33));
      expect(read(14), equals(0x1));
      // Port 2 wins when both write one register
      wAddr.put(7);
      wData.put(0x70);
      wEn.put(1);
      wAddr2.put(7);
      wData2.put(0x77);
      wEn2.put(1);
      await stepClocks(1);
      wEn.put(0);
      wEn2.put(0);
      expect(read(7), equals(0x77));
      // A pointer update alone, through port 2
      wAddr2.put(9);
      wData2.put(0x99);
      wEn2.put(1);
      await stepClocks(1);
      wEn2.put(0);
      expect(read(9), equals(0x99));
    });

    test('Reset Clears Registers and Shadows', () async {
      await write(2, 0x22);
      await write(14, 0xEE);
      xchgAllEn.put(1);
      await stepClocks(1);
      xchgAllEn.put(0);
      await write(2, 0x2B);
      reset.put(1);
      await stepClocks(2);
      reset.put(0);
      expect(rf.clearing.value.toInt(), equals(1));
      await stepClocks(16);
      expect(rf.clearing.value.toInt(), equals(0));
      for (var i = 0; i < 16; i++) {
        expect(rf.regValue(i), equals(0), reason: 'R$i');
        expect(rf.shadowValue(i), equals(0), reason: 'S$i');
      }
      expect(read(2), equals(0));
    });
  });
}
