// =============================================================================
// File: hdl/parcore/test/parcore_rv32_pipeline_test.dart
// Description: Runs RV32 guest programs on the four-stage Parcore pipeline and
//              checks the registers core 1 holds at the end.
//
// Two simulators run the same tests:
//   PARCORE_FAST_SIM=1   Verilator, on the generated SystemVerilog (fast).
//                        Uses $VERILATOR, or `verilator` on the PATH.
//   otherwise            The ROHD simulator, in Dart (no other tools; slower).
// `make test-parcore` uses Verilator; `make test-parcore PARCORE_FAST_SIM=0`
// uses ROHD.
//
// Every run lasts exactly maxCycles cycles: there is no early exit, so a slow
// instruction can't end a run before its result is written.
// =============================================================================

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:parcore_rohd/parcore_config.dart';
import 'package:parcore_rohd/parcore_tcm.dart';
import 'package:particle_rohd/block_ram_tdp.dart';
import 'package:parcore_rohd/parcore_top.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'rv32_reference.dart';

final bool useVerilator = Platform.environment['PARCORE_FAST_SIM'] == '1';

List<int> loadBinary(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    throw Exception('Binary not found: $path');
  }
  return file.readAsBytesSync();
}

typedef PipelineResult = ({Map<int, int> regs, int cycles, String stdout});

/// Runs a guest program (already merged into core 0's image) for [maxCycles]
/// cycles and returns core 1's architectural registers x0..x31.
Future<PipelineResult> runPipeline({
  required Uint8List c0Merged,
  required List<int> c1Kernel,
  required List<int> c2Kernel,
  required List<int> c3Kernel,
  int maxCycles = 25000,
}) =>
    useVerilator
        ? runVerilatorPipeline(
            c0Merged: c0Merged,
            c1Kernel: c1Kernel,
            c2Kernel: c2Kernel,
            c3Kernel: c3Kernel,
            maxCycles: maxCycles)
        : runRohdPipeline(
            c0Merged: c0Merged,
            c1Kernel: c1Kernel,
            c2Kernel: c2Kernel,
            c3Kernel: c3Kernel,
            maxCycles: maxCycles);

// -----------------------------------------------------------------------------
// ROHD simulator
// -----------------------------------------------------------------------------

Future<PipelineResult> runRohdPipeline({
  required Uint8List c0Merged,
  required List<int> c1Kernel,
  required List<int> c2Kernel,
  required List<int> c3Kernel,
  required int maxCycles,
}) async {
  await Simulator.reset();
  final clk = SimpleClockGenerator(10).clk;
  final reset = Logic(name: 'reset');
  final uartRx = Logic(name: 'uart_rx');
  final top = ParcoreTop(
    clk: clk,
    reset: reset,
    uartRx: uartRx,
    core0Binary: c0Merged,
    core1Binary: c1Kernel,
    core2Binary: c2Kernel,
    core3Binary: c3Kernel,
  );
  await top.build();

  ParcoreTcm? core1Tcm;
  void find(Module m) {
    for (final s in m.subModules) {
      if (s is ParcoreTcm && s.name == 'core1_tcm') core1Tcm = s;
      find(s);
    }
  }
  find(top);
  if (core1Tcm == null) throw StateError('core1_tcm not found in ParcoreTop');

  reset.inject(1);
  uartRx.inject(1);
  Simulator.setMaxSimTime(10 * (maxCycles + 10));
  unawaited(Simulator.run());
  for (var i = 0; i < 4; i++) {
    await clk.nextPosedge;
  }
  reset.inject(0);
  for (var i = 4; i < maxCycles; i++) {
    await clk.nextPosedge;
  }
  await Simulator.endSimulation();
  await Simulator.simulationEnded;

  final regs = <int, int>{};
  final out = StringBuffer();
  for (var r = 0; r < 32; r++) {
    regs[r] = core1Tcm!.readWord(r * 4);
    out.writeln('R$r=0x${regs[r]!.toRadixString(16).padLeft(8, '0')}');
  }
  out.writeln('SCOREBOARD=0x${core1Tcm!.readWord(0x80).toRadixString(16)}');
  return (regs: regs, cycles: maxCycles, stdout: out.toString());
}

