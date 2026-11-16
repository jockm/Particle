import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
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
  int guestTextEndAddr,
  int maxCycles,
) async {
  final tmpDir = Directory('/tmp/parcore_verilator');
  if (!tmpDir.existsSync()) tmpDir.createSync(recursive: true);
  final binFile = File('${tmpDir.path}/obj_dir/VParcoreTop');

  if (!binFile.existsSync()) {
    var sv = top.generateSynth();
    final tcmRegex = RegExp(
      r'module\s+(ParcoreTcm(?:_\d+)?)\s*\([^;]*\);[\s\S]*?endmodule',
    );
    sv = sv.replaceAllMapped(tcmRegex, (m) {
      final modName = m.group(1)!;
      return """
module $modName (
  input logic clk,
  input logic [15:0] addrA,
  output logic [15:0] rDataA,
  input logic [15:0] addrB,
  input logic [31:0] wDataB,
  input logic [3:0] bEnB,
  input logic wEnB,
  input logic rEnB,
  output logic [31:0] rDataB
);
  logic [7:0] mem [0:16383];
  string hexfile;
  initial begin
    for (int i = 0; i < 16384; i++) mem[i] = 8'h00;
    \$sformat(hexfile, "/tmp/parcore_verilator/%m.hex"); \$display("TCM LOAD: %s", hexfile);
    \$readmemh(hexfile, mem);
  end
  wire [13:0] bAddrA = {addrA[12:0], 1'b0};
  assign rDataA = {mem[bAddrA + 14'd1], mem[bAddrA]};
  wire [13:0] bAddrB = {addrB[11:0], 2'b00};
  always_ff @(posedge clk) begin
    if (wEnB) begin
      if (bEnB[0]) mem[bAddrB] <= wDataB[7:0];
      if (bEnB[1]) mem[bAddrB + 14'd1] <= wDataB[15:8];
      if (bEnB[2]) mem[bAddrB + 14'd2] <= wDataB[23:16];
      if (bEnB[3]) mem[bAddrB + 14'd3] <= wDataB[31:24];
    end
  end
  always_comb begin
    if (rEnB) begin
      rDataB = {mem[bAddrB + 14'd3], mem[bAddrB + 14'd2], mem[bAddrB + 14'd1], mem[bAddrB]};
    end else begin
      rDataB = 32'h0;
    end
  end
endmodule
""";
    });
    File('${tmpDir.path}/parcore_top.sv').writeAsStringSync(sv);
    File('${tmpDir.path}/sim_main.cpp').writeAsStringSync("""
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
    uint32_t guest_text_end = 0x00000800;
    if (const char* ge = std::getenv("GUEST_TEXT_END")) {
        guest_text_end = static_cast<uint32_t>(std::strtoul(ge, nullptr, 10));
    }

    top->clk = 0;
    top->reset = 1;
    top->uart_rx = 1;
    top->guest_text_end = guest_text_end;
    top->eval();

    auto read_c1_word = [&](uint32_t addr) -> uint32_t {
        auto& m = top->rootp->ParcoreTop__DOT__core1_tcm__DOT__mem;
        return uint32_t(m[addr]) | (uint32_t(m[addr+1]) << 8) |
               (uint32_t(m[addr+2]) << 16) | (uint32_t(m[addr+3]) << 24);
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
            uint32_t x31 = read_c1_word(0x0C00 + 31 * 4);
            if (x31 == 0xCAFE0001 || (x31 & 0xFFFF0000) == 0xDEAD0000) {
                drain = 32;
            }
        }
    }
    uint32_t x31 = read_c1_word(0x0C00 + 31 * 4);
    uint32_t gp  = read_c1_word(0x0C00 + 3 * 4);
    uint32_t a0  = read_c1_word(0x0C00 + 10 * 4);
    std::printf("RESULT x31=0x%08x gp=%u a0=0x%08x cyc=%d\\n", x31, gp, a0, cyc);
    delete top;
    return 0;
}
""");
    final res = Process.runSync(
      '/Users/jock/oss-cad-suite/bin/verilator',
      [
        '--cc',
        '--exe',
        '--build',
        '-O3',
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

  void writeHex(String path, List<int> bytes) {
    final mem = Uint8List(16384);
    for (int i = 0; i < bytes.length && (0x0100 + i) < 16384; i++) {
      mem[0x0100 + i] = bytes[i];
    }
    final sb = StringBuffer();
    for (int i = 0; i < 16384; i++) {
      sb.writeln(mem[i].toRadixString(16).padLeft(2, '0'));
    }
    File(path).writeAsStringSync(sb.toString());
  }

  writeHex('${tmpDir.path}/TOP.ParcoreTop.core0_tcm.hex', c0Merged);
  writeHex('${tmpDir.path}/ParcoreTop.core0_tcm.hex', c0Merged);
  writeHex('${tmpDir.path}/TOP.ParcoreTop.core1_tcm.hex', c1Kernel);
  writeHex('${tmpDir.path}/ParcoreTop.core1_tcm.hex', c1Kernel);
  writeHex('${tmpDir.path}/TOP.ParcoreTop.core2_tcm.hex', c2Kernel);
  writeHex('${tmpDir.path}/ParcoreTop.core2_tcm.hex', c2Kernel);
  writeHex('${tmpDir.path}/TOP.ParcoreTop.core3_tcm.hex', c3Merged);
  writeHex('${tmpDir.path}/ParcoreTop.core3_tcm.hex', c3Merged);

  final runRes = Process.runSync(
    binFile.path,
    const [],
    environment: {'MAX_CYCLES': '$maxCycles', 'GUEST_TEXT_END': '$guestTextEndAddr'},
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

      final textFiles = suiteDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.text.bin'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

      group(suite, () {
        for (final textFile in textFiles) {
          final fileName = textFile.uri.pathSegments.last;
          final testName = fileName.substring(
            0,
            fileName.length - '.text.bin'.length,
          );
          final fullId = '$suite/$testName';
          if (filter.isNotEmpty) {
            final matches = filter.contains('/')
                ? fullId == filter
                : (suite == filter || testName == filter);
            if (!matches) continue;
          }

          final dataPath = '${suiteDir.path}/$testName.data.bin';

          test(fullId, () async {
            await Simulator.reset();
            final clk = Logic(name: 'clk');
            final reset = Logic(name: 'reset');
            final uartRx = Logic(name: 'uart_rx');

            final c0Kernel =
                _loadBinary('../../build/parcore/riscv/core0_if_uart.bin');
            final c1Kernel =
                _loadBinary('../../build/parcore/riscv/core1_id.bin');
            final c2Kernel =
                _loadBinary('../../build/parcore/riscv/core2_ex.bin');
            final c3Kernel =
                _loadBinary('../../build/parcore/riscv/core3_mem.bin');
            final textBytes = textFile.readAsBytesSync();
            final dataBytes = File(dataPath).existsSync()
                ? File(dataPath).readAsBytesSync()
                : const <int>[];

            // Merge Core 0 kernel (0x0100) + guest .text (0x0500) + non-overlapping .data (0x0800)
            const c0TcmOffset = 0x0500 - 0x0100;
            const c0DataOffset = 0x0800 - 0x0100;
            final c0Size = (c0TcmOffset + textBytes.length + 64) < 0x2000
                ? 0x2000
                : (c0TcmOffset + textBytes.length + 64);
            final c0Merged = Uint8List(c0Size);
            for (int i = 0; i < c0Kernel.length; i++) {
              c0Merged[i] = c0Kernel[i];
            }
            for (int i = 0; i < textBytes.length; i++) {
              c0Merged[c0TcmOffset + i] = textBytes[i];
            }
            for (int i = 0;
                i < dataBytes.length && (c0DataOffset + i) < c0Merged.length;
                i++) {
              if ((c0DataOffset + i) >= (c0TcmOffset + textBytes.length)) {
                c0Merged[c0DataOffset + i] = dataBytes[i];
              }
            }

            // Merge Core 3 kernel (0x0100) + guest .data (0x0800)
            const c3DataOffset = 0x0800 - 0x0100;
            final c3Merged = Uint8List(0x0F00);
            for (int i = 0; i < c3Kernel.length; i++) {
              c3Merged[i] = c3Kernel[i];
            }
            for (int i = 0;
                i < dataBytes.length && (c3DataOffset + i) < c3Merged.length;
                i++) {
              c3Merged[c3DataOffset + i] = dataBytes[i];
            }

            final top = ParcoreTop(
              clk: clk,
              reset: reset,
              uartRx: uartRx,
              core0Binary: c0Merged,
              core1Binary: c1Kernel,
              core2Binary: c2Kernel,
              core3Binary: c3Merged,
              guestTextEnd: Const(0x0500 + textBytes.length, width: 32),
            );
            await top.build();

            if (Platform.environment['PARCORE_FAST_SIM'] == '1') {
              final r = await _runVerilatorSynth(
                top,
                c0Merged,
                c1Kernel,
                c2Kernel,
                c3Merged,
                0x0500 + textBytes.length,
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

            const regBase = 0x0C00;
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
                    final sbNow = c1Tcm.readWord(0x0C80) & 0xFFFFFFFF;
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
          }, timeout: Timeout.none);
        }
      });
    }
  });
}
