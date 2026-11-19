// =============================================================================
// File: hdl/particle/test/cpu_core_test.dart
// Description: Core behaviour the differential ISA test can't check against
//              psim: reset, cycle counts, MBOX interrupts (including during a
//              FIFO stall and a divide), vector 15, misaligned loads, and a
//              core built without its divider.
//
// Programs are assembled with build/tools/pasm (`make tools`).
// =============================================================================

import 'dart:io';

import 'package:particle_rohd/cpu_config.dart';
import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import 'core_harness.dart';

final _work = Directory.systemTemp.createTempSync('particle_core_test_');
var _count = 0;

/// Assembles [source] (origin 0x100) and returns its bytes.
List<int> asm(String source) {
  final n = _count++;
  final src = File('${_work.path}/p$n.asm')..writeAsStringSync(source);
  final out = '${_work.path}/p$n.bin';
  final res = Process.runSync(
      '../../build/tools/pasm', [src.path, '-I', '../../lib', '-o', out]);
  if (res.exitCode != 0) {
    throw StateError('pasm failed:\n${res.stdout}${res.stderr}\n$source');
  }
  return File(out).readAsBytesSync();
}

/// Steps until the PC is [addr] (fails after [limit] cycles).
Future<void> runTo(CoreHarness h, int addr, {int limit = 2000}) async {
  for (var i = 0; i < limit; i++) {
    if (h.pc == addr) return;
    await h.step();
  }
  fail('PC never reached 0x${addr.toRadixString(16)} (at 0x${h.pc.toRadixString(16)})');
}

Future<void> strobeMbox(CoreHarness h, int vector) async {
  h.mboxVector.inject(vector);
  h.mboxStrobe.inject(1);
  await h.step();
  h.mboxStrobe.inject(0);
}

