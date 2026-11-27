import "dart:async";
import "dart:io";
import "package:rohd/rohd.dart";
import "package:test/test.dart";
import "../../particle/test/test_helpers.dart";
import "../lib/parcore_top.dart";
import "guest_echo.dart";

List<int>? _loadBinary(String path) {
  final file = File(path);
  return file.existsSync() ? file.readAsBytesSync() : null;
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group("Parcore 4-Stage Multi-Core System Verification", () {
    late SimpleClockGenerator clk;
    late Logic reset;
    late Logic uartRx;
    late ParcoreTop top;

    setUp(() async {
      clk = SimpleClockGenerator(10);
      reset = Logic(name: 'reset');
      uartRx = Logic(name: 'uart_rx');

      final c0 = _loadBinary('../../build/parcore/riscv/core0_if.bin');
      final c1 = _loadBinary('../../build/parcore/riscv/core1_id.bin');
      final c2 = _loadBinary('../../build/parcore/riscv/core2_ex.bin');
      final c3 = _loadBinary('../../build/parcore/riscv/core3_mem.bin');

      top = ParcoreTop(
        clk: clk.clk,
        reset: reset,
        uartRx: uartRx,
        core0Binary: kernelWithGuest(c0!, guestEchoProgram),
        core1Binary: c1,
        core2Binary: c2,
        core3Binary: kernelWithGuest(c3!, guestEchoProgram),
      );

      await top.build();
    });

    test("ParcoreTop elaborates, builds synthesis graph, and generates SystemVerilog", () {
      final sv = top.dumpSystemVerilog();
      expect(sv, contains("module ParcoreTop"));
      expect(sv, contains("parcore_fifo_if_to_id"));
      expect(sv, contains("parcore_fifo_id_to_ex"));
      expect(sv, contains("parcore_fifo_ex_to_mem"));
      expect(sv, contains("parcore_fifo_mem_to_wb"));
      expect(sv, contains("parcore_ftdi_uart"));
    });

    test("ParcoreTop holds reset and maintains valid UART line", () async {
      reset.put(1);
      uartRx.put(1);

      unawaited(Simulator.run());

      await clk.waitCycles(5);

      expect(top.uartTx.value.isValid, isTrue);
      expect(top.uartTx.value.toInt(), equals(1));

      await Simulator.endSimulation();
    });

    test("Guest UART echo: 0x41 sent on uartRx comes back on uartTx (guest program at 0x500, UART on core 3)", () async {
      reset.put(1);
      uartRx.put(1);

      unawaited(Simulator.run());

      await clk.waitCycles(5);
      reset.put(0);

      await clk.waitCycles(10);

      const testByte = 0x41; // ASCII 'A'
      final baudCycles = top.ftdiDivisor; // 25 at 25 MHz, 1 Mbps

      // Send Start bit (Low)
      uartRx.put(0);
      await clk.waitCycles(baudCycles);

      // Send 8 Data Bits (LSB first)
      for (int b = 0; b < 8; b++) {
        uartRx.put((testByte >> b) & 1);
        await clk.waitCycles(baudCycles);
      }

      // Send Stop bit (High)
      uartRx.put(1);

      // Detect falling edge (Start bit arrival)
      bool sawStart = false;
      for (int i = 0; i < 20000; i++) {
        if (top.uartTx.value.toInt() == 0) {
          sawStart = true;
          break;
        }
        await clk.waitCycles(1);
      }
      expect(sawStart, isTrue, reason: "the guest did not echo: no start bit on uartTx");

      // Advance to center of first data bit:
      // Half baud period (start bit center) + 1 full baud period (data bit 0 center)
      // Minus 1 cycle since we detected edge after 1 cycle elapsed
      await clk.waitCycles(baudCycles + (baudCycles ~/ 2) - 1);

      int echoedByte = 0;
      for (int b = 0; b < 8; b++) {
        echoedByte |= (top.uartTx.value.toInt() << b);
        await clk.waitCycles(baudCycles);
      }

      expect(echoedByte, equals(testByte), reason: "the guest echoed the wrong byte");

      await Simulator.endSimulation();
    });
  });

  group("Guest UART output", () {
    test(
        "Four back-to-back guest stores come out as \"Hi!\\n\" (core 3 waits for the transmitter)",
        () async {
      final clk = SimpleClockGenerator(10);
      final reset = Logic(name: 'reset');
      final uartRx = Logic(name: 'uart_rx');
      final c0 = _loadBinary('../../build/parcore/riscv/core0_if.bin')!;
      final c1 = _loadBinary('../../build/parcore/riscv/core1_id.bin');
      final c2 = _loadBinary('../../build/parcore/riscv/core2_ex.bin');
      final c3 = _loadBinary('../../build/parcore/riscv/core3_mem.bin')!;
      final top = ParcoreTop(
        clk: clk.clk,
        reset: reset,
        uartRx: uartRx,
        core0Binary: kernelWithGuest(c0, guestHelloProgram),
        core1Binary: c1,
        core2Binary: c2,
        core3Binary: kernelWithGuest(c3, guestHelloProgram),
        // 100 cycles per bit, 1,000 per byte: slower than the guest's stores
        // arrive, so core 3 has to wait for the transmitter between them
        ftdiBaud: 250000,
      );
      await top.build();

      reset.put(1);
      uartRx.put(1);
      unawaited(Simulator.run());
      try {
        await clk.waitCycles(5);
        reset.put(0);

        // Receive bytes from uartTx: wait for a start bit, then sample each
        // data bit in its middle
        final baud = top.ftdiDivisor;
        final received = <int>[];
        var waited = 0;
        while (received.length < 4 && waited < 12000) {
          if (top.uartTx.value.toInt() != 0) {
            await clk.waitCycles(1);
            waited++;
            continue;
          }
          await clk.waitCycles(baud + baud ~/ 2 - 1);
          var byte = 0;
          for (var b = 0; b < 8; b++) {
            byte |= top.uartTx.value.toInt() << b;
            await clk.waitCycles(baud);
          }
          received.add(byte);
          // Into the stop bit
          await clk.waitCycles(baud ~/ 2);
        }
        expect(String.fromCharCodes(received), equals('Hi!\n'));
      } finally {
        // Also after a failure, so the simulator stops cleanly
        await Simulator.endSimulation();
      }
    });
  });
}
