// ==============================================================================
// Particle Cycle-Accurate Simulator core (Dart port of psim.py)
// Architecture: Particle 32-bit RISC (16-bit Compact ISA)
// ==============================================================================

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'psim_pycompat.dart';

const int mask32 = 0xFFFFFFFF;
const int sign32 = 0x80000000;

int toSigned32(int val) {
  val = val & mask32;
  return val < sign32 ? val : val - 0x100000000;
}

int toUnsigned32(int val) => val & mask32;

/// High 32 bits of the unsigned 64-bit product of two 32-bit values.
/// (A plain a*b can exceed Dart's signed 64-bit int range.)
int _mulHighU32(int a, int b) {
  final aHi = a >> 16, aLo = a & 0xFFFF;
  final bHi = b >> 16, bLo = b & 0xFFFF;
  final mid = ((aHi * bLo + aLo * bHi) << 16) + aLo * bLo;
  return aHi * bHi + (mid >> 32);
}

/// Python's int(n / d): true division as a double, truncated toward zero.
int _pyTruncDiv(int n, int d) => (n / d).truncate();

/// Equivalent of collections.deque(maxlen=N).
class BoundedFifo {
  final int maxLen;
  final Queue<int> _q = Queue<int>();
  BoundedFifo(this.maxLen);

  int get length => _q.length;
  bool get isEmpty => _q.isEmpty;
  bool get isNotEmpty => _q.isNotEmpty;

  void append(int v) {
    if (_q.length >= maxLen) _q.removeFirst();
    _q.add(v);
  }

  int popLeft() => _q.removeFirst();
}

/// Shared reader for the host's standard input.
///
/// Python polled stdin with select() and read one character at a time; Dart
/// cannot block or poll stdin synchronously alongside the event loop, so this
/// class reads stdin asynchronously into a queue of characters that the
/// simulator (FIFO channel 0) and the debugger prompt both draw from.
/// Text is decoded as UTF-8 with universal newlines, like Python's sys.stdin.
class ConsoleInput {
  ConsoleInput._();
  static final ConsoleInput instance = ConsoleInput._();

  final Queue<int> _chars = Queue<int>();
  StreamSubscription<String>? _sub;
  bool _eof = false;
  bool _pendingCR = false;
  Completer<void>? _waiter;

  bool get isEof => _eof;
  bool get hasData => _chars.isNotEmpty;

  void start() {
    if (_sub != null) return;
    _sub = stdin.transform(const Utf8Decoder(allowMalformed: true)).listen(
        _onData,
        onDone: _onDone,
        onError: (Object e) => _onDone(),
        cancelOnError: true);
  }

  void _onData(String s) {
    for (final r in s.runes) {
      if (_pendingCR) {
        _pendingCR = false;
        if (r == 0x0A) continue; // \r\n -> \n
      }
      if (r == 0x0D) {
        _chars.add(0x0A); // lone \r -> \n
        _pendingCR = true;
      } else {
        _chars.add(r);
      }
    }
    wake();
  }

  void _onDone() {
    _eof = true;
    wake();
  }

  /// Wakes anything waiting in [waitForActivity].
  void wake() {
    final w = _waiter;
    _waiter = null;
    if (w != null && !w.isCompleted) w.complete();
  }

  /// Completes when input arrives, stdin closes, or [wake] is called.
  Future<void> waitForActivity() {
    start();
    return (_waiter ??= Completer<void>()).future;
  }

  /// Non-blocking read of one character (as a code point), or null.
  int? pollChar() {
    start();
    return _chars.isEmpty ? null : _chars.removeFirst();
  }

  /// Equivalent of Python's input() without the prompt: returns the next line
  /// without its newline, the partial last line at EOF, or null at EOF with
  /// nothing left. Throws [KeyboardInterrupt] if [interrupted] reports a
  /// pending Ctrl+C while waiting.
  Future<String?> readLine(bool Function() interrupted) async {
    start();
    while (true) {
      if (interrupted()) throw KeyboardInterrupt();
      if (_chars.contains(0x0A)) {
        final line = <int>[];
        while (true) {
          final c = _chars.removeFirst();
          if (c == 0x0A) break;
          line.add(c);
        }
        return String.fromCharCodes(line);
      }
      if (_eof) {
        if (_chars.isEmpty) return null;
        final line = _chars.toList();
        _chars.clear();
        return String.fromCharCodes(line);
      }
      await waitForActivity();
    }
  }

