// =============================================================================
// File: hdl/parcore/test/rv32_reference.dart
// Description: A small RV32 reference interpreter for the Parcore guest tests.
//              The pipeline tests run each guest program here and compare all
//              32 registers with what core 1 holds at the end of the run, so
//              expected values never depend on how long a run lasts.
//
// Covers what Parcore emulates: RV32I, RV32M, the Zbb instructions core 1
// decodes, and Zicsr for the CSRs core 2 keeps (mstatus, mtvec, mscratch,
// mepc, mcause). It follows Parcore's memory layout:
//   * The program is fetched from its own image at [programBase] (core 0's
//     TCM). Execution stops at a zero word, as core 0 does, or when the PC
//     leaves the program.
//   * Loads and stores use a separate data memory (core 3's TCM), which
//     starts as [dataImage] placed at [dataImageBase] and wraps at
//     [dataBytes], as ParcoreTcm does.
// Anything else (ECALL, EBREAK, MRET, FENCE, the counter CSRs, an unknown
// encoding) throws, so a test that uses it gets a clear error instead of a
// silently wrong expectation.
// =============================================================================

import 'dart:typed_data';

class Rv32Result {
  /// x0..x31 at the end, as unsigned 32-bit values.
  final List<int> regs;

  /// Instructions executed.
  final int steps;

  Rv32Result(this.regs, this.steps);
}

class Rv32UnsupportedError extends Error {
  final String message;
  Rv32UnsupportedError(this.message);
  @override
  String toString() => 'Rv32UnsupportedError: $message';
}

