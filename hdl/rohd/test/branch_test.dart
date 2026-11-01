// =============================================================================
// File: hdl/rohd/test/branch_test.dart
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
}
