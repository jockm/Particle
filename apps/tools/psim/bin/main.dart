// =============================================================================
// File: apps/tools/psim/bin/main.dart
// Project: Particle RISC Architecture
// Description: Particle Simulator CLI & Interactive Debugger (p4db).
// =============================================================================

import "dart:io";
import "../lib/cluster.dart";
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
  /// The cores being debugged: one, or a cluster's.
  final List<ParticleCore> cores;
  final List<String> names;
  final Cluster? cluster;
  final int maxCycles;

  /// The core that r, m, w, b and fifo work on.
  int focus = 0;
  ParticleCore get core => cores[focus];

  /// Breakpoints, by core.
  late final List<Set<int>> breakpointsOf = [for (final _ in cores) <int>{}];
  Set<int> get breakpoints => breakpointsOf[focus];
  final LineReader reader = LineReader();

  Debugger(ParticleCore core, {this.maxCycles = 10000000})
      : cores = [core],
        names = ["core0"],
        cluster = null;

  Debugger.cluster(Cluster c, {this.maxCycles = 10000000})
      : cores = c.cores,
        names = c.names,
        cluster = c;

  /// Runs one cycle: the cluster's lock step, or the single core's step.
  /// Returns false once nothing runs any more.
  bool _stepOnce() {
    final c = cluster;
    if (c == null) return core.step();
    c.step();
    return !c.allHalted;
  }

  int get _cycles => cluster?.cycles ?? core.cycleCount;

  bool get _allHalted => cores.every((c) => c.halted);

  /// The core (by index) at one of its breakpoints, or null.
  int? _atBreakpoint() {
    for (var i = 0; i < cores.length; i++) {
      if (!cores[i].halted && breakpointsOf[i].contains(cores[i].pc)) return i;
    }
    return null;
  }

  String _hex(int v) => v.toRadixString(16).toUpperCase().padLeft(8, "0");

  void dumpRegisters() {
    final pcHex = core.pc.toRadixString(16).toUpperCase().padLeft(8, "0");
    stdout.writeln("  PC: 0x$pcHex  Cycles: ${core.cycleCount}");

    void bank(String title, String prefix, List<int> values) {
      stdout.writeln();
      stdout.writeln("  [$title]");
      for (var row = 0; row < 4; row++) {
        final line = StringBuffer("  ");
        for (var col = 0; col < 4; col++) {
          final idx = (row * 4) + col;
          final hex = values[idx].toRadixString(16).toUpperCase().padLeft(8, "0");
          line.write("$prefix${idx.toString().padLeft(2, '0')}: 0x$hex  ");
        }
        stdout.writeln(line.toString());
      }
    }

    bank("Registers (R0..R15)", "R", core.r.raw);
    bank("Shadow Registers (S0..S15)", "S", core.shadowR);
    stdout.writeln();
  }

  void printHelp([String? topic]) {
    final commands = {
      'c': "c                  Continue execution until breakpoint, halt, or Ctrl+C",
      's': "s [count]          Step one instruction (or [count] instructions)",
      'r': "r                  Display PC, cycles, the 16 registers and their 16 shadows",
      'm': "m <addr> [n]       Dump memory at <addr> (hex or decimal) for [n] bytes",
      'w': "w <addr> <v1> ...  Write 32-bit word(s) to memory (e.g. w 0x180 0xCAFE)",
      'wh': "wh <addr> <h1> ... Write 16-bit halfword(s) to memory (e.g. wh 0x180 0xCAFE)",
      'wb': "wb <addr> <b1> ... Write raw byte(s) to memory (e.g. wb 0x180 0xFE 0xCA)",
      'b': "b <addr>           Set breakpoint at <addr> (on the selected core)",
      'cores': "cores              List the cores, their PCs, cycles and state",
      'switch': "switch <id>        Select the core that r, m, w, b and fifo work on",
      'fifo': "fifo               Show the selected core's FIFO channels",
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
          final oldPcs = [for (final c in cores) c.pc];
          final active = _stepOnce();
          if (cluster == null) {
            stdout.writeln("Stepped [0x${_hex(oldPcs[0])}] -> PC: 0x${_hex(core.pc)}");
          } else {
            for (var k = 0; k < cores.length; k++) {
              stdout.writeln("${k == focus ? "*" : " "} ${names[k]}: [0x${_hex(oldPcs[k])}] -> PC: 0x${_hex(cores[k].pc)}${cores[k].halted ? " (halted)" : cores[k].stalled ? " (stalled)" : ""}");
            }
          }
          if (!active) {
            stdout.writeln(cluster == null ? "Core halted." : "All cores halted.");
            break;
          }
        }
      } else if (cmd == "c") {
        // The first instruction runs even at a breakpoint, so c moves on
        var first = true;
        while (!_allHalted && _cycles < maxCycles) {
          final at = first ? null : _atBreakpoint();
          first = false;
          if (at != null) {
            focus = at;
            stdout.writeln("Breakpoint hit at 0x${_hex(cores[at].pc)}${cluster == null ? "" : " on ${names[at]}"}");
            break;
          }
          _stepOnce();
          if (cluster != null && cluster!.deadlocked) {
            stdout.writeln("Deadlock: every running core is waiting on an empty FIFO:");
            for (final w in cluster!.waiting) {
              stdout.writeln("  $w");
            }
            break;
          }
        }
        if (_allHalted) {
          stdout.writeln("Program terminated cleanly at PC: 0x${_hex(core.pc)} in $_cycles cycles.");
        } else if (_cycles >= maxCycles) {
          stdout.writeln("Halted at 0x${_hex(core.pc)} after $_cycles cycles.");
        }
      } else if (cmd == "cores") {
        for (var k = 0; k < cores.length; k++) {
          final c = cores[k];
          final state = c.halted ? "HALTED" : c.stalled ? "STALLED (channel ${c.waitingChannel})" : "RUNNING";
          stdout.writeln("${k == focus ? "*" : " "} [$k] ${names[k].padRight(16)} PC: 0x${_hex(c.pc)}  Cycles: ${c.cycleCount}  $state");
        }
      } else if (cmd == "switch") {
        final n = args.isEmpty ? null : parseNum(args[0]);
        if (n == null || n < 0 || n >= cores.length) {
          stdout.writeln("Usage: switch <id> (0..${cores.length - 1}); 'cores' lists them");
        } else {
          focus = n;
          stdout.writeln("Selected ${names[n]}.");
        }
      } else if (cmd == "fifo") {
        for (var ch = 0; ch < core.fifos.length; ch++) {
          final q = core.fifos[ch];
          final route = core.txRoutes[ch];
          final head = q.isEmpty ? "-" : "0x${_hex(q.first)}";
          final to = route == null ? "" : "  writes go to ${route.$1.label ?? "another core"} channel ${route.$2}";
          stdout.writeln("  ch$ch: ${q.length.toString().padLeft(3)} entries  head: $head  ${q.isEmpty ? "EMPTY" : q.length >= 256 ? "FULL" : ""}$to");
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

/// Exit codes. A run that ends on a TRAP instruction exits with the trap
/// number (0 or 15; 1-14 are reserved for traps that may end a run later).
const int exitPsimError = 16; // file not found, bad arguments
const int exitCycleLimit = 17; // cycle limit reached
// 18: PC ran past the end of memory (ParticleCore.exitPcOutOfMemory)

const int defaultMaxCycles = 10000000;

void main(List<String> args) {
  String? binary;
  String? clusterFile;
  var debug = false;
  var baseAddr = 0x00000100;
  var exitOnReset = true;
  var maxCycles = defaultMaxCycles;
  // Features left out of the core (a cluster file sets them per core)
  final leftOut = <String>{};

  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == "-d" || arg == "--debug") {
      debug = true;
    } else if (arg == "-b" || arg == "--base") {
      final value = (i + 1 < args.length) ? parseNum(args[++i]) : null;
      if (value == null) {
        stderr.writeln("[ERROR] $arg needs an address");
        exitCode = exitPsimError;
        return;
      }
      baseAddr = value;
    } else if (arg == "--no-exit-on-reset") {
      exitOnReset = false;
    } else if (arg == "--no-pointer-modes") {
      leftOut.add("pointer_modes");
    } else if (arg == "--no-subword") {
      leftOut.add("subword");
    } else if (arg == "--no-shadow-bank") {
      leftOut.add("shadow_bank");
    } else if (arg == "--no-mbox-receive") {
      leftOut.add("mbox_receive");
    } else if (arg == "-C" || arg == "--cluster") {
      if (i + 1 >= args.length) {
        stderr.writeln("[ERROR] $arg needs a cluster file");
        exitCode = exitPsimError;
        return;
      }
      clusterFile = args[++i];
    } else if (arg == "--max-cycles") {
      final value = (i + 1 < args.length) ? parseNum(args[++i]) : null;
      if (value == null || value <= 0) {
        stderr.writeln("[ERROR] $arg needs a positive number");
        exitCode = exitPsimError;
        return;
      }
      maxCycles = value;
    } else if (arg.startsWith("-")) {
      stderr.writeln("[ERROR] Unknown option: $arg");
      exitCode = exitPsimError;
      return;
    } else {
      binary = arg;
    }
  }

  if (clusterFile != null) {
    if (binary != null) {
      stderr.writeln("[ERROR] Give either a binary or -C <cluster file>, not both");
      exitCode = exitPsimError;
      return;
    }
    if (leftOut.isNotEmpty) {
      stderr.writeln("[ERROR] With -C, set pointer_modes, subword, shadow_bank and mbox_receive per core in the cluster file");
      exitCode = exitPsimError;
      return;
    }
    runCluster(clusterFile, debug: debug, exitOnReset: exitOnReset, maxCycles: maxCycles);
    return;
  }

  final core = ParticleCore();
  core.exitOnReset = exitOnReset;
  core.pointerModes = !leftOut.contains("pointer_modes");
  core.subword = !leftOut.contains("subword");
  core.shadowBank = !leftOut.contains("shadow_bank");
  core.mboxReceive = !leftOut.contains("mbox_receive");

  if (binary != null) {
    final file = File(binary);
    if (!file.existsSync()) {
      stderr.writeln("[ERROR] Binary file not found: $binary");
      exitCode = exitPsimError;
      return;
    }
    final bytes = file.readAsBytesSync();
    for (var i = 0; i < bytes.length; i++) {
      core.write8(baseAddr + i, bytes[i]);
    }
    stdout.writeln("Loaded ${bytes.length} bytes at 0x${baseAddr.toRadixString(16).toUpperCase().padLeft(8, '0')}. Particle Debugger (p4db) ready.");
  }

  if (debug || binary == null) {
    Debugger(core, maxCycles: maxCycles).cmdloop();
  } else {
    while (!core.halted && core.cycleCount < maxCycles) {
      core.step();
    }
    stdout.writeln("Simulation completed in ${core.cycleCount} cycles. PC = 0x${core.pc.toRadixString(16).toUpperCase().padLeft(8, '0')}");
    if (core.halted) {
      if (core.haltCode == ParticleCore.exitPcOutOfMemory) {
        stdout.writeln("[SIM] PC ran past the end of memory without a trap");
      }
      exitCode = core.haltCode ?? 0;
    } else {
      stdout.writeln("[SIM] Cycle limit ($maxCycles) reached");
      exitCode = exitCycleLimit;
    }
  }
}

