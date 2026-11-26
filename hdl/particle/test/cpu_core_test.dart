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
  // The handler counts in R2, copies R14 to R3 and returns with RETI
  const mboxHandler = '''
.org 0x110
    ADD     R2, 1
    LD      R3, R14
    RETI
''';

  test('MBOX: taken between instructions, R14 kept, RETI returns to EPC',
      () async {
    final h = CoreHarness(asm('''
.org 0x100
    LDI     R14, _main
    JMP     R14, R0
$mboxHandler
.org 0x500
_main:
    LDI     R14, 0x5A       ; must survive the trap
_loop:
    ADD     R1, 1
    BBRA    _loop
'''));
    await h.start();
    await h.step(40);
    final before = h.snapshot().reg(1);
    await strobeMbox(h, 1);
    await h.step(40);
    final st = h.snapshot();
    expect(st.reg(2), equals(1), reason: 'the handler ran once');
    expect(st.reg(3), equals(0x5A), reason: "the handler saw main's R14");
    expect(st.reg(14), equals(0x5A), reason: 'R14 survived');
    expect(st.reg(1), greaterThan(before), reason: 'RETI resumed the loop');
    await h.stop();
  });

  test('MBOX interrupts a FIFO.R stall, which runs again after RETI',
      () async {
    final h = CoreHarness(asm('''
.org 0x100
    LDI     R14, _main
    JMP     R14, R0
.org 0x110
    ADD     R2, 1
    LDI     R5, 0x77
    FIFO.W  R5, R4          ; feed the channel the main code waits on
    RETI
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
    expect(st.reg(6), equals(0x77), reason: 'FIFO.R ran again and got data');
    expect(st.reg(7), equals(9));
    await h.stop();
  });

  test('MBOX abandons a divide, which runs again after RETI', () async {
    final h = CoreHarness(asm('''
.org 0x100
    LDI     R14, _main
    JMP     R14, R0
.org 0x110
    ADD     R2, 1
    LDI     R8, 1000
    DIV     R8, R9          ; the handler divides too
    RETI
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
    expect(st.reg(8), equals(100), reason: "the handler's divide");
    expect(st.reg(5), equals(1234), reason: 'the DIV ran again');
    expect(st.reg(7), equals(9));
    await h.stop();
  });

  test('DI holds an MBOX until EI; the handler reads its value '
      'and sender', () async {
    final h = CoreHarness(asm('''
.org 0x100
    LDI     R14, _main
    JMP     R14, R0
.org 0x110
    ADD     R2, 1
    LDIS    R5, 0xFF04      ; NI_MBOX_VALUE
    LD32    R10, (R5)
    LDIS    R5, 0xFF08      ; NI_MBOX_SOURCE
    LD32    R11, (R5)
    RETI
.org 0x500
_main:
    DI
    LD      R1, 0
_wait:
    ADD     R1, 1
    LD      R6, R1
    SUB     R6, 15
    BBRA.NZ R6, _wait       ; a while, masked
    LD      R12, R2         ; the handler hasn't run
    EI
    NOP
    NOP
_h: BBRA    _h
'''));
    await h.start();
    await h.step(12);
    h.mboxData.inject(0x12345678);
    h.mboxSource.inject(3);
    await strobeMbox(h, 1);
    await h.runToHalt();
    final st = h.snapshot();
    expect(st.reg(12), equals(0), reason: 'held while masked');
    expect(st.reg(2), equals(1), reason: 'taken after EI');
    expect(st.reg(10), equals(0x12345678));
    expect(st.reg(11), equals(3));
    await h.stop();
  });

  test('WAIT sleeps until an MBOX, which is taken; RETI returns past the WAIT',
      () async {
    final h = CoreHarness(asm('''
.org 0x100
    LDI     R14, _main
    JMP     R14, R0
.org 0x110
    ADD     R2, 1
    RETI
.org 0x500
_main:
    LD      R1, 1
    WAIT
    ADD     R1, 1
_h: BBRA    _h
'''));
    await h.start();
    await h.step(30);
    expect(h.core.waiting.value.toInt(), equals(1), reason: 'asleep');
    expect(h.snapshot().reg(1), equals(1));
    await strobeMbox(h, 1);
    await h.runToHalt();
    final st = h.snapshot();
    expect(st.reg(2), equals(1), reason: 'the handler ran');
    expect(st.reg(1), equals(2), reason: 'RETI returned past the WAIT');
    expect(h.core.waiting.value.toInt(), equals(0));
    await h.stop();
  });

  test('A masked MBOX ends a WAIT and stays queued until EI', () async {
    final h = CoreHarness(asm('''
.org 0x100
    LDI     R14, _main
    JMP     R14, R0
.org 0x110
    ADD     R2, 1
    LD      R12, R3         ; set after the WAIT, before EI
    RETI
.org 0x500
_main:
    DI
    WAIT
    LD      R3, 7
    LD      R13, R2         ; the handler hasn't run
    EI
    NOP
_h: BBRA    _h
'''));
    await h.start();
    await h.step(30);
    expect(h.core.waiting.value.toInt(), equals(1));
    await strobeMbox(h, 1);
    await h.runToHalt();
    final st = h.snapshot();
    expect(st.reg(13), equals(0), reason: 'held while masked');
    expect(st.reg(2), equals(1), reason: 'taken after EI');
    expect(st.reg(12), equals(7));
    await h.stop();
  });

  test('HALT sleeps until reset: an MBOX is not taken', () async {
    final h = CoreHarness(asm('''
.org 0x100
    LDI     R14, _main
    JMP     R14, R0
.org 0x110
    ADD     R2, 1
    RETI
.org 0x500
_main:
    LD      R1, 1
    HALT
    LD      R1, 5
_h: BBRA    _h
'''));
    await h.start();
    await h.step(30);
    expect(h.core.halted.value.toInt(), equals(1));
    await strobeMbox(h, 1);
    await h.step(40);
    final st = h.snapshot();
    expect(st.reg(2), equals(0), reason: 'no MBOX taken');
    expect(st.reg(1), equals(1));
    expect(h.core.halted.value.toInt(), equals(1));
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

  test('The reserved opcodes 0xD3 and 0xD4 take vector 15', () async {
    final h = CoreHarness(asm('''
.org 0x100
    LDI     R14, _main
    JMP     R14, R0
.org 0x1F0
    ADD     R6, 1
    LD      R7, R14
    ADD     R14, 2
    JMP     R14, R0
.org 0x500
_main:
    LD      R1, 1
    .half   0xD304          ; formerly RBASE 4
    LD      R1, 2
    .half   0xD410          ; formerly RBASE R1
    LD      R2, 3
_halt: BBRA _halt
'''));
    await h.start();
    await h.runToHalt();
    final st = h.snapshot();
    expect(st.reg(6), equals(2), reason: 'both trapped');
    expect(st.reg(7), equals(0x506), reason: 'R14 = the second one');
    expect(st.reg(1), equals(2), reason: 'registers are not windowed');
    expect(st.reg(2), equals(3));
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
