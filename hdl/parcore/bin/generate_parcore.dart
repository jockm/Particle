// =============================================================================
// File: hdl/parcore/bin/generate_parcore.dart
// Description: Synthesizable SystemVerilog generator for Parcore 4-stage CPU.
// =============================================================================

import 'dart:io';
import 'package:rohd/rohd.dart';
import '../lib/parcore_top.dart';

Future<void> main() async {
  print('==================================================================');
  print('Parcore: Generating Distributed 4-Stage SystemVerilog via ROHD...');
  print('==================================================================');

  final clk = Logic(name: 'clk');
  final reset = Logic(name: 'reset');
  final uartRx = Logic(name: 'uart_rx');

  final parcore = ParcoreTop(
    clk: clk,
    reset: reset,
    uartRx: uartRx,
  );

  await parcore.build();

  final svCode = parcore.generateSynth();

  final outputFile = File('parcore_top.sv');
  await outputFile.writeAsString(svCode);

  print(
      'Emission complete: Synthesizable SystemVerilog written to "${outputFile.path}".');
}
