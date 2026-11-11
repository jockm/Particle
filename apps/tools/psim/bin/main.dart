// =============================================================================
// File: apps/tools/psim/bin/main.dart
// Project: Particle RISC Architecture
// Description: Particle Simulator CLI & Interactive Debugger (p4db).
// =============================================================================

import "dart:io";
import "../lib/core.dart";
import "../lib/line_reader.dart";

int? parseNum(String s) {
  final clean = s.trim();
  if (clean.isEmpty) return null;
  if (clean.toLowerCase().startsWith("0x")) {
    return int.tryParse(clean.substring(2), radix: 16);
  }
  if (clean.startsWith("0b") || clean.startsWith("0B")) {
    return int.tryParse(clean.substring(2), radix: 2);
  }
  return int.tryParse(clean, radix: 10);
}

class Debugger {
  final ParticleCore core;
  final Set<int> breakpoints = {};
  final LineReader reader = LineReader();

  Debugger(this.core);

  void dumpRegisters() {
    final pcHex = core.pc.toRadixString(16).toUpperCase().padLeft(8, "0");
    stdout.writeln("  PC: 0x$pcHex  Cycles: ${core.cycleCount}  RBASE: ${core.rbase} (Window maps R1..R15 -> phys ${(1 + core.rbase) & 0x1F}..${(15 + core.rbase) & 0x1F})");

    stdout.writeln();
    stdout.writeln("  [Physical Register File (0..31)]");
    for (var row = 0; row < 8; row++) {
      final line = StringBuffer("  ");
      for (var col = 0; col < 4; col++) {
        final rIdx = (row * 4) + col;
        final hex = core.r.raw[rIdx].toRadixString(16).toUpperCase().padLeft(8, "0");
        final rStr = "P${rIdx.toString().padLeft(2, '0')}";
        line.write("$rStr: 0x$hex  ");
      }
      stdout.writeln(line.toString());
    }

    stdout.writeln();
    stdout.writeln("  [Shadow Register File (0..31)]");
    for (var row = 0; row < 8; row++) {
      final line = StringBuffer("  ");
      for (var col = 0; col < 4; col++) {
        final sIdx = (row * 4) + col;
        final hex = core.shadowR[sIdx].toRadixString(16).toUpperCase().padLeft(8, "0");
        final sStr = "S${sIdx.toString().padLeft(2, '0')}";
        line.write("$sStr: 0x$hex  ");
      }
      stdout.writeln(line.toString());
    }

    stdout.writeln();
    stdout.writeln("  [Active Virtual Registers (vR0..vR15)]");
    for (var row = 0; row < 4; row++) {
      final line = StringBuffer("  ");
      for (var col = 0; col < 4; col++) {
        final vIdx = (row * 4) + col;
        final hex = core.r[vIdx].toRadixString(16).toUpperCase().padLeft(8, "0");
        final vStr = "R${vIdx.toString().padLeft(2, '0')}";
        line.write("$vStr: 0x$hex  ");
      }
      stdout.writeln(line.toString());
    }
    stdout.writeln();
  }

  void printHelp([String? topic]) {
    final commands = {
      'c': "c                  Continue execution until breakpoint, halt, or Ctrl+C",
      's': "s [count]          Step one instruction (or [count] instructions)",
      'r': "r                  Display PC, cycles, RBASE, all 32 physical and 16 active virtual registers",
      'm': "m <addr> [n]       Dump memory at <addr> (hex or decimal) for [n] bytes",
      'w': "w <addr> <v1> ...  Write 32-bit word(s) to memory (e.g. w 0x180 0xCAFE)",
      'wh': "wh <addr> <h1> ... Write 16-bit halfword(s) to memory (e.g. wh 0x180 0xCAFE)",
      'wb': "wb <addr> <b1> ... Write raw byte(s) to memory (e.g. wb 0x180 0xFE 0xCA)",
      'b': "b <addr>           Set breakpoint at <addr>",
      'q': "q / quit           Exit the debugger",
      'help': "help [cmd]         Display help for all commands or a specific command",
    };

    if (topic != null && commands.containsKey(topic.toLowerCase())) {
      stdout.writeln("  ${commands[topic.toLowerCase()]}");
    } else {
      stdout.writeln("\nParticle Debugger (p4db) Commands:");
      for (final desc in commands.values) {
        stdout.writeln("  $desc");
      }
      stdout.writeln();
    }
  }

