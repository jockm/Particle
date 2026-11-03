#!/usr/bin/env bash
set -e

echo "==> 1. Cleaning up invalid temporary scratch test files..."
rm -f hdl/parcore/test/diag_test.dart hdl/parcore/test/debug_uart_test.dart

echo "==> 2. Updating hdl/rohd/test/multicore_firmware_test.dart for build directory paths..."
cat << 'DART_EOF' > hdl/rohd/test/multicore_firmware_test.dart
import "dart:async";
import "dart:io";
import "dart:typed_data";
import "package:rohd/rohd.dart";
import "package:test/test.dart";
import "../lib/constants.dart";
import "../lib/cpu_config.dart";
import "../lib/particle_multi_core.dart";

Uint8List _loadBinary(List<String> candidatePaths) {
  for (final path in candidatePaths) {
    final file = File(path);
    if (file.existsSync()) {
      return file.readAsBytesSync();
    }
  }
  throw Exception('Unable to locate binary in candidates: $candidatePaths');
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group("Core 1 Firmware Dispatch Verification", () {
    late Logic clk;
    late Logic reset;
    late Logic c0MemARData;
    late Logic c0MemBRData;
    late Logic c1MemARData;
    late Logic c1MemBRData;
    late ParticleMultiCore multiCore;

    late Uint8List c1FirmwareBytes;
    late Uint8List c0StimulusBytes;

    int currentTimestamp = 0;

    void stepClock() {
      // Feed memory half-cycle before posedge
      Simulator.registerAction(currentTimestamp + 2, () {
        if (multiCore.c0MemPortAAddr.value.isValid) {
          final pc0 = multiCore.c0MemPortAAddr.value.toInt();
          final off0 = pc0 - 0x00000100;
          if (off0 >= 0 && off0 + 1 < c0StimulusBytes.length) {
            c0MemARData
                .put((c0StimulusBytes[off0 + 1] << 8) | c0StimulusBytes[off0]);
          } else {
            c0MemARData.put(0);
          }
        }

        if (multiCore.c1MemPortAAddr.value.isValid) {
          final pc1 = multiCore.c1MemPortAAddr.value.toInt();
          final off1 = pc1 - 0x00000100;
          if (off1 >= 0 && off1 + 1 < c1FirmwareBytes.length) {
            c1MemARData
                .put((c1FirmwareBytes[off1 + 1] << 8) | c1FirmwareBytes[off1]);
          } else {
            c1MemARData.put(0);
          }
        }
      });

      // Rising clock edge
      Simulator.registerAction(currentTimestamp + 5, () => clk.put(1));

      // Falling clock edge
      Simulator.registerAction(currentTimestamp + 10, () => clk.put(0));

      currentTimestamp += 10;
    }

    setUp(() async {
      clk = Logic(name: 'clk');
      reset = Logic(name: 'reset');
      c0MemARData = Logic(name: 'c0MemARData', width: ParticleWidths.halfWord);
      c0MemBRData = Logic(name: 'c0MemBRData', width: ParticleWidths.word);
      c1MemARData = Logic(name: 'c1MemARData', width: ParticleWidths.halfWord);
      c1MemBRData = Logic(name: 'c1MemBRData', width: ParticleWidths.word);

      c1FirmwareBytes = _loadBinary([
        '../../build/parcore/riscv/core1_dispatch.bin',
        'build/parcore/riscv/core1_dispatch.bin',
        '../../firmware/parcore/riscv/core1_dispatch.bin',
        'firmware/parcore/riscv/core1_dispatch.bin',
      ]);

      c0StimulusBytes = _loadBinary([
        'build/c0_stimulus.bin',
        '../../build/c0_stimulus.bin',
        'hdl/rohd/build/c0_stimulus.bin',
      ]);

      multiCore = ParticleMultiCore(
        clk: clk,
        reset: reset,
        c0MemPortARData: c0MemARData,
        c0MemPortBRData: c0MemBRData,
        c1MemPortARData: c1MemARData,
        c1MemPortBRData: c1MemBRData,
        configCore0: const CpuConfig(trapTableBase: 0x00000100),
        configCore1: const CpuConfig(trapTableBase: 0x00000100),
      );

      await multiCore.build();

      currentTimestamp = 0;
      clk.put(0);
      reset.put(1);
      c0MemARData.put(0);
      c0MemBRData.put(0);
      c1MemARData.put(0);
      c1MemBRData.put(0);

      // Reset for 4 clock cycles
      for (int i = 0; i < 4; i++) {
        stepClock();
      }

      Simulator.registerAction(currentTimestamp + 2, () => reset.put(0));
    });

    test("Core 1 boots and stalls on FIFO.R waiting for token", () async {
      for (int i = 0; i < 8; i++) {
        stepClock();
      }

      await Simulator.run();

      expect(multiCore.c1MemPortAAddr.value.toInt(), equals(0x00000102));
    });

    test("Branch TAKEN: Core 0 pushes tokens -> Core 1 evaluates BEQ and strobes MBOX", () async {
      bool mboxStrobeSeen = false;
      int mboxVector = 0;

      multiCore.c0MboxStrobeIn.changed.listen((event) {
        if (multiCore.c0MboxStrobeIn.value.isValid &&
            multiCore.c0MboxStrobeIn.value.toInt() == 1) {
          mboxStrobeSeen = true;
          if (multiCore.c0MboxVectorIn.value.isValid) {
            mboxVector = multiCore.c0MboxVectorIn.value.toInt();
          }
        }
      });

      for (int i = 0; i < 100; i++) {
        stepClock();
      }

      await Simulator.run();

      expect(mboxStrobeSeen, isTrue, reason: "Taken branch must strobe Core 0 MBOX");
      expect(mboxVector, equals(1), reason: "Branch redirect vector is 1");
    });
  });
}
DART_EOF

