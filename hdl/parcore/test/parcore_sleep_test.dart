// WAIT, HALT and the conductor's CORE_STATE register and MBOX (item 13 of
// Road to GHz, package 3): the conductor lets core 0 out of reset, sees it
// asleep in a WAIT, wakes it with an MBOX, and sees it halt. At each step it
// shows CORE_STATE's low byte on the LEDs.

import 'dart:async';
import 'dart:io';

import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../lib/parcore_top.dart';

/// [source] assembled by pasm (with [options]); the binary starts at 0x100.
List<int> assemble(String source, [List<String> options = const []]) {
  final dir = Directory.systemTemp.createTempSync('parcore_sleep_');
  File('${dir.path}/p.asm').writeAsStringSync(source);
  final res = Process.runSync('../../build/tools/pasm',
      ['${dir.path}/p.asm', '-I', '../../lib', '-o', '${dir.path}/p.bin', ...options]);
  if (res.exitCode != 0) throw StateError('pasm failed:\n${res.stdout}${res.stderr}');
  return File('${dir.path}/p.bin').readAsBytesSync();
}

const conductorSource = '''
.include "lib/common.inc"
.org 0x100
    LDI     R14, _main
    JMP     R14, R0
.org 0x200
_main:
    LOAD32  R10, 0xF0000000     ; RST_CTRL
    LD      R14, 0x3E           ; let core 0 run; cores 1-3 stay in reset
    ST32    (R10), R14
    LD      R11, R10
    ADD     R11, 15
    ADD     R11, 15
    ADD     R11, 2              ; STATUS (0xF000_0020)
    LD      R12, R11
    ADD     R12, 8              ; CORE_STATE (0xF000_0028)
._wait_seen:
    LD32    R3, (R12)
    LD      R4, R3
    AND     R4, 3
    SUB     R4, 1
    BBRA.NZ R4, ._wait_seen     ; until core 0 is in its WAIT
    ; CORE_PC: core 0 is at its WAIT (0x500); CYCLES goes on
    LD      R13, R12
    ADD     R13, 8              ; CORE_PC of core 0 (0xF000_0030)
    LD32    R4, (R13)
    LDI     R7, 0x500
    SUB     R4, R7
    JUMP.NZ R4, _bad
    LD      R13, R12
    ADD     R13, 4              ; CYCLES (0xF000_002C)
    LD32    R4, (R13)
    NOP
    LD32    R7, (R13)
    SLT     R4, R7              ; 1 if it went on
    JUMP.Z  R4, _bad
    ST32    (R11), R3           ; LEDs: CORE_STATE (core 0 waiting)
    LD      R5, 0               ; MBOX: core 0, vector 1
    LD      R14, 1
    PUSH8   R14, 0
    OR      R5, R14
    LD      R6, 9               ; the value
    MBOX    R6, R5
._halt_seen:
    LD32    R3, (R12)
    LD      R4, R3
    AND     R4, 3
    SUB     R4, 2
    BBRA.NZ R4, ._halt_seen     ; until core 0 has halted
    ST32    (R11), R3           ; LEDs: CORE_STATE (core 0 halted)
_done:
    BBRA    _done
_bad:
    LD      R4, 0
    ST32    (R11), R4           ; LEDs: 0, a check failed
    BBRA    _done
''';

const core0Source = '''
.org 0x100
    LDI     R14, _main
    JMP     R14, R0
.org 0x110                      ; vector 1: the MBOX
    LDIS    R5, 0xFF04          ; NI_MBOX_VALUE
    LD32    R7, (R5)
    RETI
.org 0x500
_main:
    WAIT
    LD      R8, R7
    SUB     R8, 9
    FBRA.NZ R8, _bad            ; the MBOX's value arrived
    HALT
_bad:
    BBRA    _bad
''';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('The conductor sees core 0 wait and halt in CORE_STATE, and wakes it '
      'with an MBOX', () async {
    final clk = SimpleClockGenerator(10);
    final reset = Logic(name: 'reset');
    final uartRx = Logic(name: 'uart_rx');
    // The conductor has no 2-word branches: its program is assembled
    // without them
    final top = ParcoreTop(
      clk: clk.clk,
      reset: reset,
      uartRx: uartRx,
      conductorBinary: assemble(conductorSource, ['-D', '__NO_LONG_BRANCHES']),
      core0Binary: assemble(core0Source),
    );
    await top.build();
    uartRx.put(1);
    reset.put(1);
    unawaited(Simulator.run());
    await clk.clk.nextPosedge;
    await clk.clk.nextPosedge;
    reset.put(0);

    // Cores 1-3 in reset (3): 0b11111101 while core 0 waits, 0b11111110
    // once it has halted
    final seen = <int>[];
    for (var i = 0; i < 4000; i++) {
      await clk.clk.nextPosedge;
      final v = top.leds.value;
      if (!v.isValid) continue;
      final led = v.toInt();
      if (seen.isEmpty || seen.last != led) seen.add(led);
      if (led == 0xFE) break;
    }
    await Simulator.endSimulation();
    expect(seen, contains(0xFD), reason: 'core 0 seen in its WAIT: $seen');
    expect(seen.last, equals(0xFE), reason: 'core 0 seen halted: $seen');
  });
}