  void cmdloop() {
    stdout.writeln("Particle Debugger (p4db) ready. Type 'help' or '?' for commands.");
    while (true) {
      final line = reader.readLine("(p4db) ");
      if (line == null) break;
      if (line.isEmpty) continue;

      final parts = line.split(RegExp(r"\s+"));
      final cmd = parts[0].toLowerCase();
      final args = parts.sublist(1);

      if (cmd == "q" || cmd == "quit" || cmd == "exit") {
        break;
      } else if (cmd == "help" || cmd == "?") {
        printHelp(args.isNotEmpty ? args[0] : null);
      } else if (cmd == "r") {
        dumpRegisters();
      } else if (cmd == "s") {
        final count = (args.isNotEmpty) ? (parseNum(args[0]) ?? 1) : 1;
        for (var i = 0; i < count; i++) {
          final oldPc = core.pc;
          final active = core.step();
          final oldPcHex = oldPc.toRadixString(16).toUpperCase().padLeft(8, "0");
          final pcHex = core.pc.toRadixString(16).toUpperCase().padLeft(8, "0");
          stdout.writeln("Stepped [0x$oldPcHex] -> PC: 0x$pcHex");
          if (!active) {
            stdout.writeln("Core halted.");
            break;
          }
        }
      } else if (cmd == "c") {
        while (!core.halted && core.cycleCount < 10000000) {
          if (breakpoints.contains(core.pc)) {
            final pcHex = core.pc.toRadixString(16).toUpperCase().padLeft(8, "0");
            stdout.writeln("Breakpoint hit at 0x$pcHex");
            break;
          }
          core.step();
        }
        if (core.halted) {
          final pcHex = core.pc.toRadixString(16).toUpperCase().padLeft(8, "0");
          stdout.writeln("Program terminated cleanly at PC: 0x$pcHex in ${core.cycleCount} cycles.");
        } else if (core.cycleCount >= 10000000) {
          final pcHex = core.pc.toRadixString(16).toUpperCase().padLeft(8, "0");
          stdout.writeln("Halted at 0x$pcHex after ${core.cycleCount} cycles.");
        }
      } else if (cmd == "b") {
        if (args.isEmpty) {
          stdout.writeln("Usage: b <addr>");
        } else {
          final addr = parseNum(args[0]);
          if (addr != null) {
            breakpoints.add(addr);
            stdout.writeln("Breakpoint set at 0x${addr.toRadixString(16).toUpperCase().padLeft(8, '0')}");
          } else {
            stdout.writeln("Invalid breakpoint address.");
          }
        }
      } else if (cmd == "m") {
        if (args.isEmpty) {
          stdout.writeln("Usage: m <addr> [count]");
          continue;
        }
        final addr = parseNum(args[0]);
        final count = (args.length > 1) ? parseNum(args[1]) ?? 16 : 16;
        if (addr == null) {
          stdout.writeln("Invalid address or count");
          continue;
        }
        final endAddr = addr + count;
        var cur = addr & ~0xF;
        while (cur < endAddr) {
          final rowBytes = <int>[];
          for (var i = 0; i < 16; i++) {
            rowBytes.add(core.read8(cur + i));
          }
          final hexStr = rowBytes.map((b) => b.toRadixString(16).toUpperCase().padLeft(2, "0")).join(" ");
          final asciiStr = rowBytes.map((b) => (b >= 32 && b <= 126) ? String.fromCharCode(b) : ".").join();
          final curHex = cur.toRadixString(16).toUpperCase().padLeft(8, "0");
          stdout.writeln("0x$curHex:  $hexStr   |$asciiStr|");
          cur += 16;
        }
      } else if (cmd == "w" || cmd == "set") {
        if (args.length < 2) {
          stdout.writeln("Usage: w <addr> <val1> [val2 ...]");
          continue;
        }
        final addr = parseNum(args[0]);
        if (addr == null) {
          stdout.writeln("Invalid address");
          continue;
        }
        for (var i = 0; i < args.length - 1; i++) {
          final val = parseNum(args[i + 1]);
          if (val == null) continue;
          final target = addr + (i * 4);
          core.write32(target, val);
          stdout.writeln("  [0x${target.toRadixString(16).toUpperCase().padLeft(8, '0')}] <= 0x${val.toRadixString(16).toUpperCase().padLeft(8, '0')}");
        }
      } else if (cmd == "wh") {
        if (args.length < 2) {
          stdout.writeln("Usage: wh <addr> <val1> [val2 ...]");
          continue;
        }
        final addr = parseNum(args[0]);
        if (addr == null || (addr & 1) != 0) {
          stdout.writeln("Alignment error or invalid address.");
          continue;
        }
        for (var i = 0; i < args.length - 1; i++) {
          final val = parseNum(args[i + 1]);
          if (val == null) continue;
          final target = addr + (i * 2);
          core.write16(target, val);
          stdout.writeln("  [0x${target.toRadixString(16).toUpperCase().padLeft(8, '0')}] <= 0x${val.toRadixString(16).toUpperCase().padLeft(4, '0')}");
        }
      } else if (cmd == "wb") {
        if (args.length < 2) {
          stdout.writeln("Usage: wb <addr> <byte1> [byte2 ...]");
          continue;
        }
        final addr = parseNum(args[0]);
        if (addr == null) {
          stdout.writeln("Invalid address");
          continue;
        }
        for (var i = 0; i < args.length - 1; i++) {
          final val = parseNum(args[i + 1]);
          if (val == null) continue;
          final target = addr + i;
          core.write8(target, val);
          stdout.writeln("  [0x${target.toRadixString(16).toUpperCase().padLeft(8, '0')}] <= 0x${val.toRadixString(16).toUpperCase().padLeft(2, '0')}");
        }
      } else {
        stdout.writeln("Unknown command: $cmd. Type 'help' for available commands.");
      }
    }
  }
}