echo "==> 3. Updating hdl/parcore/test/parcore_pipeline_trace_test.dart..."
cat << 'DART_EOF' > hdl/parcore/test/parcore_pipeline_trace_test.dart
import "dart:async";
import "dart:io";
import "package:rohd/rohd.dart";
import "package:test/test.dart";
import "../../rohd/test/test_helpers.dart";
import "../lib/parcore_top.dart";

List<int> loadFirmware(String relativePath) {
  final candidates = [
    '../../$relativePath',
    relativePath,
    '../$relativePath',
  ];
  for (final candidate in candidates) {
    final file = File(candidate);
    if (file.existsSync()) {
      return file.readAsBytesSync();
    }
  }
  throw Exception('Unable to locate firmware binary at $relativePath');
}

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group("Parcore End-to-End Multi-Core Firmware Pipeline Tests", () {
    late SimpleClockGenerator clk;
    late Logic reset;
    late Logic uartRx;
    late ParcoreTop top;

    setUp(() async {
      clk = SimpleClockGenerator(10);
      reset = Logic(name: 'reset');
      uartRx = Logic(name: 'uart_rx');

      final c0Bin = loadFirmware('build/parcore/riscv/core0_if_uart.bin');
      final c1Bin = loadFirmware('build/parcore/riscv/core1_id.bin');
      final c2Bin = loadFirmware('build/parcore/riscv/core2_ex.bin');
      final c3Bin = loadFirmware('build/parcore/riscv/core3_mem.bin');

      top = ParcoreTop(
        clk: clk.clk,
        reset: reset,
        uartRx: uartRx,
        core0Binary: c0Bin,
        core1Binary: c1Bin,
        core2Binary: c2Bin,
        core3Binary: c3Bin,
      );

      await top.build();
    });

    test("Host drives serial character into uartRx and Core 0 echoes to uartTx", () async {
      reset.put(1);
      uartRx.put(1);

      unawaited(Simulator.run());

      // Reset sequence
      await clk.waitCycles(5);
      reset.put(0);

      // Settle
      await clk.waitCycles(10);

      const testChar = 75; // ASCII 'K' (0x4B)
      const baudDivisor = 8;

      // Send Start bit (Low)
      uartRx.put(0);
      await clk.waitCycles(baudDivisor);

      // Send 8 data bits LSB first
      for (int i = 0; i < 8; i++) {
        uartRx.put((testChar >> i) & 1);
        await clk.waitCycles(baudDivisor);
      }

      // Send Stop bit (High)
      uartRx.put(1);

      // Wait for echo start bit
      bool sawTxStart = false;
      for (int i = 0; i < 200; i++) {
        if (top.uartTx.value.toInt() == 0) {
          sawTxStart = true;
          break;
        }
        await clk.waitCycles(1);
      }
      expect(sawTxStart, isTrue, reason: "Core 0 should echo received character back over uartTx");

      // Advance to center of start bit
      await clk.waitCycles(baudDivisor ~/ 2);

      // Sample 8 data bits
      int receivedByte = 0;
      for (int i = 0; i < 8; i++) {
        await clk.waitCycles(baudDivisor);
        receivedByte |= (top.uartTx.value.toInt() << i);
      }

      // Stop bit
      await clk.waitCycles(baudDivisor);

      expect(receivedByte, equals(testChar));

      await Simulator.endSimulation();
    });
  });
}
DART_EOF