/// Runs the cluster described by [path], or debugs it.
void runCluster(String path, {required bool debug, required bool exitOnReset, required int maxCycles}) {
  final Cluster cluster;
  try {
    cluster = Cluster.fromFile(path, exitOnReset: exitOnReset);
  } on ClusterConfigError catch (e) {
    stderr.writeln("[ERROR] $e");
    exitCode = exitPsimError;
    return;
  }
  stdout.writeln("Loaded cluster of ${cluster.cores.length} cores: ${cluster.names.join(", ")}.");
  if (debug) {
    Debugger.cluster(cluster, maxCycles: maxCycles).cmdloop();
    return;
  }
  while (!cluster.allHalted && cluster.cycles < maxCycles) {
    cluster.step();
    if (cluster.deadlocked) {
      stdout.writeln("\n[SIM] Deadlock after ${cluster.cycles} cycles: every running core is waiting on an empty FIFO:");
      for (final w in cluster.waiting) {
        stdout.writeln("[SIM]   $w");
      }
      exitCode = exitDeadlock;
      return;
    }
  }
  stdout.writeln("Simulation completed in ${cluster.cycles} cycles.");
  if (cluster.ring != null) stdout.writeln("  Ring: ${cluster.ring!.hops} packet hops");
  for (var i = 0; i < cluster.cores.length; i++) {
    final c = cluster.cores[i];
    final state = c.halted ? "halted (exit ${c.haltCode ?? 0})" : "running";
    stdout.writeln("  ${cluster.names[i]} (core ${cluster.ids[i]}): PC = 0x${c.pc.toRadixString(16).toUpperCase().padLeft(8, '0')}, $state");
  }
  if (cluster.allHalted) {
    exitCode = cluster.exitCode;
  } else {
    stdout.writeln("[SIM] Cycle limit ($maxCycles) reached");
    exitCode = exitCycleLimit;
  }
}
