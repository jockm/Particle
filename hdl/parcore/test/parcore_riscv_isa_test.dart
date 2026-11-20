import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:parcore_rohd/parcore_config.dart';
import 'package:particle_rohd/block_ram_tdp.dart';
import 'package:parcore_rohd/parcore_tcm.dart';
import 'package:parcore_rohd/parcore_top.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

List<int> _loadBinary(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    throw Exception('Binary not found: $path');
  }
  return file.readAsBytesSync();
}


Future<({int x31, int gp, int a0, int cycles})> _runVerilatorSynth(
  ParcoreTop top,
  Uint8List c0Merged,
  List<int> c1Kernel,
  List<int> c2Kernel,
  Uint8List c3Merged,
  int maxCycles,
) async {
  final tmpDir = Directory('/tmp/parcore_verilator');
  if (!tmpDir.existsSync()) tmpDir.createSync(recursive: true);
  final binFile = File('${tmpDir.path}/obj_dir/VParcoreTop');

  // Build the Verilator model, and build it again whenever the generated
  // SystemVerilog or the C++ harness changes (a cached model would otherwise
  // keep simulating old hardware)
  {
    var sv = top.generateSynth();
    // Each TCM loads its contents with $readmemh from the bank files
    // written below (ParcoreTop(tcmInitDir: '/tmp/parcore_verilator')).
    final svFile = File('${tmpDir.path}/parcore_top.sv');
    final mainFile = File('${tmpDir.path}/sim_main.cpp');
    final simMain = """
#include "VParcoreTop.h"
#include "VParcoreTop___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    VParcoreTop* top = new VParcoreTop;
    int max_cycles = 150000;
    if (const char* mc = std::getenv("MAX_CYCLES")) max_cycles = std::atoi(mc);

    top->clk = 0;
    top->reset = 1;
    top->uart_rx = 1;
    top->eval();

    // Core 1's TCM is two 16-bit banks: bank 0 = bits 15:0 of each word
    auto read_c1_word = [&](uint32_t addr) -> uint32_t {
        auto& b0 = top->rootp->ParcoreTop__DOT__core1_tcm__DOT__ram_bank0;
        auto& b1 = top->rootp->ParcoreTop__DOT__core1_tcm__DOT__ram_bank1;
        return uint32_t(b0[addr >> 2]) | (uint32_t(b1[addr >> 2]) << 16);
    };

    int drain = -1;
    int cyc = 0;
    for (cyc = 1; cyc <= max_cycles; cyc++) {
        if (cyc == 5) top->reset = 0;
        top->clk = 1; top->eval();
        top->clk = 0; top->eval();

        if (drain > 0) {
            if (--drain == 0) break;
        } else if ((cyc & 0x3F) == 0) {
            uint32_t x31 = read_c1_word(0x0000 + 31 * 4);
            if (x31 == 0xCAFE0001 || (x31 & 0xFFFF0000) == 0xDEAD0000) {
                drain = 32;
            }
        }
    }
    uint32_t x31 = read_c1_word(0x0000 + 31 * 4);
    uint32_t gp  = read_c1_word(0x0000 + 3 * 4);
    uint32_t a0  = read_c1_word(0x0000 + 10 * 4);
    std::printf("RESULT x31=0x%08x gp=%u a0=0x%08x cyc=%d\\n", x31, gp, a0, cyc);
    delete top;
    return 0;
}
""";
    final upToDate = binFile.existsSync() &&
        svFile.existsSync() &&
        svFile.readAsStringSync() == sv &&
        mainFile.existsSync() &&
        mainFile.readAsStringSync() == simMain;
    if (!upToDate) {
      svFile.writeAsStringSync(sv);
      mainFile.writeAsStringSync(simMain);
      final objDir = Directory('${tmpDir.path}/obj_dir');
      if (objDir.existsSync()) objDir.deleteSync(recursive: true);
      // Verilator: \$VERILATOR, or `verilator` on the PATH
      final verilator = Platform.environment['VERILATOR'] ?? 'verilator';
      final res = Process.runSync(
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
        workingDirectory: tmpDir.path,
      );
      if (res.exitCode != 0) {
        throw Exception('Verilator build failed:\n${res.stderr}');
      }
    }
  }

  // Each TCM's two bank files, as ParcoreTop(tcmInitDir:) expects
  final images = <String, (List<int>, int)>{
    'conductor_tcm': (const [], ParcoreConfig.conductorConfig.tcmSizeBytes),
    'core0_tcm': (c0Merged, ParcoreConfig.core0If.tcmSizeBytes),
    'core1_tcm': (c1Kernel, ParcoreConfig.core1Id.tcmSizeBytes),
    'core2_tcm': (c2Kernel, ParcoreConfig.core2Ex.tcmSizeBytes),
    'core3_tcm': (c3Merged, ParcoreConfig.core3Mem.tcmSizeBytes),
  };
  for (final e in images.entries) {
    final (bytes, size) = e.value;
    final (bank0, bank1) = ParticleBlockRamTdp.bankFiles(bytes,
        loadOffset: 0x100, depthWords: size ~/ 4);
    File('${tmpDir.path}/${e.key}_bank0.hex').writeAsStringSync(bank0);
    File('${tmpDir.path}/${e.key}_bank1.hex').writeAsStringSync(bank1);
  }

  final runRes = Process.runSync(
    binFile.path,
    const [],
    environment: {'MAX_CYCLES': '$maxCycles'},
  );
  final out = '${runRes.stdout}';
  final m = RegExp(r'RESULT x31=0x([0-9a-fA-F]+) gp=(\d+) a0=0x([0-9a-fA-F]+) cyc=(\d+)').firstMatch(out);
  if (m == null) {
    throw Exception('Unexpected Verilator output:\n$out\n${runRes.stderr}');
  }
  return (
    x31: int.parse(m.group(1)!, radix: 16),
    gp: int.parse(m.group(2)!),
    a0: int.parse(m.group(3)!, radix: 16),
    cycles: int.parse(m.group(4)!),
  );
}