// -----------------------------------------------------------------------------
// Verilator
// -----------------------------------------------------------------------------

const _verilatorDir = '/tmp/parcore_pipeline_verilator';

/// The generated SystemVerilog. Each TCM loads its contents with $readmemh
/// from `$_verilatorDir/<name>_tcm_bank0.hex` / `_bank1.hex`, which each run
/// writes, so the model is built once for every program.
Future<String> _pipelineSystemVerilog() async {
  final top = ParcoreTop(
    clk: Logic(name: 'clk'),
    reset: Logic(name: 'reset'),
    uartRx: Logic(name: 'uart_rx'),
    core0Binary: Uint8List(8192),
    core1Binary: Uint8List(4096),
    core2Binary: Uint8List(4096),
    core3Binary: Uint8List(4096),
    tcmInitDir: _verilatorDir,
  );
  await top.build();
  final sv = top.generateSynth();
  await Simulator.reset();
  return sv;
}

const _simMain = r"""
#include "VParcoreTop.h"
#include "VParcoreTop___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    VParcoreTop* top = new VParcoreTop;
    int max_cycles = 25000;
    if (const char* mc = std::getenv("MAX_CYCLES")) max_cycles = std::atoi(mc);

    top->clk = 0;
    top->reset = 1;
    top->uart_rx = 1;
    top->guest_text_end = 0x00000800;
    top->eval();

    // Each TCM is two 16-bit banks: bank 0 holds bits 15:0 of each word,
    // bank 1 bits 31:16
    auto& c0_b0 = top->rootp->ParcoreTop__DOT__core0_tcm__DOT__ram_bank0;
    auto& c0_b1 = top->rootp->ParcoreTop__DOT__core0_tcm__DOT__ram_bank1;
    auto& c1_b0 = top->rootp->ParcoreTop__DOT__core1_tcm__DOT__ram_bank0;
    auto& c1_b1 = top->rootp->ParcoreTop__DOT__core1_tcm__DOT__ram_bank1;
    auto word = [](auto& b0, auto& b1, int a) {
        return uint32_t(b0[a >> 2]) | (uint32_t(b1[a >> 2]) << 16);
    };

    // Every run lasts exactly max_cycles cycles
    int cyc;
    for (cyc = 1; cyc <= max_cycles; cyc++) {
        if (cyc == 5) top->reset = 0;
        top->clk = 1; top->eval();
        top->clk = 0; top->eval();
    }
    cyc--;

    std::printf("C0_500=0x%08x\n", word(c0_b0, c0_b1, 0x500));
    for (int a = 0; a < 0x100; a += 4) {
        uint32_t v = word(c1_b0, c1_b1, a);
        if (v != 0) std::printf("C1_MEM[0x%04x]=0x%08x\n", a, v);
    }
    std::printf("CYCLES=%d C0_PC=0x%04x C1_PC=0x%04x C2_PC=0x%04x C3_PC=0x%04x\n",
                cyc,
                top->rootp->ParcoreTop__DOT__core0_if__DOT__pc,
                top->rootp->ParcoreTop__DOT__core1_id__DOT__pc,
                top->rootp->ParcoreTop__DOT__core2_ex__DOT__pc,
                top->rootp->ParcoreTop__DOT__core3_mem__DOT__pc);
    std::printf("SCOREBOARD=0x%08x\n", word(c1_b0, c1_b1, 0x80));
    for (int r = 0; r < 32; r++) {
        std::printf("R%d=0x%08x\n", r, word(c1_b0, c1_b1, r * 4));
    }
    delete top;
    return 0;
}
""";

/// Builds the Verilator model, once per test run, and again whenever the
/// generated SystemVerilog or the C++ harness has changed since the last build.
Future<File>? _verilatorBuild;

