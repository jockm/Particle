// =============================================================================
// File: hdl/rohd/bin/generate.dart
// Architecture: Particle 32-bit RISC
// Description: Synthesizable SystemVerilog generator for Yosys / Lattice ECP5
//              synthesis targeting ULX3S FPGA platforms.
// =============================================================================

import 'dart:io';
import 'package:rohd/rohd.dart';
import '../lib/cpu_config.dart';
import '../lib/cpu_core.dart';

Future<void> main() async {
  print('==================================================================');
  print('Particle Processor: Generating Synthesizable Hardware via ROHD...');
  print('==================================================================');

  final clk = Logic(name: 'clk');
  final reset = Logic(name: 'reset');
  final memARData = Logic(name: 'memARData', width: 16);
  final memBRData = Logic(name: 'memBRData', width: 32);
  final mboxStrobe = Logic(name: 'mboxStrobe');
  final mboxVector = Logic(name: 'mboxVector', width: 4);

  final core = ParticleCpuCore(
    clk: clk,
    reset: reset,
    memPortARData: memARData,
    memPortBRData: memBRData,
    mboxStrobeIn: mboxStrobe,
    mboxVectorIn: mboxVector,
    config: const CpuConfig(coreId: 0),
  );

  await core.build();

  final svCode = core.generateSynth();

  final outputFile = File('particle_top.sv');
  await outputFile.writeAsString(svCode);

  print(
      'Emission complete: Synthesizable SystemVerilog written to "${outputFile.path}".');
}
