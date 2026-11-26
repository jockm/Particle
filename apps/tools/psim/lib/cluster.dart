// =============================================================================
// File: apps/tools/psim/lib/cluster.dart
// Project: Particle RISC Architecture
// Description: Multi-core cluster: several cores run in lock step, with FIFO
//              channels routed between them, a shared memory window, and
//              MBOX traps from one core to another. Configured by a JSON file
//              (psim -C <file.json>).
// =============================================================================
import "dart:convert";
import "dart:io";
import "dart:typed_data";

import "core.dart";
import "ring.dart";

/// A cluster configuration that cannot be used.
class ClusterConfigError implements Exception {
  final String message;
  ClusterConfigError(this.message);
  @override
  String toString() => message;
}

/// Exit code: every running core is waiting on an empty FIFO, so none can
/// make progress.
const int exitDeadlock = 19;

/// Several cores running in lock step: each cycle, every running core
/// executes one instruction, in id order.
class Cluster {
  final List<ParticleCore> cores;
  final List<int> ids;
  final List<String> names;

  /// The ring the cores' channels go through ("topology": "ring"), or null
  /// when each channel writes straight into another core's FIFO.
  final RingNetwork? ring;

  /// Lock-step cycles run.
  int cycles = 0;

  Cluster._(this.cores, this.ids, this.names, this.ring);

  /// Reads the cluster described by the JSON file at [path]. Binary paths
  /// are relative to the file's folder. [exitOnReset] is psim's
  /// `--no-exit-on-reset`, inverted.
  factory Cluster.fromFile(String path, {bool exitOnReset = true}) {
    final file = File(path);
    if (!file.existsSync()) throw ClusterConfigError("Cluster file not found: $path");
    final Object? json;
    try {
      json = jsonDecode(file.readAsStringSync());
    } on FormatException catch (e) {
      throw ClusterConfigError("$path is not valid JSON: ${e.message}");
    }
    if (json is! Map<String, dynamic>) throw ClusterConfigError("$path: expected a JSON object");
    return Cluster.fromJson(json, baseDir: file.parent.path, exitOnReset: exitOnReset);
  }

