// The conductor's watchdog (Road to GHz item 16, 446-447): its own code
// (firmware/parcore/conductor/watchdog.inc, with short timings) in a small
// conductor program, over the ACTIVITY register. Core 1 runs a while and
// then blocks for good in a FIFO.R: the watchdog fires and blinks FAULT_HANG
// with LED 7 (0x86) - unless core 0 is asleep in its WAIT, the sign that the
// guest program has ended. pmon (pmon.inc) runs in the loop too, its console
// at a fast baud rate.

import 'dart:async';
import 'dart:io';

import 'package:rohd/rohd.dart';
import 'package:test/test.dart';

import '../lib/parcore_top.dart';

/// [source] assembled by pasm (with [options]); the binary starts at 0x100.
List<int> assemble(String source, [List<String> options = const []]) {
  final dir = Directory.systemTemp.createTempSync('parcore_watchdog_');
  File('${dir.path}/p.asm').writeAsStringSync(source);
  final res = Process.runSync('../../build/tools/pasm', [
    '${dir.path}/p.asm', '-I', '../..', '-I', '../../lib',
    '-o', '${dir.path}/p.bin', ...options,
  ]);
  if (res.exitCode != 0) throw StateError('pasm failed:\n${res.stdout}${res.stderr}');
  return File('${dir.path}/p.bin').readAsBytesSync();
}

/// A conductor that releases the cores in [release] (bit n: core n) and runs
/// the real supervisor loop, with its watchdog.
String conductor(int release) => '''
.include "lib/common.inc"
.include "firmware/parcore/conductor/conductor_regs.inc"
.define FAULT_HANG 6
.org 0x100
_reset_vector:
    LDI     R14, _main
    JMP     R14, R0
.org 0x200
_main:
    LDI     SP, 0x2000
    LOAD32  R5, 0xF0000000      ; RST_CTRL
    LD      R14, ${0x3F & ~release}
    ST32    (R5), R14
    LDI     R1, 0x11            ; LEDs: running
    SET_LEDS
    JUMP    _supervisor_idle
_fault_delay:
    LD      R1, 10
._d:
    SUB     R1, 1
    BBRA.NZ R1, ._d
    RRET
.include "firmware/parcore/conductor/watchdog.inc"
.include "firmware/parcore/conductor/pmon.inc"
.include "firmware/parcore/conductor/spi.inc"
''';

/// Core 1: about 1,000 cycles of work, then a FIFO.R that never ends (its
/// channel 0 comes from core 0, which sends nothing).
const core1Source = '''
.org 0x100
    LDI     R14, _main
    JMP     R14, R0
.org 0x500
_main:
    LDI     R2, 300
._work:
    SUB     R2, 1
    BBRA.NZ R2, ._work
    FIFO.R  R3, R0
_h: BBRA    _h
''';

/// Core 0, as at the end of a program: asleep in a WAIT.
const core0Source = '''
.org 0x100
    LDI     R14, _main
    JMP     R14, R0
.org 0x500
_main:
    WAIT
_h: BBRA    _h
''';

/// Runs [cycles] cycles and returns the LED values seen, in order, each with
/// the cycle it first appeared.
Future<List<(int, int)>> run(ParcoreTop top, SimpleClockGenerator clk,
    Logic reset, Logic uartRx, int cycles) async {
  await top.build();
  uartRx.put(1);
  reset.put(1);
  unawaited(Simulator.run());
  await clk.clk.nextPosedge;
  await clk.clk.nextPosedge;
  reset.put(0);
  final seen = <(int, int)>[];
  for (var i = 0; i < cycles; i++) {
    await clk.clk.nextPosedge;
    final v = top.leds.value;
    if (!v.isValid) continue;
    final led = v.toInt();
    if (seen.isEmpty || seen.last.$1 != led) seen.add((led, i));
    if (led == 0x86) break;
  }
  await Simulator.endSimulation();
  return seen;
}

const timings = [
  '-D', '__NO_LONG_BRANCHES', '-D', 'WATCH_POLL=200', '-D', 'WATCH_LIMIT=20',
  '-D', 'WATCH_BLINK=1',
];

/// The console's baud rate: 4 cycles a bit at 25 MHz, so that pmon's
/// messages take little time
const fastBaud = 6250000;

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('The watchdog fires once core 1 has done nothing for WATCH_LIMIT polls',
      () async {
    final clk = SimpleClockGenerator(10);
    final reset = Logic(name: 'reset');
    final uartRx = Logic(name: 'uart_rx');
    final top = ParcoreTop(
      clk: clk.clk,
      reset: reset,
      uartRx: uartRx,
      conductorBinary: assemble(conductor(0x02), timings),
      core1Binary: assemble(core1Source),
      consoleBaud: fastBaud,
    );
    final seen = await run(top, clk, reset, uartRx, 20000);
    final leds = [for (final s in seen) s.$1];
    expect(leds, contains(0x11), reason: 'running: $seen');
    expect(leds.last, equals(0x86), reason: 'FAULT_HANG with LED 7: $seen');
    // Not before core 1 has blocked and WATCH_LIMIT polls have passed
    final fired = seen.last.$2;
    expect(fired, greaterThan(1000 + 20 * 200), reason: 'too early: $seen');
  });

  test('It stays quiet while core 0 sleeps in its WAIT (the program has ended)',
      () async {
    final clk = SimpleClockGenerator(10);
    final reset = Logic(name: 'reset');
    final uartRx = Logic(name: 'uart_rx');
    final top = ParcoreTop(
      clk: clk.clk,
      reset: reset,
      uartRx: uartRx,
      conductorBinary: assemble(conductor(0x03), timings),
      core0Binary: assemble(core0Source),
      core1Binary: assemble(core1Source),
      consoleBaud: fastBaud,
    );
    final seen = await run(top, clk, reset, uartRx, 15000);
    final leds = [for (final s in seen) s.$1];
    expect(leds, isNot(contains(0x86)), reason: '$seen');
    expect(leds.last, equals(0x11));
  });
}
