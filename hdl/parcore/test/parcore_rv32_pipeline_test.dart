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
    core3Binary: Uint8List(8192),
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
                top->rootp->ParcoreTop__DOT__core0_if__DOT__ePc,
                top->rootp->ParcoreTop__DOT__core1_id__DOT__ePc,
                top->rootp->ParcoreTop__DOT__core2_ex__DOT__ePc,
                top->rootp->ParcoreTop__DOT__core3_mem__DOT__ePc);
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
/// program (with core 3's image, its kernel and the guest program, as the data
/// memory, as on the hardware).
void expectMatchesReference(PipelineResult res, List<int> guestProg, List<int> c3Kernel) {
  final ref = runRv32Reference(guestProg,
      dataImage: mergeCore3WithGuest(c3Kernel, guestProg),
      dataBytes: ParcoreConfig.core3Mem.tcmSizeBytes);
  for (var r = 1; r < 32; r++) {
    expect(res.regs[r]! & 0xFFFFFFFF, equals(ref.regs[r]),
        reason: 'x$r differs from the RV32 reference '
            '(${ref.steps} guest instructions)');
  }
}

/// A core's kernel (at 0x100) with the guest program at 0x500; the array
/// starts at 0x100. Core 0 and core 3 both hold the guest program: one guest
/// memory, kept the same in both by core 3's store mirror.
Uint8List _mergeWithGuest(List<int> kernel, List<int> guestProg, int tcmSize) {
  final merged = Uint8List(tcmSize - 0x0100);
  for (int i = 0; i < kernel.length; i++) {
    merged[i] = kernel[i];
  }
  const guestOffsetInTcm = 0x0500 - 0x0100;
  for (int i = 0; i < guestProg.length; i++) {
    merged[guestOffsetInTcm + i] = guestProg[i];
  }
  return merged;
}

Uint8List mergeCore0WithGuest(List<int> c0Kernel, List<int> guestProg) =>
    _mergeWithGuest(c0Kernel, guestProg, ParcoreConfig.core0If.tcmSizeBytes);