  /// The cluster described by [json] (see the simulator documentation).
  factory Cluster.fromJson(Map<String, dynamic> json, {String baseDir = ".", bool exitOnReset = true}) {
    final topology = json["topology"] ?? "point_to_point_fifo";
    if (topology != "point_to_point_fifo" && topology != "ring") {
      throw ClusterConfigError("topology must be 'point_to_point_fifo' or 'ring', not '$topology'");
    }
    final coreList = json["cores"];
    if (coreList is! List || coreList.isEmpty) {
      throw ClusterConfigError("'cores' must be a non-empty list");
    }

    // Shared memory window
    final sharedSize = _int(json["shared_memory_size"] ?? 0, "shared_memory_size");
    final sharedBase = _int(json["shared_memory_base"] ?? 0x80000000, "shared_memory_base");
    final shared = sharedSize > 0 ? Uint8List(sharedSize) : null;

    final cores = <ParticleCore>[];
    final ids = <int>[];
    final names = <String>[];
    final byId = <int, int>{};
    for (final entry in coreList) {
      if (entry is! Map<String, dynamic>) throw ClusterConfigError("each core must be a JSON object");
      final id = _int(entry["id"] ?? cores.length, "id");
      if (byId.containsKey(id)) throw ClusterConfigError("core id $id is used twice");
      final memSize = _int(entry["mem_size"] ?? 0x20000, "mem_size of core $id");
      if (memSize <= 0 || (memSize & (memSize - 1)) != 0) {
        throw ClusterConfigError("mem_size of core $id must be a power of two");
      }
      final core = ParticleCore(memSize: memSize);
      core.exitOnReset = exitOnReset;
      // Optional features, as the hardware's CpuConfig (all on by default)
      bool feature(String key) {
        final v = entry[key] ?? true;
        if (v is! bool) throw ClusterConfigError("$key of core $id must be true or false");
        return v;
      }
      core.pointerModes = feature("pointer_modes");
      core.subword = feature("subword");
      core.shadowBank = feature("shadow_bank");
      core.mboxReceive = feature("mbox_receive");
      final name = (entry["name"] as String?) ?? "core$id";
      core.label = name;
      if (shared != null) {
        core.shared = shared;
        core.sharedBase = sharedBase;
      }
      final binary = entry["binary"] as String?;
      if (binary != null) {
        final path = File(binary).isAbsolute ? binary : "$baseDir/$binary";
        final f = File(path);
        if (!f.existsSync()) throw ClusterConfigError("binary of core $id not found: $binary");
        final base = _int(entry["base_addr"] ?? 0x100, "base_addr of core $id");
        final bytes = f.readAsBytesSync();
        for (var i = 0; i < bytes.length; i++) {
          core.write8(base + i, bytes[i]);
        }
      }
      final regs = entry["initial_registers"];
      if (regs is Map) {
        regs.forEach((k, v) {
          final r = _register(k as String);
          if (r == null) throw ClusterConfigError("core $id: unknown register '$k'");
          core.r[r] = _int(v, "register $k of core $id");
        });
      }
      byId[id] = cores.length;
      cores.add(core);
      ids.add(id);
      names.add(name);
    }

    // FIFO routes and MBOX targets need every core. On a ring the cores are
    // in the order listed.
    final ring = topology == "ring" ? RingNetwork(cores) : null;
    for (var i = 0; i < cores.length; i++) {
      final entry = coreList[i] as Map<String, dynamic>;
      final routes = (entry["fifo_connections"] as Map?)?["tx"];
      if (routes is List) {
        for (final route in routes) {
          final ch = _int(route["channel"], "channel of core ${ids[i]}");
          final target = _int(route["target_core"], "target_core of core ${ids[i]}");
          final tch = _int(route["target_channel"] ?? ch, "target_channel of core ${ids[i]}");
          final t = byId[target];
          if (t == null) throw ClusterConfigError("core ${ids[i]}: target_core $target does not exist");
          if (ch < 0 || ch >= cores[i].txRoutes.length) {
            throw ClusterConfigError("core ${ids[i]}: channel $ch is out of range (0..${cores[i].txRoutes.length - 1})");
          }
          if (tch < 0 || tch >= cores[t].fifos.length) {
            throw ClusterConfigError("core ${ids[i]}: target_channel $tch is out of range (0..${cores[t].fifos.length - 1})");
          }
          if (ring != null) {
            try {
              ring.route(i, ch, t, tch);
            } on StateError catch (e) {
              throw ClusterConfigError("core ${ids[i]}: ${e.message}");
            }
          } else {
            cores[i].txRoutes[ch] = (cores[t], tch);
          }
        }
      }
      // MBOX target: named, or the other core of a pair
      final named = entry["mbox_target"];
      int? target;
      if (named != null) {
        target = byId[_int(named, "mbox_target of core ${ids[i]}")];
        if (target == null) throw ClusterConfigError("core ${ids[i]}: mbox_target $named does not exist");
      } else if (cores.length == 2) {
        target = 1 - i;
      }
      final source = i;
      final t = target;
      var warned = false;
      cores[i].onMbox = (vector, value) {
        if (t == null) {
          if (!warned) {
            stdout.writeln("\n[SIM] ${names[source]}: MBOX with no target (set 'mbox_target' for clusters of more than two cores)");
            warned = true;
          }
          return;
        }
        final dest = cores[t];
        if (!dest.halted && dest.mboxReceive) {
          dest.pendingTrap = vector & 0x0F;
          dest.pendingMboxValue = value;
        }
      };
    }
    return Cluster._(cores, ids, names, ring);
  }

  /// Runs one lock-step cycle.
  void step() {
    for (final c in cores) {
      if (!c.halted) c.step();
    }
    // The routers keep running when their cores have stopped
    ring?.step();
    cycles++;
  }

  bool get allHalted => cores.every((c) => c.halted);

  /// Whether no core can make progress: every running core is waiting on
  /// an empty FIFO, and no MBOX trap is pending.
  bool get deadlocked {
    final running = cores.where((c) => !c.halted).toList();
    return running.isNotEmpty &&
        running.every((c) => c.stalled && c.pendingTrap == null) &&
        (ring == null || ring!.idle);
  }

  /// One line per waiting core, for the deadlock message.
  List<String> get waiting => [
        for (var i = 0; i < cores.length; i++)
          if (!cores[i].halted && cores[i].stalled)
            "${names[i]} (core ${ids[i]}) waits on channel ${cores[i].waitingChannel} at PC 0x${cores[i].pc.toRadixString(16).toUpperCase().padLeft(8, '0')}"
      ];

  /// The exit code once every core has stopped: 0 when all ended with
  /// TRAP 0, otherwise the code of the lowest-numbered core that ended
  /// another way.
  int get exitCode {
    final order = List.generate(cores.length, (i) => i)..sort((a, b) => ids[a].compareTo(ids[b]));
    for (final i in order) {
      final code = cores[i].haltCode ?? 0;
      if (code != 0) return code;
    }
    return 0;
  }

  static int _int(Object? v, String what) {
    if (v is int) return v;
    if (v is String) {
      final s = v.trim().toLowerCase();
      final n = s.startsWith("0x") ? int.tryParse(s.substring(2), radix: 16) : int.tryParse(s);
      if (n != null) return n;
    }
    throw ClusterConfigError("$what must be a number, not '$v'");
  }

  static int? _register(String name) {
    final n = name.trim().toUpperCase();
    if (n == "SP") return 15;
    if (!n.startsWith("R")) return null;
    final i = int.tryParse(n.substring(1));
    return (i != null && i >= 0 && i <= 15) ? i : null;
  }
}