/// Runs [program] (little-endian 32-bit words) and returns the registers.
Rv32Result runRv32Reference(
  List<int> program, {
  int programBase = 0x500,
  List<int> dataImage = const [],
  int dataImageBase = 0x100,
  int dataBytes = 4096,
  int maxSteps = 100000,
}) {
  const mask32 = 0xFFFFFFFF;
  final x = List<int>.filled(32, 0);
  final data = Uint8List(dataBytes);
  for (var i = 0; i < dataImage.length; i++) {
    data[(dataImageBase + i) % dataBytes] = dataImage[i];
  }
  final csrs = <int, int>{0x300: 0, 0x305: 0, 0x340: 0, 0x341: 0, 0x342: 0};

  int sext(int v, int bits) {
    final m = 1 << (bits - 1);
    return ((v & ((1 << bits) - 1)) ^ m) - m;
  }

  int s32(int v) => sext(v, 32);
  int u32(int v) => v & mask32;

  int load(int addr, int size) {
    var v = 0;
    for (var i = 0; i < size; i++) {
      v |= data[(addr + i) % dataBytes] << (8 * i);
    }
    return v;
  }

  void store(int addr, int size, int value) {
    for (var i = 0; i < size; i++) {
      data[(addr + i) % dataBytes] = (value >> (8 * i)) & 0xFF;
    }
  }

  int fetch(int pc) {
    final off = pc - programBase;
    if (off < 0 || off + 4 > program.length || off % 4 != 0) return 0;
    return program[off] |
        (program[off + 1] << 8) |
        (program[off + 2] << 16) |
        (program[off + 3] << 24);
  }

  int clz(int v) {
    for (var i = 31; i >= 0; i--) {
      if ((v >> i) & 1 == 1) return 31 - i;
    }
    return 32;
  }

  int ctz(int v) {
    for (var i = 0; i < 32; i++) {
      if ((v >> i) & 1 == 1) return i;
    }
    return 32;
  }

  int cpop(int v) {
    var n = 0;
    for (var i = 0; i < 32; i++) {
      n += (v >> i) & 1;
    }
    return n;
  }

  int rol(int v, int s) => u32((v << (s & 31)) | (v >> ((32 - (s & 31)) & 31)));
  int ror(int v, int s) => u32((v >> (s & 31)) | (v << ((32 - (s & 31)) & 31)));

  // High 32 bits of a 64-bit product: BigInt, since an unsigned 32 x 32
  // product doesn't fit in Dart's signed 64-bit int
  int mulh(int a, int b) =>
      ((BigInt.from(a) * BigInt.from(b)) >> 32).toUnsigned(32).toInt();

  var pc = programBase;
  var steps = 0;
  while (steps < maxSteps) {
    final inst = fetch(pc);
    if (inst == 0) break;
    steps++;

    final opcode = inst & 0x7F;
    final rd = (inst >> 7) & 0x1F;
    final funct3 = (inst >> 12) & 0x7;
    final rs1 = (inst >> 15) & 0x1F;
    final rs2 = (inst >> 20) & 0x1F;
    final funct7 = (inst >> 25) & 0x7F;
    final a = x[rs1];
    final b = x[rs2];
    final immI = sext(inst >> 20, 12);
    final immS = sext(((inst >> 25) << 5) | ((inst >> 7) & 0x1F), 12);
    final immB = sext(
        (((inst >> 31) & 1) << 12) |
            (((inst >> 7) & 1) << 11) |
            (((inst >> 25) & 0x3F) << 5) |
            (((inst >> 8) & 0xF) << 1),
        13);
    final immJ = sext(
        (((inst >> 31) & 1) << 20) |
            (((inst >> 12) & 0xFF) << 12) |
            (((inst >> 20) & 1) << 11) |
            (((inst >> 21) & 0x3FF) << 1),
        21);
    var next = pc + 4;
    int? result;

    Never unsupported() => throw Rv32UnsupportedError(
        'instruction 0x${inst.toRadixString(16).padLeft(8, '0')} '
        'at 0x${pc.toRadixString(16)}');

    switch (opcode) {
      case 0x37: // LUI
        result = u32(inst & 0xFFFFF000);
      case 0x17: // AUIPC
        result = u32(pc + (inst & 0xFFFFF000));
      case 0x6F: // JAL
        result = u32(pc + 4);
        next = pc + immJ;
      case 0x67: // JALR
        if (funct3 != 0) unsupported();
        result = u32(pc + 4);
        next = (a + immI) & ~1;
      case 0x63: // branches
        final bool taken;
        switch (funct3) {
          case 0:
            taken = a == b;
          case 1:
            taken = a != b;
          case 4:
            taken = s32(a) < s32(b);
          case 5:
            taken = s32(a) >= s32(b);
          case 6:
            taken = a < b;
          case 7:
            taken = a >= b;
          default:
            unsupported();
        }
        if (taken) next = pc + immB;
      case 0x03: // loads
        final addr = u32(a + immI);
        switch (funct3) {
          case 0:
            result = u32(sext(load(addr, 1), 8));
          case 1:
            result = u32(sext(load(addr, 2), 16));
          case 2:
            result = load(addr, 4);
          case 4:
            result = load(addr, 1);
          case 5:
            result = load(addr, 2);
          default:
            unsupported();
        }
      case 0x23: // stores
        final addr = u32(a + immS);
        switch (funct3) {
          case 0:
            store(addr, 1, b);
          case 1:
            store(addr, 2, b);
          case 2:
            store(addr, 4, b);
          default:
            unsupported();
        }
      case 0x13: // OP-IMM
        final shamt = rs2;
        switch (funct3) {
          case 0:
            result = u32(a + immI);
          case 2:
            result = s32(a) < immI ? 1 : 0;
          case 3:
            result = a < u32(immI) ? 1 : 0;
          case 4:
            result = u32(a ^ immI);
          case 6:
            result = u32(a | immI);
          case 7:
            result = u32(a & immI);
          case 1:
            if (funct7 == 0x00) {
              result = u32(a << shamt); // SLLI
            } else if (funct7 == 0x30) {
              switch (rs2) {
                case 0:
                  result = clz(a);
                case 1:
                  result = ctz(a);
                case 2:
                  result = cpop(a);
                case 4:
                  result = u32(sext(a, 8)); // SEXT.B
                case 5:
                  result = u32(sext(a, 16)); // SEXT.H
                default:
                  unsupported();
              }
            } else {
              unsupported();
            }
          case 5:
            if (funct7 == 0x00) {
              result = a >> shamt; // SRLI
            } else if (funct7 == 0x20) {
              result = u32(s32(a) >> shamt); // SRAI
            } else if (funct7 == 0x30) {
              result = ror(a, shamt); // RORI
            } else if ((inst >> 20) == 0x287) {
              var v = 0; // ORC.B
              for (var i = 0; i < 4; i++) {
                if ((a >> (8 * i)) & 0xFF != 0) v |= 0xFF << (8 * i);
              }
              result = v;
            } else if ((inst >> 20) == 0x698) {
              result = ((a & 0xFF) << 24) | // REV8
                  (((a >> 8) & 0xFF) << 16) |
                  (((a >> 16) & 0xFF) << 8) |
                  ((a >> 24) & 0xFF);
            } else {
              unsupported();
            }
        }
      case 0x33: // OP
        switch ((funct7 << 3) | funct3) {
          case 0x000:
            result = u32(a + b);
          case 0x100:
            result = u32(a - b);
          case 0x001:
            result = u32(a << (b & 31));
          case 0x002:
            result = s32(a) < s32(b) ? 1 : 0;
          case 0x003:
            result = a < b ? 1 : 0;
          case 0x004:
            result = a ^ b;
          case 0x005:
            result = a >> (b & 31);
          case 0x105:
            result = u32(s32(a) >> (b & 31));
          case 0x006:
            result = a | b;
          case 0x007:
            result = a & b;
          // RV32M
          case 0x008:
            result = u32(s32(a) * s32(b));
          case 0x009:
            result = mulh(s32(a), s32(b));
          case 0x00A:
            result = mulh(s32(a), b); // MULHSU: signed x unsigned
          case 0x00B:
            result = mulh(a, b);
          case 0x00C: // DIV
            result = b == 0
                ? mask32
                : (s32(a) == -0x80000000 && s32(b) == -1)
                    ? 0x80000000
                    : u32(s32(a) ~/ s32(b));
          case 0x00D: // DIVU
            result = b == 0 ? mask32 : a ~/ b;
          case 0x00E: // REM
            result = b == 0
                ? a
                : (s32(a) == -0x80000000 && s32(b) == -1)
                    ? 0
                    : u32(s32(a).remainder(s32(b)));
          case 0x00F: // REMU
            result = b == 0 ? a : a % b;
          // Zbb
          case 0x207:
            result = a & u32(~b); // ANDN
          case 0x206:
            result = a | u32(~b); // ORN
          case 0x204:
            result = u32(~(a ^ b)); // XNOR
          case 0x054:
            result = s32(a) < s32(b) ? a : b; // MIN
          case 0x055:
            result = a < b ? a : b; // MINU
          case 0x056:
            result = s32(a) > s32(b) ? a : b; // MAX
          case 0x057:
            result = a > b ? a : b; // MAXU
          case 0x024:
            if (rs2 != 0) unsupported();
            result = a & 0xFFFF; // ZEXT.H
          case 0x301:
            result = rol(a, b); // ROL
          case 0x305:
            result = ror(a, b); // ROR
          default:
            unsupported();
        }
      case 0x73: // SYSTEM: Zicsr
        final csr = inst >> 20;
        if (funct3 == 0 || funct3 == 4) unsupported(); // ECALL, EBREAK, MRET
        if (!csrs.containsKey(csr)) unsupported();
        final old = csrs[csr]!;
        final src = funct3 >= 5 ? rs1 : a; // immediate forms use rs1 as uimm
        switch (funct3 & 3) {
          case 1: // CSRRW / CSRRWI
            csrs[csr] = src;
          case 2: // CSRRS / CSRRSI
            if (rs1 != 0) csrs[csr] = old | src;
          case 3: // CSRRC / CSRRCI
            if (rs1 != 0) csrs[csr] = old & u32(~src);
        }
        result = old;
      default:
        unsupported();
    }

    if (result != null && rd != 0) x[rd] = u32(result);
    pc = u32(next);
  }

  return Rv32Result(List<int>.unmodifiable(x), steps);
}
