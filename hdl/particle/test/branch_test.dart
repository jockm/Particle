// =============================================================================
// File: hdl/particle/test/branch_test.dart
// Architecture: Particle 32-bit RISC Core
// Description: Unit testbench verifying branch target computation in cpu_core.
// =============================================================================

import 'package:test/test.dart';
import 'package:rohd/rohd.dart';
import '../lib/constants.dart';
import '../lib/cpu_config.dart';
import '../lib/cpu_core.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('Core initializes PC to trapTableBase on reset', () async {
    final clk = Logic(name: 'clk');
    final reset = Logic(name: 'reset');
    final memARData = Logic(name: 'memARData', width: ParticleWidths.inst);
    final memBRData = Logic(name: 'memBRData', width: ParticleWidths.word);
    final mboxStrobe = Logic(name: 'mboxStrobe');
    final mboxVector =
        Logic(name: 'mboxVector', width: ParticleWidths.trapVector);

    final core = ParticleCpuCore(
      clk: clk,
      reset: reset,
      memPortARData: memARData,
      memPortBRData: memBRData,
      mboxStrobeIn: mboxStrobe,
      mboxVectorIn: mboxVector,
      config: const CpuConfig(trapTableBase: 0x00000100),
    );

    await core.build();

    // Clock generator
    Simulator.registerAction(0, () => clk.put(0));
    Simulator.registerAction(5, () => clk.put(1));
    Simulator.registerAction(10, () => clk.put(0));

    // Reset sequence
    reset.put(1);
    memARData.put(0);
    memBRData.put(0);
    mboxStrobe.put(0);
    mboxVector.put(0);

    await Simulator.run();

    reset.put(0);
    expect(core.memPortAAddr.value.toInt(), equals(0x00000100));
  });

  test("JTBL Rr computed table jump updates PC correctly", () async {
    final clk = Logic(name: "clk");
    final reset = Logic(name: "reset");
    final memARData = Logic(name: "memARData", width: ParticleWidths.inst);
    final memBRData = Logic(name: "memBRData", width: ParticleWidths.word);
    final mboxStrobe = Logic(name: "mboxStrobe");
    final mboxVector =
        Logic(name: "mboxVector", width: ParticleWidths.trapVector);

    final core = ParticleCpuCore(
      clk: clk,
      reset: reset,
      memPortARData: memARData,
      memPortBRData: memBRData,
      mboxStrobeIn: mboxStrobe,
      mboxVectorIn: mboxVector,
      config: const CpuConfig(trapTableBase: 0x00000100),
    );

    await core.build();

    // Reset cycle (t=0..10)
    Simulator.registerAction(0, () => clk.put(0));
    Simulator.registerAction(5, () => clk.put(1));
    Simulator.registerAction(10, () => clk.put(0));

    reset.put(1);
    memARData.put(0);
    memBRData.put(0);
    mboxStrobe.put(0);
    mboxVector.put(0);

    // Cycle 1: Fetch at 0x100 -> Feed LD R1, 3 (0x0113: opcode=0x01 ldImm4, rr=1, rl=3)
    Simulator.registerAction(12, () {
      reset.put(0);
      memARData.put((ParticleOpcodes.ldImm4 << 8) | 0x13);
    });
    Simulator.registerAction(15, () => clk.put(1));
    Simulator.registerAction(20, () => clk.put(0));

    // Cycle 2: Exec LD R1, 3 -> R1 latched to 3 on rising edge
    Simulator.registerAction(25, () => clk.put(1));
    Simulator.registerAction(30, () => clk.put(0));

    // Cycle 3: Fetch at 0x102 -> Feed JTBL R1 (0x8110: opcode=0x81 jtbl, rr=1, rl=0)
    Simulator.registerAction(32, () {
      memARData.put((ParticleOpcodes.jtbl << 8) | 0x10);
    });
    Simulator.registerAction(35, () => clk.put(1));
    Simulator.registerAction(40, () => clk.put(0));

    // Cycle 4: Exec JTBL R1 -> PC updates to 0x102 + 2 + (3 * 2) = 0x10A
    Simulator.registerAction(45, () => clk.put(1));
    Simulator.registerAction(50, () => clk.put(0));

    await Simulator.run();

    // Core should now request instruction at computed target 0x0000010A
    expect(core.memPortAAddr.value.toInt(), equals(0x0000010A));
  });
}