  Future<void> stop() async {
    final s = _sub;
    _sub = null;
    if (s != null) await s.cancel();
  }
}

class RegisterWindowView {
  final ParticleCore core;
  final List<int> raw = List<int>.filled(32, 0);

  RegisterWindowView(this.core);

  int eff(int idx) {
    if (idx == 0) return 0;
    return (idx + core.rbase) & 0x1F;
  }

  int operator [](int idx) => raw[eff(idx)];

  void operator []=(int idx, int val) {
    final phys = eff(idx);
    if (phys != 0) raw[phys] = val & mask32;
  }

  int get length => 32;
}

class ParticleCore {
  final int memSize;
  Uint8List mem;
  int rbase = 0;
  late RegisterWindowView r;
  List<int> shadowR = List<int>.filled(32, 0);
  int pc = 0x00000100;
  final List<BoundedFifo> fifos;
  int trapBase = 0x00000100;
  int trapStride = 64;
  int cycleCount = 0;
  bool halted = false;
  bool stalled = false;

  /// Set by [step] when the core stalled on an empty FIFO read (the channel
  /// number), otherwise -1. Used by the run loops to wait for host input
  /// instead of spinning; it has no architectural effect.
  int waitingOnFifo = -1;

  ParticleCore({this.memSize = 0x20000, int numFifos = 4})
      : mem = Uint8List(memSize),
        fifos = List<BoundedFifo>.generate(numFifos, (_) => BoundedFifo(256)) {
    r = RegisterWindowView(this);
  }

  void reset() {
    r = RegisterWindowView(this);
    shadowR = List<int>.filled(32, 0);
    rbase = 0;
    pc = trapBase;
    cycleCount = 0;
    halted = false;
    stalled = false;
  }

  /// Python's `core.mem[base:base+len(data)] = data` on the bytearray,
  /// including its slice clamping/insertion rules. Bytes that end up beyond
  /// mem_size are unreachable (all accesses are masked), so they are dropped.
  void loadImage(int base, List<int> data) {
    final length = mem.length;
    int clamp(int i) {
      if (i < 0) {
        i += length;
        if (i < 0) i = 0;
      } else if (i > length) {
        i = length;
      }
      return i;
    }

    final start = clamp(base);
    var stop = clamp(base + data.length);
    if (stop < start) stop = start;
    final grown = List<int>.of(mem)..replaceRange(start, stop, data);
    mem.setRange(0, memSize, grown);
  }

  void triggerTrap(int trapIdx, [int? returnPcArg]) {
    final returnPc = returnPcArg ?? ((pc + 2) & mask32);
    r[14] = returnPc;

    // Trap 14 Simulation Debug Quit Hook
    if (trapIdx == 14) {
      stdout.write('\n[SIM] Debug Quit Trap 14 triggered at PC: '
          '0x${hex8(returnPc)} (R1=0x${hex8(r[1])}, Cycles=$cycleCount)\n');
      halted = true;
      return;
    }

    pc = (trapBase + (trapIdx * trapStride)) & mask32;
  }

  int read8(int addr) => mem[addr & (memSize - 1)];

  void write8(int addr, int val) {
    mem[addr & (memSize - 1)] = val & 0xFF;
  }

  int read16(int addr) {
    if ((addr & 1) != 0) {
      triggerTrap(14, pc);
      return 0;
    }
    final a = addr & (memSize - 1);
    return mem[a] | (mem[(a + 1) & (memSize - 1)] << 8);
  }