void main() {
  tearDown(() async {
    // A failed test may leave its simulation running
    await CoreHarness.stopActive();
  });

  test('Reset: the first instruction is fetched from 0x100', () async {
    final h = CoreHarness(asm('.org 0x100\n    LD R1, 5\n_h: BBRA _h\n'));
    await h.start();
    expect(h.pc, equals(0x100));
    expect(h.core.memPortAAddr.value.toInt(), equals(0x100));
    await h.runToHalt();
    expect(h.snapshot().reg(1), equals(5));
    await h.stop();
  });

  test('Cycle counts: ALU 1, LDI 2, loads 2, stores 1, taken FBRA 2',
      () async {
    final h = CoreHarness(asm('''
.org 0x100
    ADD     R1, 1           ; 0x100
    ADD     R1, 1           ; 0x102
    LDI     R2, 0x8000      ; 0x104 (2 cycles)
    ST32    (R2), R1        ; 0x108
    LD32    R3, (R2)        ; 0x10A (2 cycles)
    FBRA    _t              ; 0x10C (taken, decided in D: 2 cycles)
    ADD     R4, 1
_t: ADD     R5, 1           ; 0x110
_h: BBRA    _h              ; 0x112
'''));
    await h.start();
    // The cycle the core enters Exec at each PC
    final seen = <int, int>{};
    for (var c = 0; c < 20; c++) {
      if (h.inExec) seen.putIfAbsent(h.pc, () => c);
      await h.step();
    }
    expect(seen[0x102]! - seen[0x100]!, equals(1), reason: 'ADD');
    expect(seen[0x104]! - seen[0x102]!, equals(1), reason: 'ADD');
    expect(seen[0x108]! - seen[0x104]!, equals(2), reason: 'LDI');
    expect(seen[0x10A]! - seen[0x108]!, equals(1), reason: 'ST32');
    expect(seen[0x10C]! - seen[0x10A]!, equals(2), reason: 'LD32');
    expect(seen[0x110]! - seen[0x10C]!, equals(2), reason: 'taken FBRA');
    final st = h.snapshot();
    expect(st.reg(3), equals(2));
    expect(st.reg(4), equals(0));
    expect(st.reg(5), equals(1));
    await h.stop();
  });

  test('Cycle counts: MUL 2, conditional branches 1 or 3, JMP 3', () async {
    final h = CoreHarness(asm('''
.org 0x100
    ADD     R1, 3           ; 0x100
    MULL    R1, R1          ; 0x102 (2 cycles)
    FBRA.Z  R1, _x          ; 0x104 (not taken: 1 cycle)
    FBRA.NZ R1, _t          ; 0x106 (taken, decided in E: 3 cycles)
    ADD     R4, 1
_t: LDI     R6, _j          ; 0x10A
    JMP     R6, R0          ; 0x10E (3 cycles)
    ADD     R4, 1
_j: ADD     R5, 1           ; 0x112
_h: BBRA    _h              ; 0x114
_x: BBRA    _x
'''));
    await h.start();
    final seen = <int, int>{};
    for (var c = 0; c < 30; c++) {
      if (h.inExec) seen.putIfAbsent(h.pc, () => c);
      await h.step();
    }
    expect(seen[0x104]! - seen[0x102]!, equals(2), reason: 'MULL');
    expect(seen[0x106]! - seen[0x104]!, equals(1), reason: 'FBRA.Z not taken');
    expect(seen[0x10A]! - seen[0x106]!, equals(3), reason: 'FBRA.NZ taken');
    expect(seen[0x112]! - seen[0x10E]!, equals(3), reason: 'JMP');
    final st = h.snapshot();
    expect(st.reg(1), equals(9));
    expect(st.reg(4), equals(0));
    expect(st.reg(5), equals(1));
    await h.stop();
  });

  // Vector 1 handler: count in R2, keep the return address in R3, return
  const mboxHandler = '''
.org 0x110
    ADD     R2, 1
    LD      R3, R14
    JMP     R14, R0
''';

  test('MBOX: taken between instructions, R14 = the next instruction',
      () async {
    final h = CoreHarness(asm('''
.org 0x100
    LDI     R14, _main
    JMP     R14, R0
$mboxHandler
.org 0x500
_main:
    ADD     R1, 1
    BBRA    _main
'''));
    await h.start();
    await h.step(40);
    final before = h.snapshot().reg(1);
    await strobeMbox(h, 1);
    await h.step(40);
    final st = h.snapshot();
    expect(st.reg(2), equals(1), reason: 'the handler ran once');
    expect(st.reg(3), anyOf(equals(0x500), equals(0x502)),
        reason: 'R14 is an instruction in the loop');
    expect(st.reg(1), greaterThan(before), reason: 'the loop resumed');
    await h.stop();
  });

  test('MBOX interrupts a FIFO.R stall, which runs again after the handler',
      () async {
    final h = CoreHarness(asm('''
.org 0x100
    LDI     R14, _main
    JMP     R14, R0
.org 0x110
    ADD     R2, 1
    LD      R3, R14
    LDI     R5, 0x77
    FIFO.W  R5, R4          ; feed the channel the main code waits on
    JMP     R14, R0
.org 0x500
_main:
    LD      R4, 1
    FIFO.R  R6, R4          ; 0x502: stalls (empty)
    LD      R7, 9
_h: BBRA    _h
'''));
    await h.start();
    await h.step(30);
    expect(h.pc, equals(0x502), reason: 'stalled on FIFO.R');
    await strobeMbox(h, 1);
    await h.runToHalt();
    final st = h.snapshot();
    expect(st.reg(2), equals(1));
    expect(st.reg(3), equals(0x502), reason: 'R14 = the stalled FIFO.R');
    expect(st.reg(6), equals(0x77), reason: 'FIFO.R ran again and got data');
    expect(st.reg(7), equals(9));
    await h.stop();
  });

  test('MBOX abandons a divide, which runs again after the handler', () async {
    final h = CoreHarness(asm('''
.org 0x100
    LDI     R14, _main
    JMP     R14, R0
.org 0x110
    ADD     R2, 1
    LD      R3, R14
    LDI     R8, 1000
    DIV     R8, R9          ; the handler divides too
    JMP     R14, R0
.org 0x500
_main:
    LDI     R5, 12345
    LD      R9, 10
    DIV     R5, R9          ; 0x506
    LD      R7, 9
_h: BBRA    _h
'''));
    await h.start();
    await runTo(h, 0x506);
    await h.step(6); // part-way through the divide
    expect(h.pc, equals(0x506));
    await strobeMbox(h, 1);
    await h.runToHalt();
    final st = h.snapshot();
    expect(st.reg(2), equals(1));
    expect(st.reg(3), equals(0x506), reason: 'R14 = the DIV');
    expect(st.reg(8), equals(100), reason: "the handler's divide");
    expect(st.reg(5), equals(1234), reason: 'the DIV ran again');
    expect(st.reg(7), equals(9));
    await h.stop();
  });

  test('An illegal opcode takes vector 15 with R14 = its address', () async {
    final h = CoreHarness(asm('''
.org 0x100
    LDI     R14, _main
    JMP     R14, R0
.org 0x1F0
    LD      R6, R14
_h15: BBRA  _h15
.org 0x500
_main:
    LD      R1, 1
    .half   0xFF12          ; not an opcode
    LD      R2, 2
'''));
    await h.start();
    await h.runToHalt();
    final st = h.snapshot();
    expect(st.reg(6), equals(0x502));
    expect(st.reg(1), equals(1));
    expect(st.reg(2), equals(0), reason: 'execution did not continue');
    await h.stop();
  });

  test('A misaligned load takes vector 14 and changes nothing', () async {
    final h = CoreHarness(asm('''
.org 0x100
    LDI     R14, _main
    JMP     R14, R0
.org 0x1E0
    LD      R6, R14
_h14: BBRA  _h14
.org 0x500
_main:
    LDI     R1, 0x8002
    LD      R2, 5
    LD32    R2, (R1++)      ; 0x506: misaligned
'''));
    await h.start();
    await h.runToHalt();
    final st = h.snapshot();
    expect(st.reg(6), equals(0x506));
    expect(st.reg(1), equals(0x8002), reason: 'pointer unchanged');
    expect(st.reg(2), equals(5), reason: 'destination unchanged');
    await h.stop();
  });

  test('Without a divider, DIV takes vector 15', () async {
    final h = CoreHarness(
        asm('''
.org 0x100
    LDI     R14, _main
    JMP     R14, R0
.org 0x1F0
    LD      R6, R14
_h15: BBRA  _h15
.org 0x500
_main:
    LD      R1, 8
    LD      R2, 2
    DIV     R1, R2          ; 0x504
'''),
        config: const CpuConfig(enableDivider: false));
    await h.start();
    await h.runToHalt();
    final st = h.snapshot();
    expect(st.reg(6), equals(0x504));
    expect(st.reg(1), equals(8));
    await h.stop();
  });
}