Future<File> _buildVerilatorModel() async {
  final dir = Directory(_verilatorDir)..createSync(recursive: true);
  final binFile = File('$_verilatorDir/obj_dir/VParcoreTop');
  final svFile = File('$_verilatorDir/parcore_top.sv');
  final mainFile = File('$_verilatorDir/sim_main.cpp');

  final sv = await _pipelineSystemVerilog();
  final upToDate = binFile.existsSync() &&
      svFile.existsSync() &&
      svFile.readAsStringSync() == sv &&
      mainFile.existsSync() &&
      mainFile.readAsStringSync() == _simMain;
  if (upToDate) return binFile;

  svFile.writeAsStringSync(sv);
  mainFile.writeAsStringSync(_simMain);
  final objDir = Directory('$_verilatorDir/obj_dir');
  if (objDir.existsSync()) objDir.deleteSync(recursive: true);

  final verilator = Platform.environment['VERILATOR'] ?? 'verilator';
  final ProcessResult res;
  try {
    res = Process.runSync(
      verilator,
      [
        '--cc',
        '--exe',
        '--build',
        '-O3',
        '--public-flat-rw', // keeps the internal signals the harness reads
        '-Wno-fatal',
        '--top-module',
        'ParcoreTop',
        'parcore_top.sv',
        'sim_main.cpp',
        '-o',
        'VParcoreTop',
      ],
      workingDirectory: dir.path,
    );
  } on ProcessException catch (e) {
    throw Exception('Could not run Verilator ($verilator): ${e.message}. '
        'Put verilator on the PATH or set VERILATOR, or run with '
        'PARCORE_FAST_SIM=0 to use the ROHD simulator.');
  }
  if (res.exitCode != 0) {
    throw Exception('Verilator build failed:\n${res.stderr}');
  }
  return binFile;
}

Future<PipelineResult> runVerilatorPipeline({
  required Uint8List c0Merged,
  required List<int> c1Kernel,
  required List<int> c2Kernel,
  required List<int> c3Kernel,
  required int maxCycles,
}) async {
  final binFile = await (_verilatorBuild ??= _buildVerilatorModel());

  // Each TCM's two bank files, as ParcoreTop(tcmInitDir:) expects
  final images = <String, (List<int>, int)>{
    'conductor_tcm': (const [], ParcoreConfig.conductorConfig.tcmSizeBytes),
    'core0_tcm': (c0Merged, ParcoreConfig.core0If.tcmSizeBytes),
    'core1_tcm': (c1Kernel, ParcoreConfig.core1Id.tcmSizeBytes),
    'core2_tcm': (c2Kernel, ParcoreConfig.core2Ex.tcmSizeBytes),
    'core3_tcm': (c3Kernel, ParcoreConfig.core3Mem.tcmSizeBytes),
  };
  for (final e in images.entries) {
    final (bytes, size) = e.value;
    final (bank0, bank1) = ParticleBlockRamTdp.bankFiles(bytes,
        loadOffset: 0x100, depthWords: size ~/ 4);
    File('$_verilatorDir/${e.key}_bank0.hex').writeAsStringSync(bank0);
    File('$_verilatorDir/${e.key}_bank1.hex').writeAsStringSync(bank1);
  }

  final runRes = Process.runSync(
    binFile.path,
    const [],
    environment: {'MAX_CYCLES': '$maxCycles'},
  );
  if (runRes.exitCode != 0) {
    throw Exception('Verilator run failed:\n${runRes.stderr}');
  }

  final out = '${runRes.stdout}';
  final cycMatch = RegExp(r'CYCLES=(\d+)').firstMatch(out);
  final cycles = cycMatch != null ? int.parse(cycMatch.group(1)!) : 0;
  final regs = <int, int>{};
  for (final m in RegExp(r'^R(\d+)=0x([0-9a-fA-F]+)', multiLine: true).allMatches(out)) {
    regs[int.parse(m.group(1)!)] = int.parse(m.group(2)!, radix: 16);
  }
  return (regs: regs, cycles: cycles, stdout: out);
}

