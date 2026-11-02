import 'dart:async';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';
import '../lib/shared_reg_fabric.dart';

void main() {
  tearDown(() async {
    await Simulator.endSimulation();
    await Simulator.reset();
  });

  group('SharedRegFabric Tests', () {
    late SimpleClockGenerator clkGen;
    late Logic reset;

    late Logic c0Rs1Addr;
    late Logic c0Rs2Addr;
    late Logic c0RdAddr;
    late Logic c0RdData;
    late Logic c0RdWe;

    late Logic c1Rs1Addr;
    late Logic c1Rs2Addr;
    late Logic c1RdAddr;
    late Logic c1RdData;
    late Logic c1RdWe;

    late SharedRegFabric fabric;

    Future<void> stepClocks(int cycles) async {
      for (int i = 0; i < cycles; i++) {
        await clkGen.clk.nextPosedge;
      }
    }

    setUp(() async {
      clkGen = SimpleClockGenerator(10);
      reset = Logic(name: 'reset');

      c0Rs1Addr = Logic(name: 'c0_rs1_addr', width: 5);
      c0Rs2Addr = Logic(name: 'c0_rs2_addr', width: 5);
      c0RdAddr  = Logic(name: 'c0_rd_addr', width: 5);
      c0RdData  = Logic(name: 'c0_rd_data', width: 32);
      c0RdWe    = Logic(name: 'c0_rd_we');

      c1Rs1Addr = Logic(name: 'c1_rs1_addr', width: 5);
      c1Rs2Addr = Logic(name: 'c1_rs2_addr', width: 5);
      c1RdAddr  = Logic(name: 'c1_rd_addr', width: 5);
      c1RdData  = Logic(name: 'c1_rd_data', width: 32);
      c1RdWe    = Logic(name: 'c1_rd_we');

      fabric = SharedRegFabric(
        clk: clkGen.clk,
        reset: reset,
        c0Rs1Addr: c0Rs1Addr,
        c0Rs2Addr: c0Rs2Addr,
        c0RdAddr: c0RdAddr,
        c0RdData: c0RdData,
        c0RdWe: c0RdWe,
        c1Rs1Addr: c1Rs1Addr,
        c1Rs2Addr: c1Rs2Addr,
        c1RdAddr: c1RdAddr,
        c1RdData: c1RdData,
        c1RdWe: c1RdWe,
      );

      await fabric.build();

      // Start clock generator
      unawaited(Simulator.run());

      // Reset sequence
      reset.put(1);
      c0Rs1Addr.put(0);
      c0Rs2Addr.put(0);
      c0RdAddr.put(0);
      c0RdData.put(0);
      c0RdWe.put(0);

      c1Rs1Addr.put(0);
      c1Rs2Addr.put(0);
      c1RdAddr.put(0);
      c1RdData.put(0);
      c1RdWe.put(0);

      await stepClocks(2);
      reset.put(0);
      await stepClocks(1);
    });

    test('x0 is hardwired zero and ignores writes', () async {
      c0RdAddr.put(0);
      c0RdData.put(0xDEADBEEF);
      c0RdWe.put(1);
      c0Rs1Addr.put(0);

      expect(fabric.c0Rs1Data.value.toInt(), equals(0));

      await stepClocks(1);
      c0RdWe.put(0);

      expect(fabric.c0Rs1Data.value.toInt(), equals(0));
    });

    test('Concurrent non-conflicting writes from Core 0 and Core 1', () async {
      c0RdAddr.put(5);
      c0RdData.put(0xAAAA);
      c0RdWe.put(1);

      c1RdAddr.put(10);
      c1RdData.put(0xBBBB);
      c1RdWe.put(1);

      await stepClocks(1);
      c0RdWe.put(0);
      c1RdWe.put(0);

      c0Rs1Addr.put(5);
      c0Rs2Addr.put(10);
      expect(fabric.c0Rs1Data.value.toInt(), equals(0xAAAA));
      expect(fabric.c0Rs2Data.value.toInt(), equals(0xBBBB));

      c1Rs1Addr.put(5);
      c1Rs2Addr.put(10);
      expect(fabric.c1Rs1Data.value.toInt(), equals(0xAAAA));
      expect(fabric.c1Rs2Data.value.toInt(), equals(0xBBBB));
    });

    test('Write collision arbitration: C0 has priority and collision asserted', () async {
      c0RdAddr.put(7);
      c0RdData.put(0xC000);
      c0RdWe.put(1);

      c1RdAddr.put(7);
      c1RdData.put(0xC111);
      c1RdWe.put(1);

      expect(fabric.collisionStrobe.value.toInt(), equals(1));

      await stepClocks(1);
      c0RdWe.put(0);
      c1RdWe.put(0);

      c0Rs1Addr.put(7);
      expect(fabric.c0Rs1Data.value.toInt(), equals(0xC000));
      expect(fabric.collisionStrobe.value.toInt(), equals(0));
    });

    test('Combinational internal RAW bypass forwarding', () async {
      c0RdAddr.put(3);
      c0RdData.put(0x1234);
      c0RdWe.put(1);
      c1Rs1Addr.put(3);

      expect(fabric.c1Rs1Data.value.toInt(), equals(0x1234));

      await stepClocks(1);
      c0RdWe.put(0);
      expect(fabric.c1Rs1Data.value.toInt(), equals(0x1234));
    });
  });
}
