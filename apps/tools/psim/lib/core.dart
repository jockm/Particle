// =============================================================================
// File: apps/tools/psim/lib/core.dart
// Project: Particle RISC Architecture
// Description: Particle 32-bit RISC core engine.
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

/// R0..R15. R0 reads as zero; writes to it are discarded.
class Registers {
  final Uint32List raw = Uint32List(16);

  int operator [](int idx) {
    return raw[idx];
  }

  void operator []=(int idx, int val) {
    if (idx != 0) {
      raw[idx] = val & mask32;
    }
  }
}

/// A core's network interface, when its channels go through a network on
/// chip (a cluster with "topology": "ring") instead of straight into another
/// core's FIFO.
abstract class NetworkPort {
  /// Whether channel [ch]'s writes go into the network.
  bool sends(int ch);

  /// A write of [value] to channel [ch]: [pushAccepted], [pushNoCredit]
  /// (the receiver has no room: dropped, as a FIFO.W to a full FIFO is) or
  /// [pushQueueFull] (the injection queue is full: FIFO.W waits).
  int push(int ch, int value);

  /// FIFO.STAT of output channel [ch]: words held (256 minus the credits),
  /// full when there are no credits, empty when there are 256.
  int txStatus(int ch);

  /// The core read a word from its channel [ch]: a credit for its sender.
  void popped(int ch);

  /// A store to the FLUSH register: send a FLUSH on channel [ch].
  void flush(int ch);

  /// A store to the CONFIG register: send a CONFIG packet (see
  /// [niConfigAddr]).
  void config(int word);

  static const pushAccepted = 0;
  static const pushNoCredit = 1;
  static const pushQueueFull = 2;
}

/// The network interface's FLUSH register: storing a channel number sends a
/// FLUSH on that channel (Documentation/noc_design.md).
const int niFlushAddr = 0xFFFFFF00;

/// The network interface's MBOX registers: the value and the sending core of
/// the last MBOX trap taken (Documentation/mbox_design.md).
const int niMboxValueAddr = 0xFFFFFF04;
const int niMboxSourceAddr = 0xFFFFFF08;

/// The CONFIG register: a store sends a CONFIG packet. Bits 31:24 the core
/// it goes to (0xFF: every core); 23:20 the entry (0 the route of a channel,
/// 1 the sender of a channel's input, 2 the default MBOX target); 19:16 the
/// channel; 15:8 a core and 3:0 a channel, the entry's new value (for the
/// MBOX target, only the core).
const int niConfigAddr = 0xFFFFFF0C;

/// MBOXes a core can hold before it takes them, and the core number that
/// means every core.
const int mboxQueueDepth = 4;
const int mboxBroadcast = 0xFF;

class ParticleCore {
  final int memSize;
  late final Uint8List mem;
  final ByteData byteData;

  final Registers r = Registers();
  final Uint32List shadowR = Uint32List(16);

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

  // ---------------- Optional features (as the hardware's CpuConfig) ----------------

  /// Loads and stores that pre/post increment or decrement their pointer
  /// register. When false they are illegal (vector 15).
  bool pointerModes = true;

  /// Byte and halfword loads and stores. When false they are illegal.
  bool subword = true;

  /// The shadow bank. When false XCHG, XCHGALL and XCHGMOST are illegal.
  bool shadowBank = true;

  /// Taking MBOX traps from other cores. When false they are ignored.
  bool mboxReceive = true;

  /// The 2-word PC-relative instructions (BRA, BRA.Z/NZ/N/P, RJUMP disp16,
  /// BEQ, BNE, LEA). When false they are illegal.
  bool longBranches = true;

  /// The immediate BEXTR and SBEXTR (0x8D). When false they are illegal.
  bool immBextr = true;

  /// WAIT (0xEA) and HALT (0xEB). When false they are illegal.
  bool waitHalt = true;

  /// Whether the core is in a WAIT, waiting for an MBOX.
  bool inWait = false;

  /// The opcodes of [longBranches].
  static const longBranchOps = {
    0xBC, 0xBD, 0xBE, 0xBF, 0xCC, 0xCD, 0xCE, 0xCF, 0x09,
  };

