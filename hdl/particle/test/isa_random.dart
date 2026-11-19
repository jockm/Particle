// =============================================================================
// File: hdl/particle/test/isa_random.dart
// Description: Seeded random Particle programs for the differential ISA test.
//              Each program loads random values, runs a random mix of ALU,
//              multiply, divide, R14-immediate, load/store (every addressing
//              mode, aligned, inside a checked area), TAS, FIFO and XCHG
//              instructions, and ends in a jump to itself.
// =============================================================================

import 'dart:math';

const dataBase = 0x8000; // checked area: dataBase .. dataBase + 256

String randomProgram(int seed, {int length = 120}) {
  final rnd = Random(seed);
  final out = StringBuffer()
    ..writeln('; Random differential program, seed $seed')
    ..writeln('; check-memory: 0x${dataBase.toRadixString(16)} 256')
    ..writeln('; max-cycles: 20000')
    ..writeln('.org 0x100');

  String reg() => 'R${1 + rnd.nextInt(11)}'; // R1..R11
  int u4() => rnd.nextInt(16);
  int s4() => rnd.nextInt(16) - 8;
  int neg4() => 1 + rnd.nextInt(15);
  void emit(String s) => out.writeln('    $s');

  void load32(String r, int value) {
    emit('LDI R14, 0x${(value >> 16).toRadixString(16)}');
    emit('PUSH8 R14, 0x${((value >> 8) & 0xFF).toRadixString(16)}');
    emit('PUSH8 R14, 0x${(value & 0xFF).toRadixString(16)}');
    emit('LD $r, R14');
  }

  int interesting() {
    switch (rnd.nextInt(6)) {
      case 0:
        return [0, 1, 0xFFFFFFFF, 0x80000000, 0x7FFFFFFF, 2, 31, 32][rnd.nextInt(8)];
      case 1:
        return rnd.nextInt(256);
      default:
        return rnd.nextInt(1 << 32);
    }
  }

  for (var i = 1; i <= 11; i++) {
    load32('R$i', interesting());
  }

  const rrOps = [
    'ADD', 'SUB', 'SADD', 'SSUB', 'AND', 'OR', 'XOR', 'SHIFTL', 'SHIFTR',
    'ASHIFTR', 'ROTL', 'ROTR', 'SLT', 'SSLT', 'SEQ', 'SNE', 'SLE', 'SSLE',
    'MULL', 'MULH', 'SMULH', 'MULHSU', 'BSET', 'BCLR', 'BINV', 'BGET',
    'BEXTR', 'CLZ', 'DIV', 'MOD', 'SDIV', 'SMOD', 'LD',
  ];
  const u4Ops = [
    'ADD', 'SUB', 'AND', 'OR', 'XOR', 'SHIFTL', 'SHIFTR', 'ASHIFTR', 'ROTL',
    'ROTR', 'SLT', 'MULL', 'MULH', 'MULHSU', 'BSET', 'BCLR', 'BINV', 'BGET',
    'DIV', 'MOD', 'LD', 'PUSH4',
  ];
  const s4Ops = ['SADD', 'SSUB', 'SSLT', 'SMULH', 'SDIV', 'SMOD'];
  const unary = ['NEG', 'NOT', 'NEZ', 'SEXT8', 'SEXT16', 'REV32'];

  final fifoCount = [0, 0, 0, 0];

  for (var n = 0; n < length; n++) {
    final kind = rnd.nextInt(100);
    if (kind < 30) {
      emit('${rrOps[rnd.nextInt(rrOps.length)]} ${reg()}, ${reg()}');
    } else if (kind < 42) {
      emit('${u4Ops[rnd.nextInt(u4Ops.length)]} ${reg()}, ${u4()}');
    } else if (kind < 48) {
      emit('${s4Ops[rnd.nextInt(s4Ops.length)]} ${reg()}, ${s4()}');
    } else if (kind < 52) {
      emit('${['SLT', 'SSLT', 'LD'][rnd.nextInt(3)]} ${reg()}, -${neg4()}');
    } else if (kind < 57) {
      emit('${unary[rnd.nextInt(unary.length)]} ${reg()}');
    } else if (kind < 63) {
      // R14 forms, then move R14 somewhere visible
      switch (rnd.nextInt(5)) {
        case 0:
          emit('LD R14, ${rnd.nextInt(256)}');
        case 1:
          emit('LD R14, -${rnd.nextInt(256)}');
        case 2:
          emit('SLT R14, ${rnd.nextBool() ? '' : '-'}${rnd.nextInt(256)}');
        case 3:
          emit('SSLT R14, ${rnd.nextBool() ? '-${rnd.nextInt(256)}' : '${rnd.nextInt(128)}'}');
        case 4:
          emit('PUSH8 R14, ${rnd.nextInt(256)}');
      }
      emit('LD ${reg()}, R14');
    } else if (kind < 85) {
      // Load or store through R13, aligned, inside the checked area
      final sizeIdx = rnd.nextInt(3);
      final size = [1, 2, 4][sizeIdx];
      final width = [8, 16, 32][sizeIdx];
      final offset = (16 + rnd.nextInt(224)) & ~(size - 1);
      emit('LDI R13, 0x${(dataBase + offset).toRadixString(16)}');
      final ptr = ['(R13)', '(R13++)', '(++R13)', '(R13--)', '(--R13)'][rnd.nextInt(5)];
      // Sometimes the data register is the pointer itself
      final data = rnd.nextInt(8) == 0 ? 'R13' : reg();
      if (rnd.nextBool()) {
        emit('LD$width $data, $ptr');
      } else {
        emit('ST$width $ptr, $data');
      }
      if (data == 'R13') {
        emit('LD ${reg()}, R13');
      }
    } else if (kind < 88) {
      final offset = (16 + rnd.nextInt(224)) & ~3;
      emit('LDI R13, 0x${(dataBase + offset).toRadixString(16)}');
      emit('TAS (R13), ${reg()}');
    } else if (kind < 97) {
      final ch = 1 + rnd.nextInt(3);
      emit('LD R15, $ch');
      switch (rnd.nextInt(5)) {
        case 0:
          if (fifoCount[ch] < 200) {
            emit('FIFO.W ${reg()}, R15');
            fifoCount[ch]++;
          }
        case 1:
          if (fifoCount[ch] > 0) {
            emit('FIFO.R ${reg()}, R15');
            fifoCount[ch]--;
          }
        case 2:
          emit('FIFO.TRYR ${reg()}, R15');
          if (fifoCount[ch] > 0) fifoCount[ch]--;
          emit('LD ${reg()}, R14');
        case 3:
          if (fifoCount[ch] < 200) {
            emit('FIFO.TRYW ${reg()}, R15');
            fifoCount[ch]++;
            emit('LD ${reg()}, R14');
          }
        case 4:
          emit('FIFO.STAT ${reg()}, R15');
      }
    } else {
      emit('XCHG ${reg()}');
    }
  }

  out
    ..writeln('_halt:')
    ..writeln('    BBRA _halt');
  return out.toString();
}
