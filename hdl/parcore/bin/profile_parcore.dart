// =============================================================================
// File: hdl/parcore/bin/profile_parcore.dart
// Description: Profiles Parcore running a guest program (make parcore-profile).
// =============================================================================
//
// dart run bin/profile_parcore.dart --guest <guest.bin>
//     [--firmware <dir>] [--work <dir>] [--max-cycles <n>] [--top <n>]
//
// Runs ParcoreTop in Verilator with the stage firmware from --firmware
// (default ../../build/parcore/riscv: core0_if.bin ... core3_mem.bin and
// their .lst listings) and the guest at 0x500, from reset until the guest
// stores 0xA5 to the LEDs (0x1000_0008). Counters added to each stage core
// record, for every instruction address, the cycles it spent in E and how
// often it entered E, and the cycles E was empty (bubbles: a taken branch or
// jump, or a redirect). It prints:
//   * the run's cycles and RISC-V instructions (from the RV32 reference model
//     running the same guest) and the cycles per RISC-V instruction, overall
//     and for each phase: a phase starts when the guest stores a value from
//     1 to 15 to the LEDs (apps/riscv/bench.S does this);
//   * for each core, the share of cycles running, waiting in a FIFO.R and in
//     bubbles, and the routines (labels from the .lst) taking the most cycles.
// It also checks that the guest's a0 matches the reference model's.
//
// Needs Verilator (`verilator` on the PATH, or $VERILATOR).

import 'dart:io';
import 'dart:typed_data';

import 'package:parcore_rohd/parcore_config.dart';
import 'package:parcore_rohd/parcore_top.dart';
import 'package:particle_rohd/block_ram_tdp.dart';
import 'package:rohd/rohd.dart';

import '../test/rv32_reference.dart';

const _cores = ['core0_if', 'core1_id', 'core2_ex', 'core3_mem'];
const _ledsAddr = 0x10000008;
const _done = 0xA5;

Never usage(String message) {
  stderr.writeln('profile_parcore: $message');
  stderr.writeln('usage: dart run bin/profile_parcore.dart --guest <guest.bin> '
      '[--firmware <dir>] [--work <dir>] [--max-cycles <n>] [--top <n>]');
  exit(2);
}

// Counters added to each ParticleCpuCore module of the generated design
const _profileBlock = '''
// ---- Profile counters (bin/profile_parcore.dart) ----
int unsigned prof_cyc[0:8191];
int unsigned prof_ent[0:8191];
int unsigned prof_bub;
int unsigned prof_run;
logic [31:0] prof_prev;
logic prof_prevv;
initial begin
  prof_bub = 0; prof_run = 0; prof_prevv = 0;
  for (int i = 0; i < 8192; i++) begin prof_cyc[i] = 0; prof_ent[i] = 0; end
end
always_ff @(posedge clk) begin
  if (reset) prof_prevv <= 0;
  else begin
    prof_run <= prof_run + 1;
    if (eValid) begin
      prof_cyc[ePc[13:1]] <= prof_cyc[ePc[13:1]] + 1;
      if (!prof_prevv || prof_prev != ePc) prof_ent[ePc[13:1]] <= prof_ent[ePc[13:1]] + 1;
    end else prof_bub <= prof_bub + 1;
    prof_prev <= ePc;
    prof_prevv <= eValid;
  end
end
''';

String _simMain() {
  final dumps = StringBuffer();
  for (final c in _cores) {
    dumps.writeln('        dump("$c", r->ParcoreTop__DOT__${c}__DOT__prof_cyc, '
        'r->ParcoreTop__DOT__${c}__DOT__prof_ent, '
        'r->ParcoreTop__DOT__${c}__DOT__prof_run, '
        'r->ParcoreTop__DOT__${c}__DOT__prof_bub);');
  }
  return '''
#include "VParcoreTop.h"
#include "VParcoreTop___024root.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>

template <typename A, typename B>
static void dump(const char* core, const A& cyc, const B& ent, uint32_t run, uint32_t bub) {
    std::printf("CORE %s %u %u\\n", core, run, bub);
    for (int i = 0; i < 8192; i++)
        if (cyc[i]) std::printf("PC %s %x %u %u\\n", core, i * 2, cyc[i], ent[i]);
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    VParcoreTop* top = new VParcoreTop;
    VParcoreTop___024root* r = top->rootp;
    const long maxCycles = std::atol(std::getenv("MAX_CYCLES"));
    top->clk = 0;
    top->reset = 1;
    top->uart_rx = 1;
    top->eval();
    int leds = -1;
    long cyc, doneAt = -1;
    for (cyc = 1; cyc <= maxCycles; cyc++) {
        if (cyc == 5) top->reset = 0;
        top->clk = 1; top->eval();
        top->clk = 0; top->eval();
        if (top->leds != leds) {
            leds = top->leds;
            std::printf("LEDS %ld %d\\n", cyc, leds);
            if (leds == $_done && doneAt < 0) {
                doneAt = cyc;
$dumps            }
        }
        // Let the last writebacks land, then read the guest's a0 (x10)
        if (doneAt >= 0 && cyc == doneAt + 2000) break;
    }
    auto& b0 = r->ParcoreTop__DOT__core1_tcm__DOT__ram_bank0;
    auto& b1 = r->ParcoreTop__DOT__core1_tcm__DOT__ram_bank1;
    std::printf("A0 %08x\\n", uint32_t(b0[10]) | (uint32_t(b1[10]) << 16));
    std::printf("END %ld %ld\\n", cyc, doneAt);
    delete top;
    return 0;
}
''';
}

