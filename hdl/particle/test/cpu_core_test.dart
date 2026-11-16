// =============================================================================
// File: hdl/particle/test/cpu_core_test.dart
// Architecture: Particle 32-bit RISC
// Description: Integrated testbench verifying instruction fetch, reset vector,
//              and Direct Stride vector dispatch.
// =============================================================================

import 'package:rohd/rohd.dart';
import 'package:test/test.dart';
import '../lib/constants.dart';
import '../lib/cpu_config.dart';
import '../lib/cpu_core.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  group('Particle CPU Core Integration Tests', () {
    late Logic clk;
    late Logic reset;
    late Logic memARData;
    late Logic memBRData;
    late Logic mboxStrobe;
    late Logic mboxVector;
    late ParticleCpuCore core;

    setUp(() async {
      clk = Logic(name: 'clk');
      reset = Logic(name: 'reset');
      memARData = Logic(name: 'memARData', width: ParticleWidths.halfWord);
      memBRData = Logic(name: 'memBRData', width: ParticleWidths.word);
      mboxStrobe = Logic(name: 'mboxStrobe');
      mboxVector = Logic(name: 'mboxVector', width: ParticleWidths.trapVector);

      core = ParticleCpuCore(
        clk: clk,
        reset: reset,
        memPortARData: memARData,
        memPortBRData: memBRData,
        mboxStrobeIn: mboxStrobe,
        mboxVectorIn: mboxVector,
        config: const CpuConfig(trapTableBase: 0x0100, trapStrideBytes: 64),
      );
      await core.build();
    });

    test('Core Reset Vector Fetch at 0x0100', () async {
      // Clock 1 cycle in reset
      Simulator.registerAction(0, () => clk.put(0));
      Simulator.registerAction(5, () => clk.put(1));
      Simulator.registerAction(10, () => clk.put(0));

      reset.put(1);
      memARData.put(0);
      memBRData.put(0);
      mboxStrobe.put(0);
      mboxVector.put(0);

      await Simulator.run();

      expect(core.memPortAAddr.value.toInt(), equals(0x00000100));
    });

    test('Inbound MBOX Strobe Interruption to Vector 1 (0x0140)', () async {
      // Cycle 1: Reset active
      Simulator.registerAction(0, () => clk.put(0));
      Simulator.registerAction(5, () => clk.put(1));
      Simulator.registerAction(10, () => clk.put(0));

      // Cycle 2: Deassert reset, assert MBOX strobe for Vector 1
      Simulator.registerAction(12, () {
        reset.put(0);
        mboxVector.put(1);
        mboxStrobe.put(1);
      });
      Simulator.registerAction(15, () => clk.put(1));
      Simulator.registerAction(20, () => clk.put(0));

      reset.put(1);
      memARData.put(0);
      memBRData.put(0);
      mboxStrobe.put(0);
      mboxVector.put(0);

      await Simulator.run();

      // Vector 1 target: TRAP_TABLE_BASE (0x0100) + (1 * 64) = 0x0140 (320)
      expect(core.memPortAAddr.value.toInt(), equals(0x00000140));
    });
  
    test('ParticleCpuCore executes RBASE instructions correctly', () async {
      // Cycle 1: Reset active
      Simulator.registerAction(0, () => clk.put(0));
      Simulator.registerAction(5, () => clk.put(1));
      Simulator.registerAction(10, () => clk.put(0));

      // Cycle 2: Release reset -> State Fetch (Fetch 0xD310: RBASE Imm4 = 16 or 0xD30F: RBASE Imm4 = 15)
      Simulator.registerAction(12, () {
        reset.put(0);
        // Opcode 0xD3, Imm4 = 15 (0xD30F)
        memARData.put((ParticleOpcodes.rbaseImm4 << 8) | 0x0F);
      });
      Simulator.registerAction(15, () => clk.put(1));
      Simulator.registerAction(20, () => clk.put(0));

      // Cycle 3: State Exec -> RBASE updates on this clock edge
      Simulator.registerAction(25, () => clk.put(1));
      Simulator.registerAction(30, () => clk.put(0));

      reset.put(1);
      memARData.put(0);
      memBRData.put(0);
      mboxStrobe.put(0);
      mboxVector.put(0);

      await Simulator.run();

      expect(core.memPortAAddr.value.toInt(), equals(0x00000102));
    });    test('Trap 14 is triggered on unaligned LD32 address', () async {
      // Pulse 1 (t=5): Reset active
      Simulator.registerAction(0, () => clk.put(0));
      Simulator.registerAction(5, () => clk.put(1));
      Simulator.registerAction(10, () => clk.put(0));

      // Pulse 2 (t=15): Fetch ADD_IMM4 R2, 1 (0x0621)
      Simulator.registerAction(12, () {
        reset.put(0);
        memARData.put((ParticleOpcodes.addImm4 << 8) | 0x21);
      });
      Simulator.registerAction(15, () => clk.put(1));
      Simulator.registerAction(20, () => clk.put(0));

      // Pulse 3 (t=25): Exec ADD_IMM4 (R2 becomes 1) -> PC latches 0x0102, transitions to stateFetch
      Simulator.registerAction(25, () => clk.put(1));
      Simulator.registerAction(30, () => clk.put(0));

      // Pulse 4 (t=35): Fetch LD32 R1, (R2) -> transitions to stateExec
      Simulator.registerAction(32, () {
        memARData.put((ParticleOpcodes.ld32 << 8) | 0x12);
      });
      Simulator.registerAction(35, () => clk.put(1));
      Simulator.registerAction(40, () => clk.put(0));

      // Pulse 5 (t=45): Exec LD32 -> Trap 14 fires, next PC latches 0x0480
      Simulator.registerAction(45, () => clk.put(1));
      Simulator.registerAction(50, () => clk.put(0));

      reset.put(1);
      memARData.put(0);
      memBRData.put(0);
      mboxStrobe.put(0);
      mboxVector.put(0);

      await Simulator.run();

      // Trap 14 target: 0x0100 + (14 * 64) = 0x0480 (1152)
      expect(core.memPortAAddr.value.toInt(), equals(0x00000480));

      // Memory Read/Write strobes must be suppressed during alignment trap
      expect(core.memPortBREn.value.toInt(), equals(0));
      expect(core.memPortBWEn.value.toInt(), equals(0));
    });

    test('Trap 14 is triggered on unaligned LD16 address', () async {
      // Pulse 1 (t=5): Reset active
      Simulator.registerAction(0, () => clk.put(0));
      Simulator.registerAction(5, () => clk.put(1));
      Simulator.registerAction(10, () => clk.put(0));

      // Pulse 2 (t=15): Fetch ADD_IMM4 R2, 1 (0x0621)
      Simulator.registerAction(12, () {
        reset.put(0);
        memARData.put((ParticleOpcodes.addImm4 << 8) | 0x21);
      });
      Simulator.registerAction(15, () => clk.put(1));
      Simulator.registerAction(20, () => clk.put(0));

      // Pulse 3 (t=25): Exec ADD_IMM4 (R2 becomes 1) -> PC latches 0x0102
      Simulator.registerAction(25, () => clk.put(1));
      Simulator.registerAction(30, () => clk.put(0));

      // Pulse 4 (t=35): Fetch LD16 R1, (R2) -> opcode 0x20, Rr = 1, Rl = 2
      Simulator.registerAction(32, () {
        memARData.put((ParticleOpcodes.ld16 << 8) | 0x12);
      });
      Simulator.registerAction(35, () => clk.put(1));
      Simulator.registerAction(40, () => clk.put(0));

      // Pulse 5 (t=45): Exec LD16 -> Trap 14 fires due to odd address (1)
      Simulator.registerAction(45, () => clk.put(1));
      Simulator.registerAction(50, () => clk.put(0));

      reset.put(1);
      memARData.put(0);
      memBRData.put(0);
      mboxStrobe.put(0);
      mboxVector.put(0);

      await Simulator.run();

      expect(core.memPortAAddr.value.toInt(), equals(0x00000480));
      expect(core.memPortBREn.value.toInt(), equals(0));
    });

    test('Trap 14 is triggered on unaligned branch/jump target', () async {
      // Pulse 1 (t=5): Reset active
      Simulator.registerAction(0, () => clk.put(0));
      Simulator.registerAction(5, () => clk.put(1));
      Simulator.registerAction(10, () => clk.put(0));

      // Pulse 2 (t=15): Fetch ADD_IMM4 R1, 1 (0x0611) -> R1 becomes 1 (odd jump target)
      Simulator.registerAction(12, () {
        reset.put(0);
        memARData.put((ParticleOpcodes.addImm4 << 8) | 0x11);
      });
      Simulator.registerAction(15, () => clk.put(1));
      Simulator.registerAction(20, () => clk.put(0));

      // Pulse 3 (t=25): Exec ADD_IMM4 -> R1 becomes 1, PC latches 0x0102
      Simulator.registerAction(25, () => clk.put(1));
      Simulator.registerAction(30, () => clk.put(0));

      // Pulse 4 (t=35): Fetch JMP R1, R0 -> opcode 0xA0, Rr = 1, Rl = 0
      Simulator.registerAction(32, () {
        memARData.put((ParticleOpcodes.jmp << 8) | 0x10);
      });
      Simulator.registerAction(35, () => clk.put(1));
      Simulator.registerAction(40, () => clk.put(0));

      // Pulse 5 (t=45): Exec JMP -> branch target bit 0 is set -> Trap 14 fires
      Simulator.registerAction(45, () => clk.put(1));
      Simulator.registerAction(50, () => clk.put(0));

      reset.put(1);
      memARData.put(0);
      memBRData.put(0);
      mboxStrobe.put(0);
      mboxVector.put(0);

      await Simulator.run();

      expect(core.memPortAAddr.value.toInt(), equals(0x00000480));
    });

    test('LDI zero-extends 16-bit immediate and advances PC by 4', () async {
      // Pulse 1 (t=5): Reset active
      Simulator.registerAction(0, () => clk.put(0));
      Simulator.registerAction(5, () => clk.put(1));
      Simulator.registerAction(10, () => clk.put(0));

      // Pulse 2 (t=15): Fetch LDI R5, 0xBEEF (Word 0 = 0x0705)
      Simulator.registerAction(12, () {
        reset.put(0);
        memARData.put((ParticleOpcodes.ldi << 8) | 0x05);
      });
      Simulator.registerAction(15, () => clk.put(1));
      Simulator.registerAction(20, () => clk.put(0));

      // Pulse 3 (t=25): Exec LDI -> transitions to stateFetchImm (memPortAAddr -> 0x0102)
      Simulator.registerAction(25, () => clk.put(1));
      Simulator.registerAction(30, () => clk.put(0));

      // Pulse 4 (t=35): FetchImm latches 0xBEEF into R5 and advances PC to 0x0104
      Simulator.registerAction(32, () {
        expect(core.memPortAAddr.value.toInt(), equals(0x00000102));
        memARData.put(0xBEEF);
      });
      Simulator.registerAction(35, () => clk.put(1));
      Simulator.registerAction(40, () => clk.put(0));

      // Pulse 5 (t=45): Fetch next instruction ST32 (R0), R5 (0x3505) to observe R5 on memPortBWData
      Simulator.registerAction(42, () {
        expect(core.memPortAAddr.value.toInt(), equals(0x00000104));
        memARData.put((ParticleOpcodes.st32 << 8) | 0x05);
      });
      Simulator.registerAction(45, () => clk.put(1));
      Simulator.registerAction(50, () => clk.put(0));

      reset.put(1);
      memARData.put(0);
      memBRData.put(0);
      mboxStrobe.put(0);
      mboxVector.put(0);

      await Simulator.run();

      expect(core.memPortBWData.value.toInt(), equals(0x0000BEEF));
      expect(core.memPortAAddr.value.toInt(), equals(0x00000104));
    });

    test('LDIS sign-extends 16-bit immediate and advances PC by 4', () async {
      // Pulse 1 (t=5): Reset active
      Simulator.registerAction(0, () => clk.put(0));
      Simulator.registerAction(5, () => clk.put(1));
      Simulator.registerAction(10, () => clk.put(0));

      // Pulse 2 (t=15): Fetch LDIS R6, -4096 (0xF000 -> Word 0 = 0x0806)
      Simulator.registerAction(12, () {
        reset.put(0);
        memARData.put((ParticleOpcodes.ldis << 8) | 0x06);
      });
      Simulator.registerAction(15, () => clk.put(1));
      Simulator.registerAction(20, () => clk.put(0));

      // Pulse 3 (t=25): Exec LDIS -> transitions to stateFetchImm (memPortAAddr -> 0x0102)
      Simulator.registerAction(25, () => clk.put(1));
      Simulator.registerAction(30, () => clk.put(0));

      // Pulse 4 (t=35): FetchImm latches 0xFFFFF000 into R6 and advances PC to 0x0104
      Simulator.registerAction(32, () {
        expect(core.memPortAAddr.value.toInt(), equals(0x00000102));
        memARData.put(0xF000);
      });
      Simulator.registerAction(35, () => clk.put(1));
      Simulator.registerAction(40, () => clk.put(0));

      // Pulse 5 (t=45): Fetch ST32 (R0), R6 (0x3506) to observe R6 on memPortBWData
      Simulator.registerAction(42, () {
        expect(core.memPortAAddr.value.toInt(), equals(0x00000104));
        memARData.put((ParticleOpcodes.st32 << 8) | 0x06);
      });
      Simulator.registerAction(45, () => clk.put(1));
      Simulator.registerAction(50, () => clk.put(0));

      reset.put(1);
      memARData.put(0);
      memBRData.put(0);
      mboxStrobe.put(0);
      mboxVector.put(0);

      await Simulator.run();

      expect(core.memPortBWData.value.toInt(), equals(0xFFFFF000));
      expect(core.memPortAAddr.value.toInt(), equals(0x00000104));
    });
  });
}
