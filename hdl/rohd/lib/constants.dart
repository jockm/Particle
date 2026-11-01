// =============================================================================
// File: hdl/rohd/lib/constants.dart
// Architecture: Particle 32-bit RISC Core
// Description: Architectural constants, widths, opcodes, and ALU operation codes.
// =============================================================================

abstract class ParticleWidths {
  static const int word = 32;
  static const int inst = 16;
  static const int halfWord = 16;
  static const int byte = 8;
  static const int regAddr = 4;
  static const int trapVector = 4;
  static const int fifoChan = 2;
  static const int byteEnable = 4;
}

abstract class ParticleVectors {
  static const int reset = 0;
  static const int mboxStrobe = 1;
  static const int trapMin = 2;
  static const int trapMax = 13;
  static const int alignFault = 14;
  static const int illegalInstruction = 15;
}

abstract class AluOps {
  static const int add = 0;
  static const int sub = 1;
  static const int and = 2;
  static const int or = 3;
  static const int xor = 4;
  static const int shiftl = 5;
  static const int shiftr = 6;
  static const int ashiftr = 7;
  static const int rotl = 8;
  static const int rotr = 9;
  static const int clz = 10;
  static const int bextr = 11;
  static const int bset = 12;
  static const int bclr = 13;
  static const int binv = 14;
  static const int bget = 15;
  static const int slt = 16;
  static const int sslt = 17;
  static const int not = 18;
  static const int nez = 19;
}

abstract class ParticleOpcodes {
  // 4.1 Loads & Immediates (0x00 - 0x06)
  static const int ld = 0x00;
  static const int ldImm4 = 0x01;
  static const int ldImm8 = 0x02;
  static const int ldNegImm4 = 0x03;
  static const int ldNegImm8 = 0x04;
  static const int push4 = 0x05;
  static const int push8 = 0x06;

  // 4.2 Memory Loads & Stores (0x10 - 0x39)
  static const int ld8 = 0x10;
  static const int ld8PreInc = 0x11;
  static const int ld8PostInc = 0x12;
  static const int ld8PreDec = 0x13;
  static const int ld8PostDec = 0x14;
  static const int st8 = 0x15;
  static const int st8PreInc = 0x16;
  static const int st8PostInc = 0x17;
  static const int st8PreDec = 0x18;
  static const int st8PostDec = 0x19;

  static const int ld16 = 0x20;
  static const int ld16PreInc = 0x21;
  static const int ld16PostInc = 0x22;
  static const int ld16PreDec = 0x23;
  static const int ld16PostDec = 0x24;
  static const int st16 = 0x25;
  static const int st16PreInc = 0x26;
  static const int st16PostInc = 0x27;
  static const int st16PreDec = 0x28;
  static const int st16PostDec = 0x29;

  static const int ld32 = 0x30;
  static const int ld32PreInc = 0x31;
  static const int ld32PostInc = 0x32;
  static const int ld32PreDec = 0x33;
  static const int ld32PostDec = 0x34;
  static const int st32 = 0x35;
  static const int st32PreInc = 0x36;
  static const int st32PostInc = 0x37;
  static const int st32PreDec = 0x38;
  static const int st32PostDec = 0x39;

  // 4.3 Unsigned & Signed Arithmetic (0x40 - 0x57)
  static const int add = 0x40;
  static const int sub = 0x41;
  static const int div = 0x42;
  static const int mod = 0x43;
  static const int addImm4 = 0x44;
  static const int subImm4 = 0x45;
  static const int divImm4 = 0x46;
  static const int modImm4 = 0x47;

  static const int sadd = 0x50;
  static const int ssub = 0x51;
  static const int sdiv = 0x52;
  static const int smod = 0x53;
  static const int saddImm4 = 0x54;
  static const int ssubImm4 = 0x55;
  static const int sdivImm4 = 0x56;
  static const int smodImm4 = 0x57;