Uint8List mergeCore3WithGuest(List<int> c3Kernel, List<int> guestProg) =>
    _mergeWithGuest(c3Kernel, guestProg, ParcoreConfig.core3Mem.tcmSizeBytes);

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
    c0Kernel = loadBinary('../../build/parcore/riscv/core0_if.bin');
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
        c3Kernel: mergeCore3WithGuest(c3Kernel, guestProg),
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
        c3Kernel: mergeCore3WithGuest(c3Kernel, guestProg),
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
        c3Kernel: mergeCore3WithGuest(c3Kernel, guestProg),
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
        c3Kernel: mergeCore3WithGuest(c3Kernel, guestProg),
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
        c3Kernel: mergeCore3WithGuest(c3Kernel, guestProg),
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
        c3Kernel: mergeCore3WithGuest(c3Kernel, guestProg),
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

    test('Guest instructions - illegal instructions trap (mcause 2, mtval, mepc); WFI does nothing', () async {
      // SRET (a SYSTEM encoding Parcore doesn't support) and 0xFFFFFFFF (an
      // unknown opcode) each trap to mtvec with mcause 2, mtval = the
      // instruction and mepc = its address; the instruction after neither
      // runs. WFI before them does nothing. The RV32 reference model has no
      // traps, so the test checks the registers itself.
      final guestInstructions = <int>[
        0x00000297, // auipc x5, 0            ; x5 = 0x500
        0x04028293, // addi x5, x5, 0x40      ; handler at 0x540
        0x30529073, // csrrw x0, mtvec, x5
        0x00100313, // addi x6, x0, 1
        0x10500073, // wfi                    ; 0x510: a no-op
        0x00130313, // addi x6, x6, 1         ; x6 = 2
        0x10200073, // sret                   ; 0x518: not supported: illegal, mtval = 0x10200073
        0x00700393, // addi x7, x0, 7         ; skipped: the handler does not return
        0x00000000, // (core 0 stops here until the trap redirects it)
        0x00000000, // (core 0 stops here until the trap redirects it)
        0x00000000, // (core 0 stops here until the trap redirects it)
        0x00000000, // (core 0 stops here until the trap redirects it)
        0x00000000, // (core 0 stops here until the trap redirects it)
        0x00000000, // (core 0 stops here until the trap redirects it)
        0x00000000, // (core 0 stops here until the trap redirects it)
        0x00000000, // (core 0 stops here until the trap redirects it)
        0x34202573, // csrrs x10, mcause, x0  ; 0x540: handler 1
        0x343025f3, // csrrs x11, mtval, x0
        0x34102673, // csrrs x12, mepc, x0
        0x04028293, // addi x5, x5, 0x40      ; handler 2 at 0x580
        0x30529073, // csrrw x0, mtvec, x5
        0xffffffff, // .word 0xFFFFFFFF       ; 0x554: unknown opcode: illegal
        0x00700393, // addi x7, x0, 7         ; skipped
        0x00000000, // (core 0 stops here until the trap redirects it)
        0x00000000, // (core 0 stops here until the trap redirects it)
        0x00000000, // (core 0 stops here until the trap redirects it)
        0x00000000, // (core 0 stops here until the trap redirects it)
        0x00000000, // (core 0 stops here until the trap redirects it)
        0x00000000, // (core 0 stops here until the trap redirects it)
        0x00000000, // (core 0 stops here until the trap redirects it)
        0x00000000, // (core 0 stops here until the trap redirects it)
        0x00000000, // (core 0 stops here until the trap redirects it)
        0x342026f3, // csrrs x13, mcause, x0  ; 0x580: handler 2
        0x34302773, // csrrs x14, mtval, x0
        0x341027f3, // csrrs x15, mepc, x0
      ];
      final guestProg = encodeWords(guestInstructions);
      final res = await runPipeline(
        c0Merged: mergeCore0WithGuest(c0Kernel, guestProg),
        c1Kernel: c1Kernel,
        c2Kernel: c2Kernel,
        c3Kernel: mergeCore3WithGuest(c3Kernel, guestProg),
        maxCycles: 20000,
      );
      final regs = res.regs;
      int x(int n) => regs[n]! & 0xFFFFFFFF;
      expect(x(6), equals(2), reason: 'WFI did nothing');
      expect(x(7), equals(0), reason: 'nothing after a trapping instruction ran');
      expect(x(10), equals(2), reason: 'SRET: mcause');
      expect(x(11), equals(0x10200073), reason: 'SRET: mtval');
      expect(x(12), equals(0x518), reason: 'SRET: mepc');
      expect(x(13), equals(2), reason: '0xFFFFFFFF: mcause');
      expect(x(14), equals(0xFFFFFFFF), reason: '0xFFFFFFFF: mtval');
      expect(x(15), equals(0x554), reason: '0xFFFFFFFF: mepc');
    });

    test('Guest instructions - invalid encodings within known opcodes trap', () async {
      // Each ILLEGAL word below has a known opcode but an invalid funct3,
      // funct7 or rs2: it must trap (mcause 2). The handler at 0x504 counts
      // the traps in x20, adds up their mtval in x21, and resumes after the
      // instruction. The valid encodings beside them must not trap.
      final guestInstructions = <int>[
        0x0240006f, // jal x0, +0x24          ; to 0x524 (start)
        0x34302373, // csrrs x6, mtval, x0    ; 0x504: handler
        0x006a8ab3, // add x21, x21, x6       ; sum of mtvals
        0x001a0a13, // addi x20, x20, 1       ; count
        0x341022f3, // csrrs x5, mepc, x0
        0x00428293, // addi x5, x5, 4
        0x34129073, // csrrw x0, mepc, x5
        0x30200073, // mret                   ; resume after the illegal instruction
        0x00000000, // (never reached)
        0x00000297, // auipc x5, 0            ; 0x524
        0xfe028293, // addi x5, x5, -0x20     ; 0x504
        0x30529073, // csrrw x0, mtvec, x5
        0x000014b7, // lui x9, 0x1
        0x90048493, // addi x9, x9, -0x700    ; x9 = 0x900, a data address
        0x00301393, // valid:   slli x7, x0, 3
        0x02301393, // ILLEGAL: OP-IMM funct3 1, funct7 0x01
        0x00305393, // valid:   srli x7, x0, 3
        0x40305393, // valid:   srai x7, x0, 3
        0x60305393, // valid:   rori x7, x0, 3
        0x20305393, // ILLEGAL: OP-IMM funct3 5, funct7 0x10
        0x400003b3, // valid:   sub x7, x0, x0
        0x400053b3, // valid:   sra x7, x0, x0
        0x400073b3, // valid:   andn x7, x0, x0
        0x400013b3, // ILLEGAL: OP funct7 0x20, funct3 1
        0x600013b3, // valid:   rol x7, x0, x0
        0x600053b3, // valid:   ror x7, x0, x0
        0x600023b3, // ILLEGAL: OP funct7 0x30, funct3 2
        0x0a0043b3, // valid:   min x7, x0, x0
        0x0a0073b3, // valid:   maxu x7, x0, x0
        0x0a0003b3, // ILLEGAL: OP funct7 0x05, funct3 0
        0x080043b3, // valid:   zext.h x7, x0
        0x081043b3, // ILLEGAL: OP funct7 0x04, funct3 4, rs2 1
        0x080003b3, // ILLEGAL: OP funct7 0x04, funct3 0
        0x020003b3, // valid:   mul x7, x0, x0
        0x000003b3, // valid:   add x7, x0, x0
        0x040003b3, // ILLEGAL: OP funct7 0x02
        0x00048383, // valid:   lb x7, 0(x9)
        0x00049383, // valid:   lh x7, 0(x9)
        0x0004a383, // valid:   lw x7, 0(x9)
        0x0004c383, // valid:   lbu x7, 0(x9)
        0x0004d383, // valid:   lhu x7, 0(x9)
        0x0004b383, // ILLEGAL: LOAD funct3 3
        0x0004e383, // ILLEGAL: LOAD funct3 6
        0x0004f383, // ILLEGAL: LOAD funct3 7
        0x00048023, // valid:   sb x0, 0(x9)
        0x00049023, // valid:   sh x0, 0(x9)
        0x0004a023, // valid:   sw x0, 0(x9)
        0x0004b023, // ILLEGAL: STORE funct3 3
        0x00000263, // valid:   beq x0, x0, +4
        0x00001263, // valid:   bne x0, x0, +4
        0x00004263, // valid:   blt x0, x0, +4
        0x00005263, // valid:   bge x0, x0, +4
        0x00006263, // valid:   bltu x0, x0, +4
        0x00007263, // valid:   bgeu x0, x0, +4
        0x00002263, // ILLEGAL: BRANCH funct3 2
        0x00003263, // ILLEGAL: BRANCH funct3 3
        0x00001067, // ILLEGAL: JALR funct3 1
        0x0ff0000f, // valid:   fence
        0x0000200f, // ILLEGAL: MISC-MEM funct3 2
        0x340023f3, // valid:   csrrs x7, mscratch, x0
        0x340043f3, // ILLEGAL: SYSTEM funct3 4
        0x07700b13, // addi x22, x0, 0x77     ; reached the end
      ];
      final guestProg = encodeWords(guestInstructions);
      final res = await runPipeline(
        c0Merged: mergeCore0WithGuest(c0Kernel, guestProg),
        c1Kernel: c1Kernel,
        c2Kernel: c2Kernel,
        c3Kernel: mergeCore3WithGuest(c3Kernel, guestProg),
        maxCycles: 60000,
      );
      final regs = res.regs;
      int x(int n) => regs[n]! & 0xFFFFFFFF;
      expect(x(22), equals(0x77), reason: 'reached the end');
      expect(x(20), equals(17), reason: 'one trap per ILLEGAL word, none for the valid ones');
      expect(x(21), equals(0x1484F133), reason: 'the sum of the ILLEGAL words (mtval)');
    });

    test('Guest instructions - FENCE.I (code written with SW and SB, then run)', () async {
      // Writes a routine at 0x900 (addi x5, x0, 0x123 with SW; addi x6, x0,
      // 0x456 with four SBs; jalr x0, 0(x1) with SW), runs it after FENCE.I,
      // then replaces its first instruction (addi x5, x0, 0x321) and runs it
      // again. Core 0 only fetches the new code if core 3 mirrored the stores
      // into its TCM. The RV32 reference keeps code and data apart, so it
      // can't check this program.
      final guestInstructions = <int>[
0x00001537, // lui x10, 0x1
        0x90050513, // addi x10, x10, -1792
        0x123005b7, // lui x11, 0x12300
        0x29358593, // addi x11, x11, 659
        0x00b52023, // sw x11, 0(x10)     ; word store
        0x45600637, // lui x12, 0x45600
        0x31360613, // addi x12, x12, 787
        0x00c50223, // sb x12, 4(x10)     ; byte stores
        0x00865613, // srli x12, x12, 8
        0x00c502a3, // sb x12, 5(x10)     ; byte stores
        0x00865613, // srli x12, x12, 8
        0x00c50323, // sb x12, 6(x10)     ; byte stores
        0x00865613, // srli x12, x12, 8
        0x00c503a3, // sb x12, 7(x10)     ; byte stores
        0x000086b7, // lui x13, 0x8
        0x06768693, // addi x13, x13, 103
        0x00d52423, // sw x13, 8(x10)
        0x0000100f, // fence.i
        0x000500e7, // jalr x1, 0(x10)    ; x5 = 0x123, x6 = 0x456
        0x00028493, // addi x9, x5, 0
        0x321005b7, // lui x11, 0x32100
        0x29358593, // addi x11, x11, 659
        0x00b52023, // sw x11, 0(x10)     ; replace code already run
        0x0000100f, // fence.i
        0x000500e7, // jalr x1, 0(x10)    ; x5 = 0x321
        0x07700393, // addi x7, x0, 0x77
      ];
      final guestProg = encodeWords(guestInstructions);
      final res = await runPipeline(
        c0Merged: mergeCore0WithGuest(c0Kernel, guestProg),
        c1Kernel: c1Kernel,
        c2Kernel: c2Kernel,
        c3Kernel: mergeCore3WithGuest(c3Kernel, guestProg),
        maxCycles: 20000,
      );
      final regs = res.regs;
      print('FENCE.I test completed in ${res.cycles} cycles');
      expect(regs[9]! & 0xFFFFFFFF, equals(0x123), reason: 'first run, SW');
      expect(regs[6]! & 0xFFFFFFFF, equals(0x456), reason: 'first run, SB');
      expect(regs[5]! & 0xFFFFFFFF, equals(0x321),
          reason: 'second run sees the replaced instruction');
      expect(regs[7]! & 0xFFFFFFFF, equals(0x77), reason: 'returned twice');
    });
  });
}
