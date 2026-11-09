// ==============================================================================
// Particle Debugger (p4db) - Dart port of the Debugger class in psim.py
// ==============================================================================

import 'dart:async';
import 'dart:io';

import 'psim_core.dart';
import 'psim_pycompat.dart';

/// How many instructions the run loops execute between trips through the Dart
/// event loop (which is where stdin data, Ctrl+C and stdout flushing happen).
const int _yieldEvery = 4096;

/// Tracks Ctrl+C. Python turned SIGINT into a KeyboardInterrupt exception;
/// Dart delivers it as an event, so the run loops poll this flag.
class SigintMonitor {
  StreamSubscription<ProcessSignal>? _sub;
  bool _pending = false;

  void start() {
    if (_sub != null) return;
    try {
      _sub = ProcessSignal.sigint.watch().listen((_) {
        _pending = true;
        ConsoleInput.instance.wake();
      });
    } on Object {
      _sub = null; // Signal watching unsupported: Ctrl+C keeps its default.
    }
  }

  /// Returns true (once) if Ctrl+C was pressed since the last call.
  bool consume() {
    final p = _pending;
    _pending = false;
    return p;
  }

  Future<void> stop() async {
    final s = _sub;
    _sub = null;
    if (s != null) await s.cancel();
  }
}

/// Lets the event loop run. If the core is stalled waiting for console input,
/// waits until input arrives (or Ctrl+C) instead of spinning.
Future<void> pumpEvents(ParticleCore core) async {
  final console = ConsoleInput.instance;
  if (core.waitingOnFifo == 0 && !console.isEof && !console.hasData) {
    await console.waitForActivity();
  } else if (core.waitingOnFifo >= 0) {
    // Stalled on a FIFO nothing can fill: Python spins here forever.
    await Future<void>.delayed(const Duration(milliseconds: 1));
  } else {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Runs the core until halt or [cycleLimit] cycles, without a debugger.
Future<void> runToCompletion(ParticleCore core, int cycleLimit) async {
  var sinceYield = 0;
  while (!core.halted && core.cycleCount < cycleLimit) {
    core.step();
    sinceYield++;
    if (core.waitingOnFifo >= 0 || sinceYield >= _yieldEvery) {
      sinceYield = 0;
      await pumpEvents(core);
    }
  }
}

void _out(String s) => stdout.write(s);

class Debugger {
  final ParticleCore core;
  final Set<int> breakpoints = <int>{};
  final SigintMonitor _sigint = SigintMonitor();

  Debugger(this.core);

  int _parseNum(String s) {
    s = pyStrip(s);
    if (s.toLowerCase().startsWith('0x')) {
      return pyInt(s, 16);
    }
    if (s.runes.any((c) => 'abcdefABCDEF'.runes.contains(c)) ||
        s.runes.length == 8) {
      return pyInt(s, 16);
    }
    return pyInt(s, 0);
  }

  void _write8(int addr, int val) {
    final b = val & 0xFF;
    core.write8(addr, b);
  }

  void _write16(int addr, int val) {
    val = val & 0xFFFF;
    core.write16(addr, val);
  }

  void _write32(int addr, int val) {
    val = val & 0xFFFFFFFF;
    core.write32(addr, val);
  }

  void printHelp([String? topic]) {
    const commands = <String, String>{
      'c': "c                  Continue execution until breakpoint, halt, or Ctrl+C",
      's': "s [count]          Step one instruction (or [count] instructions)",
      'r': "r                  Display registers, PC, and cycle count",
      'm': "m <addr> [n]       Dump memory at <addr> (hex or decimal) for [n] bytes",

      'w': "w <addr> <v1> ...   Write 32-bit word(s) to memory (e.g. w 0x180 0xCAFE)",
      'wh': "wh <addr> <h1> ... Write 16-bit halfword(s) to memory (e.g. wh 0x180 0xCAFE)",
      'wb': "wb <addr> <b1> ... Write raw byte(s) to memory (e.g. wb 0x180 0xFE 0xCA)",

      'b': "b <addr>           Set breakpoint at <addr>",
      'q': "q / quit           Exit the debugger",
      'help': "help [cmd]         Display help for all commands or a specific command",
    };
    if (topic != null && topic.isNotEmpty) {
      topic = topic.toLowerCase();
      final desc = commands[topic];
      if (desc != null) {
        _out('  $desc\n');
      } else {
        _out("Unknown command '$topic'. Type 'help' for available commands.\n");
      }
    } else {
      _out('\nParticle Debugger (p4db) Commands:\n');
      for (final desc in commands.values) {
        _out('  $desc\n');
      }
      _out('\n');
    }
  }

  Future<void> cmdloop() async {
    _sigint.start();
    try {
      await _cmdloop();
    } finally {
      await _sigint.stop();
    }
  }

  Future<void> _cmdloop() async {
    _out("Particle Debugger (p4db) ready. Type 'help' or '?' for commands.\n");
    while (true) {
      var line = '';
      try {
        _out('(p4db) ');
        final got = await ConsoleInput.instance.readLine(_sigint.consume);
        if (got == null) throw const _Eof();
        line = pyStrip(got);
      } on _Eof {
        _out('\n');
        break;
      } on KeyboardInterrupt {
        _out('\n');
        break;
      }
      if (line.isEmpty) continue;

      final parts = pySplit(line);
      final cmd = parts[0].toLowerCase();
      final args = parts.sublist(1);

      if (cmd == 'q' || cmd == 'quit' || cmd == 'exit') {
        break;
      } else if (cmd == 'help' || cmd == '?') {
        final topic = args.isNotEmpty ? args[0] : null;
        printHelp(topic);
      } else if (cmd == 'r') {
        _out('  PC: 0x${hex8(core.pc)}  Cycles: ${core.cycleCount}\n');
        for (var row = 0; row < 4; row++) {
          final cells = <String>[];
          for (var r = row * 4; r < (row + 1) * 4; r++) {
            cells.add('R${r.toString().padLeft(2, '0')}: 0x${hex8(core.r[r])}');
          }
          _out('  ${cells.join('  ')}\n');
        }
      } else if (cmd == 's') {
        // Like the original, a bad count is not caught (the tool exits).
        final count = args.isNotEmpty ? _parseNum(args[0]) : 1;
        var sinceYield = 0;
        for (var i = 0; i < count; i++) {
          final oldPc = core.pc;
          final active = core.step();
          _out('Stepped [0x${hex8(oldPc)}] -> PC: 0x${hex8(core.pc)}\n');
          if (!active) {
            _out('Core halted.\n');
            break;
          }
          if (++sinceYield >= _yieldEvery) {
            sinceYield = 0;
            await Future<void>.delayed(Duration.zero);
            if (_sigint.consume()) throw KeyboardInterrupt();
          }
        }
      } else if (cmd == 'c') {
        var interrupted = false;
        var sinceYield = 0;
        while (!core.halted && core.cycleCount < 1000000) {
          if (breakpoints.contains(core.pc)) {
            _out('Breakpoint hit at 0x${hex8(core.pc)}\n');
            break;
          }
          core.step();
          sinceYield++;
          if (core.waitingOnFifo >= 0 || sinceYield >= _yieldEvery) {
            sinceYield = 0;
            await pumpEvents(core);
            if (_sigint.consume()) {
              interrupted = true;
              break;
            }
          }
        }
        if (interrupted) {
          _out('\nExecution paused at PC: 0x${hex8(core.pc)}\n');
        } else if (core.halted) {
          _out('Program terminated cleanly by Trap 14 at PC: '
              '0x${hex8(core.pc)} in ${core.cycleCount} cycles.\n');
        } else if (core.cycleCount >= 1000000) {
          _out('Halted at 0x${hex8(core.pc)} after 1000000 cycles.\n');
        }
      } else if (cmd == 'b') {
        if (args.isEmpty) {
          _out('Usage: b <addr>\n');
        } else {
          try {
            final addr = _parseNum(args[0]);
            breakpoints.add(addr);
            _out('Breakpoint set at 0x${hex8(addr)}\n');
          } on PyValueError {
            _out('Invalid breakpoint address.\n');
          }
        }
      } else if (cmd == 'm') {
        if (args.isEmpty) {
          _out('Usage: m <addr> [count]\n');
          continue;
        }
        var addr = 0;
        var count = 0;
        try {
          addr = _parseNum(args[0]);
          count = args.length > 1 ? _parseNum(args[1]) : 16;
        } on PyValueError {
          _out('Invalid address or count\n');
          continue;
        }
        final endAddr = addr + count;
        var cur = addr & ~0xF;
        while (cur < endAddr) {
          final rowBytes = List<int>.generate(16, (i) => core.read8(cur + i));
          final hexStr = rowBytes.map((b) => pyHex(b, 2)).join(' ');
          final asciiStr = String.fromCharCodes(
              rowBytes.map((b) => (b >= 32 && b <= 126) ? b : 0x2E));
          _out('0x${hex8(cur)}:  $hexStr   |$asciiStr|\n');
          cur += 16;
        }
      } else if (cmd == 'w' || cmd == 'set') {
        if (args.length < 2) {
          _out('Usage: w <addr> <val1> [val2 ...]\n');
          continue;
        }
        try {
          final addr = _parseNum(args[0]);
          for (var i = 0; i < args.length - 1; i++) {
            final targetAddr = addr + (i * 4);
            final val = _parseNum(args[i + 1]) & 0xFFFFFFFF;
            _write32(targetAddr, val);
            _out('  [0x${hex8(targetAddr)}] <= 0x${hex8(val)}\n');
          }
        } on PyValueError {
          _out('Invalid address or value\n');
        }
      } else if (cmd == 'wh') {
        if (args.length < 2) {
          _out('Usage: wh <addr> <val1> [val2 ...]\n');
          continue;
        }
        try {
          final addr = _parseNum(args[0]);
          if ((addr & 1) != 0) {
            _out('Alignment error: 0x${hex8(addr)} is not 2-byte aligned.\n');
            continue;
          }
          for (var i = 0; i < args.length - 1; i++) {
            final targetAddr = addr + (i * 2);
            final val = _parseNum(args[i + 1]) & 0xFFFF;
            _write16(targetAddr, val);
            _out('  [0x${hex8(targetAddr)}] <= 0x${pyHex(val, 4)}\n');
          }
        } on PyValueError {
          _out('Invalid address or value\n');
        }
      } else if (cmd == 'wb') {
        if (args.length < 2) {
          _out('Usage: wb <addr> <byte1> [byte2 ...]\n');
          continue;
        }
        try {
          final addr = _parseNum(args[0]);
          for (var i = 0; i < args.length - 1; i++) {
            final targetAddr = addr + i;
            final val = _parseNum(args[i + 1]) & 0xFF;
            _write8(targetAddr, val);
            _out('  [0x${hex8(targetAddr)}] <= 0x${pyHex(val, 2)}\n');
          }
        } on PyValueError {
          _out('Invalid address or byte value\n');
        }
      } else {
        _out("Unknown command: $cmd. Type 'help' for available commands.\n");
      }
    }
  }
}

class _Eof implements Exception {
  const _Eof();
}