  // 4.4 Logic, Shifts, Sign-Extension & Inversions (0x60 - 0x73)
  static const int shiftL = 0x60;
  static const int sext8 = 0x61;
  static const int shiftR = 0x62;
  static const int ashiftR = 0x63;
  static const int rotL = 0x64;
  static const int rotR = 0x65;
  static const int andOp = 0x66;
  static const int orOp = 0x67;
  static const int xorOp = 0x68;
  static const int shiftLImm4 = 0x69;
  static const int sext16 = 0x6A;
  static const int shiftRImm4 = 0x6B;
  static const int ashiftRImm4 = 0x6C;
  static const int rotLImm4 = 0x6D;
  static const int rotRImm4 = 0x6E;
  static const int andImm4 = 0x6F;
  static const int orImm4 = 0x70;
  static const int xorImm4 = 0x71;
  static const int notOp = 0x72;
  static const int nezOp = 0x73;

  // 4.5 Multipliers (0x78 - 0x7F)
  static const int mull = 0x78;
  static const int mulh = 0x79;
  static const int smulh = 0x7A;
  static const int mulhsu = 0x7B;
  static const int mullImm4 = 0x7C;
  static const int mulhImm4 = 0x7D;
  static const int smulhImm4 = 0x7E;
  static const int mulhsuImm4 = 0x7F;

  // 4.6 Bit Manipulation & System Operations (0x80 - 0x8B)
  static const int bextr = 0x80;
  static const int jtbl = 0x81;
  static const int clz = 0x82;
  static const int bset = 0x83;
  static const int bsetImm4 = 0x84;
  static const int bclr = 0x85;
  static const int bclrImm4 = 0x86;
  static const int binv = 0x87;
  static const int binvImm4 = 0x88;
  static const int bget = 0x89;
  static const int bgetImm4 = 0x8A;
  static const int tas = 0x8B;

  // 4.7 Relational Comparisons (0x90 - 0x99)
  static const int slt = 0x90;
  static const int sltImm4 = 0x91;
  static const int sltNegImm4 = 0x92;
  static const int sltR14Imm8 = 0x93;
  static const int sltR14NegImm8 = 0x94;
  static const int sslt = 0x95;
  static const int ssltImm4 = 0x96;
  static const int ssltNegImm4 = 0x97;
  static const int ssltR14Imm8 = 0x98;
  static const int ssltR14NegImm8 = 0x99;

  // 4.8 Control Flow & Hardware Synchronization (0xA0 - 0xA4)
  static const int jmp = 0xA0;
  static const int rjump = 0xA1;
  static const int trapR = 0xA2;
  static const int trapImm4 = 0xA3;
  static const int branch = 0xA4;

  // 4.9 Forward Branches (0xB0 - 0xBB)
  static const int fbraImm8 = 0xB0;
  static const int fbraZR = 0xB1;
  static const int fbraNR = 0xB2;
  static const int fbraPR = 0xB3;
  static const int fbraZImm4 = 0xB4;
  static const int fbraNImm4 = 0xB5;
  static const int fbraPImm4 = 0xB6;
  static const int fbraZImm8 = 0xB7;
  static const int fbraNImm8 = 0xB8;
  static const int fbraPImm8 = 0xB9;
  static const int fbraNZImm4 = 0xBA;
  static const int fbraNZImm8 = 0xBB;

  // 4.10 Backward Branches (0xC0 - 0xCB)
  static const int bbraImm8 = 0xC0;
  static const int bbraZR = 0xC1;
  static const int bbraNR = 0xC2;
  static const int bbraPR = 0xC3;
  static const int bbraZImm4 = 0xC4;
  static const int bbraNImm4 = 0xC5;
  static const int bbraPImm4 = 0xC6;
  static const int bbraZImm8 = 0xC7;
  static const int bbraNImm8 = 0xC8;
  static const int bbraPImm8 = 0xC9;
  static const int bbraNZImm4 = 0xCA;
  static const int bbraNZImm8 = 0xCB;

  // 4.11 Context Exchange (0xD0 - 0xD2)
  static const int xchg = 0xD0;
  static const int xchgAll = 0xD1;
  static const int xchgMost = 0xD2;

  // 4.12 Hardware Streaming FIFOs & Mailbox (0xE0 - 0xE9)
  static const int fifoR = 0xE0;
  static const int fifoW = 0xE1;
  static const int fifoStat = 0xE2;
  static const int fifoTryR = 0xE3;
  static const int fifoTryW = 0xE4;
  static const int mbox = 0xE5;
}
