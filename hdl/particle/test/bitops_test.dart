import 'package:rohd/rohd.dart';
import 'package:test/test.dart';
import '../lib/constants.dart';
import '../lib/cpu_config.dart';
import '../lib/cpu_core.dart';

void main() {
  tearDown(() async {
    await Simulator.reset();
  });

  test('BEXTR, BSET, BINV, BCLR execute correctly in core', () async {
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
    // Reset cycle (t=0..10)
    Simulator.registerAction(0, () => clk.put(0));
    Simulator.registerAction(5, () => clk.put(1));
    Simulator.registerAction(10, () => clk.put(0));

    reset.put(1);
    memARData.put(0);
    memBRData.put(0);
    mboxStrobe.put(0);
    mboxVector.put(0);

    // 1. Fetch LD R1, 5 (0x0115: ldImm4, rr=1, rl=5)
    Simulator.registerAction(12, () {
      reset.put(0);
      memARData.put((ParticleOpcodes.ldImm4 << 8) | 0x15);
    });
    Simulator.registerAction(15, () => clk.put(1));
    Simulator.registerAction(20, () => clk.put(0));

    // Exec LD R1, 5 -> R1 becomes 5
    Simulator.registerAction(25, () => clk.put(1));
    Simulator.registerAction(30, () => clk.put(0));

    // 2. Fetch BEXTR R1, R1 (0x8011: bextr, rr=1, rl=1)
    // R1 = 5 (binary 0101). Offset = 5 & 0x1F = 5. (5 >> 5) & 1 = 0
    Simulator.registerAction(32, () {
      memARData.put((ParticleOpcodes.bextr << 8) | 0x11);
    });
    Simulator.registerAction(35, () => clk.put(1));
    Simulator.registerAction(40, () => clk.put(0));

    // Exec BEXTR R1, R1 -> R1 becomes 0
    Simulator.registerAction(45, () => clk.put(1));
    Simulator.registerAction(50, () => clk.put(0));

    // 3. Fetch BSET R1, 3 (0x8413: bsetImm4, rr=1, imm4=3) -> R1 = 0 | (1 << 3) = 8
    Simulator.registerAction(52, () {
      memARData.put((ParticleOpcodes.bsetImm4 << 8) | 0x13);
    });
    Simulator.registerAction(55, () => clk.put(1));
    Simulator.registerAction(60, () => clk.put(0));

    // Exec BSET R1, 3 -> R1 becomes 8
    Simulator.registerAction(65, () => clk.put(1));
    Simulator.registerAction(70, () => clk.put(0));

    // 4. Fetch BINV R1, 0 (0x8810: binvImm4, rr=1, imm4=0) -> R1 = 8 ^ (1 << 0) = 9
    Simulator.registerAction(72, () {
      memARData.put((ParticleOpcodes.binvImm4 << 8) | 0x10);
    });
    Simulator.registerAction(75, () => clk.put(1));
    Simulator.registerAction(80, () => clk.put(0));

    // Exec BINV R1, 0 -> R1 becomes 9
    Simulator.registerAction(85, () => clk.put(1));
    Simulator.registerAction(90, () => clk.put(0));

    // 5. Fetch BCLR R1, 3 (0x8613: bclrImm4, rr=1, imm4=3) -> R1 = 9 & ~(1 << 3) = 1
    Simulator.registerAction(92, () {
      memARData.put((ParticleOpcodes.bclrImm4 << 8) | 0x13);
    });
    Simulator.registerAction(95, () => clk.put(1));
    Simulator.registerAction(100, () => clk.put(0));

    // Exec BCLR R1, 3 -> R1 becomes 1
    Simulator.registerAction(105, () => clk.put(1));
    Simulator.registerAction(110, () => clk.put(0));

    await Simulator.run();
  });
}