/// A kernel at 0x100 with [guest] at 0x500; the array starts at 0x100.
Uint8List _merge(List<int> kernel, List<int> guest, int tcmSize) {
  final merged = Uint8List(tcmSize - 0x100);
  merged.setAll(0, kernel);
  if (guest.isNotEmpty) merged.setAll(0x500 - 0x100, guest);
  return merged;
}

/// Labels and instruction text by address, from a pasm listing.
(List<(int, String)>, Map<int, String>) _readListing(File lst) {
  final labels = <(int, String)>[];
  final text = <int, String>{};
  final labelLine = RegExp(r'^([0-9A-F]{8})\s+([A-Za-z_.][\w.]*):\s*$');
  final codeLine = RegExp(r'^([0-9A-F]{8})  ([0-9A-F]+)\s+\d+\s+(.*)$');
  for (final line in lst.readAsLinesSync()) {
    final l = labelLine.firstMatch(line);
    if (l != null) {
      final name = l.group(2)!;
      // Local labels (._x) belong to the routine they're in
      if (!name.startsWith('.')) labels.add((int.parse(l.group(1)!, radix: 16), name));
      continue;
    }
    final c = codeLine.firstMatch(line);
    if (c != null) text[int.parse(c.group(1)!, radix: 16)] = c.group(3)!.trim();
  }
  labels.sort((a, b) => a.$1.compareTo(b.$1));
  return (labels, text);
}

String _pct(int part, int whole) =>
    whole == 0 ? '   -  ' : '${(100 * part / whole).toStringAsFixed(1).padLeft(5)}%';

String _num(int n) => n.toString().replaceAllMapped(
    RegExp(r'(\d)(?=(\d{3})+$)'), (m) => '${m.group(1)},');