void main(List<String> args) {
  String? binary;
  var debug = false;
  var baseAddr = 0x00000100;

  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == "-d" || arg == "--debug") {
      debug = true;
    } else if (arg == "-b" || arg == "--base") {
      if (i + 1 < args.length) {
        baseAddr = parseNum(args[++i]) ?? baseAddr;
      }
    } else if (!arg.startsWith("-")) {
      binary = arg;
    }
  }

  final core = ParticleCore();

  if (binary != null) {
    final file = File(binary);
    if (!file.existsSync()) {
      stderr.writeln("[ERROR] Binary file not found: $binary");
      exit(1);
    }
    final bytes = file.readAsBytesSync();
    for (var i = 0; i < bytes.length; i++) {
      core.write8(baseAddr + i, bytes[i]);
    }
    stdout.writeln("Loaded ${bytes.length} bytes at 0x${baseAddr.toRadixString(16).toUpperCase().padLeft(8, '0')}. Particle Debugger (p4db) ready.");
  }

  if (debug || binary == null) {
    Debugger(core).cmdloop();
  } else {
    while (!core.halted && core.cycleCount < 10000000) {
      core.step();
    }
    stdout.writeln("Simulation completed in ${core.cycleCount} cycles. PC = 0x${core.pc.toRadixString(16).toUpperCase().padLeft(8, '0')}");
  }
}