  void write16(int addr, int val) {
    if ((addr & 1) != 0) {
      triggerTrap(14, pc);
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
    final a = addr & (memSize - 1);
    mem[a] = val & 0xFF;
    mem[(a + 1) & (memSize - 1)] = (val >> 8) & 0xFF;
    mem[(a + 2) & (memSize - 1)] = (val >> 16) & 0xFF;
    mem[(a + 3) & (memSize - 1)] = (val >> 24) & 0xFF;
  }

  int effIdx(int idx) => r.eff(idx);

  int getReg(int idx) => r[idx];

  void setReg(int idx, int val) {
    r[idx] = val;
  }

  bool step() {
    waitingOnFifo = -1;
    if (halted || pc >= memSize) {
      halted = true;
      return false;
    }

    if ((pc & 1) != 0) {
      triggerTrap(14, pc);
      return true;
    }

    final inst = read16(pc);
    final opcode = (inst >> 8) & 0xFF;
    final rr = (inst >> 4) & 0x0F;
    final rl = inst & 0x0F;
    final imm8 = inst & 0xFF;
    final imm4 = inst & 0x0F;

    var nextPc = (pc + 2) & mask32;

    switch (opcode) {
      // ---------------- Register Loads & Immediates (0x00 - 0x06) ----------------
      case 0x00: // LD Rr, Rl
        setReg(rr, r[rl]);
      case 0x01: // LD Rr, Imm4
        setReg(rr, imm4);
      case 0x02: // LD R14, Imm8
        setReg(14, imm8);
      case 0x03: // LD Rr, -Imm4
        setReg(rr, toUnsigned32(-imm4));
      case 0x04: // LD R14, -Imm8
        setReg(14, toUnsigned32(-imm8));
      case 0x05: // PUSH4 Rr, Imm4
        setReg(rr, (r[rr] << 4) | imm4);
      case 0x06: // PUSH8 R14, Imm8
        setReg(14, (r[14] << 8) | imm8);

      // ---------------- Memory Group (8-bit: 0x10 - 0x19) ----------------
      case 0x10: // LD8 Rr, (Rl)
        setReg(rr, read8(r[rl]));
      case 0x11: // LD8 Rr, (++Rl)
        final addr = (r[rl] + 1) & mask32;
        setReg(rl, addr);
        setReg(rr, read8(addr));
      case 0x12: // LD8 Rr, (Rl++)
        final addr = r[rl];
        setReg(rl, (addr + 1) & mask32);
        setReg(rr, read8(addr));
      case 0x13: // LD8 Rr, (--Rl)
        final addr = (r[rl] - 1) & mask32;
        setReg(rl, addr);
        setReg(rr, read8(addr));
      case 0x14: // LD8 Rr, (Rl--)
        final addr = r[rl];
        setReg(rl, (addr - 1) & mask32);
        setReg(rr, read8(addr));
      case 0x15: // ST8 (Rr), Rl
        write8(r[rr], r[rl]);
      case 0x16: // ST8 (++Rr), Rl
        final addr = (r[rr] + 1) & mask32;
        setReg(rr, addr);
        write8(addr, r[rl]);
      case 0x17: // ST8 (Rr++), Rl
        final addr = r[rr];
        setReg(rr, (addr + 1) & mask32);
        write8(addr, r[rl]);
      case 0x18: // ST8 (--Rr), Rl
        final addr = (r[rr] - 1) & mask32;
        setReg(rr, addr);
        write8(addr, r[rl]);
      case 0x19: // ST8 (Rr--), Rl
        final addr = r[rr];
        setReg(rr, (addr - 1) & mask32);
        write8(addr, r[rl]);

      // ---------------- Memory Group (16-bit: 0x20 - 0x29) ----------------
      case 0x20: // LD16 Rr, (Rl)
        setReg(rr, read16(r[rl]));
      case 0x21: // LD16 Rr, (++Rl)
        final addr = (r[rl] + 2) & mask32;
        setReg(rl, addr);
        setReg(rr, read16(addr));
      case 0x22: // LD16 Rr, (Rl++)
        final addr = r[rl];
        setReg(rl, (addr + 2) & mask32);
        setReg(rr, read16(addr));
      case 0x23: // LD16 Rr, (--Rl)
        final addr = (r[rl] - 2) & mask32;
        setReg(rl, addr);
        setReg(rr, read16(addr));
      case 0x24: // LD16 Rr, (Rl--)
        final addr = r[rl];
        setReg(rl, (addr - 2) & mask32);
        setReg(rr, read16(addr));
      case 0x25: // ST16 (Rr), Rl
        write16(r[rr], r[rl]);
      case 0x26: // ST16 (++Rr), Rl
        final addr = (r[rr] + 2) & mask32;
        setReg(rr, addr);
        write16(addr, r[rl]);
      case 0x27: // ST16 (Rr++), Rl
        final addr = r[rr];
        setReg(rr, (addr + 2) & mask32);
        write16(addr, r[rl]);
      case 0x28: // ST16 (--Rr), Rl
        final addr = (r[rr] - 2) & mask32;
        setReg(rr, addr);
        write16(addr, r[rl]);
      case 0x29: // ST16 (Rr--), Rl
        final addr = r[rr];
        setReg(rr, (addr - 2) & mask32);
        write16(addr, r[rl]);

      // ---------------- Memory Group (32-bit: 0x30 - 0x39) ----------------
      case 0x30: // LD32 Rr, (Rl)
        setReg(rr, read32(r[rl]));
      case 0x31: // LD32 Rr, (++Rl)
        final addr = (r[rl] + 4) & mask32;
        setReg(rl, addr);
        setReg(rr, read32(addr));
      case 0x32: // LD32 Rr, (Rl++)
        final addr = r[rl];
        setReg(rl, (addr + 4) & mask32);
        setReg(rr, read32(addr));
      case 0x33: // LD32 Rr, (--Rl)
        final addr = (r[rl] - 4) & mask32;
        setReg(rl, addr);
        setReg(rr, read32(addr));
      case 0x34: // LD32 Rr, (Rl--)
        final addr = r[rl];
        setReg(rl, (addr - 4) & mask32);
        setReg(rr, read32(addr));
      case 0x35: // ST32 (Rr), Rl
        write32(r[rr], r[rl]);
      case 0x36: // ST32 (++Rr), Rl
        final addr = (r[rr] + 4) & mask32;
        setReg(rr, addr);
        write32(addr, r[rl]);
      case 0x37: // ST32 (Rr++), Rl
        final addr = r[rr];
        setReg(rr, (addr + 4) & mask32);
        write32(addr, r[rl]);
      case 0x38: // ST32 (--Rr), Rl
        final addr = (r[rr] - 4) & mask32;
        setReg(rr, addr);
        write32(addr, r[rl]);
      case 0x39: // ST32 (Rr--), Rl
        final addr = r[rr];
        setReg(rr, (addr - 4) & mask32);
        write32(addr, r[rl]);

      // ---------------- Unsigned Arithmetic (0x40 - 0x48) ----------------
      case 0x48: // NEG Rr
        setReg(rr, toUnsigned32(-toSigned32(r[rr])));
      case 0x40: // ADD Rr, Rl
        setReg(rr, r[rr] + r[rl]);
      case 0x41: // SUB Rr, Rl
        setReg(rr, r[rr] - r[rl]);
      case 0x42: // DIV Rr, Rl
        final denom = r[rl];
        setReg(rr, denom == 0 ? 0xFFFFFFFF : r[rr] ~/ denom);
      case 0x43: // MOD Rr, Rl
        final denom = r[rl];
        setReg(rr, denom == 0 ? r[rr] : r[rr] % denom);
      case 0x44: // ADD Rr, Imm4
        setReg(rr, r[rr] + imm4);
      case 0x45: // SUB Rr, Imm4
        setReg(rr, r[rr] - imm4);
      case 0x46: // DIV Rr, Imm4
        setReg(rr, imm4 == 0 ? 0xFFFFFFFF : r[rr] ~/ imm4);
      case 0x47: // MOD Rr, Imm4
        setReg(rr, imm4 == 0 ? r[rr] : r[rr] % imm4);

      // ---------------- Signed Arithmetic (0x50 - 0x57) ----------------
      case 0x50: // SADD Rr, Rl
        setReg(rr, toSigned32(r[rr]) + toSigned32(r[rl]));
      case 0x51: // SSUB Rr, Rl
        setReg(rr, toSigned32(r[rr]) - toSigned32(r[rl]));
      case 0x52: // SDIV Rr, Rl
        final n = toSigned32(r[rr]), d = toSigned32(r[rl]);
        setReg(rr, d == 0 ? -1 : _pyTruncDiv(n, d));
      case 0x53: // SMOD Rr, Rl
        final n = toSigned32(r[rr]), d = toSigned32(r[rl]);
        setReg(rr, d == 0 ? n : (n - _pyTruncDiv(n, d) * d));
      case 0x54: // SADD Rr, Imm4
        final immS = imm4 < 8 ? imm4 : imm4 - 16;
        setReg(rr, toSigned32(r[rr]) + immS);
      case 0x55: // SSUB Rr, Imm4
        final immS = imm4 < 8 ? imm4 : imm4 - 16;
        setReg(rr, toSigned32(r[rr]) - immS);
      case 0x56: // SDIV Rr, Imm4
        final immS = imm4 < 8 ? imm4 : imm4 - 16;
        final n = toSigned32(r[rr]);
        setReg(rr, immS == 0 ? -1 : _pyTruncDiv(n, immS));
      case 0x57: // SMOD Rr, Imm4
        final immS = imm4 < 8 ? imm4 : imm4 - 16;
        final n = toSigned32(r[rr]);
        setReg(rr, immS == 0 ? n : (n - _pyTruncDiv(n, immS) * immS));

      // ---------------- Shifts & Logic (0x60 - 0x73) ----------------
      case 0x60: // SHIFTL Rr, Rl
        setReg(rr, r[rr] << (r[rl] & 31));
      case 0x61: // SEXT8 Rr
        final v = r[rr] & 0xFF;
        setReg(rr, v < 0x80 ? v : v - 0x100);
      case 0x62: // SHIFTR Rr, Rl
        setReg(rr, r[rr] >> (r[rl] & 31));
      case 0x63: // ASHIFTR Rr, Rl
        setReg(rr, toSigned32(r[rr]) >> (r[rl] & 31));
      case 0x64: // ROTL Rr, Rl
        final s = r[rl] & 31;
        setReg(rr, s != 0 ? ((r[rr] << s) | (r[rr] >> (32 - s))) : r[rr]);
      case 0x65: // ROTR Rr, Rl
        final s = r[rl] & 31;
        setReg(rr, s != 0 ? ((r[rr] >> s) | (r[rr] << (32 - s))) : r[rr]);
      case 0x66: // AND Rr, Rl
        setReg(rr, r[rr] & r[rl]);
      case 0x67: // OR Rr, Rl
        setReg(rr, r[rr] | r[rl]);
      case 0x68: // XOR Rr, Rl
        setReg(rr, r[rr] ^ r[rl]);
      case 0x69: // SHIFTL Rr, Imm4
        setReg(rr, r[rr] << imm4);
      case 0x6A: // SEXT16 Rr
        final v = r[rr] & 0xFFFF;
        setReg(rr, v < 0x8000 ? v : v - 0x10000);
      case 0x6B: // SHIFTR Rr, Imm4
        setReg(rr, r[rr] >> imm4);
      case 0x6C: // ASHIFTR Rr, Imm4
        setReg(rr, toSigned32(r[rr]) >> imm4);
      case 0x6D: // ROTL Rr, Imm4
        setReg(rr,
            imm4 != 0 ? ((r[rr] << imm4) | (r[rr] >> (32 - imm4))) : r[rr]);
      case 0x6E: // ROTR Rr, Imm4
        setReg(rr,
            imm4 != 0 ? ((r[rr] >> imm4) | (r[rr] << (32 - imm4))) : r[rr]);
      case 0x6F: // AND Rr, Imm4
        setReg(rr, r[rr] & imm4);
      case 0x70: // OR Rr, Imm4
        setReg(rr, r[rr] | imm4);
      case 0x71: // XOR Rr, Imm4
        setReg(rr, r[rr] ^ imm4);
      case 0x72: // NOT Rr
        setReg(rr, ~r[rr] & mask32);
      case 0x73: // NEZ Rr
        setReg(rr, r[rr] != 0 ? 1 : 0);

      // ---------------- Multipliers (0x78 - 0x7F) ----------------
      case 0x78: // MULL Rr, Rl (low 32 bits survive Dart's 64-bit wraparound)
        setReg(rr, r[rr] * r[rl]);
      case 0x79: // MULH Rr, Rl
        setReg(rr, _mulHighU32(r[rr], r[rl]));
      case 0x7A: // SMULH Rr, Rl
        final p = toSigned32(r[rr]) * toSigned32(r[rl]);
        setReg(rr, p >> 32);
      case 0x7B: // MULHSU Rr, Rl
        final p = toSigned32(r[rr]) * r[rl];
        setReg(rr, p >> 32);
      case 0x7C: // MULL Rr, Imm4
        setReg(rr, r[rr] * imm4);
      case 0x7D: // MULH Rr, Imm4
        setReg(rr, (r[rr] * imm4) >> 32);
      case 0x7E: // SMULH Rr, Imm4
        final immS = imm4 < 8 ? imm4 : imm4 - 16;
        final p = toSigned32(r[rr]) * immS;
        setReg(rr, p >> 32);
      case 0x7F: // MULHSU Rr, Imm4
        final p = toSigned32(r[rr]) * imm4;
        setReg(rr, p >> 32);

      // ---------------- Bit Manipulation & Special (0x80 - 0x8C) ----------------
      case 0x80: // BEXTR Rr, Rl
        final pos = r[rl] & 0x1F;
        final length = (r[rl] >> 5) & 0x1F;
        final mask = length < 32 ? (1 << length) - 1 : 0xFFFFFFFF;
        setReg(rr, (r[rr] >> pos) & mask);
      case 0x81: // JTBL Rr
        nextPc = (pc + 2 + (r[rr] * 2)) & mask32;
      case 0x82: // CLZ Rr, Rl
        final val = r[rl];
        var cnt = 0;
        for (var b = 31; b >= 0; b--) {
          if (((val >> b) & 1) != 0) break;
          cnt += 1;
        }
        setReg(rr, cnt);
      case 0x83: // BSET Rr, Rl
        setReg(rr, r[rr] | (1 << (r[rl] & 31)));
      case 0x84: // BSET Rr, Imm4
        setReg(rr, r[rr] | (1 << imm4));
      case 0x85: // BCLR Rr, Rl
        setReg(rr, r[rr] & ~(1 << (r[rl] & 31)));
      case 0x86: // BCLR Rr, Imm4
        setReg(rr, r[rr] & ~(1 << imm4));
      case 0x87: // BINV Rr, Rl
        setReg(rr, r[rr] ^ (1 << (r[rl] & 31)));
      case 0x88: // BINV Rr, Imm4
        setReg(rr, r[rr] ^ (1 << imm4));
      case 0x89: // BGET Rr, Rl
        setReg(rr, (r[rr] >> (r[rl] & 31)) & 1);
      case 0x8A: // BGET Rr, Imm4
        setReg(rr, (r[rr] >> imm4) & 1);
      case 0x8B: // TAS (Rr), Rl
        final addr = r[rr];
        final oldVal = read32(addr);
        write32(addr, r[rl]);
        setReg(rl, oldVal);
      case 0x8C: // REV32 Rr
        final v = r[rr];
        final swapped = ((v & 0x000000FF) << 24) |
            ((v & 0x0000FF00) << 8) |
            ((v & 0x00FF0000) >> 8) |
            ((v & 0xFF000000) >> 24);
        setReg(rr, swapped);

      // ---------------- Comparisons (SLT / SSLT: 0x90 - 0x9D) ----------------
      case 0x90: // SLT Rr, Rl
        setReg(rr, r[rr] < r[rl] ? 1 : 0);
      case 0x91: // SLT Rr, Imm4
        setReg(rr, r[rr] < imm4 ? 1 : 0);
      case 0x92: // SLT Rr, -Imm4
        setReg(rr, r[rr] < toUnsigned32(-imm4) ? 1 : 0);
      case 0x93: // SLT R14, Imm8
        setReg(14, r[14] < imm8 ? 1 : 0);
      case 0x94: // SLT R14, -Imm8
        setReg(14, r[14] < toUnsigned32(-imm8) ? 1 : 0);
      case 0x95: // SSLT Rr, Rl
        setReg(rr, toSigned32(r[rr]) < toSigned32(r[rl]) ? 1 : 0);
      case 0x96: // SSLT Rr, Imm4
        final immS = imm4 < 8 ? imm4 : imm4 - 16;
        setReg(rr, toSigned32(r[rr]) < immS ? 1 : 0);
      case 0x97: // SSLT Rr, -Imm4
        setReg(rr, toSigned32(r[rr]) < -imm4 ? 1 : 0);
      case 0x98: // SSLT R14, Imm8
        final immS = imm8 < 128 ? imm8 : imm8 - 256;
        setReg(14, toSigned32(r[14]) < immS ? 1 : 0);
      case 0x99: // SSLT R14, -Imm8
        setReg(14, toSigned32(r[14]) < -imm8 ? 1 : 0);
      case 0x9A: // SEQ Rr, Rl
        setReg(rr, r[rr] == r[rl] ? 1 : 0);
      case 0x9B: // SNE Rr, Rl
        setReg(rr, r[rr] != r[rl] ? 1 : 0);
      case 0x9C: // SLE Rr, Rl
        setReg(rr, r[rr] <= r[rl] ? 1 : 0);
      case 0x9D: // SSLE Rr, Rl
        setReg(rr, toSigned32(r[rr]) <= toSigned32(r[rl]) ? 1 : 0);

      // ---------------- Control Flow (0xA0 - 0xA4) ----------------
      case 0xA0: // JMP Rr, Rl
        final target = r[rr];
        setReg(rl, nextPc);
        nextPc = target;
      case 0xA1: // RJUMP Rr, Rl
        final target = (pc + (toSigned32(r[rr]) * 2)) & mask32;
        setReg(rl, nextPc);
        nextPc = target;
      case 0xA2: // TRAP Rr
        triggerTrap(r[rr] & 0x0F, nextPc);
        return true;
      case 0xA3: // TRAP Imm4
        triggerTrap(imm4 & 0x0F, nextPc);
        return true;
      case 0xA4: // BRANCH Rr
        nextPc = (pc + (toSigned32(r[rr]) * 2)) & mask32;

      // ---------------- Forward Branches (0xB0 - 0xBB) ----------------
      case 0xB0: // FBRA Imm8
        nextPc = (pc + (imm8 * 2)) & mask32;
      case 0xB1:
        if (r[rr] == 0) nextPc = (pc + (r[rl] * 2)) & mask32;
      case 0xB2:
        if (toSigned32(r[rr]) < 0) nextPc = (pc + (r[rl] * 2)) & mask32;
      case 0xB3:
        if (toSigned32(r[rr]) > 0) nextPc = (pc + (r[rl] * 2)) & mask32;
      case 0xB4: // FBRA.Z Rr, Imm4
        if (r[rr] == 0) nextPc = (pc + (imm4 * 2)) & mask32;
      case 0xB5: // FBRA.N Rr, Imm4
        if (toSigned32(r[rr]) < 0) nextPc = (pc + (imm4 * 2)) & mask32;
      case 0xB6: // FBRA.P Rr, Imm4
        if (toSigned32(r[rr]) > 0) nextPc = (pc + (imm4 * 2)) & mask32;
      case 0xB7: // FBRA.Z R14, Imm8
        if (r[14] == 0) nextPc = (pc + (imm8 * 2)) & mask32;
      case 0xB8: // FBRA.N R14, Imm8
        if (toSigned32(r[14]) < 0) nextPc = (pc + (imm8 * 2)) & mask32;
      case 0xB9: // FBRA.P R14, Imm8
        if (toSigned32(r[14]) > 0) nextPc = (pc + (imm8 * 2)) & mask32;
      case 0xBA: // FBRA.NZ Rr, Imm4
        if (r[rr] != 0) nextPc = (pc + (imm4 * 2)) & mask32;
      case 0xBB: // FBRA.NZ R14, Imm8
        if (r[14] != 0) nextPc = (pc + (imm8 * 2)) & mask32;

      // ---------------- Backward Branches (0xC0 - 0xCB) ----------------
      case 0xC0: // BBRA Imm8
        nextPc = (pc - (imm8 * 2)) & mask32;
      case 0xC1:
        if (r[rr] == 0) nextPc = (pc - (r[rl] * 2)) & mask32;
      case 0xC2:
        if (toSigned32(r[rr]) < 0) nextPc = (pc - (r[rl] * 2)) & mask32;
      case 0xC3:
        if (toSigned32(r[rr]) > 0) nextPc = (pc - (r[rl] * 2)) & mask32;
      case 0xC4: // BBRA.Z Rr, Imm4
        if (r[rr] == 0) nextPc = (pc - (imm4 * 2)) & mask32;
      case 0xC5: // BBRA.N Rr, Imm4
        if (toSigned32(r[rr]) < 0) nextPc = (pc - (imm4 * 2)) & mask32;
      case 0xC6: // BBRA.P Rr, Imm4
        if (toSigned32(r[rr]) > 0) nextPc = (pc - (imm4 * 2)) & mask32;
      case 0xC7: // BBRA.Z R14, Imm8
        if (r[14] == 0) nextPc = (pc - (imm8 * 2)) & mask32;
      case 0xC8: // BBRA.N R14, Imm8
        if (toSigned32(r[14]) < 0) nextPc = (pc - (imm8 * 2)) & mask32;
      case 0xC9: // BBRA.P R14, Imm8
        if (toSigned32(r[14]) > 0) nextPc = (pc - (imm8 * 2)) & mask32;
      case 0xCA: // BBRA.NZ Rr, Imm4
        if (r[rr] != 0) nextPc = (pc - (imm4 * 2)) & mask32;
      case 0xCB: // BBRA.NZ R14, Imm8
        if (r[14] != 0) nextPc = (pc - (imm8 * 2)) & mask32;

      // ---------------- Shadow Banks (0xD0 - 0xD4) ----------------
      case 0xD0: // XCHG Rr
        if (rr != 0) {
          final fromShadow = shadowR[rr], fromLive = r[rr];
          r[rr] = fromShadow;
          shadowR[rr] = fromLive;
        }
      case 0xD1: // XCHGALL
        for (var i = 1; i < 16; i++) {
          final fromShadow = shadowR[i], fromLive = r[i];
          r[i] = fromShadow;
          shadowR[i] = fromLive;
        }
      case 0xD2: // XCHGMOST
        // Note: the original indexes the window view with an already-windowed
        // index, so rbase is applied twice. Preserved as-is.
        for (var i = 1; i < 15; i++) {
          final phys = effIdx(i);
          final fromShadow = shadowR[phys], fromLive = r[phys];
          r[phys] = fromShadow;
          shadowR[phys] = fromLive;
        }
      case 0xD3: // RBASE Imm8
        rbase = imm8 & 0x1F;
      case 0xD4: // RBASE Rr
        rbase = getReg(rr) & 0x1F;

      // ---------------- Streaming FIFOs (0xE0 - 0xE7) ----------------
      case 0xE0: // FIFO.R Rr, chan
        final fid = imm4 % fifos.length;

        // Non-blocking poll of host stdin for Console RX (Channel 0)
        if (fid == 0 && fifos[fid].isEmpty) {
          final ch = ConsoleInput.instance.pollChar();
          if (ch != null) fifos[fid].append(ch);
        }

        if (fifos[fid].isEmpty) {
          waitingOnFifo = fid;
          return true; // Stall core on empty FIFO
        }
        setReg(rr, fifos[fid].popLeft());

      case 0xE1: // FIFO.W Rr, chan
        final fid = imm4 % fifos.length;
        final val = r[rr] & 0xFF;
        if (fid == 0) {
          // Pipe Channel 0 writes directly to host stdout (UART TX)
          stdout.write(String.fromCharCode(val));
        }
        if (fifos[fid].length < 256) fifos[fid].append(r[rr]);

      case 0xE4: // FIFO.STAT (channel in Rl)
      case 0xE5: // FIFO.STAT (channel in Imm4)
        final fid = (opcode == 0xE4 ? r[rl] : imm4) % fifos.length;
        final emptyB = fifos[fid].length == 0 ? 1 : 0;
        final fullB = fifos[fid].length >= 256 ? 2 : 0;
        setReg(rr, (fifos[fid].length << 8) | fullB | emptyB);
      case 0xE6: // FIFO.TRYR
        final fid = r[rl] % fifos.length;
        if (fifos[fid].isNotEmpty) {
          setReg(rr, fifos[fid].popLeft());
          setReg(14, 1);
        } else {
          setReg(14, 0);
        }
      case 0xE7: // FIFO.TRYW
        final fid = r[rl] % fifos.length;
        if (fifos[fid].length < 256) {
          fifos[fid].append(r[rr]);
          setReg(14, 1);
        } else {
          setReg(14, 0);
        }

      default:
        // Undefined opcodes execute as NOPs (same as the Python if/elif chain).
        break;
    }

    pc = nextPc;
    cycleCount += 1;
    return true;
  }
}