Future<void> main(List<String> args) async {
  final opts = <String, String>{
    'firmware': '../../build/parcore/riscv',
    'work': '/tmp/parcore_profile',
    'max-cycles': '50000000',
    'top': '8',
  };
  for (var i = 0; i < args.length; i++) {
    final opt = args[i];
    if (!opt.startsWith('--') ||
        !['guest', 'firmware', 'work', 'max-cycles', 'top'].contains(opt.substring(2))) {
      usage('unknown option: $opt');
    }
    if (i + 1 >= args.length) usage('$opt needs a value');
    opts[opt.substring(2)] = args[++i];
  }
  if (!opts.containsKey('guest')) usage('--guest is required');
  final fw = opts['firmware']!;
  final work = opts['work']!;
  final maxCycles = int.parse(opts['max-cycles']!);
  final topN = int.parse(opts['top']!);

  List<int> read(String path) {
    final f = File(path);
    if (!f.existsSync()) usage('$path not found');
    return f.readAsBytesSync();
  }

  final guest = read(opts['guest']!);
  final kernels = {
    for (final c in _cores) c: read('$fw/$c.bin'),
  };
  final c3Image = _merge(kernels['core3_mem']!, guest, ParcoreConfig.core3Mem.tcmSizeBytes);

  // The reference model: instructions in all, and at each LED store
  final phaseSteps = <(int, int)>[]; // (value, instructions before it)
  final ref = runRv32Reference(guest,
      dataImage: c3Image,
      dataBytes: ParcoreConfig.core3Mem.tcmSizeBytes,
      maxSteps: 10000000, onStore: (addr, value, steps) {
    if (addr == _ledsAddr) phaseSteps.add((value & 0xFF, steps));
  });
  final doneStep = phaseSteps.where((p) => p.$1 == _done).firstOrNull;
  if (doneStep == null) {
    usage('the guest never stores 0x${_done.toRadixString(16)} to the LEDs '
        '(0x${_ledsAddr.toRadixString(16)}) in the reference model');
  }
  final instructions = doneStep.$2;

  // The design, with the profile counters, built once and kept in --work
  Directory(work).createSync(recursive: true);
  final top = ParcoreTop(
    clk: Logic(name: 'clk'),
    reset: Logic(name: 'reset'),
    uartRx: Logic(name: 'uart_rx'),
    core0Binary: Uint8List(ParcoreConfig.core0If.tcmSizeBytes - 0x100),
    core1Binary: Uint8List(ParcoreConfig.core1Id.tcmSizeBytes - 0x100),
    core2Binary: Uint8List(ParcoreConfig.core2Ex.tcmSizeBytes - 0x100),
    core3Binary: Uint8List(ParcoreConfig.core3Mem.tcmSizeBytes - 0x100),
    tcmInitDir: work,
  );
  await top.build();
  var sv = top.generateSynth();
  final ends = RegExp(r'^endmodule : ParticleCpuCore(_\d+)?$', multiLine: true);
  if (!ends.hasMatch(sv)) throw StateError('no ParticleCpuCore module in the design');
  sv = sv.replaceAllMapped(ends, (m) => '$_profileBlock${m.group(0)}');
  final main = _simMain();
  final svFile = File('$work/parcore_profile.sv');
  final mainFile = File('$work/sim_main.cpp');
  final exe = File('$work/obj_dir/VParcoreTop');
  if (!(exe.existsSync() &&
      svFile.existsSync() && svFile.readAsStringSync() == sv &&
      mainFile.existsSync() && mainFile.readAsStringSync() == main)) {
    stdout.writeln('==> Building the profiling model with Verilator (in $work)...');
    svFile.writeAsStringSync(sv);
    mainFile.writeAsStringSync(main);
    final objDir = Directory('$work/obj_dir');
    if (objDir.existsSync()) objDir.deleteSync(recursive: true);
    final verilator = Platform.environment['VERILATOR'] ?? 'verilator';
    final res = Process.runSync(
        verilator,
        ['--cc', '--exe', '--build', '-O3', '--public-flat-rw', '-Wno-fatal',
         '--top-module', 'ParcoreTop', 'parcore_profile.sv', 'sim_main.cpp',
         '-o', 'VParcoreTop'],
        workingDirectory: work);
    if (res.exitCode != 0) {
      stderr.writeln('Verilator build failed:\n${res.stdout}${res.stderr}');
      exit(1);
    }
  }

  final images = <String, (List<int>, int)>{
    'conductor_tcm': (const [], ParcoreConfig.conductorConfig.tcmSizeBytes),
    'core0_tcm': (_merge(kernels['core0_if']!, guest, ParcoreConfig.core0If.tcmSizeBytes),
        ParcoreConfig.core0If.tcmSizeBytes),
    'core1_tcm': (kernels['core1_id']!, ParcoreConfig.core1Id.tcmSizeBytes),
    'core2_tcm': (kernels['core2_ex']!, ParcoreConfig.core2Ex.tcmSizeBytes),
    'core3_tcm': (c3Image, ParcoreConfig.core3Mem.tcmSizeBytes),
  };
  for (final e in images.entries) {
    final (bytes, size) = e.value;
    final (bank0, bank1) =
        ParticleBlockRamTdp.bankFiles(bytes, loadOffset: 0x100, depthWords: size ~/ 4);
    File('$work/${e.key}_bank0.hex').writeAsStringSync(bank0);
    File('$work/${e.key}_bank1.hex').writeAsStringSync(bank1);
  }

  stdout.writeln('==> Running ${opts['guest']} (${_num(instructions)} RISC-V instructions)...');
  final run = Process.runSync(exe.path, const [],
      environment: {'MAX_CYCLES': '$maxCycles'});
  if (run.exitCode != 0) {
    stderr.writeln('The profiling run failed:\n${run.stderr}');
    exit(1);
  }
  final out = '${run.stdout}';
  final end = RegExp(r'^END (\d+) (-?\d+)$', multiLine: true).firstMatch(out)!;
  final doneAt = int.parse(end.group(2)!);
  if (doneAt < 0) {
    stderr.writeln('The guest didn\'t finish in ${_num(maxCycles)} cycles '
        '(raise --max-cycles, or check that it works).');
    exit(1);
  }
  final cycles = doneAt - 4; // reset is released at cycle 5
  final a0 = int.parse(RegExp(r'^A0 ([0-9a-f]+)$', multiLine: true).firstMatch(out)!.group(1)!,
      radix: 16);

  String each(int c, int n) => n == 0 ? '-' : (c / n).toStringAsFixed(1);

  stdout.writeln();
  stdout.writeln('Parcore profile of ${opts['guest']}');
  stdout.writeln('  ${_num(cycles)} cycles for ${_num(instructions)} RISC-V instructions: '
      '${each(cycles, instructions)} cycles each');
  final a0Ok = a0 == ref.regs[10];
  stdout.writeln('  a0 = 0x${a0.toRadixString(16).padLeft(8, '0')} '
      '(${a0Ok ? 'matches the reference model' : 'DIFFERS from the reference model: 0x${ref.regs[10].toRadixString(16).padLeft(8, '0')}'})');

  // Phases: from each LED value 1..15 to the next LED store
  final ledChanges = [
    for (final m in RegExp(r'^LEDS (\d+) (\d+)$', multiLine: true).allMatches(out))
      (int.parse(m.group(1)!), int.parse(m.group(2)!)),
  ];
  final phases = [
    for (var i = 0; i < phaseSteps.length; i++)
      if (phaseSteps[i].$1 >= 1 && phaseSteps[i].$1 <= 15) i,
  ];
  if (phases.isNotEmpty) {
    stdout.writeln();
    stdout.writeln('  Phase   RISC-V instructions      Cycles   Cycles each');
    for (final i in phases) {
      final value = phaseSteps[i].$1;
      final steps = (i + 1 < phaseSteps.length ? phaseSteps[i + 1].$2 : instructions) -
          phaseSteps[i].$2;
      final start = ledChanges.where((c) => c.$2 == value).firstOrNull?.$1;
      final next = i + 1 < phaseSteps.length ? phaseSteps[i + 1].$1 : _done;
      final stop = ledChanges.where((c) => c.$2 == next && (start == null || c.$1 > start)).firstOrNull?.$1;
      final c = (start != null && stop != null) ? stop - start : 0;
      stdout.writeln('  ${'$value'.padLeft(5)}   ${_num(steps).padLeft(19)}   ${_num(c).padLeft(10)}   '
          '${each(c, steps).padLeft(11)}');
    }
  }

  stdout.writeln();
  stdout.writeln('  Core        Running   In FIFO.R   Bubbles');
  final perCore = <String, (int, int, Map<int, (int, int)>)>{};
  for (final m in RegExp(r'^CORE (\w+) (\d+) (\d+)$', multiLine: true).allMatches(out)) {
    perCore[m.group(1)!] = (int.parse(m.group(2)!), int.parse(m.group(3)!), {});
  }
  for (final m in RegExp(r'^PC (\w+) ([0-9a-f]+) (\d+) (\d+)$', multiLine: true).allMatches(out)) {
    perCore[m.group(1)!]!.$3[int.parse(m.group(2)!, radix: 16)] =
        (int.parse(m.group(3)!), int.parse(m.group(4)!));
  }
  final details = StringBuffer();
  for (final c in _cores) {
    final (run, bubbles, pcs) = perCore[c]!;
    final (labels, text) = _readListing(File('$fw/$c.lst'));
    String routine(int a) {
      var best = '(before the first label)';
      for (final (addr, name) in labels) {
        if (addr > a) break;
        best = name;
      }
      return best;
    }

    var waiting = 0;
    final byRoutine = <String, int>{};
    pcs.forEach((a, v) {
      final (cyc, entries) = v;
      if ((text[a] ?? '').toUpperCase().startsWith('FIFO.R')) waiting += cyc - entries;
      byRoutine.update(routine(a), (x) => x + cyc, ifAbsent: () => cyc);
    });
    final running = run - bubbles - waiting;
    stdout.writeln('  ${c.padRight(10)} ${_pct(running, run)}   ${_pct(waiting, run).padLeft(9)}   '
        '${_pct(bubbles, run).padLeft(7)}');
    details.writeln('  $c (cycles in E, FIFO.R waits included)');
    final sorted = byRoutine.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    for (final e in sorted.take(topN)) {
      details.writeln('    ${_pct(e.value, run)}  ${e.key}');
    }
  }
  stdout.writeln();
  stdout.writeln('  Routines taking the most cycles');
  stdout.write(details);
  if (!a0Ok) exit(1);
}
