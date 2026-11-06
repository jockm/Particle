import 'dart:io';
import 'package:parcore_rohd/parcore_tcm.dart';
import "dart:async";
import "dart:io";
import "dart:typed_data";
import "package:rohd/rohd.dart";
import "package:test/test.dart";
import "../../rohd/test/test_helpers.dart";
import "package:parcore_rohd/parcore_top.dart";

List<int> loadBinary(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    throw Exception('Binary not found: $path');
  }
  return file.readAsBytesSync();
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group("Parcore RV32IM Guest Program Execution", () {
    late SimpleClockGenerator clk;
    late Logic reset;
    late Logic uartRx;
    late ParcoreTop top;

    setUp(() async {
      clk = SimpleClockGenerator(10);
      reset = Logic(name: 'reset');
      uartRx = Logic(name: 'uart_rx');

      final c0Kernel = loadBinary('../../build/parcore/riscv/core0_if_uart.bin');
      final c1Kernel = loadBinary('../../build/parcore/riscv/core1_id.bin');
      final c2Kernel = loadBinary('../../build/parcore/riscv/core2_ex.bin');
      final c3Kernel = loadBinary('../../build/parcore/riscv/core3_mem.bin');
      final guestProg = loadBinary('../../build/guest_rv32_test.bin');

      final c0Merged = Uint8List(0x2000); // 8KB
      for (int i = 0; i < c0Kernel.length; i++) {
        c0Merged[i] = c0Kernel[i];
      }
      const guestOffsetInTcm = 0x0500 - 0x0100;
      for (int i = 0; i < guestProg.length; i++) {
        c0Merged[guestOffsetInTcm + i] = guestProg[i];
      }

      top = ParcoreTop(
        clk: clk.clk,
        reset: reset,
        uartRx: uartRx,
        core0Binary: c0Merged,
        core1Binary: c1Kernel,
        core2Binary: c2Kernel,
        core3Binary: c3Kernel,
      );

      await top.build();
    });

    test("Guest instructions retire into Core 1 architectural registers (x1..x5)", () async {
      reset.put(1);
      uartRx.put(1);

      unawaited(Simulator.run());

      // Reset sequence
      await clk.waitCycles(5);
      reset.put(0);

      final core0 = top.subModules.firstWhere((m) => m.name == 'core0_if');

      final c0Pc = core0.output('memPortAAddr');
      final core1 = top.subModules.firstWhere((m) => m.name == 'core1_id');
      final c1Pc = core1.output('memPortAAddr');

      final c0FifoPush = core0.output('fifoPushEn');
      final c0FifoData = core0.output('fifoPushData');
      final c0FifoChan = core0.output('fifoChanSelect');

      final c1FifoPop = core1.output('fifoPopEn');
      final c1FifoPush = core1.output('fifoPushEn');
      final c1FifoPushData = core1.output('fifoPushData');
      final c1FifoChan = core1.output('fifoChanSelect');

      int pushes = 0;
      int pops = 0;

      // Fast simulation loop: tally pushes/pops without stdout bottleneck
      final core2 = top.subModules.firstWhere((m) => m.name == "core2_ex");
      final core3 = top.subModules.firstWhere((m) => m.name == "core3_mem");
      final c3Push = core3.output("fifoPushEn");

      int idleCycles = 0;
      for (int cycle = 0; cycle < 36000; cycle++) {
        await clk.waitCycles(1);
        if (c0FifoPush.value.isValid && c0FifoPush.value.toInt() == 1) pushes++;
        if (c1FifoPop.value.isValid && c1FifoPop.value.toInt() == 1) pops++;

        // Detect early completion: 1000 consecutive cycles without any Core3 writeback
        if (c3Push.value.isValid && c3Push.value.toInt() == 1) {
          idleCycles = 0;
        } else {
          idleCycles++;
        }
        if (pushes > 0 && pops >= 340 && idleCycles > 800) {
          print("Program completed early at cycle $cycle (pipeline drained).");
          break;
        }
      }
      print("Summary: Total C0 Pushes = $pushes, Total C1 Pops = $pops");
      print("Final C0 PC = 0x${c0Pc.value.toInt().toRadixString(16)}, C1 PC = 0x${c1Pc.value.toInt().toRadixString(16)}");

      expect(pops, greaterThan(0), reason: "Core 1 should pop instructions from IF FIFO");

      await Simulator.endSimulation();

      const int regBase = 0x0600;
      final c1Tcm = top.subModules.firstWhere((m) => m.name == 'core1_tcm') as ParcoreTcm;
      final Map<int, int> regs = {};
      for (int i = 1; i <= 31; i++) {
        regs[i] = c1Tcm.readWord(regBase + i * 4);
      }

      print("=== Section 3 ALU Immediate & Reg-Reg Results ===");
      print("  x1=0x${regs[1]!.toRadixString(16)} [setup x1=-16, expected 0xfffffff0]");
      print("  x2=0x${regs[2]!.toRadixString(16)} [setup x2=4, expected 0x4]");
      print("  x3=0x${regs[3]!.toRadixString(16)} [slli 4<<3, expected 0x20]");
      print("  x4=0x${regs[4]!.toRadixString(16)} [srli -16>>2, expected 0x3ffffffc]");
      print("  x5=0x${regs[5]!.toRadixString(16)} [srai -16>>>2, expected 0xfffffffc]");
      print("  x6=0x${regs[6]!.toRadixString(16)} [slti (-16<4), expected 0x1]");
      print("  x7=0x${regs[7]!.toRadixString(16)} [sltiu (-16<4)u, expected 0x0]");
      print("  x8=0x${regs[8]!.toRadixString(16)} [xori -16^0xff, expected 0xffffff0f]");
      print("  x9=0x${regs[9]!.toRadixString(16)} [ori 4|0xf0, expected 0xf4]");
      print("  x10=0x${regs[10]!.toRadixString(16)} [andi -16&0xff, expected 0xf0]");
      print("  x11=0x${regs[11]!.toRadixString(16)} [sub 4-(-16), expected 0x14]");
      print("  x12=0x${regs[12]!.toRadixString(16)} [sll 4<<4, expected 0x40]");
      print("  x13=0x${regs[13]!.toRadixString(16)} [slt (-16<4), expected 0x1]");
      print("  x14=0x${regs[14]!.toRadixString(16)} [sltu (-16<4)u, expected 0x0]");
      print("  x15=0x${regs[15]!.toRadixString(16)} [xor -16^4, expected 0xfffffff4]");
      print("  x16=0x${regs[16]!.toRadixString(16)} [srl -16>>4, expected 0x0fffffff]");
      print("  x17=0x${regs[17]!.toRadixString(16)} [sra -16>>>4, expected 0xffffffff]");
      print("  x18=0x${regs[18]!.toRadixString(16)} [or -16|4, expected 0xfffffff4]");
      print("  x19=0x${regs[19]!.toRadixString(16)} [and -16&4, expected 0x0]");

      expect(regs[1]! & 0xFFFFFFFF, equals(0xFFFFFFF0), reason: "x1 should be -16");
      expect(regs[2], equals(4), reason: "x2 should be 4");
      expect(regs[3], equals(0x20), reason: "x3 should be 32 (slli)");
      expect(regs[4]! & 0xFFFFFFFF, equals(0x3FFFFFFC), reason: "x4 should be 0x3FFFFFFC (srli)");
      expect(regs[5]! & 0xFFFFFFFF, equals(0xFFFFFFFC), reason: "x5 should be -4 (srai)");
      expect(regs[6], equals(1), reason: "x6 should be 1 (slti)");
      expect(regs[7], equals(0), reason: "x7 should be 0 (sltiu)");
      expect(regs[8]! & 0xFFFFFFFF, equals(0xFFFFFF0F), reason: "x8 should be 0xFFFFFF0F (xori)");
      expect(regs[9], equals(0xF4), reason: "x9 should be 0xF4 (ori)");
      expect(regs[10], equals(0xF0), reason: "x10 should be 0xF0 (andi)");
      expect(regs[11], equals(0x14), reason: "x11 should be 20 (sub)");
      expect(regs[12], equals(0x40), reason: "x12 should be 64 (sll)");
      expect(regs[13], equals(1), reason: "x13 should be 1 (slt)");
      expect(regs[14], equals(0), reason: "x14 should be 0 (sltu)");
      expect(regs[15]! & 0xFFFFFFFF, equals(0xFFFFFFF4), reason: "x15 should be 0xFFFFFFF4 (xor)");
      expect(regs[16]! & 0xFFFFFFFF, equals(0x0FFFFFFF), reason: "x16 should be 0x0FFFFFFF (srl)");
      expect(regs[17]! & 0xFFFFFFFF, equals(0xFFFFFFFF), reason: "x17 should be 0xFFFFFFFF (sra)");
      expect(regs[18]! & 0xFFFFFFFF, equals(0xFFFFFFF4), reason: "x18 should be 0xFFFFFFF4 (or)");
      expect(regs[19], equals(0), reason: "x19 should be 0 (and)");

      print("=== Section 4 RV32M Multiply & Divide Results ===");
      print("  x23=0x${regs[23]!.toRadixString(16)} [mul 20*3, expected 0x3c (60)]");
      print("  x24=0x${regs[24]!.toRadixString(16)} [setup x24=0x80000000]");
      print("  x25=0x${regs[25]!.toRadixString(16)} [setup x25=2]");
      print("  x26=0x${regs[26]!.toRadixString(16)} [mulhu 0x80000000*2, expected 0x1]");
      print("  x27=0x${regs[27]!.toRadixString(16)} [div 20/3, expected 0x6]");
      print("  x28=0x${regs[28]!.toRadixString(16)} [divu 20/3, expected 0x6]");
      print("  x29=0x${regs[29]!.toRadixString(16)} [rem 20%3, expected 0x2]");
      print("  x30=0x${regs[30]!.toRadixString(16)} [remu 20%3, expected 0x2]");
      print("  x31=0x${regs[31]!.toRadixString(16)} [div by zero 20/0, expected 0xffffffff]");

      expect(regs[23], equals(60), reason: "x23 should be 60 (mul)");
      expect(regs[26], equals(1), reason: "x26 should be 1 (mulhu)");
      expect(regs[27], equals(6), reason: "x27 should be 6 (div)");
      expect(regs[28], equals(6), reason: "x28 should be 6 (divu)");
      expect(regs[29], equals(2), reason: "x29 should be 2 (rem)");
      expect(regs[30], equals(2), reason: "x30 should be 2 (remu)");
      expect(regs[31]! & 0xFFFFFFFF, equals(0xFFFFFFFF), reason: "x31 should be 0xFFFFFFFF (div by 0)");

      await Simulator.endSimulation();
      
    });

    test("Guest instructions - Signed Division & Remainder Edge Cases", () async {
      final c0Kernel = loadBinary('../../build/parcore/riscv/core0_if_uart.bin');
      final c1Kernel = loadBinary('../../build/parcore/riscv/core1_id.bin');
      final c2Kernel = loadBinary('../../build/parcore/riscv/core2_ex.bin');
      final c3Kernel = loadBinary('../../build/parcore/riscv/core3_mem.bin');
      final guestProg = loadBinary('../../build/guest_rv32_signed_div.bin');

      final c0Merged = Uint8List(0x2000);
      for (int i = 0; i < c0Kernel.length; i++) {
        c0Merged[i] = c0Kernel[i];
      }
      const guestOffsetInTcm = 0x0500 - 0x0100;
      for (int i = 0; i < guestProg.length; i++) {
        c0Merged[guestOffsetInTcm + i] = guestProg[i];
      }

      final signedTop = ParcoreTop(
        clk: clk.clk,
        reset: reset,
        uartRx: uartRx,
        core0Binary: c0Merged,
        core1Binary: c1Kernel,
        core2Binary: c2Kernel,
        core3Binary: c3Kernel,
      );

      await signedTop.build();

      reset.put(1);
      uartRx.put(1);

      unawaited(Simulator.run());

      await clk.waitCycles(5);
      reset.put(0);

      final core0 = signedTop.subModules.firstWhere((m) => m.name == 'core0_if');
      final core1 = signedTop.subModules.firstWhere((m) => m.name == 'core1_id');
      final core3 = signedTop.subModules.firstWhere((m) => m.name == 'core3_mem');

      final c0FifoPush = core0.output('fifoPushEn');
      final c1FifoPop  = core1.output('fifoPopEn');
      final c3Push     = core3.output('fifoPushEn');

      int pushes = 0;
      int pops = 0;
      int c3Pushes = 0;
      int idleCycles = 0;

      for (int cycle = 0; cycle < 30000; cycle++) {
        await clk.waitCycles(1);
        if (c0FifoPush.value.isValid && c0FifoPush.value.toInt() == 1) pushes++;
        if (c1FifoPop.value.isValid && c1FifoPop.value.toInt() == 1) pops++;
        if (c3Push.value.isValid && c3Push.value.toInt() == 1) {
          c3Pushes++;
          idleCycles = 0;
        } else {
          idleCycles++;
        }

        // 18 writeback packets * 2 words = 36 c3 pushes.
        // Wait for all 36 writeback pushes from Core 3 plus settling cycles for Core 1 register writeback.
        if (c3Pushes >= 36 && idleCycles > 300) {
          print("Signed division test drained at cycle $cycle (pops=$pops).");
          final c2Pc = signedTop.subModules.firstWhere((m) => m.name == 'core2_ex').output('memPortAAddr');
          final c3Pc = signedTop.subModules.firstWhere((m) => m.name == 'core3_mem').output('memPortAAddr');
          print("  Core 0 PC: 0x${core0.output('memPortAAddr').value.toInt().toRadixString(16)}");
          print("  Core 1 PC: 0x${core1.output('memPortAAddr').value.toInt().toRadixString(16)}");
          print("  Core 2 PC: 0x${c2Pc.value.toInt().toRadixString(16)}");
          print("  Core 3 PC: 0x${c3Pc.value.toInt().toRadixString(16)}");
          break;
        }
      }

      await Simulator.endSimulation();

      const int regBase = 0x0600;
      final c1Tcm = signedTop.subModules.firstWhere((m) => m.name == 'core1_tcm') as ParcoreTcm;
      final Map<int, int> regs = {};
      for (int i = 1; i <= 31; i++) {
        regs[i] = c1Tcm.readWord(regBase + i * 4);
      }

      print("=== Section 4.1 Debug: Pushes=$pushes, Pops=$pops ===");
      for (int i = 1; i <= 5; i++) {
        print("  x$i=0x${regs[i]!.toRadixString(16)}");
      }
      print("=== Section 4.1 Signed Division Edge Cases ===");
      print("  x6=0x${regs[6]!.toRadixString(16)} [(-20)/3, expected 0xfffffffa (-6)]");
      print("  x7=0x${regs[7]!.toRadixString(16)} [(-20)%3, expected 0xfffffffe (-2)]");
      print("  x8=0x${regs[8]!.toRadixString(16)} [20/(-3), expected 0xfffffffa (-6)]");
      print("  x9=0x${regs[9]!.toRadixString(16)} [20%(-3), expected 0x2 (2)]");
      print("  x10=0x${regs[10]!.toRadixString(16)} [(-20)/(-3), expected 0x6 (6)]");
      print("  x11=0x${regs[11]!.toRadixString(16)} [(-20)%(-3), expected 0xfffffffe (-2)]");
      print("  x14=0x${regs[14]!.toRadixString(16)} [overflow -2G/-1, expected 0x80000000]");
      print("  x15=0x${regs[15]!.toRadixString(16)} [overflow -2G%-1, expected 0x0]");
      print("  x16=0x${regs[16]!.toRadixString(16)} [rem 20%0, expected 0x14 (20)]");
      print("  x17=0x${regs[17]!.toRadixString(16)} [remu 20%0, expected 0x14 (20)]");

      expect(regs[6]! & 0xFFFFFFFF, equals(0xFFFFFFFA), reason: "x6 should be -6 ((-20)/3)");
      expect(regs[7]! & 0xFFFFFFFF, equals(0xFFFFFFFE), reason: "x7 should be -2 ((-20)%3)");
      expect(regs[8]! & 0xFFFFFFFF, equals(0xFFFFFFFA), reason: "x8 should be -6 (20/(-3))");
      expect(regs[9]!, equals(2), reason: "x9 should be 2 (20%(-3))");
      expect(regs[10]!, equals(6), reason: "x10 should be 6 ((-20)/(-3))");
      expect(regs[11]! & 0xFFFFFFFF, equals(0xFFFFFFFE), reason: "x11 should be -2 ((-20)%(-3))");
      expect(regs[14]! & 0xFFFFFFFF, equals(0x80000000), reason: "x14 should be 0x80000000 (-2G/-1 overflow)");
      expect(regs[15]!, equals(0), reason: "x15 should be 0 (-2G%-1)");
      expect(regs[16]!, equals(20), reason: "x16 should be 20 (20%0)");
      expect(regs[17]!, equals(20), reason: "x17 should be 20 (20%0 unsigned)");
    });

    test("Guest instructions - Multiply High & Full RV32M (MUL, MULH, MULHSU, MULHU)", () async {
      final c0Kernel = loadBinary('../../build/parcore/riscv/core0_if_uart.bin');
      final c1Kernel = loadBinary('../../build/parcore/riscv/core1_id.bin');
      final c2Kernel = loadBinary('../../build/parcore/riscv/core2_ex.bin');
      final c3Kernel = loadBinary('../../build/parcore/riscv/core3_mem.bin');
      final guestProg = loadBinary('../../build/guest_rv32_mul_test.bin');

      final c0Merged = Uint8List(0x2000);
      for (int i = 0; i < c0Kernel.length; i++) {
        c0Merged[i] = c0Kernel[i];
      }
      const guestOffsetInTcm = 0x0500 - 0x0100;
      for (int i = 0; i < guestProg.length; i++) {
        c0Merged[guestOffsetInTcm + i] = guestProg[i];
      }

      final mulTop = ParcoreTop(
        clk: clk.clk,
        reset: reset,
        uartRx: uartRx,
        core0Binary: c0Merged,
        core1Binary: c1Kernel,
        core2Binary: c2Kernel,
        core3Binary: c3Kernel,
      );
      await mulTop.build();

      reset.put(1);
      uartRx.put(1);

      unawaited(Simulator.run());

      await clk.waitCycles(5);
      reset.put(0);

      final core0 = mulTop.subModules.firstWhere((m) => m.name == 'core0_if');
      final core1 = mulTop.subModules.firstWhere((m) => m.name == 'core1_id');

      final core3 = mulTop.subModules.firstWhere((m) => m.name == 'core3_mem');
      final c0FifoPush = core0.output('fifoPushEn');
      final c1FifoPop  = core1.output('fifoPopEn');
      final c3FifoPush = core3.output('fifoPushEn');

      int pushes = 0;
      int pops = 0;
      int idleCycles = 0;

      for (int cycle = 0; cycle < 20000; cycle++) {
        await clk.waitCycles(1);
        if (c0FifoPush.value.isValid && c0FifoPush.value.toInt() == 1) pushes++;
        if (c1FifoPop.value.isValid && c1FifoPop.value.toInt() == 1) {
          pops++;
          idleCycles = 0;
        } else if (c3FifoPush.value.isValid && c3FifoPush.value.toInt() == 1) {
          idleCycles = 0;
        } else {
          idleCycles++;
        }

        if (pushes > 0 && pops >= 38 && idleCycles > 350) {
          print("Multiply test drained at cycle $cycle (pops=$pops).");
          final c2Pc = mulTop.subModules.firstWhere((m) => m.name == 'core2_ex').output('memPortAAddr');
          final c3Pc = mulTop.subModules.firstWhere((m) => m.name == 'core3_mem').output('memPortAAddr');
          print("  Core 0 PC: 0x${core0.output('memPortAAddr').value.toInt().toRadixString(16)}");
          print("  Core 1 PC: 0x${core1.output('memPortAAddr').value.toInt().toRadixString(16)}");
          print("  Core 2 PC: 0x${c2Pc.value.toInt().toRadixString(16)}");
          print("  Core 3 PC: 0x${c3Pc.value.toInt().toRadixString(16)}");
          break;
        }
      }

      await Simulator.endSimulation();

      const int regBase = 0x0600;
      final c1Tcm = mulTop.subModules.firstWhere((m) => m.name == 'core1_tcm') as ParcoreTcm;
      final Map<int, int> regs = {};
      for (int i = 1; i <= 31; i++) {
        regs[i] = c1Tcm.readWord(regBase + i * 4);
      }

      print("=== Section 4.2 Multiply Extension Results ===");
      print("  x7=0x${regs[7]!.toRadixString(16)} [mul 20*(-3), expected 0xffffffc4 (-60)]");
      print("  x8=0x${regs[8]!.toRadixString(16)} [mulh 0x40000000*2, expected 0x0]");
      print("  x9=0x${regs[9]!.toRadixString(16)} [mulh (-1)*2, expected 0xffffffff]");
      print("  x10=0x${regs[10]!.toRadixString(16)} [mulh (-1)*(-3), expected 0x0]");
      print("  x11=0x${regs[11]!.toRadixString(16)} [mulhsu (-1)*2, expected 0xffffffff]");
      print("  x12=0x${regs[12]!.toRadixString(16)} [mulhsu (-1)*0x80000000, expected 0xffffffff]");
      print("  x13=0x${regs[13]!.toRadixString(16)} [mulhsu 20*0x80000000, expected 0xa (10)]");
      print("  x14=0x${regs[14]!.toRadixString(16)} [mulhu 0x80000000*2, expected 0x1]");
      print("  x15=0x${regs[15]!.toRadixString(16)} [mulhu 0xffffffff*0xffffffff, expected 0xfffffffe]");

      expect(regs[7]! & 0xFFFFFFFF, equals(0xFFFFFFC4), reason: "x7 should be -60 (mul 20*(-3))");
      expect(regs[8]!, equals(0), reason: "x8 should be 0 (mulh 0x40000000*2)");
      expect(regs[9]! & 0xFFFFFFFF, equals(0xFFFFFFFF), reason: "x9 should be -1 (mulh (-1)*2)");
      expect(regs[10]!, equals(0), reason: "x10 should be 0 (mulh (-1)*(-3))");
      expect(regs[11]! & 0xFFFFFFFF, equals(0xFFFFFFFF), reason: "x11 should be -1 (mulhsu (-1)*2)");
      expect(regs[12]! & 0xFFFFFFFF, equals(0xFFFFFFFF), reason: "x12 should be -1 (mulhsu (-1)*0x80000000)");
      expect(regs[13]!, equals(10), reason: "x13 should be 10 (mulhsu 20*0x80000000)");
      expect(regs[14]!, equals(1), reason: "x14 should be 1 (mulhu 0x80000000*2)");
      expect(regs[15]! & 0xFFFFFFFF, equals(0xFFFFFFFE), reason: "x15 should be 0xFFFFFFFE (mulhu max unsigned)");
    });

    test("Guest instructions - Sub-word Memory Access (LB, LBU, LH, LHU, LW, SB, SH, SW)", () async {
      final c0Kernel = loadBinary('../../build/parcore/riscv/core0_if_uart.bin');
      final c1Kernel = loadBinary('../../build/parcore/riscv/core1_id.bin');
      final c2Kernel = loadBinary('../../build/parcore/riscv/core2_ex.bin');
      final c3Kernel = loadBinary('../../build/parcore/riscv/core3_mem.bin');
      final guestProg = loadBinary('../../build/guest_rv32_mem_test.bin');

      final c0Merged = Uint8List(0x2000);
      for (int i = 0; i < c0Kernel.length; i++) {
        c0Merged[i] = c0Kernel[i];
      }
      const guestOffsetInTcm = 0x0500 - 0x0100;
      for (int i = 0; i < guestProg.length; i++) {
        c0Merged[guestOffsetInTcm + i] = guestProg[i];
      }

      final memTop = ParcoreTop(
        clk: clk.clk,
        reset: reset,
        uartRx: uartRx,
        core0Binary: c0Merged,
        core1Binary: c1Kernel,
        core2Binary: c2Kernel,
        core3Binary: c3Kernel,
      );
      await memTop.build();

      reset.put(1);
      uartRx.put(1);

      unawaited(Simulator.run());

      await clk.waitCycles(5);
      reset.put(0);

      final core0 = memTop.subModules.firstWhere((m) => m.name == 'core0_if');
      final core1 = memTop.subModules.firstWhere((m) => m.name == 'core1_id');
      final core3 = memTop.subModules.firstWhere((m) => m.name == 'core3_mem');

      final c0FifoPush = core0.output('fifoPushEn');
      final c1FifoPop  = core1.output('fifoPopEn');
      final c3FifoPush = core3.output('fifoPushEn');

      int pushes = 0;
      int pops = 0;
      int idleCycles = 0;

      for (int cycle = 0; cycle < 25000; cycle++) {
        await clk.waitCycles(1);
        if (c0FifoPush.value.isValid && c0FifoPush.value.toInt() == 1) pushes++;
        if (c1FifoPop.value.isValid && c1FifoPop.value.toInt() == 1) {
          pops++;
          idleCycles = 0;
        } else if (c3FifoPush.value.isValid && c3FifoPush.value.toInt() == 1) {
          idleCycles = 0;
        } else {
          idleCycles++;
        }

        if (pushes > 0 && pops >= 50 && idleCycles > 400) {
          print("Memory test drained at cycle $cycle (pops=$pops).");
          final c2Pc = memTop.subModules.firstWhere((m) => m.name == 'core2_ex').output('memPortAAddr');
          final c3Pc = memTop.subModules.firstWhere((m) => m.name == 'core3_mem').output('memPortAAddr');
          print("  Core 0 PC: 0x${core0.output('memPortAAddr').value.toInt().toRadixString(16)}");
          print("  Core 1 PC: 0x${core1.output('memPortAAddr').value.toInt().toRadixString(16)}");
          print("  Core 2 PC: 0x${c2Pc.value.toInt().toRadixString(16)}");
          print("  Core 3 PC: 0x${c3Pc.value.toInt().toRadixString(16)}");
          break;
        }
      }

      await Simulator.endSimulation();

      const int regBase = 0x0600;
      final c1Tcm = memTop.subModules.firstWhere((m) => m.name == 'core1_tcm') as ParcoreTcm;
      final Map<int, int> regs = {};
      for (int i = 1; i <= 31; i++) {
        regs[i] = c1Tcm.readWord(regBase + i * 4);
      }

      print("=== Section 5: Memory Load & Store Results ===");
      print("  x6=0x${regs[6]!.toRadixString(16)} [lb 0x800 -> 0x5a, expected 0x5a]");
      print("  x7=0x${regs[7]!.toRadixString(16)} [lb 0x801 -> 0xf2, expected 0xfffffff2]");
      print("  x8=0x${regs[8]!.toRadixString(16)} [lbu 0x801 -> 0xf2, expected 0xf2]");
      print("  x9=0x${regs[9]!.toRadixString(16)} [lh 0x804 -> 0x1234, expected 0x1234]");
      print("  x10=0x${regs[10]!.toRadixString(16)} [lh 0x806 -> 0xfffe, expected 0xfffffffe]");
      print("  x11=0x${regs[11]!.toRadixString(16)} [lhu 0x806 -> 0xfffe, expected 0xfffe]");
      print("  x12=0x${regs[12]!.toRadixString(16)} [lw 0x800 -> composite word, expected 0xf25af25a]");
      print("  x13=0x${regs[13]!.toRadixString(16)} [lw 0x804 -> composite word, expected 0xfffe1234]");

      expect(regs[6]!, equals(0x5A), reason: "x6 should be 0x5A (lb positive byte)");
      expect(regs[7]! & 0xFFFFFFFF, equals(0xFFFFFFF2), reason: "x7 should be 0xFFFFFFF2 (lb sign-extended)");
      expect(regs[8]!, equals(0xF2), reason: "x8 should be 0xF2 (lbu zero-extended)");
      expect(regs[9]!, equals(0x1234), reason: "x9 should be 0x1234 (lh positive halfword)");
      expect(regs[10]! & 0xFFFFFFFF, equals(0xFFFFFFFE), reason: "x10 should be 0xFFFFFFFE (lh sign-extended)");
      expect(regs[11]!, equals(0xFFFE), reason: "x11 should be 0xFFFE (lhu zero-extended)");
      expect(regs[12]! & 0xFFFFFFFF, equals(0xF25AF25A), reason: "x12 should be 0xF25AF25A (lw 4 bytes combined)");
      expect(regs[13]! & 0xFFFFFFFF, equals(0xFFFE1234), reason: "x13 should be 0xFFFE1234 (lw 2 halfwords combined)");
    });

  });
}
