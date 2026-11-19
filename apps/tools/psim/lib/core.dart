// =============================================================================
// File: apps/tools/psim/lib/core.dart
// Project: Particle RISC Architecture
// Description: Particle 32-bit RISC core engine with Option-2 RBASE windowing.
// =============================================================================

import "dart:collection";
import "dart:io";
import "dart:typed_data";

const int mask32 = 0xFFFFFFFF;
const int sign32 = 0x80000000;

int toSigned32(int val) {
  val &= mask32;
  return (val < sign32) ? val : val - 0x100000000;
}

int toUnsigned32(int val) {
  return val & mask32;
}

class RegisterWindowView {
  final ParticleCore core;
  final Uint32List raw = Uint32List(32);

  RegisterWindowView(this.core);

  int effIdx(int idx) {
    if (idx == 0) return 0;
    return (idx + core.rbase) & 0x1F;
  }

  int operator [](int idx) {
    return raw[effIdx(idx)];
  }

  void operator []=(int idx, int val) {
    final phys = effIdx(idx);
    if (phys != 0) {
      raw[phys] = val & mask32;
    }
  }
}

class ParticleCore {
  final int memSize;
  late final Uint8List mem;
  final ByteData byteData;

  int rbase = 0;
  late final RegisterWindowView r;
  final Uint32List shadowR = Uint32List(32);

  int pc = 0x00000100;
  final List<Queue<int>> fifos;
  final int trapBase = 0x00000100;
  final int trapStride = 16;

  int cycleCount = 0;
  bool halted = false;

  /// Why the core halted, as the simulator's exit code: the trap number for
  /// a TRAP instruction that ends the run (0 or 15), or [exitPcOutOfMemory].
  int? haltCode;

  /// When true (the default) a `TRAP 0` instruction ends the run with exit
  /// code 0. When false it jumps to the reset vector like any other trap.
  bool exitOnReset = true;

  /// Exit code: the PC ran past the end of memory without a trap.
  static const int exitPcOutOfMemory = 18;

  /// Set when a trap is taken while an instruction executes (for example a
  /// misaligned data access), so the instruction does not overwrite the
  /// vector address with its own next PC.
  bool _trapTaken = false;
  bool stalled = false;

  /// The channel this core is waiting on while [stalled], for messages.
  int? waitingChannel;

  // ---------------- Multi-core (cluster) connections ----------------

  /// The core's name in messages, set in a cluster.
  String? label;

  /// Where each local channel's writes go: another core's receive channel,
  /// or null for this core's own channel (and the console on channel 0).
  final List<(ParticleCore, int)?> txRoutes = List.filled(4, null);

  /// Memory shared by every core of a cluster, at [sharedBase].
  Uint8List? shared;
  int sharedBase = 0;

  /// Called when this core executes MBOX with vector Imm4 and the value of
  /// Rr; null when there is no other core (MBOX does nothing).
  void Function(int vector, int value)? onMbox;

  /// A trap another core raised with MBOX, taken before the next
  /// instruction, and the value it sent. A newer MBOX replaces an older one.
  int? pendingTrap;
  int pendingMboxValue = 0;

  ParticleCore({this.memSize = 0x20000, int numFifos = 4})
      : fifos = List.generate(numFifos, (_) => Queue<int>()),
        byteData = ByteData(memSize) {
    mem = byteData.buffer.asUint8List();
    r = RegisterWindowView(this);
  }

  void reset() {
    for (var i = 0; i < 32; i++) {
      r.raw[i] = 0;
      shadowR[i] = 0;
    }
    rbase = 0;
    pc = trapBase;
    cycleCount = 0;
    halted = false;
    haltCode = null;
    stalled = false;
    waitingChannel = null;
    pendingTrap = null;
    for (final f in fifos) {
      f.clear();
    }
  }