  /// The signed 16-bit second word of the instruction at [pc].
  int _disp16() {
    final w = read16((pc + 2) & mask32);
    return w < 0x8000 ? w : w - 0x10000;
  }

  /// Whether [opcode] belongs to a feature this core leaves out.
  bool _leftOut(int opcode) {
    final group = opcode >> 4;
    final mode = opcode & 0x0F;
    final isMem = group >= 1 && group <= 3 && mode <= 9;
    if (!pointerModes && isMem && mode != 0 && mode != 5) return true;
    if (!subword && isMem && group != 3) return true;
    if (!shadowBank && opcode >= 0xD0 && opcode <= 0xD2) return true;
    if (!longBranches && longBranchOps.contains(opcode)) return true;
    if (!immBextr && opcode == 0x8D) return true;
    if (!waitHalt && (opcode == 0xEA || opcode == 0xEB)) return true;
    return false;
  }

  // ---------------- Multi-core (cluster) connections ----------------

  /// The core's name in messages, set in a cluster.
  String? label;

  /// Where each local channel's writes go: another core's receive channel,
  /// or null for this core's own channel (and the console on channel 0).
  final List<(ParticleCore, int)?> txRoutes = List.filled(4, null);

  /// The network this core's channels go through, or null.
  NetworkPort? network;

  /// Memory shared by every core of a cluster, at [sharedBase].
  Uint8List? shared;
  int sharedBase = 0;

  /// This core's number in a cluster (the "id" of its entry).
  int id = 0;

  /// The core `MBOX Rr, Imm4` goes to (a core number), or null.
  int? mboxTarget;

  /// Called when this core executes MBOX: the target core (null for the
  /// default target, [mboxBroadcast] for every core), the vector and the
  /// value. False when it can't be sent yet (the core waits and tries again);
  /// null when there is no other core (MBOX does nothing).
  bool Function(int? target, int vector, int value)? onMbox;

  /// MBOXes from other cores, waiting to be taken: (vector, value, source).
  /// One more slot holds a broadcast; a broadcast that finds it full is
  /// dropped. Taken before the next instruction unless masked.
  final Queue<(int, int, int)> mboxQueue = Queue();
  (int, int, int)? mboxBroadcastSlot;

  /// Masks the asynchronous traps (today MBOX): set by DI and by taking an
  /// MBOX trap; cleared by EI and RETI.
  bool mboxMasked = false;

  /// Where RETI returns: the instruction an MBOX trap interrupted.
  int epc = 0;

  /// The last MBOX trap's value and sending core (the MBOX registers).
  int mboxValue = 0;
  int mboxSource = 0;

  /// Whether an MBOX trap is ready to be taken.
  bool get mboxReady =>
      mboxReceive && !mboxMasked && (mboxQueue.isNotEmpty || mboxBroadcastSlot != null);

  /// An MBOX arriving: false when the queue is full (the sender tries
  /// again). A broadcast always counts as accepted.
  bool acceptMbox(int vector, int value, int source, {bool broadcast = false}) {
    if (!mboxReceive) return true;
    if (broadcast) {
      mboxBroadcastSlot ??= (vector & 0x0F, value & mask32, source);
      return true;
    }
    if (mboxQueue.length >= mboxQueueDepth) return false;
    mboxQueue.add((vector & 0x0F, value & mask32, source));
    return true;
  }

  ParticleCore({this.memSize = 0x20000, int numFifos = 4})
      : fifos = List.generate(numFifos, (_) => Queue<int>()),
        byteData = ByteData(memSize) {
    mem = byteData.buffer.asUint8List();
  }

