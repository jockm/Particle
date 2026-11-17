import 'dart:io';
import 'dart:typed_data';
import 'package:parcore_rohd/parcore_top.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

List<int> loadBinary(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    throw Exception('Binary not found: $path');
  }
  return file.readAsBytesSync();
}

Future<({Map<int, int> regs, int cycles, String stdout})> runVerilatorPipeline({
  required Uint8List c0Merged,
  required List<int> c1Kernel,
  required List<int> c2Kernel,
  required List<int> c3Kernel,
  int maxCycles = 25000,
  int idleThreshold = 400,
}) async {
  final tmpDir = Directory('/tmp/parcore_pipeline_verilator');
  if (!tmpDir.existsSync()) tmpDir.createSync(recursive: true);
  final binFile = File('${tmpDir.path}/obj_dir/VParcoreTop');

  if (!binFile.existsSync()) {
    final dummyClk = Logic(name: 'clk');
    final dummyReset = Logic(name: 'reset');
    final dummyUartRx = Logic(name: 'uart_rx');
    final top = ParcoreTop(
      clk: dummyClk,
      reset: dummyReset,
      uartRx: dummyUartRx,
      core0Binary: Uint8List(8192),
      core1Binary: Uint8List(4096),
      core2Binary: Uint8List(4096),
      core3Binary: Uint8List(4096),
    );
    await top.build();
    var sv = top.generateSynth();
    await Simulator.reset();

    final tcmRegex = RegExp(
      r'(module\s+ParcoreTcm(?:_\d+)?\s*\([^;]*\);)[\s\S]*?endmodule',
    );
    sv = sv.replaceAllMapped(tcmRegex, (m) {
      final header = m.group(1)!;
      return """
$header
  logic [7:0] mem [0:16383];
  string hexfile;
  initial begin
    for (int i = 0; i < 16384; i++) mem[i] = 8'h00;
    \$sformat(hexfile, "/tmp/parcore_pipeline_verilator/%m.hex");
    \$readmemh(hexfile, mem);
  end
  wire [13:0] bAddrA = {13'(addrA), 1'b0};
  assign rDataA = {mem[bAddrA + 14'd1], mem[bAddrA]};
  wire [13:0] bAddrB = {12'(addrB), 2'b00};
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
    File('${tmpDir.path}/sim_main.cpp').writeAsStringSync(r"""
#include "VParcoreTop.h"
#include "VParcoreTop___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    VParcoreTop* top = new VParcoreTop;
    int max_cycles = 25000;
    if (const char* mc = std::getenv("MAX_CYCLES")) max_cycles = std::atoi(mc);
    int idle_thresh = 400;
    if (const char* it = std::getenv("IDLE_THRESH")) idle_thresh = std::atoi(it);

    top->clk = 0;
    top->reset = 1;
    top->uart_rx = 1;
    top->guest_text_end = 0x00000800;
    top->eval();

    auto& c0_mem = top->rootp->ParcoreTop__DOT__core0_tcm__DOT__mem;
    auto& c1_mem = top->rootp->ParcoreTop__DOT__core1_tcm__DOT__mem;
    uint32_t prev_regs[32];
    std::memset(prev_regs, 0, sizeof(prev_regs));

    int idle = 0;
    bool had_activity = false;
    int cyc = 0;
    for (cyc = 1; cyc <= max_cycles; cyc++) {
        if (cyc == 5) top->reset = 0;
        top->clk = 1; top->eval();
        top->clk = 0; top->eval();

        if (cyc > 300) {
            bool changed = false;
            for (int r = 1; r < 32; r++) {
                uint32_t addr = r * 4;
                uint32_t val = uint32_t(c1_mem[addr]) | (uint32_t(c1_mem[addr+1]) << 8) |
                               (uint32_t(c1_mem[addr+2]) << 16) | (uint32_t(c1_mem[addr+3]) << 24);
                if (val != prev_regs[r]) {
                    prev_regs[r] = val;
                    changed = true;
                }
            }
            if (changed) {
                had_activity = true;
                idle = 0;
            } else if (had_activity) {
                idle++;
                if (idle >= idle_thresh) break;
            }
        }
    }

    uint32_t c0_500 = uint32_t(c0_mem[0x500]) | (uint32_t(c0_mem[0x501]) << 8) |
                      (uint32_t(c0_mem[0x502]) << 16) | (uint32_t(c0_mem[0x503]) << 24);
    std::printf("C0_500=0x%08x\n", c0_500);
    for (int a = 0; a < 4096; a += 4) {
        uint32_t v = uint32_t(c1_mem[a]) | (uint32_t(c1_mem[a+1]) << 8) |
                     (uint32_t(c1_mem[a+2]) << 16) | (uint32_t(c1_mem[a+3]) << 24);
        if (v != 0 && a < 0x100) std::printf("C1_MEM[0x%04x]=0x%08x\n", a, v);
    }
    std::printf("CYCLES=%d C0_PC=0x%04x C1_PC=0x%04x C2_PC=0x%04x C3_PC=0x%04x\n",
                cyc,
                top->rootp->ParcoreTop__DOT__core0_if__DOT__pc,
                top->rootp->ParcoreTop__DOT__core1_id__DOT__pc,
                top->rootp->ParcoreTop__DOT__core2_ex__DOT__pc,
                top->rootp->ParcoreTop__DOT__core3_mem__DOT__pc);
    for (int r = 0; r < 32; r++) {
        uint32_t addr = r * 4;
        uint32_t val = uint32_t(c1_mem[addr]) | (uint32_t(c1_mem[addr+1]) << 8) |
                       (uint32_t(c1_mem[addr+2]) << 16) | (uint32_t(c1_mem[addr+3]) << 24);
        std::printf("R%d=0x%08x\n", r, val);
    }
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

  writeHex('${tmpDir.path}/TOP.ParcoreTop.conductor_tcm.hex', const []);
  writeHex('${tmpDir.path}/TOP.ParcoreTop.core0_tcm.hex', c0Merged);
  writeHex('${tmpDir.path}/ParcoreTop.core0_tcm.hex', c0Merged);
  writeHex('${tmpDir.path}/TOP.ParcoreTop.core1_tcm.hex', c1Kernel);
  writeHex('${tmpDir.path}/ParcoreTop.core1_tcm.hex', c1Kernel);
  writeHex('${tmpDir.path}/TOP.ParcoreTop.core2_tcm.hex', c2Kernel);
  writeHex('${tmpDir.path}/ParcoreTop.core2_tcm.hex', c2Kernel);
  writeHex('${tmpDir.path}/TOP.ParcoreTop.core3_tcm.hex', c3Kernel);
  writeHex('${tmpDir.path}/ParcoreTop.core3_tcm.hex', c3Kernel);

  final runRes = Process.runSync(
    binFile.path,
    const [],
    environment: {
      'MAX_CYCLES': '$maxCycles',
      'IDLE_THRESH': '$idleThreshold',
    },
  );
  if (runRes.exitCode != 0) {
    throw Exception('Verilator run failed:\n${runRes.stderr}');
  }

  final out = '${runRes.stdout}';
  final cycMatch = RegExp(r'CYCLES=(\d+)').firstMatch(out);
  final cycles = cycMatch != null ? int.parse(cycMatch.group(1)!) : 0;
  final regs = <int, int>{};
  for (final m in RegExp(r'R(\d+)=0x([0-9a-fA-F]+)').allMatches(out)) {
    regs[int.parse(m.group(1)!)] = int.parse(m.group(2)!, radix: 16);
  }
  return (regs: regs, cycles: cycles, stdout: out);
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

  group('Parcore RV32IM Guest Program Execution (Verilator Fast Mode)', () {
    test('Guest instructions retire into Core 1 architectural registers (x1..x5)', () async {
      final guestProg = loadBinary('../../build/guest_rv32_test.bin');
      final res = await runVerilatorPipeline(
        c0Merged: mergeCore0WithGuest(c0Kernel, guestProg),
        c1Kernel: c1Kernel,
        c2Kernel: c2Kernel,
        c3Kernel: c3Kernel,
        maxCycles: 35000,
      );
      final regs = res.regs;
      print('Completed in ${res.cycles} cycles | stdout:\n${res.stdout}');
      expect(regs[1]! & 0xFFFFFFFF, equals(0xFFFFFFF0));
      expect(regs[2]! & 0xFFFFFFFF, equals(0x4));
      expect(regs[3]! & 0xFFFFFFFF, equals(0x20));
      expect(regs[4]! & 0xFFFFFFFF, equals(0x3FFFFFFC));
      expect(regs[5]! & 0xFFFFFFFF, equals(0xFFFFFFFC));
    });

    test('Guest instructions - Signed Division & Remainder Edge Cases', () async {
      final guestProg = loadBinary('../../build/guest_rv32_signed_div.bin');
      final res = await runVerilatorPipeline(
        c0Merged: mergeCore0WithGuest(c0Kernel, guestProg),
        c1Kernel: c1Kernel,
        c2Kernel: c2Kernel,
        c3Kernel: c3Kernel,
        maxCycles: 20000,
      );
      final regs = res.regs;
      print('Signed division completed in ${res.cycles} cycles');
      expect(regs[1], isNotNull);
      expect(regs[3]! & 0xFFFFFFFF, isNot(equals(0)));
    });

    test('Guest instructions - Multiply High & Full RV32M (MUL, MULH, MULHSU, MULHU)', () async {
      final guestProg = loadBinary('../../build/guest_rv32_mul_test.bin');
      final res = await runVerilatorPipeline(
        c0Merged: mergeCore0WithGuest(c0Kernel, guestProg),
        c1Kernel: c1Kernel,
        c2Kernel: c2Kernel,
        c3Kernel: c3Kernel,
        maxCycles: 15000,
      );
      final regs = res.regs;
      print('Multiply test completed in ${res.cycles} cycles');
      expect(regs[7]! & 0xFFFFFFFF, equals(0xFFFFFFC4));
    });

    test('Guest instructions - Sub-word Memory Access (LB, LBU, LH, LHU, LW, SB, SH, SW)', () async {
      final guestProg = loadBinary('../../build/guest_rv32_mem_test.bin');
      final res = await runVerilatorPipeline(
        c0Merged: mergeCore0WithGuest(c0Kernel, guestProg),
        c1Kernel: c1Kernel,
        c2Kernel: c2Kernel,
        c3Kernel: c3Kernel,
        maxCycles: 15000,
      );
      final regs = res.regs;
      print('Sub-word memory test completed in ${res.cycles} cycles');
      expect(regs[6]! & 0xFFFFFFFF, equals(0x5A));
      expect(regs[7]! & 0xFFFFFFFF, equals(0xFFFFFFF2));
    });

    test('Guest instructions - Control Transfer & Pipeline Flushing (BEQ, BNE, BLT, BGEU, JAL, JALR)', () async {
      final guestProg = loadBinary('../../build/guest_rv32_branch.bin');
      final res = await runVerilatorPipeline(
        c0Merged: mergeCore0WithGuest(c0Kernel, guestProg),
        c1Kernel: c1Kernel,
        c2Kernel: c2Kernel,
        c3Kernel: c3Kernel,
        maxCycles: 15000,
      );
      final regs = res.regs;
      print('Branch redirect test completed in ${res.cycles} cycles');
      expect(regs[1]! & 0xFFFFFFFF, equals(10));
      expect(regs[2]! & 0xFFFFFFFF, equals(10));
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
      final res = await runVerilatorPipeline(
        c0Merged: mergeCore0WithGuest(c0Kernel, encodeWords(guestInstructions)),
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
    });
  });
}
