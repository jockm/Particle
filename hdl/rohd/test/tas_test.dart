import 'package:rohd/rohd.dart';
import 'package:test/test.dart';
import '../lib/constants.dart';
import '../lib/cpu_config.dart';
import '../lib/cpu_core.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('TAS (Rr), Rl performs atomic memory-register swap correctly', () async {
    final clk = Logic(name: 'clk');
    final reset = Logic(name: 'reset');
    final memARData = Logic(name: 'memARData', width: ParticleWidths.inst);
    final memBRData = Logic(name: 'memBRData', width: ParticleWidths.word);
    final mboxStrobe = Logic(name: 'mboxStrobe');
    final mboxVector = Logic(name: 'mboxVector', width: ParticleWidths.trapVector);

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

    // Clock generator schedule
    Simulator.registerAction(0, () => clk.put(0));
    Simulator.registerAction(5, () => clk.put(1));
    Simulator.registerAction(10, () => clk.put(0));

    reset.put(1);
    memARData.put(0);
    memBRData.put(0);
    mboxStrobe.put(0);
    mboxVector.put(0);

    // 1. Fetch LD R1, 4 (0x0114: ldImm4, rr=1, rl=4) -> Address = 4
    Simulator.registerAction(12, () {
      reset.put(0);
      memARData.put((ParticleOpcodes.ldImm4 << 8) | 0x14);
    });
    Simulator.registerAction(15, () => clk.put(1));
    Simulator.registerAction(20, () => clk.put(0));

    // Exec LD R1, 4 -> R1 = 4
    Simulator.registerAction(25, () => clk.put(1));
    Simulator.registerAction(30, () => clk.put(0));

    // 2. Fetch LD R2, 7 (0x0127: ldImm4, rr=2, rl=7) -> New Value = 7
    Simulator.registerAction(32, () {
      memARData.put((ParticleOpcodes.ldImm4 << 8) | 0x27);
    });
    Simulator.registerAction(35, () => clk.put(1));
    Simulator.registerAction(40, () => clk.put(0));

    // Exec LD R2, 7 -> R2 = 7
    Simulator.registerAction(45, () => clk.put(1));
    Simulator.registerAction(50, () => clk.put(0));

    // 3. Fetch TAS (R1), R2 (0x8B12: tas, rr=1, rl=2)
    Simulator.registerAction(52, () {
      memARData.put((ParticleOpcodes.tas << 8) | 0x12);
      memBRData.put(0xAA55AA55); // Old memory value
    });
    Simulator.registerAction(55, () => clk.put(1));
    Simulator.registerAction(60, () => clk.put(0));

    // Exec TAS: Verify strobes, memory address, and write data
    Simulator.registerAction(65, () {
      clk.put(1);
      expect(core.memPortBAddr.value.toInt(), equals(4));
      expect(core.memPortBWData.value.toInt(), equals(7));
      expect(core.memPortBREn.value.toInt(), equals(1));
      expect(core.memPortBWEn.value.toInt(), equals(1));
      expect(core.memPortBBEn.value.toInt(), equals(0xF));
    });
    Simulator.registerAction(70, () => clk.put(0));

    await Simulator.run();
  });
}