/// Checks x1..x31 against the RV32 reference model running the same guest
/// program (with core 3's image as the data memory, as on the hardware).
void expectMatchesReference(PipelineResult res, List<int> guestProg, List<int> c3Kernel) {
  final ref = runRv32Reference(guestProg, dataImage: c3Kernel);
  for (var r = 1; r < 32; r++) {
    expect(res.regs[r]! & 0xFFFFFFFF, equals(ref.regs[r]),
        reason: 'x$r differs from the RV32 reference '
            '(${ref.steps} guest instructions)');
  }
}

Uint8List mergeCore0WithGuest(List<int> c0Kernel, List<int> guestProg) {
  final c0Merged = Uint8List(0x2000);
  for (int i = 0; i < c0Kernel.length; i++) {
    c0Merged[i] = c0Kernel[i];
  }
  const guestOffsetInTcm = 0x0500 - 0x0100;
  for (int i = 0; i < guestProg.length; i++) {
    c0Merged[guestOffsetInTcm + i] = guestProg[i];
  }
  return c0Merged;
}

Uint8List encodeWords(List<int> words) {
  final bytes = Uint8List(words.length * 4);
  for (int i = 0; i < words.length; i++) {
    final w = words[i];
    bytes[i * 4] = w & 0xFF;
    bytes[i * 4 + 1] = (w >> 8) & 0xFF;
    bytes[i * 4 + 2] = (w >> 16) & 0xFF;
    bytes[i * 4 + 3] = (w >> 24) & 0xFF;
  }
  return bytes;
}