  /// Takes trap [trapIdx]. Only a TRAP instruction ([fromInstruction])
  /// numbered 0 (unless [exitOnReset] is off) or 15 ends the run; every
  /// other trap, and every fault raised by the core, goes to its vector.
  void triggerTrap(int trapIdx, [int? returnPc, bool fromInstruction = false]) {
    final ret = returnPc ?? ((pc + 2) & mask32);
    r[14] = ret;

    if (fromInstruction && trapIdx == 0 && exitOnReset) {
      final r1Hex = r[1].toRadixString(16).toUpperCase().padLeft(8, "0");
      final pcHex = ret.toRadixString(16).toUpperCase().padLeft(8, "0");
      stdout.writeln("\n[SIM] ${label == null ? "" : "$label: "}Reset Trap 0 triggered at PC: 0x$pcHex (R1=0x$r1Hex, Cycles=$cycleCount)");
      halted = true;
      haltCode = 0;
      return;
    }

    if (fromInstruction && trapIdx == 15) {
      final pcHex = ret.toRadixString(16).toUpperCase().padLeft(8, "0");
      stdout.writeln("\n[SIM] ${label == null ? "" : "$label: "}Out-of-Bounds / Sentinel Trap 15 triggered at PC: 0x$pcHex (Cycles=$cycleCount)");
      halted = true;
      haltCode = 15;
      return;
    }

    pc = (trapBase + (trapIdx * trapStride)) & mask32;
    _trapTaken = true;
  }

  /// The offset of [addr] in the shared window, or -1 outside it.
  int _sharedOffset(int addr) {
    final sh = shared;
    if (sh == null) return -1;
    final off = (addr & mask32) - sharedBase;
    return (off >= 0 && off < sh.length) ? off : -1;
  }

  int read8(int addr) {
    final off = _sharedOffset(addr);
    if (off >= 0) return shared![off];
    return mem[addr & (memSize - 1)];
  }

  void write8(int addr, int val) {
    final off = _sharedOffset(addr);
    if (off >= 0) {
      shared![off] = val & 0xFF;
      return;
    }
    mem[addr & (memSize - 1)] = val & 0xFF;
  }

  int read16(int addr) {
    if ((addr & 1) != 0) {
      triggerTrap(14, pc);
      return 0;
    }
    if (_sharedOffset(addr) >= 0) return read8(addr) | (read8(addr + 1) << 8);
    final a = addr & (memSize - 1);
    return mem[a] | (mem[(a + 1) & (memSize - 1)] << 8);
  }

  void write16(int addr, int val) {
    if ((addr & 1) != 0) {
      triggerTrap(14, pc);
      return;
    }
    if (_sharedOffset(addr) >= 0) {
      write8(addr, val);
      write8(addr + 1, val >> 8);
      return;
    }
    final a = addr & (memSize - 1);
    mem[a] = val & 0xFF;
    mem[(a + 1) & (memSize - 1)] = (val >> 8) & 0xFF;
  }

  int read32(int addr) {
    if ((addr & 3) != 0) {
      triggerTrap(14, pc);
      return 0;
    }
    if (_sharedOffset(addr) >= 0) {
      return read8(addr) | (read8(addr + 1) << 8) | (read8(addr + 2) << 16) | (read8(addr + 3) << 24);
    }
    final a = addr & (memSize - 1);
    return mem[a] |
        (mem[(a + 1) & (memSize - 1)] << 8) |
        (mem[(a + 2) & (memSize - 1)] << 16) |
        (mem[(a + 3) & (memSize - 1)] << 24);
  }

  void write32(int addr, int val) {
    if ((addr & 3) != 0) {
      triggerTrap(14, pc);
      return;
    }
    if (_sharedOffset(addr) >= 0) {
      for (var i = 0; i < 4; i++) {
        write8(addr + i, val >> (8 * i));
      }
      return;
    }
    final a = addr & (memSize - 1);
    mem[a] = val & 0xFF;
    mem[(a + 1) & (memSize - 1)] = (val >> 8) & 0xFF;
    mem[(a + 2) & (memSize - 1)] = (val >> 16) & 0xFF;
    mem[(a + 3) & (memSize - 1)] = (val >> 24) & 0xFF;
  }

  /// The queue a write to local channel [fid] goes into: the routed core's
  /// receive channel, or this core's own.
  Queue<int> _txQueue(int fid) {
    final route = fid < txRoutes.length ? txRoutes[fid] : null;
    return route == null ? fifos[fid] : route.$1.fifos[route.$2];
  }