echo "==> 4. Updating hdl/parcore/test/parcore_top_test.dart..."
cat << 'DART_EOF' > hdl/parcore/test/parcore_top_test.dart
import "dart:async";
import "dart:io";
import "package:rohd/rohd.dart";
import "package:test/test.dart";
import "../../rohd/test/test_helpers.dart";
import "../lib/parcore_top.dart";

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

      final c0 = _loadBinary('../../build/parcore/riscv/core0_if_uart.bin');
      final c1 = _loadBinary('../../build/parcore/riscv/core1_id.bin');
      final c2 = _loadBinary('../../build/parcore/riscv/core2_ex.bin');
      final c3 = _loadBinary('../../build/parcore/riscv/core3_mem.bin');

      top = ParcoreTop(
        clk: clk.clk,
        reset: reset,
        uartRx: uartRx,
        core0Binary: c0,
        core1Binary: c1,
        core2Binary: c2,
        core3Binary: c3,
      );

      await top.build();
    });

    test("ParcoreTop elaborates, builds synthesis graph, and generates SystemVerilog", () {
      final sv = top.generateSynth();
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

    test("Host-to-Core-0 UART Echo: transmits 0x41 on uartRx and verifies echo on uartTx", () async {
      reset.put(1);
      uartRx.put(1);

      unawaited(Simulator.run());

      await clk.waitCycles(5);
      reset.put(0);

      await clk.waitCycles(10);

      const testByte = 0x41; // ASCII 'A'
      const baudCycles = 8;

      // Start bit (Low)
      uartRx.put(0);
      await clk.waitCycles(baudCycles);

      // 8 Data Bits (LSB first)
      for (int b = 0; b < 8; b++) {
        uartRx.put((testByte >> b) & 1);
        await clk.waitCycles(baudCycles);
      }

      // Stop bit (High)
      uartRx.put(1);

      // Wait for echo start bit
      bool sawStart = false;
      for (int i = 0; i < 200; i++) {
        if (top.uartTx.value.toInt() == 0) {
          sawStart = true;
          break;
        }
        await clk.waitCycles(1);
      }
      expect(sawStart, isTrue, reason: "Core 0 failed to drive UART TX start bit low");

      // Advance to middle of start bit
      await clk.waitCycles(baudCycles ~/ 2);

      // Sample 8 data bits
      int echoedByte = 0;
      for (int b = 0; b < 8; b++) {
        await clk.waitCycles(baudCycles);
        echoedByte |= (top.uartTx.value.toInt() << b);
      }

      // Stop bit
      await clk.waitCycles(baudCycles);

      expect(echoedByte, equals(testByte), reason: "Core 0 failed to echo character back to UART TX");

      await Simulator.endSimulation();
    });
  });
}
DART_EOF

echo "==> 5. Running all tests across rohd and parcore..."
echo "--- Testing hdl/rohd ---"
cd hdl/rohd && dart test && cd ../..

echo "--- Testing hdl/parcore ---"
cd hdl/parcore && dart test && cd ../..