void main() {
  late List<int> c0Kernel;
  late List<int> c1Kernel;
  late List<int> c2Kernel;
  late List<int> c3Kernel;

  setUpAll(() {
    c0Kernel = loadBinary('../../build/parcore/riscv/core0_if_uart.bin');
    c1Kernel = loadBinary('../../build/parcore/riscv/core1_id.bin');
    c2Kernel = loadBinary('../../build/parcore/riscv/core2_ex.bin');
    c3Kernel = loadBinary('../../build/parcore/riscv/core3_mem.bin');
  });

  group('Parcore RV32IM Guest Program Execution', () {
    test('Guest instructions retire into Core 1 architectural registers (all 32, against the RV32 reference)', () async {
      final guestProg = loadBinary('../../build/guest_rv32_test.bin');
      final res = await runPipeline(
        c0Merged: mergeCore0WithGuest(c0Kernel, guestProg),
        c1Kernel: c1Kernel,
        c2Kernel: c2Kernel,
        c3Kernel: c3Kernel,
        maxCycles: 35000,
      );
      print('Completed in ${res.cycles} cycles | stdout:\n${res.stdout}');
      // The program's later parts reuse x1..x31, so only the final values
      // (from the reference model) are meaningful
      expectMatchesReference(res, guestProg, c3Kernel);
    });

    test('Guest instructions - Signed Division & Remainder Edge Cases', () async {
      final guestProg = loadBinary('../../build/guest_rv32_signed_div.bin');
      final res = await runPipeline(
        c0Merged: mergeCore0WithGuest(c0Kernel, guestProg),
        c1Kernel: c1Kernel,
        c2Kernel: c2Kernel,
        c3Kernel: c3Kernel,
        maxCycles: 20000,
      );
      final regs = res.regs;
      print('Signed division completed in ${res.cycles} cycles');
      expect(regs[1]! & 0xFFFFFFFF, equals(0xFFFFFFEC)); // -20
      expect(regs[2]! & 0xFFFFFFFF, equals(0x00000003)); // 3
      expect(regs[3]! & 0xFFFFFFFF, equals(0xFFFFFFFD)); // -3
      expect(regs[6]! & 0xFFFFFFFF, equals(0xFFFFFFFA)); // -20 / 3 = -6
      expect(regs[7]! & 0xFFFFFFFF, equals(0xFFFFFFFE)); // -20 % 3 = -2
      expect(regs[8]! & 0xFFFFFFFF, equals(0xFFFFFFFA)); // 20 / -3 = -6
      expect(regs[9]! & 0xFFFFFFFF, equals(0x00000002)); // 20 % -3 = 2
      expect(regs[10]! & 0xFFFFFFFF, equals(0x00000006)); // -20 / -3 = 6
      expect(regs[11]! & 0xFFFFFFFF, equals(0xFFFFFFFE)); // -20 % -3 = -2
      expect(regs[14]! & 0xFFFFFFFF, equals(0x80000000)); // INT_MIN / -1 = INT_MIN
      expect(regs[15]! & 0xFFFFFFFF, equals(0x00000000)); // INT_MIN % -1 = 0
      expect(regs[16]! & 0xFFFFFFFF, equals(0x00000014)); // 20 % 0 = 20
      expect(regs[17]! & 0xFFFFFFFF, equals(0x00000014)); // 20 %u 0 = 20
      expectMatchesReference(res, guestProg, c3Kernel);
    });

    test('Guest instructions - Multiply High & Full RV32M (MUL, MULH, MULHSU, MULHU)', () async {
      final guestProg = loadBinary('../../build/guest_rv32_mul_test.bin');
      final res = await runPipeline(
        c0Merged: mergeCore0WithGuest(c0Kernel, guestProg),
        c1Kernel: c1Kernel,
        c2Kernel: c2Kernel,
        c3Kernel: c3Kernel,
        maxCycles: 15000,
      );
      final regs = res.regs;
      print('Multiply test completed in ${res.cycles} cycles | stdout:\n${res.stdout}');
      expect(regs[7]! & 0xFFFFFFFF, equals(0xFFFFFFC4));
      expectMatchesReference(res, guestProg, c3Kernel);
    });

    test('Guest instructions - Sub-word Memory Access (LB, LBU, LH, LHU, LW, SB, SH, SW)', () async {
      final guestProg = loadBinary('../../build/guest_rv32_mem_test.bin');
      final res = await runPipeline(
        c0Merged: mergeCore0WithGuest(c0Kernel, guestProg),
        c1Kernel: c1Kernel,
        c2Kernel: c2Kernel,
        c3Kernel: c3Kernel,
        maxCycles: 15000,
      );
      final regs = res.regs;
      print('Sub-word memory test completed in ${res.cycles} cycles | stdout:\n${res.stdout}');
      expect(regs[6]! & 0xFFFFFFFF, equals(0x5A));
      expect(regs[7]! & 0xFFFFFFFF, equals(0xFFFFFFF2));
      expectMatchesReference(res, guestProg, c3Kernel);
    });

    test('Guest instructions - Control Transfer & Pipeline Flushing (BEQ, BNE, BLT, BGEU, JAL, JALR)', () async {
      final guestProg = loadBinary('../../build/guest_rv32_branch.bin');
      final res = await runPipeline(
        c0Merged: mergeCore0WithGuest(c0Kernel, guestProg),
        c1Kernel: c1Kernel,
        c2Kernel: c2Kernel,
        c3Kernel: c3Kernel,
        maxCycles: 15000,
      );
      final regs = res.regs;
      print('Branch redirect test completed in ${res.cycles} cycles | stdout:\n${res.stdout}');
      // Values before the first branch
      expect(regs[1]! & 0xFFFFFFFF, equals(10));
      expect(regs[2]! & 0xFFFFFFFF, equals(10));
      // Each taken branch skips its poison instructions (addi xN, x0, 0xBAD)
      // and lands on the target, and the not-taken BNE falls through
      expect(regs[3]! & 0xFFFFFFFF, equals(0x42), reason: 'BEQ taken');
      expect(regs[4]! & 0xFFFFFFFF, equals(0x55), reason: 'BNE not taken');
      expect(regs[5]! & 0xFFFFFFFF, equals(0xFFFFFFFB));
      expect(regs[6]! & 0xFFFFFFFF, equals(5));
      expect(regs[7]! & 0xFFFFFFFF, equals(0x77), reason: 'BLT taken');
      expect(regs[8]! & 0xFFFFFFFF, equals(0x88), reason: 'BGEU taken');
      expect(regs[9]! & 0xFFFFFFFF, equals(0x54C), reason: 'JAL link');
      expect(regs[10]! & 0xFFFFFFFF, equals(0x99), reason: 'JAL target');
      expect(regs[11]! & 0xFFFFFFFF, equals(0x564));
      expect(regs[12]! & 0xFFFFFFFF, equals(0x560), reason: 'JALR link');
      expect(regs[13]! & 0xFFFFFFFF, equals(0xAA), reason: 'JALR target');
      expectMatchesReference(res, guestProg, c3Kernel);
    });

    test('Guest instructions - System & CSR Architecture (CSRRW, CSRRS, CSRRC, CSRRWI)', () async {
      // Guest RV32 CSR test sequence (mscratch = 0x340):
      // lui x1, 0x12345; addi x1, x1, 0x678 -> x1 = 0x12345678
      // csrrw x2, mscratch, x1 -> x2 = 0, mscratch = 0x12345678
      // csrrs x3, mscratch, x0 -> x3 = 0x12345678
      // addi x4, x0, 0x0f; csrrs x5, mscratch, x4 -> x5 = 0x12345678, mscratch = 0x1234567f
      // addi x6, x0, 0x0f; csrrc x7, mscratch, x6 -> x7 = 0x1234567f, mscratch = 0x12345670
      // csrrs x8, mscratch, x0 -> x8 = 0x12345670
      // csrrwi x9, mscratch, 0x12 -> x9 = 0x12345670, mscratch = 0x12
      // csrrsi x10, mscratch, 0x08 -> x10 = 0x12, mscratch = 0x1a
      // csrrs x10, mscratch, x0 -> x10 = 0x1a
      final guestInstructions = <int>[
        0x123450b7, // lui x1, 0x12345
        0x67808093, // addi x1, x1, 0x678
        0x34009173, // csrrw x2, mscratch, x1
        0x340021f3, // csrrs x3, mscratch, x0
        0x00f00213, // addi x4, x0, 0x0f
        0x340222f3, // csrrs x5, mscratch, x4
        0x00f00313, // addi x6, x0, 0x0f
        0x340333f3, // csrrc x7, mscratch, x6
        0x34002473, // csrrs x8, mscratch, x0
        0x340954f3, // csrrwi x9, mscratch, 0x12
        0x34046573, // csrrsi x10, mscratch, 0x08
        0x34002573, // csrrs x10, mscratch, x0
      ];
      final guestProg = encodeWords(guestInstructions);
      final res = await runPipeline(
        c0Merged: mergeCore0WithGuest(c0Kernel, guestProg),
        c1Kernel: c1Kernel,
        c2Kernel: c2Kernel,
        c3Kernel: c3Kernel,
        maxCycles: 15000,
      );
      final regs = res.regs;
      print('System & CSR test completed in ${res.cycles} cycles');
      expect(regs[2]! & 0xFFFFFFFF, equals(0x0), reason: 'csrrw old val');
      expect(regs[3]! & 0xFFFFFFFF, equals(0x12345678), reason: 'csrrs read val');
      expect(regs[5]! & 0xFFFFFFFF, equals(0x12345678), reason: 'csrrs set old val');
      expect(regs[7]! & 0xFFFFFFFF, equals(0x1234567F), reason: 'csrrc clr old val');
      expect(regs[8]! & 0xFFFFFFFF, equals(0x12345670), reason: 'csrrs clr result');
      expect(regs[9]! & 0xFFFFFFFF, equals(0x12345670), reason: 'csrrwi old val');
      expect(regs[10]! & 0xFFFFFFFF, equals(0x1A), reason: 'csrrsi result');
      expectMatchesReference(res, guestProg, c3Kernel);
    });
  });
}