  bool step() {
    if (halted || pc >= memSize) {
      if (!halted) haltCode = exitPcOutOfMemory;
      halted = true;
      return false;
    }

    // A trap raised by another core's MBOX: a stalled instruction is
    // abandoned, and runs again when the handler returns
    final pending = pendingTrap;
    if (pending != null) {
      pendingTrap = null;
      stalled = false;
      waitingChannel = null;
      // The value goes to MBOX_VALUE, the word below the trap table
      write32((trapBase - 4) & mask32, pendingMboxValue);
      triggerTrap(pending, pc);
      _trapTaken = false;
      cycleCount++;
      return true;
    }

    if ((pc & 1) != 0) {
      triggerTrap(14, pc);
      _trapTaken = false;
      cycleCount++;
      return true;
    }

    _trapTaken = false;
    stalled = false;
    waitingChannel = null;

    final inst = read16(pc);
    final opcode = (inst >> 8) & 0xFF;
    final rr = (inst >> 4) & 0x0F;
    final rl = inst & 0x0F;
    final imm8 = inst & 0xFF;
    final imm4 = inst & 0x0F;

    var nextPc = (pc + 2) & mask32;

    // A load, store or TAS that takes vector 14 (misaligned) changes no
    // register, as on hardware: save them, and put them back if it traps
    final instPc = pc;
    final savedRegs = ((opcode >= 0x10 && opcode <= 0x39) || opcode == 0x8B)
        ? Uint32List.fromList(r.raw)
        : null;

    // ---------------- Register Loads & Immediates (0x00 - 0x08) ----------------
    if (opcode == 0x00) {
      r[rr] = r[rl];
    } else if (opcode == 0x01) {
      r[rr] = imm4;
    } else if (opcode == 0x02) {
      r[14] = imm8;
    } else if (opcode == 0x03) {
      r[rr] = toUnsigned32(-imm4);
    } else if (opcode == 0x04) {
      r[14] = toUnsigned32(-imm8);
    } else if (opcode == 0x05) {
      r[rr] = ((r[rr] << 4) | imm4) & mask32;
    } else if (opcode == 0x06) {
      r[14] = ((r[14] << 8) | imm8) & mask32;
    } else if (opcode == 0x07) {
      final imm16 = read16((pc + 2) & mask32);
      if (!_trapTaken) {
        r[rl] = imm16;
        nextPc = (pc + 4) & mask32;
      }
    } else if (opcode == 0x08) {
      final imm16 = read16((pc + 2) & mask32);
      if (!_trapTaken) {
        final immS = (imm16 < 0x8000) ? imm16 : imm16 - 0x10000;
        r[rl] = toUnsigned32(immS);
        nextPc = (pc + 4) & mask32;
      }

    // ---------------- Memory Group (8-bit: 0x10 - 0x19) ----------------
    } else if (opcode == 0x10) {
      r[rr] = read8(r[rl]);
    } else if (opcode == 0x11) {
      final addr = (r[rl] + 1) & mask32;
      r[rl] = addr;
      r[rr] = read8(addr);
    } else if (opcode == 0x12) {
      final addr = r[rl];
      r[rl] = (addr + 1) & mask32;
      r[rr] = read8(addr);
    } else if (opcode == 0x13) {
      final addr = (r[rl] - 1) & mask32;
      r[rl] = addr;
      r[rr] = read8(addr);
    } else if (opcode == 0x14) {
      final addr = r[rl];
      r[rl] = (addr - 1) & mask32;
      r[rr] = read8(addr);
    } else if (opcode == 0x15) {
      write8(r[rr], r[rl]);
    } else if (opcode == 0x16) {
      final addr = (r[rr] + 1) & mask32;
      r[rr] = addr;
      write8(addr, r[rl]);
    } else if (opcode == 0x17) {
      final addr = r[rr];
      r[rr] = (addr + 1) & mask32;
      write8(addr, r[rl]);
    } else if (opcode == 0x18) {
      final addr = (r[rr] - 1) & mask32;
      r[rr] = addr;
      write8(addr, r[rl]);
    } else if (opcode == 0x19) {
      final addr = r[rr];
      r[rr] = (addr - 1) & mask32;
      write8(addr, r[rl]);

    // ---------------- Memory Group (16-bit: 0x20 - 0x29) ----------------
    } else if (opcode == 0x20) {
      r[rr] = read16(r[rl]);
    } else if (opcode == 0x21) {
      final addr = (r[rl] + 2) & mask32;
      r[rl] = addr;
      r[rr] = read16(addr);
    } else if (opcode == 0x22) {
      final addr = r[rl];
      r[rl] = (addr + 2) & mask32;
      r[rr] = read16(addr);
    } else if (opcode == 0x23) {
      final addr = (r[rl] - 2) & mask32;
      r[rl] = addr;
      r[rr] = read16(addr);
    } else if (opcode == 0x24) {
      final addr = r[rl];
      r[rl] = (addr - 2) & mask32;
      r[rr] = read16(addr);
    } else if (opcode == 0x25) {
      write16(r[rr], r[rl]);
    } else if (opcode == 0x26) {
      final addr = (r[rr] + 2) & mask32;
      r[rr] = addr;
      write16(addr, r[rl]);
    } else if (opcode == 0x27) {
      final addr = r[rr];
      r[rr] = (addr + 2) & mask32;
      write16(addr, r[rl]);
    } else if (opcode == 0x28) {
      final addr = (r[rr] - 2) & mask32;
      r[rr] = addr;
      write16(addr, r[rl]);
    } else if (opcode == 0x29) {
      final addr = r[rr];
      r[rr] = (addr - 2) & mask32;
      write16(addr, r[rl]);

    // ---------------- Memory Group (32-bit: 0x30 - 0x39) ----------------
    } else if (opcode == 0x30) {
      r[rr] = read32(r[rl]);
    } else if (opcode == 0x31) {
      final addr = (r[rl] + 4) & mask32;
      r[rl] = addr;
      r[rr] = read32(addr);
    } else if (opcode == 0x32) {
      final addr = r[rl];
      r[rl] = (addr + 4) & mask32;
      r[rr] = read32(addr);
    } else if (opcode == 0x33) {
      final addr = (r[rl] - 4) & mask32;
      r[rl] = addr;
      r[rr] = read32(addr);
    } else if (opcode == 0x34) {
      final addr = r[rl];
      r[rl] = (addr - 4) & mask32;
      r[rr] = read32(addr);
    } else if (opcode == 0x35) {
      write32(r[rr], r[rl]);
    } else if (opcode == 0x36) {
      final addr = (r[rr] + 4) & mask32;
      r[rr] = addr;
      write32(addr, r[rl]);
    } else if (opcode == 0x37) {
      final addr = r[rr];
      r[rr] = (addr + 4) & mask32;
      write32(addr, r[rl]);
    } else if (opcode == 0x38) {
      final addr = (r[rr] - 4) & mask32;
      r[rr] = addr;
      write32(addr, r[rl]);
    } else if (opcode == 0x39) {
      final addr = r[rr];
      r[rr] = (addr - 4) & mask32;
      write32(addr, r[rl]);

    // ---------------- Unsigned Arithmetic (0x40 - 0x48) ----------------
    } else if (opcode == 0x48) {
      r[rr] = toUnsigned32(-toSigned32(r[rr]));
    } else if (opcode == 0x40) {
      r[rr] = (r[rr] + r[rl]) & mask32;
    } else if (opcode == 0x41) {
      r[rr] = (r[rr] - r[rl]) & mask32;
    } else if (opcode == 0x42) {
      final denom = r[rl];
      r[rr] = (denom == 0) ? 0xFFFFFFFF : (r[rr] ~/ denom);
    } else if (opcode == 0x43) {
      final denom = r[rl];
      r[rr] = (denom == 0) ? r[rr] : (r[rr] % denom);
    } else if (opcode == 0x44) {
      r[rr] = (r[rr] + imm4) & mask32;
    } else if (opcode == 0x45) {
      r[rr] = (r[rr] - imm4) & mask32;
    } else if (opcode == 0x46) {
      r[rr] = (imm4 == 0) ? 0xFFFFFFFF : (r[rr] ~/ imm4);
    } else if (opcode == 0x47) {
      r[rr] = (imm4 == 0) ? r[rr] : (r[rr] % imm4);

    // ---------------- Signed Arithmetic (0x50 - 0x57) ----------------
    } else if (opcode == 0x50) {
      r[rr] = (toSigned32(r[rr]) + toSigned32(r[rl])) & mask32;
    } else if (opcode == 0x51) {
      r[rr] = (toSigned32(r[rr]) - toSigned32(r[rl])) & mask32;
    } else if (opcode == 0x52) {
      final n = toSigned32(r[rr]);
      final d = toSigned32(r[rl]);
      r[rr] = (d == 0) ? toUnsigned32(-1) : toUnsigned32(n ~/ d);
    } else if (opcode == 0x53) {
      final n = toSigned32(r[rr]);
      final d = toSigned32(r[rl]);
      // remainder() truncates: the result takes the sign of the dividend
      r[rr] = (d == 0) ? toUnsigned32(n) : toUnsigned32(n.remainder(d));
    } else if (opcode == 0x54) {
      final immS = (imm4 < 8) ? imm4 : imm4 - 16;
      r[rr] = (toSigned32(r[rr]) + immS) & mask32;
    } else if (opcode == 0x55) {
      final immS = (imm4 < 8) ? imm4 : imm4 - 16;
      r[rr] = (toSigned32(r[rr]) - immS) & mask32;
    } else if (opcode == 0x56) {
      final immS = (imm4 < 8) ? imm4 : imm4 - 16;
      final n = toSigned32(r[rr]);
      r[rr] = (immS == 0) ? toUnsigned32(-1) : toUnsigned32(n ~/ immS);
    } else if (opcode == 0x57) {
      final immS = (imm4 < 8) ? imm4 : imm4 - 16;
      final n = toSigned32(r[rr]);
      // remainder() truncates: the result takes the sign of the dividend
      r[rr] = (immS == 0) ? toUnsigned32(n) : toUnsigned32(n.remainder(immS));

    // ---------------- Shifts & Logic (0x60 - 0x73) ----------------
    } else if (opcode == 0x60) {
      r[rr] = (r[rr] << (r[rl] & 31)) & mask32;
    } else if (opcode == 0x61) {
      final v = r[rr] & 0xFF;
      r[rr] = toUnsigned32((v < 0x80) ? v : v - 0x100);
    } else if (opcode == 0x62) {
      r[rr] = (r[rr] >> (r[rl] & 31)) & mask32;
    } else if (opcode == 0x63) {
      r[rr] = (toSigned32(r[rr]) >> (r[rl] & 31)) & mask32;
    } else if (opcode == 0x64) {
      final s = r[rl] & 31;
      r[rr] = (s != 0) ? (((r[rr] << s) | (r[rr] >> (32 - s))) & mask32) : r[rr];
    } else if (opcode == 0x65) {
      final s = r[rl] & 31;
      r[rr] = (s != 0) ? (((r[rr] >> s) | (r[rr] << (32 - s))) & mask32) : r[rr];
    } else if (opcode == 0x66) {
      r[rr] = r[rr] & r[rl];
    } else if (opcode == 0x67) {
      r[rr] = r[rr] | r[rl];
    } else if (opcode == 0x68) {
      r[rr] = r[rr] ^ r[rl];
    } else if (opcode == 0x69) {
      r[rr] = (r[rr] << imm4) & mask32;
    } else if (opcode == 0x6A) {
      final v = r[rr] & 0xFFFF;
      r[rr] = toUnsigned32((v < 0x8000) ? v : v - 0x10000);
    } else if (opcode == 0x6B) {
      r[rr] = (r[rr] >> imm4) & mask32;
    } else if (opcode == 0x6C) {
      r[rr] = (toSigned32(r[rr]) >> imm4) & mask32;
    } else if (opcode == 0x6D) {
      r[rr] = (imm4 != 0) ? (((r[rr] << imm4) | (r[rr] >> (32 - imm4))) & mask32) : r[rr];
    } else if (opcode == 0x6E) {
      r[rr] = (imm4 != 0) ? (((r[rr] >> imm4) | (r[rr] << (32 - imm4))) & mask32) : r[rr];
    } else if (opcode == 0x6F) {
      r[rr] = r[rr] & imm4;
    } else if (opcode == 0x70) {
      r[rr] = r[rr] | imm4;
    } else if (opcode == 0x71) {
      r[rr] = r[rr] ^ imm4;
    } else if (opcode == 0x72) {
      r[rr] = (~r[rr]) & mask32;
    } else if (opcode == 0x73) {
      r[rr] = (r[rr] != 0) ? 1 : 0;

    // ---------------- Multipliers (0x78 - 0x7F) ----------------
    } else if (opcode == 0x78) {
      r[rr] = (r[rr] * r[rl]) & mask32;
    } else if (opcode == 0x79) {
      final p = BigInt.from(r[rr]) * BigInt.from(r[rl]);
      r[rr] = ((p >> 32) & BigInt.from(mask32)).toInt();
    } else if (opcode == 0x7A) {
      final p = BigInt.from(toSigned32(r[rr])) * BigInt.from(toSigned32(r[rl]));
      r[rr] = ((p >> 32) & BigInt.from(mask32)).toInt();
    } else if (opcode == 0x7B) {
      final p = BigInt.from(toSigned32(r[rr])) * BigInt.from(r[rl]);
      r[rr] = ((p >> 32) & BigInt.from(mask32)).toInt();
    } else if (opcode == 0x7C) {
      r[rr] = (r[rr] * imm4) & mask32;
    } else if (opcode == 0x7D) {
      final p = BigInt.from(r[rr]) * BigInt.from(imm4);
      r[rr] = ((p >> 32) & BigInt.from(mask32)).toInt();
    } else if (opcode == 0x7E) {
      final immS = (imm4 < 8) ? imm4 : imm4 - 16;
      final p = BigInt.from(toSigned32(r[rr])) * BigInt.from(immS);
      r[rr] = ((p >> 32) & BigInt.from(mask32)).toInt();
    } else if (opcode == 0x7F) {
      final p = BigInt.from(toSigned32(r[rr])) * BigInt.from(imm4);
      r[rr] = ((p >> 32) & BigInt.from(mask32)).toInt();

    // ---------------- Bit Manipulation & Special (0x80 - 0x8C) ----------------
    } else if (opcode == 0x80) {
      final pos = r[rl] & 0x1F;
      final length = (r[rl] >> 5) & 0x1F;
      final mask = (length < 32) ? ((1 << length) - 1) : mask32;
      r[rr] = (r[rr] >> pos) & mask;
    } else if (opcode == 0x81) {
      nextPc = (pc + 2 + (r[rr] * 2)) & mask32;
    } else if (opcode == 0x82) {
      final val = r[rl];
      var cnt = 0;
      for (var b = 31; b >= 0; b--) {
        if (((val >> b) & 1) != 0) break;
        cnt++;
      }
      r[rr] = cnt;
    } else if (opcode == 0x83) {
      r[rr] = r[rr] | (1 << (r[rl] & 31));
    } else if (opcode == 0x84) {
      r[rr] = r[rr] | (1 << imm4);
    } else if (opcode == 0x85) {
      r[rr] = r[rr] & ~(1 << (r[rl] & 31));
    } else if (opcode == 0x86) {
      r[rr] = r[rr] & ~(1 << imm4);
    } else if (opcode == 0x87) {
      r[rr] = r[rr] ^ (1 << (r[rl] & 31));
    } else if (opcode == 0x88) {
      r[rr] = r[rr] ^ (1 << imm4);
    } else if (opcode == 0x89) {
      r[rr] = (r[rr] >> (r[rl] & 31)) & 1;
    } else if (opcode == 0x8A) {
      r[rr] = (r[rr] >> imm4) & 1;
    } else if (opcode == 0x8B) {
      final addr = r[rr];
      final oldVal = read32(addr);
      write32(addr, r[rl]);
      r[rl] = oldVal;
    } else if (opcode == 0x8C) {
      final v = r[rr];
      final swapped = (((v & 0x000000FF) << 24) |
              ((v & 0x0000FF00) << 8) |
              ((v & 0x00FF0000) >> 8) |
              ((v & 0xFF000000) >>> 24)) &
          mask32;
      r[rr] = swapped;

    // ---------------- Comparisons (SLT / SSLT / SEQ / SNE / SLE / SSLE: 0x90 - 0x9D) ----------------
    } else if (opcode == 0x90) {
      r[rr] = (r[rr] < r[rl]) ? 1 : 0;
    } else if (opcode == 0x91) {
      r[rr] = (r[rr] < imm4) ? 1 : 0;
    } else if (opcode == 0x92) {
      r[rr] = (r[rr] < toUnsigned32(-imm4)) ? 1 : 0;
    } else if (opcode == 0x93) {
      r[14] = (r[14] < imm8) ? 1 : 0;
    } else if (opcode == 0x94) {
      r[14] = (r[14] < toUnsigned32(-imm8)) ? 1 : 0;
    } else if (opcode == 0x95) {
      r[rr] = (toSigned32(r[rr]) < toSigned32(r[rl])) ? 1 : 0;
    } else if (opcode == 0x96) {
      final immS = (imm4 < 8) ? imm4 : imm4 - 16;
      r[rr] = (toSigned32(r[rr]) < immS) ? 1 : 0;
    } else if (opcode == 0x97) {
      r[rr] = (toSigned32(r[rr]) < -imm4) ? 1 : 0;
    } else if (opcode == 0x98) {
      final immS = (imm8 < 128) ? imm8 : imm8 - 256;
      r[14] = (toSigned32(r[14]) < immS) ? 1 : 0;
    } else if (opcode == 0x99) {
      r[14] = (toSigned32(r[14]) < -imm8) ? 1 : 0;
    } else if (opcode == 0x9A) {
      r[rr] = (r[rr] == r[rl]) ? 1 : 0;
    } else if (opcode == 0x9B) {
      r[rr] = (r[rr] != r[rl]) ? 1 : 0;
    } else if (opcode == 0x9C) {
      r[rr] = (r[rr] <= r[rl]) ? 1 : 0;
    } else if (opcode == 0x9D) {
      r[rr] = (toSigned32(r[rr]) <= toSigned32(r[rl])) ? 1 : 0;

    // ---------------- Control Flow (0xA0 - 0xA4) ----------------
    } else if (opcode == 0xA0) {
      final target = r[rr];
      r[rl] = nextPc;
      nextPc = target;
    } else if (opcode == 0xA1) {
      final target = (pc + (toSigned32(r[rr]) * 2)) & mask32;
      r[rl] = nextPc;
      nextPc = target;
    } else if (opcode == 0xA2) {
      triggerTrap(r[rr] & 0x0F, nextPc, true);
      _trapTaken = false;
      cycleCount++;
      return true;
    } else if (opcode == 0xA3) {
      triggerTrap(imm4 & 0x0F, nextPc, true);
      _trapTaken = false;
      cycleCount++;
      return true;
    } else if (opcode == 0xA4) {
      nextPc = (pc + (toSigned32(r[rr]) * 2)) & mask32;

    // ---------------- Forward Branches (0xB0 - 0xBB) ----------------
    } else if (opcode == 0xB0) {
      nextPc = (pc + (imm8 * 2)) & mask32;
    } else if (opcode == 0xB1) {
      if (r[rr] == 0) nextPc = (pc + (r[rl] * 2)) & mask32;
    } else if (opcode == 0xB2) {
      if (toSigned32(r[rr]) < 0) nextPc = (pc + (r[rl] * 2)) & mask32;
    } else if (opcode == 0xB3) {
      if (toSigned32(r[rr]) > 0) nextPc = (pc + (r[rl] * 2)) & mask32;
    } else if (opcode == 0xB4) {
      if (r[rr] == 0) nextPc = (pc + (imm4 * 2)) & mask32;
    } else if (opcode == 0xB5) {
      if (toSigned32(r[rr]) < 0) nextPc = (pc + (imm4 * 2)) & mask32;
    } else if (opcode == 0xB6) {
      if (toSigned32(r[rr]) > 0) nextPc = (pc + (imm4 * 2)) & mask32;
    } else if (opcode == 0xB7) {
      if (r[14] == 0) nextPc = (pc + (imm8 * 2)) & mask32;
    } else if (opcode == 0xB8) {
      if (toSigned32(r[14]) < 0) nextPc = (pc + (imm8 * 2)) & mask32;
    } else if (opcode == 0xB9) {
      if (toSigned32(r[14]) > 0) nextPc = (pc + (imm8 * 2)) & mask32;
    } else if (opcode == 0xBA) {
      if (r[rr] != 0) nextPc = (pc + (imm4 * 2)) & mask32;
    } else if (opcode == 0xBB) {
      if (r[14] != 0) nextPc = (pc + (imm8 * 2)) & mask32;

    // ---------------- Backward Branches (0xC0 - 0xCB) ----------------
    } else if (opcode == 0xC0) {
      nextPc = (pc - (imm8 * 2)) & mask32;
    } else if (opcode == 0xC1) {
      if (r[rr] == 0) nextPc = (pc - (r[rl] * 2)) & mask32;
    } else if (opcode == 0xC2) {
      if (toSigned32(r[rr]) < 0) nextPc = (pc - (r[rl] * 2)) & mask32;
    } else if (opcode == 0xC3) {
      if (toSigned32(r[rr]) > 0) nextPc = (pc - (r[rl] * 2)) & mask32;
    } else if (opcode == 0xC4) {
      if (r[rr] == 0) nextPc = (pc - (imm4 * 2)) & mask32;
    } else if (opcode == 0xC5) {
      if (toSigned32(r[rr]) < 0) nextPc = (pc - (imm4 * 2)) & mask32;
    } else if (opcode == 0xC6) {
      if (toSigned32(r[rr]) > 0) nextPc = (pc - (imm4 * 2)) & mask32;
    } else if (opcode == 0xC7) {
      if (r[14] == 0) nextPc = (pc - (imm8 * 2)) & mask32;
    } else if (opcode == 0xC8) {
      if (toSigned32(r[14]) < 0) nextPc = (pc - (imm8 * 2)) & mask32;
    } else if (opcode == 0xC9) {
      if (toSigned32(r[14]) > 0) nextPc = (pc - (imm8 * 2)) & mask32;
    } else if (opcode == 0xCA) {
      if (r[rr] != 0) nextPc = (pc - (imm4 * 2)) & mask32;
    } else if (opcode == 0xCB) {
      if (r[14] != 0) nextPc = (pc - (imm8 * 2)) & mask32;

    // ---------------- Shadow Banks & RBASE (0xD0 - 0xD4) ----------------
    } else if (opcode == 0xD0) {
      if (rr != 0) {
        final phys = r.effIdx(rr);
        final tmp = r.raw[phys];
        r.raw[phys] = shadowR[phys];
        shadowR[phys] = tmp;
      }
    } else if (opcode == 0xD1) {
      for (var i = 1; i < 32; i++) {
        final tmp = r.raw[i];
        r.raw[i] = shadowR[i];
        shadowR[i] = tmp;
      }
    } else if (opcode == 0xD2) {
      for (var i = 1; i < 15; i++) {
        final phys = r.effIdx(i);
        final tmp = r.raw[phys];
        r.raw[phys] = shadowR[phys];
        shadowR[phys] = tmp;
      }
    } else if (opcode == 0xD3) {
      rbase = imm8 & 0x1F;
    } else if (opcode == 0xD4) {
      rbase = r[rr] & 0x1F;

    // ---------------- Streaming FIFOs (0xE0 - 0xE7) ----------------
    } else if (opcode == 0xE0) {
      final fid = r[rl] % fifos.length;
      if (fid == 0 && fifos[fid].isEmpty) {
        // Non-blocking poll of host stdin for Console RX
      }
      if (fifos[fid].isEmpty) {
        // Stall on the empty channel: the PC stays here, and the cycle counts
        stalled = true;
        waitingChannel = fid;
        cycleCount++;
        return true;
      }
      r[rr] = fifos[fid].removeFirst();
    } else if (opcode == 0xE1) {
      final fid = r[rl] % fifos.length;
      final route = fid < txRoutes.length ? txRoutes[fid] : null;
      if (fid == 0 && route == null) {
        stdout.writeCharCode(r[rr] & 0xFF);
      }
      final q = _txQueue(fid);
      if (q.length < 256) {
        q.add(r[rr]);
      }
    } else if (opcode == 0xE5) {
      // MBOX: raise trap Imm4 on another core, sending Rr
      onMbox?.call(imm4, r[rr]);
    } else if (opcode == 0xE4) {
      final fid = r[rl] % fifos.length;
      final emptyB = fifos[fid].isEmpty ? 1 : 0;
      final fullB = (fifos[fid].length >= 256) ? 2 : 0;
      r[rr] = (fifos[fid].length << 8) | fullB | emptyB;
    } else if (opcode == 0xE6) {
      final fid = r[rl] % fifos.length;
      if (fifos[fid].isNotEmpty) {
        r[rr] = fifos[fid].removeFirst();
        r[14] = 1;
      } else {
        r[14] = 0;
      }
    } else if (opcode == 0xE7) {
      final fid = r[rl] % fifos.length;
      final q = _txQueue(fid);
      if (q.length < 256) {
        q.add(r[rr]);
        r[14] = 1;
      } else {
        r[14] = 0;
      }
    } else {
      // Undefined opcode: vector 15, R14 = its address (as on hardware)
      triggerTrap(15, pc);
    }

    // A fault taken during the instruction has already set the PC to its
    // vector
    if (_trapTaken) {
      _trapTaken = false;
      if (savedRegs != null) {
        r.raw.setAll(0, savedRegs);
        r[14] = instPc; // the trap's link: the faulting instruction
      }
    } else {
      pc = nextPc;
    }
    cycleCount++;
    return true;
  }
}