/// Tests that can't pass yet, with the reason.
const _knownGaps = <String, String>{};

void main() {
  tearDown(() async {
    if (Simulator.time > 0 && !Simulator.simulationHasEnded) {
      unawaited(Simulator.endSimulation());
    }
    await Simulator.reset();
  });

  final testsRoot = Directory('../../build/parcore/riscv_tests');
  final filter = Platform.environment['RISCV_TEST_FILTER'] ?? '';

  group('Official RISC-V ISA Tests (riscv-tests)', () {
    if (!testsRoot.existsSync()) {
      test('riscv-tests binaries built', () {
        fail(
          'Missing ../../build/parcore/riscv_tests. '
          'Run ./hdl/parcore/test/riscv_tests/build_riscv_tests.sh first.',
        );
      });
      return;
    }

    final suites = ['rv32ui', 'rv32um', 'rv32uzbb'];
    for (final suite in suites) {
      final suiteDir = Directory('${testsRoot.path}/$suite');
      if (!suiteDir.existsSync()) continue;

      // One image per test, loaded at 0x500: .text, then .data (link.ld)
      final imageFiles = suiteDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.image.bin'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

      group(suite, () {
        for (final imageFile in imageFiles) {
          final fileName = imageFile.uri.pathSegments.last;
          final testName = fileName.substring(
            0,
            fileName.length - '.image.bin'.length,
          );
          final fullId = '$suite/$testName';
          if (filter.isNotEmpty) {
            final matches = filter.contains('/')
                ? fullId == filter
                : (suite == filter || testName == filter);
            if (!matches) continue;
          }

          test(fullId, () async {
            await Simulator.reset();
            final clk = Logic(name: 'clk');
            final reset = Logic(name: 'reset');
            final uartRx = Logic(name: 'uart_rx');

            final c0Kernel =
                _loadBinary('../../build/parcore/riscv/core0_if.bin');
            final c1Kernel =
                _loadBinary('../../build/parcore/riscv/core1_id.bin');
            final c2Kernel =
                _loadBinary('../../build/parcore/riscv/core2_ex.bin');
            final c3Kernel =
                _loadBinary('../../build/parcore/riscv/core3_mem.bin');
            final imageBytes = imageFile.readAsBytesSync();

            // Core 0 and core 3 both get their kernel (at 0x100) and the guest
            // image (at 0x500): one guest memory, kept the same in both by
            // core 3's store mirror. Arrays start at 0x100.
            Uint8List withGuest(List<int> kernel, int tcmSize) {
              const guestOffset = 0x0500 - 0x0100;
              if (0x0500 + imageBytes.length > tcmSize) {
                throw StateError('$fullId: the guest image ends at 0x'
                    '${(0x500 + imageBytes.length).toRadixString(16)}, past '
                    'the ${tcmSize ~/ 1024} KiB TCM');
              }
              final merged = Uint8List(tcmSize - 0x0100);
              merged.setRange(0, kernel.length, kernel);
              merged.setRange(
                  guestOffset, guestOffset + imageBytes.length, imageBytes);
              return merged;
            }

            final c0Merged =
                withGuest(c0Kernel, ParcoreConfig.core0If.tcmSizeBytes);
            final c3Merged =
                withGuest(c3Kernel, ParcoreConfig.core3Mem.tcmSizeBytes);

            final top = ParcoreTop(
              clk: clk,
              reset: reset,
              uartRx: uartRx,
              core0Binary: c0Merged,
              core1Binary: c1Kernel,
              core2Binary: c2Kernel,
              core3Binary: c3Merged,
              tcmInitDir: '/tmp/parcore_verilator',
            );
            await top.build();

            if (Platform.environment['PARCORE_FAST_SIM'] == '1') {
              final r = await _runVerilatorSynth(
                top,
                c0Merged,
                c1Kernel,
                c2Kernel,
                c3Merged,
                450000,
              );
              stderr.writeln(
                '[FAST-SIM] $fullId finished in ${r.cycles} cycles: '
                'x31=0x${r.x31.toRadixString(16)}, gp=${r.gp}, a0=0x${r.a0.toRadixString(16)}',
              );
              expect(
                r.x31,
                equals(0xCAFE0001),
                reason:
                    '$fullId failed or timed out after ${r.cycles} cycles: '
                    'x31=0x${r.x31.toRadixString(16)}, TESTNUM (gp/x3)=${r.gp}, '
                    'a0=0x${r.a0.toRadixString(16)}',
              );
              expect(r.gp, equals(1), reason: '$fullId failed at TESTNUM = ${r.gp}');
              expect(
                r.a0,
                equals(0),
                reason: '$fullId non-zero a0 = 0x${r.a0.toRadixString(16)}',
              );
              return;
            }

            clk.put(0);
            reset.put(1);
            uartRx.put(1);

            const regBase = 0x0000;
            final c1Tcm = top.subModules
                .firstWhere((m) => m.name == 'core1_tcm') as ParcoreTcm;

            int x31 = 0;
            int totalCycles = 0;
            int lastGp = -1;
            int stallWindows = 0;
            final sw = Stopwatch()..start();
            const maxCycles = 150000;
            const sliceCycles = 2048;

            final c0Core = top.subModules.firstWhere((m) => m.name == 'core0_if');
            final c1Core = top.subModules.firstWhere((m) => m.name == 'core1_id');
            final c2Core = top.subModules.firstWhere((m) => m.name == 'core2_ex');
            final c3Core = top.subModules.firstWhere((m) => m.name == 'core3_mem');

            clk <= SimpleClockGenerator(10).clk;

            // Deassert reset at cycle 5 (t = 50)
            Simulator.registerAction(50, () => reset.put(0));

            void scheduleCheckpoint(int targetCycle) {
              Simulator.registerAction(targetCycle * 10, () async {
                totalCycles = targetCycle;
                await Future<void>.delayed(Duration.zero);

                x31 = c1Tcm.readWord(regBase + 31 * 4) & 0xFFFFFFFF;
                if (x31 == 0xCAFE0001 || (x31 & 0xFFFF0000) == 0xDEAD0000) {
                  Simulator.registerAction((totalCycles + 32) * 10, () {
                    totalCycles += 32;
                    unawaited(Simulator.endSimulation());
                  });
                  return;
                }

                if (totalCycles % 4096 == 0 || totalCycles >= 55000) {
                  final gpNow = c1Tcm.readWord(regBase + 3 * 4) & 0xFFFFFFFF;
                  final secs = sw.elapsed.inSeconds;
                  final mm = (secs ~/ 60).toString().padLeft(2, '0');
                  final ss = (secs % 60).toString().padLeft(2, '0');
                  stderr.writeln(
                    '[$mm:$ss] cyc=$totalCycles gp=$gpNow/38 x31=0x${x31.toRadixString(16)}',
                  );
                  if (gpNow == lastGp && totalCycles % 4096 == 0) {
                    stallWindows++;
                    final tpNow = c1Tcm.readWord(regBase + 4 * 4) & 0xFFFFFFFF;
                    final t0Now = c1Tcm.readWord(regBase + 5 * 4) & 0xFFFFFFFF;
                    final sbNow = c1Tcm.readWord(0x0080) & 0xFFFFFFFF;
                    stderr.writeln(
                      '  [STALL DIAG] tp=$tpNow t0=$t0Now sb=0x${sbNow.toRadixString(16)} '
                      'c0_pc=0x${c0Core.output('memPortAAddr').value.toInt().toRadixString(16)} '
                      'c1_pc=0x${c1Core.output('memPortAAddr').value.toInt().toRadixString(16)} '
                      'c2_pc=0x${c2Core.output('memPortAAddr').value.toInt().toRadixString(16)} '
                      'c3_pc=0x${c3Core.output('memPortAAddr').value.toInt().toRadixString(16)}',
                    );
                    if (stallWindows >= 2) {
                      unawaited(Simulator.endSimulation());
                      return;
                    }
                  } else if (gpNow != lastGp) {
                    lastGp = gpNow;
                    stallWindows = 0;
                  }
                }

                if (totalCycles >= maxCycles) {
                  unawaited(Simulator.endSimulation());
                  return;
                }

                final nextTarget = (totalCycles + sliceCycles) > maxCycles
                    ? maxCycles
                    : (totalCycles + sliceCycles);
                scheduleCheckpoint(nextTarget);
              });
            }

            Simulator.setMaxSimTime(maxCycles * 10 + 1000);
            scheduleCheckpoint(sliceCycles);
            await Simulator.run();

            x31 = c1Tcm.readWord(regBase + 31 * 4) & 0xFFFFFFFF;
            final gp = c1Tcm.readWord(regBase + 3 * 4) & 0xFFFFFFFF;
            final a0 = c1Tcm.readWord(regBase + 10 * 4) & 0xFFFFFFFF;

            expect(
              x31,
              equals(0xCAFE0001),
              reason:
                  '$fullId failed or timed out after $totalCycles cycles: '
                  'x31=0x${x31.toRadixString(16)}, TESTNUM (gp/x3)=$gp, '
                  'a0=0x${a0.toRadixString(16)}',
            );
            expect(gp, equals(1), reason: '$fullId failed at TESTNUM = $gp');
            expect(
              a0,
              equals(0),
              reason: '$fullId non-zero a0 = 0x${a0.toRadixString(16)}',
            );
          }, timeout: Timeout.none, skip: _knownGaps[fullId]);
        }
      });
    }
  });
}
