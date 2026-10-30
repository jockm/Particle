abstract class ParticleWidths {
  static const int word = 32;
  static const int inst = 16;
  static const int regAddr = 4;
}

abstract class ParticleOpcodes {
  static const int ld = 0x00;
  static const int ldImm4 = 0x01;
  static const int ldImm8 = 0x02;
}