  void reset() {
    for (var i = 0; i < 16; i++) {
      r.raw[i] = 0;
      shadowR[i] = 0;
    }
    pc = trapBase;
    cycleCount = 0;
    halted = false;
    haltCode = null;
    stalled = false;
    waitingChannel = null;
    mboxQueue.clear();
    mboxBroadcastSlot = null;
    mboxMasked = false;
    epc = 0;
    mboxValue = 0;
    mboxSource = 0;
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
    if ((addr & mask32) == niMboxValueAddr) return mboxValue;
    if ((addr & mask32) == niMboxSourceAddr) return mboxSource;
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
    if (network != null && (addr & mask32) == niFlushAddr) {
      network!.flush(val & 3);
      return;
    }
    if ((addr & mask32) == niConfigAddr) {
      network?.config(val & mask32);
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

    // An MBOX trap from another core: a stalled instruction is abandoned,
    // and runs again when RETI returns to it. The return PC goes to EPC (R14
    // is kept), MBOX traps are masked, and the handler reads the value and
    // the sender from the MBOX registers.
    if (mboxReady) {
      final (int, int, int) entry;
      if (mboxQueue.isNotEmpty) {
        entry = mboxQueue.removeFirst();
      } else {
        entry = mboxBroadcastSlot!;
        mboxBroadcastSlot = null;
      }
      final (vector, value, source) = entry;
      stalled = false;
      waitingChannel = null;
      inWait = false;
      mboxValue = value;
      mboxSource = source;
      // Taken at a WAIT, it ends the WAIT: RETI returns past it
      final atWait = waitHalt && ((read16(pc) >> 8) & 0xFF) == 0xEA;
      _trapTaken = false;
      epc = atWait ? (pc + 2) & mask32 : pc;
      mboxMasked = true;
      pc = (trapBase + vector * trapStride) & mask32;
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
    inWait = false;

    final inst = read16(pc);
    final opcode = (inst >> 8) & 0xFF;
    if (_leftOut(opcode)) {
      // A left-out feature's instruction: vector 15, as an undefined opcode
      triggerTrap(15, pc);
      _trapTaken = false;
      cycleCount++;
      return true;
    }
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
    } else if (opcode == 0x09) {
      // LEA Rl, disp16: the address PC + disp16 (bytes)
      final d = _disp16();
      if (!_trapTaken) {
        r[rl] = (pc + d) & mask32;
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
      // Entries of 2 << Rl[1:0] bytes
      nextPc = (pc + 2 + (r[rr] * (2 << (rl & 3)))) & mask32;
    } else if (opcode == 0x8D) {
      // BEXTR Rr, Rl, pos, len (SBEXTR with bit 15): from Rl, in 2 words
      final imm = read16((pc + 2) & mask32);
      if (!_trapTaken) {
        final pos = imm & 0x1F;
        final length = (imm >> 5) & 0x1F;
        var v = (r[rl] >> pos) & ((1 << length) - 1);
        if ((imm & 0x8000) != 0 && length > 0 && ((v >> (length - 1)) & 1) != 0) {
          v |= mask32 & ~((1 << length) - 1);
        }
        r[rr] = v;
        nextPc = (pc + 4) & mask32;
      }
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

    // ---------------- 2-word PC-relative branches (item 13) ----------------
    // The second word is a signed halfword displacement from this
    // instruction; not taken, execution goes on at PC + 4
    } else if (longBranchOps.contains(opcode)) {
      final d = _disp16();
      if (!_trapTaken) {
        final target = (pc + d * 2) & mask32;
        final taken = switch (opcode) {
          0xBC => r[rr] == 0,
          0xBD => r[rr] != 0,
          0xBE => toSigned32(r[rr]) < 0,
          0xBF => toSigned32(r[rr]) > 0,
          0xCE => r[rr] == r[rl],
          0xCF => r[rr] != r[rl],
          _ => true, // BRA, RJUMP
        };
        nextPc = (pc + 4) & mask32;
        if (opcode == 0xCD) r[rl] = nextPc; // RJUMP disp16, Rl: link PC + 4
        if (taken) nextPc = target;
      }

    // ---------------- Shadow Bank (0xD0 - 0xD2) ----------------
    // (0xD3 and 0xD4 are reserved: vector 15, like any undefined opcode)
    } else if (opcode == 0xD0) {
      if (rr != 0) {
        final tmp = r.raw[rr];
        r.raw[rr] = shadowR[rr];
        shadowR[rr] = tmp;
      }
    } else if (opcode == 0xD1) {
      for (var i = 1; i < 16; i++) {
        final tmp = r.raw[i];
        r.raw[i] = shadowR[i];
        shadowR[i] = tmp;
      }
    } else if (opcode == 0xD2) {
      for (var i = 1; i < 15; i++) {
        final tmp = r.raw[i];
        r.raw[i] = shadowR[i];
        shadowR[i] = tmp;
      }

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
      network?.popped(fid);
    } else if (opcode == 0xE1) {
      final fid = r[rl] % fifos.length;
      final net = network;
      if (net != null && net.sends(fid)) {
        if (net.push(fid, r[rr]) == NetworkPort.pushQueueFull) {
          // The injection queue is full: wait, as FIFO.R waits for data
          stalled = true;
          waitingChannel = fid;
          cycleCount++;
          return true;
        }
      } else {
        final route = fid < txRoutes.length ? txRoutes[fid] : null;
        if (fid == 0 && route == null) {
          stdout.writeCharCode(r[rr] & 0xFF);
        }
        final q = _txQueue(fid);
        if (q.length < 256) {
          q.add(r[rr]);
        }
      }
    } else if (opcode == 0xE5 || opcode == 0xE2) {
      // MBOX Rr, Imm4: vector Imm4 on the default target. MBOX Rr, Rl: the
      // target core in Rl bits 7:0, the vector in 11:8. It waits while it
      // can't be sent (the target's queue is full, or the last is unanswered)
      final send = onMbox;
      if (send != null) {
        final target = opcode == 0xE2 ? r[rl] & 0xFF : null;
        final vector = opcode == 0xE2 ? (r[rl] >> 8) & 0x0F : imm4;
        if (!send(target, vector, r[rr])) {
          stalled = true;
          waitingChannel = null;
          cycleCount++;
          return true;
        }
      }
    } else if (opcode == 0xE3) {
      // RETI: back to the instruction the MBOX trap interrupted
      nextPc = epc;
      mboxMasked = false;
    } else if (opcode == 0xE8) {
      mboxMasked = false; // EI
    } else if (opcode == 0xE9) {
      mboxMasked = true; // DI
    } else if (opcode == 0xEA) {
      // WAIT: until an MBOX is pending. Unmasked, it is taken (above, with
      // EPC past the WAIT); masked, execution goes on and it stays queued
      final pending = mboxReceive && (mboxQueue.isNotEmpty || mboxBroadcastSlot != null);
      if (!pending) {
        stalled = true;
        inWait = true;
        waitingChannel = null;
        cycleCount++;
        return true;
      }
    } else if (opcode == 0xEB) {
      // HALT: the core sleeps until it is reset; on its own it ends the run
      final pcHex = pc.toRadixString(16).toUpperCase().padLeft(8, "0");
      stdout.writeln("\n[SIM] ${label == null ? "" : "$label: "}HALT at PC: 0x$pcHex (Cycles=$cycleCount)");
      halted = true;
      haltCode = 0;
      cycleCount++;
      return false;
    } else if (opcode == 0xE4) {
      final fid = r[rl] % fifos.length;
      if (network != null && network!.sends(fid)) {
        r[rr] = network!.txStatus(fid);
      } else {
        final emptyB = fifos[fid].isEmpty ? 1 : 0;
        final fullB = (fifos[fid].length >= 256) ? 2 : 0;
        r[rr] = (fifos[fid].length << 8) | fullB | emptyB;
      }
    } else if (opcode == 0xE6) {
      final fid = r[rl] % fifos.length;
      if (fifos[fid].isNotEmpty) {
        r[rr] = fifos[fid].removeFirst();
        network?.popped(fid);
        r[14] = 1;
      } else {
        r[14] = 0;
      }
    } else if (opcode == 0xE7 && network != null && network!.sends(r[rl] % fifos.length)) {
      final fid = r[rl] % fifos.length;
      r[14] = network!.push(fid, r[rr]) == NetworkPort.pushAccepted ? 1 : 0;
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
