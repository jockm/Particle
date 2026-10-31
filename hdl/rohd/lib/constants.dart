abstract class ParticleWidths {
  static const int word = 32;
  static const int halfWord = 16;
  static const int inst = 16;
  static const int byte = 8;
  static const int regAddr = 4;
  static const int opcode = 8;
  static const int imm4 = 4;
  static const int imm8 = 8;
}

abstract class ParticleOpcodes {
  // Loads & Immediates
  static const int ld = 0x00;
  static const int ldImm4 = 0x01;
  static const int ldImm8 = 0x02;
  static const int ldNegImm4 = 0x03;
  static const int ldNegImm8 = 0x04;
  static const int push4 = 0x05;
  static const int push8 = 0x06;

  // Unsigned & Signed Math
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

  // Logic, Shifts & Sign Extension
  static const int shiftl = 0x60;
  static const int sext8 = 0x61;
  static const int shiftr = 0x62;
  static const int ashiftr = 0x63;
  static const int rotl = 0x64;
  static const int rotr = 0x65;
  static const int and = 0x66;
  static const int or = 0x67;
  static const int xor = 0x68;
  static const int shiftlImm4 = 0x69;
  static const int sext16 = 0x6A;
  static const int shiftrImm4 = 0x6B;
  static const int ashiftrImm4 = 0x6C;
  static const int rotlImm4 = 0x6D;
  static const int rotrImm4 = 0x6E;
  static const int andImm4 = 0x6F;
  static const int orImm4 = 0x70;
  static const int xorImm4 = 0x71;

  // Newly Added Inversion & Boolean Instructions
  static const int not = 0x72;
  static const int nez = 0x73;

  // Multipliers
  static const int mull = 0x78;
  static const int mulh = 0x79;
  static const int smulh = 0x7A;
  static const int mulhsu = 0x7B;
  static const int mullImm4 = 0x7C;
  static const int mulhImm4 = 0x7D;
  static const int smulhImm4 = 0x7E;
  static const int mulhsuImm4 = 0x7F;

  // Bit Manipulation & System
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

  // Relational
  static const int slt = 0x90;
  static const int sltImm4 = 0x91;
  static const int sslt = 0x95;
  static const int ssltImm4 = 0x96;

  // Control Flow & System
  static const int jmp = 0xA0;
  static const int rjump = 0xA1;
  static const int trapReg = 0xA2;
  static const int trapImm4 = 0xA3;
  static const int wait = 0xA4;

  // Branches
  static const int fbra = 0xB0;
  static const int bbra = 0xC0;

  // Shadow Banks
  static const int xchg = 0xD0;
  static const int xchgall = 0xD1;
  static const int xchgmost = 0xD2;

  // Hardware Streaming FIFOs
  static const int fifoR = 0xE0;
  static const int fifoW = 0xE1;
  static const int fifoStat = 0xE2;
  static const int fifoTryR = 0xE3;
  static const int fifoTryW = 0xE4;
  static const int mbox = 0xE5;
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
