#!/usr/bin/env bash
set -e

cat << 'DART_DIAG' > hdl/parcore/test/diag_test.dart
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

  test("Diagnostic UART Execution Trace", () async {
    final clk = SimpleClockGenerator(10);
    final reset = Logic(name: 'reset');
    final uartRx = Logic(name: 'uart_rx');

    final c0 = _loadBinary('../../build/parcore/riscv/core0_if_uart.bin');
    final c1 = _loadBinary('../../build/parcore/riscv/core1_id.bin');
    final c2 = _loadBinary('../../build/parcore/riscv/core2_ex.bin');
    final c3 = _loadBinary('../../build/parcore/riscv/core3_mem.bin');

    final top = ParcoreTop(
      clk: clk.clk,
      reset: reset,
      uartRx: uartRx,
      core0Binary: c0,
      core1Binary: c1,
      core2Binary: c2,
      core3Binary: c3,
    );

    await top.build();

    reset.put(1);
    uartRx.put(1);

    unawaited(Simulator.run());

    await clk.waitCycles(5);
    reset.put(0);

    // Track signals directly from modules
    final uart = top.subModules.firstWhere((m) => m.name == 'parcore_ftdi_uart');
    final core0 = top.subModules.firstWhere((m) => m.name == 'core0_if');

    final c0Pc = core0.findByName('pc')!;
    final rxBufValid = uart.findByName('rxBufValid')!;
    final rxBuf = uart.findByName('rxBuf')!;
    final rxReceiving = uart.findByName('rxReceiving')!;
    final txBusy = uart.findByName('txBusy')!;
    final txValid = uart.findByName('txValid')!;

    // Send 'A' (0x41)
    const testByte = 0x41;
    const baudCycles = 8;

    // Run until byte sent
    uartRx.put(0);
    for (int i = 0; i < baudCycles; i++) {
      await clk.waitCycles(1);
    }
    for (int b = 0; b < 8; b++) {
      uartRx.put((testByte >> b) & 1);
      for (int i = 0; i < baudCycles; i++) {
        await clk.waitCycles(1);
      }
    }
    uartRx.put(1);

    // Watch for 60 cycles after transmission completes
    for (int cycle = 0; cycle < 60; cycle++) {
      await clk.waitCycles(1);
      print('Cycle $cycle: Core0 PC=0x${c0Pc.value.toInt().toRadixString(16)}, '
            'rxReceiving=${rxReceiving.value.toInt()}, '
            'rxBufValid=${rxBufValid.value.toInt()}, '
            'rxBuf=0x${rxBuf.value.toInt().toRadixString(16)}, '
            'txValid=${txValid.value.toInt()}, '
            'txBusy=${txBusy.value.toInt()}, '
            'uartTx=${top.uartTx.value.toInt()}');
      if (top.uartTx.value.toInt() == 0) {
        print(">>> SUCCESS: Detected uartTx == 0 at cycle $cycle!");
        break;
      }
    }

    await Simulator.endSimulation();
  });
}
DART_DIAG

cd hdl/parcore && dart test test/diag_test.dart -r expanded
